"""Print a DI2 AI deck (DA_Deck_*: a tree of CardGenerator_* sub-objects) as an indented tree.

usage: python tools/re_ai/deck_tree.py <asset name or dump.json>
Each node shows its generator class and its own leaf properties; child generators are expanded in place.
"""
import json
import re
import sys

from ue_flat import find, walk


SKIP = {"ParentNode", "TreeAsset"}


def full(e):
    o = e.get("Outer")
    if isinstance(o, dict):
        m = re.match(r"\w+'[^:]*:(.*)'", o["ObjectName"])
        if m:
            return m.group(1) + "." + e["Name"]
    return e["Name"]


def main():
    exps = json.load(open(find(sys.argv[1]), encoding="utf-8"))
    by = {full(e): e for e in exps}
    seen = set()

    def show(key, ind, label=""):
        e = by.get(key)
        if key in seen:
            print(" " * ind + label + "(see above) " + key)
            return
        if e is None:
            print(" " * ind + label + "?? " + key)
            return
        seen.add(key)
        lines = []
        walk(e.get("Properties", {}), "", lines)
        own, kids = [], []
        for p, v in lines:
            if p.split(".")[-1] in SKIP or p.endswith("NodeName") and not v:
                continue
            if isinstance(v, str) and v.startswith("@") and ":" in v and v[1:].split(":", 1)[1] in by:
                kids.append((p, v[1:].split(":", 1)[1]))
            else:
                own.append(f"{p}={v}")
        t = e["Type"].replace("CardGenerator_", "").replace("BP_CardGenerator_", "")
        print(" " * ind + label + t + ("  " + "; ".join(own) if own else ""))
        for p, k in kids:
            show(k, ind + 2, p + ": ")

    roots = [full(e) for e in exps if not e.get("Outer")]
    for r in roots:
        show(r, 0)
    for k in by:
        if k not in seen:
            print("UNREACHED", k)


if __name__ == "__main__":
    main()
