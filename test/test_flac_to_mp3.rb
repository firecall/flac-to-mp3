# frozen_string_literal: true

require_relative "test_helper"

class ConverterTest < Minitest::Test
  include FlacToMp3::TestHelpers

  # ── new_mp3_path ──────────────────────────────────────────────────────

  def test_new_mp3_path_replaces_extension
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/song.flac")
    assert_equal "/music/song.mp3", result
  end

  def test_new_mp3_path_handles_uppercase_extension
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/SONG.FLAC")
    assert_equal "/music/SONG.mp3", result
  end

  def test_new_mp3_path_removes_flac_from_filename
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/01 Track FLAC.flac")
    assert_equal "/music/01 Track.mp3", result
  end

  def test_new_mp3_path_removes_flac_dash_separated
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/album-FLAC-cover.flac")
    assert_equal "/music/album-cover.mp3", result
  end

  def test_new_mp3_path_removes_flac_underscore_separated
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/track_FLAC_version.flac")
    assert_equal "/music/track_version.mp3", result
  end

  def test_new_mp3_path_preserves_non_flac_dashes
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/02 - Another One.flac")
    assert_equal "/music/02 - Another One.mp3", result
  end

  def test_new_mp3_path_only_flac_becomes_unknown
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/FLAC.flac")
    assert_equal "/music/unknown.mp3", result
  end

  def test_new_mp3_path_lowercase_flac_only
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/flac.flac")
    assert_equal "/music/unknown.mp3", result
  end

  def test_new_mp3_path_preserves_subdirectory
    conv = FlacToMp3::Converter.new(path: "/tmp")
    result = conv.new_mp3_path("/music/subdir/track.flac")
    assert_equal "/music/subdir/track.mp3", result
  end

  # ── find_flac_files ───────────────────────────────────────────────────

  def test_find_flac_files_finds_all_variants
    setup_temp_dir(
      "song.flac" => "",
      "SONG.FLAC" => "",
      "track.Flac" => "",
      "not-audio.txt" => "",
      "subdir/nested.flac" => ""
    )

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    results = conv.find_flac_files.sort

    assert_equal 4, results.length
    assert results.all? { |f| f.end_with?(".flac", ".FLAC", ".Flac") }
    assert results.any? { |f| f.include?("subdir") }
  ensure
    teardown_temp_dir
  end

  def test_find_flac_files_returns_empty_for_no_flacs
    setup_temp_dir("readme.txt" => "", "cover.jpg" => "")

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    results = conv.find_flac_files

    assert_equal [], results
  ensure
    teardown_temp_dir
  end

  # ── convert_file (dry-run) ────────────────────────────────────────────

  def test_convert_file_dry_run_increments_processed
    setup_temp_dir("track.flac" => "")

    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: true)
    result = conv.convert_file(File.join(@tmpdir, "track.flac"))

    assert result
    assert_equal 1, conv.stats[:processed]
    assert_equal 0, conv.stats[:failed]
    refute File.exist?(File.join(@tmpdir, "track.mp3")),
           "dry-run should not create an MP3 file"
  ensure
    teardown_temp_dir
  end

  def test_convert_file_skips_existing_mp3
    setup_temp_dir("track.flac" => "", "track.mp3" => "existing mp3")

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    result = conv.convert_file(File.join(@tmpdir, "track.flac"))

    assert result
    assert_equal 1, conv.stats[:skipped]
    assert_equal 0, conv.stats[:processed]
  ensure
    teardown_temp_dir
  end

  # ── remove_original ───────────────────────────────────────────────────

  def test_remove_original_deletes_file_in_live_mode
    setup_temp_dir("track.flac" => "dummy")

    flac_path = File.join(@tmpdir, "track.flac")
    assert File.exist?(flac_path)

    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: false)
    conv.remove_original(flac_path)

    refute File.exist?(flac_path)
  ensure
    teardown_temp_dir
  end

  def test_remove_original_does_not_delete_in_dry_run
    setup_temp_dir("track.flac" => "dummy")

    flac_path = File.join(@tmpdir, "track.flac")
    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: true)
    conv.remove_original(flac_path)

    assert File.exist?(flac_path), "dry-run should not delete the original file"
  ensure
    teardown_temp_dir
  end

  # ── record_space ──────────────────────────────────────────────────────

  def test_record_space_calculates_savings
    setup_temp_dir("track.flac" => "X" * 1000)

    flac_path = File.join(@tmpdir, "track.flac")
    conv = FlacToMp3::Converter.new(path: @tmpdir)

    # Create a smaller mp3 to simulate post-conversion state
    mp3_path = conv.new_mp3_path(flac_path)
    File.write(mp3_path, "Y" * 200)

    saved = conv.record_space(flac_path)

    assert_equal 800, saved
    assert_equal 800, conv.stats[:space_saved_bytes]
  ensure
    teardown_temp_dir
  end

  def test_record_space_no_mp3_yet
    setup_temp_dir("track.flac" => "X" * 500)

    flac_path = File.join(@tmpdir, "track.flac")
    conv = FlacToMp3::Converter.new(path: @tmpdir)

    saved = conv.record_space(flac_path)

    assert_equal 500, saved
  ensure
    teardown_temp_dir
  end

  # ── stats tracking ────────────────────────────────────────────────────

  def test_stats_initial_values
    conv = FlacToMp3::Converter.new(path: "/tmp")
    assert_equal({ processed: 0, failed: 0, skipped: 0, space_saved_bytes: 0 }, conv.stats)
  end

  def test_path_is_expanded
    conv = FlacToMp3::Converter.new(path: "relative/path")
    assert_equal File.expand_path("relative/path"), conv.path
  end
end

class DualLoggerTest < Minitest::Test
  include FlacToMp3::TestHelpers

  def test_creates_log_file
    setup_temp_dir({})
    logger = FlacToMp3::DualLogger.new(log_dir: @tmpdir)

    assert File.exist?(logger.log_path)
    assert_match(/flac-to-mp3-\d{4}-\d{2}-\d{2}-\d{6}\.log/, logger.log_path)
  ensure
    logger&.close
    teardown_temp_dir
  end

  def test_log_writes_to_file
    setup_temp_dir({})
    logger = FlacToMp3::DualLogger.new(log_dir: @tmpdir)

    logger.log("Test message")
    logger.close

    content = File.read(logger.log_path)
    assert_includes content, "Test message"
  ensure
    teardown_temp_dir
  end

  def test_log_summary_output
    setup_temp_dir({})
    logger = FlacToMp3::DualLogger.new(log_dir: @tmpdir)

    stats = { processed: 3, failed: 1, skipped: 2, space_saved_bytes: 1_500_000 }
    logger.log_summary(stats: stats, elapsed: 125)

    logger.close
    content = File.read(logger.log_path)

    assert_includes content, "Files processed : 3"
    assert_includes content, "Files failed    : 1"
    assert_includes content, "Files skipped   : 2"
    assert_includes content, "Time elapsed    : 2m 05s"
    assert_includes content, "1.43 MB"
  ensure
    teardown_temp_dir
  end

  def test_log_summary_with_hours
    setup_temp_dir({})
    logger = FlacToMp3::DualLogger.new(log_dir: @tmpdir)

    stats = { processed: 0, failed: 0, skipped: 0, space_saved_bytes: 0 }
    logger.log_summary(stats: stats, elapsed: 3723) # 1h 02m 03s

    logger.close
    content = File.read(logger.log_path)

    assert_includes content, "1h 02m 03s"
  ensure
    teardown_temp_dir
  end
end
