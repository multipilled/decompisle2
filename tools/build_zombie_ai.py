"""Build game/data/zombie_ai.json: DI2's zombie card-dealer AI data for game/scripts/zombie_ai.gd (recon/ZOMBIE_AI.md).

Inputs: CUE4Parse dumps in extracted/json (tools/di2x.sh json 'Content/DI2/(Expansion02/)?AI/' plus DA_AttackSequence_,
DA_AttackDef_, DA_ActionDefinition_, BalancingData/NPCs). Every asset is stored generically: its main export's
properties with sub-objects of the same package inlined as {"$t": class, ...props}; references to other assets become
"@Name". The interpreter in zombie_ai.gd gives the classes their native meaning.

Output:
  controllers  {Archetype: {contexts: {context: deck}, aggro: {...}, bt_main}}  (BP Super chain merged, child wins)
  assets       {Name: tree}  every deck / card / attack sequence / attack def / attack rules / action definition reached
  aliases      {"#Alias": expression}  (DIShared/Core/ExpressionAliases DT_ExpressionAliases_*)
  actions / action_defs / curves / explosion_sets / spheres  archetype-specific actions (actions())
usage: python tools/build_zombie_ai.py
"""
import glob
import json
import os
import re

ROOT = os.path.join(os.path.dirname(__file__), "..")
JS = os.path.join(ROOT, "extracted", "json")
OUT = os.path.join(ROOT, "game", "data", "zombie_ai.json")
ARCHETYPES = ["Walker", "Runner", "Shambler", "Thug", "Screamer", "Slobber", "Mutator", "Butcher", "Suicider"]
FOLLOW = re.compile(r"^(DA_Deck_|DA_Card_|DA_AttackSequence_|DA_AttackDef_|DA_AttackRules_|DA_ActionDefinition_|"
                    r"DA_AttributeType_)")
DROP = {"ParentNode", "TreeAsset", "Tooltip"}

_index = None


def index():
    global _index
    if _index is None:
        _index = {}
        for f in glob.glob(os.path.join(JS, "**", "*.json"), recursive=True):
            _index.setdefault(os.path.basename(f)[:-5], f)
    return _index


_bp_index = None
_use_bp = False   # actions() only: also resolve Blueprint classes from the bytecode dumps


def bp_index():
    """Blueprint classes CUE4Parse's json export skips (actions, status effects, action params): the bytecode dumps
    (tools/re_ai/bpdump.sh -> extracted/json_bp) carry the same exports. Only actions() reads them: the cards'
    BP_ActionParams_* defaults found there (e.g. PeekedCardCheckInterval 0.3) are not merged into the decks yet."""
    global _bp_index
    if _bp_index is None:
        _bp_index = {os.path.basename(f)[:-5]: f
                     for f in glob.glob(os.path.join(JS + "_bp", "**", "*.json"), recursive=True)}
    return _bp_index


def ref_name(v):
    if isinstance(v, dict) and "ObjectName" in v and set(v) <= {"ObjectName", "ObjectPath"}:
        m = re.match(r"\w+'(.*)'", v["ObjectName"])
        return m.group(1) if m else v["ObjectName"]
    return None


def full(e):
    o = e.get("Outer")
    if isinstance(o, dict):
        m = re.match(r"\w+'[^:]*:(.*)'", o["ObjectName"])
        if m:
            return m.group(1) + "." + e["Name"]
    return e["Name"]


def load(name):
    f = index().get(name) or (bp_index().get(name) if _use_bp else None)
    return json.load(open(f, encoding="utf-8")) if f else None


def convert(name, wanted):
    """Main export of asset `name` as a tree; asset refs matching FOLLOW go into `wanted`."""
    exps = load(name)
    if exps is None:
        return None
    by = {full(e): e for e in exps}

    def val(v, depth):
        r = ref_name(v)
        if r is not None:
            if r == "None" or r is None:
                return None
            if ":" in r:
                pkg, sub = r.split(":", 1)
                if sub in by and depth < 40:
                    return obj(by[sub], depth + 1)
                return "@" + r
            base = r.split(".")[-1]
            if FOLLOW.match(base):
                wanted.add(base)
            return "@" + base
        if isinstance(v, dict):
            return {k: val(x, depth) for k, x in v.items() if k not in DROP}
        if isinstance(v, list):
            return [val(x, depth) for x in v]
        return v

    def obj(e, depth):
        d = {"$t": e["Type"]}
        d.update(bp_defaults(e["Type"]))
        d.update(val({k: v for k, v in e.get("Properties", {}).items() if k not in DROP}, depth))
        return d

    main = next((e for e in exps if not e.get("Outer")), exps[0])
    return obj(main, 0)


