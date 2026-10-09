"""Wwise 2019.2 (bank v135) HIRC object parser for the objects DI2's zombie dialogue events use: Sound, ActorMixer,
SwitchCntr, RanSeqCntr, Action, Event, Attenuation, FxShareSet/FxCustom, Bus (header part).
Layouts follow the bank format as documented by the open-source wwiser project; every parse is checked to end exactly
at the object's size, so a wrong layout cannot pass silently. Personal-use research; nothing is published.
"""
import struct

from wwise_bank import HIRC_TYPES, hirc

# AkPropID (2019.2)
PROP = {0x00: "Volume", 0x01: "LFE", 0x02: "Pitch", 0x03: "LPF", 0x04: "HPF", 0x05: "BusVolume",
        0x06: "MakeUpGain", 0x07: "Priority", 0x08: "PriorityDistanceOffset", 0x0B: "MuteRatio", 0x0C: "PAN_LR",
        0x0D: "PAN_FR", 0x0E: "CenterPCT", 0x0F: "DelayTime", 0x10: "TransitionTime", 0x11: "Probability",
        0x12: "DialogueMode", 0x13: "UserAuxSendVolume0", 0x14: "UserAuxSendVolume1", 0x15: "UserAuxSendVolume2",
        0x16: "UserAuxSendVolume3", 0x17: "GameAuxSendVolume", 0x18: "OutputBusVolume", 0x19: "OutputBusHPF",
        0x1A: "OutputBusLPF", 0x1B: "HDRBusThreshold", 0x1C: "HDRBusRatio", 0x1D: "HDRBusReleaseTime",
        0x1E: "HDRBusGameParam", 0x1F: "HDRBusGameParamMin", 0x20: "HDRBusGameParamMax", 0x21: "HDRActiveRange",
        0x22: "LoopStart", 0x23: "LoopEnd", 0x24: "TrimInTime", 0x25: "TrimOutTime", 0x26: "FadeInTime",
        0x27: "FadeOutTime", 0x28: "FadeInCurve", 0x29: "FadeOutCurve", 0x2A: "LoopCrossfadeDuration",
        0x2B: "CrossfadeUpCurve", 0x2C: "CrossfadeDownCurve", 0x36: "PlaybackSpeed", 0x39: "AttachedPluginFXID",
        0x3A: "Loop", 0x3B: "InitialDelay", 0x44: "GameAuxSendLPF", 0x45: "GameAuxSendHPF", 0x46: "AttenuationID",
        0x47: "PositioningTypeBlend", 0x48: "ReflectionBusVolume"}
INT_PROPS = {"AttenuationID", "AttachedPluginFXID", "HDRBusGameParam", "Loop", "FadeInCurve", "FadeOutCurve",
             "CrossfadeUpCurve", "CrossfadeDownCurve"}
# AkRTPC_ParameterID (2019.2), the ones that matter here
RTPC_PARAM = {0: "Volume", 1: "LFE", 2: "Pitch", 3: "LPF", 4: "HPF", 5: "BusVolume", 6: "InitialDelay",
              7: "MakeUpGain", 13: "PlaybackSpeed", 14: "MuteRatio", 17: "Priority", 29: "BypassFX0",
              30: "BypassFX1", 31: "BypassFX2", 32: "BypassFX3", 33: "BypassAllFX", 38: "GameAuxSendVolume",
              39: "UserAuxSendVolume0", 43: "OutputBusVolume", 44: "OutputBusHPF", 45: "OutputBusLPF"}
CURVE_INTERP = {0: "Log3", 1: "Sine", 2: "Log1", 3: "InvSCurve", 4: "Linear", 5: "SCurve", 6: "Exp1",
                7: "SineRecip", 8: "Exp3", 9: "Constant"}


