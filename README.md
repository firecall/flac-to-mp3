# Convert FLAC files to MP3

Ruby script that recursively converts FLAC audio files to MP3 using FFmpeg.

## Requirements

- Ruby 4.0+
- FFmpeg (with libmp3lame)

## Usage

```bash
# Using default path or FLAC_MUSIC_PATH env var
bin/flac-to-mp3

# Specify a custom path
bin/flac-to-mp3 --path "/path/to/music"

# Dry-run mode — preview only, no changes
bin/flac-to-mp3 --dry-run
bin/flac-to-mp3 -n --path /my/music

# Show help
bin/flac-to-mp3 --help
```

## Configuration

Set the `FLAC_MUSIC_PATH` environment variable to avoid passing `--path` every time:

```bash
export FLAC_MUSIC_PATH="/path/to/music"
bin/flac-to-mp3
```

Or copy `.env.example` to `.env` — the script loads it automatically.

No default path is set — either `--path` or `FLAC_MUSIC_PATH` must be provided.

## What It Does

- Recursively finds all `.flac` files (case-insensitive)
- Converts each to `.mp3` via FFmpeg (VBR ~190kbps, preserves metadata)
- Strips "FLAC" / "flac" substrings from filenames
- Removes original FLAC files after successful conversion
- Skips files where the MP3 already exists
- Logs progress to both terminal and a timestamped log file
- Prints a summary with files processed, failures, time elapsed, and disk space saved

## Dry-Run Mode

`--dry-run` or `-n` shows exactly what would happen without converting or deleting anything: which files would be converted, renamed, and removed.
