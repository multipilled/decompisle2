"""Metrics + contact sheets for scripts/anim_capture.gd captures (recon/ANIMATION.md).

usage: python tools/anim_report.py <capture_dir> [--sheets] [--compare <other_capture_dir>]

Per scenario (<dir>/anim/<scenario>.jsonl, one record per 1/60 s frame):
  * pops: the largest per-frame second differences of the watched bones (camera space for Dani's rig, world space
    for zombies): |x[t+1] - 2 x[t] + x[t-1]| in cm and the same for rotation in degrees. A clean 30 Hz clip sampled
    at 60 Hz stays small; a hard cut, a section jump or a snapped blend shows as a spike. Listed with the clip /
    state on both sides so cuts can be attributed.
  * foot slide (zombies): horizontal speed of each foot while it is planted, in cm/s. Planted = the ball within
    3 cm of its lowest height in a 1 s window, moving vertically under 30 cm/s (not lifting or still touching down), and not swinging: its horizontal velocity relative to the
    pelvis along the facing direction is <= 5 cm/s. Shuffling gaits (walk_slow / walk_med lift the ball only 3-8 cm)
    pass the height test during their swing; the swing foot moves forward past the pelvis, a stance foot (planted or
    sliding) moves back relative to it, so the relative test keeps only stance frames. Frames with a montage weighted over 0.05 are skipped: the metric
    measures the locomotion layer.
  * --sheets: contact sheets of the frame strips around each mark (<dir>/sheets/<scenario>_<mark>.png).
"""
import json
import math
import sys
from pathlib import Path

import numpy as np


def load(path):
    return [json.loads(l) for l in Path(path).read_text().splitlines() if l.strip()]


def quat_angle(a, b):
    d = abs(float(np.dot(a, b)))
    return math.degrees(2.0 * math.acos(min(1.0, d)))


def series(recs, get):
    out = []
    for r in recs:
        v = get(r)
        out.append(np.array(v, dtype=np.float64) if v is not None else None)
    return out


def pops(recs, get, label_of, top=8):
    """Largest positional (cm) and angular (deg) second differences."""
    xs = series(recs, get)
    ev = []
    for i in range(1, len(xs) - 1):
        a, b, c = xs[i - 1], xs[i], xs[i + 1]
        if a is None or b is None or c is None:
            continue
        acc = np.linalg.norm(c[:3] - 2 * b[:3] + a[:3]) * 100.0
        # Angular: change of the per-frame rotation step.
        w1 = quat_angle(a[3:7], b[3:7])
        w2 = quat_angle(b[3:7], c[3:7])
        ev.append((acc, abs(w2 - w1), i))
    by_pos = sorted(ev, key=lambda e: -e[0])[:top]
    by_rot = sorted(ev, key=lambda e: -e[1])[:top]
    med_p = float(np.median([e[0] for e in ev])) if ev else 0.0
    med_r = float(np.median([e[1] for e in ev])) if ev else 0.0
    return by_pos, by_rot, med_p, med_r


def p_label(recs, i):
    r = recs[i]
    return f"{r.get('p_anim', '')}@{r.get('p_pos', 0):.2f} {r.get('p_state', '')}/{r.get('p_phase', '')}"


def z_label(recs, i, zi=0):
    z = recs[i]["z"][zi] if zi < len(recs[i].get("z", [])) else {}
    return f"{z.get('anim', '')}@{z.get('apos', 0):.2f} x{z.get('speed_scale', 1):.2f} {z.get('react', '')}"


def foot_slide(recs, zi=0, foot="ball_l", frm=0):
    pts, pel, yaw = [], [], []
    for r in recs:
        zs = r.get("z", [])
        if zi >= len(zs) or not zs[zi] or zs[zi].get("dead"):
            pts.append(None)
            pel.append(None)
            yaw.append(0.0)
            continue
        if any(m[2] > 0.05 for m in zs[zi].get("mon", [])):
            pts.append(None)   # a montage drives the feet (attack root motion isn't applied; recon/ANIMATION.md 9.4)
            pel.append(None)
            yaw.append(0.0)
            continue
        b = zs[zi]["b"].get(foot)
        pv = zs[zi]["b"].get("pelvis")
        pts.append(np.array(b[:3]) if b else None)
        pel.append(np.array(pv[:3]) if pv else None)
        yaw.append(float(zs[zi].get("node", [0, 0, 0, 0])[3]))
    speeds = []
    n = len(pts)
    for i in range(max(1, frm), n):
        if pts[i] is None or pts[i - 1] is None:
            continue
        lo = min(p[1] for p in pts[max(0, i - 30):min(n, i + 30)] if p is not None)
        if pts[i][1] - lo < 0.03 and abs(pts[i][1] - pts[i - 1][1]) * 60.0 < 0.3:
            d = pts[i] - pts[i - 1]
            if pel[i] is not None and pel[i - 1] is not None:
                rel = d - (pel[i] - pel[i - 1])
                fwd = (-math.sin(yaw[i]), -math.cos(yaw[i]))   # Godot facing (-Z rotated by the node's yaw)
                if (rel[0] * fwd[0] + rel[2] * fwd[1]) * 60.0 * 100.0 > 5.0:
                    continue   # swinging forward past the pelvis
            speeds.append(math.hypot(d[0], d[2]) * 60.0 * 100.0)
    if not speeds:
        return None
    return {"planted_frames": len(speeds), "mean_cm_s": round(float(np.mean(speeds)), 1),
            "p90_cm_s": round(float(np.percentile(speeds, 90)), 1), "max_cm_s": round(float(np.max(speeds)), 1)}


