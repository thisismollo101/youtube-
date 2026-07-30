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
3. **Sample** — one frame per second of shot, so coverage tracks content. A fixed count per shot
   spends the budget backwards: a 9.7s shot and a 1.1s insert would get identical coverage, so
   the shot carrying the most action gets seen least. There is deliberately no per-shot ceiling:
   any cap re-creates the same inversion on long takes, where a shot silently drops below the
   nominal rate. Totals are bounded by the global budget instead, which scales every shot by the
   same factor rather than truncating one.
4. **Tile** — **one sheet per shot**, gridded to that shot's frame count, so a long shot reads as
   a sequence. Geometry is derived from the source aspect ratio.
5. **Transcribe** — platform captions if they exist, `whisper-cli` if not, and an explicit "none"
   rather than silence when neither is available.
6. **Align** — caption cues are assigned to shots by timestamp overlap into `dialogue.md`.
7. **Flag hidden transitions** — a hard cut is one frame of large change; a whip-pan or sky wipe
   is several frames of moderate change, and never crosses the cut threshold. Those runs are
   reported in the manifest with a ready-made `zoom.sh` command, because a missed one silently
   merges two entirely different setups into a single shot.

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
shots/           one sheet per shot, frames proportional to shot length
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
| `WV_MAX_SHEETS` | `20` | The only real limit on coverage — a budget in sheets (i.e. images to read). Raise for long videos. |
| `WV_SEC_PER_FRAME` | `1.0` | Seconds of shot per sampled frame. Lower for denser coverage. |
| `WV_FONT` | auto-detected | No usable system font found. |
| `WHISPER_MODEL` | `~/.claude/models/ggml-base.en.bin` | Local transcription fallback. |

## Limits

- **Speaker attribution is inferred**, not diarized — captions carry no speaker labels, so it comes
  from who is on screen and whose mouth is moving. Reliable for one visible speaker, weak for
  off-screen narration and overlapping voices. Lines are tagged `on-screen` / `voiceover` /
  `uncertain` rather than silently guessed.
- **Camera movement is inferred** from the frames sampled across a shot, not measured. Static,
  pan, push-in and travelling moves read reliably at one frame per second; handheld float, slow
  drift and speed ramps remain judgement calls.
- **Very long videos are scaled back.** Past the frame budget every shot's coverage is reduced
  proportionally, never below 2 frames, so long shots keep the largest share. The manifest says
  so explicitly.