class R:
    def __init__(self, b, o, end):
        self.b, self.o, self.end = b, o, end

    def u8(self):
        v = self.b[self.o]
        self.o += 1
        return v

    def u16(self):
        v = struct.unpack_from("<H", self.b, self.o)[0]
        self.o += 2
        return v

    def u32(self):
        v = struct.unpack_from("<I", self.b, self.o)[0]
        self.o += 4
        return v

    def s32(self):
        v = struct.unpack_from("<i", self.b, self.o)[0]
        self.o += 4
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.b, self.o)[0]
        self.o += 4
        return v

    def var(self):
        """7-bit packed int (AkBankReadVar)."""
        v = 0
        while True:
            c = self.u8()
            v = (v << 7) | (c & 0x7F)
            if not c & 0x80:
                return v

    def raw(self, n):
        v = self.b[self.o:self.o + n]
        self.o += n
        return v


def curve(r):
    pts = []
    for _ in range(r.u16()):
        pts.append((r.f32(), r.f32(), CURVE_INTERP.get(r.u32(), "?")))
    return pts


def initial_rtpc(r):
    out = []
    for _ in range(r.u16()):
        rid = r.u32()
        rtype = r.u8()
        accum = r.u8()
        pid = r.var()
        cid = r.u32()
        scaling = r.u8()
        out.append({"rtpc": rid, "type": rtype, "accum": accum, "param": RTPC_PARAM.get(pid, pid), "curve_id": cid,
                    "scaling": scaling, "points": curve(r)})
    return out


def state_params(r):
    """v135 StateParams: (var PropertyId, u8 accumType, u8 inDb) list, then state groups (var counts)."""
    props = [{"param": RTPC_PARAM.get(p, p), "accum": a, "in_db": d}
             for p, a, d in [(r.var(), r.u8(), r.u8()) for _ in range(r.var())]]
    groups = []
    for _ in range(r.var()):
        gid = r.u32()
        sync = r.u8()
        groups.append({"group": gid, "sync": sync, "states": [(r.u32(), r.u32()) for _ in range(r.var())]})
    return props, groups


def prop_bundle(r):
    n = r.u8()
    ids = [r.u8() for _ in range(n)]
    out = {}
    for i in ids:
        name = PROP.get(i, f"prop_{i:#x}")
        out[name] = r.u32() if name in INT_PROPS else r.f32()
    return out


def ranged_bundle(r):
    n = r.u8()
    ids = [r.u8() for _ in range(n)]
    return {PROP.get(i, f"prop_{i:#x}"): (r.f32(), r.f32()) for i in ids}


def node_base(r):
    nb = {}
    nb["fx_override"] = r.u8()
    nfx = r.u8()
    fx = []
    if nfx:
        nb["fx_bypass_bits"] = r.u8()
        for _ in range(nfx):
            fx.append({"index": r.u8(), "fx_id": r.u32(), "shareset": r.u8(), "rendered": r.u8()})
    nb["fx"] = fx
    nb["override_attachment"] = r.u8()
    nb["override_bus"] = r.u32()
    nb["parent"] = r.u32()
    nb["priority_bits"] = r.u8()
    nb["props"] = prop_bundle(r)
    nb["ranged"] = ranged_bundle(r)
    pos = r.u8()
    p = {"bits": pos, "override": bool(pos & 1), "listener_relative_routing": bool(pos & 2),
         "panner": (pos >> 2) & 3, "position_type": (pos >> 5) & 3}
    if pos & 2:
        b3 = r.u8()
        p["bits3d"] = b3
        p["spatialization"] = b3 & 3
        if p["position_type"] != 0:
            p["path_mode"] = r.u8()
            p["transition_time"] = r.s32()
            nv = r.u32()
            p["vertices"] = [(r.f32(), r.f32(), r.f32(), r.s32()) for _ in range(nv)]
            npl = r.u32()
            p["playlist"] = [(r.u32(), r.u32()) for _ in range(npl)]
            p["automation"] = [(r.f32(), r.f32(), r.f32()) for _ in range(npl)]
    nb["positioning"] = p
    aux = r.u8()
    nb["aux_bits"] = aux
    if aux & 0x08:
        nb["aux"] = [r.u32() for _ in range(4)]
    nb["reflections_aux"] = r.u32()
    nb["adv"] = {"bits": r.u8(), "virtual_queue": r.u8(), "max_instances": r.u16(), "below_threshold": r.u8(),
                 "hdr_bits": r.u8()}
    nb["state_props"], nb["state_groups"] = state_params(r)
    nb["rtpc"] = initial_rtpc(r)
    return nb


