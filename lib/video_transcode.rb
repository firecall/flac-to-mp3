#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'find'
require 'time'
require 'json'
require 'open3'

module VideoTranscode
  # Video file extensions that the converter will process.
  VIDEO_EXTENSIONS = %w[.mkv .mp4 .avi .mov .wmv .m4v .webm].freeze

  # Case-insensitive regex matching any video extension at end of string.
  VIDEO_EXTENSION_REGEX = /\.(?:mkv|mp4|avi|mov|wmv|m4v|webm)$/i.freeze

  # Handles the conversion logic: finding video files, probing resolution,
  # running ffmpeg with NVENC, comparing sizes, and replacing originals.
  class Converter
    attr_reader :path, :dry_run, :stats

    TARGET_HEIGHT = 720
    TARGET_WIDTH = 1280

    def initialize(path:, dry_run: false)
      @path = File.expand_path(path)
      @dry_run = dry_run
      @stats = { processed: 0, failed: 0, skipped: 0, kept: 0,
                 renamed: 0, space_saved_bytes: 0 }
      @mutex = Mutex.new
      @use_windows_ffmpeg = detect_windows_ffmpeg
    end

    # Recursively find all video files under @path.
    def find_video_files
      files = []
      Find.find(@path) do |f|
        next unless File.file?(f) && video_extension?(f)

        files << f
        yield files.length if block_given?
      end
      files
    end

    # Derive the target MKV path by replacing the original extension with .mkv.
    def new_mkv_path(source_path)
      source_path.sub(VIDEO_EXTENSION_REGEX, '.mkv')
    end

    # Check whether a video file is already ≤ 720p.
    # Uses ffprobe to read the height of the first video stream.
    def needs_transcode?(source_path)
      height = probe_video_height(source_path)
      return true if height.nil? # can't probe, assume it needs transcoding

      height > TARGET_HEIGHT
    end

    # Convert a single video file.
    # Returns true on success/skip, false on failure.
    def convert_file?(source_path, logger: nil)
      mkv_path = new_mkv_path(source_path)

      # Only skip if output exists AND is a different file from the source.
      # (When source is already .mkv, mkv_path == source_path — that's not a skip.)
      if mkv_path != source_path && File.exist?(mkv_path)
        return skip_existing?(mkv_path, logger)
      end

      unless needs_transcode?(source_path)
        logger&.log("[SKIP] Already ≤ #{TARGET_HEIGHT}p: #{File.basename(source_path)}")
        @mutex.synchronize { @stats[:skipped] += 1 }
        return true
      end

      return dry_run_convert?(source_path, mkv_path, logger) if dry_run

      # When source is already .mkv, transcode to a temp file to avoid
      # ffmpeg reading and writing the same file simultaneously.
      if mkv_path == source_path
        transcode_mkv_in_place(source_path, logger)
      else
        transcode_and_compare(source_path, mkv_path, logger)
      end
    end

    # After transcoding, compare file sizes. Keep whichever is smaller.
    # Delete the other. Updates stats accordingly.
    def transcode_and_compare(source_path, mkv_path, logger)
      unless run_transcode(source_path, mkv_path, logger)
        @mutex.synchronize { @stats[:failed] += 1 }
        return false
      end

      compare_and_replace(source_path, mkv_path, logger)
    end

    # Run the NVENC ffmpeg transcode. Returns true on success.
    def run_transcode(source_path, mkv_path, logger)
      cmd = ffmpeg_command(source_path, mkv_path)
      if system(*cmd, err: File::NULL)
        logger&.log("[OK] Transcoded: #{File.basename(source_path)} -> #{File.basename(mkv_path)}")
        true
      else
        logger&.log("[FAIL] FFmpeg error on: #{File.basename(source_path)}")
        # Clean up partial output
        File.delete(mkv_path) if File.exist?(mkv_path)
        false
      end
    rescue StandardError => e
      logger&.log("[FAIL] #{File.basename(source_path)}: #{e.message}")
      File.delete(mkv_path) if File.exist?(mkv_path)
      false
    end

    # Transcode an already-.mkv file to a temp file, then compare sizes.
    # Avoids ffmpeg reading and writing the same file simultaneously.
    def transcode_mkv_in_place(source_path, logger)
      tmp_path = "#{source_path}.tmp"
      unless run_transcode(source_path, tmp_path, logger)
        @mutex.synchronize { @stats[:failed] += 1 }
        return false
      end

      source_size = File.size(source_path)
      tmp_size = File.size(tmp_path)

      if tmp_size < source_size
        saved = source_size - tmp_size
        @mutex.synchronize { @stats[:space_saved_bytes] += saved }
        File.delete(source_path)

        final_path = unique_path(new_filename(source_path))
        File.rename(tmp_path, final_path)
        renamed = final_path != source_path
        logger&.log("[DEL] Replaced original with smaller transcode: #{File.basename(final_path)} " \
                    "(saved #{format_bytes(saved)})")
        logger&.log("[RNM] Renamed: #{File.basename(source_path)} -> #{File.basename(final_path)}") if renamed
        @mutex.synchronize do
          @stats[:processed] += 1
          @stats[:renamed] += 1 if renamed
        end
      else
        File.delete(tmp_path)
        logger&.log("[KEEP] Transcoded file not smaller " \
                    "(#{format_bytes(tmp_size)} vs #{format_bytes(source_size)}): " \
                    "#{File.basename(source_path)}")
        @mutex.synchronize { @stats[:kept] += 1 }
      end
      true
    end

    # Compare sizes: if transcoded is smaller, delete original and keep transcoded.
    # If transcoded is larger or equal, keep original and delete transcoded.
    def compare_and_replace(source_path, mkv_path, logger)
      source_size = File.size(source_path)
      mkv_size = File.size(mkv_path)

      if mkv_size < source_size
        saved = source_size - mkv_size
        @mutex.synchronize { @stats[:space_saved_bytes] += saved }
        File.delete(source_path)

        final_path = unique_path(new_filename(source_path))
        File.rename(mkv_path, final_path)
        renamed = final_path != mkv_path
        logger&.log("[DEL] Removed original: #{File.basename(source_path)} " \
                    "(saved #{format_bytes(saved)})")
        logger&.log("[RNM] Renamed: #{File.basename(mkv_path)} -> #{File.basename(final_path)}") if renamed
        @mutex.synchronize do
          @stats[:renamed] += 1 if renamed
        end
        true
      else
        File.delete(mkv_path)
        logger&.log("[KEEP] Transcoded file not smaller " \
                    "(#{format_bytes(mkv_size)} vs #{format_bytes(source_size)}): " \
                    "#{File.basename(source_path)}")
        @mutex.synchronize { @stats[:kept] += 1 }
        true
      end
    end

    # Probe video height using ffprobe. Returns integer height or nil on failure.
    def probe_video_height(source_path)
      exe = @use_windows_ffmpeg ? 'ffprobe.exe' : 'ffprobe'
      src = @use_windows_ffmpeg ? to_windows_path(source_path) : source_path

      stdout, _stderr, status = Open3.capture3(
        exe, '-v', 'quiet', '-print_format', 'json',
        '-show_streams', '-select_streams', 'v:0', src
      )
      return nil unless status.success?

      streams = JSON.parse(stdout)['streams']
      return nil if streams.nil? || streams.empty?

      streams.first['height']
    rescue StandardError
      nil
    end

    def log_error(message, logger: nil)
      logger&.log(message)
      @mutex.synchronize { @stats[:failed] += 1 }
    end

    # Derive a Plex-standardized filename for the transcoded output.
    # Attempts "Title (Year) - 720p.mkv"; falls back to in-place tag substitution.
    def new_filename(source_path)
      dir = File.dirname(source_path)
      base = File.basename(source_path)
      base_no_ext = base.sub(VIDEO_EXTENSION_REGEX, '')

      plex_name = parse_plex_name(base_no_ext)
      return File.join(dir, "#{plex_name}.mkv") if plex_name

      File.join(dir, "#{replace_tags_fallback(base_no_ext)}.mkv")
    end

    # True when Windows-native ffmpeg.exe will be used for conversions.
    def windows_ffmpeg?
      @use_windows_ffmpeg
    end

    # True when path is on the Windows filesystem via WSL (/mnt/c/, /mnt/d/, etc.).
    def windows_path?(path)
      path.match?(%r{^/mnt/[a-z]/}i)
    end

    # Convert a WSL path like /mnt/c/Users/foo to C:\Users\foo.
    def to_windows_path(path)
      path
        .sub(%r{^/mnt/([a-z])/}i) { "#{Regexp.last_match(1).upcase}:\\" }
        .gsub('/', '\\')
    end

    private

    # Attempt to parse "Title (Year) - 720p" from a scene filename.
    # Returns nil if no year is found, triggering the fallback path.
    def parse_plex_name(base_no_ext)
      # Match first 4-digit year between 1900-2099 not part of a larger number
      match = base_no_ext.match(/\b((?:19|20)\d{2})\b/)
      return nil unless match

      year = match[1]
      title = base_no_ext[0...match.begin(0)].gsub('.', ' ').gsub('_', ' ').strip
      title = title.gsub(/\s{2,}/, ' ')

      # Don't produce empty or meaningless titles
      return nil if title.empty? || title.length < 1

      "#{title} (#{year}) - 720p"
    end

    # Fallback: in-place tag substitution when Plex name parsing fails.
    def replace_tags_fallback(base_no_ext)
      result = base_no_ext.dup

      # Replace resolution tags
      result.gsub!(/\b2160p\b/i, '720p')
      result.gsub!(/\b1080p\b/i, '720p')
      result.gsub!(/\b4[kK]\b/, '720p')
      result.gsub!(/\bUHD\b/i, '720p')

      # Normalize H.264 codec tags
      result.gsub!(/\bx265\b/i, 'x264')
      result.gsub!(/\bh\.?265\b/i, 'x264')
      result.gsub!(/\bHEVC\b/i, 'x264')
      result.gsub!(/\bAVC\b/i, 'x264')
      result.gsub!(/\bh\.?264\b/i, 'x264')

      # Strip group tags: [GROUP] or -GROUP at end before extension
      result.gsub!(/\s*[-_.]\s*\[[^\]]+\]\s*$/, '')
      result.gsub!(/\s*[-_.]\s*-[A-Za-z0-9]+\s*$/, '')

      # If no resolution tag remains, append 720p
      unless result.match?(/\b\d{3,4}p\b/i)
        result = "#{result}.720p"
      end

      result.strip
    end

    def video_extension?(filename)
      VIDEO_EXTENSION_REGEX.match?(filename)
    end

    def skip_existing?(mkv_path, logger)
      logger&.log("[SKIP] Output already exists: #{File.basename(mkv_path)}")
      @mutex.synchronize { @stats[:skipped] += 1 }
      true
    end

    def dry_run_convert?(source_path, mkv_path, logger)
      logger&.log("[DRY-RUN] Would transcode: #{File.basename(source_path)} -> #{File.basename(mkv_path)}")
      @mutex.synchronize { @stats[:processed] += 1 }
      true
    end

    # Build the FFmpeg command for NVENC 720p transcode with best quality settings.
    def ffmpeg_command(source_path, mkv_path)
      exe = @use_windows_ffmpeg ? 'ffmpeg.exe' : 'ffmpeg'
      src = @use_windows_ffmpeg ? to_windows_path(source_path) : source_path
      dst = @use_windows_ffmpeg ? to_windows_path(mkv_path) : mkv_path

      [
        exe, '-y', '-i', src,
        '-c:v', 'h264_nvenc',
        '-preset', 'p7',
        '-rc', 'vbr_hq',
        '-cq', '18',
        '-b:v', '0',
        '-maxrate', '5000k',
        '-bufsize', '10000k',
        '-bf', '4',
        '-profile:v', 'high',
        '-pix_fmt', 'yuv420p',
        '-vf', "scale='min(#{TARGET_WIDTH},iw)':'min(#{TARGET_HEIGHT},ih)':force_original_aspect_ratio=decrease",
        '-c:a', 'copy',
        '-map', '0',
        dst
      ]
    end

    def detect_windows_ffmpeg
      return false unless windows_path?(@path)

      system('where.exe ffmpeg.exe > /dev/null 2>&1') == true
    rescue StandardError
      false
    end

    # Resolve filename collisions by appending an incrementing suffix.
    def unique_path(path)
      return path unless File.exist?(path)

      dir = File.dirname(path)
      base = File.basename(path, '.mkv')
      counter = 1
      loop do
        candidate = File.join(dir, "#{base}-#{counter}.mkv")
        return candidate unless File.exist?(candidate)

        counter += 1
      end
    end

    def format_bytes(bytes)
      if bytes >= 1_073_741_824
        format('%.2f GB', bytes / 1_073_741_824.0)
      elsif bytes >= 1_048_576
        format('%.2f MB', bytes / 1_048_576.0)
      elsif bytes >= 1024
        format('%.2f KB', bytes / 1024.0)
      else
        "#{bytes} B"
      end
    end
  end

  # Dual-output logger: writes to both STDOUT and a timestamped log file.
  class DualLogger
    attr_reader :log_path

    def initialize(log_dir: Dir.pwd)
      timestamp = Time.now.strftime('%Y-%m-%d-%H%M%S')
      @log_path = File.join(log_dir, "video-transcode-#{timestamp}.log")
      @file = File.open(@log_path, 'a')
      @mutex = Mutex.new
    end

    def log(message)
      line = "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
      @mutex.synchronize do
        puts line
        @file.puts(line)
        @file.flush
      end
    end

    def close
      @file.close
    end

    def log_summary(stats:, elapsed:, logger: nil)
      logger ||= self
      separator = '=' * 50
      logger.log(separator)
      logger.log('SUMMARY')
      logger.log(separator)
      log_summary_stats(stats, elapsed, logger)
      logger.log(separator)
    end

    private

    def log_summary_stats(stats, elapsed, logger)
      total = stats[:processed] + stats[:failed] + stats[:skipped] + stats[:kept]
      log_file_counts(stats, total, logger)
      logger.log("  Time elapsed    : #{format_duration(elapsed)}")
      logger.log("  Disk space saved: #{format_bytes(stats[:space_saved_bytes])}")
    end

    def log_file_counts(stats, total, logger)
      logger.log("  Files processed : #{stats[:processed]}")
      logger.log("  Files failed    : #{stats[:failed]}")
      logger.log("  Files skipped   : #{stats[:skipped]}")
      logger.log("  Originals kept  : #{stats[:kept]}")
      logger.log("  Total files     : #{total}")
    end

    def format_duration(seconds)
      mm, ss = seconds.divmod(60)
      hh, mm = mm.divmod(60)
      if hh.positive?
        format('%<hh>dh %<mm>02dm %<ss>02ds', hh:, mm:, ss:)
      else
        format('%<mm>dm %<ss>02ds', mm:, ss:)
      end
    end

    def format_bytes(bytes)
      if bytes >= 1_073_741_824
        format('%.2f GB', bytes / 1_073_741_824.0)
      elsif bytes >= 1_048_576
        format('%.2f MB', bytes / 1_048_576.0)
      elsif bytes >= 1024
        format('%.2f KB', bytes / 1024.0)
      else
        "#{bytes} B"
      end
    end
  end
end
