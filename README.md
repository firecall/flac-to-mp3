# Convert FLAC files to MP3

Ruby script that recursively converts FLAC audio files to MP3 using FFmpeg.

## Requirements

- Ruby 4.0+
- FFmpeg (with libmp3lame)

### Installing FFmpeg

**Linux / WSL:**
```bash
sudo apt install ffmpeg
```

**Windows (recommended — for WSL users targeting a Windows drive):**

Install via winget in PowerShell or Command Prompt:
```powershell
winget install Gyan.FFmpeg
```

Then open a new WSL terminal so the updated Windows PATH is inherited.

### FFmpeg selection under WSL

When the target path is on a Windows drive (`/mnt/c/`, `/mnt/d/`, etc.), the script automatically picks the faster option:

| Condition | FFmpeg used |
|-----------|-------------|
| `ffmpeg.exe` found on Windows PATH | `ffmpeg.exe` (Windows native) |
| Only Linux `ffmpeg` available | `ffmpeg` (Linux, via WSL) |

Using `ffmpeg.exe` is significantly faster for Windows paths because it reads and writes NTFS directly. The Linux binary has to cross the WSL filesystem boundary on every read and write, which is slow for large libraries.

The active FFmpeg is shown in the run header:
```
FFmpeg      : ffmpeg.exe (Windows native)
```
or
```
FFmpeg      : /usr/bin/ffmpeg
```

## Usage

```bash
# Using default path or FLAC_MUSIC_PATH env var
bin/flac-to-mp3

# Specify a custom path
bin/flac-to-mp3 --path "/path/to/music"

# Dry-run mode — preview only, no changes
bin/flac-to-mp3 --dry-run
bin/flac-to-mp3 -n --path /my/music

# Run 8 parallel ffmpeg workers (default: 4)
bin/flac-to-mp3 --jobs 8

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
- Renames directories to remove format tags and encoding noise (see below)
- Logs progress to both terminal and a timestamped log file
- Prints a summary with files processed, failures, time elapsed, and disk space saved

## Directory Renaming

After conversion, the script renames **all** directories whose names contain format tags or encoding noise — not just FLAC-tagged ones. It strips:

| Pattern | Example input | Result |
|---------|--------------|--------|
| Any bracket tag | `Artist - Album [FLAC]` | `Artist - Album` |
| Bracket tag with depth/rate | `Artist - Album [Flac 16-44]` | `Artist - Album` |
| Bracket tag with bit depth | `Artist - Album [24Bit-44.1kHz]` | `Artist - Album` |
| Bracket tag + uploader handle | `Artist - Album [FLAC]-Sc4r3cr0w` | `Artist - Album` |
| Source/format tag | `Artist - Album [EAC-FLAC]` | `Artist - Album` |
| Tagger/distributor tag | `Artist - Album [PMEDIA]` | `Artist - Album` |
| Ripper tag | `Artist - Album [Hunter]` | `Artist - Album` |
| Parenthesised FLAC | `Artist - Album (FLAC)` | `Artist - Album` |
| Bare "FLAC" substring | `My FLAC Collection` | `My Collection` |
| Bitrate (kbps) | `Artist - Album 320kbps` / `320_kbps` | `Artist - Album` |
| Parenthesised bitrate | `Artist - Album (320kbps)` | `Artist - Album` |
| Bit-depth/sample-rate pair | `Artist - Album flac 24-48` | `Artist - Album` |
| Trailing sample rate | `Artist - Album [FLAC] 88` | `Artist - Album` |
| Emoji (standalone or attached) | `Artist - Album ⭐️` / `Beats⭐` | `Artist - Album` |

Nested directories are renamed deepest-first so parent renames don't invalidate child paths. Directories that would collide with an existing name are skipped with a warning.

## Dry-Run Mode

`--dry-run` or `-n` shows exactly what would happen without converting, deleting, or renaming anything: which files would be converted and which directories would be renamed.

---

# Video Transcode

Ruby script that recursively converts video files to 720p H.264 MKV using Nvidia NVENC hardware encoding. Designed to save disk space while preserving visual and audio quality.

## Requirements

- Ruby 4.0+
- FFmpeg compiled with `h264_nvenc` encoder support
- Nvidia GPU with NVENC hardware encoding capability
- Nvidia GPU drivers installed

### NVIDIA Driver & NVENC Setup (Linux)

```bash
# Install Nvidia drivers (Ubuntu/Debian)
sudo apt install nvidia-driver-550

