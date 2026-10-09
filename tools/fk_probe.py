"""FK probe over a merged glb: camera_root view pitch (bone +Z) and weapon_01_r height over clips.
usage: python tools/fk_probe.py <glb> <clip>..."""
import json, struct, sys
import numpy as np

def load(path):
    b = open(path, 'rb').read()
    jl = struct.unpack('<I', b[12:16])[0]
    g = json.loads(b[20:20 + jl])
    bin_ = b[20 + jl + 8:]
    return g, bin_

def acc(g, bin_, i):
    a = g['accessors'][i]; v = g['bufferViews'][a['bufferView']]
    n = {'SCALAR': 1, 'VEC3': 3, 'VEC4': 4}[a['type']]
    off = v.get('byteOffset', 0) + a.get('byteOffset', 0)
    return np.frombuffer(bin_, np.float32, a['count'] * n, off).reshape(a['count'], n) if n > 1 else np.frombuffer(bin_, np.float32, a['count'], off)

def qmat(q):
    x, y, z, w = q
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)], [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)], [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])

g, bin_ = load(sys.argv[1])
nodes = g['nodes']
parent = {}
for i, n in enumerate(nodes):
    for c in n.get('children', []):
        parent[c] = i
name_to = {n.get('name'): i for i, n in enumerate(nodes)}
anims = {a['name']: a for a in g['animations']}

def sample(anim, t):
    pose = {}
    for ch in anim['channels']:
        s = anim['samplers'][ch['sampler']]
        times = acc(g, bin_, s['input']); vals = acc(g, bin_, s['output'])
        k = int(np.clip(np.searchsorted(times, t) - 1, 0, len(times) - 2)) if len(times) > 1 else 0
        f = 0.0 if len(times) < 2 else float(np.clip((t - times[k]) / max(times[k+1] - times[k], 1e-6), 0, 1))
        v = vals[k] * (1 - f) + vals[min(k+1, len(vals)-1)] * f
        if ch['target']['path'] == 'rotation':
            v = v / np.linalg.norm(v)
        pose.setdefault(ch['target']['node'], {})[ch['target']['path']] = v
    return pose

def world(i, pose, cache):
    if i in cache: return cache[i]
    n = nodes[i]; p = pose.get(i, {})
    r = qmat(p.get('rotation', n.get('rotation', [0, 0, 0, 1])))
    tr = np.array(p.get('translation', n.get('translation', [0, 0, 0])))
    m = np.eye(4); m[:3, :3] = r; m[:3, 3] = tr
    if i in parent: m = world(parent[i], pose, cache) @ m
    cache[i] = m
    return m

cam = name_to['camera_root']; wpn = name_to['weapon_01_r']; root = name_to.get('Root', name_to.get('root'))
for clip in sys.argv[2:]:
    a = anims[clip]
    tmax = max(acc(g, bin_, s['input'])[-1] for s in a['samplers'])
    line = f"{clip:48}"
    for k in range(8):
        pose = sample(a, tmax * k / 7); cache = {}
        R = np.linalg.inv(world(root, pose, cache)) @ world(cam, pose, cache)   # skeleton (Root) space
        v = R[:3, :3] @ np.array([0, 0, 1.0])
        W = np.linalg.inv(world(root, pose, cache)) @ world(wpn, pose, cache)
        line += f" {np.degrees(np.arcsin(np.clip(v[1], -1, 1))):+5.1f}/{W[1,3]-R[1,3]:+.2f}"
    print(line)
