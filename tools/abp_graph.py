"""Print a cooked UE 4.27 AnimBlueprint's AnimGraph as a tree (recon/ANIMATION.md).

LinkID = index of the node among the generated class's AnimNode struct properties in ChildProperties order
(verified on ABP_ZombieWalker: UseCachedPose 'MorphTargets'/'Facial' LinkIDs 111/146 = their SaveCachedPose nodes).

usage: python tools/abp_graph.py <ABP json> [--root NodeName] [--depth N]
"""
import json
import sys

SKIP = {"InputPoses", "InputPoseNames", "BlendPoses", "BasePose", "Pose", "Source", "Base", "Additive",
        "LinkToCachingNode", "ComponentPose", "Result", "BlendPose", "SourcePose", "PerBoneBlendWeights",
        "ExposedValueHandlers", "EvaluateGraphExposedInputs", "BlendTime", "BlendProfile", "BlendType",
        "CustomBlendCurve", "StateMachineIndexInClass", "LayerSetup", "SourcePropertyNames", "DestPropertyNames"}


def load(path):
    d = json.load(open(path, encoding="utf-8"))
    cls = next(e for e in d if e["Type"] == "AnimBlueprintGeneratedClass")
    cdo = d[-1]["Properties"]
    names = [c["Name"] for c in cls.get("ChildProperties", [])
             if c.get("Type") == "StructProperty" and "AnimNode" in json.dumps(c.get("Struct", ""))]
    return names, cdo


def links(v):
    """(label, LinkID) pairs of every pose link in a node's properties."""
    out = []

    def walk(x, lab):
        if isinstance(x, dict):
            if "LinkID" in x and len(x) <= 2:
                out.append((lab, x["LinkID"]))
                return
            for k, y in x.items():
                walk(y, k)
        elif isinstance(x, list):
            for i, y in enumerate(x):
                walk(y, f"{lab}[{i}]")
    walk(v, "")
    return out


def brief(v):
    out = {}
    for k, x in v.items():
        if k in SKIP or isinstance(x, (dict, list)) and k not in ("BranchFilters", "BlendWeights", "LayerSetup"):
            if k == "LayerSetup":
                out[k] = x
            continue
        out[k] = x
    if "LayerSetup" in v:
        out["LayerSetup"] = [[(f["BoneName"], f["BlendDepth"]) for f in l.get("BranchFilters", [])]
                             for l in v["LayerSetup"]]
    if "BlendWeights" in v:
        out["BlendWeights"] = v["BlendWeights"]
    return out


def main():
    path = sys.argv[1]
    root = sys.argv[sys.argv.index("--root") + 1] if "--root" in sys.argv else "AnimGraphNode_Root"
    depth = int(sys.argv[sys.argv.index("--depth") + 1]) if "--depth" in sys.argv else 99
    names, cdo = load(path)
    seen = set()

    def show(name, lab, ind):
        v = cdo.get(name, {})
        print("  " * ind + f"{lab}: {name} {json.dumps(brief(v))[:400]}")
        if name in seen or ind >= depth:
            return
        seen.add(name)
        for l, i in links(v):
            if 0 <= i < len(names):
                show(names[i], l, ind + 1)
    show(root, "root", 0)


if __name__ == "__main__":
    main()
