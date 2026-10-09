"""Every DI2 weapon archetype -> game/data/weapons.json (plus the list of meshes to export).

Sources (di2x json dumps of the user's own install):
  DA_{Melee,Ranged}WeaponArchetype_*  UI name/description, mesh, balancing blueprint (ItemType)
  BP_Weapon_* (and its Super chain)   AttributesComponent values, MeleeArchetypeData timings / sweep / impact,
                                      EquippableData.HeldItemData -> HeldItemClassData (animation class)
Melee damage type is DI2's swing style: Slicing / Chopping / Stabbing and bisecting weapons cut, the rest are blunt.

usage: python tools/build_weapons.py            writes weapons.json + extracted/weapon_meshes.txt
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import di2_animsets as A  # noqa: E402
from build_class_data import class_id  # noqa: E402

OUT = Path(r"game\data\weapons.json")
MESH_LIST = Path(r"extracted\weapon_meshes.txt")
CLASSES = json.loads(Path(r"extracted\weapon_classes.json").read_text())
# Stable ids the game code and tests already use.
ALIASES = {"WoodBaseballBat": "bat", "Machete": "machete", "Pistol": "pistol"}
# Variants with no held-item data and no base weapon sharing their name.
CLASS_FALLBACK = {"Legendary_Stiletto": "DA_HeldItemClassData_Short1H_Stabbing_Dagger"}
SKIP = re.compile(r"_AI$|VendorCopy|Horde|Debug|PheromoneGrenade|AcidSprayer|Chemist")


def snake(s):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", s).replace("__", "_").lower()


def text(v):
    return (v or {}).get("LocalizedString") or (v or {}).get("SourceString") or ""


def bp_chain(bp):
    """Blueprint CDO property dicts, most derived first, following Super."""
    out, name = [], bp
    while name:
        d = A.load(name)
        if not d:
            break
        cls = next((e for e in d if e["Type"] == "BlueprintGeneratedClass"), {})
        comps = {e["Name"]: e.get("Properties", {}) for e in d}
        cdo = next((e.get("Properties", {}) for e in d if e.get("Name", "").startswith("Default__")), {})
        out.append((name, cdo, comps, d))
        sup = A.anyref(cls.get("Super")) if cls.get("Super") else None
        name = sup.split(".")[-1].removesuffix("_C") if sup else None
        if len(out) > 8:
            break
    return out


def attributes(chain):
    vals = {}
    for _, _, _, d in reversed(chain):  # base first, derived overrides
        for e in d:
            avs = e.get("Properties", {}).get("AttributeValueSet")
            if not avs:
                continue
            for k, v in avs.items():
                s = v.get("InitialSettings", {}) if isinstance(v, dict) else {}
                if not s:
                    continue
                lo, hi, want = s.get("MinValue"), s.get("MaxValue"), s.get("DesiredValue")
                key = k.removesuffix("Attribute")
                if lo is not None or hi is not None:
                    vals[key] = [lo if lo is not None else hi, hi if hi is not None else lo]
                elif want is not None:
                    vals[key] = want
    return vals


def first(chain, key):
    for _, cdo, comps, d in chain:
        if key in cdo:
            return cdo[key]
        for e in d:
            if key in e.get("Properties", {}):
                return e["Properties"][key]
    return None


def _to_class(name):
    seen = 0
    while name and seen < 6 and "ClassData_" not in name:
        d = A.load(name)
        p = (d or [{}])[0].get("Properties", {})
        name = A.anyref(p.get("Parent")).split(".")[-1] if p.get("Parent") else None
        seen += 1
    return name if name and A.load(name) else None


def held_class(chain, suffix, mesh):
    eq = first(chain, "EquippableData") or {}
    hid = A.anyref(eq.get("HeldItemData")) if eq.get("HeldItemData") else None
    found = _to_class(hid.split(".")[-1]) if hid else None
    if found:
        return found
    # Inherited from native/base defaults: DI2 names held-item data after the weapon (or its mesh).
    stems = [suffix, re.sub(r"^(Named_?|NGPlus_|Named_NGP_|EXP\d_Named|Legendary_?|Premium)", "", suffix),
             mesh.removeprefix("SK_") if mesh else ""]
    for stem in [x for x in stems if x]:
        for cand in (f"DA_HeldItemData_{stem}", f"DA_HeldItem_ClassData_{stem}", f"DA_Exp1_HeldItemData_{stem}",
                     f"DA_Exp2_HeldItemData_{stem}", f"DA_Exp1_HeldItem_ClassData_{stem}"):
            if A.load(cand):
                c = _to_class(cand) if "ClassData_" not in cand else cand
                if c:
                    return c
    return None


def base_of(class_name):
    for base, v in CLASSES.items():
        if class_name in v["classes"]:
            return base.lower()
    return None


def rng(v, default=None):
    if v is None:
        return default
    return v if isinstance(v, list) else [v, v]


def mean(v, default=0.0):
    if v is None:
        return default
    return (v[0] + v[1]) / 2.0 if isinstance(v, list) else v


def object_sets(chain):
    """Every ObjectSetComponent.AnimSetCollections entry of the most derived blueprint that sets them (the
    collections hit-effect trees' CosmeticEffectDamageCauser nodes look their keys up in)."""
    for _, _, _, d in chain:
        names = []
        for e in d:
            v = e.get("Properties", {}).get("AnimSetCollections")
            if v:
                names += re.findall(r"AnimSetCollection'(\w+)'", json.dumps(v))
        if names:
            return names
    return []


def attacker_sets(chain):
    """ObjectSetComponent.AnimSetCollections: DA_AnimSetCollection_Attacker_<Blunt|Sharp|Stab><Low|Medium|Weighty>
    (the hit cosmetic-effect sets DI2 picks per weapon) and DA_AnimSetCollection_Counter_<class>."""
    names = []
    for _, _, _, d in chain:
        for e in d:
            v = e.get("Properties", {}).get("AnimSetCollections")
            if v:
                names += re.findall(r"AnimSetCollection'(\w+)'", json.dumps(v))
        if names:
            break
    att = next((re.match(r"DA_AnimSetCollection_Attacker_(Blunt|Sharp|Stab)(Low|Medium|Weighty)", n) for n in names
                if n.startswith("DA_AnimSetCollection_Attacker_")), None)
    counter = next((n.removeprefix("DA_AnimSetCollection_Counter_") for n in names if n.startswith("DA_AnimSetCollection_Counter_")), None)
    return (att.group(1).lower(), att.group(2).lower()) if att else (None, None), counter


def curve_keys(name):
    """CurveFloat keys [[time, value], ...] of a DI2 curve asset, or None."""
    for e in A.load(name) or []:
        keys = e.get("Properties", {}).get("FloatCurve", {}).get("Keys", [])
        if keys:
            return [[round(k["Time"], 4), round(k["Value"], 4)] for k in keys]
    return None


def hit_effects(chain):
    """DI2 FImpactSettings of the weapon's hits: the attacker / victim / environment HitEffectTrees
    (game/data/hit_effects.json) and CustomImpactFacts ({Hit}.<Name> facts the trees test). Each field comes
    from the most derived blueprint in the Super chain that sets it (melee: MeleeArchetypeData; ranged: the
    projectile spawn module); an unset field is the native default (null)."""
    out = {"attacker": None, "victim": None, "environment": None, "facts": None}
    for _, _, _, d in chain:
        for e in d:
            stack = [e.get("Properties", {})]
            while stack:
                o = stack.pop()
                if isinstance(o, list):
                    stack.extend(o)
                    continue
                if not isinstance(o, dict):
                    continue
                st = (o.get("ImpactConfiguration") or {}).get("Settings") if isinstance(o.get("ImpactConfiguration"), dict) else None
                if isinstance(st, dict):
                    for k in ("attacker", "victim", "environment"):
                        v = st.get(k.title() + "EffectTree")
                        if out[k] is None and v:
                            out[k] = (A.anyref(v) or "").split(".")[-1] or None
                    if out["facts"] is None and "CustomImpactFacts" in st:
                        out["facts"] = {f["Name"]: (f.get("bBooleanValue") if f.get("Type", "").endswith("Boolean") else
                                                    f.get("FloatValue") if f.get("Type", "").endswith("Float") else
                                                    f.get("IntegerValue") if f.get("Type", "").endswith("Integer") else f.get("StringValue"))
                                        for f in st["CustomImpactFacts"]}
                stack.extend(v for v in o.values() if isinstance(v, (dict, list)))
    out["facts"] = out["facts"] or {}
    return out


def melee_entry(arch, chain, attrs, cls):
    mad = first(chain, "MeleeArchetypeData") or {}
    style = cls.split("_")[3] if cls and cls.count("_") >= 3 else ""
    bisect = bool((mad.get("ImpactData") or {}).get("bCanCauseBisection"))
    # Damage type: MeleeArchetypeData.DamageType where a weapon sets it (the bladed fists: Sharp); otherwise the
    # weapon's attacker set (Blunt / Sharp / Stab). DI2's native default for an unset DamageType isn't in the data.
    (attacker, weight), counter = attacker_sets(chain)
    override = re.findall(r"BP_DamageType_(\w+?)_C", json.dumps(mad.get("DamageType"))) if mad.get("DamageType") else []
    sharp = (override[0] == "Sharp") if override else attacker in ("sharp", "stab")
    sweep = mad.get("MeleeSweepParams") or {}
    states = {}
    for st in (mad.get("DurabilityFeedbackSettings") or {}).get("WeaponDurabilityVisualStates", []):
        m = A.anyref(st["Value"].get("VisualStateSkeletalMesh"))
        if m:
            states[st["Key"].split("::")[-1].lower()] = m.split(".")[-1]
    return {
        "kind": "melee",
        "damage_type": "sharp" if sharp else "blunt",
        "damage_type_source": ("MeleeArchetypeData.DamageType" if override else f"Attacker_{(attacker or '?').title()}{(weight or '').title()}"),
        "attacker": attacker,
        "attacker_weight": weight,
        "counter_set": counter,
        "stabbing": style == "Stabbing",
        "damage": rng(attrs.get("Damage"), [20, 22]),
        "force": mean(attrs.get("Force"), 15.0),
        "durability": rng(attrs.get("MaxDurability"), [40, 44]),
        "durability_loss_per_hit": mad.get("DurabilityLossPerHit", 0.6),
        "crit_chance": mean(attrs.get("CriticalChance"), 3.5) / 100.0,
        "crit_multiplier": mean(attrs.get("CriticalDamage"), 1.3),
        "stamina_per_attack": mean(attrs.get("StaminaCostPerAttack"), 12.0),
        "limb_damage_multiplier": mean(attrs.get("LimbDamageMultiplier"), 1.0),
        "counter_damage_multiplier": mean(attrs.get("CounterAttackDamageMultiplier"), 1.0),
        "thrown_damage_multiplier": mean(attrs.get("ThrownAttackDamageMultiplier"), 1.3),
        "thrown_force_multiplier": mean(attrs.get("ThrownAttackForceMultiplier"), 1.2),
        "elemental_buildup": mean(attrs.get("ElementalBuildUpMultiplier"), 1.2),
        "anticipation": mad.get("WeaponStandardAttackAnticipationTime", 0.4),
        "attack_speed": mad.get("WeaponStandardAttackSpeed", 1.0),
        "repetition": mad.get("WeaponStandardAttackRepetitionTime", 0.4),
        "pulse_delay": mad.get("WeaponStandardAttackPulseDelay", 0.1),
        "heavy_charge_time": mad.get("BasePowerAttackChargeTime", 1.2),
        "heavy_stamina_multiplier": mad.get("BasePowerAttackStaminaCostMultiplier", 2.0),
        "heavy_damage_multiplier": 2.0,
        "heavy_intensity_curve_name": (A.anyref(mad.get("PowerAttackMultiplierCurve")) or "").split(".")[-1] or None,
        "heavy_force_curve_name": (A.anyref(mad.get("PowerAttackForceMultiplierCurveOverride")) or "").split(".")[-1] or None,
        "heavy_intensity_curve": curve_keys((A.anyref(mad.get("PowerAttackMultiplierCurve")) or "").split(".")[-1]),
        "heavy_force_curve": curve_keys((A.anyref(mad.get("PowerAttackForceMultiplierCurveOverride")) or "").split(".")[-1]),
        "heavy_charge_time_source": "MeleeArchetypeData.BasePowerAttackChargeTime" if "BasePowerAttackChargeTime" in mad else "native default (stand-in 1.2)",
        "camera_shake": [mad.get("WeaponCameraShakeScaleMin", 0.7), mad.get("WeaponCameraShakeScaleMax", 0.8)],
        # Cosmetic effects DI2 plays for this weapon's attacks (unset = native default, see UNVERIFIED.md).
        "cosmetics": {k: (A.anyref(v) or "").split(".")[-1] for k, v in mad.items() if "CosmeticEffect" in k and A.anyref(v)},
        # DI2 FImpactPauseSettings {Duration, EaseOut, SlowDownScale}; null = native struct default (not in data).
        "impact_pause": {k2: (mad.get("ImpactPauseSettings") or {}).get(k) for k, k2 in
                         (("Duration", "duration"), ("EaseOut", "ease_out"), ("SlowDownScale", "slowdown"))},
        "rebound_cooldown": mad.get("ReboundInternalCooldown", 2.5),
        "reach": sweep.get("TraceDistance", 180.0) / 100.0,
        "sweep_radius": sweep.get("TraceHeight", 10.0) / 100.0,
        "stab_reach": sweep.get("StabTraceDistance", sweep.get("TraceDistance", 180.0)) / 100.0,
        "can_bisect": bisect,
        "visual_states": states,
    }


OBJ = re.compile(r"^(\w+)'(?:[^:']*:)?([^']*)'$")
UNRESOLVED_ATTRS = set()


def _key_of(e):
    """Sub-object path inside the class default object, e.g. 'RangedWeaponModulesComponent.RangedWeaponFireMode_0'."""
    outer = (e.get("Outer") or {}).get("ObjectName", "") if isinstance(e.get("Outer"), dict) else ""
    m = OBJ.match(outer)
    parent = m.group(2) if m and ":" in outer else ""
    return f"{parent}.{e['Name']}" if parent else e["Name"]


def _attr_value(field, attrs):
    """DI2 FAttributeValueSource: Source=Attribute -> the weapon's attribute; else the inline Value."""
    at = A.anyref(field.get("AttributeType")) if field.get("AttributeType") else None
    if field.get("Source", "").endswith("::Attribute") and at:
        nm = at.split(".")[-1]
        suf = re.sub(r"^DA_Attribute(Type)?_(Ranged_)?", "", nm)
        cands = [suf, suf.replace("_", "")]
        m = re.match(r"(.+)_(Min|Max)$", suf)
        if m:
            cands += [m.group(2) + m.group(1), m.group(1) + m.group(2)]
        m = re.match(r"(.+)_(Min|Max)$", suf)
        if m:
            cands.append(m.group(2) + m.group(1).replace("Dist", "Distance"))
        m = re.match(r"Reload(?:Speed)?_?(Full|Partial)$", suf)
        if m:
            cands.append(m.group(1) + "Reload")
        if suf == "MagazineCapacity":
            cands.append("MagazineAmmoCapacity")
        for c in cands:
            if c in attrs:
                return attrs[c]
        if field.get("Value") is not None:
            return field["Value"]
        # The weapon doesn't carry the attribute: DI2 uses the attribute type's own default.
        d = A.load(nm)
        dv = (d or [{}])[0].get("Properties", {}).get("DefaultValue") if d else None
        if dv is None:
            UNRESOLVED_ATTRS.add(nm)
        return dv
    return field.get("Value")


def module_tree(chain, attrs):
    """RangedWeaponModulesComponent with every sub-object reference replaced by its resolved properties (derived
    blueprint first, then the parents it inherits unchanged modules from) and attribute-sourced values resolved."""
    index = {}
    for _, _, _, d in reversed(chain):
        for e in d:
            index[_key_of(e)] = e

    def resolve(v, depth=0):
        if depth > 12:
            return None
        if isinstance(v, dict):
            if "ObjectName" in v and len(v) <= 2:
                m = OBJ.match(v["ObjectName"])
                if m and m.group(2) in index and ":" in v["ObjectName"]:
                    e = index[m.group(2)]
                    out = {"_type": e["Type"]}
                    out.update({k: resolve(x, depth + 1) for k, x in e.get("Properties", {}).items()
                                if not re.search("Cosmetic|Audio|ForceFeedback|Stim|Invocation|OnCurrent", k)})
                    return out
                return (m.group(2) or v["ObjectName"]).split(".")[-1] if m else v["ObjectName"]
            if ("Source" in v and ("Value" in v or "AttributeType" in v)) or set(v) <= {"Value", "AttributeType", "Source"}:
                return _attr_value(v, attrs)
            return {k: resolve(x, depth + 1) for k, x in v.items()}
        if isinstance(v, list):
            return [resolve(x, depth + 1) for x in v]
        return v

    comp = next((e for k, e in index.items() if e.get("Type") == "RangedWeaponModulesComponent"), None)
    if not comp:
        return None
    return resolve({"ObjectName": "x'y:" + _key_of(comp) + "'"}) if False else {
        k: resolve(x) for k, x in comp.get("Properties", {}).items() if not k.startswith("On")}


def ranged_entry(attrs, chain):
    falloff = [attrs.get("MinDamageFalloffDistance", 2000.0), attrs.get("MaxDamageFalloffDistance", 2500.0)]
    dmg_type = "projectile"
    for _, _, _, d in chain:
        m = re.findall(r"BP_DamageType_(\w+?)(?:_C)?'", json.dumps(d))
        if m:
            dmg_type = m[0].lower()
            break
    return {
        "kind": "ranged",
        "damage_type": "projectile",
        "di2_damage_type": dmg_type,
        "damage": rng(attrs.get("Damage"), [20, 22]),
        "crit_multiplier": mean(attrs.get("CriticalDamage"), 1.5) or 1.5,
        "headshot_multiplier": 2.0,
        "limb_damage_multiplier": 1.0,
        "delay_between_shots": mean(attrs.get("DelayBetweenShots"), 0.2),
        "magazine": int(mean(attrs.get("MagazineAmmoCapacity"), 12)),
        "reserve_ammo": int(mean(attrs.get("MagazineAmmoCapacity"), 12)) * 6,
        "pellets": int(mean(attrs.get("ProjectilesPerShot", attrs.get("PelletCount")), 1)),
        "reload_partial": mean(attrs.get("PartialReload"), 1.7),
        "reload_full": mean(attrs.get("FullReload"), 2.0),
        "ads_time": mean(attrs.get("ADSTransitionTime"), 0.2),
        "recoil_h": [mean(attrs.get("MinHorizontalRecoil"), -0.15), mean(attrs.get("MaxHorizontalRecoil"), 0.15)],
        "recoil_v": [mean(attrs.get("MinVerticalRecoil"), 0.7), mean(attrs.get("MaxVerticalRecoil"), 1.0)],
        "spread": [mean(attrs.get("SpreadMin"), 1.0), mean(attrs.get("SpreadMax"), 2.5)],
        "falloff_start": mean(falloff[0]) / 100.0,
        "falloff_end": mean(falloff[1]) / 100.0,
        "falloff_scale": 0.5,
        "handling": mean(attrs.get("Handling"), 80.0),
        "accuracy": mean(attrs.get("Accuracy"), 70.0),
        "force": mean(attrs.get("Force"), 25.0),
        "impulse": 50.0,
        "sweep_radius": 0.02,
        "attributes": attrs,
        "modules": module_tree(chain, attrs),
    }


def sockets(mesh):
    """Sockets of a weapon mesh (its own, then its skeleton's): name -> {bone, pos (Godot bone-local metres)}.
    UE vectors map to Godot bone-local space as (x, z, y) * 0.01, as merge_anims.py converts bone transforms."""
    out = {}
    d = A.load(mesh) or []
    skel = None
    for e in d:
        if e.get("Type") == "SkeletalMesh":
            skel = A.anyref(e.get("Skeleton") or e.get("Properties", {}).get("Skeleton"))
    sources = [d] + ([A.load(skel.split(".")[-1])] if skel and A.load(skel.split(".")[-1]) else [])
    for src in sources:
        for e in src or []:
            if e.get("Type") == "SkeletalMeshSocket":
                q = e.get("Properties", {})
                loc = q.get("RelativeLocation", {"X": 0, "Y": 0, "Z": 0})
                out.setdefault(q.get("SocketName"), {"bone": q.get("BoneName"),
                                                    "pos": [loc.get("X", 0) * 0.01, loc.get("Z", 0) * 0.01, loc.get("Y", 0) * 0.01]})
    return out


def main():
    weapons, meshes, unresolved = {}, set(), []
    for name in sorted(A.index()):
        m = re.match(r"DA_(Melee|Ranged)WeaponArchetype_(.+)$", name)
        if not m or SKIP.search(name) or "/Horde/" in A.index()[name].as_posix():
            continue
        d = A.load(name)
        p = next((e.get("Properties", {}) for e in d if "WeaponArchetype" in e.get("Type", "")), {})
        bp = A.anyref(p.get("ItemType")) if p.get("ItemType") else None
        bp = (p.get("ItemType") or {}).get("AssetPathName", "").split(".")[-1].removesuffix("_C") or bp
        chain = bp_chain(bp) if bp else []
        if not chain:
            unresolved.append(name)
            continue
        attrs = attributes(chain)
        mesh = (p.get("ItemSkeletalMesh") or {}).get("AssetPathName", "").split(".")[-1]
        cls = held_class(chain, m.group(2), mesh) or CLASS_FALLBACK.get(m.group(2))
        wid = ALIASES.get(m.group(2), snake(m.group(2)))
        entry = {
            "name": text(p.get("UIName")) or m.group(2),
            "description": text(p.get("UIDescription")),
            "archetype": name,
            "blueprint": chain[0][0],
            "profile": (first(chain, "WeaponProfile") or "").split("::")[-1],
            "class": cls,
            "base": base_of(cls) if cls else None,
            "cash": p.get("CashValue"),
            "rarities": [r.split("::")[-1] for r in p.get("SupportedRarities", [])],
            "mesh_asset": mesh,
            "mesh": f"res://assets/di2/weapons/{mesh}.glb" if mesh else "",
        }
        entry.update(melee_entry(m.group(2), chain, attrs, cls) if m.group(1) == "Melee" else ranged_entry(attrs, chain))
        entry["sockets"] = sockets(mesh) if mesh else {}
        entry["hit_effects"] = hit_effects(chain)
        entry["hit_effects"]["causer_sets"] = object_sets(chain)
        weapons[wid] = entry
        if mesh:
            meshes.add(mesh)
            meshes.update(entry.get("visual_states", {}).values())
    # Legendary / named / modded variants without a class of their own animate like the base weapon they share
    # the most name or mesh tokens with (Legendary Warhammer -> Warhammer, Sledgehammer_Acid -> Sledgehammer).
    def tokens(w):
        raw = re.sub(r"(Legendary|Named|NGPlus|NGP|EXP\d|KCD|NHW|Premium|Acid|Impact|Fire|Shock|SK_|_)", " ", w["archetype"].split("Archetype_")[-1] + " " + w.get("mesh_asset", ""))
        return {t.lower() for t in re.findall(r"[A-Z0-9]?[a-z0-9]+|[A-Z]+(?![a-z])", raw) if len(t) > 2}
    for wid, w in weapons.items():
        if w.get("base"):
            continue
        mine = tokens(w)
        best = max((len(mine & tokens(o)), oid) for oid, o in weapons.items()
                   if o.get("base") and o["kind"] == w["kind"] and oid != wid) if mine else (0, None)
        if best[0] > 0:
            src = weapons[best[1]]
            w.update({"class": src["class"], "base": src["base"], "class_from": best[1]})
            if w["kind"] == "melee" and not w.get("attacker"):
                w["damage_type"] = src["damage_type"]
                w["damage_type_source"] = f"(none in data; base weapon {best[1]})"
    # The game/data/classes/<class_id>.json file each weapon animates with (same id as tools/build_class_data.py).
    for w in weapons.values():
        if w.get("class"):
            w["class_id"] = class_id(w["class"])
    old = json.loads(OUT.read_text()) if OUT.exists() else {}
    out = {"_source": "tools/build_weapons.py: every DI2 weapon archetype from the user's own install (personal use).",
           "kick": old.get("kick", {}), "player": old.get("player", {})}
    out.update(weapons)
    OUT.write_text(json.dumps(out, indent=1))
    MESH_LIST.write_text("\n".join(sorted(meshes)))
    kinds = {}
    for w in weapons.values():
        kinds[(w["kind"], w.get("base"))] = kinds.get((w["kind"], w.get("base")), 0) + 1
    print(f"{len(weapons)} weapons, {len(meshes)} meshes; unresolved: {unresolved}")
    if UNRESOLVED_ATTRS:
        print("attribute-sourced fields with no weapon attribute (inline Value used):", sorted(UNRESOLVED_ATTRS))
    for k, n in sorted(kinds.items(), key=lambda x: str(x)):
        print(f"  {k}: {n}")
    for wid in ("bat", "machete", "pistol"):
        w = weapons.get(wid, {})
        print(wid, {k: w.get(k) for k in ("name", "class", "base", "damage", "force", "reach", "damage_type", "mesh")})


if __name__ == "__main__":
    main()
