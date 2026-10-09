"""Static helpers over DI2's shipping exe (never run): PE sections, strings, pointer scans, UE4.27 reflection.

UE 4.27 compiled reflection (UObjectGlobals.h, shipping, no metadata):
  FPropertyParamsBase        { const char* NameUTF8; const char* RepNotifyFuncUTF8; uint64 PropertyFlags;
                               uint8 Flags (EPropertyGenFlags); uint32 ObjectFlags; int32 ArrayDim; }   0x24 bytes
  FPropertyParamsBaseWithOffset : base + int32 Offset                                                   @0x24
  FBoolPropertyParams        : base + uint32 ElementSize; uint8 SizeOf; void (*SetBitFunc)(void*)       (no offset)
Personal-use research notes; nothing from here is published.
usage (library): from di2exe import Exe; e = Exe(); e.props_named("HitsToDeathMaxBlendThreshold")
"""
import mmap
import re
import struct
import sys
from functools import cached_property

import pefile

EXE = r"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Binaries\Win64\DeadIsland-Win64-Shipping.exe"

GEN_FLAGS = {0x00: "Byte", 0x01: "Int8", 0x02: "Int16", 0x03: "Int", 0x04: "Int64", 0x05: "UInt16", 0x06: "UInt32",
             0x07: "UInt64", 0x08: "UnsizedInt", 0x09: "UnsizedUInt", 0x0A: "Float", 0x0B: "Double", 0x0C: "Bool",
             0x0D: "SoftClass", 0x0E: "WeakObject", 0x0F: "LazyObject", 0x10: "SoftObject", 0x11: "Class",
             0x12: "Object", 0x13: "Interface", 0x14: "Name", 0x15: "Str", 0x16: "Array", 0x17: "Map", 0x18: "Set",
             0x19: "Struct", 0x1A: "Delegate", 0x1B: "InlineMulticastDelegate", 0x1C: "SparseMulticastDelegate",
             0x1D: "Text", 0x1E: "Enum", 0x1F: "FieldPath"}


