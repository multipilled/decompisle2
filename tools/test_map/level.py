"""Read DI2 level packages (CUE4Parse JSON dumps of .umap files, extracted/json/...) into placed static meshes,
decals, lights and level-settings actors with world transforms. Personal use; reads the user's own install only.

Conventions
  * UE space: left-handed, X forward, Y right, Z up, centimetres. Rotators are degrees (Pitch, Yaw, Roll) and turn
    into matrices the way FRotationMatrix does (rows = the rotated X, Y, Z axes).
  * A reference {"ObjectPath": "/Game/.../Map.N"} names export N of the same package (0-based: a StaticMesh's
    BodySetup ".0" is the package's first export).
  * DI2's cooker merges static components into StaticWorldActor "Cooked_StaticDataActor" (visible) and
    "Cooked_StaticDataActorHidden" (bHidden: whitebox blockers); their RelativeLocation is already world space unless
    the component has an AttachParent.
"""
import json
import math
import os

import numpy as np

ROOT = r"."
JSON_ROOT = os.path.join(ROOT, "extracted", "json")

MESH_TYPES = ("StaticMeshComponent", "InstancedStaticMeshComponent", "HierarchicalInstancedStaticMeshComponent",
              "FoliageInstancedStaticMeshComponent", "SplineMeshComponent")


def package_json(pkg):
    """'DeadIsland/Content/.../X.umap' (or .uasset) -> parsed export list."""
    p = os.path.join(JSON_ROOT, os.path.splitext(pkg)[0] + ".json")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def ref_index(ref):
    """Export index (0-based, as CUE4Parse writes it) a same-package reference points at, else None."""
    if not ref:
        return None
    path = ref.get("ObjectPath", "")
    tail = path.rsplit(".", 1)
    if len(tail) == 2 and tail[1].isdigit():
        return int(tail[1])
    return None


def obj_name(ref):
    """'StaticMesh'SM_X'' -> 'SM_X'; ObjectPath '/Game/A/SM_X.2' -> 'SM_X'."""
    if not ref:
        return None
    return ref["ObjectPath"].split("/")[-1].split(".")[0]


def rotator_matrix(r):
    """FRotationMatrix(Pitch, Yaw, Roll) as a 3x3 numpy array whose ROWS are the rotated X, Y, Z axes."""
    p, y, ro = (math.radians(r.get(k, 0.0)) for k in ("Pitch", "Yaw", "Roll"))
    sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    return np.array([
        [cp * cy, cp * sy, sp],
        [sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp],
        [-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp],
    ])


def quat_matrix(q):
    """FQuat (X, Y, Z, W) -> 3x3 rows-are-axes matrix (FQuatRotationTranslationMatrix)."""
    x, y, z, w = q["X"], q["Y"], q["Z"], q["W"]
    x2, y2, z2 = x + x, y + y, z + z
    xx, xy, xz = x * x2, x * y2, x * z2
    yy, yz, zz = y * y2, y * z2, z * z2
    wx, wy, wz = w * x2, w * y2, w * z2
    return np.array([
        [1 - (yy + zz), xy + wz, xz - wy],
        [xy - wz, 1 - (xx + zz), yz + wx],
        [xz + wy, yz - wx, 1 - (xx + yy)],
    ])


def vec(v, default=(0.0, 0.0, 0.0)):
    return np.array([v["X"], v["Y"], v["Z"]]) if v else np.array(default, float)


def make_xform(loc, rot_rows, scale):
    """4x4 UE row-vector transform: p' = p @ M (scale, then rotate, then translate), like FTransform::ToMatrixWithScale."""
    m = np.eye(4)
    m[:3, :3] = rot_rows * np.asarray(scale)[:, None]
    m[3, :3] = loc
    return m


def relative_xform(p):
    return make_xform(vec(p.get("RelativeLocation")), rotator_matrix(p.get("RelativeRotation") or {}),
                      vec(p.get("RelativeScale3D"), (1.0, 1.0, 1.0)))


# --- archetypes (Template chain) ---------------------------------------------------------------------------------
# A cooked component stores only what differs from its archetype ("Template": the Blueprint class's
# <Name>_GEN_VARIABLE component template, whose own Template is the parent class's, ... down to the native default).
# A Blueprint actor placed in a level (vehicles, doors, lamp fixtures, hazard props) therefore often has no StaticMesh /
# RelativeLocation on its components: they come from the template. Only these keys are taken from templates; package-
# local references (AttachParent, ...) point into the template's own package and are never merged.
TEMPLATE_KEYS = ("StaticMesh", "OverrideMaterials", "RelativeLocation", "RelativeRotation", "RelativeScale3D",
                 "bHiddenInGame", "bVisible", "CastShadow", "BodyInstance", "bUseDefaultCollision", "SplineParams",
                 "ForwardAxis", "DecalMaterial", "DecalSize")
