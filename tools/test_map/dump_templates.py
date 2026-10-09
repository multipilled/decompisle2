"""Dump (tools/di2x.sh json) every Blueprint package the levels' components inherit from (level.merged_props'
Template chain), repeating until the chain is complete. Heavy (mounts the paks): run through tools/with_cpu.sh.

    python tools/test_map/dump_templates.py <level package> ...
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import level as L  # noqa: E402

ROOT = L.ROOT
DI2X = os.path.join(ROOT, "tools", "di2x", "bin", "out", "di2x.exe")
ENV = dict(os.environ, DOTNET_ROOT=os.path.join(ROOT, "tools", "dotnet10"), MSYS_NO_PATHCONV="1")


def scan(pkgs):
    for pkg in pkgs:
        lv = L.Level(pkg)
        for i, e in enumerate(lv.exports):
            if e.get("Type", "").endswith("Component"):
                lv.props(i)
                for m in lv.props(i).get("OverrideMaterials") or []:
                    lv.asset_material(m)


def main(pkgs):
    tried = set()
    for rnd in range(8):
        L.MISSING_TEMPLATES.clear()
        L._TEMPLATE_PKGS.clear()
        scan(pkgs)
        todo = sorted(L.MISSING_TEMPLATES - tried)
        print("round %d: %d template packages missing" % (rnd, len(todo)))
        if not todo:
            break
        tried.update(todo)
        lst = os.path.join(ROOT, "extracted", "test_map", "template_json_missing.txt")
        open(lst, "w").write("\n".join(os.path.basename(p)[:-7] for p in todo))  # di2x @file: asset names
        r = subprocess.run([DI2X, "json", "@" + lst], env=ENV, capture_output=True, text=True)
        print("\n".join(l for l in r.stdout.splitlines() if not l.startswith("ok"))[-1500:])
    left = sorted(L.MISSING_TEMPLATES)
    print("still missing: %d %s" % (len(left), left[:10]))


if __name__ == "__main__":
    main(sys.argv[1:])
