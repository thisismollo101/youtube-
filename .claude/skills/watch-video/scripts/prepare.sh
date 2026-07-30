#!/usr/bin/env bash
# watch-video: turn a video into a shot list, frames Claude can read, and
# dialogue pinned to shot numbers.
#
#   prepare.sh <URL|path> [workdir]
#
# Prints the manifest path on the last line. Tunables:
#   WV_THRESHOLD  scene-detection sensitivity      (default: auto-calibrated)
#   WV_MIN_SHOT   merge shots shorter than this    (default 0.40s)
#   WV_MAX_SHEETS cap on 3-frame shot sheets       (default 20)
#   WHISPER_MODEL ggml model path for the fallback transcript
set -euo pipefail

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: prepare.sh <URL|path> [workdir]" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

THRESHOLD="${WV_THRESHOLD:-auto}"
MIN_SHOT="${WV_MIN_SHOT:-0.40}"
MAX_SHEETS="${WV_MAX_SHEETS:-20}"

CELL_W=500        # shot-sheet cell width; the legibility floor found by testing
CAST_W=300        # cast-sheet cells can be smaller — identify, not read
MAX_EDGE=1900     # sheets past this get downscaled hard and lose the detail

# ------------------------------------------------------------------ deps
miss=""
for c in ffmpeg ffprobe python3; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
if [ -n "$miss" ]; then
  echo "missing required:$miss" >&2
  echo "  macOS:  brew install ffmpeg python3" >&2
  echo "  linux:  sudo apt-get install -y ffmpeg python3" >&2
  exit 3
fi

FONT="${WV_FONT:-}"
if [ -z "$FONT" ]; then
  for f in /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
           /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
           /System/Library/Fonts/Supplemental/Arial\ Bold.ttf \
           /System/Library/Fonts/Helvetica.ttc \
           /usr/share/fonts/TTF/DejaVuSans-Bold.ttf; do
    [ -f "$f" ] && { FONT="$f"; break; }
  done
fi
[ -n "$FONT" ] || { echo "no usable font found; set WV_FONT=/path/to/font.ttf" >&2; exit 3; }

# ---------------------------------------------------------------- workdir
WORK="${2:-}"
if [ -z "$WORK" ]; then
  SLUG=$(printf '%s' "$SRC" | tr -c 'A-Za-z0-9' '-' | cut -c1-40)
  WORK="${TMPDIR:-/tmp}/watch-video/${SLUG}-$$"
