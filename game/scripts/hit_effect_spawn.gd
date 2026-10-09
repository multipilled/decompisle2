class_name HitEffectSpawn
## Where and how DI2 spawns a hit-effect tree's cosmetic effects (recon/RE_FLESH.md "Hit-effect spawn transform").
##
## UHitEffectsComponent's dispatch (exe 0x1415485f0) walks the attacker / victim / environment tree and hands each
## gathered {Definition, DirectionInterpolationFactor} to the spawn loop (0x141556dd0). The loop asks the impact for
## a location and base rotation (impact vtable +0x38), lets the impact adjust the rotation per effect (+0x40), then
## spawns the CE attached to the impact's component (UCosmeticEffectsComponent spawn 0x140ccd260). Per impact type:
##   Point impact (melee, ranged, kicks; vtable 0x1450daff8): location = HitInfo.ImpactPoint, attached at
##     HitInfo's bone; rotation = point_basis(HitInfo.ImpactNormal, HitFromDirection, factor) (0x1414810b0).
##     HitFromDirection = normalize(HitInfo.TraceEnd - HitInfo.TraceStart) (melee request 0x1410ab130): the way
##     the weapon / shot travels, attacker -> victim.
##   Radial impact (explosions; 0x14518e7f0): location = the victim's root component, rotation =
##     (location - Origin).Rotation() (0x1413d0880); no per-effect step, so the factor is unused.
##   General impact (0x14518e7a8): location = the root component, rotation zero (0x1413d0800).
## The math runs in DI2's (UE) space with the particle port's axis helpers (DI2Particles.g2u_dir / u2g_basis).


## Point impact rotation, exe 0x1414810b0 (UE 4.27 helpers: ToOrientationQuat 0x141f2fa50, Slerp_NotNormalized
## 0x141f2f300, FindBetweenNormals 0x141f27c40). Godot-space normal / travel in, Godot basis out (+X = the effect's
## forward, as DI2's ParticleSystemComponent X):
##   no travel direction -> ImpactNormal.Rotation() (roll 0);
##   q = orient(N); factor > 0: q = normalize(Slerp(q, orient(D), factor));
##   factor < 1: re-roll q about its X so its Y axis = normalize(D x X) (skipped when |D x X|^2 <= 1e-4).
static func point_basis(normal: Vector3, travel: Vector3, factor: float) -> Basis:
	var n := DI2Particles.g2u_dir(normal)
	var d := DI2Particles.g2u_dir(travel)
	if d.length_squared() <= 0.0:
		return _rotation_basis(n)
	var q := _orient_quat(n)
	if factor > 0.0:
		q = _normalized(_slerp_not_normalized(q, _orient_quat(d), factor))
	if factor < 1.0:
		var x := _axis_x(q)
		var c := d.cross(x)
		if c.length_squared() > 0.0001:
			q = _mul(_find_between_normals(_axis_y(q), c.normalized()), q)
	return DI2Particles.u2g_basis(Basis(_axis_x(q), _axis_y(q), _axis_z(q)))


## Radial impact rotation, exe 0x1413d0880: FVector::Rotation() of (victim root location - explosion origin).
static func radial_basis(root: Vector3, origin: Vector3) -> Basis:
	return _rotation_basis(DI2Particles.g2u_dir(root - origin))


## Plays a CE with an explicit base transform (DI2's impact rotation instead of play_ce's own blend) through
## DI2Particles.play_ce's walk (link rotation / attachment / desaturation, nested CEs with the same spawn transform).
## Returns how many systems started.
static func play(parent: Node, ce_name: String, pos: Vector3, base: Basis, ps_params := {}) -> int:
	if not DI2Particles.db().get("ce", {}).has(ce_name):
		return 0
	DI2Particles.play_ce(parent, ce_name, pos, Vector3.ZERO, Vector3.ZERO, -1.0, ps_params, base)
	return DI2Particles.last_spawned.size()


# --- UE 4.27 math (UE space, quaternions as Quaternion(x, y, z, w) with UE's formulas) ---------------------------

## FVector::Rotation() -> FRotationMatrix, roll 0.
static func _rotation_basis(v: Vector3) -> Basis:
	var yaw := rad_to_deg(atan2(v.y, v.x))
	var pitch := rad_to_deg(atan2(v.z, sqrt(v.x * v.x + v.y * v.y)))
	return DI2Particles.u2g_basis(DI2Particles.rotator_basis_ue(pitch, yaw, 0.0))


## FVector::ToOrientationQuat.
static func _orient_quat(v: Vector3) -> Quaternion:
	var yaw := atan2(v.y, v.x)
	var pitch := atan2(v.z, sqrt(v.x * v.x + v.y * v.y))
	var sp := sin(pitch * 0.5); var cp := cos(pitch * 0.5)
	var sy := sin(yaw * 0.5); var cy := cos(yaw * 0.5)
	return Quaternion(sp * sy, -sp * cy, cp * sy, cp * cy)


## FQuat::Slerp_NotNormalized.
static func _slerp_not_normalized(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	var raw := a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
	var cosom := absf(raw)
	var s0: float
	var s1: float
	if cosom < 0.9999:
		var omega := acos(clampf(cosom, -1.0, 1.0))
		var inv_sin := 1.0 / sin(omega)
		s0 = sin((1.0 - t) * omega) * inv_sin
		s1 = sin(t * omega) * inv_sin
	else:
		s0 = 1.0 - t
		s1 = t
	if raw < 0.0:
		s1 = -s1
	return Quaternion(s0 * a.x + s1 * b.x, s0 * a.y + s1 * b.y, s0 * a.z + s1 * b.z, s0 * a.w + s1 * b.w)


## FQuat::GetNormalized (identity when |q|^2 < 1e-8).
static func _normalized(q: Quaternion) -> Quaternion:
	var l2 := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
	if l2 < 1e-8:
		return Quaternion(0, 0, 0, 1)
	var s := 1.0 / sqrt(l2)
	return Quaternion(q.x * s, q.y * s, q.z * s, q.w * s)


## FQuat::FindBetweenNormals(a, b): the shortest rotation taking a onto b (normalized).
static func _find_between_normals(a: Vector3, b: Vector3) -> Quaternion:
	var w := 1.0 + a.dot(b)
	var q: Quaternion
	if w >= 1e-6:
		var c := a.cross(b)
		q = Quaternion(c.x, c.y, c.z, w)
	elif absf(a.x) > absf(a.y):
		q = Quaternion(-a.z, 0.0, a.x, 0.0)
	else:
		q = Quaternion(0.0, -a.z, a.y, 0.0)
	return _normalized(q)


## FQuat operator* (a * b: b first, then a).
static func _mul(a: Quaternion, b: Quaternion) -> Quaternion:
	return Quaternion(
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)


static func _axis_x(q: Quaternion) -> Vector3:
	return Vector3(1.0 - 2.0 * (q.y * q.y + q.z * q.z), 2.0 * (q.x * q.y + q.w * q.z), 2.0 * (q.x * q.z - q.w * q.y))


static func _axis_y(q: Quaternion) -> Vector3:
	return Vector3(2.0 * (q.x * q.y - q.w * q.z), 1.0 - 2.0 * (q.x * q.x + q.z * q.z), 2.0 * (q.y * q.z + q.w * q.x))


static func _axis_z(q: Quaternion) -> Vector3:
	return Vector3(2.0 * (q.x * q.z + q.w * q.y), 2.0 * (q.y * q.z - q.w * q.x), 1.0 - 2.0 * (q.x * q.x + q.y * q.y))
