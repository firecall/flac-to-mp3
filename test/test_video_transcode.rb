#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'test_helper'
require 'json'

class ConverterMkvPathTest < Minitest::Test
  def test_new_mkv_path_replaces_mkv_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.mkv')
  end

  def test_new_mkv_path_replaces_mp4_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.mp4')
  end

  def test_new_mkv_path_replaces_avi_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.avi')
  end

  def test_new_mkv_path_replaces_mov_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.mov')
  end

  def test_new_mkv_path_replaces_wmv_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.wmv')
  end

  def test_new_mkv_path_replaces_m4v_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.m4v')
  end

  def test_new_mkv_path_replaces_webm_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/movie.mkv', conv.new_mkv_path('/media/movie.webm')
  end

  def test_new_mkv_path_handles_uppercase_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/MOVIE.mkv', conv.new_mkv_path('/media/MOVIE.MP4')
  end

  def test_new_mkv_path_preserves_subdirectory
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal '/media/subdir/video.mkv', conv.new_mkv_path('/media/subdir/video.avi')
  end

  def test_new_mkv_path_does_not_change_non_video_extension
    conv = VideoTranscode::Converter.new(path: '/tmp')
    # Non-video extensions should be left alone (no replacement)
    assert_equal '/media/readme.txt', conv.new_mkv_path('/media/readme.txt')
  end
end

class ConverterFileFindTest < Minitest::Test
  include VideoTranscode::TestHelpers

  def test_find_video_files_finds_all_variants
    setup_temp_dir(
      'movie.mkv' => '',
      'show.mp4' => '',
      'clip.avi' => '',
      'video.mov' => '',
      'old.wmv' => '',
      'itunes.m4v' => '',
      'web.webm' => '',
      'not-a-video.txt' => '',
      'image.jpg' => '',
      'subdir/nested.mkv' => ''
    )

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    results = conv.find_video_files.sort

    assert_equal 8, results.length
    assert(results.any? { |f| f.end_with?('.mkv') })
    assert(results.any? { |f| f.end_with?('.mp4') })
    assert(results.any? { |f| f.end_with?('.webm') })
    assert(results.any? { |f| f.include?('subdir') })
    refute(results.any? { |f| f.end_with?('.txt') })
    refute(results.any? { |f| f.end_with?('.jpg') })
  ensure
    teardown_temp_dir
  end

  def test_find_video_files_returns_empty_for_no_videos
    setup_temp_dir('readme.txt' => '', 'cover.jpg' => '')

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    assert_equal [], conv.find_video_files
  ensure
    teardown_temp_dir
  end

  def test_find_video_files_case_insensitive
    setup_temp_dir(
      'Movie.MKV' => '',
      'Show.MP4' => '',
      'Clip.AVI' => ''
    )

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    results = conv.find_video_files.sort

    assert_equal 3, results.length
  ensure
    teardown_temp_dir
  end
end

class ConverterTranscodeLogicTest < Minitest::Test
  include VideoTranscode::TestHelpers

  def test_convert_file_dry_run_increments_processed
    setup_temp_dir('movie.mp4' => '')

    conv = VideoTranscode::Converter.new(path: @tmpdir, dry_run: true)
    # Override needs_transcode? using Ruby's define_method trick
    conv.define_singleton_method(:needs_transcode?) { |_| true }
    result = conv.convert_file?(File.join(@tmpdir, 'movie.mp4'))

    assert result
    assert_equal 1, conv.stats[:processed]
    assert_equal 0, conv.stats[:failed]
    refute File.exist?(File.join(@tmpdir, 'movie.mkv')),
           'dry-run should not create an MKV file'
  ensure
    teardown_temp_dir
  end

  def test_convert_file_skips_existing_mkv
    setup_temp_dir('movie.mp4' => '', 'movie.mkv' => 'existing mkv')

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    result = conv.convert_file?(File.join(@tmpdir, 'movie.mp4'))

    assert result
    assert_equal 1, conv.stats[:skipped]
    assert_equal 0, conv.stats[:processed]
  ensure
    teardown_temp_dir
  end

  def test_convert_file_skips_if_already_720p
    setup_temp_dir('720movie.mp4' => '')

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    conv.define_singleton_method(:needs_transcode?) { |_| false }
    result = conv.convert_file?(File.join(@tmpdir, '720movie.mp4'))

    assert result
    assert_equal 1, conv.stats[:skipped]
    assert_equal 0, conv.stats[:processed]
    refute File.exist?(File.join(@tmpdir, '720movie.mkv'))
  ensure
    teardown_temp_dir
  end
