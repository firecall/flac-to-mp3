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
                 space_saved_bytes: 0 }
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

      return skip_existing?(mkv_path, logger) if File.exist?(mkv_path)

      unless needs_transcode?(source_path)
        logger&.log("[SKIP] Already ≤ #{TARGET_HEIGHT}p: #{File.basename(source_path)}")
        @mutex.synchronize { @stats[:skipped] += 1 }
        return true
      end

      return dry_run_convert?(source_path, mkv_path, logger) if dry_run

      transcode_and_compare(source_path, mkv_path, logger)
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

    # Compare sizes: if transcoded is smaller, delete original and keep transcoded.
    # If transcoded is larger or equal, keep original and delete transcoded.
    def compare_and_replace(source_path, mkv_path, logger)
      source_size = File.size(source_path)
      mkv_size = File.size(mkv_path)

      if mkv_size < source_size
        saved = source_size - mkv_size
        @mutex.synchronize { @stats[:space_saved_bytes] += saved }
        File.delete(source_path)
        logger&.log("[DEL] Removed original: #{File.basename(source_path)} " \
                    "(saved #{format_bytes(saved)})")
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
