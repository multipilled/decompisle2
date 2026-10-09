"""Gun-side animations for every ranged weapon (slide, magazine, pump, bolt...).

DI2 plays each ranged action as two montages: the 1P arms and a `*_Weapon` montage on the gun's own skeleton
(see the "weapon" role in data/classes/<class>.json Shoot / Reload / ... slots). This merges those sequences
onto each gun mesh (game/assets/di2/weapons/<SK>.glb) under the same clip names the class data uses, so the
game plays the pair together.

usage: python tools/build_gun_anims.py
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(r".")
W = json.loads((ROOT / "game/data/weapons.json").read_text())
MESH = ROOT / "extracted/mesh"


def weapon_clips(class_id):
    d = json.loads((ROOT / f"game/data/classes/{class_id}.json").read_text())
    out = set()
    for slot in d["slots"].values():
        for g in slot["groups"]:
            for it in g["items"]:
                r = it.get("weapon")
                if isinstance(r, dict):
                    out.update(r.get("clips", []))
    return sorted(out)


def main():
    done = {}
    by_mesh = {}
    for wid, w in W.items():
        if isinstance(w, dict) and w.get("kind") == "ranged" and w.get("class_id") and w.get("mesh_asset"):
            by_mesh.setdefault(w["mesh_asset"], []).append(w)
    for wid, w in W.items():
        if not isinstance(w, dict) or w.get("kind") != "ranged" or not w.get("class_id") or not w.get("mesh_asset"):
            continue
        mesh = w["mesh_asset"]
        if mesh in done:
            continue
        # Every weapon sharing this gun mesh (e.g. Shotgun and the pre-order Short Shotgun) adds its class's clips.
        clips = {}
        for other in by_mesh[mesh]:
            base_clips = json.loads((ROOT / f"game/assets/di2/dani/classes/{other['base']}.clips.json").read_text())
            clips.update({c: base_clips[c] for c in weapon_clips(other["class_id"]) if c in base_clips})
        src = next(MESH.rglob(f"{mesh}.glb"), None)
        if not clips or not src:
            print(f"{wid:28} {mesh}: no gun clips ({len(clips)}) or mesh ({src})")
            done[mesh] = 0
            continue
        cj = ROOT / f"game/assets/di2/weapons/{mesh}.clips.json"
        cj.write_text(json.dumps(clips, indent=1))
        r = subprocess.run([sys.executable, str(ROOT / "tools/merge_anims.py"), str(src),
                            str(ROOT / f"game/assets/di2/weapons/{mesh}.glb"), str(cj)], capture_output=True, text=True)
        skipped = [l for l in r.stdout.splitlines() if l.startswith("SKIP")]
        done[mesh] = len(clips) - len(skipped)
        print(f"{wid:28} {mesh}: {done[mesh]}/{len(clips)} gun clips" + (f"  ({skipped[:2]})" if skipped else "") + (r.stderr[-300:] if r.returncode else ""))


if __name__ == "__main__":
    main()