fi
mkdir -p "$WORK"/{shots_src,cast_src,shots,cast}
rm -f "$WORK"/shots_src/* "$WORK"/cast_src/* "$WORK"/shots/* "$WORK"/cast/* 2>/dev/null || true

# ---------------------------------------------------------------- acquire
echo "[1/6] fetching" >&2
if [ -f "$SRC" ]; then
  cp -f "$SRC" "$WORK/video.mp4"
  # A sidecar subtitle next to a local file is as good as platform captions.
  for ext in vtt srt; do
    [ -f "${SRC%.*}.$ext" ] && cp -f "${SRC%.*}.$ext" "$WORK/video.local.$ext" && break
  done
else
  command -v yt-dlp >/dev/null 2>&1 || {
    echo "yt-dlp needed for URLs: pip install -U yt-dlp" >&2; exit 3; }
  # Captions ride along with the download: exactly timed, free, and far better
  # than re-deriving speech locally.
  yt-dlp --no-playlist --no-warnings \
         --write-subs --write-auto-subs --sub-lang "en.*" --sub-format vtt \
         -f "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b" \
         -o "$WORK/video.%(ext)s" "$SRC" >/dev/null 2>&1 || {
    # A plain media URL has no page to extract, so yt-dlp's generic path can
    # fail on something curl fetches without trouble.
    case "$SRC" in
      *.mp4|*.mov|*.m4v|*.webm|*.mkv)
        command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 600 -o "$WORK/video.mp4" "$SRC" \
          || { echo "could not fetch: $SRC" >&2; exit 4; } ;;
      *) echo "yt-dlp failed for: $SRC" >&2; exit 4 ;;
    esac
  }
  if [ ! -f "$WORK/video.mp4" ]; then
    CAND=$(ls -1 "$WORK"/video.* 2>/dev/null | grep -vE '\.(vtt|srt|json)$' | head -n1 || true)
    [ -n "$CAND" ] || { echo "no video file downloaded" >&2; exit 4; }
    ffmpeg -nostdin -y -loglevel error -i "$CAND" -c copy "$WORK/video.mp4" 2>/dev/null \
      || mv "$CAND" "$WORK/video.mp4"
  fi
fi

# ------------------------------------------------------------------ probe
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/video.mp4" | head -n1)
W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$WORK/video.mp4" | head -n1)
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$WORK/video.mp4" | head -n1)
[ -n "${DUR:-}" ] && [ -n "${W:-}" ] && [ -n "${H:-}" ] || { echo "could not probe video" >&2; exit 4; }

# Geometry from the measured aspect ratio. Three columns always — a row is one
# shot, read start / middle / end. Rows per sheet fall out of cell height so a
# vertical video gets short sheets and a landscape one gets tall sheets, and
# neither blows past MAX_EDGE.
CELL_H=$(awk -v w="$W" -v h="$H" -v c="$CELL_W" 'BEGIN{printf "%d", c*h/w}')
ROWS=$(awk -v e="$MAX_EDGE" -v ch="$CELL_H" 'BEGIN{r=int(e/ch); if(r<1)r=1; if(r>6)r=6; print r}')
CAST_H=$(awk -v w="$W" -v h="$H" -v c="$CAST_W" 'BEGIN{printf "%d", c*h/w}')
CAST_COLS=5
CAST_ROWS=$(awk -v e="$MAX_EDGE" -v ch="$CAST_H" 'BEGIN{r=int(e/ch); if(r<1)r=1; if(r>6)r=6; print r}')

export WV_FONT="$FONT"
export WV_FS=$(awk -v w="$W" 'BEGIN{f=int(w/16); if(f<18)f=18; print f}')
export WV_PAD=$(awk -v w="$W" 'BEGIN{p=int(w/60); if(p<4)p=4; print p}')
export WV_BB=$(awk -v f="$WV_FS" 'BEGIN{b=int(f/5); if(b<3)b=3; print b}')

# ------------------------------------------------------------ detect shots
echo "[2/6] detecting shots" >&2
# One decode pass collects every frame's scene score above the noise gate; the
# threshold is then chosen from that distribution instead of being guessed.
ffmpeg -nostdin -loglevel info -i "$WORK/video.mp4" \
  -filter:v "select='gt(scene,0.01)',metadata=print" -f null - 2>&1 \
  | grep -oE 'pts_time:[0-9.]+|lavfi.scene_score=[0-9.]+' | paste - - \
  | sed -E 's/pts_time:([0-9.]+)\tlavfi\.scene_score=([0-9.]+)/\1 \2/' > "$WORK/scores.txt" || true

SHOT_COUNT=$(python3 "$HERE/align.py" shots --scores "$WORK/scores.txt" \
  --threshold "$THRESHOLD" --duration "$DUR" --min-dur "$MIN_SHOT" --out "$WORK/shots.tsv")
THRESHOLD_USED=$(cut -f1 "$WORK/threshold.txt" 2>/dev/null || echo "$THRESHOLD")
THRESHOLD_WHY=$(cut -f2 "$WORK/threshold.txt" 2>/dev/null || echo "")
echo "      $SHOT_COUNT shots (threshold $THRESHOLD_USED — $THRESHOLD_WHY)" >&2

# ------------------------------------------------------- pick sampling plan
MAX_3F=$(( MAX_SHEETS * ROWS ))
CAPPED_NOTE=""
if [ "$SHOT_COUNT" -gt "$MAX_3F" ]; then
  # Too many shots for three frames each. Give the full treatment to the longest
  # shots — the ones carrying the content — and keep every other shot present on
  # the cast sheets so nothing silently disappears.
  sort -t$'\t' -k4 -gr "$WORK/shots.tsv" | head -n "$MAX_3F" | sort -t$'\t' -k1 -n > "$WORK/shots_3f.tsv"
  CAPPED_NOTE="$SHOT_COUNT shots exceeded the $MAX_3F-shot budget for 3-frame sheets. The $MAX_3F longest shots got start/middle/end frames; every shot still appears once on the cast sheets. Raise with WV_MAX_SHEETS."
  echo "      capping 3-frame sheets at $MAX_3F shots" >&2
else
  cp "$WORK/shots.tsv" "$WORK/shots_3f.tsv"
fi

# ------------------------------------------------------------ build jobs
label() { awk -v i="$1" -v t="$2" 'BEGIN{printf "S%d  %dm%04.1fs", i, int(t/60), t-60*int(t/60)}'; }

: > "$WORK/jobs.tsv"
n=0
while IFS=$'\t' read -r idx st en du; do
  n=$((n+1))
  mid=$(awk -v s="$st" -v e="$en" 'BEGIN{printf "%.3f", (s+e)/2}')
  printf '%s\t%s\t%s\n' "$mid" "$(label "$idx" "$mid")" \
    "$WORK/cast_src/$(printf 'c_%04d.jpg' "$n")" >> "$WORK/jobs.tsv"
done < "$WORK/shots.tsv"

m=0
while IFS=$'\t' read -r idx st en du; do
  # Nudge off the exact boundary so a frame lands inside the shot, not on the cut.
  off=$(awk -v d="$du" 'BEGIN{o=d*0.15; if(o>0.20)o=0.20; if(o<0.02)o=0.02; print o}')
  t1=$(awk -v s="$st" -v o="$off" 'BEGIN{printf "%.3f", s+o}')
  t2=$(awk -v s="$st" -v e="$en" 'BEGIN{printf "%.3f", (s+e)/2}')
  t3=$(awk -v e="$en" -v o="$off" 'BEGIN{printf "%.3f", e-o}')
  for t in "$t1" "$t2" "$t3"; do
    m=$((m+1))
    printf '%s\t%s\t%s\n' "$t" "$(label "$idx" "$t")" \
      "$WORK/shots_src/$(printf 's_%04d.jpg' "$m")" >> "$WORK/jobs.tsv"
  done
done < "$WORK/shots_3f.tsv"

echo "[3/6] extracting $(wc -l < "$WORK/jobs.tsv" | tr -d ' ') frames" >&2
xargs -P 4 -I LINE "$HERE/extract_one.sh" "$WORK" LINE < "$WORK/jobs.tsv"

# ----------------------------------------------------------------- tiling
echo "[4/6] building sheets" >&2
# Any frame that failed to extract would break the %04d sequence input, so
# renumber what actually landed before tiling.
renumber() {
  local dir="$1" pre="$2" i=0 f
  for f in $(ls -1 "$dir" 2>/dev/null | sort); do
    i=$((i+1))
    local want; want=$(printf "%s_%04d.jpg" "$pre" "$i")
    [ "$f" = "$want" ] || mv "$dir/$f" "$dir/$want"
  done
  echo "$i"
}
NS=$(renumber "$WORK/shots_src" s)
NC=$(renumber "$WORK/cast_src" c)

[ "$NS" -gt 0 ] && ffmpeg -nostdin -y -loglevel error -framerate 1 -i "$WORK/shots_src/s_%04d.jpg" \
  -vf "scale=${CELL_W}:-1,tile=3x${ROWS}:margin=10:padding=8:color=white" \
  -q:v 3 "$WORK/shots/sheet_%02d.jpg"
[ "$NC" -gt 0 ] && ffmpeg -nostdin -y -loglevel error -framerate 1 -i "$WORK/cast_src/c_%04d.jpg" \
  -vf "scale=${CAST_W}:-1,tile=${CAST_COLS}x${CAST_ROWS}:margin=10:padding=8:color=white" \
  -q:v 3 "$WORK/cast/sheet_%02d.jpg"

# ------------------------------------------------------------- transcript
echo "[5/6] transcript" >&2
CAPS=""; TSOURCE="none — no captions available and whisper-cli not installed"
VTT=$(ls -1 "$WORK"/video*.vtt "$WORK"/video*.srt 2>/dev/null | head -n1 || true)
if [ -n "$VTT" ]; then
  CAPS="$VTT"
  case "$VTT" in
    *local*) TSOURCE="sidecar subtitle file ($(basename "$VTT"))" ;;
    *)       TSOURCE="platform captions ($(basename "$VTT"))" ;;
  esac
elif command -v whisper-cli >/dev/null 2>&1; then
  MODEL="${WHISPER_MODEL:-$HOME/.claude/models/ggml-base.en.bin}"
  if [ -f "$MODEL" ]; then
    ffmpeg -nostdin -y -loglevel error -i "$WORK/video.mp4" -ar 16000 -ac 1 "$WORK/audio.wav"
    # -ovtt keeps cue timings, which is what pins a line to a shot.
    (cd "$WORK" && whisper-cli -m "$MODEL" -f audio.wav -ovtt -of whisper >/dev/null 2>&1) || true
    [ -f "$WORK/whisper.vtt" ] && { CAPS="$WORK/whisper.vtt"; TSOURCE="whisper ($(basename "$MODEL"))"; }
  else
    TSOURCE="none — whisper-cli found but no model at $MODEL"
  fi
fi
echo "      $TSOURCE" >&2

# ---------------------------------------------------------------- report
echo "[6/6] writing manifest" >&2
python3 "$HERE/align.py" report \
  --workdir "$WORK" --shots "$WORK/shots.tsv" --captions "$CAPS" \
  --transcript-source "$TSOURCE" --source "$SRC" --duration "$DUR" \
  --width "$W" --height "$H" --threshold "$THRESHOLD_USED ($THRESHOLD_WHY)" --min-dur "$MIN_SHOT" \
  --capped-note "$CAPPED_NOTE" >&2

echo "$WORK/manifest.md"
