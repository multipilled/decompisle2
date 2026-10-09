"""Mouth-follows-voice check for an anim capture (scripts/anim_capture.gd z_face) with zombie voices running.

usage: python -I tools/zaudio/face_report.py <capture_dir> [voice.jsonl]
Per watched zombie segment: frames, mouth_db range, the lowerJaw rotation in head space relative to its pose at the
-48 dB floor, and the Pearson correlation of jaw angle with the DI2 mouth input 2^((dB + 48) / 10) (ZombieAnim
FaceLayer.mouth_input, recon/ANIMATION.md 7.2). The voice log lists the lines each zombie played.
"""
import json
import math
import sys
from pathlib import Path


def qangle(a, b):
    d = abs(sum(x * y for x, y in zip(a, b)))
    return math.degrees(2.0 * math.acos(min(1.0, d)))


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    sx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    sy = math.sqrt(sum((y - my) ** 2 for y in ys))
    if sx == 0 or sy == 0:
        return float("nan")
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (sx * sy)


def main(argv):
    cap = Path(argv[0])
    recs = [json.loads(l) for l in (cap / "anim" / "z_face.jsonl").read_text().splitlines() if l.strip()]
    segs = []
    cur = None
    for r in recs:
        zs = r.get("z") or []
        z = zs[0] if zs else {}
        face = z.get("face")
        fb = z.get("fb", {})
        if r.get("mark"):
            cur = {"mark": r["mark"], "rows": []}
            segs.append(cur)
        if cur is None or face is None or "lowerJaw" not in fb:
            continue
        if float(face.get("w", 1.0)) < 0.999:
            continue   # facial layer off / blending in: the mouth layer doesn't drive the jaw yet
        bs = face.get("bs") or [1.0]
        cur["rows"].append((r["f"], float(face["db"]), fb["lowerJaw"][3:7], 1.0 - float(bs[0])))
    for s in segs:
        rows = s["rows"]
        if len(rows) < 10:
            continue
        # reference: the segment's most closed mouth (smallest non-Base blend-space weight)
        ref = min(rows, key=lambda r: r[3])[2]
        dbs = [r[1] for r in rows]
        ang = [qangle(r[2], ref) for r in rows]
        opn = [r[3] for r in rows]
        inp = [2.0 ** ((db + 48.0) / 10.0) for db in dbs]
        # FaceLayer blends the mouth samples at 7/s (BS TargetWeightInterpolationSpeedPerSec): best lag 0..20 frames
        def lagged(a, b):
            return max(((pearson(a[:len(a) - k] if k else a, b[k:]), k) for k in range(0, 21)),
                       key=lambda t: (t[0] if t[0] == t[0] else -2))
        bj, bo = lagged(inp, ang), lagged(inp, opn)
        print(f"{s['mark']}: {len(rows)} frames, db {min(dbs):.1f}..{max(dbs):.1f}, jaw {min(ang):.1f}..{max(ang):.1f} deg, "
              f"corr(jaw, mouth input) {bj[0]:.3f} @ lag {bj[1]}, corr(open weight, input) {bo[0]:.3f} @ lag {bo[1]}")
    if len(argv) > 1 and Path(argv[1]).exists():
        for l in Path(argv[1]).read_text().splitlines():
            if not l.strip():
                continue
            v = json.loads(l)
            print(f"voice {v['family']} {v['voice']}: {len(v['lines'])} lines")
            for ln in v["lines"][:12]:
                print("   ", ln)


if __name__ == "__main__":
    main(sys.argv[1:])
