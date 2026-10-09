"""DI2 zombie hit-reaction trees -> game/data/hit_reacts.json (format and porting notes: recon/HIT_REACTS.md).

DI2 picks a zombie's reaction to a hit (flinch, stumble, knockdown, death, launch, ragdoll, head organs, bisection)
in two steps:
  1. HitReactTreeSet (DA_HitReactTreeSet_Zombie_Common / _Special_Large / _Butcher): an ordered list of
     {Expression, ReactTree, NetworkPolicy}. The first entry whose expression holds names the HitReactTree
     (an empty expression always holds).
  2. HitReactTree (CT_HitReact_*): a ConditionalTree whose response nodes fire HitDeathReactionResponses
     (MinorAnimatedFlinch / MajorAnimatedFlinch / AnimatedKnockback / Knockdown / Death / Ragdoll / Launch / ...)
     and then continue to NextNode, so one hit can fire several responses. LinkMultipleResults nodes run
     another HitReactTree in place and then continue. Modules (CT_HitReact_InterruptionLevel_Zombie,
     CT_HitReact_Bisect_Zombie) are ModularConditionalTrees whose result label picks a link.
Animated responses name an anim set ("HitReactions.Small" = CollectionName.Key) that the zombie's own
AnimSetCollections resolve to an AnimSetData (groups of {Expression, items -> AnimMontage}).

Node kinds (bool / str / module / result match tools/build_hit_effects.py, so one evaluator can run both):
  bool    expr, t (true node), f (false node)
  str     expr, links {value: node}, default
  num     expr, ranges [[min, max, node]], default            ConditionalTreeNode_NumericExpression
  module  module (a ModularConditionalTree name), links {label: node}
  result  label                                               (modular trees only)
  resp    r (the response, see below), next                   ConditionalTreeNode_HitDeathReactionResponse
  link    tree (a HitReactTree name), next                    ConditionalTreeNode_LinkMultipleResults
A node id of null ends the walk.

Responses (resp.r): {"class": DI2 class, "native": native parent class (BP subclasses), "id": tree:node of the
response object, ...properties}. Expressions are plain strings, object references are asset names, and a
blueprint response's class-default properties (its CDO) are merged under the instance's own.

usage: python tools/build_hit_reacts.py [--missing <file>] [--fetch]
  --missing <file>  also write the DI2 asset names this needs that are not dumped in extracted/json (one per
                    line, for `tools/di2x.sh json @<file>`).
  --fetch           dump those assets with di2x (new files under extracted/json only; existing dumps are not
                    touched) and rebuild, repeating while new references turn up (archetype BPs -> their
                    components, collections, anim sets, montages). Heavy: run it through the CPU throttle,
                    `tools/with_cpu.sh <name> python tools/build_hit_reacts.py --fetch`.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import di2_animsets as A  # noqa: E402

ROOT = Path(r".")
OUT = ROOT / "game/data/hit_reacts.json"
TREE_SETS = ["DA_HitReactTreeSet_Zombie_Common", "DA_HitReactTreeSet_Zombie_Special_Large",
             "DA_HitReactTreeSet_Zombie_Butcher"]
# The bodies the port ships (zombie.gd BODIES) -> their DI2 archetype blueprint.
ARCHETYPES = {"Walker": "BP_Base_Walker", "Runner": "BP_Base_Runner", "Shambler": "BP_Base_Shambler",
              "Thug": "BP_Base_Thug"}
BODY_FOLDER = {"Walker": "walker", "Runner": "runner", "Shambler": "shambler", "Thug": "thug"}
# Special archetypes (tools/archetype_bodies.py, recon/ARCHETYPES.md).
ARCHETYPES.update({"Screamer": "BP_Base_Screamer", "Slobber": "BP_Base_Slobber", "Butcher": "BP_Base_Butcher", "Suicider": "BP_Base_Suicider"})
BODY_FOLDER.update({"Screamer": "screamer", "Slobber": "slobber", "Butcher": "butcher", "Suicider": "suicider"})
EXTRA_SETS = ["StandUp"]
# Archetype CDO properties that feed hit reactions.
ARCH_PROPS = ["HitDeathReactionsClass", "StabilityClass", "HealthComponentClass", "AnimSetCollections",
              "VulnerableRequirement_Heavy", "VulnerableRequirement_Medium", "VulnerableRequirement_Light",
              "ArchetypeSpecificFacts", "GroupSpecificFacts", "GenericBalancingDataRow", "CombatTargetComponentClass",
              "HeadStompHealthFracThreshold", "ChallengeRating"]

missing = set()


# --- References / property normalisation -----------------------------------------------------------------------

def ref(o):
    """Node id from an object reference (`Class'Tree:Node'`)."""
    if not o:
        return None
    m = re.search(r"'[^:']*:([\w.]+)'", o.get("ObjectName", ""))
    return m.group(1).split(".")[-1] if m else None


def asset(o):
    if not o:
        return None
    m = re.search(r"'(\w+)'", o.get("ObjectName", ""))
    return m.group(1) if m else None


def norm(v):
    """DI2 property JSON -> plain data: {"Expression": e} -> e, object refs -> names, FName structs -> str."""
    if isinstance(v, dict):
        if set(v) == {"Expression"}:
            return v["Expression"]
        if "ObjectName" in v and set(v) <= {"ObjectName", "ObjectPath"}:
            m = re.search(r"'([^']+)'", v["ObjectName"])
            return m.group(1).split(":")[-1].split(".")[-1] if m and ":" in m.group(1) else (m.group(1) if m else None)
        if set(v) == {"NameStorage"}:
            return v["NameStorage"]
        if set(v) == {"DataTable", "RowName"}:
            return {"table": norm(v["DataTable"]), "row": v["RowName"]}
        return {k: norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    return v


def cdo(name):
    """Class-default properties of a blueprint (BP_X or BP_X_C), its native parent and its template chain."""
    pkg = name[:-2] if name.endswith("_C") else name
    d = A.load(pkg)
    if d is None:
        missing.add(pkg)
        return None
    cls = next((e for e in d if e["Type"] == "BlueprintGeneratedClass"), {})
    obj = next((e for e in d if e["Name"].startswith("Default__")), {})
    sup_ref = (cls.get("Super") or cls.get("SuperStruct") or {}) if cls else {}
    sup = asset(sup_ref) if sup_ref else None
    tmpl = obj.get("Template", {}).get("ObjectName", "")
    m = re.search(r"(\w+)_C'Default__", tmpl)
    return {"props": obj.get("Properties", {}), "super": sup, "template": m.group(1) if m else None,
            "super_is_bp": sup_ref.get("ObjectName", "").startswith("BlueprintGeneratedClass")}


def component(name):
    """A component blueprint's class defaults along its parent chain (BPC_HitDeathReactions_Walker_C ->
    BPC_HitDeathReactions_Zombie_C -> native): the most derived value of each property wins."""
    chain, props, native = [], {}, None
    while name:
        c = cdo(name)
        if c is None:
            chain.append(name + " (not dumped)")
            break
        chain.append(name)
        for k, v in norm(c["props"]).items():
            props.setdefault(k, v)
        if not c["super_is_bp"]:
            native = c["super"]
            break
        name = c["super"]
    return {"class": chain[0], "chain": chain, "native": native, **props}


# --- Hit-react trees ----------------------------------------------------------------------------------------------

def response(e, sub):
    """A HitDeathReactionResponse object -> dict (BP CDO defaults merged under the instance's properties)."""
    t = e["Type"]
    out = {"class": t, "id": e["Name"]}
    props = {}
    if t.endswith("_C"):
        c = cdo(t)
        if c:
            out["native"] = c["super"]
            props.update(norm(c["props"]))
            out["cdo"] = sorted(c["props"])
    props.update(norm(e.get("Properties", {})))
    # Instanced sub-objects (action params ...) are stored on the response by object name.
    for k, v in list(props.items()):
        if isinstance(v, str) and v in sub:
            props[k] = {"class": sub[v]["Type"], **norm(sub[v].get("Properties", {}))}
    out.update(props)
    return out


def tree_nodes(name):
    d = A.load(name)
    if d is None:
        missing.add(name)
        return None
    objs = {}
    for e in d:
        objs.setdefault(e["Name"], e)
    # Response objects are sub-objects of their node; several share a Name (`..._0`), so key them by outer.
    by_outer = {}
    for e in d:
        m = re.search(r":([\w.]+)'", (e.get("Outer") or {}).get("ObjectName", ""))
        if m:
            by_outer.setdefault(m.group(1).split(".")[-1], {})[e["Name"]] = e
    root = next(e for e in d if e["Type"] in ("HitReactTree", "ModularConditionalTree"))
    p = root.get("Properties", {})
    nodes = {}
    for e in d:
        t, q = e["Type"], e.get("Properties", {})
        if not t.startswith("ConditionalTreeNode_"):
            continue
        expr = (q.get("Expression") or {}).get("Expression", "")
        n = e["Name"]
        if t == "ConditionalTreeNode_BooleanExpression":
            nodes[n] = {"k": "bool", "expr": expr, "t": ref(q.get("TrueNode")), "f": ref(q.get("FalseNode"))}
        elif t == "ConditionalTreeNode_StringExpression":
            nodes[n] = {"k": "str", "expr": expr, "links": {l["Value"]: ref(l.get("Node")) for l in q.get("Links", [])},
                        "default": ref(q.get("DefaultNode"))}
        elif t == "ConditionalTreeNode_NumericExpression":
            nodes[n] = {"k": "num", "expr": expr,
                        "ranges": [[l.get("Min"), l.get("Max"), ref(l.get("Node"))] for l in q.get("Links", [])],
                        "default": ref(q.get("DefaultNode"))}
        elif t == "ConditionalTreeNode_Module":
            nodes[n] = {"k": "module", "module": asset(q.get("ModuleToUse")),
                        "links": {l["Value"]: ref(l.get("Node")) for l in q.get("Links", [])}}
        elif t == "ConditionalTreeNode_ModularResult":
            nodes[n] = {"k": "result", "label": q.get("ResultLabel", "")}
        elif t == "ConditionalTreeNode_HitDeathReactionResponse":
            rn = ref(q.get("Response"))
            sub = by_outer.get(n, {})
            r = sub.get(rn)
            nodes[n] = {"k": "resp", "r": response(r, by_outer.get(rn, {})) if r else None, "next": ref(q.get("NextNode"))}
        elif t == "ConditionalTreeNode_LinkMultipleResults":
            nodes[n] = {"k": "link", "tree": asset(q.get("LinkedTree")), "next": ref(q.get("NextNode"))}
        else:
            nodes[n] = {"k": "unknown", "type": t, "props": norm(q)}
    entry = {"kind": root["Type"], "start": ref(p.get("StartNode")), "nodes": nodes}
    if p.get("OutputStrings"):
        entry["outputs"] = p["OutputStrings"]
    return entry


def tree_set(name):
    d = A.load(name)
    if d is None:
        missing.add(name)
        return None
    p = d[0].get("Properties", {})
    return [{"expr": (t.get("Expression") or {}).get("Expression", ""), "tree": asset(t.get("ReactTree")),
             "net": (t.get("NetworkPolicy") or "").split("::")[-1]} for t in p.get("HitReactTrees", [])]


def collect_trees(sets):
    """Every HitReactTree / module reachable from the tree sets."""
    trees, modules = {}, {}
    todo = [e["tree"] for s in sets.values() if s for e in s]
    while todo:
        n = todo.pop()
        if not n or n in trees or n in modules:
            continue
        t = tree_nodes(n)
        if t is None:
            continue
        (modules if t["kind"] == "ModularConditionalTree" else trees)[n] = t
        for node in t["nodes"].values():
            if node["k"] == "link":
                todo.append(node["tree"])
            elif node["k"] == "module":
                todo.append(node["module"])
    return trees, modules


# --- Anim sets ----------------------------------------------------------------------------------------------------

def items(lst):
    return [[it.get("Weight", 1.0), asset(it.get("Asset")) or norm(it.get("InstancedAsset"))]
            for it in lst or []]


def order(o):
    return (asset(o) or "").replace("AnimSetSelectionOrder_", "")


def anim_set_data(name):
    """AnimSetData -> {"kind": "groups", groups: [{name, expr, order, null_ok, items: [[w, montage]]}]};
    AnimSetVelocityData -> {"kind": "velocity", speed_groups: [{expr, speed: {lo, lo_type, hi, hi_type},
    angle_groups: [{zero, order, dir, cos_extent, items}]}]}."""
    d = A.load(name)
    if d is None:
        missing.add(name)
        return None
    main = next((e for e in d if e["Type"] in ("AnimSetData", "AnimSetVelocityData")), None)
    if main is None:
        return None
    p = main.get("Properties", {})
    if main["Type"] == "AnimSetData":
        return {"kind": "groups", "groups": [{
            "name": g.get("Name"), "expr": (g.get("Expression") or {}).get("Expression", ""),
            "order": order(g.get("Order")), "null_ok": g.get("bAllowSingleNullEntry", False),
            "items": items(g.get("Items"))} for g in p.get("Groups", [])]}
    out = []
    for sg in p.get("SpeedGroups", []):
        r = sg.get("SpeedRange", {})
        lo, hi = r.get("LowerBound", {}), r.get("UpperBound", {})
        out.append({"expr": (sg.get("Expression") or {}).get("Expression", ""),
                    "speed": {"lo": lo.get("Value"), "lo_type": (lo.get("Type") or "").split("::")[-1],
                              "hi": hi.get("Value"), "hi_type": (hi.get("Type") or "").split("::")[-1]},
                    "angle_groups": [{"zero": ag.get("bMatchesZeroVelocity", False), "order": order(ag.get("Order")),
                                      "dir": [ag.get("AngleRangeCentreDirection", {}).get(c) for c in "XYZ"],
                                      "cos_extent": ag.get("CosAngleRangeCentreExtent"), "items": items(ag.get("Items"))}
                                     for ag in sg.get("AngleGroups", [])]})
    return {"kind": "velocity", "speed_groups": out}


def collection(name):
    """AnimSetCollection -> {"name": CollectionName or "", "keys": {key: {"set": AnimSetData} | {"montage": AM}}}."""
    d = A.load(name)
    if d is None:
        missing.add(name)
        return None
    objs = {e["Name"]: e for e in d}
    main = next((e for e in d if e["Type"] == "AnimSetCollection"), None)
    if main is None:
        return None
    p = main.get("Properties", {})
    keys = {}
    for s in p.get("AnimSetData", []):
        v = s.get("Value") or {}
        if v.get("AnimSetData"):
            keys[s["Key"]] = {"set": asset(v["AnimSetData"]), "class": asset(v.get("AnimSetClass"))}
        elif v.get("AnimAsset"):
            keys[s["Key"]] = {"montage": asset(v["AnimAsset"])}
        elif v.get("AnimSet"):
            o = objs.get(ref(v["AnimSet"]) or "")
            q = (o or {}).get("Properties", {})
            if o and q.get("Data"):
                keys[s["Key"]] = {"set": asset(q["Data"]), "class": o["Type"]}
            elif o and q.get("Asset"):
                keys[s["Key"]] = {"montage": asset(q["Asset"]), "class": o["Type"]}
            elif o:
                keys[s["Key"]] = {"class": o["Type"], "props": norm(q)}
        elif v.get("InstancedAnimAsset"):
            keys[s["Key"]] = {"inline": norm(v["InstancedAnimAsset"])}
    return {"name": "" if p.get("CollectionName") in (None, "None") else p["CollectionName"], "keys": keys}


def anim_set_names(trees):
    out = set()
    for t in trees.values():
        for n in t["nodes"].values():
            if n["k"] == "resp" and n["r"] and n["r"].get("AnimSetName"):
                out.add(n["r"]["AnimSetName"])
    return out


# --- Archetypes -------------------------------------------------------------------------------------------------

def archetype(bp):
    """Walk the archetype CDO's template chain (BP_Base_Walker -> BP_Base_Zombie -> BP_Base_AI); the most
    specific value of each hit-reaction property wins."""
    chain, props = [], {}
    name = bp
    while name:
        c = cdo(name)
        if c is None:
            chain.append(name + " (not dumped)")
            break
        chain.append(name)
        for k in ARCH_PROPS:
            if k in c["props"] and k not in props:
                props[k] = norm(c["props"][k])
        name = c["template"]
    out = {"bp": bp, "chain": chain, **props}
    if props.get("HitDeathReactionsClass"):
        out["hit_death_reactions"] = component(props["HitDeathReactionsClass"])
    if props.get("StabilityClass"):
        out["stability"] = component(props["StabilityClass"])
    # Attack montages carry BP_AnimNotifyState_ModifiableValues_InterruptThreshold_<Type> windows with a
    # MappingValue (VeryLow..Max); the notify's DA_ForceInterruptThreshold_<Type> maps it to the KB value
    # "ForceInterrupt" (DA_ModifiableValueDef_ForceInterruptThreshold: TakeMaximum, pushed to the KB).
    note = component(f"BP_AnimNotifyState_ModifiableValues_InterruptThreshold_{bp.replace('BP_Base_', '')}")
    da = A.load(note.get("ModifiableValuesDataAsset") or "") if note.get("ModifiableValuesDataAsset") else None
    if da:
        p = da[0].get("Properties", {})
        out["force_interrupt"] = {"notify": note["class"], "asset": note["ModifiableValuesDataAsset"],
                                  "value": "ForceInterrupt",
                                  "levels": {v["Key"].split("::")[-1]: v["Value"] for v in p.get("Values", [])}}
    return out


# --- Montages -> port clips ---------------------------------------------------------------------------------------

def body_clips():
    """{body: {AnimSequence: clip key}} from game/assets/di2/<body>/clips.json (clip key -> DI2 sequence)."""
    out = {}
    for arch, folder in BODY_FOLDER.items():
        p = ROOT / "game/assets/di2" / folder / "clips.json"
        rev = {}
        if p.exists():
            for key, seq in json.loads(p.read_text(encoding="utf-8")).items():
                rev.setdefault(seq, key)
        out[folder] = rev
    return out


def montage(name, clips):
    d = A.load(name)
    if d is None:
        missing.add(name)
        return {"dumped": False}
    m = next((e for e in d if e["Type"] == "AnimMontage"), None)
    if m is None:
        return {"dumped": False}
    p = m["Properties"]
    tracks = []
    for tr in p.get("SlotAnimTracks", []):
        segs = [{"seq": asset(s.get("AnimReference")), "start": s.get("StartPos", 0.0),
                 "from": s.get("AnimStartTime", 0.0), "to": s.get("AnimEndTime"), "rate": s.get("AnimPlayRate", 1.0),
                 "loops": s.get("LoopingCount", 1)}
                for s in (tr.get("AnimTrack") or {}).get("AnimSegments", [])]
        tracks.append({"slot": tr.get("SlotName"), "segments": segs})
    seqs = list(dict.fromkeys(s["seq"] for t in tracks for s in t["segments"] if s["seq"]))
    out = {"dumped": True, "length": p.get("SequenceLength"), "rate": p.get("RateScale", 1.0),
           "blend_in": (p.get("BlendIn") or {}).get("BlendTime"), "blend_out": (p.get("BlendOut") or {}).get("BlendTime"),
           "blend_out_trigger": p.get("BlendOutTriggerTime"), "auto_blend_out": p.get("bEnableAutoBlendOut"),
           "slots": tracks, "sections": [s.get("SectionName") for s in p.get("CompositeSections", [])],
           "notifies": [[n.get("NotifyName"), round(n.get("LinkValue", 0) or 0, 4), round(n.get("Duration", 0) or 0, 4)]
                        for n in p.get("Notifies", [])],
           "clips": {}}
    for body, rev in clips.items():
        keys = [rev.get(s) for s in seqs]
        if any(keys):
            out["clips"][body] = keys if len(keys) > 1 else keys[0]
    return out


def montages_of(sets_data, trees):
    names = set()
    for s in sets_data.values():
        if not s:
            continue
        if s["kind"] == "groups":
            for g in s["groups"]:
                names |= {it[1] for it in g["items"] if isinstance(it[1], str)}
        else:
            for sg in s["speed_groups"]:
                for ag in sg["angle_groups"]:
                    names |= {it[1] for it in ag["items"] if isinstance(it[1], str)}
    for t in trees.values():
        for n in t["nodes"].values():
            if n["k"] == "resp" and n["r"]:
                names |= {m for m in n["r"].get("ReactionMontageChoices", []) or [] if isinstance(m, str)}
    return names


REF_ASSET = re.compile(r"^(DA_LaunchSettings_|DA_ImpulseFilterSet_|Curve_|CE_HitReact_)")


def referenced_assets(trees):
    """Data the responses point at (launch settings and their impulse filter sets, flinch impulse curves,
    hit-react cosmetic effects), followed through the assets themselves: {name: {export name: properties}}."""
    names = set()

    def scan(v):
        if isinstance(v, dict):
            for x in v.values():
                scan(x)
        elif isinstance(v, list):
            for x in v:
                scan(x)
        elif isinstance(v, str) and REF_ASSET.match(v):
            names.add(v)

    for t in trees.values():
        for n in t["nodes"].values():
            if n["k"] == "resp":
                scan(n["r"])
    out = {}
    while names - set(out) - missing:
        for name in sorted(names - set(out) - missing):
            d = A.load(name)
            if d is None:
                missing.add(name)
                continue
            out[name] = {e["Name"]: {"class": e["Type"], **norm(e.get("Properties", {}))} for e in d}
            scan(out[name])
    return dict(sorted(out.items()))


def asset_anim_set_names(assets):
    """Anim set names the referenced assets play (LaunchSettings.OptionalLaunchAnimSetName)."""
    return {e["OptionalLaunchAnimSetName"] for a in assets.values() for e in a.values()
            if e.get("OptionalLaunchAnimSetName")}


# --- Facts --------------------------------------------------------------------------------------------------------

IDENT = re.compile(r"(\{\w+\}\.\w+|#\w+|[A-Za-z_]\w*)(\s*\()?")
KEYWORDS = {"true", "false", "and", "or"}


def expr_idents(expr):
    out = []
    for m in IDENT.finditer(re.sub(r"\"[^\"]*\"|'[^']*'", "", expr or "")):
        word, call = m.group(1), m.group(2)
        if call or word.lower() in KEYWORDS:
            continue
        out.append(word)
    return out


def all_exprs(v):
    """Every expression string inside a node / response / anim-set structure."""
    if isinstance(v, dict):
        for k, x in v.items():
            if k in ("expr",) and isinstance(x, str):
                yield x
            elif isinstance(x, str) and ("Expression" in k):
                yield x
            else:
                yield from all_exprs(x)
    elif isinstance(v, list):
        for x in v:
            yield from all_exprs(x)


def fact_inventory(sources, aliases):
    """{fact: {"scope", "used_by": [...]}} for every leaf fact the expressions read (aliases expanded) plus the
    alias names used, with their definitions."""
    facts, used_aliases = {}, {}

    def visit(expr, where, depth=0):
        for w in expr_idents(expr):
            if w.startswith("#"):
                a = w[1:]
                if a in aliases:
                    used_aliases.setdefault(a, aliases[a])
                    if depth < 24:
                        visit(aliases[a], where, depth + 1)
                    continue
                w = a  # an unknown #Name is read as a plain fact
            if w.replace(".", "").isdigit():
                continue
            m = re.match(r"\{(\w+)\}\.(\w+)", w)
            scope, key = (m.group(1).capitalize(), m.group(2)) if m else ("", w)
            k = f"{scope}.{key}" if scope else key
            low = {x.lower(): x for x in facts}
            k = low.get(k.lower(), k)  # DI2 names (FName) are case-insensitive
            f = facts.setdefault(k, {"scope": scope or "bare", "used_by": []})
            if where not in f["used_by"]:
                f["used_by"].append(where)

    for where, v in sources:
        for e in all_exprs(v):
            visit(e, where)
    return dict(sorted(facts.items())), dict(sorted(used_aliases.items()))


# --- Main -------------------------------------------------------------------------------------------------------------

def fetch(names):
    """`di2x json @list` for exact asset names (same as tools/di2x.sh: local .NET 10, output in extracted/json)."""
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(sorted(names)) + "\n")
    env = dict(os.environ, DOTNET_ROOT=str(ROOT / "tools/dotnet10"))
    try:
        r = subprocess.run([str(ROOT / "tools/di2x/bin/out/di2x.exe"), "json", "@" + f.name], env=env,
                           capture_output=True, text=True)
    finally:
        os.unlink(f.name)
    ok = sum(1 for line in r.stdout.splitlines() if line.startswith("ok "))
    print(f"di2x: {ok} dumped, {len(names) - ok} not found or failed")
    A.index.cache_clear()
    A.load.cache_clear()
    return ok


