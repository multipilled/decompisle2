"""DI2 character initial states -> game/data/character_states.json.

Each DI2 skeletal mesh carries a CharacterInitialStateWrapper (asset user data) with the zombie's starting look:
  InitialSplatterSetVariants  the stored wound sets it spawns with (one variant per spawn)
  MaterialVariants            alternative outfits: lists of {source material -> replacement material}
  InitialAttachmentSpec       a hat / accessory attachment
  SpawnableParts, VisceraAsset   the gore parts and viscera it uses
  Left/Right/OtherFootwearType, FoleyClothingType   audio types
usage: python tools/build_character_states.py
"""
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(r".")
sys.path.insert(0, str(ROOT / "tools"))
import di2_animsets as A  # noqa: E402

# Bodies the recreation ships (game/assets/di2/<folder>), see zombie.gd BODIES.
BODIES = {"walker": "SK_WalkerMaleCas01", "runner": "SK_RunnerMaleCas01", "shambler": "SK_ShamMaleCas01", "thug": "SK_ThugA01"}
BODIES.update({"screamer": "SK_Screamer01", "slobber": "SK_SlobberA", "butcher": "SK_Butcher01", "suicider": "SK_SuiciderA"})  # special archetypes (tools/archetype_bodies.py)
from archetype_bodies import VARIANTS  # noqa: E402  P2 variant bodies (mesh only, class clips)
BODIES.update({b: Path(v["mesh"]).name for b, v in VARIANTS.items()})


def name(ref):
    m = re.search(r"'([^']+)'", (ref or {}).get("ObjectName", ""))
    return m.group(1).split(":")[-1] if m else None


def attachment(spec_name, folder):
    """AttachmentSpecAsset -> its static-mesh children: mesh glb (exported with di2x, packed next to the body), the
    socket / bone and the relative transform converted to the glb skeleton's space (UE (x, y, z) cm -> (x, z, y) m,
    quaternion (x, z, y, -w): the same mirror the meshes and skeletons go through)."""
    d = A.load(spec_name) or []
    out = []
    for e in d:
        if e["Type"] != "StaticMeshAttachmentSpec":
            continue
        p = e["Properties"]
        mesh = name(p.get("Mesh"))
        loc = p.get("Location", {})
        t, q, sc = loc.get("Translation", {}), loc.get("Rotation", {}), loc.get("Scale3D", {"X": 1, "Y": 1, "Z": 1})
        glb = next(ROOT.glob(f"extracted/mesh/**/{mesh}.glb"), None)
        if glb is None:
            subprocess.run(["bash", str(ROOT / "tools/di2x.sh"), "mesh", f"/{mesh}\."], cwd=ROOT, capture_output=True)
            glb = next(ROOT.glob(f"extracted/mesh/**/{mesh}.glb"), None)
        rel = None
        if glb:
            dst = ROOT / "game/assets/di2" / folder / "attachments"
            dst.mkdir(parents=True, exist_ok=True)
            shutil.copy2(glb, dst / glb.name)
            subprocess.run([sys.executable, str(ROOT / "tools/pack_materials.py"), str(dst / glb.name)], cwd=ROOT, capture_output=True)
            rel = f"res://assets/di2/{folder}/attachments/{glb.name}"
        out.append({
            "name": p.get("Name"), "mesh": mesh, "glb": rel, "socket": p.get("SocketName"),
            "origin": [t.get("X", 0) * 0.01, t.get("Z", 0) * 0.01, t.get("Y", 0) * 0.01],
            "quat": [q.get("X", 0), q.get("Z", 0), q.get("Y", 0), -q.get("W", 1)],
            "scale": [sc.get("X", 1), sc.get("Z", 1), sc.get("Y", 1)],
            "actor": name(p.get("ActorClass")),
        })
    return out


def main():
    out = {}
    for folder, sk in BODIES.items():
        d = A.load(sk) or []
        st = next((e["Properties"]["State"] for e in d if e["Type"] == "CharacterInitialStateWrapper"), None)
        if st is None:
            print(f"{folder}: {sk} has no initial state")
            continue
        out[folder] = {
            "mesh": sk,
            "splatter_variants": [{"set": name(v.get("SplatterSet")), "activated_slots": v.get("ActivatedSlots", [])}
                                  for v in st.get("InitialSplatterSetVariants", [])],
            "material_variants": [[{"source": name(s.get("SourceMaterial")), "replacement": name(s.get("ReplacementMaterial"))}
                                   for s in v.get("Substitutions", [])] for v in st.get("MaterialVariants", [])],
            "attachment": name(st.get("InitialAttachmentSpec")),
            "attachment_parts": attachment(name(st.get("InitialAttachmentSpec")), folder) if st.get("InitialAttachmentSpec") else [],
            "spawnable_parts": name(st.get("SpawnableParts")),
            "viscera": name(st.get("VisceraAsset")),
            "footwear": [str(st.get(k, "")).split("::")[-1] for k in ("LeftFootwearType", "RightFootwearType", "OtherFootwearType")],
            "foley": str(st.get("FoleyClothingType", "")).split("::")[-1],
        }
        print(folder, sk, len(out[folder]["splatter_variants"]), "splatter variants,",
              len(out[folder]["material_variants"]), "material variants, attachment", out[folder]["attachment"])
    (ROOT / "game/data/character_states.json").write_text(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
