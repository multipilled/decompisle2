class_name DI2Explosion
extends Node3D
## DI2's explosion action (UExplosionAction, recon/RE_EXPLOSIONS.md), driven by a DA_ExplosionArchetype from
## data/explosions.json (tools/build_explosions.py):
## - the blast front grows at BlastSpeed up to the (modified) OuterRadius (tick 0x1414020f0); a zombie is hit once,
##   when the front reaches it;
## - static geometry between the centre and the victim occludes it (StaticOcclusion per blocker, 0x1413f44c0); at
##   Impacts.OccludedImpactSkipThreshold (0.9) the victim is skipped;
## - damage per DamageDefinition = static-occlusion scale x DamageMultiplier x angle scale x distance scale(d / R)
##   x Damage (0x141413040), the distance curve picked per victim class (DistanceScaleCurveClassOverrides);
## - stability force = StabilityDamageForce x ForceMultiplier x angle x stability distance scale x occlusion scale,
##   impulse = BlastImpulse x the archetype distance scale, capped at 30000 (0x1413f22e0);
## - the hit carries the archetype's ImpactKB facts and RadialToBodyPartDamageMultiplier (BodyPart-
##   DamageEffectivenessMultiplier when the ImpactData can break / dismember / bisect), goes through the archetype's
##   VictimEffectTree (CT_HitEffect_Explosion_Victim) and spreads its part damage over the body parts like DI2's
##   MultiPartHealth (GoreBody.set_radial_part_budget, 0x1412c0940).

## Emitted when the blast front reaches OuterRadius, with hits_log.
signal finished(hits: Array)

const DATA_PATH := "res://data/explosions.json"
## Impacts.OccludedImpactSkipThreshold (cvar default, 0x1404d93e0).
const OCCLUDED_SKIP := 0.9
## The impulse cap in 0x1413f22e0.
const IMPULSE_CAP := 30000.0
## MultiPartHealth.RadialDamageQuantityToBodyPartDamageConversionFactor (cvar default 1.0, 0x1404c2d10).
const PART_CONVERSION := 1.0

static var _data := {}

var arch: Dictionary
var radius := 1.0          # m (ModifiedExplosionOuterRadius / 100)
var damage_mult := 1.0     # ExplosionActionParams.DamageMultiplier (the thrower's ExplosionDamage attribute)
var force_mult := 1.0      # ExplosionActionParams.ForceMultiplier
var instigator: Node3D
var t := 0.0
var _hit := {}
## Per victim, for tests: [zombie name, distance m, x, damage, stability force, impulse, occlusion].
var hits_log := []


static func data() -> Dictionary:
	if _data.is_empty():
		_data = Util.load_json(DATA_PATH)
	return _data


## Starts DI2 explosion `archetype` (e.g. "PipeBomb") at `at`. `damage_mult` stands in for the thrower's
## DA_Attribute_Throwable_ExplosionDamage value (bUseDamageAttributeMultiplier).
static func spawn(parent: Node, archetype: String, at: Vector3, by: Node3D = null, damage_mult := 1.0) -> DI2Explosion:
	var a: Dictionary = data()["archetypes"].get(archetype, {})
	if a.is_empty():
		push_warning("DI2Explosion: unknown archetype %s" % archetype)
		return null
	var e := DI2Explosion.new()
	e.arch = a
	e.radius = float(a["OuterRadius"]) / 100.0
	e.damage_mult = damage_mult
	e.instigator = by
	parent.add_child(e)
	e.global_position = at
	# The archetype's CosmeticEffects (particles session's DI2Particles); the recreation's blast as a stand-in.
	var ce := str(a.get("CosmeticEffects", ""))
	if ce != "" and DI2Particles.db().get("ce", {}).has(ce):
		DI2Particles.play_ce(parent, ce, at, Vector3.UP, Vector3.DOWN)
	else:
		Fx.explosion(parent, at)
	return e


