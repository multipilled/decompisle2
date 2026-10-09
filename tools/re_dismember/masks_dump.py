"""Per-body dismember data from the extracted JSON: UDIEngineMaterialMasks bits decoded against the material slots,
and the safe/break/boneend region sockets (with BoneBranchMask). Local data only.
usage: python masks_dump.py [--json out.json]"""
import json
import sys

ROOT = r"extracted\json\DeadIsland\Content\DI2\Art\Characters"
BODIES = {"walker": r"\ZombieMale\Walker\SK_WalkerMaleCas01.json",
          "runner": r"\ZombieMale\Runner\SK_RunnerMaleCas01.json",
          "shambler": r"\ZombieMale\Shambler\SK_ShamMaleCas01.json",
          "thug": r"\ZombieSpecial\Thug\SK_ThugA01.json",
          "screamer": r"\ZombieSpecial\Screamer\SK_Screamer01.json",  # tools/archetype_bodies.py
          "slobber": r"\ZombieSpecial\Slobber\SK_SlobberA.json",
          "butcher": r"\ZombieSpecial\Butcher\SK_Butcher01.json",
          "suicider": r"\ZombieSpecial\Suicider\SK_SuiciderA.json"}
# P2 variant bodies (mesh only, class clips): tools/archetype_bodies.py VARIANTS.
sys.path.insert(0, "tools")
from archetype_bodies import VARIANTS  # noqa: E402
BODIES.update({b: "\\" + v["mesh"].split("Characters/", 1)[1].replace("/", "\\") + ".json" for b, v in VARIANTS.items()})
MASKS = ["HideMask", "InitiallyHiddenMask", "WriteSplatterMask", "CapDismemberMask", "DeformationMask",
         "DismemberMask", "InternalDeformationMask", "SkeletonVisceraMask", "SoftBodyDeformationMask", "ClothingMask",
         "ClothingProxyMask", "ArmourMask", "TrimMask", "TrimHQMask", "RegeneratesMask", "SplatterGroupMask",
         "SplatterClothingGroupMask", "SortBiasMask", "BinaryDismemberMask"]


def main():
    out = {}
    for body, rel in BODIES.items():
        d = json.load(open(ROOT + rel, encoding="utf-8"))
        sk = [o for o in d if o["Type"] == "SkeletalMesh"][0]
        mats = [((m.get("Material") or {}).get("ObjectName") or "None").split("'")[1] if m.get("Material") else "None"
                for m in sk["SkeletalMaterials"]]
        mm = [o for o in d if o["Type"] == "DIEngineMaterialMasks"]
        masks = mm[0]["Properties"]["Masks"] if mm else {}
        socks = []
        for o in d:
            if o["Type"] == "SkeletalMeshSocket":
                p = o["Properties"]
                n = p.get("SocketName", "")
                if "_region" in n:
                    socks.append({"name": n, "bone": p.get("BoneName"), "loc": p.get("RelativeLocation"),
                                  "rot": p.get("RelativeRotation"), "scale": p.get("RelativeScale"),
                                  "branch_mask": p.get("BoneBranchMask", 0)})
        rec = {"materials": mats, "masks": {}, "sockets": socks}
        print(f"== {body}: {len(mats)} material slots, {len(socks)} region sockets")
        for k in MASKS:
            v = masks.get(k, 0)
            bits = [b for b in range(64) if v >> b & 1]
            rec["masks"][k] = {"value": v, "bits": bits}
            if k == "SortBiasMask" or not v:
                continue
            named = [f"{b}:{mats[b]}" if b < len(mats) else str(b) for b in bits]
            if len(bits) > len(mats):          # print the complement when the mask is mostly ones
                clear = [f"{b}:{mats[b]}" for b in range(len(mats)) if not v >> b & 1]
                print(f"   {k:26s} all slots except {clear}")
            else:
                print(f"   {k:26s} {named}")
        out[body] = rec
    if "--json" in sys.argv:
        json.dump(out, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
