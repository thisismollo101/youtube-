#!/usr/bin/env bash
# watch-video: turn a video into a shot list, frames Claude can read, and
# dialogue pinned to shot numbers.
#
#   prepare.sh <URL|path> [workdir]
#
# Prints the manifest path on the last line. Tunables:
#   WV_THRESHOLD  scene-detection sensitivity      (default: auto-calibrated)
#   WV_MIN_SHOT   merge shots shorter than this    (default 0.40s)
#   WV_MAX_SHEETS overall frame budget, in sheets   (default 20)
#   WV_SEC_PER_FRAME seconds of shot per sampled frame (default 1.0)
#   WHISPER_MODEL ggml model path for the fallback transcript
set -euo pipefail

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: prepare.sh <URL|path> [workdir]" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

THRESHOLD="${WV_THRESHOLD:-auto}"
MIN_SHOT="${WV_MIN_SHOT:-0.40}"
MAX_SHEETS="${WV_MAX_SHEETS:-20}"
SEC_PER_FRAME="${WV_SEC_PER_FRAME:-1.0}"   # one sampled frame per this many seconds of shot
MIN_FRAMES="${WV_MIN_FRAMES:-4}"           # 2 frames give one interval — too few to call a move
HEAD_WINDOW="${WV_HEAD_WINDOW:-0.5}"       # extra samples inside this much of each shot's head
SOFT_WINDOW="${WV_SOFT_WINDOW:-1.6}"       # spread of extra samples after a hidden transition

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
mkdir -p "$WORK"/{frames,cast_src,shots,cast}
rm -rf "$WORK"/frames/* 2>/dev/null || true
rm -f "$WORK"/cast_src/* "$WORK"/shots/* "$WORK"/cast/* 2>/dev/null || true

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
# Frames per shot follow the shot's own length. A fixed count per shot spends
# the budget backwards: a 9.7s shot and a 1.1s insert get identical coverage,
# so the shot carrying the most action is the one seen least.
PER_SHEET=$(( 3 * ROWS ))                       # frames one sheet can hold
MAX_FRAMES=$(( MAX_SHEETS * PER_SHEET ))
awk -F'\t' -v spf="$SEC_PER_FRAME" -v maxf="$MAX_FRAMES" -v MINF="$MIN_FRAMES" '
  { idx[NR]=$1; st[NR]=$2; en[NR]=$3; du[NR]=$4
    # No per-shot ceiling at all. Any cap re-creates the inversion this is meant
    # to remove: past the cap a long shot silently drops below the nominal rate,
    # and long shots are the ones that need coverage most. The global budget
    # below bounds the total, and scales every shot by the same factor rather
    # than truncating one.
    n=int(du[NR]/spf + 0.5); if(n<MINF)n=MINF; nf[NR]=n; tot+=n+2 }   # +2 head samples
  END{
    # Over budget: scale every shot back proportionally but never below 2, so
    # long shots still keep the largest share rather than being dropped.
    if (tot > maxf) {
      f = maxf/tot
      for(i=1;i<=NR;i++){ n=int(nf[i]*f + 0.5); if(n<MINF)n=MINF; nf[i]=n }
    }
    for(i=1;i<=NR;i++) printf "%s\t%s\t%s\t%s\t%d\n", idx[i], st[i], en[i], du[i], nf[i]
  }' "$WORK/shots.tsv" > "$WORK/plan.tsv"

PLANNED=$(awk -F'\t' '{s+=$5} END{print s+0}' "$WORK/plan.tsv")
CAPPED_NOTE=""
if [ "$PLANNED" -ge "$MAX_FRAMES" ]; then
  CAPPED_NOTE="Frame budget reached ($PLANNED of $MAX_FRAMES). Per-shot coverage was scaled back proportionally — long shots keep the most frames, none drop below 2. Raise with WV_MAX_SHEETS or lower WV_SEC_PER_FRAME."
  echo "      frame budget reached — coverage scaled to $PLANNED frames" >&2
fi

# ------------------------------------------------------------ build jobs
label() { awk -v i="$1" -v t="$2" 'BEGIN{printf "S%d  %dm%04.1fs", i, int(t/60), t-60*int(t/60)}'; }

: > "$WORK/jobs.tsv"
n=0
while IFS=$'\t' read -r idx st en du nf; do
  n=$((n+1))
  mid=$(awk -v s="$st" -v e="$en" 'BEGIN{printf "%.3f", (s+e)/2}')
  printf '%s\t%s\t%s\n' "$mid" "$(label "$idx" "$mid")" \
    "$WORK/cast_src/$(printf 'c_%04d.jpg' "$n")" >> "$WORK/jobs.tsv"

  # Each shot gets its own directory so it can be tiled on its own sheet at
  # whatever grid its frame count needs.
  SDIR="$WORK/frames/$(printf 'shot_%03d' "$idx")"
  mkdir -p "$SDIR"
  # Inset from the boundaries so no frame lands on the cut itself.
  off=$(awk -v d="$du" 'BEGIN{o=d*0.12; if(o>0.20)o=0.20; if(o<0.02)o=0.02; print o}')
  {
    awk -v s="$st" -v e="$en" -v o="$off" -v n="$nf" -v hw="$HEAD_WINDOW" 'BEGIN{
      a=s+o; b=e-o; if(b<=a){a=(s+e)/2; b=a}
      for(i=0;i<n;i++) t[i]=(n==1? a : a + (b-a)*i/(n-1))
      # Crash zooms, whip settles and the first frames of a move nearly all live
      # in the opening moments of a shot — exactly where an even spread is
      # thinnest.
      hb = a + hw; if (hb > b) hb = b
      if (hb > a) { t[n] = a + (hb-a)/3; t[n+1] = a + 2*(hb-a)/3; n += 2 }
      for(i=0;i<n;i++) print t[i]
    }'
    # A hidden transition starts a new setup mid-shot, so it needs the same head
    # density as a real cut — otherwise a crash zoom on the far side of a whip
    # lands in the gap between evenly-spaced samples and is never seen.
    # A wipe can hold for a while before the new setup resolves — the sky in a
    # tilt-through-sky join, the blur in a long whip — so this window is much
    # wider than a normal shot head, and evenly spread rather than front-packed.
    [ -f "$WORK/soft.tsv" ] && awk -F'\t' -v s="$st" -v e="$en" -v sw="$SOFT_WINDOW" '
      $1 > s && $1 < e {
        if ($1 - 0.15 > s) print $1 - 0.15
        for (i = 1; i <= 4; i++) print $1 + sw*i/4
      }' "$WORK/soft.tsv" | awk -v e="$en" '$1 < e'
  } | sort -g | awk 'NR==1 || $1-prev > 0.03 {print; prev=$1}' | while read -r t; do
    j=$((${j:-0}+1))
    printf '%s\t%s\t%s\n' "$t" "$(label "$idx" "$t")" \
      "$SDIR/$(printf 'f_%03d.jpg' "$j")" >> "$WORK/jobs.tsv"
  done
done < "$WORK/plan.tsv"

echo "[3/6] extracting $(wc -l < "$WORK/jobs.tsv" | tr -d ' ') frames" >&2
xargs -P 4 -I LINE "$HERE/extract_one.sh" "$WORK" LINE < "$WORK/jobs.tsv"

# ----------------------------------------------------------------- tiling
echo "[4/6] building sheets" >&2
# Any frame that failed to extract would break the %04d sequence input, so
# renumber what actually landed before tiling.
# Width must match the %0Nd pattern the tiling step feeds to ffmpeg, or the
# image2 demuxer silently finds nothing.
renumber() {
  local dir="$1" pre="$2" width="${3:-4}" i=0 f
  for f in $(ls -1 "$dir" 2>/dev/null | sort); do
    i=$((i+1))
    local want; want=$(printf "%s_%0${width}d.jpg" "$pre" "$i")
    [ "$f" = "$want" ] || mv "$dir/$f" "$dir/$want"
  done
  echo "$i"
}
NC=$(renumber "$WORK/cast_src" c)

# One sheet per shot, gridded to that shot's frame count, so a long shot reads
# as a sequence instead of being squeezed into the same row as a 1s insert.
MAX_COLS=$(awk -v e="$MAX_EDGE" -v c="$CELL_W" 'BEGIN{n=int(e/c); if(n<1)n=1; print n}')
MAX_ROWS=$(awk -v e="$MAX_EDGE" -v c="$CELL_H" 'BEGIN{n=int(e/c); if(n<1)n=1; print n}')
: > "$WORK/sheets.tsv"
for SDIR in "$WORK"/frames/shot_*; do
  [ -d "$SDIR" ] || continue
  SID=$(basename "$SDIR")
  NF=$(renumber "$SDIR" f 3)
  [ "$NF" -gt 0 ] || continue
  COLS=$(awk -v n="$NF" -v m="$MAX_COLS" 'BEGIN{print (n<m? n : m)}')
  ROWS_S=$(awk -v n="$NF" -v c="$COLS" -v m="$MAX_ROWS" 'BEGIN{r=int((n+c-1)/c); if(r>m)r=m; if(r<1)r=1; print r}')
  ffmpeg -nostdin -y -loglevel error -framerate 1 -i "$SDIR/f_%03d.jpg" \
    -vf "scale=${CELL_W}:-1,tile=${COLS}x${ROWS_S}:margin=10:padding=8:color=white" \
    -q:v 3 "$WORK/shots/${SID}_%02d.jpg"
  printf '%s\t%s\t%sx%s\n' "$SID" "$NF" "$COLS" "$ROWS_S" >> "$WORK/sheets.tsv"
done

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
