"""DI2 physics asset (PA_*.json from `di2x json`) -> game/data/ragdoll_<name>.json for zombie.gd.

Everything is converted into Godot bone-local space the same way merge_anims.py converts bone transforms:
vectors (x, y, z) -> (x, z, y), centimetres -> metres. Bodies keep DI2's masses and damping; constraints keep
DI2's frames and cone/twist limits (UE: twist about the primary axis, swing1 about Z, swing2 about Y).

usage: python tools/build_ragdoll.py <PA json> <out json>
"""
import json
import math
import sys


def M(v, s=1.0):
    return [v["X"] * s, v["Z"] * s, v["Y"] * s]


def rotator_axes(r):
    """UE FRotationMatrix rows (X, Y, Z axes) for a rotator in degrees."""
    p, y, ro = (math.radians(r.get(k, 0.0)) for k in ("Pitch", "Yaw", "Roll"))
    sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(ro), math.cos(ro)
    x = {"X": cp * cy, "Y": cp * sy, "Z": sp}
    yy = {"X": sr * sp * cy - cr * sy, "Y": sr * sp * sy + cr * cy, "Z": -sr * cp}
    z = {"X": -(cr * sp * cy + sr * sy), "Y": cy * sr - cr * sp * sy, "Z": cr * cp}
    return x, yy, z


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


def norm(a):
    n = math.sqrt(sum(c * c for c in a)) or 1.0
    return [c / n for c in a]


def proper_basis(x, y):
    """Right-handed orthonormal basis (columns x, y, z) from two mapped axes (the y/z swap mirrors them)."""
    x = norm(x)
    z = norm(cross(x, y))
    y = cross(z, x)
    return x + y + z


def main(src, dst):
    d = json.load(open(src, encoding="utf-8"))
    bodies, constraints = [], []
    for e in d:
        p = e.get("Properties", {})
        if e.get("Type") == "SkeletalBodySetup":
            di = p.get("DefaultInstance", {})
            shapes = []
            ag = p.get("AggGeom", {})
            for s in ag.get("SphylElems", []):
                _, _, zax = rotator_axes(s.get("Rotation", {}))
                axis = norm(M(zax))
                # Godot capsules run along local Y; any perpendicular pair completes the frame.
                ref = [1, 0, 0] if abs(axis[0]) < 0.9 else [0, 0, 1]
                xcol = norm(cross(axis, ref))
                zcol = cross(xcol, axis)
                shapes.append({"type": "capsule", "center": M(s["Center"], 0.01), "basis": xcol + axis + zcol,
                               "radius": s["Radius"] * 0.01, "height": (s["Length"] + 2 * s["Radius"]) * 0.01})
            for s in ag.get("SphereElems", []):
                shapes.append({"type": "sphere", "center": M(s["Center"], 0.01), "radius": s["Radius"] * 0.01})
            for s in ag.get("BoxElems", []):
                xa, ya, za = rotator_axes(s.get("Rotation", {}))
                # The mirror maps (X, Y, Z) to a left-handed set; a box is symmetric, so flip Z to stay proper.
                cx, cy, cz = M(xa), M(ya), [-c for c in M(za)]
                shapes.append({"type": "box", "center": M(s["Center"], 0.01), "basis": cx + cy + cz,
                               "size": [s["X"] * 0.01, s["Y"] * 0.01, s["Z"] * 0.01]})
            # PhysicalAnimation profiles: [OrientationStrength, AngularVelocityStrength, local] per profile.
            prof = {pr["ProfileName"]: [pr["PhysicalAnimationData"]["OrientationStrength"],
                                        pr["PhysicalAnimationData"]["AngularVelocityStrength"],
                                        pr["PhysicalAnimationData"]["bIsLocalSimulation"]]
                    for pr in p.get("PhysicalAnimationData", [])}
            bodies.append({
                "bone": p["BoneName"],
                "profiles": prof,
                "kinematic": p.get("PhysicsType") == "PhysType_Kinematic",
                "mass": di.get("MassInKgOverride", 0.0) if di.get("bOverrideMass") else 0.0,
                "linear_damp": di.get("LinearDamping", 0.01),
                "angular_damp": di.get("AngularDamping", 0.0),
                "shapes": shapes,
            })
        elif e.get("Type") == "PhysicsConstraintTemplate":
            ci = p["DefaultInstance"]
            prof = ci.get("ProfileInstance", {})
            cone, twist = prof.get("ConeLimit", {}), prof.get("TwistLimit", {})

            def lim(motion, deg):
                return {"ACM_Locked": 0.0, "ACM_Free": -1.0}.get(motion, deg)
            pri1 = ci.get("PriAxis1", {"X": 1, "Y": 0, "Z": 0})
            sec1 = ci.get("SecAxis1", {"X": 0, "Y": 1, "Z": 0})
            constraints.append({
                "child": ci["ConstraintBone1"], "parent": ci["ConstraintBone2"],
                "pos": M(ci.get("Pos1", {"X": 0, "Y": 0, "Z": 0}), 0.01),
                "basis": proper_basis(M(pri1), M(sec1)),
                # degrees; 0 = locked, -1 = free (UE default motion is Free)
                "twist": lim(twist.get("TwistMotion", "ACM_Free"), twist.get("TwistLimitDegrees", 45.0)),
                "swing1": lim(cone.get("Swing1Motion", "ACM_Free"), cone.get("Swing1LimitDegrees", 45.0)),
                "swing2": lim(cone.get("Swing2Motion", "ACM_Free"), cone.get("Swing2LimitDegrees", 45.0)),
            })
    json.dump({"source": src.replace("\\", "/").split("/Content/")[-1], "bodies": bodies, "constraints": constraints},
              open(dst, "w"), indent=1)
    print(f"{len(bodies)} bodies, {len(constraints)} constraints -> {dst}")
    for c in constraints:
        print(f"  {c['child']:12} -> {c['parent']:12} twist {c['twist']:5.1f} swing1 {c['swing1']:5.1f} swing2 {c['swing2']:5.1f}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
