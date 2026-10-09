"""DI2 (UE4.27, Dambuster fork) frozen shader-map reader: material shader maps from the .ushaderresources blobs and
the global shader cache (GlobalShaderCache-PCD3D_SM5.bin). Pure python; local data only.

Stream layout (FShaderMapBase::Serialize, 4.27 'old' cooked format, names as FStrings):
  [material only] FMaterialShaderMapId: i32 QualityLevel, i32 FeatureLevel, FSHAHash CookedShaderMapIdHash,
                  FPlatformTypeLayoutParameters {u32 MaxFieldAlignment, u32 Flags}
  u32 FrozenSize, frozen bytes
  i32 NumVTables, i32 NumScriptNames (no MinimalNames in DI2), vtables {u64 hash, TArray<{i32,i32}>},
  script names {FString, TArray<i32>}
  pointer table: i32 NumTypes, i32 NumVFTypes, u64 Types[], u64 VFTypes[], TArray<{u64 hash, u32 size, SHA}>
  bool32 bShareCode, then FSHAHash ResourceHash (shared code) or inline code.
"""
import struct


class S:
    def __init__(self, b, p=0):
        self.b, self.p = b, p

    def r(self, fmt):
        v = struct.unpack_from("<" + fmt, self.b, self.p)
        self.p += struct.calcsize("<" + fmt)
        return v if len(v) > 1 else v[0]

    def fstring(self):
        n = self.r("i")
        if n == 0:
            return ""
        if n < 0:
            s = self.b[self.p:self.p - 2 * n].decode("utf-16le")
            self.p += -2 * n
        else:
            s = self.b[self.p:self.p + n].decode("latin1")
            self.p += n
        return s.rstrip("\0")


def shader_map(s, material):
    out = {}
    if material:
        out["quality"], out["feature"] = s.r("i"), s.r("i")
        out["id_hash"] = s.b[s.p:s.p + 20].hex(); s.p += 20
        out["layout"] = s.r("II")
    size = s.r("I")
    out["frozen"] = s.b[s.p:s.p + size]; s.p += size
    nvt, nsn = s.r("ii")  # DI2: no MinimalNames count (4.25-style)
    nmn = 0
    vts = []
    for _ in range(nvt):
        h = s.r("Q"); n = s.r("i"); vts.append((h, [s.r("ii") for _ in range(n)]))
    names = []
    for _ in range(nsn + nmn):
        nm = s.fstring(); n = s.r("i"); names.append((nm, [s.r("i") for _ in range(n)]))
    out["vtables"], out["names"] = vts, names
    nt, nvf = s.r("ii")
    out["types"] = [s.r("Q") for _ in range(nt)]
    out["vftypes"] = [s.r("Q") for _ in range(nvf)]
    nd = s.r("i")
    deps = []
    for _ in range(nd):
        h = s.r("Q"); sz = s.r("I"); sha = s.b[s.p:s.p + 20].hex(); s.p += 20
        deps.append((h, sz, sha))
    out["deps"] = deps
    share = s.r("I")
    out["share"] = share
    if share:
        out["resource_hash"] = s.b[s.p:s.p + 20].hex(); s.p += 20
    else:
        raise NotImplementedError("inline shader code")
    return out


def material_blob(blob):
    s = S(blob)
    n = s.r("i")
    res = []
    for _ in range(n):
        cooked = s.r("I")
        if not cooked:
            res.append(None); continue
        valid = s.r("I")
        if not valid:
            res.append(None); continue
        res.append(shader_map(s, True))
    return res, s.p


def global_cache(b):
    s = S(b)
    n = s.r("i")
    return [shader_map(s, False) for _ in range(n)], s.p


# --- Frozen FShaderMapContent walk (DI2 layout, worked out from the data; see recon/SHADERS_FLESH.md) -------------
# Pointers: u64, bit0 = frozen, signed offset from the pointer's own address = value >> 1.
# TMemoryImageArray: {ptr, i32 num, i32 max} (16 bytes).
# FShaderMapContent: +0 hash table (24) | +24 ShaderTypes | +40 ShaderPermutations | +56 Shaders (ptrs) |
#   +72 ShaderPipelines | +88 Platform (u8) ; FMaterialShaderMapContent: +96 OrderedMeshShaderMaps (ptrs) ...
#   FMeshMaterialShaderMap: +96 VertexFactoryTypeName (FHashedName u64). FGlobalShaderMapContent: +96 HashedSourceFilename.
# DI2 FShader base (FShader + DI2 compact arrays = a single 8-byte pointer to {u16 count, items}):
#   +0x00 Bindings: 9 compact arrays, +0x48 u32 StructureLayoutHash, +0x4c u16 RootParameterBufferIndex
#   +0x50 ParameterMapInfo: UniformBuffers, TextureSamplers, SRVs, LooseParameterBuffers (compact arrays)
#   +0x70 UniformBufferParameterStructs, +0x78 UniformBufferParameters (compact arrays)
#   +0x80 Type (TIndexedPtr: index<<1|1 into the pointer table's Types), +0x88 VFType (same, VFTypes; 0 = none)
#   +0x90 Target (bits 0-3 frequency, 4-10 platform), +0x94 ResourceIndex, +0x98 NumInstructions
FREQS = {0: "VS", 1: "HS", 2: "DS", 3: "PS", 4: "GS", 5: "CS"}


def _u64(f, p):
    return struct.unpack_from("<Q", f, p)[0]


def ptr(f, p):
    v = struct.unpack_from("<q", f, p)[0]
    return p + (v >> 1) if v & 1 else None


def tarr(f, p):
    d = ptr(f, p)
    n = struct.unpack_from("<i", f, p + 8)[0]
    return d, n


def compact(f, p):
    """DI2 compact array: pointer to {u16 count, then items}; returns (data offset, count)."""
    d = ptr(f, p)
    if d is None:
        return None, 0
    return d + 2, struct.unpack_from("<H", f, d)[0]


def shader(f, p, types, vftypes):
    t = _u64(f, p + 0x80)
    v = _u64(f, p + 0x88)
    tgt = struct.unpack_from("<I", f, p + 0x90)[0]
    ri, ni = struct.unpack_from("<iI", f, p + 0x94)
    return {"at": p, "type": types[t >> 1] if t & 1 else None, "vf": vftypes[v >> 1] if v & 1 else None,
            "freq": FREQS.get(tgt & 15, tgt & 15), "resource_index": ri, "instructions": ni}


def content(f, p, types, vftypes):
    """FShaderMapContent at p: list of shaders with their permutation ids."""
    tp, n = tarr(f, p + 24)
    pp, _ = tarr(f, p + 40)
    sp, _ = tarr(f, p + 56)
    out = []
    for i in range(n):
        s = shader(f, ptr(f, sp + 8 * i), types, vftypes)
        s["type_hash"] = _u64(f, tp + 8 * i)
        s["permutation"] = struct.unpack_from("<i", f, pp + 4 * i)[0]
        out.append(s)
    return out


def material_shaders(sm):
    """All shaders of a material shader map: (vf hash or None, shader dict)."""
    f, types, vft = sm["frozen"], sm["types"], sm["vftypes"]
    out = [(None, s) for s in content(f, 0, types, vft)]
    mp, n = tarr(f, 96)
    for i in range(n):
        m = ptr(f, mp + 8 * i)
        vf = _u64(f, m + 96)
        out += [(vf, s) for s in content(f, m, types, vft)]
    return out


def global_shaders(sm):
    f = sm["frozen"]
    return content(f, 0, sm["types"], sm["vftypes"]), _u64(f, 96)
