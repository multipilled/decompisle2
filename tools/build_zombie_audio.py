"""DI2 zombie voice / breathing audio -> game/data/zombie_audio.json (recon/ZOMBIE_AUDIO.md has every source).

Inputs (all extracted from the user's own install, static only):
  * DamLoc dialogue database: extracted/raw/.../StagedData/DamLoc/Data/DialogueData.xml (voices, voice sets, triggers,
    rules, communications + per-voice variations) and DialogueList.xml (per audio file: Wwise event + Volume dB);
  * voice choice: CT_Voice_<Family> trees + DA_CharacterVoiceDefinition_* (extracted/json);
  * breathing component: BPC_BreathingAudio_AI CDO + native defaults recovered from the exe (COMPONENT_NATIVE);
  * montage notifies: AnimNotify_BreathingEvent / BP_AnimNotify_AttackBreathingEvent_Exert(Chained)_AI /
    BP_AnimNotifyState_ScopedFacts_BlockBreathing_AI instances in every zombie AM_* montage (times via
    tools/di2_animsets.link_time, like montages_zombie.json);
  * Wwise: the DX_* dialogue events' own bank data (event-based packaging, inside the AkAudioEvent uassets) and
    InitBank.uasset (busses, attenuations, game-parameter defaults), parsed by tools/zaudio/wwise_hirc.py;
  * per-file peak envelopes: game/assets/di2/zombie_vox/peaks.json (tools/zaudio/convert_voices.py).
usage: python -I tools/build_zombie_audio.py
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = r"."
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "zaudio"))
import di2_animsets as A  # noqa: E402
from wwise_bank import fnv  # noqa: E402
from wwise_hirc import parse_bank  # noqa: E402

RAW = os.path.join(ROOT, r"extracted\raw\DeadIsland\Content")
JSON = os.path.join(ROOT, r"extracted\json\DeadIsland\Content")
DAMLOC = os.path.join(RAW, r"StagedData\DamLoc\Data")
OUT = os.path.join(ROOT, r"game\data\zombie_audio.json")
VOX = os.path.join(ROOT, r"game\assets\di2\zombie_vox")
FAMILIES = ["Walker", "Runner", "Shambler", "Thug"]

# --- breathing component ------------------------------------------------------------------------------------------
# UBreathingAudioComponent native defaults (constructor, see recon/ZOMBIE_AUDIO.md section 3); BPC_BreathingAudio_AI's
# CDO and the zombie's CharacterVoiceDefinition override some of them below.
COMPONENT_NATIVE = json.load(open(os.path.join(ROOT, r"tools\zaudio\component_native.json")))


def jload(rel):
    p = os.path.join(JSON, rel)
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


def props_of(d, typ):
    for e in d or []:
        if e.get("Type") == typ:
            return e.get("Properties", {})
    return {}


def idx(path):
    return int(path.rsplit(".", 1)[1])


# --- voice trees ---------------------------------------------------------------------------------------------------
def voice_tree(fam):
    d = jload(f"DI2/Enemies/Zombies/{fam}/CT_Voice_{fam}.json")

    def walk(i):
        e = d[i]
        t = e["Type"]
        p = e.get("Properties", {})
        if t == "ConditionalTreeNode_BooleanExpression":
            return {"bool": p["Expression"]["Expression"],
                    "true": walk(idx(p["TrueNode"]["ObjectPath"])) if "TrueNode" in p else None,
                    "false": walk(idx(p["FalseNode"]["ObjectPath"])) if "FalseNode" in p else None}
        if t == "ConditionalTreeNode_StringExpression":
            return {"string": p["Expression"]["Expression"],
                    "links": {l["Value"]: walk(idx(l["Node"]["ObjectPath"])) for l in p.get("Links", [])},
                    "default": walk(idx(p["DefaultNode"]["ObjectPath"])) if "DefaultNode" in p else None}
        if t == "ConditionalTreeNode_Voice":
            out = []
            while True:
                dd = d[idx(p["Data"]["ObjectPath"])]["Properties"]
                out.append({"voice": dd["VoiceName"]["NameStorage"],
                            "definition": dd["Definition"]["ObjectName"].split("'")[1],
                            "facts": {c["Name"]: c.get("StringValue") for c in dd.get("CharacterFacts", [])}})
                if "NextNode" not in p:
                    break
                p = d[idx(p["NextNode"]["ObjectPath"])].get("Properties", {})
            return {"voices": out}
        raise ValueError(t)

    root = [e for e in d if e["Type"] == "VoiceTree"][0]["Properties"]["StartNode"]["ObjectPath"]
    return walk(idx(root))


def tree_voices(node, acc):
    if node is None:
        return acc
    if "voices" in node:
        acc += [v["voice"] for v in node["voices"]]
    for k in ("true", "false", "default"):
        tree_voices(node.get(k), acc)
    for v in node.get("links", {}).values():
        tree_voices(v, acc)
    return acc


def voice_definition(fam, name):
    p = props_of(jload(f"DI2/Enemies/Zombies/{fam}/{name}.json"), "CharacterVoiceDefinition")
    out = {}
    for k, v in p.items():
        if isinstance(v, dict) and "ObjectName" in v:
            v = v["ObjectName"].split("'")[1]
        elif isinstance(v, dict) and "Expression" in v:
            v = v["Expression"]
        elif isinstance(v, list):
            v = [x["ObjectName"].split("'")[1] if isinstance(x, dict) and "ObjectName" in x else x for x in v]
        out[k] = v
    return out


# --- DamLoc --------------------------------------------------------------------------------------------------------
def damloc(voice_names):
    r = ET.parse(os.path.join(DAMLOC, "DialogueData.xml")).getroot()
    B = list(r.find("BaseVoiceSets"))
    T = list(r.find("Triggers"))
    R = list(r.find("Rules"))
    C = list(r.find("Communications"))
    VS = list(r.find("VoiceSets"))
    V = {v.get("Name"): v for v in r.find("Voices")}

    def chain(bi):
        out = []
        while bi is not None:
            out.append(bi)
            pi = B[bi].get("RefParentIndex")
            bi = int(pi) if pi else None
        return out

    used_bvs = set()
    voices = {}
    for vn in voice_names:
        v = V[vn]
        sets = []
        for s in v.find("VoiceSets"):
            vs = VS[int(s.get("RefIndex"))]
            bi = int(vs.get("RefParentBaseVoiceSetIndex"))
            sets.append({"voice_set": vs.get("Name"), "base": B[bi].get("Name"),
                         "folder": vs.get("PhysicalAudioFolder"), "vs_index": int(s.get("RefIndex"))})
            used_bvs.update(chain(bi))
        voices[vn] = {"folder": v.get("PhysicalAudioFolder"), "sets": sets}

    base_sets = {}
    triggers = {}
    for bi in sorted(used_bvs):
        b = B[bi]
        pi = b.get("RefParentIndex")
        base_sets[b.get("Name")] = {"parent": B[int(pi)].get("Name") if pi else None,
                                    "triggers": [t.get("RefName") for t in b.find("Triggers")],
                                    "communications": [c.get("RefName") for c in b.find("Communications")]}
        for t in b.find("Triggers"):
            ti = int(t.get("RefIndex"))
            tr = T[ti]
            key = f"{b.get('Name')}.{tr.get('Name')}"
            par = tr.get("RefParentIndex")
            par_key = None
            if par:
                pt = T[int(par)]
                owner = next(B[j].get("Name") for j in range(len(B))
                             if any(int(x.get("RefIndex")) == int(par) for x in B[j].find("Triggers")))
                par_key = f"{owner}.{pt.get('Name')}"
            rules = []
            for rr in tr.find("Rules"):
                ru = R[int(rr.get("RefIndex"))]
                rule = {"index": int(ru.get("Index")), "criteria": ru.get("Criteria") or "",
                        "complexity": int(ru.get("CriteriaComplexity")), "boost": int(ru.get("CriteriaBoost")),
                        "default": ru.get("IsDefaultRule") == "1"}
                for sec in ru:
                    acts = []
                    for a in sec:
                        act = {"action": a.get("Name")}
                        for k in ("BaseVoiceSetName", "CommunicationName", "KnowledgeBase", "Fact", "Value",
                                  "Transient"):
                            if a.get(k) is not None:
                                act[k] = a.get(k)
                        acts.append(act)
                    rule[sec.tag] = acts
                rules.append(rule)
            triggers[key] = {"name": tr.get("Name"), "priority": tr.get("Priority"), "parent": par_key,
                             "rules": rules}

    # per voice: base communication "<BVS>.<Comm>" -> {play, files}
    comm_owner = {}
    for b in B:
        for c in b.find("Communications"):
            comm_owner[int(c.get("RefIndex"))] = b.get("Name")
    comms = {}
    for vn, info in voices.items():
        out = {}
        for s in info["sets"]:
            vs = VS[s["vs_index"]]
            for c in vs.find("Communications"):
                ce = C[int(c.get("RefIndex"))]
                base_i = int(ce.get("RefParentIndex"))
                key = f"{comm_owner.get(base_i, '?')}.{C[base_i].get('Name')}"
                files = [f"{s['folder']}/{x.get('PhysicalAudioFilename')}" for x in ce.find("Variations")]
                out[key] = {"play": ce.get("VariationPlayType"), "files": files}
        comms[vn] = out
    return voices, base_sets, triggers, comms


def dialogue_lines(voice_names):
    r = ET.parse(os.path.join(DAMLOC, "DialogueList.xml")).getroot()
    want = set(voice_names)
    out = {}
    for d in r.find("DialogueLines"):
        p = d.get("Path") or ""
        m = re.match(r"Main/Voices/([^/]+)/(.+)$", p)
        if not m or m.group(1) not in want:
            continue
        out[f"{m.group(1)}/{m.group(2)}"] = {"event": d.get("Event"), "volume_db": float(d.get("Volume") or 0),
                                             "type": d.get("DialogueType")}
    return out


# --- Wwise ---------------------------------------------------------------------------------------------------------
EVENT_DIRS = ["Normal", "SpecialLarge", "SpecialSmall"]


def wwise(events_used):
    init = parse_bank(open(os.path.join(RAW, r"WwiseAudio\InitBank.uasset"), "rb").read())
    out = {"events": {}, "busses": {}, "attenuations": {}}

    def bus_chain(bid):
        ch = []
        import struct
        b = open(os.path.join(RAW, r"WwiseAudio\InitBank.uasset"), "rb").read()
        from wwise_bank import hirc
        objs = {oid: (t, off, s) for t, oid, off, s in hirc(b)}
        from wwise_hirc import PROP, INT_PROPS
        while bid and bid in objs:
            t, off, s = objs[bid]
            o = off
            parent = struct.unpack_from("<I", b, o)[0]
            o += 4
            if parent == 0:
                o += 4
            n = b[o]
            o += 1
            ids = list(b[o:o + n])
            o += n
            props = {}
            for i in ids:
                nm = PROP.get(i, hex(i))
                props[nm] = struct.unpack_from("<I" if nm in INT_PROPS else "<f", b, o)[0]
                o += 4
            ch.append({"id": bid, "props": props})
            bid = parent
        return ch

    for ev in sorted(events_used):
        path = None
        for d in EVENT_DIRS:
            p = os.path.join(RAW, rf"WwiseAudio\Events\Dialogue\Zombie\{d}\{ev}.uasset")
            if os.path.exists(p):
                path = p
        if not path:
            out["events"][ev] = {"missing": True}
            continue
        objs = parse_bank(open(path, "rb").read())
        bad = [o["id"] for o in objs.values() if not o["_consumed_exactly"]]
        evo = next(o for o in objs.values() if o["type"] == "Event")
        act = objs[evo["actions"][0]]
        # follow the play target down the SFX_Walker_Distance = Normal branch to the external-source sound
        node = objs.get(act["target"])
        path_nodes = []
        while node is not None and node["type"] != "Sound":
            path_nodes.append(node["id"])
            if node["type"] == "SwitchCntr":
                want = fnv("Normal") if node["group_id"] == fnv("SFX_Walker_Distance") else node["default_switch"]
                nxt = next((g["nodes"][0] for g in node["switch_groups"] if g["switch"] == want), None)
                if nxt is None and node.get("children"):
                    nxt = node["children"][0]
                node = objs.get(nxt)
            else:
                node = objs.get(node["children"][0]) if node.get("children") else None
        if node is None:
            out["events"][ev] = {"no_external_sound": True}
            continue
        snd = node
        # object chain: sound -> parents (Volume / Pitch / HPF / LPF props, FX)
        chain = []
        o = snd
        while o is not None:
            chain.append({"id": o["id"], "type": o["type"], "props": o["props"], "ranged": o["ranged"],
                          "fx": [f["fx_id"] for f in o["fx"]], "fx_override": o["fx_override"],
                          "max_instances": o["adv"]["max_instances"], "override_bus": o["override_bus"]})
            o = objs.get(o["parent"])
        bus = next(c["override_bus"] for c in chain if c["override_bus"])
        effective_fx = next((c["fx"] for c in chain if c["fx_override"] or c["fx"]), [])
        fx = {}
        for fid in effective_fx:
            f = objs.get(fid) or init.get(fid)
            fx[fid] = {"plugin": hex(f["plugin"]), "params": f["params"],
                       "rtpc": [{"rtpc": r["rtpc"], "param": r["param"], "points": r["points"]} for r in f["rtpc"]]}
        bchain = bus_chain(bus)
        # the voice's attenuation: the nearest object in the actor-mixer chain that sets one, else its 3D bus's
        att_id = next((c["props"].get("AttenuationID") for c in chain if "AttenuationID" in c["props"]), None)
        att_src = "object"
        if att_id is None:
            att_id = next((c["props"].get("AttenuationID") for c in bchain if "AttenuationID" in c["props"]), None)
            att_src = "bus"
        if att_id and str(att_id) not in out["attenuations"]:
            a = init.get(att_id) or objs.get(att_id)
            out["attenuations"][str(att_id)] = {"cone": a.get("cone_params"), "curve_map": a["curve_map"],
                                                "curves": a["curves"], "source": att_src}
        obj_vol = sum(c["props"].get("Volume", 0.0) for c in chain)
        bus_vol = sum(c["props"].get("Volume", 0.0) + c["props"].get("BusVolume", 0.0)
                      + c["props"].get("OutputBusVolume", 0.0) for c in bchain)
        out["events"][ev] = {"bank_parse_ok": not bad, "path": path_nodes + [snd["id"]], "sound": snd["id"],
                             "object_chain": chain, "object_volume_db": obj_vol, "bus": bus, "bus_chain": bchain,
                             "bus_volume_db": bus_vol, "attenuation": att_id, "fx": fx,
                             "sound_max_instances": snd["adv"]["max_instances"],
                             "hpf": sum(c["props"].get("HPF", 0.0) for c in chain),
                             "lpf": sum(c["props"].get("LPF", 0.0) for c in chain),
                             "pitch_cents": sum(c["props"].get("Pitch", 0.0) for c in chain)}
    # game parameter default of the mouth RTPC (STMG)
    return out


def meter_settings():
    from wwise_bank import meter_params
    objs = parse_bank(open(os.path.join(RAW, r"WwiseAudio\Events\Dialogue\Zombie\Normal\DX_Walker_Talk.uasset"),
                           "rb").read())
    m = objs[220051762]
    p = meter_params(bytes.fromhex(m["params"]))
    p["mode"] = ["Peak", "RMS"][p["mode"]]
    p["scope"] = ["Global", "GameObject"][p["scope"]]
    p["fx_shareset"] = 220051762
    p["game_param"] = "RTPC_Zombie_Mouth_Volume"
    p["game_param_default"] = -48.0          # Init.bnk STMG record (ramp none)
    p["frame_samples"] = 1024                # DefaultGame.ini AkWindowsInitializationSettings SamplesPerFrame
    p["sample_rate"] = 48000
    return p


# --- montage notifies ---------------------------------------------------------------------------------------------
NOTIFY_CLASSES = {"AnimNotify_BreathingEvent": "event",
                  "BP_AnimNotify_AttackBreathingEvent_Exert_AI_C": "exert",
                  "BP_AnimNotify_AttackBreathingEvent_ExertChained_AI_C": "exert_chained"}
BLOCK_STATE = "BP_AnimNotifyState_ScopedFacts_BlockBreathing_AI_C"


def class_defaults():
    """Notify class defaults: native AnimNotify_BreathingEvent ctor + each BP class's CDO."""
    nat = COMPONENT_NATIVE["anim_notify_breathing_event"]
    out = {"AnimNotify_BreathingEvent": dict(nat)}
    for cls, f in (("BP_AnimNotify_AttackBreathingEvent_Exert_AI_C", "BP_AnimNotify_AttackBreathingEvent_Exert_AI"),
                   ("BP_AnimNotify_AttackBreathingEvent_ExertChained_AI_C",
                    "BP_AnimNotify_AttackBreathingEvent_ExertChained_AI")):
        d = json.load(open(os.path.join(ROOT, rf"extracted\json_bp\DeadIsland\Content\DI2\Enemies\{f}.json")))
        cdo = next(e for e in d if e.get("Name", "").startswith("Default__"))
        v = dict(nat)
        v.update(norm_notify(cdo.get("Properties", {})))
        out[cls] = v
    return out


