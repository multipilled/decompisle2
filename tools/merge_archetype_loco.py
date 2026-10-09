"""Merge-only locomotion speeds for archetypes that got their own DI2 body (coordinator decision 2026-10-08,
recon/ARCHETYPES.md): every game/data/archetypes.json row whose name starts with a family below takes
locomotion.walk_speed / chase_speed / crawl_speed from its body's clip root motion, measured by tools/merge_anims.py into
game/assets/di2/<body>/<body>.anims.json, the same rule as tools/convert_archetypes.py (walk = walk_slow, chase = walk,
crawl = crawl). Every other field is left as it is. A body without a `crawl` clip (the Butcher: no crawler locomotion in
its data) keeps its current crawl_speed.

Stats (coordinator decision 2026-10-08, recon/ARCHETYPES.md "archetypes.json provenance"): rows of STAT_FAMILIES also
take health, base_force, knockdown_duration and attacks[].damage / cooldown from a dry run of tools/convert_archetypes.py
(written to game/test_out/archetypes/converter_dryrun.json, never to archetypes.json). The converter reads them from
DA_AIAttributeValues_<Class> (MaxHealthAttribute, BaseForceAttribute, KnockdownDuration, BaseDamageAttribute,
AttackSpacingDuration; <Class> = the row name before the first "_"), except that a row with its own
DA_AIAttributeValues_<Row> asset reads that one. Nothing else in the file changes.

Variant rows (P2, coordinator decision 2026-10-09): every tools/archetype_bodies.py VARIANTS entry gets its own row
(name = the variant's "archetype", e.g. Walker_Burning), a copy of its class row (Walker / Runner). Source: no variant
has a DA_AIAttributeValues_<Class>_<Variant> or BPC_MultiPartHealth_<Class>_<Variant> asset in extracted/json, and its
Blueprint's AICharacterAttributesComponent overrides no attribute, so DI2 uses BP_Base_<Class>'s components and
DA_AIAttributeValues_<Class>. The row also records the Blueprint's SubArchetypeSpecificFacts and Archetype /
SubArchetypeSpecificPerks (data for the elemental behaviours, Q15; nothing reads them yet). Only those rows change.

usage: python tools/merge_archetype_loco.py
"""
import copy
import json
from pathlib import Path

ROOT = Path(r".")
OUT = ROOT / "game" / "data" / "archetypes.json"
FAMILIES = ("Screamer", "Slobber", "Butcher", "Suicider")   # tools/archetype_bodies.py bodies
KEYS = {"walk_speed": "walk_slow", "chase_speed": "walk", "crawl_speed": "crawl"}
STAT_FAMILIES = ("Screamer", "Slobber", "Butcher", "Suicider", "Mutator", "Whipper")
DRYRUN = ROOT / "game" / "test_out" / "archetypes" / "converter_dryrun.json"


import sys
sys.path.insert(0, str(ROOT / "tools"))
import convert_archetypes as C  # noqa: E402


def type_default(attr):
    """An attribute left on bUseTypeDefaultValue takes DA_AttributeType_<attr>.DefaultValue (e.g. AttackSpacingDuration
    1.0), not the class asset's value."""
    p = next((ROOT / "extracted/json").rglob(f"DA_AttributeType_{attr}.json"))
    return float(json.loads(p.read_text(encoding="utf-8"))[0]["Properties"]["DefaultValue"])


def converter_rows():
    DRYRUN.parent.mkdir(parents=True, exist_ok=True)
    C.OUT = DRYRUN
    C.main()
    return {r["name"]: r for r in json.loads(DRYRUN.read_text())}


def merge_stats(rows):
    conv = converter_rows()
    for r in rows:
        if not r["name"].startswith(STAT_FAMILIES) or r["name"] not in conv:
            continue
        c = conv[r["name"]]
        # A sub-variant with its own DA_AIAttributeValues_<Row> (e.g. Screamer_HausReveal) reads that asset; the
        # converter only reads the class asset (coordinator, 2026-10-08).
        own = C.ai_attributes(r["name"]) if "_" in r["name"] else {}
        if own:
            limb = c["limb_health"]
            c = dict(c, health=float(own.get("health") or limb), base_force=own.get("force"),
                     knockdown_duration=own.get("knockdown") or c["knockdown_duration"],
                     attacks=C.attacks(1.0, float(own.get("damage") or 12.0), float(own.get("spacing") or type_default("AttackSpacingDuration"))))
            print(f"  {r['name']:22} reads DA_AIAttributeValues_{r['name']}")
        before = (r["health"], r.get("base_force"), r.get("knockdown_duration"))
        for k in ("health", "base_force", "knockdown_duration"):
            r[k] = c[k]
        cards = {a["name"]: a for a in c["attacks"]}
        for a in r["attacks"]:
            if a["name"] in cards:
                a["damage"], a["cooldown"] = cards[a["name"]]["damage"], cards[a["name"]]["cooldown"]
        print(f"  {r['name']:22} health/force/knockdown {before} -> {(r['health'], r['base_force'], r['knockdown_duration'])}")


def variant_props(bp):
    """The variant Blueprint's facts and perks (Default__<BP>_C), each perk as its DA_PerkDefinition name."""
    path = next((ROOT / "extracted/json").rglob(f"{bp}.json"))
    cdo = next(e for e in json.loads(path.read_text(encoding="utf-8")) if e["Name"].startswith("Default__"))
    p = cdo.get("Properties") or {}
    names = lambda k: [str(x.get("ObjectName", "")).split("'")[1] if "'" in str(x.get("ObjectName", "")) else x.get("NameStorage")
                       for x in p.get(k, [])]
    return str(path.relative_to(ROOT / "extracted/json/DeadIsland/Content")).replace("\\", "/"), {
        "facts": names("SubArchetypeSpecificFacts"),
        "perks": names("ArchetypeSpecificPerks") + names("SubArchetypeSpecificPerks")}


def merge_variants(rows):
    from archetype_bodies import built  # rows for the variant bodies built so far
    by_name = {r["name"]: r for r in rows}
    for body, v in built().items():
        src, props = variant_props(v.get("bp", "BP_" + v["archetype"]))
        row = copy.deepcopy(by_name[v["class"]])
        row.update(name=v["archetype"], source=src, variant_of=v["class"], body=body, **props)
        if v["archetype"] in by_name:
            rows[rows.index(by_name[v["archetype"]])] = row
        else:
            rows.append(row)
        print(f"  {v['archetype']:22} = {v['class']} stats, facts {props['facts']}, {len(props['perks'])} perks")


def main():
    raw = OUT.read_text(encoding="utf-8")
    rows = json.loads(raw)
    for fam in FAMILIES:
        rep = json.loads((ROOT / "game/assets/di2" / fam.lower() / f"{fam.lower()}.anims.json").read_text())
        for r in rows:
            if not r["name"].startswith(fam):
                continue
            before = dict(r["locomotion"])
            for key, clip in KEYS.items():
                if clip in rep:
                    r["locomotion"][key] = rep[clip]["root_speed"]
            print(f"  {r['name']:22} {before} -> {r['locomotion']}")
    merge_stats(rows)
    merge_variants(rows)
    OUT.write_text(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main()
