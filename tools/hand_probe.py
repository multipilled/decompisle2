"""Hands (and weapon) in camera_root space over a clip: x right, y up, z forward (metres)."""
import sys, importlib.util, numpy as np
spec = importlib.util.spec_from_file_location("pp", "tools/paired_probe.py")
src = open("tools/paired_probe.py").read().split("dani, dclip, zomb, zclip")[0]
exec(src)
r = Rig(sys.argv[1])
for clip in sys.argv[2:]:
    L = r.length(clip); print("==", clip, round(L, 3))
    for k in range(9):
        t = L * k / 8; p = r.pose(clip, t)
        cam = r.bone('camera_root', p, {}); inv = np.linalg.inv(cam)
        out = []
        for b in ('hand_l', 'hand_r', 'weapon_01_r'):
            v = (inv @ r.bone(b, p, {}))[:3, 3]
            # camera_root local: +Z forward, +Y up, +X = left (rest maps X to skeleton -Z)
            out.append(f"{b}=({-v[0]:+.2f},{v[1]:+.2f},{v[2]:+.2f})")
        print(f"  t={t:4.2f} " + " ".join(out))
