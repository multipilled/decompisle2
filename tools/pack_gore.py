"""Build game/assets/di2/gore from di2x mesh exports of the user's own install.

Outputs (all local, gitignored with the rest of assets/di2):
  breakage.glb      DI2's bone-breakout shards SM_BreakageA-E (one node each, original pivots)
  blood_gibs.glb    DI2's flat gore splats SM_BloodGibs1-7 (alpha-masked floor meshes)
  head_viscera.glb  the Walker's skull/brain/jaw section split into its pieces
  organs.glb        the Walker's torso viscera split into its organs
  viscera.json      per piece: the VisceraProxy it matched, its group, rupture bone and rest centre
plus <name>.materials.json + textures/ via pack_materials.py.

Viscera pieces are the connected islands of the merged character mesh. Each island is assigned to the
VisceraProxy box (Viscera_ZombieStandard) it sits in; the proxy's RuptureBoneId says which bone the piece
belongs to. Piece meshes are re-centred on their island centre; the node keeps that centre as its
translation, so the scene still reassembles the head/torso in the character's bind pose.

usage: pack_gore.py   (after: di2x.sh mesh 'Dismemberment/SM_Breakage|BloodGibs/SM_BloodGibs' and
                       di2x.sh json 'Viscera/Male/Viscera_ZombieStandard')
"""
import json
import shutil
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import pack_materials  # noqa: E402

ROOT = Path(r".")
MESH = ROOT / "extracted/mesh/DeadIsland/Content"
JSON = ROOT / "extracted/json/DeadIsland/Content"
RAWANIM = ROOT / "extracted/rawanim"
OUT = ROOT / "game/assets/di2/gore"

BREAKAGE = [MESH / f"DIShared/Art/Characters/Dismemberment/SM_Breakage{c}.glb" for c in "ABCDE"]
BLOOD_GIBS = [MESH / f"DIShared/Art/Characters/Internal/Viscera/Generic/BloodGibs/SM_BloodGibs{i}.glb" for i in range(1, 8)]
WALKER = MESH / "DI2/Art/Characters/ZombieMale/Walker/SK_WalkerMaleCas01.glb"
VISCERA = JSON / "DIShared/Art/Characters/Internal/Viscera/Male/Viscera_ZombieStandard.json"

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


# --- glb io -----------------------------------------------------------------------------------------

def read_glb(path):
    b = Path(path).read_bytes()
    jl = struct.unpack_from("<I", b, 12)[0]
    g = json.loads(b[20:20 + jl])
    bl = struct.unpack_from("<I", b, 20 + jl)[0]
    return g, b[28 + jl:28 + jl + bl]


