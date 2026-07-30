---
name: watch-video
description: Use when the user gives a video URL (YouTube, Instagram, Loom, TikTok, direct link) or a local video file and wants Claude to actually SEE it — a director-style shot-by-shot breakdown with shot list, what's on screen, who's featured, who's speaking, what's said, and the style. Triggers on "/watch-video URL", "watch this video", "break this reel down", "give me a shot list".
---

# watch-video — a director's breakdown, not a transcript

Claude has no native video model. This skill splits a video into a shot list, frames grouped by
shot, and dialogue already pinned to shot numbers, then you read them together.

## Step 1 — Run the pipeline

```bash
.claude/skills/watch-video/scripts/prepare.sh "<URL or path>"
```

It prints a manifest path. One command does everything: download (with captions), shot detection,
frame extraction, tiling, transcript, alignment. It takes a couple of minutes on a long video.

If it exits non-zero it tells you what is missing — run `scripts/check-deps.sh` and pass on the
install line. Do not fall back to improvising ffmpeg commands.

## Step 2 — Read the output in this order

1. **`manifest.md`** — shot list, measured cut statistics, sheet paths.
2. **`cast/sheet_*.jpg`** — one frame per shot. Read these *before* the shot sheets and fix a
   stable label for every recurring person. Use their real name if it is spoken or on screen,
   otherwise a descriptive handle (`Woman A — dark curly hair, red apron`). Keep those labels
   for the rest of the breakdown so one person doesn't become three across 40 shots.
3. **`shots/shot_NNN_*.jpg`** — **one sheet per shot**, read in shot order. Frames run left to
   right, top to bottom, evenly spaced across that shot at about one per second, so a long shot
   arrives as a real sequence and a short insert as a couple of stills. A shot needing more
   frames than one sheet holds continues onto `_02`, `_03`. Read each sheet as a sequence and
   compare first frame to last: a subject growing in frame is a push-in, sliding across is a
   pan, and a background that changes throughout means the camera is travelling.
4. **`dialogue.md`** — every line, already assigned to a shot number.

Each frame carries `S<shot> <time>` burned into the corner. **Read timestamps off the image.**
Never compute them from a cell's position in the grid.

## Step 3 — Produce the breakdown

Output in the Apex Artworks clip shape: a title, a logline, the runtime and shot count, then the
shots — each a one-line description plus a **verbatim prompt** detailed enough to regenerate the
shot from scratch.

```markdown
# <Title — evocative, 2–5 words, e.g. "Golden Hour, First Bite">

<Logline: one sentence covering the whole clip — who, where, what happens, the light.>

<duration>s · <n> shots

## The shots

**01** — <one sentence: what happens in this shot>

> **Verbatim prompt**
> <A full generative-video prompt for this shot: subject and wardrobe, setting, time of day
> and light, framing and camera movement, the action beat by beat, and any line spoken.>

**02** — ...
```

Then the same data as JSON, using these exact field names so it can go straight into the library:

```json
{
  "clip_id": "<id or null>",
  "title": "...",
  "description": "<logline>",
  "duration_s": 15,
  "shot_count": 4,
  "shots": [
    {"shot_index": 1, "description": "...", "verbatim_text": "...", "shot_deeplink": null}
  ]
}
```

### The bar for the prose

A shot sheet is a **sequence**, not a still. Most of the value is in what changes between the
first frame and the last, and a breakdown that ignores that is a caption, not a description.

- **Say what changes.** Where does the subject move, what enters or leaves frame, what does the
  camera do, what is different at the end versus the start? If genuinely nothing changes, say
  it's a held shot — but check before claiming it. A shot sampled at 8 frames that you describe
  in one static sentence means you didn't read it.
- **Never default to "static".** Walking, tracking, whip-pans and reframes are common and easy to
  miss if you only glance at the first frame. Compare first to last.
- **Name specifics, not categories.** Props, wardrobe, signage text, gestures, the actual gag.
  "He balances on a floating lounger, arms out, wobbling" — not "hamming up the perks". Vague
  summary language is a tell that the shot wasn't looked at.
- **No boilerplate style clauses.** Do not append the same "clean bright commercial lighting,
  warm palette, crisp grade, shallow depth of field" to every shot. Mention lighting, grade or
  lens only where it is a real feature of *that* shot or changes from its neighbours. Repetition
  across shots is padding.
- **Carry continuity between shots.** Props and actions often continue across a cut — a whip-pan
  out of one shot and into the next, an object carried through. Note it; it is exactly what a
  reskin needs to preserve.
- **Flag what you couldn't see.** Thin coverage, an ambiguous beat, an unreadable sign — say so
  rather than smoothing it over.

### Writing the shots well

- **Description** — one sentence, present tense, the beat of the shot. Match the register of
  "The camera pushes in as she smiles, brings the burger close, and takes a small, natural bite."
- **Verbatim prompt** — this is the recreatable artefact, so it carries the detail: who is in
  frame and what they look like, wardrobe, setting and background, the quality of the light,
  framing and how the camera moves, the action in order, and what is said. Where a line is
  spoken, fold it in the way the reference does — "She softly says in English that it tastes
  amazing."
- **Characters** — fix each recurring person's label from the cast sheets first, then describe
  them consistently in every prompt they appear in. Use a real name only if it is spoken or
  shown on screen.
- **Style** — the look belongs inside the prompts (grade, light, lens feel, film stock), not in
  a separate section. Take pacing claims from the **measured** cut statistics in `manifest.md`,
  never estimate them.

If the user asks for a straight shot table instead — columns for framing, camera, who's in
frame, who's speaking, action, and the line — give them that from the same material.

## Being straight about what is inferred

Two things in this output are read off pictures rather than measured, and should be marked when
they are uncertain rather than stated flatly:

- **Who is speaking.** Captions carry no speaker labels, so attribution comes from who is on
  screen and whose mouth is moving. Tag each line `on-screen`, `voiceover`, or `uncertain`.
  Overlapping and off-screen voices are genuinely ambiguous — say so.
- **Camera movement.** Three frames read static vs pan vs push-in reliably. Handheld float,
  slow drift, and speed ramps are judgement calls at this sampling rate — hedge them.

If `manifest.md` reports a coverage cap, say so in the output. If it reports no transcript, say
that too rather than inventing dialogue.

## Tuning

| Variable | Default | Use when |
|---|---|---|
| `WV_THRESHOLD` | auto | Auto-calibrated per video. Override only to force a value. |
| `WV_MIN_SHOT` | `0.40` | Flashes/whip-pans splitting into fragments → raise. |
| `WV_MAX_SHEETS` | `20` | Long video capped and you want full 3-frame coverage → raise. |
| `WHISPER_MODEL` | `~/.claude/models/ggml-base.en.bin` | Local transcription fallback. |

Clean up the workdir when done: `rm -rf <workdir>`.