_bp_cache = {}


def bp_defaults(cls):
    """Class-default properties of a Blueprint class (<Name>_C) along its BP parents, references as "@Name": the
    values an instance of it inherits (cooked instances store only what differs)."""
    if not cls.endswith("_C"):
        return {}
    if cls in _bp_cache:
        return _bp_cache[cls]
    _bp_cache[cls] = {}
    exps = load(cls[:-2]) or []
    out = {}
    sup = next((ref_name(e.get("Super")) for e in exps if e.get("Super")), None)
    if sup:
        out.update(bp_defaults(sup))

    def plain(v):
        r = ref_name(v)
        if r is not None:
            return "@" + r.split(":")[-1].split(".")[-1]
        if isinstance(v, dict):
            return {k: plain(x) for k, x in v.items()}
        if isinstance(v, list):
            return [plain(x) for x in v]
        return v
    for e in exps:
        if e["Name"] == "Default__" + cls:
            out.update({k: plain(v) for k, v in e.get("Properties", {}).items() if k not in DROP})
    _bp_cache[cls] = out
    return out


def controller(arch):
    """Merged CDO data of BP_AIController_<arch> along its Super chain."""
    chain, name = [], "BP_AIController_" + arch
    while name:
        exps = load(name)
        if exps is None:
            break
        chain.append(exps)
        # The class export's Super (exps[0] is not always the class: BP_AIController_Butcher starts with a Function).
        cls = next((e for e in exps if e.get("Type") == "BlueprintGeneratedClass"), exps[0])
        sup = ref_name(cls.get("Super")) if cls.get("Super") else None
        name = sup[:-2] if sup and sup.startswith("BP_") and sup.endswith("_C") else None
    contexts = {}
    out = {"contexts": contexts}
    for exps in reversed(chain):   # base first, child overrides
        for e in exps:
            p = e.get("Properties", {})
            if e["Type"] == "AICardDealerComponent":
                for c in p.get("Contexts", []):
                    r = ref_name(c["Value"])
                    if r and r != "None":
                        contexts[c["Key"]] = r
                    else:
                        contexts.setdefault(c["Key"], None)
            elif e["Name"].startswith("Default__"):
                for k in ("BT_Main", "CombatAgentClass", "AIMovementClass"):
                    if k in p:
                        out[k] = ref_name(p[k])
    agg = out.get("CombatAgentClass")
    if agg:
        exps = load(agg[:-2]) or []
        for e in exps:
            if e["Name"].startswith("Default__"):
                out["aggro"] = {k: (ref_name(v) or v) for k, v in e.get("Properties", {}).items()
                                if not isinstance(v, (dict, list)) or ref_name(v)}
    return out


def aliases():
    out = {}
    for f in sorted(glob.glob(os.path.join(JS, "DeadIsland", "Content", "DIShared", "Core", "ExpressionAliases",
                                           "DT_*.json"))):
        for e in json.load(open(f, encoding="utf-8")):
            for k, v in (e.get("Rows") or {}).items():
                out["#" + k] = v["Expression"]["Expression"]
    return out


def anim_sets(assets):
    """{Archetype: {AnimSetName: {"montage": AM} | {"set": AnimSetData name}}, "_data": {set: data}} for every
    AnimSetName the AI assets play (AttackSequenceUnit_AnimSetAction, idle breaks), resolved against the archetype's
    AnimSetCollections (BP_Base_<Type> chain, via tools/build_hit_reacts.py) as zombie_reactions resolves hit-react sets:
    key "<CollectionName>.<Key>" when the collection is named, else "<Key>"."""
    import build_hit_reacts as H
    names = set()

    def walk(v):
        if isinstance(v, dict):
            for k, x in v.items():
                if k == "AnimSetName" and isinstance(x, str) and x not in ("", "None"):
                    names.add(x)
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(assets)
    # Status-effect actions zombie_reactions plays (DA_ActionDefinition_Stun_Disorientated_AI Into / Outro anim sets).
    names |= {"Disorientated", "DisorientatedEnd", "Scream", "ScreamEnd"}   # + BP_Action_ScreamStateMachine_Screamer
    out, data = {}, {}
    for arch, bp in H.ARCHETYPES.items():
        a = H.archetype(bp) or {}
        r = {}
        for c in a.get("AnimSetCollections", []):
            col = H.collection(c)
            if not col:
                continue
            for key, v in col["keys"].items():
                full = (col["name"] + "." + key) if col["name"] else key
                if full in names and full not in r:
                    r[full] = v
                    if v.get("set") and v["set"] not in data:
                        data[v["set"]] = H.anim_set_data(v["set"])
        out[arch] = r
    out["_data"] = data
    return out, sorted(names)


