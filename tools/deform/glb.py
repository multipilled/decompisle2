"""Minimal glTF-binary reader (numpy) for the DI2 body glbs. Read-only."""
import json, struct
import numpy as np

_CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
_NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class Glb:
    def __init__(self, path):
        data = open(path, "rb").read()
        magic, ver, length = struct.unpack_from("<III", data, 0)
        assert magic == 0x46546C67, "not a glb"
        off = 12
        self.json = None
        self.bin = None
        while off < length:
            clen, ctype = struct.unpack_from("<II", data, off)
            chunk = data[off + 8: off + 8 + clen]
            if ctype == 0x4E4F534A:
                self.json = json.loads(chunk)
            elif ctype == 0x004E4942:
                self.bin = chunk
            off += 8 + clen

    def accessor(self, idx):
        a = self.json["accessors"][idx]
        bv = self.json["bufferViews"][a["bufferView"]]
        dt = np.dtype(_CT[a["componentType"]])
        nc = _NC[a["type"]]
        start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = bv.get("byteStride", 0)
        if stride and stride != dt.itemsize * nc:
            raw = np.frombuffer(self.bin, np.uint8, count=stride * (a["count"] - 1) + dt.itemsize * nc, offset=start)
            out = np.lib.stride_tricks.as_strided(raw, (a["count"], dt.itemsize * nc), (stride, 1)).copy()
            arr = out.view(dt).reshape(a["count"], nc)
        else:
            arr = np.frombuffer(self.bin, dt, count=a["count"] * nc, offset=start).reshape(a["count"], nc)
        if a.get("normalized"):
            info = np.iinfo(dt)
            arr = np.maximum(arr.astype(np.float32) / info.max, -1.0)
        return arr

    def primitives(self):
        """[(mesh_index, prim_index, material_name, prim_dict)] in file order."""
        out = []
        for mi, m in enumerate(self.json["meshes"]):
            for pi, p in enumerate(m["primitives"]):
                mat = self.json["materials"][p["material"]]["name"] if "material" in p else None
                out.append((mi, pi, mat, p))
        return out