def main():
    tried = set()
    for _ in range(8):
        build()
        new = missing - tried
        if "--fetch" not in sys.argv or not new or not fetch(new):
            break
        tried |= new
        missing.clear()


def build():
    sets = {n: tree_set(n) for n in TREE_SETS}
    trees, modules = collect_trees(sets)

    archetypes = {a: archetype(bp) for a, bp in ARCHETYPES.items()}
    coll_names = list(dict.fromkeys(c for a in archetypes.values() for c in a.get("AnimSetCollections") or []))
    collections = {c: collection(c) for c in coll_names}
    collections = {k: v for k, v in collections.items() if v}

    # Resolve every anim set name the responses use against each archetype's collections. "StandUp" is not
    # named by any tree: it is the collections' only get-up set, exported for the knockdown recovery that
    # KnockdownActionResponse runs natively (see recon/HIT_REACTS.md).
    assets = referenced_assets(trees)
    names = sorted(anim_set_names(trees) | asset_anim_set_names(assets) | set(EXTRA_SETS))
    resolved, set_names = {}, set()
    for a, arch in archetypes.items():
        r = {}
        for full in names:
            cname, _, key = full.rpartition(".")
            for c in arch.get("AnimSetCollections") or []:
                col = collections.get(c)
                if col and col["name"] == cname and key in col["keys"]:
                    r[full] = {"collection": c, **col["keys"][key]}
                    if col["keys"][key].get("set"):
                        set_names.add(col["keys"][key]["set"])
                    break
        resolved[a] = r
        arch["anim_sets"] = r
    sets_data = {n: anim_set_data(n) for n in sorted(set_names)}
    clips = body_clips()
    montages = {m: montage(m, clips) for m in sorted(montages_of(sets_data, trees))}

    aliases = json.loads((ROOT / "game/data/expression_aliases.json").read_text(encoding="utf-8"))
    sources = [(n, s) for n, s in sets.items()] + [(n, t) for n, t in {**trees, **modules}.items()] + \
              [(n, s) for n, s in sets_data.items()] + [(a, {"v": [v.get(k) for k in v if k.startswith("Vulnerable")]})
                                                        for a, v in archetypes.items()]
    facts, used_aliases = fact_inventory(sources, aliases)

    # {Hit}.Head / Torso_Upper / Arm_Left ... are the zombie body-part ids: DT_ZombiePartBoneDefinition rows.
    pb = A.load("DT_ZombiePartBoneDefinition")
    parts = {k: v.get("BoneNames", []) for k, v in (pb[0].get("Rows", {}) if pb else {}).items()}
    if pb is None:
        missing.add("DT_ZombiePartBoneDefinition")

    # Sequences the reaction montages play that a body's clips.json lacks (to merge into that body's glb).
    # A body counts only for the montages its own archetype's anim sets reach.
    clips_missing = {}
    for a, arch in archetypes.items():
        body = BODY_FOLDER[a]
        ams = montages_of({s["set"]: sets_data.get(s["set"]) for s in arch["anim_sets"].values() if s.get("set")}, {})
        ams |= {s["montage"] for s in arch["anim_sets"].values() if s.get("montage")}
        ams |= montages_of({}, trees)
        seqs = {s["seq"] for m in ams for t in montages.get(m, {}).get("slots", []) for s in t["segments"] if s["seq"]}
        clips_missing[body] = sorted(s for s in seqs if s not in clips[body]) if arch["anim_sets"] else None

    out = {"tree_sets": sets, "trees": trees, "modules": modules, "archetypes": archetypes, "parts": parts,
           "clips_missing": clips_missing,
           "collections": {c: v for c, v in collections.items()
                           if v["name"] in {n.rpartition(".")[0] for n in names}},
           "anim_sets": sets_data, "montages": montages, "assets": assets, "facts": facts,
           "aliases": used_aliases, "missing": sorted(missing)}
    OUT.write_text(json.dumps(out, separators=(",", ":")))

    nresp = sum(1 for t in trees.values() for n in t["nodes"].values() if n["k"] == "resp")
    dumped = sum(1 for m in montages.values() if m.get("dumped"))
    mapped = sum(1 for m in montages.values() if m.get("clips"))
    unknown = sorted({n["type"] for t in {**trees, **modules}.values() for n in t["nodes"].values() if n["k"] == "unknown"})
    print(f"{len(sets)} tree sets, {len(trees)} hit-react trees ({nresp} responses), {len(modules)} modules, "
          f"{len(names)} anim set names -> {len(sets_data)} anim sets, {len(montages)} montages "
          f"({dumped} dumped, {mapped} mapped to clips), {len(facts)} facts, {len(used_aliases)} aliases; "
          f"unknown node types: {unknown}")
    for a, arch in archetypes.items():
        print(f"  {a}: chain {arch['chain']}, anim sets resolved {len(arch['anim_sets'])}/{len(names)}")
    if missing:
        print(f"{len(missing)} DI2 assets not dumped in extracted/json (listed under \"missing\")")
    if "--missing" in sys.argv:
        Path(sys.argv[sys.argv.index("--missing") + 1]).write_text("\n".join(sorted(missing)) + "\n")


if __name__ == "__main__":
    main()