end

class ConverterSizeComparisonTest < Minitest::Test
  include VideoTranscode::TestHelpers

  def test_compare_and_replace_keeps_smaller_transcode
    setup_temp_dir('movie.mp4' => 'X' * 1000)

    source_path = File.join(@tmpdir, 'movie.mp4')
    mkv_path = File.join(@tmpdir, 'movie.mkv')
    File.write(mkv_path, 'Y' * 200)

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    conv.compare_and_replace(source_path, mkv_path, nil)

    refute File.exist?(source_path), 'original should be deleted'
    assert File.exist?(mkv_path), 'transcoded file should be kept'
    assert_equal 800, conv.stats[:space_saved_bytes]
    assert_equal 0, conv.stats[:kept]
  ensure
    teardown_temp_dir
  end

  def test_compare_and_replace_keeps_original_when_transcode_larger
    setup_temp_dir('movie.mp4' => 'X' * 200)

    source_path = File.join(@tmpdir, 'movie.mp4')
    mkv_path = File.join(@tmpdir, 'movie.mkv')
    File.write(mkv_path, 'Y' * 1000)

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    conv.compare_and_replace(source_path, mkv_path, nil)

    assert File.exist?(source_path), 'original should be kept'
    refute File.exist?(mkv_path), 'transcoded file should be deleted'
    assert_equal 1, conv.stats[:kept]
    assert_equal 0, conv.stats[:space_saved_bytes]
  ensure
    teardown_temp_dir
  end

  def test_compare_and_replace_keeps_original_when_equal_size
    setup_temp_dir('movie.mp4' => 'X' * 500)

    source_path = File.join(@tmpdir, 'movie.mp4')
    mkv_path = File.join(@tmpdir, 'movie.mkv')
    File.write(mkv_path, 'Y' * 500)

    conv = VideoTranscode::Converter.new(path: @tmpdir)
    conv.compare_and_replace(source_path, mkv_path, nil)

    assert File.exist?(source_path), 'original should be kept'
    refute File.exist?(mkv_path), 'transcoded file should be deleted'
    assert_equal 1, conv.stats[:kept]
    assert_equal 0, conv.stats[:space_saved_bytes]
  ensure
    teardown_temp_dir
  end
end

class ConverterNeedsTranscodeTest < Minitest::Test
  include VideoTranscode::TestHelpers

  def test_needs_transcode_returns_true_for_1080p
    conv = VideoTranscode::Converter.new(path: '/tmp')
    conv.define_singleton_method(:probe_video_height) { |_| 1080 }
    assert conv.needs_transcode?('/some/video.mp4')
  end

  def test_needs_transcode_returns_true_for_4k
    conv = VideoTranscode::Converter.new(path: '/tmp')
    conv.define_singleton_method(:probe_video_height) { |_| 2160 }
    assert conv.needs_transcode?('/some/video.mp4')
  end

  def test_needs_transcode_returns_false_for_720p
    conv = VideoTranscode::Converter.new(path: '/tmp')
    conv.define_singleton_method(:probe_video_height) { |_| 720 }
    refute conv.needs_transcode?('/some/video.mp4')
  end

  def test_needs_transcode_returns_false_for_480p
    conv = VideoTranscode::Converter.new(path: '/tmp')
    conv.define_singleton_method(:probe_video_height) { |_| 480 }
    refute conv.needs_transcode?('/some/video.mp4')
  end

  def test_needs_transcode_returns_true_when_probe_fails
    conv = VideoTranscode::Converter.new(path: '/tmp')
    conv.define_singleton_method(:probe_video_height) { |_| nil }
    assert conv.needs_transcode?('/some/video.mp4'),
           'should assume transcoding is needed when probe fails'
  end
end

class ConverterStatsTest < Minitest::Test
  def test_stats_initial_values
    conv = VideoTranscode::Converter.new(path: '/tmp')
    expected = { processed: 0, failed: 0, skipped: 0, kept: 0,
                 space_saved_bytes: 0 }
    assert_equal expected, conv.stats
  end

  def test_path_is_expanded
    conv = VideoTranscode::Converter.new(path: 'relative/path')
    assert_equal File.expand_path('relative/path'), conv.path
  end

  def test_log_error_increments_failed_stat
    conv = VideoTranscode::Converter.new(path: '/tmp')
    conv.log_error('something went wrong')
    assert_equal 1, conv.stats[:failed]
  end
