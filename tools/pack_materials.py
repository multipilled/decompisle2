"""Copy the textures each glb's materials use (from di2x mesh exports) next to the glb, plus a
materials.json manifest the Godot side reads to build its shaders.

usage: pack_materials.py [--pool] <asset.glb> [<asset.glb> ...]

--pool (archetype variant bodies, coordinator decision 2026-10-09): textures are not copied next to the glb. A texture
an existing body already has (game/assets/di2/<body>/textures/<name>, same size) is referenced there, anything else is
copied once into the shared pool game/assets/di2/textures/; manifest paths are relative to the glb's folder
("../walker/textures/x.png", "../textures/x.png"; Godot simplifies the "..").
"""
import json
import os
import shutil
import struct
import sys
from pathlib import Path

MESH_ROOT = Path(r"extracted\mesh")
TEX_ROOT = Path(r"extracted\tex")
ASSETS = Path(r"game\assets\di2")
POOL = ASSETS / "textures"

# DI2's own material parameters come first. The PM_* slots are CUE4Parse's guesses and can be wrong,
# e.g. the Thug's PM_Diffuse is its blood-drip map and PM_Normals is the inner (muscle) normal map.
SLOTS = {
    "albedo": ("Diffuse Colour Map", "PM_Diffuse", "Diffuse", "Base Color", "BaseColor", "Albedo"),
    "normal": ("Normal Map", "PM_Normals", "Normal", "Normals"),
    "mro": ("Packed MRO Map (see tooltip!)", "MRO", "PM_SpecularMasks"),
    "ata": ("Packed ATA Map (see tooltip!)", "Packed Translucency Map (see tooltip!)"),
}


def layer_for(name: str) -> str:
    n = name.lower()
    if "viscera" in n or "intestine" in n or "organ" in n:
        return "organs"
    if "skull" in n or "skeleton" in n or "bone" in n or "brain" in n:
        return "bone"
    if "int" in n.replace("mi_", "").split("_")[-1] or "IntA" in name or "IntB" in name:
        return "muscle"
    if "eye" in n:
        return "eye"
    if "hair" in n or "brow" in n:
        return "hair"
    if any(k in n for k in ("clothing", "feet", "glove", "bracelet", "band", "upperbody", "lowerbody", "hat", "gear")):
        return "cloth"
    if any(k in n for k in ("bbat", "machete", "pistol", "magazine", "sightdot")):
        return "weapon"
    return "skin"


def material_names(glb: Path):
    b = glb.read_bytes()
    jl = struct.unpack_from("<I", b, 12)[0]
    g = json.loads(b[20:20 + jl])
    return [m["name"] for m in g.get("materials", [])]


def find_mi(name: str):
    hits = list(MESH_ROOT.rglob(f"{name}.json"))
    return hits[0] if hits else None


def find_texture(obj_path: str):
    # "/Game/DI2/Art/.../T_X_D.0" -> extracted/mesh/DeadIsland/Content/DI2/Art/.../T_X_D.png
    # (or extracted/tex/..., for textures exported separately with `di2x tex`)
    rel = obj_path.split(".")[0].replace("/Game/", "DeadIsland/Content/")
    for root in (MESH_ROOT, TEX_ROOT):
        if (p := root / (rel + ".png")).exists():
            return p
    hits = list(MESH_ROOT.rglob(Path(rel).name + ".png"))
    return hits[0] if hits else None


class Placer:
    """Where a body's textures go: its own textures/ folder, or (pool mode) an existing body's copy / the shared pool."""

    def __init__(self, glb, pool):
        self.pool = pool
        self.base = glb.parent
        self.tex_dir = POOL if pool else glb.parent / "textures"
        self.rel = Path(os.path.relpath(self.tex_dir, self.base)).as_posix()
        self.tex_dir.mkdir(exist_ok=True)
        self.used = set()

    def place(self, src):
        """Copy (or find) `src`; returns the manifest path (relative to the glb's folder)."""
        if self.pool:
            for have in sorted(ASSETS.glob(f"*/textures/{src.name}")):
                if have.stat().st_size == src.stat().st_size:
                    self.used.add(have)
                    return Path(os.path.relpath(have, self.base)).as_posix()
        out = self.tex_dir / src.name
        if not (self.pool and out.exists()):
            shutil.copy2(src, out)
        self.used.add(out)
        return f"{self.rel}/{src.name}"