MISSING_TEMPLATES = set()  # packages whose JSON dump is missing (tools/di2x.sh json them, then rebuild)
_TEMPLATE_PKGS = {}


def game_path_pkg(object_path):
    """'/Game/A/B.N' -> ('DeadIsland/Content/A/B.uasset', N); None for /Script (native defaults) and other roots."""
    path, _, idx = (object_path or "").rpartition(".")
    if not path.startswith("/Game/") or not idx.isdigit():
        return None
    return "DeadIsland/Content/" + path[6:] + ".uasset", int(idx)


def template_export(ref):
    pk = game_path_pkg((ref or {}).get("ObjectPath"))
    if pk is None:
        return None
    pkg, idx = pk
    if pkg not in _TEMPLATE_PKGS:
        try:
            _TEMPLATE_PKGS[pkg] = package_json(pkg)
        except FileNotFoundError:
            _TEMPLATE_PKGS[pkg] = None
            MISSING_TEMPLATES.add(pkg)
    ex = _TEMPLATE_PKGS[pkg]
    return ex[idx] if ex is not None and 0 <= idx < len(ex) else None


def merged_props(e):
    """Properties of export e over its Template chain (TEMPLATE_KEYS only; structs merged one level deep)."""
    chain, t = [], e.get("Template")
    for _ in range(12):
        te = template_export(t)
        if te is None:
            break
        chain.append(te.get("Properties") or {})
        t = te.get("Template")
    if not chain:
        return e.get("Properties") or {}
    out = {}
    for p in reversed(chain):
        for k in TEMPLATE_KEYS:
            if k in p:
                v = p[k]
                out[k] = dict(out[k], **v) if isinstance(v, dict) and isinstance(out.get(k), dict) and "ObjectPath" not in v else v
    own = e.get("Properties") or {}
    for k, v in own.items():
        out[k] = dict(out[k], **v) if isinstance(v, dict) and isinstance(out.get(k), dict) and "ObjectPath" not in v else v
    return out


class Level:
    """One level package: exports, owners, world transforms."""

    def __init__(self, pkg):
        self.pkg = pkg
        self.name = os.path.splitext(os.path.basename(pkg))[0]
        self.exports = package_json(pkg)
        self._world = {}
        self._props = {}

    def props(self, i):
        """Export i's properties over its archetype chain (merged_props)."""
        if i not in self._props:
            self._props[i] = merged_props(self.exports[i])
        return self._props[i]

    def export(self, ref):
        i = ref_index(ref)
        return self.exports[i] if i is not None and 0 <= i < len(self.exports) else None

    def world(self, i):
        """World 4x4 (row-vector) of scene component export i, following AttachParent (UE's absolute flags aside)."""
        if i in self._world:
            return self._world[i]
        p = self.props(i)
        m = relative_xform(p)
        par = ref_index(p.get("AttachParent"))
        if par is not None and par != i and 0 <= par < len(self.exports):
            m = m @ self.world(par)
        self._world[i] = m
        return m

    def owner(self, e):
        """The actor export a component lives in (its Outer), or None."""
        return self.export(e.get("Outer"))

    def asset_material(self, ref):
        """Material reference -> an asset object path. Materials cooked into the level itself (vehicle
        MaterialInstanceDynamics: '/Game/.../<Level>.N') resolve to their Parent asset; the MID's own parameter values
        are not carried over (recon/TEST_MAP.md)."""
        seen = 0
        while ref and seen < 8:
            pkg = ref.get("ObjectPath", "").split(".")[0]
            if pkg.endswith("/" + self.name):
                e = self.export(ref)
            elif pkg.rsplit("/", 1)[-1].startswith("BP_"):
                e = template_export(ref)  # a MID inside a Blueprint's template (merged_props OverrideMaterials)
            else:
                break
            ref = ((e or {}).get("Properties") or {}).get("Parent")
            seen += 1
        return (ref or {}).get("ObjectPath")

    def hidden(self, e, p=None):
        p = p if p is not None else (e.get("Properties") or {})
        if p.get("bHiddenInGame") or p.get("bVisible") is False:
            return True
        o = self.owner(e)
        return bool(o and (o.get("Properties") or {}).get("bHidden"))


