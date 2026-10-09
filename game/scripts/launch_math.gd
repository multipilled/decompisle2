class_name LaunchMath
extends RefCounted
## DI2's LaunchCharacterAction impulses (static RE of the shipping exe; recon/ANIMATION.md 8):
##   global strength  0x1411f1660: GlobalImpulseStrengthMultiplierSettings (FixedValue / Expression /
##                    RangeBasedExpression remap) x (1 + uniform(-RandomDeviationMultiplierRange, +range))
##   root velocity    0x1411a5e10 -> 0x1411cf5a0: the impact direction (point impacts: HitFromDirection; radial: from
##                    the origin to the actor's bounds centre), inverted if bInvertLaunchDirection, slerped toward the
##                    instigator's forward by BlendTowardInstigatorForwardDirection (0x1411ce870), + vertical scale on
##                    the up component, normalised, elevation clamped to MaximumVerticalRootLaunchAngleInDegrees when
##                    bRestrictMaximumVerticalRootLaunchAngle (0x1411cece0), x magnitude x strength; minus the current
##                    velocity x ExistingRootVelocityFractionToNegate when bNegateExistingCharacterRootVelocity; clamped
##                    (0x1411cfff0: min only if bClampToMinimumMagnitude, max only if bClampToMaximumMagnitude)
##   mesh point       0x1411a5240: the impact direction x CharacterMeshLinearImpulseVelocityMagnitude x strength,
##                    clamped, on the impact's bone (a velocity change on that body, 0x14126b820), through the
##                    ImpulseFilterSet (0x141402f60: the hit bone's entry, else its body parts'; scale + left/right
##                    mirrored secondary impulses)
##   angular          0x1411a3d50: yaw / pitch in [-1, 1] from the impact location in the actor's local bounds
##                    (0x1411a54d0: Y across, Z up), forced to +-1 if bForce*MappingToRangeExtents, x the weighting
##                    multipliers; yaw axis = actor up - actor forward x TiltBackRotationAxisScale, pitch axis = the
##                    horizontal perpendicular of the impact direction (0x1411a5820); axis = their blend by
##                    |pitch| / (|yaw| + |pitch|); magnitude (|yaw| + |pitch|) / 2 x CharacterMeshAngularImpulse-
##                    VelocityMagnitude x strength, clamped
## ULaunchSettings native defaults (InternalConstructor exe 0x141cf0170) fill unset fields.
## All in UE units (cm, cm/s, deg/s, UE axes X fwd / Y right / Z up); returned in Godot units / axes.

const ROOT_DEFAULTS := {"bApplyToCharacterRoot": true, "CharacterRootImpulseVelocityMagnitude": 1000.0,
	"BlendTowardInstigatorForwardDirection": 0.5, "CharacterRootAdditionalVerticalImpulseScale": 0.25,
	"bNegateExistingCharacterRootVelocity": true, "ExistingRootVelocityFractionToNegate": 0.75,
	"bRestrictMaximumVerticalRootLaunchAngle": false, "MaximumVerticalRootLaunchAngleInDegrees": 90.0}
const LINEAR_DEFAULTS := {"bApplyToCharacterMeshLocation": true, "CharacterMeshLinearImpulseVelocityMagnitude": 500.0}
const ANGULAR_DEFAULTS := {"bApplyAngularMeshImpulse": true, "CharacterMeshAngularImpulseVelocityMagnitude": 3000.0,
	"AngularYawWeightingMultiplier": 1.0, "AngularPitchWeightingMultiplier": 1.0, "bForceYawMappingToRangeExtents": false,
	"bForcePitchMappingToRangeExtents": false, "TiltBackRotationAxisScale": -0.1}
const CLAMP_DEFAULTS := {"bClampToMinimumMagnitude": false, "MinimumMagnitude": 0.0, "bClampToMaximumMagnitude": false,
	"MaximumMagnitude": 1000.0}


## Godot world (m) <-> UE world (cm): CUE4Parse's glTF convention, UE (x, y, z) = Godot (x, z, y).
static func g2u(v: Vector3, scale := 100.0) -> Vector3:
	return Vector3(v.x, v.z, v.y) * scale


static func u2g(v: Vector3, scale := 0.01) -> Vector3:
	return Vector3(v.x, v.z, v.y) * scale


