"""Exact constant-buffer / register bindings of DI2's Splatter compute shaders, read from the frozen global shader map
(GlobalShaderCache-PCD3D_SM5.bin) at the member offsets the exe's shader constructors bind (decompiled:
FSplatterBaseCS 0x1409fe3a0, FDismemberBaseCS 0x1409fd960, FSplatterDeformMeshCS 0x1409fd560).

FShaderParameter = {u16 BufferIndex, u16 BaseIndex (bytes into the cbuffer), u16 NumBytes}; NumBytes 0 = unbound.
FShaderResourceParameter = {u16 BaseIndex (register), u16 NumResources}.
Also maps each shader to its archive index in ShaderArchive-Global (same rule as tools/shaders/material_map.py).
usage: python tools/re_dismember/params.py [type-regex]       (reads extracted/shaders/archive/, local data only)"""
import re
import struct
import sys

sys.path.insert(0, r"tools\shaders")
import frozen  # noqa: E402
import shader_archive  # noqa: E402

ARCH = r"extracted\shaders\archive"
NAMES = r"extracted\shaders\name_hashes.tsv"

BASE = [  # FSplatterBaseCS (0x1409fe3a0): (offset, kind, name); R = resource (4 bytes), P = parameter (6 bytes)
    (0xa0, "R", "PositionBufferUAV"), (0xa4, "R", "TangentBufferUAV"), (0xa8, "R", "UVBufferUAV"),
    (0xac, "R", "ColourBufferUAV"), (0xb0, "R", "SkinBufferUAV"), (0xb4, "R", "DeformBufferUAV"),
    (0xb8, "R", "SoftBodyBufferUAV"), (0xbc, "R", "IndirectArgsUAV"), (0xc0, "R", "IndexBufferUAV"),
    (0xc4, "R", "MiscBufferUAV"), (0xc8, "R", "PositionBufferSRV"), (0xcc, "R", "TangentBufferSRV"),
    (0xd0, "R", "UVBufferSRV"), (0xd4, "R", "ColourBufferSRV"), (0xd8, "R", "SkinBufferSRV"),
    (0xdc, "R", "DeformBufferSRV"), (0xe0, "R", "SoftBodyBufferSRV"), (0xe4, "R", "IndexBufferSRV"),
    (0xe8, "R", "IndirectArgsSRV"), (0xec, "R", "MiscBufferSRV"),
    (0xf0, "P", "SRVStrides0"), (0xf6, "P", "SRVStrides1"), (0xfc, "P", "UAVStrides0"), (0x102, "P", "UAVStrides1"),
    (0x108, "P", "SRVOffsets"), (0x10e, "P", "UAVOffsets"), (0x114, "P", "c_DrawParams"),
    (0x11a, "P", "c_SectionParameters"),
]
DISMEMBER = [  # FDismemberBaseCS (0x1409fd960), size 0x160
    (0x130, "R", "BoneTopologySRV"), (0x134, "P", "c_DecalMatrix"), (0x13a, "P", "c_SafeRegionMatrix"),
    (0x140, "P", "c_BoneMatrix"), (0x146, "P", "c_TargetBoneData"), (0x14c, "P", "c_IndirectArgsIndexParameter"),
    (0x152, "P", "c_UseTrim"), (0x158, "P", "c_BinaryDismember"),
]
DEFORM = [  # FSplatterDeformMeshCS (0x1409fd560), size 0x1d0
    (0x130, "P", "c_LocalToWorldMatrix"), (0x136, "P", "c_DecalMatrixArray"), (0x13c, "P", "c_SafeRegionMatrixArray"),
    (0x142, "P", "c_ScaleVecArray"), (0x148, "P", "c_ClearValueArray"), (0x14e, "P", "c_DeformParamsArray"),
    (0x154, "P", "c_RangeParamsArray")] + [(0x15a + 4 * i, "R", f"s_DispTexArray_{i}") for i in range(16)] + [
    (0x19a, "R", "s_DispTexSampler"), (0x19e, "R", "BoneMatrixSRV"), (0x1a2, "P", "IsSoftUpdate"),
    (0x1a8, "P", "SoftPosition"), (0x1ae, "P", "SoftAxis"), (0x1b4, "P", "SoftRadius"), (0x1ba, "P", "SoftInfluence"),
    (0x1c0, "P", "SoftFade"), (0x1c6, "P", "SoftNumVolumes"),
]
LAYOUT = {"FSplatterBreakCS": DISMEMBER, "FSplatterGeometryCS_FourBone": DISMEMBER,
          "FSplatterGeometryCS_FourBone_TwoUV": DISMEMBER, "FSplatterGeometryIndicesCS_FourBone": DISMEMBER,
          "FSplatterConsolidateStaticIArgCS": DISMEMBER, "FSplatterDeformMeshCS": DEFORM}


def main():
    rx = re.compile(sys.argv[1] if len(sys.argv) > 1 else ".")
    names = {}
    for line in open(NAMES, encoding="utf-8"):
        h, n = line.rstrip("\n").split("\t")
        names[int(h, 16)] = n
    cache = open(ARCH + r"\GlobalShaderCache-PCD3D_SM5.bin", "rb").read()
    maps, _ = frozen.global_cache(cache)
    lib = shader_archive.parse(ARCH + r"\ShaderArchive-Global-PCD3D_SM5.ushaderbytecode")
    smh = {h: i for i, h in enumerate(lib["shadermap_hashes"])}
    for sm in maps:
        shaders, src = frozen.global_shaders(sm)
        mi = smh.get(sm.get("resource_hash"))
        if mi is None:
            continue
        ioff, nsh, _, _ = lib["shadermaps"][mi]
        sh_idx = lib["indices"][ioff:ioff + nsh]
        for s in shaders:
            tname = names.get(s["type_hash"], hex(s["type_hash"]))
            if not tname.startswith(("FSplatter", "FDismember")) or not rx.search(tname):
                continue
            f, at = sm["frozen"], s["at"]
            li = sh_idx[s["resource_index"]] if 0 <= s["resource_index"] < len(sh_idx) else None
            print(f"== {tname} perm {s['permutation']} {s['freq']} lib {li} instr {s['instructions']}")
            for off, kind, nm in BASE + LAYOUT.get(tname, []):
                if kind == "P":
                    bi, base, nb = struct.unpack_from("<HHH", f, at + off)
                    if nb:
                        print(f"   {nm:28s} cb{bi} byte {base:5d} = c{base // 16}.{'xyzw'[(base % 16) // 4]}  {nb} bytes")
                else:
                    base, num = struct.unpack_from("<HH", f, at + off)
                    if num:
                        print(f"   {nm:28s} register {base} x{num}")


if __name__ == "__main__":
    main()
