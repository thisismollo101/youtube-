# watch-video

A Claude Code skill that turns a video into a **director-style shot-by-shot breakdown** — shot
list, what's on screen, who's featured, who's speaking, what's said, and the style.

Claude has no native video model, so the pipeline converts a video into things it *can* read:
frames grouped by shot, and dialogue pinned to shot numbers.

## Use

```bash
.claude/skills/watch-video/scripts/check-deps.sh          # what's installed
.claude/skills/watch-video/scripts/prepare.sh "<URL>"     # or a local file path
```

`prepare.sh` prints a manifest path. `SKILL.md` tells Claude how to read the output.

Requires `ffmpeg`, `ffprobe`, `python3`; `yt-dlp` for URLs. `whisper-cli` plus a model is an
optional fallback used only when a video has no captions.

## How it works

1. **Fetch** — `yt-dlp` pulls the video *and* its captions in one pass. Local files are copied,
   and a sidecar `.vtt`/`.srt` next to the file is picked up automatically.
2. **Detect shots** — one decode pass collects every frame's scene score, and the cut threshold
   is picked from that distribution: real cuts sit far above the noise floor, so the largest
   multiplicative gap splits them. This matters because no fixed value works — a bright promo
   scores its cuts at 0.85 against 0.03 noise, while a dark, warm ad scores its at 0.28 against
   0.06. A fixed 0.30 reports that second video as one 13-second shot. Fragments under
   `WV_MIN_SHOT` are merged so a flash frame doesn't become five phantom shots, and cut
   statistics come from here, so pacing is measured rather than guessed.
3. **Sample** — three frames per shot (start / middle / end). One frame per cut cannot show what
   happens *within* a shot, which is what makes camera movement readable.
4. **Tile** — frames go onto contact sheets with **one shot per row**, columns left-to-right in
   time. Geometry is derived from the source aspect ratio.
5. **Transcribe** — platform captions if they exist, `whisper-cli` if not, and an explicit "none"
   rather than silence when neither is available.
6. **Align** — caption cues are assigned to shots by timestamp overlap into `dialogue.md`.

## Two things that matter

**Timestamps are burned into every frame** (`S3 0m07.0s`). Claude reads them off the image instead
of deriving them from grid position, which removes a whole class of off-by-one drift.

**Sheet geometry adapts to aspect ratio.** A fixed grid tuned for 16:9 produces a ~1028x3248 sheet
on a 9:16 reel, which gets downscaled to roughly 123px per cell — too small to identify a person or
read a caption, on the exact format the skill exists to handle. Cells are held at 500px wide and
rows per sheet fall out of cell height, so sheets stay under ~1900px on the long edge in either
orientation.

## Working from a downloaded file

Passing a local path skips the download stage entirely and is the most reliable way to run this —
no extractor breakage, no rate limits, no network policy in the way:

```bash
scripts/prepare.sh ~/Downloads/clip.mp4
```

A sidecar `clip.vtt` or `clip.srt` next to the file is picked up automatically as the dialogue
source, so you get the same timed-caption quality as a platform download.

## Intermediate output

```
manifest.md      shot list, measured cut stats, read order
cast/            one frame per shot — for fixing stable character labels
shots/           three frames per shot, one shot per row
dialogue.md      every line, assigned to a shot number
```

## Final output

Claude reads the above and writes the breakdown in the Apex Artworks clip shape — title, logline,
`15s · 4 shots`, then per shot a one-line description plus a **verbatim prompt** detailed enough to
regenerate that shot. The same data is emitted as JSON using the library's field names
(`clip_id`, `shot_index`, `description`, `verbatim_text`, `shot_deeplink`). See `SKILL.md`.

## Tuning

| Variable | Default | Use when |
|---|---|---|
| `WV_THRESHOLD` | auto | Auto-calibrated per video. Override only to force a value. |
| `WV_MIN_SHOT` | `0.40` | Flashes or whip-pans splitting into fragments → raise. |
| `WV_MAX_SHEETS` | `20` | Long video capped and you want full 3-frame coverage → raise. |
| `WV_FONT` | auto-detected | No usable system font found. |
| `WHISPER_MODEL` | `~/.claude/models/ggml-base.en.bin` | Local transcription fallback. |

## Limits

- **Speaker attribution is inferred**, not diarized — captions carry no speaker labels, so it comes
  from who is on screen and whose mouth is moving. Reliable for one visible speaker, weak for
  off-screen narration and overlapping voices. Lines are tagged `on-screen` / `voiceover` /
  `uncertain` rather than silently guessed.
- **Camera movement is inferred** from three frames. Static, pan, and push-in read reliably;
  handheld float, slow drift, and speed ramps are judgement calls.
- **Very long videos are capped.** Past `WV_MAX_SHEETS` sheets the longest shots keep three-frame
  treatment and the rest appear once on the cast sheets. The manifest says so explicitly.
