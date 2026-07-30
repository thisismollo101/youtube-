#!/usr/bin/env python3
"""Shot-list maths and report generation for the watch-video skill.

Two subcommands:
  shots   cuts.txt + duration      -> shots.tsv   (idx, start, end, dur)
  report  shots.tsv + captions     -> dialogue.md, manifest.md

Kept separate from prepare.sh because VTT parsing and timestamp-overlap
alignment in awk is a bad time.
"""
import argparse, math, os, re, statistics, sys


# ----------------------------------------------------------------- shots
def build_shots(cuts, duration, min_dur):
    """Cut timestamps -> merged shot list. A cut at t ends the shot before it."""
    bounds = [0.0] + [c for c in sorted(cuts) if 0.0 < c < duration] + [duration]

    shots = []
    for start, end in zip(bounds, bounds[1:]):
        # Fold sub-minimum fragments into the previous shot: a flash frame or a
        # whip-pan trips scene detection repeatedly and would otherwise show up
        # as five phantom shots.
        if shots and (end - start) < min_dur:
            shots[-1][1] = end
        else:
            shots.append([start, end])

    # A leading fragment has no previous shot to merge into, so fix it up here.
    if len(shots) > 1 and (shots[0][1] - shots[0][0]) < min_dur:
        shots[1][0] = shots[0][0]
        shots.pop(0)

    return [(i + 1, s, e) for i, (s, e) in enumerate(shots)]