func _physics_process(delta: float) -> void:
	t += delta
	var speed := float(arch["BlastSpeed"]) / 100.0
	var front := radius if speed <= 0.0 else minf(speed * t, radius)
	for z: Zombie in get_tree().get_nodes_in_group("zombies"):
		if _hit.has(z.get_instance_id()):   # corpses too: DI2 keeps shredding them
			continue
		# The front's sphere overlap (0x1414020f0) catches the character by its root component (the capsule); its
		# damage is measured to the mesh bounds origin (victim_point).
		if _capsule_distance(z) <= front:
			_hit[z.get_instance_id()] = true
			_apply(z, victim_point(z))
	if front >= radius:
		finished.emit(hits_log)
		queue_free()


## Where DI2 measures a character from (0x141414810): the character Mesh's Bounds.Origin, the centre of
## UPhysicsAsset::CalcAABB over PA_ZombieStandard's BoundsBodies (all 20 bodies, the root sphere included) with
## each body's shapes in its bone's posed frame. When the victim's UPhysicalizedReactionComponent is in state 4
## (+0x924) DI2 uses that component's stored transform (+0x9c0) instead: not identified, the bounds stand in
## (UNVERIFIED #51).
static func victim_point(z: Zombie) -> Vector3:
	var box := victim_bounds(z)
	return box.get_center() if box.size != Vector3.ZERO else z.global_position + Vector3.UP


## The posed physics-asset bounds (world AABB) of a zombie.
static func victim_bounds(z: Zombie) -> AABB:
	var sk := z.skeleton
	var k := z.body_scale
	var box := AABB()
	var first := true
	for b: Dictionary in PhysicalReaction.load_spec()["bodies"]:
		var bi := sk.find_bone(b["bone"])
		if bi < 0:
			continue
		var bx := sk.global_transform * sk.get_bone_global_pose(bi)
		for sh: Dictionary in b["shapes"]:
			var c := Vector3(sh["center"][0], sh["center"][1], sh["center"][2]) * k
			var pts: Array[Vector3] = []
			var pad := 0.0
			match sh["type"]:
				"sphere":
					pts = [c]
					pad = float(sh["radius"]) * k
				"capsule":
					var bs := _basis9(sh["basis"])
					var r := float(sh["radius"]) * k
					var half := maxf(float(sh["height"]) * k * 0.5 - r, 0.0)
					pts = [c + bs.y * half, c - bs.y * half]
					pad = r
				"box":
					var bs := _basis9(sh["basis"])
					var e := Vector3(sh["size"][0], sh["size"][1], sh["size"][2]) * k * 0.5
					for sx in [-1.0, 1.0]:
						for sy in [-1.0, 1.0]:
							for sz in [-1.0, 1.0]:
								pts.append(c + bs * Vector3(e.x * sx, e.y * sy, e.z * sz))
			for q: Vector3 in pts:
				var w := bx * q
				var sb := AABB(w - Vector3.ONE * pad, Vector3.ONE * pad * 2.0)
				box = sb if first else box.merge(sb)
				first = false
	return box


static func _basis9(a: Array) -> Basis:
	return Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])).orthonormalized()


## Distance from the blast origin to the victim's capsule surface (sphere vs. capsule overlap).
func _capsule_distance(z: Zombie) -> float:
	var cs: CollisionShape3D = z.root_shape
	if cs == null or not (cs.shape is CapsuleShape3D):
		return global_position.distance_to(victim_point(z))
	var cap := cs.shape as CapsuleShape3D
	var up := cs.global_basis.y.normalized()
	var half := maxf(cap.height * 0.5 - cap.radius, 0.0)
	var a := cs.global_position - up * half
	var ab := up * half * 2.0
	var t := clampf((global_position - a).dot(ab) / maxf(ab.length_squared(), 1e-8), 0.0, 1.0)
	return global_position.distance_to(a + ab * t) - cap.radius


## DI2's distance scale (0x1414010f0 picks the curve, 0x1414319f0 / the inline fallback evaluate it): the most
## derived class override matching the victim, else `fallback`; with no curve, sat(1 - x).
static func distance_scale(curve: String, x: float) -> float:
	if curve == "":
		return clampf(1.0 - x, 0.0, 1.0)
	return _eval(data()["curves"].get(curve, []), x)


