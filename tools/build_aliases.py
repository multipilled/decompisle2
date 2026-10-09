"""DI2 expression aliases (DT_ExpressionAliases_* tables: Combat, BodyContext, Enemies_*, Attachments, ...)
-> game/data/expression_aliases.json {name: expression}. ClassData evaluates `#Name` through these, so every
selection fact (ScalpContext, DownContext, KnockbackLowKick, HeavyGroundContext, ...) is DI2's own definition.
usage: python tools/build_aliases.py"""
import glob
import json
import os

rows = {}
for f in sorted(glob.glob(r"extracted\json\**\*xpression*lias*.json", recursive=True)):
    for e in json.load(open(f, encoding="utf-8")):
        for k, v in (e.get("Rows") or e.get("Properties", {}).get("Rows") or {}).items():
            expr = v.get("Expression", {}).get("Expression", "") if isinstance(v, dict) else ""
            if expr:
                rows[k] = expr
json.dump(rows, open(r"game\data\expression_aliases.json", "w"), indent=1, sort_keys=True)
print(len(rows), "aliases")
