#!/usr/bin/env bash
# Pull one frame at source resolution and crop into it, for when a detail on a
# contact sheet is too small to settle. Cells are ~500px wide — enough to
# identify a person, not always enough to place them.
#
#   zoom.sh <workdir> <time> [region] [out.jpg]
#
# region: left | right | top | bottom | tl | tr | bl | br | centre | full
#         or a raw ffmpeg crop expression (w:h:x:y)
# Multiple times may be given comma-separated; they are tiled into one sheet.
set -euo pipefail

WORK="${1:-}"; TIMES="${2:-}"; REGION="${3:-full}"; OUT="${4:-$WORK/zoom.jpg}"
[ -n "$WORK" ] && [ -n "$TIMES" ] || {
  echo "usage: zoom.sh <workdir> <time[,time...]> [region] [out.jpg]" >&2; exit 2; }
VIDEO="$WORK/video.mp4"
[ -f "$VIDEO" ] || { echo "no video at $VIDEO" >&2; exit 3; }

case "$REGION" in
  left)   CROP="iw*0.45:ih:0:0" ;;
  right)  CROP="iw*0.45:ih:iw*0.55:0" ;;
  top)    CROP="iw:ih*0.45:0:0" ;;
  bottom) CROP="iw:ih*0.45:0:ih*0.55" ;;
  tl)     CROP="iw*0.5:ih*0.5:0:0" ;;
  tr)     CROP="iw*0.5:ih*0.5:iw*0.5:0" ;;
  bl)     CROP="iw*0.5:ih*0.5:0:ih*0.5" ;;
  br)     CROP="iw*0.5:ih*0.5:iw*0.5:ih*0.5" ;;
  centre|center) CROP="iw*0.5:ih*0.5:iw*0.25:ih*0.25" ;;
  full)   CROP="iw:ih:0:0" ;;
  *)      CROP="$REGION" ;;   # raw w:h:x:y
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
i=0
IFS=',' read -ra TS <<< "$TIMES"
for t in "${TS[@]}"; do
  i=$((i+1))
  # No drawtext here: the point is maximum detail, and a burned-in label would
  # sit on top of whatever is being examined.
  ffmpeg -nostdin -y -loglevel error -ss "$t" -i "$VIDEO" -frames:v 1 \
    -vf "crop=${CROP},scale=780:-1" -q:v 2 "$TMP/$(printf 'z_%02d.jpg' "$i")"
done

if [ "$i" -eq 1 ]; then
  cp "$TMP/z_01.jpg" "$OUT"
else
  COLS=$(awk -v n="$i" 'BEGIN{c=int(sqrt(n)+0.999); if(c>3)c=3; print c}')
  ROWS=$(awk -v n="$i" -v c="$COLS" 'BEGIN{print int((n+c-1)/c)}')
  ffmpeg -nostdin -y -loglevel error -framerate 1 -i "$TMP/z_%02d.jpg" \
    -vf "tile=${COLS}x${ROWS}:margin=8:padding=6:color=white" -q:v 2 "$OUT"
fi
echo "$OUT"
