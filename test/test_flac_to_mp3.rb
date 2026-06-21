# frozen_string_literal: true

require_relative 'test_helper'

class ConverterMp3PathTest < Minitest::Test
  def test_new_mp3_path_replaces_extension
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/song.mp3', conv.new_mp3_path('/music/song.flac')
  end

  def test_new_mp3_path_handles_uppercase_extension
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/SONG.mp3', conv.new_mp3_path('/music/SONG.FLAC')
  end

  def test_new_mp3_path_removes_flac_from_filename
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/01 Track.mp3', conv.new_mp3_path('/music/01 Track FLAC.flac')
  end

  def test_new_mp3_path_removes_flac_dash_separated
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/album-cover.mp3', conv.new_mp3_path('/music/album-FLAC-cover.flac')
  end

  def test_new_mp3_path_removes_flac_underscore_separated
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/track_version.mp3', conv.new_mp3_path('/music/track_FLAC_version.flac')
  end

  def test_new_mp3_path_preserves_non_flac_dashes
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/02 - Another One.mp3', conv.new_mp3_path('/music/02 - Another One.flac')
  end

  def test_new_mp3_path_only_flac_becomes_unknown
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/unknown.mp3', conv.new_mp3_path('/music/FLAC.flac')
  end

  def test_new_mp3_path_lowercase_flac_only
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/unknown.mp3', conv.new_mp3_path('/music/flac.flac')
  end

  def test_new_mp3_path_preserves_subdirectory
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/subdir/track.mp3', conv.new_mp3_path('/music/subdir/track.flac')
  end
end

class ConverterTest < Minitest::Test
  include FlacToMp3::TestHelpers

  def test_find_flac_files_finds_all_variants
    setup_temp_dir(
      'song.flac' => '',
      'SONG.FLAC' => '',
      'track.Flac' => '',
      'not-audio.txt' => '',
      'subdir/nested.flac' => ''
    )

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    results = conv.find_flac_files.sort

    assert_equal 4, results.length
    assert(results.all? { |f| f.end_with?('.flac', '.FLAC', '.Flac') })
    assert(results.any? { |f| f.include?('subdir') })
  ensure
    teardown_temp_dir
  end

  def test_find_flac_files_returns_empty_for_no_flacs
    setup_temp_dir('readme.txt' => '', 'cover.jpg' => '')

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    assert_equal [], conv.find_flac_files
  ensure
    teardown_temp_dir
  end

  def test_convert_file_dry_run_increments_processed
    setup_temp_dir('track.flac' => '')

    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: true)
    result = conv.convert_file?(File.join(@tmpdir, 'track.flac'))

    assert result
    assert_equal 1, conv.stats[:processed]
    assert_equal 0, conv.stats[:failed]
    refute File.exist?(File.join(@tmpdir, 'track.mp3')),
           'dry-run should not create an MP3 file'
  ensure
    teardown_temp_dir
  end

  def test_convert_file_skips_existing_mp3
    setup_temp_dir('track.flac' => '', 'track.mp3' => 'existing mp3')

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    result = conv.convert_file?(File.join(@tmpdir, 'track.flac'))

    assert result
    assert_equal 1, conv.stats[:skipped]
    assert_equal 0, conv.stats[:processed]
  ensure
    teardown_temp_dir
  end

  def test_remove_original_deletes_file_in_live_mode
    setup_temp_dir('track.flac' => 'dummy')

    flac_path = File.join(@tmpdir, 'track.flac')
    assert File.exist?(flac_path)

    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: false)
    conv.remove_original(flac_path)

    refute File.exist?(flac_path)
  ensure
    teardown_temp_dir
  end

  def test_remove_original_does_not_delete_in_dry_run
    setup_temp_dir('track.flac' => 'dummy')

    flac_path = File.join(@tmpdir, 'track.flac')
    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: true)
    conv.remove_original(flac_path)

    assert File.exist?(flac_path), 'dry-run should not delete the original file'
  ensure
    teardown_temp_dir
  end

  def test_record_space_calculates_savings
    setup_temp_dir('track.flac' => 'X' * 1000)

    flac_path = File.join(@tmpdir, 'track.flac')
    conv = FlacToMp3::Converter.new(path: @tmpdir)

    # Create a smaller mp3 to simulate post-conversion state
    mp3_path = conv.new_mp3_path(flac_path)
    File.write(mp3_path, 'Y' * 200)

    saved = conv.record_space(flac_path)

    assert_equal 800, saved
    assert_equal 800, conv.stats[:space_saved_bytes]
  ensure
    teardown_temp_dir
  end

  def test_record_space_no_mp3_yet
    setup_temp_dir('track.flac' => 'X' * 500)

    flac_path = File.join(@tmpdir, 'track.flac')
    conv = FlacToMp3::Converter.new(path: @tmpdir)

    assert_equal 500, conv.record_space(flac_path)
  ensure
    teardown_temp_dir
  end

  def test_stats_initial_values
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal({ processed: 0, failed: 0, skipped: 0, space_saved_bytes: 0, dirs_renamed: 0 }, conv.stats)
  end

  def test_path_is_expanded
    conv = FlacToMp3::Converter.new(path: 'relative/path')
    assert_equal File.expand_path('relative/path'), conv.path
  end