# Verify NVENC is detected
ffmpeg -hide_banner -encoders 2>&1 | grep h264_nvenc
```

If `h264_nvenc` is not shown, install an FFmpeg build that includes NVENC support:

```bash
# Linuxbrew / Homebrew
brew install ffmpeg

# Or from apt with non-free codecs
sudo apt install ffmpeg
```

## Usage

```bash
# Using default path or VIDEO_MEDIA_PATH env var
bin/video-transcode

# Specify a custom path
bin/video-transcode --path "/mnt/c/Users/alex/PLEX MEDIA"

# Dry-run mode — preview only, no changes
bin/video-transcode --dry-run
bin/video-transcode -n --path /my/media

# Adjust parallel workers (default: 1 — NVENC is GPU-limited)
bin/video-transcode --jobs 1

# Show help
bin/video-transcode --help
```

## Configuration

Set the `VIDEO_MEDIA_PATH` environment variable to avoid passing `--path` every time:

```bash
export VIDEO_MEDIA_PATH="/mnt/c/Users/alex/PLEX MEDIA"
bin/video-transcode
```

Or copy `.env.example` to `.env` — the script loads it automatically.

**Default fallback path:** `/mnt/c/Users/alex/PLEX MEDIA` (WSL path to Windows drive).

**Path resolution order:**
1. `--path` CLI argument
2. `VIDEO_MEDIA_PATH` environment variable
3. Hardcoded default

## What It Does

- Recursively finds video files: `.mkv`, `.mp4`, `.avi`, `.mov`, `.wmv`, `.m4v`, `.webm` (case-insensitive)
- Probes each file with `ffprobe` to check resolution — skips files already ≤ 720p
- Transcodes video to 720p H.264 using Nvidia NVENC with quality-focused settings
- Audio is **stream-copied** (no re-encoding) to preserve original quality
- Output is always `.mkv` container (all streams mapped)
- After transcoding, compares file sizes:
  - **Transcoded file smaller:** Deletes original, keeps transcoded file
  - **Transcoded file larger or equal:** Deletes transcoded file, keeps original
- Logs progress to both terminal and a timestamped log file
- Prints a summary with files processed, failed, skipped, kept, time elapsed, and disk space saved

## FFmpeg Encoding Settings

Quality is prioritized over speed. The FFmpeg command uses community best practices for NVENC:

```
ffmpeg -y -i INPUT \
  -c:v h264_nvenc \
  -preset p7 \           # Slowest/best quality NVENC preset
  -rc vbr_hq \           # High-quality variable bitrate mode
  -cq 18 \               # Constant quality 18 (visually lossless)
  -b:v 0 \               # No bitrate ceiling in CQ mode
  -maxrate 5000k \       # Cap peak bitrate at 5 Mbps
  -bufsize 10000k \      # 10 MB buffer for rate control
  -bf 4 \                # 4 B-frames for compression efficiency
  -profile:v high \      # High profile for best compression
  -pix_fmt yuv420p \     # Wide compatibility pixel format
  -vf "scale='min(1280,iw)':'min(720,ih)':force_original_aspect_ratio=decrease" \
  -c:a copy \            # Copy audio without re-encoding
  -map 0 \               # Include all streams
  OUTPUT.mkv
```

The scale filter ensures:
- Videos wider than 1280 or taller than 720 are resized down
- Aspect ratio is preserved
- Videos already ≤ 720p are **not** upscaled

## Dry-Run Mode

`--dry-run` or `-n` shows exactly what would happen without converting or deleting anything: which files would be transcoded, which would be skipped, and which would be kept.

## Why Default Jobs = 1

NVENC is a hardware encoder — running multiple simultaneous encodes on the same GPU causes all jobs to slow down dramatically and often produces worse total throughput than sequential encoding. The default of 1 worker is deliberate. Users with multiple GPUs can increase `--jobs` accordingly.

---

Built with [Claude Code](https://claude.ai/code).