def pick_threshold(scores):
    """Find the cut threshold from the score distribution rather than guessing.

    Real cuts sit far above the per-frame noise floor, but *how* far depends
    entirely on the footage: a bright hard-cut promo scores cuts at 0.85 against
    0.03 noise, while a dark, warm, low-contrast ad scores its cuts at 0.28
    against 0.06. One fixed default cannot serve both — at 0.30 the second video
    reports a single 13-second shot, which is silently wrong.

    So: sort descending, find the largest multiplicative gap, and split there.
    """
    vals = sorted((s for _, s in scores), reverse=True)
    if len(vals) < 4:
        return DEFAULT_THRESHOLD, "too few scored frames"

    # A video is not more than a third cuts, and anything under the floor is
    # noise, not a candidate boundary.
    # Wide enough to reach past the cuts into the noise on a short or very
    # static clip, where only a handful of frames clear the gate at all.
    limit = min(len(vals) - 1, max(30, len(vals) // 3, 400))
    best_ratio, best_i = 0.0, None
    for i in range(limit - 1):
        hi, lo = vals[i], vals[i + 1]
        if hi < NOISE_FLOOR:
            break
        if lo <= 0:
            continue
        r = hi / lo
        if r > best_ratio:
            best_ratio, best_i = r, i

    if best_i is None or best_ratio < MIN_GAP_RATIO:
        # No clean separation — either a single continuous take or a dissolve-
        # heavy edit with no hard cuts. Fall back rather than invent boundaries.
        return DEFAULT_THRESHOLD, f"no clear gap (best ratio {best_ratio:.1f}x)"

    thr = math.sqrt(vals[best_i] * vals[best_i + 1])
    thr = min(max(thr, 0.05), 0.60)
    return thr, f"{best_i + 1} cuts above a {best_ratio:.1f}x gap"


DEFAULT_THRESHOLD = 0.30
NOISE_FLOOR = 0.05
MIN_GAP_RATIO = 2.0


def cmd_shots(a):
    scores = []
    if os.path.exists(a.scores):
        with open(a.scores) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) == 2:
                    try:
                        scores.append((float(parts[0]), float(parts[1])))
                    except ValueError:
                        pass

    if a.threshold == "auto":
        thr, why = pick_threshold(scores)
    else:
        thr, why = float(a.threshold), "set by WV_THRESHOLD"

    cuts = [t for t, s in scores if s > thr]
    shots = build_shots(cuts, a.duration, a.min_dur)
    with open(os.path.join(os.path.dirname(a.out), "threshold.txt"), "w") as fh:
        fh.write(f"{thr:.4f}\t{why}\n")
    with open(a.out, "w") as fh:
        for idx, start, end in shots:
            fh.write(f"{idx}\t{start:.3f}\t{end:.3f}\t{end - start:.3f}\n")
    print(len(shots))


# -------------------------------------------------------------- captions
TS = re.compile(r"(\d{1,2}):(\d{2}):(\d{2})[.,](\d{1,3})")


def _secs(m):
    h, mi, s, ms = m.groups()
    return int(h) * 3600 + int(mi) * 60 + int(s) + int(ms.ljust(3, "0")) / 1000.0


def parse_cues(path):
    """Parse WebVTT or whisper-style output into [(start, end, text)]."""
    cues, start = [], None
    try:
        raw = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return cues

    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith(("WEBVTT", "Kind:", "Language:", "NOTE")):
            continue

        if "-->" in line:
            times = TS.findall(line)
            marks = list(TS.finditer(line))
            if len(marks) >= 2:
                start, end = _secs(marks[0]), _secs(marks[1])
                cues.append([start, end, ""])
            continue

        # whisper -otxt writes "[00:00:00.000 --> 00:00:02.000]  text" on one line
        marks = list(TS.finditer(line))
        if len(marks) >= 2 and line.startswith("["):
            text = line[line.rfind("]") + 1:].strip()
            if text:
                cues.append([_secs(marks[0]), _secs(marks[1]), text])
            continue

        if cues:
            txt = re.sub(r"<[^>]*>", "", line).strip()  # strip karaoke spans
            if txt:
                cues[-1][2] = (cues[-1][2] + " " + txt).strip()

    # Auto-captions roll: each cue repeats the previous line plus one new one.
    # Drop cues whose text is contained in the one before it.
    out = []
    for s, e, t in cues:
        if not t:
            continue
        if out and (t == out[-1][2] or t in out[-1][2]):
            continue
        if out and out[-1][2] in t:
            out[-1] = [out[-1][0], e, t]
            continue
        out.append([s, e, t])
    return out


def fmt(t):
    return f"{int(t) // 60}:{t % 60:04.1f}"


# --------------------------------------------------------------- report
def cmd_report(a):
    shots = []
    with open(a.shots) as fh:
        for line in fh:
            idx, s, e, d = line.split("\t")
            shots.append((int(idx), float(s), float(e), float(d)))

    cues = parse_cues(a.captions) if a.captions and os.path.exists(a.captions) else []

    # Assign each cue to every shot it overlaps: a line spoken across a cut
    # belongs to both shots, which is what a breakdown needs to show.
    with open(os.path.join(a.workdir, "dialogue.md"), "w") as fh:
        fh.write("# Dialogue, aligned to shots\n\n")
        fh.write(f"Source: {a.transcript_source}\n\n")
        if not cues:
            fh.write("_No transcript available._\n")
        for idx, s, e, d in shots:
            hits = [c for c in cues if c[1] > s and c[0] < e]
            if not hits:
                continue
            fh.write(f"## Shot {idx} — {fmt(s)}–{fmt(e)}\n")
            for cs, ce, text in hits:
                mark = " (starts before this shot)" if cs < s - 0.05 else ""
                mark += " (runs past this shot)" if ce > e + 0.05 else ""
                fh.write(f"- [{fmt(cs)}] {text}{mark}\n")
            fh.write("\n")

    durs = [d for _, _, _, d in shots]
    stats = {
        "count": len(shots),
        "mean": statistics.mean(durs) if durs else 0,
        "median": statistics.median(durs) if durs else 0,
        "min": min(durs) if durs else 0,
        "max": max(durs) if durs else 0,
    }

    sheets = lambda sub: sorted(
        f"{sub}/{n}" for n in os.listdir(os.path.join(a.workdir, sub))
    ) if os.path.isdir(os.path.join(a.workdir, sub)) else []

    with open(os.path.join(a.workdir, "manifest.md"), "w") as fh:
        w = fh.write
        w("# watch-video — read this first\n\n")
        w(f"- source: {a.source}\n")
        w(f"- workdir: {a.workdir}\n")
        w(f"- duration: {a.duration:.1f}s   resolution: {a.width}x{a.height}"
          f" ({'vertical' if a.height > a.width else 'landscape' if a.width > a.height else 'square'})\n")
        w(f"- transcript: {a.transcript_source}\n\n")

        w("## Measured cut statistics (use these for the style read — do not estimate pacing)\n\n")
        w(f"- {stats['count']} shots over {a.duration:.1f}s\n")
        w(f"- mean shot {stats['mean']:.2f}s, median {stats['median']:.2f}s\n")
        w(f"- shortest {stats['min']:.2f}s, longest {stats['max']:.2f}s\n")
        w(f"- detection threshold {a.threshold}, fragments under {a.min_dur}s merged\n\n")

        w("## Read order\n\n")
        w("1. `cast.md` sheets — one frame per shot. Fix a stable label per recurring person here.\n")
        w("2. `shots/` sheets — 3 frames per shot. **Each row is one shot**, left to right:\n")
        w("   start, middle, end. Compare across a row to read camera movement.\n")
        w("3. `dialogue.md` — what is said, already pinned to shot numbers.\n\n")
        w("Every frame is burned with `S<shot> <time>`. Read timestamps off the image;\n")
        w("do not compute them from cell position.\n\n")

        for label, sub in (("Cast sheets", "cast"), ("Shot sheets", "shots")):
            names = sheets(sub)
            w(f"## {label} — {len(names)} file(s)\n")
            for n in names:
                w(f"- {a.workdir}/{n}\n")
            w("\n")

        if a.capped_note:
            w(f"## Coverage note\n\n{a.capped_note}\n\n")

        w("## Shot list\n\n| # | start | end | dur |\n|---|---|---|---|\n")
        for idx, s, e, d in shots:
            w(f"| {idx} | {fmt(s)} | {fmt(e)} | {d:.2f}s |\n")

        w(f"\nCleanup when done: `rm -rf {a.workdir}`\n")

    print(f"{stats['count']} shots, mean {stats['mean']:.2f}s")


p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)

ps = sub.add_parser("shots")
ps.add_argument("--scores", required=True)
ps.add_argument("--threshold", default="auto")
ps.add_argument("--duration", type=float, required=True)
ps.add_argument("--min-dur", type=float, default=0.4)
ps.add_argument("--out", required=True)
ps.set_defaults(fn=cmd_shots)

pr = sub.add_parser("report")
pr.add_argument("--workdir", required=True)
pr.add_argument("--shots", required=True)
pr.add_argument("--captions", default="")
pr.add_argument("--transcript-source", default="none")
pr.add_argument("--source", default="")
pr.add_argument("--duration", type=float, default=0)
pr.add_argument("--width", type=int, default=0)
pr.add_argument("--height", type=int, default=0)
pr.add_argument("--threshold", default="")
pr.add_argument("--min-dur", default="")
pr.add_argument("--capped-note", default="")
pr.set_defaults(fn=cmd_report)

a = p.parse_args()
sys.exit(a.fn(a))