def source(r):
    s = {"plugin": r.u32(), "stream_type": r.u8(), "source_id": r.u32(), "mem_size": r.u32(), "bits": r.u8()}
    ptype = s["plugin"] & 0xF
    if ptype == 2:   # source plugin (e.g. Wwise Silence) carries its param block
        size = r.u32()
        s["params"] = r.raw(size).hex()
    s["external"] = (s["plugin"] >> 16) == 8 and ptype == 1
    return s


def parse(b, t, oid, off, size):
    r = R(b, off, off - 4 + size)
    o = {"type": HIRC_TYPES[t], "id": oid}
    if t == 2:
        o["source"] = source(r)
        o.update(node_base(r))
    elif t == 7:
        o.update(node_base(r))
        o["children"] = [r.u32() for _ in range(r.u32())]
    elif t == 6:
        o.update(node_base(r))
        o["group_type"] = r.u8()
        o["group_id"] = r.u32()
        o["default_switch"] = r.u32()
        o["continuous_validation"] = r.u8()
        o["children"] = [r.u32() for _ in range(r.u32())]
        groups = []
        for _ in range(r.u32()):
            sw = r.u32()
            groups.append({"switch": sw, "nodes": [r.u32() for _ in range(r.u32())]})
        o["switch_groups"] = groups
        params = []
        for _ in range(r.u32()):
            params.append({"node": r.u32(), "bits1": r.u8(), "bits2": r.u8(), "fade_out": r.s32(),
                           "fade_in": r.s32()})
        o["switch_params"] = params
    elif t == 5:
        o.update(node_base(r))
        o["loop_count"] = r.u16()
        o["loop_mod"] = (r.u16(), r.u16())
        o["transition_time"] = r.f32()
        o["transition_mod"] = (r.f32(), r.f32())
        o["avoid_repeat_count"] = r.u16()
        o["transition_mode"] = r.u8()
        o["random_mode"] = r.u8()
        o["mode"] = r.u8()
        o["bits"] = r.u8()
        o["children"] = [r.u32() for _ in range(r.u32())]
        o["playlist"] = [(r.u32(), r.s32()) for _ in range(r.u16())]
    elif t == 3:
        o["action_type"] = r.u16()
        o["target"] = r.u32()
        o["is_bus"] = r.u8()
        o["props"] = prop_bundle(r)
        o["ranged"] = ranged_bundle(r)
        o["rest"] = r.raw(r.end - r.o).hex()
    elif t == 4:
        o["actions"] = [r.u32() for _ in range(r.var())]
    elif t == 14:
        o["cone"] = r.u8()
        if o["cone"]:
            o["cone_params"] = [r.f32() for _ in range(5)]
        o["curve_map"] = [r.u8() for _ in range(7)]
        curves = []
        for _ in range(r.u8()):
            scaling = r.u8()
            curves.append({"scaling": scaling, "points": curve(r)})
        o["curves"] = curves
        o["rtpc"] = initial_rtpc(r)
    elif t in (16, 17):
        o["plugin"] = r.u32()
        n = r.u32()
        o["params"] = r.raw(n).hex()
        o["bank_data"] = [(r.u8(), r.u32()) for _ in range(r.u8())]
        o["rtpc"] = initial_rtpc(r)
        o["state_props"], o["state_groups"] = state_params(r)
        o["prop_values"] = [(r.u16(), r.f32()) for _ in range(r.u16())]
    elif t == 1:
        o["props"] = {PROP.get(i, i): v for i, v in [(r.u16(), r.f32()) for _ in range(r.u16())]}
    else:
        o["rest"] = r.raw(r.end - r.o).hex()
    o["_consumed_exactly"] = r.o == r.end
    if r.o != r.end:
        o["_left"] = r.end - r.o
    return o


def parse_bank(b):
    return {oid: parse(b, t, oid, off, s) for t, oid, off, s in hirc(b)}
