"""Mean / percentile radiance of a sky HDRI (decoded with build_flesh_materials' texdump; CUE4Parse + detex).
    python tools/test_map/sky_stats.py /Game/DSCore/Lighting/Skies/T_VeniceBeach_HDR.0 [build dir]"""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "shaders"))
import build_flesh_materials as B  # noqa: E402

obj = sys.argv[1]
B.BUILD = sys.argv[2] if len(sys.argv) > 2 else os.path.join(B.ROOT, "extracted", "test_map", "sky")
os.makedirs(B.BUILD, exist_ok=True)
raw, meta = B.dump_textures({B.game_to_pkg(obj)})
for m in meta:
    data = open(os.path.join(raw, m["name"] + ".raw"), "rb").read()
    print(m["name"], m["decoded"], m["width"], m["height"], len(data))
    w, h = m["width"], m["height"]
    if m["decoded"] == "PF_FloatRGBA":
        a = np.frombuffer(data, np.float16).reshape(h, w, 4)[..., :3].astype(np.float32)
    elif m["decoded"] in ("PF_A32B32G32R32F",):
        a = np.frombuffer(data, np.float32).reshape(h, w, 4)[..., :3]
    else:
        a = np.frombuffer(data, np.uint8).reshape(h, w, -1)[..., :3].astype(np.float32) / 255
    lum = a @ np.array([0.2126, 0.7152, 0.0722])
    rows = np.cos((np.arange(h) + 0.5) / h * np.pi - np.pi / 2)  # equirect solid-angle weight
    upper = lum[: h // 2]
    print("mean rgb %s, mean lum %.4f (solid-angle weighted %.4f), upper-hemisphere lum %.4f, p50 %.4f p99 %.4f max %.2f" % (
        a.reshape(-1, 3).mean(0), lum.mean(), (lum * rows[:, None]).sum() / (rows.sum() * w), upper.mean(),
        np.percentile(lum, 50), np.percentile(lum, 99), lum.max()))
    json.dump({"name": m["name"], "decoded": m["decoded"], "mean_rgb": a.reshape(-1, 3).mean(0).tolist(),
               "mean_lum": float(lum.mean()), "upper_lum": float(upper.mean()), "p99": float(np.percentile(lum, 99))},
              open(os.path.join(B.BUILD, m["name"] + ".stats.json"), "w"))
