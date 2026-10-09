"""Static parser for Dead Island 2 cooked USkeletalMesh LOD render data, including DI2's custom
per-vertex deform stream (the half4 the skin vertex factories bind as ATTRIBUTE16).

Input: the raw package bytes written by `tools/di2x.sh raw` (IoStore package, export data uncompressed).
Layout reference: UE 4.27 FSkeletalMeshLODRenderData::Serialize / SerializeStreamedData, with the DI2
differences that CUE4Parse handles (GameTypes/DeadIsland2, FSkelMeshSection.cs, FStaticLODModel.cs):
  * FSkelMeshSection has a trailing TArray<18-byte item> + 2 bytes (DI2 custom).
  * Index buffers hold section-relative indices (add BaseVertexIndex).
  * After the standard streamed data an extra vertex buffer follows (CUE4Parse skips it):
      u32 unknown(0) | u32 Stride(8) | u32 NumVertices | i32 ElemSize(8) | i32 Count(N) | N*8 bytes | bool(i32)
    The N*8 bytes are N half4 = (deform.xyz, depth): the stream DeformBufferSRV / ATTRIBUTE16 reads.

Personal-use research tool; reads the user's own extracted files only.
"""
import struct
import numpy as np


class Reader:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.p)[0]; self.p += 4; return v

    def u32(self):
        v = struct.unpack_from("<I", self.d, self.p)[0]; self.p += 4; return v

    def i16(self):
        v = struct.unpack_from("<h", self.d, self.p)[0]; self.p += 2; return v

    def u8(self):
        v = self.d[self.p]; self.p += 1; return v

    def boolean(self):
        v = self.i32()
        if v not in (0, 1):
            raise ValueError(f"bad bool {v} at {self.p - 4:#x}")
        return bool(v)

    def strip(self):
        g, c = self.d[self.p], self.d[self.p + 1]; self.p += 2; return g, c

    def array(self, dtype, count):
        dt = np.dtype(dtype)
        a = np.frombuffer(self.d, dt, count=count, offset=self.p).copy()
        self.p += dt.itemsize * count
        return a

    def bulk(self, dtype=None):
        """TResourceArray::BulkSerialize: i32 element size, i32 count, data. Returns (elem_size, count, offset)."""
        es = self.i32(); n = self.i32(); off = self.p
        self.p += es * n
        return es, n, off