def accessor(g, binchunk, i):
    a = g["accessors"][i]
    bv = g["bufferViews"][a["bufferView"]]
    dt, n = np.dtype(CT[a["componentType"]]), NC[a["type"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride", 0) or dt.itemsize * n
    raw = np.frombuffer(binchunk, np.uint8, stride * (a["count"] - 1) + dt.itemsize * n, start)
    rows = np.lib.stride_tricks.as_strided(raw, (a["count"], dt.itemsize * n), (stride, 1))
    return np.frombuffer(rows.copy().tobytes(), dt).reshape(a["count"], n)


def primitives(path):
    """[(material name, {POSITION, NORMAL, TEXCOORD_0}, indices (n,3))] of every primitive."""
    g, b = read_glb(path)
    mats = [m.get("name", "") for m in g.get("materials", [])]
    out = []
    for m in g["meshes"]:
        for pr in m["primitives"]:
            attrs = {k: accessor(g, b, pr["attributes"][k]).astype(np.float32)
                     for k in ("POSITION", "NORMAL", "TEXCOORD_0") if k in pr["attributes"]}
            idx = accessor(g, b, pr["indices"]).reshape(-1, 3).astype(np.int64)
            out.append((mats[pr["material"]] if "material" in pr else "", attrs, idx))
    return out


class GlbWriter:
    """Static meshes, one node per piece: name, material name, vertex arrays, indices, translation."""

    def __init__(self):
        self.g = {"asset": {"version": "2.0", "generator": "DI2 pack_gore.py"}, "scene": 0, "scenes": [{"nodes": []}],
                  "nodes": [], "meshes": [], "materials": [], "accessors": [], "bufferViews": [], "buffers": [{}]}
        self.bin = bytearray()
        self.mat_index = {}

    def _acc(self, arr, typ, target, minmax=False):
        while len(self.bin) % 4:
            self.bin += b"\0"
        arr = np.ascontiguousarray(arr)
        self.g["bufferViews"].append({"buffer": 0, "byteOffset": len(self.bin), "byteLength": arr.nbytes, "target": target})
        self.bin += arr.tobytes()
        a = {"bufferView": len(self.g["bufferViews"]) - 1, "componentType": 5125 if arr.dtype == np.uint32 else 5126,
             "count": len(arr) if typ != "SCALAR" else arr.size, "type": typ}
        if minmax:
            a["min"] = arr.min(0).tolist()
            a["max"] = arr.max(0).tolist()
        self.g["accessors"].append(a)
        return len(self.g["accessors"]) - 1

    def add(self, name, material, attrs, idx, translation=(0.0, 0.0, 0.0)):
        if material not in self.mat_index:
            self.mat_index[material] = len(self.g["materials"])
            self.g["materials"].append({"name": material, "pbrMetallicRoughness": {}})
        used = np.unique(idx)
        remap = np.full(idx.max() + 1, -1, np.int64)
        remap[used] = np.arange(len(used))
        prim = {"attributes": {"POSITION": self._acc(attrs["POSITION"][used].astype(np.float32), "VEC3", 34962, True)},
                "indices": self._acc(remap[idx].astype(np.uint32).ravel(), "SCALAR", 34963),
                "material": self.mat_index[material]}
        if "NORMAL" in attrs:
            n = attrs["NORMAL"][used].astype(np.float32)
            n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-8)
            prim["attributes"]["NORMAL"] = self._acc(n, "VEC3", 34962)
        if "TEXCOORD_0" in attrs:
            prim["attributes"]["TEXCOORD_0"] = self._acc(attrs["TEXCOORD_0"][used].astype(np.float32), "VEC2", 34962)
        self.g["meshes"].append({"name": name, "primitives": [prim]})
        node = {"name": name, "mesh": len(self.g["meshes"]) - 1}
        if any(abs(t) > 0 for t in translation):
            node["translation"] = [float(t) for t in translation]
        self.g["nodes"].append(node)
        self.g["scenes"][0]["nodes"].append(len(self.g["nodes"]) - 1)

    def write(self, path):
        while len(self.bin) % 4:
            self.bin += b"\0"
        self.g["buffers"][0]["byteLength"] = len(self.bin)
        js = json.dumps(self.g, separators=(",", ":")).encode()
        while len(js) % 4:
            js += b" "
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        data = struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js
        data += struct.pack("<II", len(self.bin), 0x004E4942) + bytes(self.bin)
        Path(path).write_bytes(data)


# --- viscera ----------------------------------------------------------------------------------------

def islands(pos, idx):
    """Connected components of a triangle list, welding split vertices by position. Returns per-triangle ids."""
    _, weld = np.unique(np.round(pos / 1e-4).astype(np.int64), axis=0, return_inverse=True)
    weld = weld.ravel()
    parent = np.arange(weld.max() + 1)

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b, c in weld[idx]:
        ra = find(a)
        parent[find(b)] = ra
        parent[find(c)] = ra
    roots = np.array([find(w) for w in range(len(parent))])
    return roots[weld][idx[:, 0]]


def bone_names():
    """SKEL_ZombieStandard bone order (RuptureBoneId indexes it), from any Walker clip's metadata."""
    meta = next(RAWANIM.glob("A_ZMB_Walker_*.json"))
    return [b["Name"] for b in json.loads(meta.read_text())["Bones"]]


def load_proxies():
    names = bone_names()
    exports = json.loads(VISCERA.read_text(encoding="utf-8"))
    groups = {}
    for e in exports:
        if e["Type"] == "VisceraGroup":
            groups[e["Name"]] = e["Properties"].get("Name", e["Name"])
    proxies = []
    for e in exports:
        if e["Type"] != "VisceraProxy" or "VisceraSubsections" not in e["Properties"]:
            continue
        p = e["Properties"]
        loc = p.get("Location", {})
        t = loc.get("Translation", {})
        outer = e.get("Outer", {}).get("ObjectName", "")
        group = next((g for k, g in groups.items() if f":{k}'" in outer), "Loose")
        bone = p.get("RuptureBoneId", -1)
        proxies.append({
            "name": p["Name"], "group": group, "bone": names[bone] if 0 <= bone < len(names) else "",
            "gib": "GibbableSectionAttachment" in p,
            "t": np.array([t.get("X", 0.0), t.get("Y", 0.0), t.get("Z", 0.0)]),
        })
    return proxies


def assign(centre_gltf, proxies):
    """Proxy whose box centre (UE component space, cm) is nearest. (Box-normalised distance mismatches the
    big skull pieces; the plain nearest centre gives every head island a distinct proxy.)"""
    p = np.array([centre_gltf[0], centre_gltf[2], centre_gltf[1]]) * 100.0  # glTF (x, y, z) m -> UE (x, z, y) cm
    return min(((px, float(np.linalg.norm(p - px["t"]))) for px in proxies), key=lambda x: x[1])


def split_viscera(materials, groups, out_name, proxies, manifest):
    """Islands of the Walker primitives with these materials, merged per matched proxy."""
    pieces = {}
    for mat, attrs, idx in primitives(WALKER):
        if mat not in materials:
            continue
        tri_island = islands(attrs["POSITION"], idx)
        for isl in np.unique(tri_island):
            tris = idx[tri_island == isl]
            centre = attrs["POSITION"][np.unique(tris)].mean(0)
            px, d = assign(centre, [p for p in proxies if p["group"] in groups])
            key = (px["name"], mat)
            pieces.setdefault(key, (px, attrs, []))[2].append(tris)
    w = GlbWriter()
    seen = {}
    for (name, mat), (px, attrs, tri_lists) in sorted(pieces.items(), key=lambda kv: kv[0]):
        tris = np.concatenate(tri_lists)
        used = np.unique(tris)
        centre = attrs["POSITION"][used].mean(0)
        local = dict(attrs)
        local["POSITION"] = attrs["POSITION"] - centre
        n = seen.get(name, 0)
        seen[name] = n + 1
        node = name if n == 0 else f"{name}_{n}"
        w.add(node, mat, local, tris, centre)
        size = attrs["POSITION"][used].max(0) - attrs["POSITION"][used].min(0)
        manifest[node] = {"file": out_name, "proxy": name, "group": px["group"], "bone": px["bone"], "gib": px["gib"],
                          "rest_centre": [round(float(c), 4) for c in centre], "size": [round(float(c), 4) for c in size],
                          "tris": int(len(tris))}
    w.write(OUT / out_name)
    print(f"{out_name}: {len(seen)} pieces")


def merge_static(sources, out_name, node_names):
    w = GlbWriter()
    for src, node in zip(sources, node_names):
        for mat, attrs, idx in primitives(src):
            w.add(node, mat, attrs, idx)
    w.write(OUT / out_name)
    print(f"{out_name}: {len(sources)} meshes")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    merge_static(BREAKAGE, "breakage.glb", [p.stem.replace("SM_", "") for p in BREAKAGE])
    merge_static(BLOOD_GIBS, "blood_gibs.glb", [p.stem.replace("SM_", "") for p in BLOOD_GIBS])
    proxies = load_proxies()
    manifest = {}
    split_viscera({"MI_WalkerSkullMidFront"}, {"Head"}, "head_viscera.glb", proxies, manifest)
    split_viscera({"MI_WalkerViscera", "MI_WalkerVisceraVarB"}, {"Guts", "Loose"}, "organs.glb", proxies, manifest)
    (OUT / "viscera.json").write_text(json.dumps(manifest, indent=1))
    glbs = ("breakage.glb", "blood_gibs.glb", "head_viscera.glb", "organs.glb")
    pack_materials.main([str(OUT / n) for n in glbs])
    inherit_from_walker(glbs)


def inherit_from_walker(glbs):
    """The Walker's viscera MIs set no textures of their own (they inherit them from a parent material);
    the Walker body manifest already resolved them, so reuse its texture slots for the same materials."""
    walker_dir = ROOT / "game/assets/di2/walker"
    walker = json.loads((walker_dir / "walker.materials.json").read_text())
    for name in glbs:
        path = OUT / name.replace(".glb", ".materials.json")
        manifest = json.loads(path.read_text())
        for mat, entry in manifest.items():
            src = walker.get(mat)
            if not src or "albedo" in entry:
                continue
            for slot in ("albedo", "normal", "mro", "ata"):
                if slot in src:
                    shutil.copy2(walker_dir / src[slot], OUT / src[slot])
                    entry[slot] = src[slot]
            for key in ("masked", "clip", "layer"):
                entry[key] = src.get(key, entry[key])
            print(f"   {mat}: textures from walker.materials.json")
        path.write_text(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()