def hair_material(m, entry, placer, name):
    """DI2 hair (MSM_Hair) has no colour map: strands are tinted from Root/Tip Colour and cut out by the
    alpha channel of the Packed Hair Data Map. Bake both into textures the flesh shader reads."""
    from PIL import Image
    entry.pop("normal", None)  # the hair materials' normal slot holds a flow map,
    entry.pop("mro", None)  # and PM_SpecularMasks the packed hair data
    colors = m.get("Colors", {})
    if "Root Colour" in colors and "Tip Colour" in colors:
        root, tip = (bytes.fromhex(colors[k]["Hex"][:6]) for k in ("Root Colour", "Tip Colour"))
        out = placer.tex_dir / f"{name}_Colour.png"
        Image.new("RGB", (4, 4), tuple((a + b) // 2 for a, b in zip(root, tip))).save(out)
        placer.used.add(out)
        entry["albedo"] = f"{placer.rel}/{out.name}"
    data = m.get("Textures", {}).get("Packed Hair Data Map")
    if data and (src := find_texture(data["ObjectPath"])):
        out = placer.tex_dir / f"{src.stem}_Alpha.png"
        if not out.exists():
            Image.open(src).getchannel("A").convert("RGB").save(out)  # coverage, read from ata.r
        placer.used.add(out)
        entry["ata"] = f"{placer.rel}/{out.name}"
        entry["masked"] = True


# DI2's parameter names per slot in data/flesh_materials.json, where each material's values are resolved through its
# whole MI chain (the mesh export's per-MI "Textures" only holds what the instance itself overrides, so inherited
# maps like the Walker skin's "Normal Map" fall back to CUE4Parse's PM_* guesses).
RESOLVED_KEYS = {"albedo": "Diffuse Colour Map", "normal": "Normal Map", "mro": "Packed MRO Map (see tooltip!)",
                 "ata": "Packed ATA Map (see tooltip!)"}
FLESH_MATERIALS = Path(r"game\data") / "flesh_materials.json"


def flesh_entry(name):
    if not FLESH_MATERIALS.exists():
        return {}
    return json.loads(FLESH_MATERIALS.read_text(encoding="utf-8")).get("materials", {}).get(name) or {}


def resolved_textures(name):
    fm = flesh_entry(name)
    tx = fm.get("params", {}).get("textures", {})
    out = {slot: (tx.get(k) or {}).get("value") for slot, k in RESOLVED_KEYS.items() if (tx.get(k) or {}).get("value")}
    # M_EyeRefractive has no Diffuse Colour Map: its sclera is "ScleraColor" (the iris composite is the eye shader's).
    if fm.get("master") == "M_EyeRefractive" and "albedo" not in out and (tx.get("ScleraColor") or {}).get("value"):
        out["albedo"] = tx["ScleraColor"]["value"]
    return out


def find_by_name(tex_name):
    for root in (MESH_ROOT, TEX_ROOT):
        hits = list(root.rglob(f"{tex_name}.png"))
        if hits:
            return hits[0]
    return None


def main(glbs, pool=False):
    for glb in map(Path, glbs):
        placer = Placer(glb, pool)
        manifest = {}
        for name in material_names(glb):
            entry = {"layer": layer_for(name), "two_sided": False, "masked": False, "clip": 0.333, "splatter": False}
            mi = find_mi(name)
            if mi:
                m = json.loads(mi.read_text(encoding="utf-8"))
                textures = m.get("Textures", {})
                for slot, keys in SLOTS.items():
                    for k in keys:
                        t = textures.get(k)
                        if t and (src := find_texture(t["ObjectPath"])):
                            entry[slot] = placer.place(src)
                            break
                if "albedo" not in entry:  # fall back to any *_D texture
                    for t in textures.values():
                        if t["ObjectName"].rstrip("'").endswith("_D") and (src := find_texture(t["ObjectPath"])):
                            entry["albedo"] = placer.place(src)
                            break
                for slot, tex_name in resolved_textures(name).items():
                    if tex_name in ("T_BlackMaskAlpha_A",):
                        continue
                    if src := find_by_name(tex_name):
                        entry[slot] = placer.place(src)
                    else:
                        print(f"   {name}: resolved {slot} {tex_name} not extracted")
                # M_EyeOcclusion is a translucent occlusion shell over the eyes, not a surface.
                if flesh_entry(name).get("master") == "M_EyeOcclusion":
                    entry["layer"] = "eye_overlay"
                over = m.get("Properties", {}).get("BasePropertyOverrides", {})
                entry["two_sided"] = bool(over.get("TwoSided", False))
                entry["masked"] = over.get("BlendMode") == "BLEND_Masked"
                entry["clip"] = over.get("OpacityMaskClipValue", 0.333)
                entry["splatter"] = bool(m.get("Switches", {}).get("Enable Splatter (Characters Only!)", False))
                entry["tint"] = next((c for k, c in m.get("Colors", {}).items() if "tint" in k.lower()), None)
                # DI2 enables the splatter switch on clothing only, so it catches clothes named without
                # "Clothing" (e.g. the Runner's jeans, MI_RunnerMaleLowerB).
                if entry["layer"] == "skin" and entry["splatter"]:
                    entry["layer"] = "cloth"
                if entry["layer"] == "hair":
                    hair_material(m, entry, placer, name)
            manifest[name] = entry
        (glb.parent / f"{glb.stem}.materials.json").write_text(json.dumps(manifest, indent=1))
        print(f"{glb.name}: {len(manifest)} materials, {len(placer.used)} textures"
              + (f" ({sum(1 for u in placer.used if u.parent == POOL)} in the shared pool)" if pool else ""))
        for k, v in manifest.items():
            print(f"   {k:40} {v['layer']:7} {'albedo' in v} {'normal' in v} {'mro' in v} splatter={v['splatter']}")


if __name__ == "__main__":
    args = sys.argv[1:]
    main([a for a in args if a != "--pool"], pool="--pool" in args)