def movement_speeds():
    """{Archetype: [{expr, speed (RNG struct, cm/s), min, max, method}]} from DA_MovementSpeed_<Type> (the character's
    MovementSpeedData, AIMovementSpeedData.BaseValues in order)."""
    out = {}
    for a in ARCHETYPES:
        exps = load("DA_MovementSpeed_" + a)
        if not exps:
            continue
        p = exps[0].get("Properties", {})
        out[a] = [{"expr": (b.get("Expression") or {}).get("Expression", ""), "speed": b.get("BaseSpeed", {}),
                   "min": b.get("ClampedMin"), "max": b.get("ClampedMax"),
                   "method": str(b.get("ModifierApplicationMethod", "")).split("::")[-1]}
                  for b in p.get("BaseValues", [])]
        out[a + "_props"] = {k: v for k, v in p.items() if k != "BaseValues"}
    return out


def actions():
    """Archetype-specific actions: BP_Base_<Arch>'s BPC_AI_CharacterAction.ArchetypeSpecificActionDefinitions
    (DA_ActionDefinitions_AI_<Arch>) override the generic action of the same Name, e.g. the Screamer's "EnterCombat"
    is DA_ActionDefinition_ScreamStateMachine_Screamer. Returns ({arch: {ActionName: def}}, {def: {Name, Category,
    impl, LifetimeFacts, defaults}}, {curve: [[time, value], ...]}, {arch: {data set key: explosion archetype}}).
    Action definitions referenced from an implementation's defaults (e.g. ScreamActionDefinition) are included;
    also BP_Base_<Arch>'s SphereComponent radii (cm), e.g. the Screamer's ScreamSphere."""
    global _use_bp
    _use_bp = True
    _bp_cache.clear()   # classes resolved without the bytecode dumps
    by_arch, defs, curves, expl, spheres, balancing = {}, {}, {}, {}, {}, {}

    def add_def(dn):
        if dn in defs:
            return
        defs[dn] = {}
        p = ((load(dn) or [{}])[0]).get("Properties", {})
        impl = ref_name(p.get("Implementation")) or ""
        d = bp_defaults(impl) if impl else {}
        defs[dn] = {"Name": p.get("Name", ""), "Category": p.get("Category", ""), "impl": impl,
                    "LifetimeFacts": [f.get("NameStorage", "") for f in p.get("LifetimeFacts", [])], "defaults": d}
        for v in d.values():
            if isinstance(v, str) and v.startswith("@DA_ActionDefinition_"):
                add_def(v[1:])
            elif isinstance(v, str) and v.startswith("@Curve_") and v[1:] not in curves:
                c = ((load(v[1:]) or [{}])[0]).get("Properties", {}).get("FloatCurve", {}).get("Keys", [])
                curves[v[1:]] = [[k["Time"], k["Value"]] for k in c]
    for a in ARCHETYPES:
        ref = None
        for e in load("BP_Base_" + a) or []:
            ref = ref_name(e.get("Properties", {}).get("ArchetypeSpecificActionDefinitions")) or ref
            if e.get("Type") == "SphereComponent" and "SphereRadius" in e.get("Properties", {}):
                spheres.setdefault(a, {})[e["Name"].replace("_GEN_VARIABLE", "")] = e["Properties"]["SphereRadius"]
        for e in load("DA_DataSetCollection_Explosions_" + a) or []:
            for kv in e.get("Properties", {}).get("AnimSetData", []):
                n = ref_name(kv["Value"].get("AnimAsset")) or ""
                ds = ref_name(kv["Value"].get("AnimSetData"))
                if not n and ds:
                    # AnimSet_DataDriven (e.g. DA_DataSet_Suicide_Suicider): [[expression, archetype], ...], first
                    # group whose expression holds.
                    groups = []
                    for g in ((load(ds) or [{}])[0]).get("Properties", {}).get("Groups", []):
                        items = [ref_name(i.get("Asset")) for i in g.get("Items", []) if i.get("Asset")]
                        if items:
                            groups.append([g.get("Expression", {}).get("Expression", ""),
                                           items[0].replace("DA_ExplosionArchetype_", "")])
                    expl.setdefault(a, {})[kv["Key"]] = groups
                else:
                    expl.setdefault(a, {})[kv["Key"]] = n.replace("DA_ExplosionArchetype_", "")
        # Per-class balancing tables read by BP_Base_<Arch>'s construction script (DT_SuicideBalancing_Suicider:
        # ArmingDuration, ExecutionSphereRadius, ...) and the class's curve references (Arming_WeightCurve, ...).
        for e in load("DT_SuicideBalancing_" + a) or []:
            for rn, row in (e.get("Rows") or {}).items():
                v = [x for x in row.values() if isinstance(x, (int, float))]
                if v:
                    balancing.setdefault(a, {})[rn] = v[0]
        for e in load("BP_Base_" + a) or []:
            if e["Name"] == "Default__BP_Base_%s_C" % a:
                for k, v in e.get("Properties", {}).items():
                    r = ref_name(v)
                    if r and r.startswith("Curve_") and r not in curves:
                        c = ((load(r) or [{}])[0]).get("Properties", {}).get("FloatCurve", {}).get("Keys", [])
                        curves[r] = [[x["Time"], x["Value"]] for x in c]
                        balancing.setdefault(a, {})[k] = r
        if not ref:
            continue
        for x in ((load(ref) or [{}])[0]).get("Properties", {}).get("Entries", []):
            dn = ref_name(x.get("Definition"))
            if dn:
                add_def(dn)
                by_arch.setdefault(a, {})[defs[dn]["Name"]] = dn
    _use_bp = False
    return by_arch, defs, curves, expl, spheres, balancing