## An axial vector (angular velocity) changes sign under the axis swap (an improper rotation).
static func u2g_axial(v: Vector3, scale := 1.0) -> Vector3:
	return -Vector3(v.x, v.z, v.y) * scale


static func _val(d: Dictionary, k: String, defaults: Dictionary) -> Variant:
	return d.get(k, defaults.get(k))


static func clamp_magnitude(v: Vector3, c: Dictionary) -> Vector3:
	var len := v.length()
	var mx := float(_val(c, "MaximumMagnitude", CLAMP_DEFAULTS)) if bool(_val(c, "bClampToMaximumMagnitude", CLAMP_DEFAULTS)) else len
	var r := len
	if bool(_val(c, "bClampToMinimumMagnitude", CLAMP_DEFAULTS)) and len < float(_val(c, "MinimumMagnitude", CLAMP_DEFAULTS)):
		r = float(_val(c, "MinimumMagnitude", CLAMP_DEFAULTS))
	elif len > mx:
		r = mx
	return v.normalized() * r if len > 1e-8 else Vector3.ZERO


## GlobalImpulseStrengthMultiplierSettings (0x1411f1660).
static func strength(s: Dictionary, facts: Dictionary) -> float:
	var g: Dictionary = s.get("GlobalImpulseStrengthMultiplierSettings", {})
	var m := 1.0
	match str(g.get("ScaleControlMethod", "")).get_slice("::", 1):
		"FixedValue":
			m = float(g.get("FixedValue", 1.0))
		"Expression":
			m = DI2Expr.num(DI2Expr.value(str(g.get("Expression", "1")), facts))
		"RangeBasedExpression":
			m = HitReactTrees.remap(g.get("RemapSettings", {}), DI2Expr.num(DI2Expr.value(str(g.get("Expression", "0")), facts)), facts)
	var r := float(g.get("RandomDeviationMultiplierRange", 0.0))
	if r > 0.0:
		m *= 1.0 - (randf() * 2.0 * r - r)
	return m