def collision_enabled(p, mesh_default=True):
    """Does the component block world traces? BodyInstance CollisionProfileName / CollisionEnabled (UE 4.27 rules:
    bUseDefaultCollision = the mesh's BodySetup default)."""
    bi = p.get("BodyInstance") or {}
    prof = bi.get("CollisionProfileName")
    if prof in ("NoCollision", "OverlapAll", "OverlapAllDynamic", "UI", "Trigger"):
        return False
    ce = bi.get("CollisionEnabled")
    if ce in ("ECollisionEnabled::NoCollision", "ECollisionEnabled::QueryOnly") and not prof:
        return ce != "ECollisionEnabled::NoCollision" and mesh_default
    return mesh_default if p.get("bUseDefaultCollision") else True


def mesh_components(level):
    """Yield dicts for every static mesh placement in the level (ISM instances expanded)."""
    for i, e in enumerate(level.exports):
        t = e.get("Type", "")
        if t not in MESH_TYPES and not (t.endswith("StaticMeshComponent")):
            continue
        p = level.props(i)  # over the Blueprint template chain (vehicles, doors, lamp fixtures: merged_props)
        mesh = p.get("StaticMesh")
        if not mesh:
            continue
        base = {"mesh": mesh["ObjectPath"], "overrides": [level.asset_material(m) for m in p.get("OverrideMaterials") or []],
                "hidden": level.hidden(e, p), "template_mesh": not (e.get("Properties") or {}).get("StaticMesh"), "collision": collision_enabled(p), "level": level.name, "export": i,
                "cast_shadow": p.get("CastShadow", True), "type": t, "owner": (level.owner(e) or {}).get("Name"),
                # HLOD: the proxy (an LODActor's component) replacing this one beyond the proxy's LODDrawDistance (cm)
                "lod_parent": ref_index(p.get("LODParentPrimitive")),
                "hlod_draw": ((level.owner(e) or {}).get("Properties") or {}).get("LODDrawDistance")
                if (level.owner(e) or {}).get("Type") == "LODActor" else None,
                # foliage cull distance (cm, FISM InstanceEndCullDistance; 0 = never culled)
                "cull_end": p.get("InstanceEndCullDistance") or p.get("LDMaxDrawDistance") or None}
        world = level.world(i)
        inst = e.get("PerInstanceSMData")
        if inst is None and "InstancedStaticMeshComponent" in t:
            inst = p.get("PerInstanceSMData")
        if inst:
            for k, d in enumerate(inst):
                td = d.get("TransformData") or d
                if "Rotation" in td:
                    im = make_xform(vec(td.get("Translation")), quat_matrix(td["Rotation"]), vec(td.get("Scale3D"), (1, 1, 1)))
                else:
                    raise NotImplementedError("instance data layout %s" % list(td))
                yield dict(base, world=im @ world, instance=k)
        else:
            yield dict(base, world=world)


def is_hlod(c):
    """Hierarchical-LOD proxy (<Level>_<n>_HLOD_Root*: merged far-distance stand-in for a whole cluster). DI2 swaps it
    out for the real meshes near the camera, so the test map never shows it."""
    return "_HLOD" in c["mesh"].rsplit("/", 1)[-1] or "HLOD" in (c.get("owner") or "")


def find_actors(level, pred):
    return [(i, e) for i, e in enumerate(level.exports) if pred(e)]


# --- UE -> Godot ------------------------------------------------------------------------------------------------
# CUE4Parse's glTF writer stores a UE point (x, y, z) cm as (x, z, y) m (tools/cue4parse-src .../Writers/Gltf/Gltf.cs
# SwapYZ, UnitScale 0.01); Godot reads glTF as-is. So a UE transform M (row vectors) becomes the Godot transform
# P·Mᵀ·P on the swapped mesh, P = the y/z swap (a reflection; P·R·P is a proper rotation again).
P = np.array([[1, 0, 0], [0, 0, 1], [0, 1, 0]], float)


def to_godot(m, origin_ue):
    """UE 4x4 row-vector world transform -> (3x3 Godot basis, Godot origin in metres), relative to origin_ue (cm)."""
    basis = P @ m[:3, :3].T @ P
    origin = P @ ((m[3, :3] - np.asarray(origin_ue)) * 0.01)
    return basis, origin


def point_to_godot(p, origin_ue):
    return P @ ((np.asarray(p, float) - np.asarray(origin_ue)) * 0.01)


def dir_to_godot(d):
    return P @ np.asarray(d, float)
