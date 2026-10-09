"""Group DI2's pak file list (extracted/files.txt) by gameplay / UI keyword and folder.

Usage: python tools/re_ui/inventory.py [out.txt]
Writes, per keyword, the folders holding matching .uasset names with counts and three sample names.
Read-only over extracted/files.txt; output defaults to extracted/re_ui/inventory.txt (never committed).
"""
import collections
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FILES = os.path.join(ROOT, "extracted", "files.txt")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "extracted", "re_ui", "inventory.txt")

KEYS = ["SkillCard", "Skill", "Perk", "Curveball", "WeaponMod", "Craft", "Blueprint", "Loot", "Pickup",
        "Medkit", "Stamina", "Dodge", "Block", "Kick", "Sprint", "Jump", "Vault", "Crouch", "Slide", "Fury",
        "Workbench", "Inventory", "Backpack", "Respawn", "Death", "Ammo", "Durability", "Health", "Progression",
        "XP", "Horde", "Wave", "Ability", "Throwable", "SWF_", "WBP_", "GFx", "Menu", "Pause", "Options",
        "Settings", "Map", "Journal", "Hint", "Tutorial", "Interact", "Container", "Cash", "Currency", "Trader"]

def main():
    rows = [l.strip() for l in open(FILES, encoding="utf-8", errors="replace") if l.strip().endswith(".uasset")]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as o:
        for k in KEYS:
            rx = re.compile(re.escape(k), re.I) if not k.endswith("_") else re.compile("^" + re.escape(k))
            folders = collections.defaultdict(list)
            for p in rows:
                d, n = p.rsplit("/", 1)
                if rx.search(n[:-7]):
                    # Animation clips swamp most movement keys; keep them in one bucket.
                    if "/Animation" in d or "/Anim/" in d or n.startswith(("A_", "AM_", "AS_", "BS_")):
                        d = "<animation assets>"
                    folders[d].append(n[:-7])
            total = sum(len(v) for v in folders.values())
            o.write("## %s  (%d assets, %d folders)\n" % (k, total, len(folders)))
            for d, ns in sorted(folders.items(), key=lambda kv: -len(kv[1]))[:14]:
                o.write("  %4d %s  e.g. %s\n" % (len(ns), d.replace("DeadIsland/Content/", ""), ", ".join(ns[:3])))
    print(OUT)

main()