static func _eval(keys: Array, x: float) -> float:
	if keys.is_empty():
		return 0.0
	if x <= float(keys[0][0]):
		return float(keys[0][1])
	for i in range(1, keys.size()):
		if x < float(keys[i][0]):
			var a: Array = keys[i - 1]
			var b: Array = keys[i]
			var dt := float(b[0]) - float(a[0])
			var u := (x - float(a[0])) / dt if dt > 0.0 else 0.0
			match str(a[2]):
				"K":
					return float(a[1])
				"C":
					var p0 := float(a[1])
					var p3 := float(b[1])
					var p1 := p0 + float(a[4]) * dt / 3.0
					var p2 := p3 - float(b[3]) * dt / 3.0
					var w := 1.0 - u
					return w * w * w * p0 + 3.0 * w * w * u * p1 + 3.0 * w * u * u * p2 + u * u * u * p3
				_:
					return lerpf(float(a[1]), float(b[1]), u)
	return float(keys.back()[1])


## The victim's DI2 class chain, most derived first (every zombie family derives from BP_Base_Zombie_C).
static func classes(z: Zombie) -> Array:
	return ["BP_Base_%s_C" % z.family(), "BP_Base_Zombie_C"]


static func pick_curve(overrides: Dictionary, z: Zombie, fallback: String) -> String:
	for c in classes(z):
		if overrides.has(c) and overrides[c] != null:
			return str(overrides[c])
	return fallback


