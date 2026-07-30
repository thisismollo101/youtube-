#!/usr/bin/env bash
# Extract one frame with its shot number and true timestamp burned in.
# Called in parallel by prepare.sh. Args: <workdir> <tab-separated: time label out>
set -euo pipefail
WORK="$1"
IFS=$'\t' read -r T LABEL OUT <<< "$2"

# -ss before -i is an input seek: fast, and accurate enough at frame level for
# stills. The burn happens at source resolution so the text survives the
# downscale that tiling applies later.
ffmpeg -nostdin -y -loglevel error -ss "$T" -i "$WORK/video.mp4" -frames:v 1 \
  -vf "drawtext=fontfile=${WV_FONT}:text='${LABEL}':x=${WV_PAD}:y=${WV_PAD}:fontsize=${WV_FS}:fontcolor=white:box=1:boxcolor=black@0.75:boxborderw=${WV_BB}" \
  -q:v 3 "$OUT" 2>/dev/null || {
    # Seeking past the last keyframe near EOF can come back empty; retry with an
    # accurate output seek before giving up on the frame.
    ffmpeg -nostdin -y -loglevel error -i "$WORK/video.mp4" -ss "$T" -frames:v 1 \
      -vf "drawtext=fontfile=${WV_FONT}:text='${LABEL}':x=${WV_PAD}:y=${WV_PAD}:fontsize=${WV_FS}:fontcolor=white:box=1:boxcolor=black@0.75:boxborderw=${WV_BB}" \
      -q:v 3 "$OUT" 2>/dev/null || true
  }
