"""Rebuild every first-person weapon-class animation set from the exported DI2 data, end to end:
resolve each class's sequences (montages, level sequences, blend-space samples), export any missing raw clips
from the user's install (di2x rawanim, plus ActorX for UE-codec clips), write the per-base clip lists, merge the
base glbs (game/assets/di2/dani/classes/<base>.glb) and rebuild data/classes/*.json.

usage: python tools/refresh_classes.py [--no-merge]
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
import di2_animsets as A  # noqa: E402

RAW = ROOT / "extracted/rawanim"
SRC = ROOT / "extracted/mesh/DeadIsland/Content/DI2/Art/Characters/Players/FemBerserker/SK_FemBerserkerFP.glb"
OUT = ROOT / "game/assets/di2/dani/classes"


def bs_samples(name):
    return [n for t, n in A.refs(A.load(name) or []) if t == "AnimSequence"]


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, shell=isinstance(cmd, str))


def main():
    data = json.loads((ROOT / "extracted/weapon_classes.json").read_text())
    missing = set()
    for base, v in data.items():
        seqs = set(v["seqs"])
        for c in v["classes"]:
            r = A.resolve_class(c)
            seqs |= set(A.sequences_for(c))
            for slot in r["slots"].values():
                for a in A.slot_montages(slot):
                    if a.startswith("BS_"):
                        seqs |= {s for s in bs_samples(a) if "_1P_" in s}
        v["seqs"] = sorted(seqs)
        missing |= {s for s in seqs if not (RAW / f"{s}.json").exists()}
    (ROOT / "extracted/weapon_classes.json").write_text(json.dumps(data, indent=1))
    print(f"{sum(len(v['seqs']) for v in data.values())} class sequences, {len(missing)} to export")
    if missing:
        lst = ROOT / "extracted/refresh_missing.txt"
        lst.write_text("\n".join(sorted(missing)))
        log = run(f'bash -c "cd . && tools/di2x.sh rawanim @extracted/refresh_missing.txt"').stdout
        ue = [l.split()[1] for l in log.splitlines() if l.startswith("raw") and "FUECompressedAnimData" in l]
        if ue:
            (ROOT / "extracted/refresh_ue.txt").write_text("\n".join(ue))
            run(f'bash -c "cd . && tools/di2x.sh anim @extracted/refresh_ue.txt"')
        print(f"exported {sum(1 for l in log.splitlines() if l.startswith('raw'))} raw clips ({len(ue)} UE codec)")
    for base, v in data.items():
        clips = {}
        for s in v["seqs"]:
            clips.setdefault(re.sub(r"^A_1P_(Base_)?", "", s).lower(), s)
        (OUT / f"{base.lower()}.clips.json").write_text(json.dumps(clips, indent=1))
    if "--no-merge" not in sys.argv:
        for base in data:
            b = base.lower()
            r = run([sys.executable, str(ROOT / "tools/merge_anims.py"), str(SRC), str(OUT / f"{b}.glb"), str(OUT / f"{b}.clips.json")])
            skips = sum(1 for l in r.stdout.splitlines() if l.startswith("SKIP"))
            print(f"  {b:28} merged ({skips} skipped)" + (" ERROR " + r.stderr[-200:] if r.returncode else ""))
    print(run([sys.executable, str(ROOT / "tools/build_class_data.py")]).stdout.splitlines()[-1])


if __name__ == "__main__":
    main()
