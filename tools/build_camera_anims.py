"""DI2 attack camera animations (Player1P/Weapon/Camera/A_1P_Camera*) -> game/data/camera_anims.json.

Each is a full 1P skeleton clip whose camera_root bone carries the camera move. This bakes, per frame, the
camera_root transform relative to its first frame, expressed in Godot camera axes (skeleton +X forward -> -Z,
+Y up, +Z right -> +X), as [qx, qy, qz, qw, tx, ty, tz]. The runtime (cosmetics.gd AnimSequenceDynamic) adds it
on top of the view, scaled by the effect's Scale parameter and played at its Rate.
usage: python tools/build_camera_anims.py (after merging extracted/camera_anims.glb)"""
import json
import sys
import numpy as np
sys.path.insert(0, r"tools")
src = open(r"tools\paired_probe.py").read().split("dani, dclip, zomb, zclip")[0]
exec(src)

R2C = np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], float).T  # columns: images of skeleton x, y, z in camera space
# skeleton +X (forward) -> camera -Z, +Y -> +Y, +Z (right) -> +X
R2C = np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]], float)


def mat_to_quat(m):
    t = np.trace(m)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2
        return [(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, 0.25 * s]
    i = int(np.argmax([m[0, 0], m[1, 1], m[2, 2]]))
    if i == 0:
        s = np.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return [0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s, (m[2, 1] - m[1, 2]) / s]
    if i == 1:
        s = np.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return [(m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s, (m[0, 2] - m[2, 0]) / s]
    s = np.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return [(m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s, (m[1, 0] - m[0, 1]) / s]


r = Rig(r"extracted\camera_anims.glb")
out = {}
for clip in r.anims:
    L = r.length(clip)
    rate = 30.0
    n = max(2, int(round(L * rate)) + 1)
    frames = []
    base = None
    for k in range(n):
        t = min(L, k / rate)
        cam = r.bone("camera_root", r.pose(clip, t), {})
        if base is None:
            base = cam
        # delta in skeleton space: rotation D = R_t R_0^-1, translation = p_t - p_0
        D = cam[:3, :3] @ np.linalg.inv(base[:3, :3])
        dp = cam[:3, 3] - base[:3, 3]
        Dc = R2C @ D @ R2C.T
        tc = R2C @ dp
        q = mat_to_quat(Dc)
        frames.append([round(float(x), 5) for x in list(q) + list(tc)])
    out[clip] = {"rate": rate, "length": round(float(L), 4), "frames": frames}
json.dump(out, open(r"game\data\camera_anims.json", "w"), separators=(",", ":"))
peak = {c: max(abs(2 * np.degrees(np.arccos(min(1, abs(f[3]))))) for f in v["frames"]) for c, v in out.items()}
print(len(out), "camera anims; largest rotation (deg):", sorted(peak.items(), key=lambda x: -x[1])[:5])