## Static occlusion from the centre to the victim: each static blocker adds (1 - occ) x StaticOcclusion
## (0x1413f44c0). Zombies are the recreation's only dynamic bodies and aren't traced (UNVERIFIED #51).
func _occlusion(p: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	var occ := 0.0
	var from := global_position
	for i in 4:
		var q := PhysicsRayQueryParameters3D.create(from, p, Util.WORLD)
		var r := space.intersect_ray(q)
		if r.is_empty():
			break
		occ = (1.0 - occ) * float(arch["StaticOcclusion"]) + occ
		from = (r["position"] as Vector3) + (p - from).normalized() * 0.02
	return occ


func _apply(z: Zombie, p: Vector3) -> void:
	var occ := _occlusion(p)
	if occ >= OCCLUDED_SKIP:
		hits_log.append([str(z.name), 0.0, 0.0, 0.0, 0.0, 0.0, occ])
		return
	var d := global_position.distance_to(p)
	var x := d / radius if radius > 0.0 else 1.0
	var angle := 1.0   # AngleScaleCurve: no throwable sets one
	var arch_curve := pick_curve(arch["DistanceScaleCurveClassOverrides"], z, str(arch.get("DistanceScaleCurve") if arch.get("DistanceScaleCurve") != null else ""))
	# Damage per definition (0x141413040). Balancing data (PlayerBasedRules) only scales the player: (1, 1) here.
	var occ_damage := _scale_curve("StaticOcclusionDamageScaleCurve", occ)
	var damage := 0.0
	var dtype := ""
	var force_fact := 0.0
	var dismember_on_kill := 0.0
	for def: Dictionary in arch["DamageDefinitions"]:
		var c := pick_curve(def["DistanceScaleCurveClassOverrides"], z, str(def["DistanceScaleCurve"]) if def["DistanceScaleCurve"] != null else arch_curve)
		var dd := occ_damage * damage_mult * angle * distance_scale(c, x) * float(def["Damage"])
		damage += dd
		if dtype == "":
			dtype = str(def["DamageType"])
			force_fact = float(def["Force"])
			dismember_on_kill = float(def["DismembermentChanceOnKill"])
	# Impulse and stability force (0x1413f22e0).
	var impulse := minf(_scale_curve("DynamicOcclusionImpactScaleCurve", 0.0) * _scale_curve("StaticOcclusionImpactScaleCurve", occ)
		* angle * distance_scale(arch_curve, x) * float(arch["BlastImpulse"]), IMPULSE_CAP)
	var stab_curve := pick_curve(arch["StabilityDistanceScaleCurveClassOverrides"], z,
		str(arch["StabilityDistanceScaleCurve"]) if arch["StabilityDistanceScaleCurve"] != null else arch_curve)
	var stability := _scale_curve("StaticOcclusionStabilityScaleCurve", occ) * force_mult * angle * distance_scale(stab_curve, x) * float(arch["StabilityDamageForce"])
	hits_log.append([str(z.name), d, x, damage, stability, impulse, occ])
	if damage <= 0.0 and stability <= 0.0:
		return
	# Facts: RadialToBodyPartDamageMultiplier, then the archetype's ImpactKB (Thrown, Nail_Bomb, Fire_Bomb ...).
	# {Hit}.ThrownAttack is DSDamageData.bThrownAttack (false on every throwable explosion's damage definition).
	var imp: Dictionary = arch["ImpactData"]
	var part_mult := float(arch["BodyPartDamageEffectivenessMultiplier"]) if (imp["bCanCauseBreak"] or imp["bCanCauseDismember"] or imp["bCanCauseBisection"]) else 0.0
	var facts := {"RadialToBodyPartDamageMultiplier": part_mult}
	for f: Array in arch["ImpactKB"]:
		facts[str(f[0])] = f[1]
	# The impact's bone: the hitbox bone nearest the centre (UNVERIFIED #51).
	var bone := _nearest_bone(z)
	var sk := z.skeleton
	var bp := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin
	var dir := (bp - global_position).normalized()
	if dir.length() < 0.5:
		dir = Vector3.FORWARD
	# DI2 launch (DA_LaunchSettings_ExplosiveDefault): along the blast, at most 45 degrees up.
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	var push := flat.rotated(flat.cross(Vector3.UP).normalized(), deg_to_rad(clampf(rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))), 0.0, 45.0))) if flat.length() > 0.1 else Vector3.UP
	z.gore.set_radial_part_budget(damage * part_mult * PART_CONVERSION)
	if instigator != null and not is_instance_valid(instigator):
		instigator = null   # freed meanwhile (e.g. the Suicider that detonated): the blast keeps going without a source
	var was_dead := z.dead
	var res := z.take_hit(bone, bp, dir, dir, damage, _kind(dtype), false, 1.0, stability, push, instigator,
		{"weapon": "", "tree": arch["VictimEffectTree"], "Force": force_fact, "ThrownAttack": false, "facts": facts,
		"CanBisect": bool(imp["bCanCauseBisection"]), "BisectionChance": float(imp["BisectionChance"]),
		"explosion_origin": global_position, "impulse": impulse, "dismember_on_kill": dismember_on_kill})
	# Each damage definition's AccumulatingEffectsToApply (status build-up, recon/RE_ACCUMULATING.md), level-scaled
	# when bUseScalingOnAccumulatingEffects (source: the instigator's level). Whether the blast distance scales them
	# is not traced (UNVERIFIED #52): applied in full.
	var src_level: int = instigator.get("level") if instigator and instigator.get("level") != null else z.level
	for def: Dictionary in arch["DamageDefinitions"]:
		if not z.dead and not (def.get("AccumulatingEffectsToApply", []) as Array).is_empty():
			z.accumulate(def["AccumulatingEffectsToApply"], src_level, bool(def.get("bUseScalingOnAccumulatingEffects", false)),
				res.get("point", bp), bone)
	if instigator and instigator.has_method("on_damage_dealt") and not res.is_empty() and not was_dead:
		instigator.popup(res.get("point", bp), str(roundi(damage)), "heavy")
		instigator.on_damage_dealt(damage, not res.get("alive", true), z)


func _scale_curve(key: String, v: float) -> float:
	var c: Variant = arch.get(key)
	return 1.0 - v if c == null else _eval(data()["curves"].get(str(c), []), v)


func _nearest_bone(z: Zombie) -> String:
	var best := "spine_03"
	var bd := INF
	var sk := z.skeleton
	for a: Area3D in z.hitboxes:
		if not is_instance_valid(a):
			continue
		var b: String = a.get_meta("bone")
		var i := sk.find_bone(b)
		if i < 0:
			continue
		var dd := (sk.global_transform * sk.get_bone_global_pose(i).origin).distance_to(global_position)
		if dd < bd:
			bd = dd
			best = b
	return best


## BP_DamageType_* -> the recreation's damage kinds.
static func _kind(t: String) -> String:
	return {"BP_DamageType_Explosive_C": "explosive", "BP_DamageType_Bleed_C": "bleed", "BP_DamageType_Fire_C": "fire",
		"BP_DamageType_Acid_C": "acid", "BP_DamageType_Electric_C": "electric", "BP_DamageType_Collision_C": "blunt"}.get(t, "explosive")
