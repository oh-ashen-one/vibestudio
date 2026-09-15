#!/usr/bin/env bash
# Generates a deterministic Phase-1-style recording folder for Phase 2
# development while real screen recording is unavailable.
#
# Output (default Fixtures/sample-recording/, pass a path to override):
#   recording.mov        30s 1920x1080 60fps H.264 with moving spatial content
#   events.json          matches VibeStudio's EventLog schema exactly
#   recording-meta.json  display 960x540 points @ scale 2.0 -> 1920x1080 px,
#                        source rect = full display
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-Fixtures/sample-recording}"
mkdir -p "$OUT"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=60" \
  -t 30 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
  "$OUT/recording.mov"

# Webcam stand-in so camera layouts (bubble / webcam-full) can be developed.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=size=640x480:rate=30" \
  -t 30 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
  "$OUT/webcam.mov"

python3 "$(dirname "$0")/make_fixture_events.py" "$OUT"

echo "Fixture written to $OUT"
