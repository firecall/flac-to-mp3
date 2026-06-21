# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run all tests
bundle exec rake          # or: bundle exec rake test

# Run a single test file
bundle exec ruby -Itest test/test_flac_to_mp3.rb

# Run a single test by name
bundle exec ruby -Itest test/test_flac_to_mp3.rb -n test_new_mp3_path_replaces_extension

# Lint
bundle exec rubocop

# Run the converter (requires ffmpeg on PATH)
bin/flac-to-mp3 --dry-run --path /path/to/music
```

## Architecture

This is a single-purpose Ruby CLI with no web framework and no runtime gem dependencies — only Ruby stdlib and the external `ffmpeg` binary.

**`lib/flac_to_mp3.rb`** — all logic lives here, two classes:
- `FlacToMp3::Converter` — finds FLAC files, derives MP3 output paths (stripping "FLAC" substrings from filenames), shells out to `ffmpeg`, deletes originals, and tracks stats. `dry_run: true` skips all filesystem writes.
- `FlacToMp3::DualLogger` — writes timestamped log lines to both STDOUT and a `.log` file in the current directory.

**`bin/flac-to-mp3`** — CLI entry point. Uses `optparse` to parse `--path` / `--dry-run` / `--help`, resolves the target path from CLI arg → `FLAC_MUSIC_PATH` env var → hardcoded default, then calls `Converter` and `DualLogger`.

**`test/`** — Minitest unit tests. `FlacToMp3::TestHelpers` (in `test_helper.rb`) provides `setup_temp_dir` / `teardown_temp_dir` to create real temporary directories with dummy files. Tests do not mock the filesystem; they use actual temp dirs and assert on real file existence/content.

## Environment pitfall

If `bundle install` fails with "Could not load OpenSSL", Ruby needs to be compiled against Homebrew's OpenSSL (not the system libssl):

```bash
RUBY_CONFIGURE_OPTS="--with-openssl-dir=/home/linuxbrew/.linuxbrew" rbenv install $(cat .ruby-version) --force
```

## Key behaviours to preserve

- `new_mp3_path` collapses separator artifacts (`--`, `__`, double spaces, leading separators) only when they result from removing the "FLAC" substring — it must not touch separators that were already in the original filename (e.g. `"02 - Another One.flac"` → `"02 - Another One.mp3"`).
- `convert_file` silently skips (increments `:skipped`) if the `.mp3` output already exists.
- `record_space` must be called *before* `remove_original`, since it reads the FLAC file size.