def find_lod_starts(d):
    """Candidate LOD records: strip(2) | bIsLODCookedOut i32 | bInlined i32 | RequiredBones (i32 C + C u16 rising
    from 0) | i32 NumSections. Returns offsets of the strip flags."""
    out = []
    a = np.frombuffer(d[: len(d) // 2 * 2], np.uint16)
    # RequiredBones start with 0,1,2 (root, pelvis, ...) in a skeletal mesh; look for u16 0,1,2,3 runs.
    for odd in range(2):
        b = np.frombuffer(d[odd: odd + (len(d) - odd) // 2 * 2], np.uint16)
        idx = np.where((b[:-3] == 0) & (b[1:-2] == 1) & (b[2:-1] == 2) & (b[3:] == 3))[0]
        for i in idx:
            pos = odd + 2 * i
            c = struct.unpack_from("<i", d, pos - 4)[0]
            if not 20 <= c <= 1000:
                continue
            bones = np.frombuffer(d, np.uint16, count=c, offset=pos)
            if not np.all(np.diff(bones.astype(np.int32)) > 0):
                continue
            cooked_out, inlined = struct.unpack_from("<ii", d, pos - 12)
            if cooked_out not in (0, 1) or inlined not in (0, 1):
                continue
            nsec = struct.unpack_from("<i", d, pos + 2 * c)[0]
            if not 1 <= nsec <= 64:
                continue
            out.append(pos - 14)
    return sorted(out)


def parse_section(r):
    s = {}
    s["strip"] = r.strip()
    s["MaterialIndex"] = r.i16()
    s["BaseIndex"] = r.i32()
    s["NumTriangles"] = r.i32()
    s["bRecomputeTangent"] = r.boolean()
    # (no RecomputeTangentsVertexMaskChannel byte in DI2's cooked data)
    s["bCastShadow"] = r.boolean()
    s["BaseVertexIndex"] = r.u32()
    ncloth = r.i32(); r.p += 64 * ncloth           # TArray<FMeshToMeshVertData>, 64 bytes each
    s["NumClothMapping"] = ncloth
    nbm = r.i32(); s["BoneMap"] = r.array("<u2", nbm)
    s["NumVertices"] = r.i32()
    s["MaxBoneInfluences"] = r.i32()
    s["CorrespondClothAssetIndex"] = r.i16()
    r.p += 20                                       # FClothingSectionData (FGuid + i32 AssetLodIndex)
    if not (s["strip"][1] & 1):                     # DuplicatedVertices unless class-stripped (CUE4Parse rule)
        n = r.i32(); r.p += 4 * n
        n = r.i32(); r.p += 8 * n
    s["bDisabled"] = r.boolean()
    n = r.i32()                                     # DI2 custom: TArray of 18-byte items + 2 bytes
    s["di2_items"] = bytes(r.d[r.p: r.p + 18 * n]); r.p += 18 * n
    s["di2_tail"] = bytes(r.d[r.p: r.p + 2]); r.p += 2
    return s


def octa_none(_):
    return None


def parse_lod(d, start):
    """Parse one inlined LOD record starting at its strip flags. Returns a dict with arrays and offsets."""
    r = Reader(d, start)
    lod = {"offset": start}
    lod["strip"] = r.strip()
    lod["bIsLODCookedOut"] = r.boolean()
    lod["bInlined"] = r.boolean()
    n = r.i32(); lod["RequiredBones"] = r.array("<u2", n)
    nsec = r.i32()
    lod["sections"] = [parse_section(r) for _ in range(nsec)]
    n = r.i32(); lod["ActiveBoneIndices"] = r.array("<u2", n)
    lod["BuffersSize"] = r.u32()
    if not lod["bInlined"]:
        raise ValueError("LOD not inlined: render data lives in bulk data, not handled")
    lod["stream_offset"] = r.p
    lod["stream_strip"] = r.strip()
    # FMultisizeIndexContainer
    isz = r.u8()
    es, n, off = r.bulk()
    assert es == isz, (es, isz)
    lod["indices"] = np.frombuffer(d, "<u2" if isz == 2 else "<u4", count=n, offset=off).astype(np.int64)
    lod["index_offset"] = off
    # FPositionVertexBuffer: Stride, NumVertices, bulk FVector
    stride = r.u32(); nv = r.u32()
    lod["position_header"] = r.p - 8
    es, n, off = r.bulk()
    assert stride == 12 and es == 12 and n == nv, (stride, es, n, nv)
    lod["NumVertices"] = nv
    lod["positions"] = np.frombuffer(d, "<f4", count=3 * nv, offset=off).reshape(nv, 3)
    lod["position_offset"] = off
    # FStaticMeshVertexBuffer
    lod["smvb_strip"] = r.strip()
    ntc = r.i32(); nv2 = r.i32(); full_uv = r.boolean(); hp_tan = r.boolean()
    assert nv2 == nv
    lod["NumTexCoords"] = ntc; lod["bUseFullPrecisionUVs"] = full_uv; lod["bUseHighPrecisionTangentBasis"] = hp_tan
    es, n, off = r.bulk()
    assert n == nv
    lod["tangent_offset"] = off; lod["tangent_elem"] = es
    if hp_tan:
        t = np.frombuffer(d, "<i2", count=nv * 8, offset=off).reshape(nv, 2, 4).astype(np.float32) / 32767.0
    else:
        # FPackedNormal since FRenderingObjectVersion::IncreaseNormalPrecision: signed int8 (CUE4Parse XORs 0x80808080
        # and rescales [0,255] -> [-1,1]; equal to int8/127.5 + 1/255)
        t = (np.frombuffer(d, np.int8, count=nv * 8, offset=off).reshape(nv, 2, 4).astype(np.float32) + 128.0) / 127.5 - 1.0
    lod["tangent_x"] = t[:, 0]; lod["tangent_z"] = t[:, 1]
    es, n, off = r.bulk()
    lod["uv_offset"] = off; lod["uv_elem"] = es
    uvdt = "<f4" if full_uv else "<f2"
    nvt = n // ntc
    lod["uvs"] = np.frombuffer(d, uvdt, count=n * 2, offset=off).reshape(nvt, ntc, 2).astype(np.float32)[:nv]
    # FSkinWeightVertexBuffer (4.27 format): data buffer + lookup buffer
    lod["skin_offset"] = r.p
    r.strip()
    lod["bVariableBonesPerVertex"] = r.boolean()
    lod["MaxBoneInfluences"] = r.u32(); r.u32(); nvw = r.u32(); lod["bUse16BitBoneIndex"] = r.boolean()
    assert nvw == nv
    r.bulk()
    r.strip(); r.i32(); r.bulk()
    # FColorVertexBuffer: strip, Stride, NumVertices, bulk FColor (only if NumVertices > 0)
    lod["color_offset"] = r.p
    r.strip(); cstride = r.u32(); cn = r.u32()
    if cn:
        es, n, off = r.bulk()
        bgra = np.frombuffer(d, np.uint8, count=4 * cn, offset=off).reshape(cn, 4)
        lod["colors"] = bgra[:, [2, 1, 0, 3]]
    lod["after_color"] = r.p
    # Adjacency index buffer (present unless the stream's class strip flag CDSF_AdjacencyData = 1 is set)
    if not (lod["stream_strip"][1] & 1):
        isz = r.u8(); es, n, off = r.bulk()
        assert es == isz
        lod["adjacency_count"] = n
    if any(s["NumClothMapping"] for s in lod["sections"]):
        raise NotImplementedError("cloth vertex buffer present")
    nprof = r.i32()                                 # FSkinWeightProfilesData: TMap count
    assert nprof == 0, nprof
    lod["deform_header"] = r.p                      # DI2 extra vertex buffer follows directly
    return lod, r


def parse_deform(d, pos, nv):
    """DI2 extra vertex buffer at `pos` (the u32 'unknown' field). Returns (half4 array, header dict, end)."""
    r = Reader(d, pos)
    hdr = {"unknown": r.u32(), "stride": r.u32(), "num_vertices": r.u32()}
    es, n, off = r.bulk()
    hdr.update(elem_size=es, count=n, data_offset=off)
    assert hdr["stride"] == 8 and es == 8 and n == nv == hdr["num_vertices"], hdr
    arr = np.frombuffer(d, "<f2", count=4 * n, offset=off).reshape(n, 4)
    hdr["trailing_bool"] = r.boolean()
    return arr, hdr, r.p