end

class ConverterDirRenameTest < Minitest::Test
  include FlacToMp3::TestHelpers

  def test_new_dir_path_removes_bracket_flac_with_bitrate
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [Flac 16-44]')
  end

  def test_new_dir_path_removes_bracket_flac
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [FLAC]')
  end

  def test_new_dir_path_removes_bare_flac
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/My Collection', conv.new_dir_path('/music/My FLAC Collection')
  end

  def test_new_dir_path_preserves_dirs_without_flac
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Normal Album', conv.new_dir_path('/music/Artist - Normal Album')
  end

  def test_new_dir_path_removes_any_bracket_tag
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [PMEDIA]')
  end

  def test_new_dir_path_removes_bracket_tag_and_emoji
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [PMEDIA] ⭐️')
  end

  def test_new_dir_path_removes_word_plus_emoji
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album Beats⭐')
  end

  def test_new_dir_path_removes_bitrate_kbps
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album 320kbps')
  end

  def test_new_dir_path_removes_bitrate_underscore_kbps
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album 320_kbps')
  end

  def test_new_dir_path_removes_parenthesised_bitrate
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album (320kbps)')
  end

  def test_new_dir_path_removes_bracket_bit_depth_sample_rate
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [24Bit-44.1kHz]')
  end

  def test_new_dir_path_cleans_non_flac_bracket_tag
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [Hunter]')
  end

  def test_new_dir_path_cleans_compound_tag_string
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [24Bit-44.1kHz] FLAC [PMEDIA] ⭐️')
  end

  def test_new_dir_path_removes_uploader_handle_after_bracket
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [FLAC]-Sc4r3cr0w')
  end

  def test_new_dir_path_removes_sample_rate_pair
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album flac 24-48')
  end

  def test_new_dir_path_removes_trailing_sample_rate_number
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album [FLAC] 88')
  end

  def test_new_dir_path_removes_parenthesised_flac
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal '/music/Artist - Album', conv.new_dir_path('/music/Artist - Album (flac)')
  end

  def test_rename_directories_renames_matching_dirs
    setup_temp_dir(
      'Artist - Album [Flac 16-44]/track.mp3' => '',
      'Artist2 - Album [FLAC]/track.mp3' => '',
      'Normal Album/track.mp3' => ''
    )

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    conv.rename_directories

    refute Dir.exist?(File.join(@tmpdir, 'Artist - Album [Flac 16-44]'))
    assert Dir.exist?(File.join(@tmpdir, 'Artist - Album'))
    refute Dir.exist?(File.join(@tmpdir, 'Artist2 - Album [FLAC]'))
    assert Dir.exist?(File.join(@tmpdir, 'Artist2 - Album'))
    assert Dir.exist?(File.join(@tmpdir, 'Normal Album'))
  ensure
    teardown_temp_dir
  end

  def test_rename_directories_cleans_non_flac_dirs
    setup_temp_dir('Artist - Album [Hunter]/track.mp3' => '')

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    conv.rename_directories

    refute Dir.exist?(File.join(@tmpdir, 'Artist - Album [Hunter]'))
    assert Dir.exist?(File.join(@tmpdir, 'Artist - Album'))
  ensure
    teardown_temp_dir
  end

  def test_rename_directories_dry_run_does_not_rename
    setup_temp_dir('Artist - Album [FLAC]/track.mp3' => '')

    conv = FlacToMp3::Converter.new(path: @tmpdir, dry_run: true)
    conv.rename_directories

    assert Dir.exist?(File.join(@tmpdir, 'Artist - Album [FLAC]')),
           'dry-run should not rename the directory'
  ensure
    teardown_temp_dir
  end

  def test_rename_directories_increments_stats
    setup_temp_dir(
      'Artist - Album [FLAC]/track.mp3' => '',
      'Another [Flac 24-96]/track.mp3' => ''
    )

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    conv.rename_directories

    assert_equal 2, conv.stats[:dirs_renamed]
  ensure
    teardown_temp_dir
  end

  def test_rename_directories_handles_nested_dirs
    setup_temp_dir('Artist [FLAC]/Album [Flac 16-44]/track.mp3' => '')

    conv = FlacToMp3::Converter.new(path: @tmpdir)
    conv.rename_directories

    assert Dir.exist?(File.join(@tmpdir, 'Artist', 'Album'))
    refute Dir.exist?(File.join(@tmpdir, 'Artist [FLAC]'))
  ensure
    teardown_temp_dir
  end