def fire_modes():
    """Ranged fire modes of the classes whose BP_Base_<Arch> has a RangedWeaponModulesComponent
    (DA_RangedWeaponModuleConfig_<Arch>): {arch: {UniqueIdentifier: {projectile, speed (cm/s, OverrideInitalProjectileSpeed,
    else the projectile's InitialSpeed), delay (StandardShotHandler DelayTimeBetweenShotsInBurst), count [min, max],
    parabola (has a TrajectoryAdjustmentHelper), deviation_deg (AIDeviationLaunchAdjustmentModule SegmentAngleInDegrees),
    muzzle}}} and {projectile class: {InitialSpeed, damage, damage_type, accumulating, spawn: {cls, radius}}}
    (BP_Projectile_*: DIProjectileMovementComponent, ApplyPointImpactCollisionResponse, the detonation's
    ProjectileResponseSpawnProjectile). Sub-object references resolve by export index (ObjectPath ".N")."""
    modes, projs = {}, {}

    def at(exps, ref):
        try:
            return exps[int(str(ref["ObjectPath"]).rsplit(".", 1)[1])]
        except (KeyError, ValueError, IndexError, TypeError):
            return {}

    def projectile(cls):
        n = cls[:-2] if cls.endswith("_C") else cls
        if n in projs:
            return projs[n]
        exps = load(n) or []
        out = {}
        for e in exps:
            pr = e.get("Properties", {})
            if e["Type"] == "DIProjectileMovementComponent":
                out["InitialSpeed"] = pr.get("InitialSpeed", 0.0)
                if "ProjectileGravityScale" in pr:
                    out["GravityScale"] = pr["ProjectileGravityScale"]
            elif e["Type"] == "ApplyPointImpactCollisionResponse":
                out["damage"] = pr.get("DamageQuantityToApply", 0.0)
                out["damage_type"] = ref_name(pr.get("DamageClassToApply")) or ""
                acc = pr.get("ImpactConfiguration", {}).get("Settings", {}).get("AccumulatingEffectsToApply", {})
                out["accumulating"] = [{"type": x.get("EffectType", "").split("::")[-1], "value": x.get("ValueToApply", 0.0),
                                        "apply_max": x.get("bApplyMaxValue", False),
                                        "can_extend": x.get("CanExtendEffectDuration", False)}
                                       for x in acc.get("AccumulatingEffects", [])]
            elif e["Type"] == "ProjectileResponseSpawnProjectile":
                cp = at(exps, pr.get("CreationParams")).get("Properties", {})
                out["spawn"] = {"cls": ref_name(pr.get("ProjectileType")) or "",
                                "radius": cp.get("FluidActorInitialState", {}).get("FluidPayloadRadius", 0.0)}
        projs[n] = out
        return out
    for a in ARCHETYPES:
        exps = load("DA_RangedWeaponModuleConfig_" + a)
        if not exps:
            continue
        for e in exps:
            if e["Type"] != "RangedWeaponFireMode":
                continue
            pr = e.get("Properties", {})
            sp = at(exps, pr.get("ProjectileSpawner")).get("Properties", {})
            conf = sp.get("ProjectileConfiguration", {})
            cls = ref_name(conf.get("ProjectileType")) or ""
            cp = at(exps, conf.get("CreationParams")).get("Properties", {})
            meth = at(exps, conf.get("ProjectileSpawnMethod")).get("Properties", {})
            sh = at(exps, pr.get("ShotHandler")).get("Properties", {})
            dev = at(exps, pr.get("LaunchAdjustmentHandler")).get("Properties", {})
            pj = projectile(cls)
            modes.setdefault(a, {})[pr.get("UniqueIdentifier", e["Name"])] = {
                "projectile": cls, "speed": cp.get("OverrideInitalProjectileSpeed", pj.get("InitialSpeed", 0.0)),
                "delay": sh.get("DelayTimeBetweenShotsInBurst", {}).get("Value", 0.0),
                "shots": sh.get("NumberOfSuccessiveShotsBeforeEndShoot", 0),
                "count": [meth.get("MinProjectileCount", 1), meth.get("MaxProjectileCount", 1)],
                "parabola": conf.get("TrajectoryAdjustmentHelper") is not None,
                "deviation_deg": dev.get("SegmentAngleInDegrees", 0.0),
                "muzzle": sp.get("MuzzleOriginBoneOrSocketName", "")}
    return modes, {k[:-2] if k.endswith("_C") else k: v for k, v in projs.items()}


