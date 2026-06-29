# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"

# Load the libraries under test
require_relative "../lib/flac_to_mp3"
require_relative "../lib/video_transcode"

module FlacToMp3
  # Helper to create a temporary directory populated with dummy FLAC files
  # for integration-style tests.
  module TestHelpers
    def setup_temp_dir(files = {})
      @tmpdir = Dir.mktmpdir("flac-to-mp3-test")
      files.each do |relative_path, content|
        full_path = File.join(@tmpdir, relative_path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, content || "dummy flac content")
      end
      @tmpdir
    end

    def teardown_temp_dir
      FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    end
  end
end

module VideoTranscode
  # Helper to create a temporary directory populated with dummy video files
  # for integration-style tests.
  module TestHelpers
    def setup_temp_dir(files = {})
      @tmpdir = Dir.mktmpdir("video-transcode-test")
      files.each do |relative_path, content|
        full_path = File.join(@tmpdir, relative_path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, content || "dummy video content")
      end
      @tmpdir
    end

    def teardown_temp_dir
      FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
    end
  end
end