class Exe:
    def __init__(self, path=EXE):
        self.f = open(path, "rb")
        self.m = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        self.pe = pefile.PE(path, fast_load=True)
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.secs = [(s.Name.rstrip(b"\0").decode(), self.base + s.VirtualAddress, s.Misc_VirtualSize,
                      s.PointerToRawData, s.SizeOfRawData) for s in self.pe.sections]

    # --- address mapping ---------------------------------------------------------------------------------------
    def off(self, va):
        for _, v, vs, raw, rs in self.secs:
            if v <= va < v + min(vs, rs):
                return raw + (va - v)
        return None

    def va(self, off):
        for _, v, vs, raw, rs in self.secs:
            if raw <= off < raw + rs:
                return v + (off - raw)
        return None

    def sec(self, name):
        return next(s for s in self.secs if s[0] == name)

    def read(self, va, n):
        o = self.off(va)
        return bytes(self.m[o:o + n]) if o is not None else None

    def q(self, va):
        return struct.unpack("<Q", self.read(va, 8))[0]

    def i32(self, va):
        return struct.unpack("<i", self.read(va, 4))[0]

    def cstr(self, va, limit=256):
        b = self.read(va, limit)
        return b.split(b"\0")[0].decode("latin1") if b else None

    # --- searches ----------------------------------------------------------------------------------------------
    def find_all(self, needle, start=0, end=None):
        out, i = [], self.m.find(needle, start, end if end else len(self.m))
        while i >= 0:
            out.append(i)
            i = self.m.find(needle, i + 1, end if end else len(self.m))
        return out

    def string_vas(self, s, wide=False):
        b = (s.encode("utf-16-le") + b"\0\0") if wide else (s.encode() + b"\0")
        return [self.va(o) for o in self.find_all(b) if (wide or o == 0 or self.m[o - 1] == 0)]

    def pointers_to(self, target_va, sections=(".rdata", ".data")):
        needle = struct.pack("<Q", target_va)
        out = []
        for name in sections:
            try:
                _, v, vs, raw, rs = self.sec(name)
            except StopIteration:
                continue
            out += [self.va(o) for o in self.find_all(needle, raw, raw + rs) if (o - raw) % 8 == 0]
        return out

    def rip_refs(self, target_va, text=".text"):
        """Code locations with a RIP-relative disp32 that resolves to target_va (lea/mov/cmp ...)."""
        _, v, vs, raw, rs = self.sec(text)
        data = self.m[raw:raw + rs]
        out = []
        # disp32 at position p resolves to (va_of_next_insn + disp). Next insn = p + 4 (+ imm bytes, rare for lea).
        lo, hi = target_va - (v + rs) - 8, target_va - v + 8
        for p in range(0, rs - 4):
            pass
        # Fast path: scan for each possible 4-byte disp is too slow in pure Python; use regex over candidate opcodes.
        for m in re.finditer(rb"[\x48\x4c][\x8d\x8b\x89\x3b\x39][\x05\x0d\x15\x1d\x25\x2d\x35\x3d]", data):
            p = m.end()
            disp = struct.unpack_from("<i", data, p)[0]
            if v + p + 4 + disp == target_va:
                out.append(v + m.start())
        return out

    @cached_property
    def rip_table(self):
        """(sites, targets) numpy arrays of every REX lea/mov/cmp rip+disp32 in .text (one scan; see rip_refs)."""
        import numpy as np
        _, v, vs, raw, rs = self.sec(".text")
        b = np.frombuffer(self.m, dtype=np.uint8, count=rs, offset=raw)
        rex = (b[:-7] == 0x48) | (b[:-7] == 0x4C)
        op = np.isin(b[1:-6], np.array([0x8D, 0x8B, 0x89, 0x3B, 0x39], dtype=np.uint8))
        modrm = (b[2:-5] & 0xC7) == 0x05
        idx = np.nonzero(rex & op & modrm)[0]
        d = (b[idx + 3].astype(np.int64) | (b[idx + 4].astype(np.int64) << 8) | (b[idx + 5].astype(np.int64) << 16)
             | (b[idx + 6].astype(np.int64) << 24))
        d = np.where(d >= 1 << 31, d - (1 << 32), d)
        return v + idx, v + idx + 7 + d

    def rip_refs_any(self, lo, hi):
        """{target: [sites]} for rip-relative references into [lo, hi)."""
        import numpy as np
        sites, tg = self.rip_table
        sel = np.nonzero((tg >= lo) & (tg < hi))[0]
        out = {}
        for i in sel:
            out.setdefault(int(tg[i]), []).append(int(sites[i]))
        return out

    # --- .pdata ------------------------------------------------------------------------------------------------
    @cached_property
    def functions(self):
        """Sorted (begin_va, end_va) from the exception directory."""
        d = self.pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
        raw = self.off(self.base + d.VirtualAddress)
        out = []
        for i in range(d.Size // 12):
            b, e, _ = struct.unpack_from("<III", self.m, raw + i * 12)
            out.append((self.base + b, self.base + e))
        return sorted(out)

    def func_of(self, va):
        import bisect
        fs = self.functions
        i = bisect.bisect_right(fs, (va, 1 << 64)) - 1
        while i >= 0:
            b, e = fs[i]
            if b <= va < e:
                return (b, e)
            if va - b > 0x20000:
                break
            i -= 1
        return None

    # --- UE reflection -----------------------------------------------------------------------------------------
    def prop_params(self, at):
        name = self.cstr(self.q(at))
        flags = self.q(at + 0x10)
        gen = self.read(at + 0x18, 1)[0]
        kind = GEN_FLAGS.get(gen & 0x3F, hex(gen))
        rec = {"at": hex(at), "name": name, "kind": kind, "flags": hex(flags), "array_dim": self.i32(at + 0x20)}
        if kind != "Bool":
            rec["offset"] = self.i32(at + 0x24)
        else:
            rec["element_size"] = struct.unpack("<I", self.read(at + 0x24, 4))[0]
            rec["setbit"] = hex(self.q(at + 0x30))
        return rec

    def props_named(self, name):
        out = []
        for sva in self.string_vas(name):
            for p in self.pointers_to(sva):
                try:
                    out.append(self.prop_params(p))
                except Exception as ex:  # noqa: BLE001
                    out.append({"at": hex(p), "error": str(ex)})
        return out


if __name__ == "__main__":
    e = Exe()
    for n in sys.argv[1:]:
        for r in e.props_named(n):
            print(n, r)


def struct_members(e, param_va):
    """All properties of the struct/class whose PropPointers array holds a pointer to `param_va`."""
    for arr in e.pointers_to(param_va):
        # walk to the array start / end: consecutive 8-byte pointers to records whose name is a C identifier
        def ok(p):
            try:
                n = e.cstr(e.q(e.q(p)), 80)
                return bool(n) and re.fullmatch(r"[A-Za-z_]\w*", n) is not None
            except Exception:  # noqa: BLE001
                return False
        a = arr
        while ok(a - 8):
            a -= 8
        out = []
        while ok(a):
            out.append(e.prop_params(e.q(a)))
            a += 8
        return out
    return []


def calls_to(e, target, text=".text"):
    """Direct `call rel32` / `jmp rel32` sites whose destination is `target` (numpy scan over .text)."""
    import numpy as np
    _, v, vs, raw, rs = e.sec(text)
    buf = np.frombuffer(e.m, dtype=np.uint8, count=rs, offset=raw)
    out = []
    for op in (0xE8, 0xE9):
        idx = np.nonzero(buf[:-5] == op)[0]
        rel = (buf[idx + 1].astype(np.int64) | (buf[idx + 2].astype(np.int64) << 8) |
               (buf[idx + 3].astype(np.int64) << 16) | (buf[idx + 4].astype(np.int64) << 24))
        rel = np.where(rel >= 1 << 31, rel - (1 << 32), rel)
        dest = v + idx + 5 + rel
        out += [(int(v + i), "call" if op == 0xE8 else "jmp") for i in idx[dest == target]]
    return out


def root_function(e, va):
    """Follow chained UNWIND_INFO (UNW_FLAG_CHAININFO) from the .pdata entry holding `va` to the function head."""
    d = e.pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
    raw = e.off(e.base + d.VirtualAddress)
    entries = {}
    for k in range(d.Size // 12):
        b, en, ui = struct.unpack_from("<III", e.m, raw + k * 12)
        entries[e.base + b] = (e.base + en, e.base + ui)
    f = e.func_of(va)
    if not f:
        return None
    b = f[0]
    for _ in range(64):
        en, ui = entries[b]
        uo = e.off(ui)
        flags, cnt = e.m[uo] >> 3, e.m[uo + 2]
        if not flags & 4:
            return b
        pb, _pe, _pu = struct.unpack_from("<III", e.m, uo + 4 + ((cnt + 1) & ~1) * 2)
        b = e.base + pb
    return b