def streams(sets, modes):
    """BP_AnimNotifyState_ActivateProjectileStream windows of the anim-set montages of classes with fire modes:
    {montage: [[Duration, params]]}, params = the instance's properties over the notify class defaults
    (FireModeIdentifier, MeshSocketToSetManualPositionFrom head_mouth, ManualOffsetRotationLimit 90,
    ManualOffsetPitchOverride -1, UseDistanceVariants / DistanceFromTargetVariants). zombie_ai.gd pairs them with
    montages_zombie.json's notifies by Duration."""
    global _use_bp
    _use_bp = True
    dflt = {k: v for k, v in bp_defaults("BP_AnimNotifyState_ActivateProjectileStream_C").items()
            if not isinstance(v, (dict, list)) or k == "DistanceFromTargetVariants"}
    _use_bp = False
    out = {}
    for a in modes:
        mons = set()
        for e in sets.get(a, {}).values():
            if "montage" in e:
                mons.add(e["montage"])
            for g in sets.get("_data", {}).get(e.get("set", ""), {}).get("groups", []):
                mons.update(str(it[1]) for it in g.get("items", []))
        for m in sorted(mons):
            exps = load(m) or []
            main = next((x for x in exps if x.get("Type") == "AnimMontage"), {})
            for n in main.get("Properties", {}).get("Notifies", []):
                if n.get("NotifyName") != "BP_ActivateProjectileStream":
                    continue
                inst = {}
                try:
                    inst = exps[int(str(n["NotifyStateClass"]["ObjectPath"]).rsplit(".", 1)[1])].get("Properties", {})
                except (KeyError, ValueError, IndexError, TypeError):
                    pass
                prm = dict(dflt)
                prm.update(inst)
                out.setdefault(m, []).append([n.get("Duration", 0.0), prm])
    return out


def main():
    ctrls = {a: controller(a) for a in ARCHETYPES}
    wanted = {d for c in ctrls.values() for d in c["contexts"].values() if d}
    assets, missing = {}, []
    while wanted:
        n = wanted.pop()
        if n in assets or n in missing:
            continue
        t = convert(n, wanted)
        if t is None:
            missing.append(n)
        else:
            assets[n] = t
    sets, set_names = anim_sets(assets)
    data = {"controllers": ctrls, "assets": assets, "aliases": aliases(), "missing": sorted(missing),
            "anim_sets": sets, "move_speeds": movement_speeds()}
    (data["actions"], data["action_defs"], data["curves"], data["explosion_sets"], data["spheres"],
     data["balancing"]) = actions()
    data["fire_modes"], data["projectiles"] = fire_modes()
    data["streams"] = streams(sets, data["fire_modes"])
    print("streams:", data["streams"])
    print("fire modes:", data["fire_modes"])
    print("archetype actions:", data["actions"], "explosion sets:", data["explosion_sets"], "spheres:", data["spheres"], "balancing:", data["balancing"])
    print("AI anim set names:", set_names)
    print("resolved per archetype:", {a: len(v) for a, v in sets.items() if a != "_data"})
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    json.dump(data, open(OUT, "w", encoding="utf-8"), indent=0, sort_keys=True)
    kinds = {}
    for t in assets.values():
        kinds[t["$t"]] = kinds.get(t["$t"], 0) + 1
    print(f"{len(ctrls)} controllers, {len(assets)} assets {kinds}, {len(data['aliases'])} aliases, "
          f"missing {len(missing)}: {missing[:12]}")


if __name__ == "__main__":
    main()