def norm_notify(p):
    out = {}
    if "Event" in p:
        out["event"] = p["Event"].split("::")[-1]
    if "VocalPlayType" in p:
        out["play_type"] = p["VocalPlayType"].split("::")[-1]
    if "VocalPlayFlags" in p:
        out["flags"] = int(p["VocalPlayFlags"])
    va = p.get("VocalAsset")
    if va is not None:
        dt = va.get("DialogueTrigger", {})
        bvs = dt.get("BaseVoiceSet", {}).get("NameStorage")
        trg = dt.get("Trigger", {}).get("NameStorage")
        if bvs is not None or trg is not None:
            out["trigger"] = [bvs, trg]
        if va.get("AudioEvent"):
            out["audio_event"] = va["AudioEvent"]["ObjectName"].split("'")[1]
    return out


def montage_notifies():
    defaults = class_defaults()
    out = {}
    base = os.path.join(JSON, r"DI2\Animation\Zombie")
    for dirpath, _, files in os.walk(base):
        for fn in files:
            if not (fn.startswith("AM_") and fn.endswith(".json")):
                continue
            d = json.load(open(os.path.join(dirpath, fn), encoding="utf-8"))
            m = next((e for e in d if e["Type"] == "AnimMontage"), None)
            if not m:
                continue
            by_name = {e.get("Name"): e for e in d}
            evs, blocks = [], []
            for n in m["Properties"].get("Notifies", []):
                t = round(A.link_time(n), 4)
                if n.get("Notify"):
                    on = n["Notify"]["ObjectName"]
                    cls = on.split("'")[0]
                    if cls not in NOTIFY_CLASSES:
                        continue
                    obj = by_name.get(on.split(":")[-1].rstrip("'"))
                    v = dict(defaults[cls])
                    v.update(norm_notify((obj or {}).get("Properties", {})))
                    v["time"] = t
                    v["class"] = NOTIFY_CLASSES[cls]
                    evs.append(v)
                elif n.get("NotifyStateClass"):
                    cls = n["NotifyStateClass"]["ObjectName"].split("'")[0]
                    if cls == BLOCK_STATE:
                        blocks.append([t, round(t + (n.get("Duration") or 0.0), 4)])
            if evs or blocks:
                out[fn[:-5]] = {"events": sorted(evs, key=lambda x: x["time"]), "block_breathing": blocks}
    return out


