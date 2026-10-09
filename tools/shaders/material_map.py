"""List a material shader map's shaders: (vertex factory, shader type, permutation) -> ShaderArchive-DeadIsland index.
  python material_map.py <ushaderresources key (MI CustomGameData hash, see shadermaps.exe material)> [type regex]
Writes extracted/shaders/maps/<key>.json."""
import json, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import frozen

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SH = os.path.join(ROOT, "extracted", "shaders")


def names():
    out = {}
    for l in open(os.path.join(SH, "name_hashes.tsv"), encoding="utf-8", errors="replace"):
        h, n = l.rstrip("\n").split("\t", 1)
        out[int(h, 16)] = n
    return out


def table():
    b = open(os.path.join(SH, "archive", "ShaderArchive-DeadIsland-PCD3D_SM5.ushaderresources"), "rb").read()
    n = struct.unpack_from("<I", b, 4)[0]
    p, t = 8, {}
    for _ in range(n):
        t[b[p:p + 20].hex().upper()] = struct.unpack_from("<QI", b, p + 20); p += 32
    return b, p, t


def shader_list(key, rx=".", nm=None, tb=None):
    nm = nm or names()
    b, base, t = tb or table()
    lib = json.load(open(os.path.join(SH, "DeadIsland", "index.json")))
    smidx = {m["hash"]: i for i, m in enumerate(lib["shadermaps"])}
    off, size = t[key.upper()]
    res, _ = frozen.material_blob(b[base + off:base + off + size])
    out = []
    for q, r in enumerate(res):
        if r is None:
            continue
        sh = lib["shadermaps"][smidx[r["resource_hash"]]]["shaders"]
        for vf, s in frozen.material_shaders(r):
            ty = nm.get(s["type"], hex(s["type"]))
            if not re.search(rx, ty):
                continue
            li = sh[s["resource_index"]]
            out.append(dict(quality=r["quality"], vf=nm.get(vf, hex(vf)) if vf else None, type=ty, perm=s["permutation"],
                            freq=s["freq"], lib_index=li, out_hash=lib["shaders"][li]["hash"], instr=s["instructions"],
                            frozen_at=s["at"]))
    return out


if __name__ == "__main__":
    rows = shader_list(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ".")
    os.makedirs(os.path.join(SH, "maps"), exist_ok=True)
    json.dump(rows, open(os.path.join(SH, "maps", sys.argv[1].upper() + ".json"), "w"), indent=1)
    for r in rows:
        print(r["quality"], r["vf"], r["type"], r["perm"], r["freq"], r["lib_index"], r["instr"])
