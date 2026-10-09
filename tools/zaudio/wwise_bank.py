"""Minimal reader for DI2's Wwise SoundBank data (bank version 135 = Wwise 2019.2) embedded in UE AkAudioBank /
AkAudioEvent uassets (event-based packaging). Reads chunk layout, HIRC objects and the fields this port needs.
Field layouts follow the Wwise 2019.2 bank format (as documented by the open-source wwiser / vgmstream projects);
every value read is DI2's own bank data. Personal-use research; nothing from here is published.
"""
import struct

HIRC_TYPES = {1: "State", 2: "Sound", 3: "Action", 4: "Event", 5: "RanSeqCntr", 6: "SwitchCntr", 7: "ActorMixer",
              8: "Bus", 9: "LayerCntr", 10: "MusicSegment", 11: "MusicTrack", 12: "MusicSwitch",
              13: "MusicRanSeq", 14: "Attenuation", 15: "DialogueEvent", 16: "FxShareSet", 17: "FxCustom",
              18: "AuxBus", 19: "LFO", 20: "Envelope", 21: "AudioDevice", 22: "TimeMod"}


def fnv(name: str) -> int:
    """Wwise ShortID = 32-bit FNV-1 of the lower-case name."""
    h = 2166136261
    for c in name.lower().encode():
        h = (h * 16777619) & 0xFFFFFFFF
        h ^= c
    return h


def chunks(b: bytes):
    """{tag: (offset of payload, size)} for the bank embedded anywhere in b (starts at 'BKHD')."""
    o = b.find(b"BKHD")
    out = {}
    while 0 <= o < len(b) - 8:
        tag = b[o:o + 4]
        if not tag.isalpha():
            break
        sz = struct.unpack_from("<I", b, o + 4)[0]
        out[tag.decode()] = (o + 8, sz)
        o += 8 + sz
    return out


def hirc(b: bytes):
    """[(type, id, payload_offset (after id), payload_size (incl. id))]"""
    c = chunks(b)
    if "HIRC" not in c:
        return []
    o, _ = c["HIRC"]
    n = struct.unpack_from("<I", b, o)[0]
    p = o + 4
    out = []
    for _ in range(n):
        t = b[p]
        s, oid = struct.unpack_from("<II", b, p + 1)
        out.append((t, oid, p + 9, s))
        p += 5 + s
    return out


def fx_custom(b: bytes, off: int):
    """FxCustom payload (after its id): plugin id, param block bytes."""
    plugin, size = struct.unpack_from("<II", b, off)
    return plugin, b[off + 8: off + 8 + size]


def meter_params(block: bytes):
    """AkMeterFX (plugin 0x00810003) param block: fAttack, fRelease, fMin, fMax, fHold, eMode, eScope,
    bApplyDownstreamVolume, uGameParamID."""
    a, r, mn, mx, h = struct.unpack_from("<5f", block, 0)
    mode, scope, down = block[20], block[21], block[22]
    gp = struct.unpack_from("<I", block, 23)[0]
    return {"attack": a, "release": r, "min": mn, "max": mx, "hold": h, "mode": mode, "scope": scope,
            "apply_downstream_volume": bool(down), "game_param_id": gp}
