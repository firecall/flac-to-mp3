#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'find'
require 'time'

module FlacToMp3
  # Handles the conversion logic: finding FLAC files, running ffmpeg,
  # renaming, removing originals, and computing disk savings.
  class Converter
    attr_reader :path, :dry_run, :stats

    def initialize(path:, dry_run: false)
      @path = File.expand_path(path)
      @dry_run = dry_run
      @stats = { processed: 0, failed: 0, skipped: 0, space_saved_bytes: 0, dirs_renamed: 0 }
      @mutex = Mutex.new
      @use_windows_ffmpeg = detect_windows_ffmpeg
    end

    def find_flac_files
      files = []
      Find.find(@path) do |f|
        next unless File.file?(f) && f.match?(/\.flac$/i)

        files << f
        yield files.length if block_given?
      end
      files
    end

    # Derive the target MP3 path:
    # 1) Replace .flac / .FLAC extension with .mp3
    # 2) Strip "FLAC" / "flac" / "Flac" substrings from the filename portion
    def new_mp3_path(flac_path)
      dir = File.dirname(flac_path)
      base = File.basename(flac_path).sub(/\.flac$/i, '.mp3')
      File.join(dir, clean_basename(base.gsub(/flac/i, '')))
    end

    # Convert a single FLAC file to MP3 using ffmpeg.
    # Returns true on success/skip, false on failure.
    def convert_file?(flac_path, logger: nil)
      mp3_path = new_mp3_path(flac_path)
      return skip_existing?(mp3_path, logger) if File.exist?(mp3_path)
      return dry_run_convert?(flac_path, mp3_path, logger) if dry_run

      run_ffmpeg?(flac_path, mp3_path, logger)
    end

    # Remove the original FLAC file after successful conversion
    def remove_original(flac_path, logger: nil)
      if dry_run
        logger&.log("[DRY-RUN] Would remove: #{flac_path}")
        return
      end

      File.delete(flac_path)
      logger&.log("[DEL] Removed: #{File.basename(flac_path)}")
    end

    def new_dir_path(dir_path)
      File.join(File.dirname(dir_path), clean_dirname(File.basename(dir_path)))
    end

    def rename_directories(logger: nil)
      find_all_directories.each do |dir_path|
        new_path = new_dir_path(dir_path)
        next if new_path == dir_path

        rename_directory(dir_path, new_path, logger)
      rescue StandardError => e
        logger&.log("[ERROR] Renaming #{File.basename(dir_path)}: #{e.message}")
      end
    end

    def record_space(flac_path)
      flac_size = File.size(flac_path)
      mp3_path = new_mp3_path(flac_path)
      mp3_size = File.exist?(mp3_path) ? File.size(mp3_path) : 0
      saved = flac_size - mp3_size
      @mutex.synchronize { @stats[:space_saved_bytes] += saved } if saved.positive?
      saved
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

    def log_error(message, logger: nil)
      logger&.log(message)
      @mutex.synchronize { @stats[:failed] += 1 }
    end

    private

    def rename_directory(dir_path, new_path, logger)
      if dry_run
        logger&.log("[DRY-RUN] Would rename dir: #{File.basename(dir_path)} -> #{File.basename(new_path)}")
        @mutex.synchronize { @stats[:dirs_renamed] += 1 }
      elsif Dir.exist?(new_path)
        logger&.log("[WARN] Skipping rename: #{File.basename(new_path)} already exists")
      else
        FileUtils.mv(dir_path, new_path)
        logger&.log("[DIR] Renamed: #{File.basename(dir_path)} -> #{File.basename(new_path)}")
        @mutex.synchronize { @stats[:dirs_renamed] += 1 }
      end
    end

    def find_all_directories
      Dir.glob("#{@path}/**/*")
         .select { |f| File.directory?(f) }
         .sort_by { |d| -d.count('/') }
    end

    def clean_dirname(name)
      result = name.gsub(/\s*\[[^\]]*\](?:[-_]\w+)*/i, '') # [PMEDIA], [FLAC]-tag, [24Bit-44.1kHz]
      result = result.gsub(/\s*\([^)]*flac[^)]*\)/i, '') # (FLAC) parens
      result = result.gsub(/flac/i, '') # bare FLAC
      result = result.gsub(/\s*\(\d+_?kbps\)/i, '') # (320kbps), (320_kbps)
      result = result.gsub(/\s*\b\d+_?kbps\b/i, '') # 320kbps, 320_kbps
      result = result.gsub(/\s*\b\d{1,2}[-x]\d{2,3}(?:\.\d+)?\b/i, '') # 24-48, 16-44, 24x96
      result = result.gsub(/\s+\b(?:88\.2|88|96|176\.4|176|192|384)\b\s*$/, '') # trailing sample rates
      result = result.gsub(/\s*\w*[\u{1F300}-\u{1FFFF}\u{2600}-\u{2BFF}️]+\w*/, '') # Beats⭐, ⭐️
      result = result.gsub(/\s{2,}/, ' ').strip
      result.empty? ? 'music' : result
    end

    # Clean up separator artifacts left by removing the FLAC substring.
    # Does NOT touch separators that were already present in the original.
    def clean_basename(base)
      base = base.gsub(/-{2,}/, '-').gsub(/_{2,}/, '_').gsub(/\s{2,}/, ' ')
      base = base.gsub(/^[-_\s]+/, '').gsub(/[-_\s]+\./, '.').strip
      base = 'unknown.mp3' if base.empty? || base == '.mp3'
      base.end_with?('.mp3') ? base : "#{base}.mp3"
    end

    def skip_existing?(mp3_path, logger)
      logger&.log("[SKIP] Output already exists: #{File.basename(mp3_path)}")
      @mutex.synchronize { @stats[:skipped] += 1 }
      true
    end

    def dry_run_convert?(flac_path, mp3_path, logger)
      logger&.log("[DRY-RUN] Would convert: #{File.basename(flac_path)} -> #{File.basename(mp3_path)}")
      @mutex.synchronize { @stats[:processed] += 1 }
      true
    end

    def ffmpeg_command(flac_path, mp3_path)
      exe = @use_windows_ffmpeg ? 'ffmpeg.exe' : 'ffmpeg'
      src = @use_windows_ffmpeg ? to_windows_path(flac_path) : flac_path
      dst = @use_windows_ffmpeg ? to_windows_path(mp3_path) : mp3_path
      [exe, '-y', '-i', src, '-codec:a', 'libmp3lame', '-qscale:a', '2',
       '-map_metadata', '0', '-id3v2_version', '3', dst]
    end

    def run_ffmpeg?(flac_path, mp3_path, logger)
      if system(*ffmpeg_command(flac_path, mp3_path), err: File::NULL)
        logger&.log("[OK] Converted: #{File.basename(flac_path)} -> #{File.basename(mp3_path)}")
        @mutex.synchronize { @stats[:processed] += 1 }
        true
      else
        logger&.log("[FAIL] ffmpeg error on: #{File.basename(flac_path)}")
        @mutex.synchronize { @stats[:failed] += 1 }
        false
      end
    end

    def detect_windows_ffmpeg
      return false unless windows_path?(@path)

      system('where.exe ffmpeg.exe > /dev/null 2>&1') == true
    rescue StandardError
      false
    end
  end

  # Dual-output logger: writes to both STDOUT and a timestamped log file.
  class DualLogger
    attr_reader :log_path

    def initialize(log_dir: Dir.pwd)
      timestamp = Time.now.strftime('%Y-%m-%d-%H%M%S')
      @log_path = File.join(log_dir, "flac-to-mp3-#{timestamp}.log")
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
      total = stats[:processed] + stats[:failed] + stats[:skipped]
      log_file_counts(stats, total, logger)
      logger.log("  Time elapsed    : #{format_duration(elapsed)}")
      logger.log("  Disk space saved: #{format_bytes(stats[:space_saved_bytes])}")
    end

    def log_file_counts(stats, total, logger)
      logger.log("  Files processed : #{stats[:processed]}")
      logger.log("  Files failed    : #{stats[:failed]}")
      logger.log("  Files skipped   : #{stats[:skipped]}")
      logger.log("  Total files     : #{total}")
      logger.log("  Dirs renamed    : #{stats[:dirs_renamed]}")
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