## {root: Vector3 m/s, point: [[Vector3 m/s, Vector3 world point, bone]], angular: Vector3 deg/s} in Godot space.
static func impulses(s: Dictionary, z: Zombie, plan: Dictionary, _extra: Dictionary) -> Dictionary:
	var f: Dictionary = plan.get("facts", {})
	var hit: Dictionary = plan.get("hit", {})
	var mult := strength(s, f)
	var radial := hit.get("explosion_origin") is Vector3
	# Actor frame (UE): forward = node -Z, right = node +X, up = node +Y.
	var fwd_u := g2u(-z.global_basis.z, 1.0).normalized()
	var right_u := g2u(z.global_basis.x, 1.0).normalized()
	var up_u := g2u(z.global_basis.y, 1.0).normalized()
	var centre_g := z.global_position + Vector3(0, z.root_shape.position.y if z.root_shape else 0.85, 0)
	var dir_u: Vector3
	if radial:
		dir_u = (g2u(centre_g) - g2u(hit["explosion_origin"])).normalized()
	else:
		dir_u = g2u(plan.get("dir", Vector3.ZERO), 1.0).normalized()
	var out := {"root": Vector3.ZERO, "point": [], "angular": Vector3.ZERO, "strength": mult}
	# Root.
	var rs: Dictionary = s.get("RootImpulseSettings", {})
	var rmag := float(_val(rs, "CharacterRootImpulseVelocityMagnitude", ROOT_DEFAULTS))
	if bool(_val(rs, "bApplyToCharacterRoot", ROOT_DEFAULTS)) and rmag > 0.0 and dir_u.length_squared() > 1e-8:
		var d := dir_u
		if bool(s.get("bInvertLaunchDirection", false)):
			d = -d
		var inst: Node3D = plan.get("attacker")
		if inst and is_instance_valid(inst):
			var ifwd := g2u(-inst.global_basis.z, 1.0).normalized()
			var x := Vector3(1, 0, 0)
			var qa := _find_between(x, d)
			var qb := _find_between(x, ifwd)
			d = (qa.slerp(qb, float(_val(rs, "BlendTowardInstigatorForwardDirection", ROOT_DEFAULTS))) * x).normalized()
		d = d + up_u * float(_val(rs, "CharacterRootAdditionalVerticalImpulseScale", ROOT_DEFAULTS))
		d = d.normalized()
		if bool(_val(rs, "bRestrictMaximumVerticalRootLaunchAngle", ROOT_DEFAULTS)):
			var max_deg := float(_val(rs, "MaximumVerticalRootLaunchAngleInDegrees", ROOT_DEFAULTS))
			var elev := PI * 0.5 - acos(clampf(up_u.dot(d), -1.0, 1.0))
			if deg_to_rad(max_deg) < elev:
				var axis := up_u.cross(d).normalized()
				d = up_u.rotated(axis, deg_to_rad(90.0 - max_deg)) if axis.length_squared() > 1e-8 else d
		var v := d * rmag * mult
		if bool(_val(rs, "bNegateExistingCharacterRootVelocity", ROOT_DEFAULTS)):
			v -= g2u(z.velocity) * float(_val(rs, "ExistingRootVelocityFractionToNegate", ROOT_DEFAULTS))
		v = clamp_magnitude(v, rs.get("CharacterRootImpulseClampSettings", {}))
		out["root"] = u2g(v)
	# Mesh point (point impacts only: a radial impact has no direction there).
	var ls: Dictionary = s.get("MeshLinearPointImpulseSettings", {})
	var lmag := float(_val(ls, "CharacterMeshLinearImpulseVelocityMagnitude", LINEAR_DEFAULTS))
	if not radial and bool(_val(ls, "bApplyToCharacterMeshLocation", LINEAR_DEFAULTS)) and lmag > 0.0 and dir_u.length_squared() > 1e-8:
		var v := clamp_magnitude(dir_u * lmag * mult, ls.get("CharacterMeshLinearImpulseClampSettings", {}))
		var point: Vector3 = plan.get("point", centre_g)
		out["point"] = _filter(s, z, str(plan.get("bone", "")), u2g(v), point)
	# Angular.
	var an: Dictionary = s.get("MeshAngularImpulseSettings", {})
	var amag := float(_val(an, "CharacterMeshAngularImpulseVelocityMagnitude", ANGULAR_DEFAULTS))
	if bool(_val(an, "bApplyAngularMeshImpulse", ANGULAR_DEFAULTS)) and amag > 0.0:
		# The impact location in the actor's local bounds (UE local: X fwd, Y right, Z up) -> [0, 1] across and up.
		var p_local := z.global_transform.affine_inverse() * (plan.get("point", centre_g) as Vector3)
		var lu := Vector3(-p_local.z, p_local.x, p_local.y)
		var bounds := _local_bounds(z)
		var lo: Vector3 = bounds[0]
		var hi: Vector3 = bounds[1]
		var ty := clampf(lu.y * 100.0, lo.y, hi.y)
		var tz := clampf(lu.z * 100.0, lo.z, hi.z)
		var yaw := ((ty - lo.y) / maxf(hi.y - lo.y, 1e-4)) * 2.0 - 1.0
		var pitch := ((tz - lo.z) / maxf(hi.z - lo.z, 1e-4)) * 2.0 - 1.0
		if bool(_val(an, "bForceYawMappingToRangeExtents", ANGULAR_DEFAULTS)):
			yaw = 1.0 if yaw > 0.0 else -1.0
		if bool(_val(an, "bForcePitchMappingToRangeExtents", ANGULAR_DEFAULTS)):
			pitch = 1.0 if pitch > 0.0 else -1.0
		yaw *= float(_val(an, "AngularYawWeightingMultiplier", ANGULAR_DEFAULTS))
		pitch *= float(_val(an, "AngularPitchWeightingMultiplier", ANGULAR_DEFAULTS))
		var a1 := (up_u - fwd_u * float(_val(an, "TiltBackRotationAxisScale", ANGULAR_DEFAULTS))).normalized()
		# Pitch axis (0x1411a5820): the reversed horizontal impact direction in the actor frame, (x, y) -> (y, -x).
		var src := dir_u if not radial else (g2u(centre_g) - g2u(hit["explosion_origin"])).normalized()
		var lx := (-src).dot(fwd_u)
		var ly := (-src).dot(right_u)
		var hl := Vector2(lx, ly)
		hl = hl.normalized() if hl.length_squared() > 1e-8 else Vector2(1, 0)
		var a2 := (fwd_u * hl.y + right_u * -hl.x).normalized()
		if yaw < 0.0:
			a1 = -a1
		if pitch < 0.0:
			a2 = -a2
		var ay := absf(yaw)
		var ap := absf(pitch)
		var w := ap / (ay + ap) if ay + ap > 0.0 else 0.0
		var axis := (a1 * (1.0 - w) + a2 * w)
		axis = axis.normalized() if axis.length_squared() > 1e-8 else Vector3.ZERO
		var av := axis * ((ay + ap) * 0.5 * amag * mult)
		av = clamp_magnitude(av, an.get("CharacterMeshAngularImpulseClampSettings", {}))
		out["angular"] = u2g_axial(av)
	return out


