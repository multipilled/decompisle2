"""Parse a UE4.27 FSerializedShaderArchive (.ushaderbytecode, version 2) from the user's own DI2 install.

Layout (RenderCore ShaderCodeArchive.h, 4.26/4.27):
  uint32 version (2)
  TArray<FSHAHash> ShaderMapHashes; TArray<FSHAHash> ShaderHashes
  TArray<FShaderMapEntry {u32 ShaderIndicesOffset, NumShaders, FirstPreloadIndex, NumPreloadEntries}>
  TArray<FShaderCodeEntry {u64 Offset, u32 Size, u32 UncompressedSize, u8 Frequency}>
  TArray<FFileCachePreloadEntry {i64 Offset, i64 Size}>
  TArray<u32> ShaderIndices
  FString compression format (DI2: "Zstd"), then the code blob: entry Offset is relative to the end of that
  FString; Size != UncompressedSize -> one zstd frame (DI2 builds shader code with a Zstd compression plugin).

Usage: python shader_archive.py <archive> <out_dir>    (writes <index>.bin per shader + index.json)
Needs the `zstandard` module (miniconda python has it). Local only; output stays under extracted/shaders.
"""
import json, os, struct, sys

import zstandard

FREQ = {0: "VS", 1: "HS", 2: "DS", 3: "PS", 4: "GS", 5: "CS"}


class R:
    def __init__(self, b, p=0):
        self.b, self.p = b, p

    def u32(self):
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def arr(self, fmt):
        n = self.u32()
        sz = struct.calcsize(fmt)
        out = [struct.unpack_from(fmt, self.b, self.p + i * sz) for i in range(n)]
        self.p += n * sz
        return out


def parse(path):
    b = open(path, "rb").read()
    r = R(b)
    ver = r.u32()
    assert ver == 2, ver
    smh = [x[0].hex() for x in r.arr("<20s")]
    sh = [x[0].hex() for x in r.arr("<20s")]
    sme = r.arr("<IIII")
    se = r.arr("<QIIB")
    pre = r.arr("<qq")
    idx = [x[0] for x in r.arr("<I")]
    n = r.u32()
    fmt = b[r.p:r.p + n].split(b"\x00")[0].decode()
    r.p += n
    return dict(data=b, base=r.p, format=fmt, shadermap_hashes=smh, shader_hashes=sh, shadermaps=sme,
                shaders=se, preload=pre, indices=idx)


def code(a, i):
    off, size, usize, freq = a["shaders"][i]
    raw = a["data"][a["base"] + off: a["base"] + off + size]
    if size == usize:
        return raw
    assert a["format"] == "Zstd", a["format"]
    return zstandard.ZstdDecompressor().decompress(raw, max_output_size=usize)


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    a = parse(src)
    os.makedirs(out, exist_ok=True)
    meta = {"format": a["format"], "shadermaps": [], "shaders": []}
    for m, (io, n, fp, npre) in enumerate(a["shadermaps"]):
        meta["shadermaps"].append({"hash": a["shadermap_hashes"][m], "shaders": a["indices"][io:io + n]})
    fails = 0
    for i, (off, size, usize, freq) in enumerate(a["shaders"]):
        try:
            c = code(a, i)
        except Exception:
            fails += 1
            c = None
        if c is not None:
            open(os.path.join(out, f"{i:06d}.bin"), "wb").write(c)
        meta["shaders"].append({"i": i, "hash": a["shader_hashes"][i], "freq": FREQ.get(freq, freq), "size": usize,
                                "ok": c is not None})
    json.dump(meta, open(os.path.join(out, "index.json"), "w"), indent=0)
    print(f"{src}: {len(a['shadermaps'])} shadermaps, {len(a['shaders'])} shaders, {fails} undecoded")