end

class ConverterWindowsPathTest < Minitest::Test
  def test_windows_path_detects_mnt_c
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert conv.windows_path?('/mnt/c/Users/music/song.flac')
  end

  def test_windows_path_detects_other_drive
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert conv.windows_path?('/mnt/d/music')
  end

  def test_windows_path_rejects_linux_path
    conv = FlacToMp3::Converter.new(path: '/tmp')
    refute conv.windows_path?('/home/user/music/song.flac')
  end

  def test_to_windows_path_c_drive
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal 'C:\Users\music\song.flac', conv.to_windows_path('/mnt/c/Users/music/song.flac')
  end

  def test_to_windows_path_uppercase_drive_letter
    conv = FlacToMp3::Converter.new(path: '/tmp')
    assert_equal 'D:\my music\song.flac', conv.to_windows_path('/mnt/d/my music/song.flac')
  end

  def test_log_error_increments_failed_stat
    conv = FlacToMp3::Converter.new(path: '/tmp')
    conv.log_error('something went wrong')
    assert_equal 1, conv.stats[:failed]
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

    logger.log('Test message')
    logger.close

    content = File.read(logger.log_path)
    assert_includes content, 'Test message'
  ensure
    teardown_temp_dir
  end

  def test_log_summary_output
    setup_temp_dir({})
    logger = FlacToMp3::DualLogger.new(log_dir: @tmpdir)

    stats = { processed: 3, failed: 1, skipped: 2, space_saved_bytes: 1_500_000, dirs_renamed: 0 }
    logger.log_summary(stats: stats, elapsed: 125)

    logger.close
    content = File.read(logger.log_path)

    assert_includes content, 'Files processed : 3'
    assert_includes content, 'Files failed    : 1'
    assert_includes content, 'Files skipped   : 2'
    assert_includes content, 'Time elapsed    : 2m 05s'
    assert_includes content, '1.43 MB'
  ensure
    teardown_temp_dir
  end

  def test_log_summary_with_hours
    setup_temp_dir({})
    logger = FlacToMp3::DualLogger.new(log_dir: @tmpdir)

    stats = { processed: 0, failed: 0, skipped: 0, space_saved_bytes: 0, dirs_renamed: 0 }
    logger.log_summary(stats: stats, elapsed: 3723) # 1h 02m 03s

    logger.close
    content = File.read(logger.log_path)

    assert_includes content, '1h 02m 03s'
  ensure
    teardown_temp_dir
  end
end