## FQuat::FindBetweenNormals.
static func _find_between(a: Vector3, b: Vector3) -> Quaternion:
	var w := 1.0 + a.dot(b)
	var q: Quaternion
	if w >= 1e-6:
		var c := a.cross(b)
		q = Quaternion(c.x, c.y, c.z, w)
	else:
		w = 0.0
		q = Quaternion(-a.z, 0.0, a.x, w) if absf(a.x) > absf(a.y) else Quaternion(0.0, -a.z, a.y, w)
	return q.normalized()


## The actor's local bounds in UE local axes (cm): the skinned meshes' AABBs in the node frame.
static func _local_bounds(z: Zombie) -> Array:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for mi in Util.find_all(z.visual, "MeshInstance3D"):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var bx := (z.global_transform.affine_inverse() * m.global_transform) * m.get_aabb()
		for i in 8:
			var c := bx.get_endpoint(i)
			var u := Vector3(-c.z, c.x, c.y)
			lo = lo.min(u)
			hi = hi.max(u)
	if lo.x == INF:
		return [Vector3(-30, -30, 0), Vector3(30, 30, 180)]
	return [lo * 100.0, hi * 100.0]


## The ImpulseFilterSet (0x141402f60): MeshImpulseBoneToModificationParams keyed by the hit bone, else by its
## DT_ZombiePartBoneDefinition parts (FName keys, case-insensitive): ImpulseScale on the impulse and each
## SecondaryImpulse (BoneName None + bApplyToLeftRightMirrorOfOriginalBone = the mirrored bone) at its scale. No entry:
## the impulse as is. How 0x141414ab0 places the secondary impulse is not read (UNVERIFIED: the mirrored body).
static func _filter(s: Dictionary, z: Zombie, bone: String, v: Vector3, point: Vector3) -> Array:
	var fs_ref = s.get("ImpulseFilterSet")
	var fs_name := ""
	if fs_ref is Dictionary:
		fs_name = str(fs_ref.get("ObjectName", "")).get_slice("'", 1)
	elif fs_ref != null:
		fs_name = str(fs_ref)
	var entry := {}
	if fs_name != "":
		var fs: Dictionary = HitReactTrees.data.get("assets", {}).get(fs_name, {})
		fs = fs.get(fs_name, fs)
		var keys := [bone]
		keys.append_array(HitReactTrees.part_ids(HitReactTrees.part_bone(z.skeleton, bone)))
		for k: String in keys:
			for e: Dictionary in fs.get("MeshImpulseBoneToModificationParams", []):
				if str(e.get("Key", "")).to_lower() == k.to_lower():
					entry = e.get("Value", {})
					break
			if not entry.is_empty():
				break
	if entry.is_empty():
		return [[v, point, bone]]
	var out := [[v * float(entry.get("ImpulseScale", 1.0)), point, bone]]
	for si: Dictionary in entry.get("SecondaryImpulses", []):
		var b := str(si.get("BoneName", "None"))
		if bool(si.get("bApplyToLeftRightMirrorOfOriginalBone", false)):
			b = bone.replace("_l", "_#").replace("_r", "_l").replace("_#", "_r")
		if b == "None" or z.skeleton.find_bone(b) < 0:
			continue
		var bi := z.skeleton.find_bone(b)
		var bp := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(bi).origin
		out.append([v * float(si.get("ImpulseScale", 1.0)), bp, b])
	return out