def z_transitions(recs, bone, window=(-1, 6)):
    """Same as transitions() for the first watched zombie (world space, clip = its dominant clip)."""
    def pos(r):
        z = r.get("z") or [{}]
        z = z[0] or {}
        b = z.get("b", {}).get(bone) if not z.get("dead") else None
        return np.array(b[:3]) if b else None
    xs = [pos(r) for r in recs]
    d2 = [0.0] * len(xs)
    for i in range(1, len(xs) - 1):
        if xs[i - 1] is not None and xs[i] is not None and xs[i + 1] is not None:
            d2[i] = float(np.linalg.norm(xs[i + 1] - 2 * xs[i] + xs[i - 1]) * 100.0)
    clip = lambda r: ((r.get("z") or [{}])[0] or {}).get("anim")
    out = []
    prev = clip(recs[0]) if recs else None
    for i, r in enumerate(recs):
        a = clip(r)
        if a != prev and i > 0 and a:
            lo, hi = max(1, i + window[0]), min(len(recs) - 1, i + window[1])
            k = max(range(lo, hi), key=lambda j: d2[j]) if hi > lo else i
            out.append((round(d2[k], 2), k, prev, a))
        prev = a
    return sorted(out, key=lambda e: -e[0]), float(np.median(d2)) if d2 else 0.0


def transitions(recs, bone, window=(-1, 6)):
    """Largest positional second difference (cm) of `bone` (Dani's rig) right after every clip switch: the frames
    where a cut or a snapped blend shows. Returns [(spike_cm, frame, from_clip, to_clip)] sorted, plus the median
    in-clip value for scale."""
    xs = series(recs, lambda r: r["p"].get(bone))
    d2 = [0.0] * len(xs)
    for i in range(1, len(xs) - 1):
        if xs[i - 1] is not None and xs[i] is not None and xs[i + 1] is not None:
            d2[i] = float(np.linalg.norm(xs[i + 1][:3] - 2 * xs[i][:3] + xs[i - 1][:3]) * 100.0)
    out = []
    prev = recs[0].get("p_anim") if recs else None
    for i, r in enumerate(recs):
        a = r.get("p_anim")
        if a != prev and i > 0:
            lo, hi = max(1, i + window[0]), min(len(recs) - 1, i + window[1])
            k = max(range(lo, hi), key=lambda j: d2[j]) if hi > lo else i
            out.append((round(d2[k], 2), k, prev, a))
        prev = a
    return sorted(out, key=lambda e: -e[0]), float(np.median(d2)) if d2 else 0.0


def anim_switches(recs, key):
    out = []
    prev = None
    for i, r in enumerate(recs):
        a = key(r)
        if a != prev:
            out.append((i, a))
            prev = a
    return out