def main():
    trees = {f.lower(): voice_tree(f) for f in FAMILIES}
    voice_names = sorted(set(sum((tree_voices(t, []) for t in trees.values()), [])))
    defs = {}
    for f in FAMILIES:
        for fn in os.listdir(os.path.join(JSON, rf"DI2\Enemies\Zombies\{f}")):
            if fn.startswith("DA_CharacterVoiceDefinition_"):
                defs[fn[:-5]] = voice_definition(f, fn[:-5])
    voices, base_sets, triggers, comms = damloc(voice_names)
    lines = dialogue_lines(voice_names)
    have = set()
    if os.path.exists(os.path.join(VOX, "peaks.json")):
        have = set(json.load(open(os.path.join(VOX, "peaks.json"))).keys())
    events_used = sorted({l["event"] for l in lines.values()})
    bpc = props_of(json.load(open(os.path.join(ROOT, r"extracted\json_bp\DeadIsland\Content\DI2\Enemies\BPC_BreathingAudio_AI.json"))),
                   "BPC_BreathingAudio_AI_C")
    comp = dict(COMPONENT_NATIVE["component"])
    for k in ("CalmHoldBreathInTime", "CalmHoldBreathOutTime"):
        if k in bpc:
            comp[k] = bpc[k]
    mouth = props_of(jload("DIShared/Audio/DataAssets/DA_BreathingAudioMouthDamLocWalker.json"),
                     "BreathingAudioMouthAnimationConfigDataAsset")
    out = {
        "_doc": "DI2 zombie vocal audio (recon/ZOMBIE_AUDIO.md). Built by tools/build_zombie_audio.py.",
        "voice_trees": trees,
        "voice_definitions": defs,
        "definition_native_defaults": COMPONENT_NATIVE["character_voice_definition"],
        "component": comp,
        "component_bp_cdo": {k: v for k, v in bpc.items() if k != "UberGraphFrame"},
        "breathing_states": COMPONENT_NATIVE["states"],
        "mental_state_from_combat_state": {"0": 0, "1": 1, "2": 1},
        "voices": voices,
        "voices_converted": sorted({k.split("/")[0] for k in have}),
        "base_voice_sets": base_sets,
        "triggers": triggers,
        "communications": comms,
        "lines": lines,
        "wwise": wwise(events_used),
        "meter": meter_settings(),
        "mouth_config": mouth,
        "montages": montage_notifies(),
    }
    json.dump(out, open(OUT, "w"), indent=1)
    print(f"voices {len(voice_names)}, triggers {len(triggers)}, lines {len(lines)}, events {len(events_used)}, "
          f"montages with breathing notifies {len(out['montages'])}")


if __name__ == "__main__":
    main()