end

class ConverterFfmpegCommandTest < Minitest::Test
  def test_ffmpeg_command_includes_nvenc_encoder
    conv = VideoTranscode::Converter.new(path: '/tmp')
    cmd = conv.send(:ffmpeg_command, '/media/movie.mp4', '/media/movie.mkv')

    assert_includes cmd, 'h264_nvenc'
    assert_includes cmd, 'p7'
    assert_includes cmd, 'vbr_hq'
    assert_includes cmd, 'copy' # audio copy
    # Check that source and dest paths are in the command array
    assert_includes cmd, '/media/movie.mp4'
    assert_includes cmd, '/media/movie.mkv'
  end

  def test_ffmpeg_command_includes_scale_filter
    conv = VideoTranscode::Converter.new(path: '/tmp')
    cmd = conv.send(:ffmpeg_command, '/media/video.avi', '/media/video.mkv')

    vf_arg = cmd[cmd.index('-vf') + 1]
    assert_includes vf_arg, 'scale'
    assert_includes vf_arg, '1280'
    assert_includes vf_arg, '720'
  end

  def test_ffmpeg_command_includes_map_all_streams
    conv = VideoTranscode::Converter.new(path: '/tmp')
    cmd = conv.send(:ffmpeg_command, '/media/video.mkv', '/media/video.mkv')

    assert_includes cmd, '-map'
    assert_includes cmd, '0'
  end
end

class ConverterWindowsPathTest < Minitest::Test
  def test_windows_path_detects_mnt_c
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert conv.windows_path?('/mnt/c/Users/media/movie.mp4')
  end

  def test_windows_path_detects_other_drive
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert conv.windows_path?('/mnt/d/media')
  end

  def test_windows_path_rejects_linux_path
    conv = VideoTranscode::Converter.new(path: '/tmp')
    refute conv.windows_path?('/home/user/media/movie.mp4')
  end

  def test_to_windows_path_c_drive
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal 'C:\Users\media\movie.mp4', conv.to_windows_path('/mnt/c/Users/media/movie.mp4')
  end

  def test_to_windows_path_uppercase_drive_letter
    conv = VideoTranscode::Converter.new(path: '/tmp')
    assert_equal 'D:\my media\movie.mp4', conv.to_windows_path('/mnt/d/my media/movie.mp4')
  end
end

class DualLoggerTest < Minitest::Test
  include VideoTranscode::TestHelpers

  def test_creates_log_file
    setup_temp_dir({})
    logger = VideoTranscode::DualLogger.new(log_dir: @tmpdir)

    assert File.exist?(logger.log_path)
    assert_match(/video-transcode-\d{4}-\d{2}-\d{2}-\d{6}\.log/, logger.log_path)
  ensure
    logger&.close
    teardown_temp_dir
  end

  def test_log_writes_to_file
    setup_temp_dir({})
    logger = VideoTranscode::DualLogger.new(log_dir: @tmpdir)

    logger.log('Test message')
    logger.close

    content = File.read(logger.log_path)
    assert_includes content, 'Test message'
  ensure
    teardown_temp_dir
  end

  def test_log_summary_output
    setup_temp_dir({})
    logger = VideoTranscode::DualLogger.new(log_dir: @tmpdir)

    stats = { processed: 3, failed: 1, skipped: 2, kept: 1,
              space_saved_bytes: 1_500_000 }
    logger.log_summary(stats: stats, elapsed: 125)

    logger.close
    content = File.read(logger.log_path)

    assert_includes content, 'Files processed : 3'
    assert_includes content, 'Files failed    : 1'
    assert_includes content, 'Files skipped   : 2'
    assert_includes content, 'Originals kept  : 1'
    assert_includes content, 'Time elapsed    : 2m 05s'
    assert_includes content, '1.43 MB'
  ensure
    teardown_temp_dir
  end

  def test_log_summary_with_hours
    setup_temp_dir({})
    logger = VideoTranscode::DualLogger.new(log_dir: @tmpdir)

    stats = { processed: 0, failed: 0, skipped: 0, kept: 0,
              space_saved_bytes: 0 }
    logger.log_summary(stats: stats, elapsed: 3723) # 1h 02m 03s

    logger.close
    content = File.read(logger.log_path)

    assert_includes content, '1h 02m 03s'
  ensure
    teardown_temp_dir
  end
end
