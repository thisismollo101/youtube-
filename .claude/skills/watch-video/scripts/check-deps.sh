#!/usr/bin/env bash
# Report what watch-video needs and what is actually present.
ok=0
chk() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  ok       %-12s %s\n' "$1" "$(command -v "$1")"
  else
    printf '  MISSING  %-12s %s\n' "$1" "$2"; [ "$3" = required ] && ok=1
  fi
}

echo "watch-video dependencies"
echo
echo "required:"
chk ffmpeg  "brew install ffmpeg   |  sudo apt-get install -y ffmpeg" required
chk ffprobe "ships with ffmpeg"                                        required
chk python3 "brew install python3  |  sudo apt-get install -y python3" required
echo
echo "needed for URLs (not for local files):"
chk yt-dlp  "pip install -U yt-dlp"
echo
echo "optional — only used when a video has no captions:"
chk whisper-cli "build whisper.cpp, then set WHISPER_MODEL"
MODEL="${WHISPER_MODEL:-$HOME/.claude/models/ggml-base.en.bin}"
if [ -f "$MODEL" ]; then printf '  ok       %-12s %s\n' "model" "$MODEL"
else printf '  MISSING  %-12s %s\n' "model" "$MODEL"; fi

echo
FONT=""
for f in /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
         /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
         /System/Library/Fonts/Supplemental/Arial\ Bold.ttf \
         /System/Library/Fonts/Helvetica.ttc \
         /usr/share/fonts/TTF/DejaVuSans-Bold.ttf; do
  [ -f "$f" ] && { FONT="$f"; break; }
done
if [ -n "$FONT" ]; then echo "font for timestamp burn-in: $FONT"
else echo "font for timestamp burn-in: NONE FOUND — set WV_FONT=/path/to/font.ttf"; ok=1; fi

echo
[ "$ok" = 0 ] && echo "ready." || echo "install the required items above first."
exit "$ok"