def report(capdir):
    capdir = Path(capdir)
    res = {}
    lines = []
    for f in sorted((capdir / "anim").glob("*.jsonl")):
        recs = load(f)
        name = f.stem
        lines.append(f"## {name} ({len(recs)} frames)")
        entry = {}
        marks = [(i, r["mark"]) for i, r in enumerate(recs) if r.get("mark")]
        if marks:
            lines.append("marks: " + ", ".join(f"f{i} {m}" for i, m in marks))
        if name.startswith("p_"):
            for bone in ("weapon_01_r", "hand_r", "hand_l"):
                bp, br, mp, mr = pops(recs, lambda r: r["p"].get(bone), p_label)
                entry[bone] = {"median_cm": round(mp, 3), "median_deg": round(mr, 3),
                               "top_cm": [[round(a, 2), i] for a, _, i in bp], "top_deg": [[round(b, 2), i] for _, b, i in br]}
                lines.append(f"{bone}: median d2x {mp:.3f} cm, d2rot {mr:.3f} deg")
                for a, b, i in bp[:5]:
                    lines.append(f"   pos spike {a:6.2f} cm  rot {b:5.2f} deg  f{i}  {p_label(recs, i - 1)}  ->  {p_label(recs, i)}  ->  {p_label(recs, i + 1)}")
                for a, b, i in br[:3]:
                    lines.append(f"   rot spike {b:6.2f} deg pos {a:5.2f} cm  f{i}  {p_label(recs, i - 1)}  ->  {p_label(recs, i)}  ->  {p_label(recs, i + 1)}")
            tr, med = transitions(recs, "hand_r")
            entry["transitions_hand_r"] = [[a, f, x, y] for a, f, x, y in tr]
            lines.append(f"clip-switch spikes hand_r (median frame {med:.2f} cm): " + "; ".join(f"{a:.1f}cm f{f} {x}->{y}" for a, f, x, y in tr[:8]))
            sw = anim_switches(recs, lambda r: r.get("p_anim"))
            lines.append("clips: " + " | ".join(f"f{i} {a}" for i, a in sw))
        else:
            for bone in ("pelvis", "head", "hand_r", "foot_l"):
                bp, br, mp, mr = pops(recs, lambda r: (r["z"][0]["b"].get(bone) if r.get("z") and r["z"][0] and not r["z"][0].get("dead") else None), z_label)
                entry[bone] = {"median_cm": round(mp, 3), "median_deg": round(mr, 3),
                               "top_cm": [[round(a, 2), i] for a, _, i in bp], "top_deg": [[round(b, 2), i] for _, b, i in br]}
                lines.append(f"{bone}: median d2x {mp:.3f} cm, d2rot {mr:.3f} deg")
                for a, b, i in bp[:4]:
                    lines.append(f"   pos spike {a:6.2f} cm  rot {b:5.2f} deg  f{i}  {z_label(recs, i - 1)}  ->  {z_label(recs, i)}  ->  {z_label(recs, i + 1)}")
            for bone in ("head", "hand_r"):
                tr, med = z_transitions(recs, bone)
                entry["transitions_" + bone] = [[a, f, x, y] for a, f, x, y in tr]
                lines.append(f"clip-switch spikes {bone}: " + "; ".join(f"{a:.1f}cm f{f} {x}->{y}" for a, f, x, y in tr[:6]))
            for foot in ("ball_l", "ball_r"):
                fs = foot_slide(recs, 0, foot)
                entry["slide_" + foot] = fs
                lines.append(f"slide {foot}: {fs}")
            sw = anim_switches(recs, lambda r: (r["z"][0].get("anim") if r.get("z") and r["z"][0] else None))
            lines.append("clips: " + " | ".join(f"f{i} {a}" for i, a in sw))
        res[name] = entry
        lines.append("")
    (capdir / "report.txt").write_text("\n".join(lines))
    (capdir / "report.json").write_text(json.dumps(res, indent=1))
    return res, lines


def sheets(capdir, cols=8, span=(-4, 44), step=2):
    from PIL import Image, ImageDraw
    capdir = Path(capdir)
    out = capdir / "sheets"
    out.mkdir(exist_ok=True)
    for f in sorted((capdir / "anim").glob("*.jsonl")):
        recs = load(f)
        strip = capdir / "strips" / f.stem
        marks = [(i, r["mark"]) for i, r in enumerate(recs) if r.get("mark")]
        for mi, (m, label) in enumerate(marks):
            frames = [i for i in range(m + span[0], m + span[1], step) if (strip / f"f{i:04d}.png").exists()]
            if not frames:
                # Strips taken every 2nd frame: shift by one.
                frames = [i for i in range(m + span[0] + 1, m + span[1], step) if (strip / f"f{i:04d}.png").exists()]
            if not frames:
                continue
            w, h = 320, 180
            rows = (len(frames) + cols - 1) // cols
            sheet = Image.new("RGB", (cols * w, rows * (h + 14)), (20, 20, 20))
            d = ImageDraw.Draw(sheet)
            for k, i in enumerate(frames):
                im = Image.open(strip / f"f{i:04d}.png").resize((w, h))
                x, y = (k % cols) * w, (k // cols) * (h + 14)
                sheet.paste(im, (x, y + 14))
                lab = p_label(recs, i) if f.stem.startswith("p_") else z_label(recs, i)
                d.text((x + 2, y), f"f{i} {lab}"[:52], fill=(230, 230, 120))
            safe = "".join(c if c.isalnum() else "_" for c in label)[:30]
            sheet.save(out / f"{f.stem}_{mi:02d}_{safe}.png")


if __name__ == "__main__":
    d = sys.argv[1]
    _, lines = report(d)
    print("\n".join(lines))
    if "--sheets" in sys.argv:
        sheets(d)
