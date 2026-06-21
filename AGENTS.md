# FLAC-to-MP3 — Agent Instructions

A Ruby script that recursively converts FLAC audio files to MP3 using FFmpeg.

## Build & Test

```bash
# Install dependencies
bundle install

# Run tests
rake test
# or: ruby -Ilib -Itest test/test_flac_to_mp3.rb
```

## Architecture

Single-file library at `lib/flac_to_mp3.rb` with two classes under `module FlacToMp3`:

- **`Converter`** — finds `.flac` files, derives MP3 paths (stripping "FLAC" from filenames), runs `ffmpeg`, removes originals, tracks stats. Supports `dry_run` mode.
- **`DualLogger`** — writes to both STDOUT and a timestamped log file.

Entry point: `bin/flac-to-mp3` — CLI with `--path`, `--dry-run`/`-n`, `--help`.

No runtime gem dependencies — only Ruby stdlib + the `ffmpeg` system binary.

## System Prerequisites

- `ffmpeg` (with libmp3lame) — required at runtime
- `watchman` — required by Ruby LSP for file watching (`sudo apt install watchman`)

## Conventions

- `# frozen_string_literal: true` on all Ruby files
- Minitest for testing; test helper at `test/test_helper.rb` provides `FlacToMp3::TestHelpers` with `setup_temp_dir`/`teardown_temp_dir` (always pair with `ensure`)
- Keyword arguments for initializers; logger passed via `logger:` keyword
- Ruby version: see `.ruby-version` (rbenv managed)

## Environment Pitfall

Ruby must be compiled against Homebrew's OpenSSL (not the system libssl), since the Homebrew version is 3.6.x and the system packages are only 3.0.x. If `bundle install` fails with "Could not load OpenSSL", reinstall Ruby with:

```bash
RUBY_CONFIGURE_OPTS="--with-openssl-dir=/home/linuxbrew/.linuxbrew" rbenv install $(cat .ruby-version) --force
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/flac_to_mp3.rb` | Core library (Converter + DualLogger) |
| `bin/flac-to-mp3` | CLI entry point |
| `test/test_flac_to_mp3.rb` | All tests |
| `test/test_helper.rb` | Test setup + TestHelpers module |
| `Rakefile` | `rake test` definition |
| `Gemfile` | Dev dependencies only (minitest, rubocop) |

See `README.md` for usage documentation.
