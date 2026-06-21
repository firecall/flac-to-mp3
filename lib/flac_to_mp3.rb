#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'time'

module FlacToMp3
  # Handles the conversion logic: finding FLAC files, running ffmpeg,
  # renaming, removing originals, and computing disk savings.
  class Converter
    attr_reader :path, :dry_run, :stats

    def initialize(path:, dry_run: false)
      @path = File.expand_path(path)
      @dry_run = dry_run
      @stats = { processed: 0, failed: 0, skipped: 0, space_saved_bytes: 0 }
    end

    # Recursively find all .flac files (case-insensitive) under :path
    def find_flac_files
      Dir.glob("#{@path}/**/*").select { |f| File.file?(f) && f.end_with?('.flac', '.FLAC', '.Flac') }
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

    # Calculate disk space difference for a single file pair
    def record_space(flac_path)
      flac_size = File.size(flac_path)
      mp3_path = new_mp3_path(flac_path)
      mp3_size = File.exist?(mp3_path) ? File.size(mp3_path) : 0
      saved = flac_size - mp3_size
      @stats[:space_saved_bytes] += saved if saved.positive?
      saved
    end

    private

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
      @stats[:skipped] += 1
      true
    end

    def dry_run_convert?(flac_path, mp3_path, logger)
      logger&.log("[DRY-RUN] Would convert: #{File.basename(flac_path)} -> #{File.basename(mp3_path)}")
      @stats[:processed] += 1
      true
    end

    def ffmpeg_command(flac_path, mp3_path)
      ['ffmpeg', '-y', '-i', flac_path, '-codec:a', 'libmp3lame', '-qscale:a', '2',
       '-map_metadata', '0', '-id3v2_version', '3', mp3_path]
    end

    def run_ffmpeg?(flac_path, mp3_path, logger)
      if system(*ffmpeg_command(flac_path, mp3_path), err: File::NULL)
        logger&.log("[OK] Converted: #{File.basename(flac_path)} -> #{File.basename(mp3_path)}")
        @stats[:processed] += 1
        true
      else
        logger&.log("[FAIL] ffmpeg error on: #{File.basename(flac_path)}")
        @stats[:failed] += 1
        false
      end
    end
  end

  # Dual-output logger: writes to both STDOUT and a timestamped log file.
  class DualLogger
    attr_reader :log_path

    def initialize(log_dir: Dir.pwd)
      timestamp = Time.now.strftime('%Y-%m-%d-%H%M%S')
      @log_path = File.join(log_dir, "flac-to-mp3-#{timestamp}.log")
      @file = File.open(@log_path, 'a')
    end

    def log(message)
      line = "[#{Time.now.strftime('%H:%M:%S')}] #{message}"
      puts line
      @file.puts(line)
      @file.flush
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
