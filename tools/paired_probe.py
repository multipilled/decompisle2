"""Paired-clip sanity: angle from Dani's camera (camera_root) to the zombie's head vs the camera's view pitch.
usage: python tools/paired_probe.py <dani glb> <dani clip> <zombie glb> <zombie clip>"""
import sys, importlib.util, numpy as np
spec = importlib.util.spec_from_file_location("fk", "tools/fk_probe.py")

def rig(path):
    import json, struct
    b = open(path, 'rb').read(); jl = struct.unpack('<I', b[12:16])[0]
    g = json.loads(b[20:20 + jl]); bin_ = b[20 + jl + 8:]
    return g, bin_

def acc(g, bin_, i):
    a = g['accessors'][i]; v = g['bufferViews'][a['bufferView']]
    n = {'SCALAR': 1, 'VEC3': 3, 'VEC4': 4}[a['type']]
    off = v.get('byteOffset', 0) + a.get('byteOffset', 0)
    arr = np.frombuffer(bin_, np.float32, a['count'] * n, off)
    return arr.reshape(a['count'], n) if n > 1 else arr

def qmat(q):
    x, y, z, w = q
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])

class Rig:
    def __init__(self, path):
        self.g, self.b = rig(path)
        self.parent = {c: i for i, n in enumerate(self.g['nodes']) for c in n.get('children', [])}
        self.idx = {n.get('name'): i for i, n in enumerate(self.g['nodes'])}
        self.anims = {a['name']: a for a in self.g['animations']}
        # skeleton space = parent of the top skin joint
        skin = self.g['skins'][0]; j0 = skin['joints'][0]
        top = j0
        while self.parent.get(top) in skin['joints']: top = self.parent[top]
        self.skel_parent = self.parent.get(top)
    def length(self, clip):
        return max(acc(self.g, self.b, s['input'])[-1] for s in self.anims[clip]['samplers'])
    def pose(self, clip, t):
        a = self.anims[clip]; pose = {}
        for ch in a['channels']:
            s = a['samplers'][ch['sampler']]
            ts = acc(self.g, self.b, s['input']); vs = acc(self.g, self.b, s['output'])
            k = int(np.clip(np.searchsorted(ts, t) - 1, 0, max(len(ts) - 2, 0)))
            f = 0.0 if len(ts) < 2 else float(np.clip((t - ts[k]) / max(ts[k+1] - ts[k], 1e-6), 0, 1))
            v = vs[k] * (1 - f) + vs[min(k+1, len(vs)-1)] * f
            if ch['target']['path'] == 'rotation': v = v / np.linalg.norm(v)
            pose.setdefault(ch['target']['node'], {})[ch['target']['path']] = v
        return pose
    def world(self, i, pose, cache, stop):
        if i in cache: return cache[i]
        if i == stop or i is None: return np.eye(4)
        n = self.g['nodes'][i]; p = pose.get(i, {})
        m = np.eye(4); m[:3, :3] = qmat(p.get('rotation', n.get('rotation', [0, 0, 0, 1])))
        m[:3, 3] = p.get('translation', n.get('translation', [0, 0, 0]))
        m = self.world(self.parent.get(i), pose, cache, stop) @ m
        cache[i] = m
        return m
    def bone(self, name, pose, cache):
        return self.world(self.idx[name], pose, cache, self.skel_parent)

dani, dclip, zomb, zclip = Rig(sys.argv[1]), sys.argv[2], Rig(sys.argv[3]), sys.argv[4]
L = min(dani.length(dclip), zomb.length(zclip))
for k in range(6):
    t = L * k / 5
    dp, zp = dani.pose(dclip, t), zomb.pose(zclip, t)
    cam = dani.bone('camera_root', dp, {}); head = zomb.bone('head', zp, {})
    view = cam[:3, :3] @ np.array([0, 0, 1.0])
    to = head[:3, 3] - cam[:3, 3]
    print(f"t={t:4.2f} cam view pitch {np.degrees(np.arcsin(view[1])):+6.1f}  head at fwd {to[0]:+.2f} up {to[1]:+.2f} side {to[2]:+.2f} -> pitch to head {np.degrees(np.arctan2(to[1], np.hypot(to[0], to[2]))):+6.1f}")
