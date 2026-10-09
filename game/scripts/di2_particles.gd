class_name DI2Particles
extends Node3D
## DI2's hit particle effects: a port of the UE 4.27 Cascade ParticleSystemComponent that Dead Island 2's cosmetic
## effects (CE_*) spawn on zombie hits, driven by DI2's own cooked particle data (game/data/particles.json, built by
## tools/build_particles.py). Format, the DI2 source of every value and what is approximated: recon/PARTICLES.md.
##
## Public API (static):
##   DI2Particles.play_ce(parent, "CE_Blunt_Medium_Normal", hit_pos, hit_normal, hit_dir)
##     plays every ParticleSystem the CE lists (and its nested CEs). parent = the node the effect attaches to when
##     the CE doesn't force world space (DI2 attaches to the hit component; pass the zombie or a bone attachment).
##     hit_normal = outward surface normal, hit_dir = direction the hit travels (attacker -> victim). Optional
##     `factor` = the hit tree's DirectionInterpolationFactor for this CE (default: from hit_effects.json); the
##     base rotation is HitEffectSpawn.point_basis (DI2 0x1414810b0). Optional `base` (Basis) skips that and uses
##     the caller's spawn rotation as is (e.g. HitEffectSpawn.radial_basis for explosions).
##   DI2Particles.play_ps(parent, "PS_Bullet_Flesh", xform, attached)   one system at a Godot transform.
##
## How it runs: one DI2Particles node = one ParticleSystemComponent. Each emitter is simulated on the CPU in DI2's
## space (UE units: cm, X forward, Y right, Z up) with the Cascade module semantics read from DI2's exe
## (tools/particles/*, extracted/ghidra_particles/*.c) and drawn with one MultiMeshInstance3D per emitter
## (sprites camera-aligned on the CPU exactly like ParticleSpriteVertexFactory; meshes with their particle
## transforms). Materials are the decompiled DI2 particle shaders (game/shaders/di2_particle_*.gdshader).

const DATA_PATH := "res://data/particles.json"
const ASSET_DIR := "res://assets/di2/particles/"
const UE_TO_M := 0.01
const M_TO_UE := 100.0
const MAX_PARTICLES_PER_EMITTER := 4000  # safety only; DI2 grows its arrays (ParticleModuleRequired MaxDrawCount is a draw limit)
const LOOPING_LIFETIME_CAP := 30.0       # UNVERIFIED: how DI2's CE deactivates a looping system is native (not decoded)

# Particle state flags (UE 4.27 FBaseParticle::Flags).
const F_JUST_SPAWNED := 0x02000000
const F_FREEZE := 0x04000000
const F_IGNORE_COLLISIONS := 0x08000000
const F_FREEZE_TRANSLATION := 0x10000000
const F_FREEZE_ROTATION := 0x20000000
const F_DELAY_COLLISIONS := 0x00000000  # folded into the collision delay array below

static var _db: Dictionary = {}
static var _tex: Dictionary = {}
static var _mesh: Dictionary = {}
static var _mat: Dictionary = {}
static var _shader: Dictionary = {}
static var _quad: ArrayMesh
static var _default_factor: Dictionary = {}
## Systems started by the last play_ce / play_ps call (tests drive them with advance()).
static var last_spawned: Array = []
static var _depth := 0
## Tests / benchmarks: >= 0 seeds every new system's RNG with seed_override + a running count (deterministic runs).
static var seed_override := -1
static var _seed_count := 0
## Profiling (benchmarks): accumulated microseconds per phase while prof_on.
static var prof_on := false
static var prof_fine := false  ## per-module timers inside Emitter.tick (adds overhead)
## Upload each emitter's instances with one MultiMesh buffer write instead of three calls per instance.
static var buffer_upload := true
## Simulate in Rust (DI2ParticleSim, rust/gore-godot/src/particles) when the GDExtension has it; false = the GDScript
## simulation below (same behaviour; kept as the reference / fallback, A/B-able).
static var use_rust := true
static var prof := {"tick": 0, "events": 0, "render": 0}

# --- instance (one ParticleSystemComponent) ---------------------------------------------------------------------
var ps_name := ""
var system: Dictionary = {}
var params: Dictionary = {}
var emitters: Array = []
var lod := 0
var rng := RandomNumberGenerator.new()
var age := 0.0
var just_registered := true
var comp_basis := Basis.IDENTITY     # component rotation in UE space
var comp_loc := Vector3.ZERO         # component location in UE space (cm)
var comp_old_loc := Vector3.ZERO
var part_sys_velocity := Vector3.ZERO  # UParticleSystemComponent::PartSysVelocity (UE cm/s)
var events: Array = []                # [kind, name, loc(UE world), vel(UE world), dir, normal, emitter]
var camera_ue := Vector3.ZERO
var desat := 0.0
var sim = null                         # DI2ParticleSim (untyped: the class comes from the GDExtension) when use_rust
var sim_lights := false                # the system has UParticleModuleLight emitters
var _lights: Array[OmniLight3D] = []


# =================================================================================================================
# Public API
# =================================================================================================================

static func db() -> Dictionary:
	if _db.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f == null:
			push_error("DI2Particles: %s missing (run tools/build_particles.py)" % DATA_PATH)
			return _db
		_db = JSON.parse_string(f.get_as_text())
		if use_rust and ClassDB.class_exists("DI2ParticleSim"):
			ClassDB.instantiate("DI2ParticleSim").preload()  # the Rust simulation's own parse, at the same time
	return _db


## Replaces every distribution (cooked lookup table or UDistribution object) inside the systems' module data by a
## compiled Dist (same math, typed fields: no per-evaluation dictionary lookups).
static func _compile_dists(node) -> void:
	if node is Dictionary:
		for k in node.keys():
			var v = node[k]
			if v is Dictionary and Dist.is_dist(v):
				node[k] = Dist.new(v)
			elif v is Dictionary or v is Array:
				_compile_dists(v)
	elif node is Array:
		for i in node.size():
			var v = node[i]
			if v is Dictionary and Dist.is_dist(v):
				node[i] = Dist.new(v)
			elif v is Dictionary or v is Array:
				_compile_dists(v)


static func play_ce(parent: Node, ce_name: String, world_pos: Vector3, normal: Vector3, dir: Vector3,
		factor := -1.0, ps_params := {}, base: Variant = null) -> void:
	var d := db()
	var ce: Dictionary = d.get("ce", {}).get(ce_name, {})
	if ce.is_empty():
		return
	if base == null:
		if factor < 0.0:
			var fs: Array = ce.get("factors", [])
			factor = 1.0 if fs.has(1.0) else (float(fs[0]) if fs.size() > 0 else 0.0)
		base = ce_rotation(normal, dir, factor)
	if _depth == 0:
		last_spawned = []
	_depth += 1
	for link: Dictionary in ce.get("ps", []):
		var b: Basis = base
		if link.get("rot") != null:
			b = b * ue_rotator_basis_g(link["rot"])
		var attached: bool = not link.get("force_not_attached", false)
		var p := play_ps(parent, link["ps"], Transform3D(b, world_pos), attached, ps_params)
		if p and link.get("desaturation") != null:
			p.desat = float(link["desaturation"])
	for n in ce.get("nested", []):
		if n != ce_name:
			play_ce(parent, n, world_pos, normal, dir, factor, ps_params, base)
	_depth -= 1


## Loads what the given CEs / particle systems need before their first play: the data, the Rust simulation's emitter
## templates, and every emitter's material, textures and mesh (a first play_ce otherwise pays for these: ~30 ms per
## new system). For level load. `lod`: the LOD to prepare (hits near the camera use 0).
static func prewarm(names: Array, lod := 0) -> void:
	var d := db()
	var systems := {}
	var seen := {}
	var todo: Array = names.duplicate()
	while not todo.is_empty():
		var n: String = todo.pop_back()
		if seen.has(n):
			continue
		seen[n] = true
		var ce: Dictionary = d.get("ce", {}).get(n, {})
		if not ce.is_empty():
			for link: Dictionary in ce.get("ps", []):
				systems[link["ps"]] = true
			todo.append_array(ce.get("nested", []))
		elif d.get("ps", {}).has(n):
			systems[n] = true
	var rust := use_rust and ClassDB.class_exists("DI2ParticleSim")
	for ps: String in systems:
		var host := DI2Particles.new()
		host.ps_name = ps
		host.system = d["ps"][ps]
		host.lod = lod
		var i := 0
		for ed in host.system.get("emitters", []):
			if ed == null:
				continue
			var e := Emitter.new(host, ed, i, true)
			if e.kind != Emitter.Kind.NONE and e.enabled and not e.lights_only:
				e._make_renderer()
			i += 1
		if rust:
			ClassDB.instantiate("DI2ParticleSim").setup(ps, lod, 0, {}, 0)
		host.free()


## DI2's point-impact hit-effect rotation (exe 0x1414810b0, recon/RE_FLESH.md "Hit-effect spawn transform"):
## HitEffectSpawn.point_basis = orient(ImpactNormal), slerped toward orient(travel direction) by the factor, re-rolled
## so Y = normalize(travel x X) when factor < 1. `dir` = the hit's travel (attacker -> victim). Godot basis out.
static func ce_rotation(normal: Vector3, dir: Vector3, factor: float) -> Basis:
	return HitEffectSpawn.point_basis(normal.normalized() if normal.length_squared() > 0.0 else Vector3.UP, dir, factor)


## One ParticleSystem at a Godot transform. attached: child of `parent` (follows it), else in world space.
static func play_ps(parent: Node, ps: String, xf: Transform3D, attached := false, ps_params := {}) -> DI2Particles:
	var d := db()
	if not d.get("ps", {}).has(ps):
		return null
	var p := DI2Particles.new()
	p.ps_name = ps
	p.system = d["ps"][ps]
	if not p.system.has("_compiled") and not (use_rust and ClassDB.class_exists("DI2ParticleSim")):
		_compile_dists(p.system.get("emitters", []))  # GDScript simulation: once per system, on first play
		p.system["_compiled"] = true
	p.params = ps_params
	p.name = ps
	var host: Node = parent
	if not attached or host == null:
		host = parent.get_tree().current_scene if parent and parent.is_inside_tree() else parent
		if host == null:
			return null
	host.add_child(p)
	p.global_transform = xf
	p._activate()
	last_spawned.append(p)
	return p


# =================================================================================================================
# Space conversion. DI2/UE: cm, X fwd, Y right, Z up (left-handed). Godot: m, Y up. Same mapping as CUE4Parse's
# glTF export used for every other DI2 asset in this project: Godot (x, y, z) = UE (x, z, y) * 0.01.
# =================================================================================================================

static func u2g(p: Vector3) -> Vector3:
	return Vector3(p.x, p.z, p.y) * UE_TO_M


static func g2u(p: Vector3) -> Vector3:
	return Vector3(p.x, p.z, p.y) * M_TO_UE


static func u2g_dir(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, v.y)


static func g2u_dir(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, v.y)


static func u2g_basis(b: Basis) -> Basis:
	# S * B * S with S = swap(y, z) (its own inverse); keeps det(B).
	return Basis(u2g_dir(b * Vector3(1, 0, 0)), u2g_dir(b * Vector3(0, 0, 1)), u2g_dir(b * Vector3(0, 1, 0)))


static func g2u_basis(b: Basis) -> Basis:
	return Basis(g2u_dir(b * Vector3(1, 0, 0)), g2u_dir(b * Vector3(0, 0, 1)), g2u_dir(b * Vector3(0, 1, 0)))


## UE FRotationTranslationMatrix(FRotator(Pitch, Yaw, Roll)) (degrees; decompiled in DI2 at 0x1409fe120, vectorised
## DEG_TO_RAD + SinCos): rows X, Y, Z become the basis columns.
static func rotator_basis_ue(pitch: float, yaw: float, roll: float) -> Basis:
	var sp := sin(deg_to_rad(pitch)); var cp := cos(deg_to_rad(pitch))
	var sy := sin(deg_to_rad(yaw)); var cy := cos(deg_to_rad(yaw))
	var sr := sin(deg_to_rad(roll)); var cr := cos(deg_to_rad(roll))
	var x := Vector3(cp * cy, cp * sy, sp)
	var y := Vector3(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp)
	var z := Vector3(-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp)
	return Basis(x, y, z)


## FQuat::FindBetweenNormals (UE 4.27), as (x, y, z, w) in UE space.
static func find_between_normals_ue(a: Vector3, b: Vector3) -> Quaternion:
	var w := 1.0 + a.dot(b)
	var q: Quaternion
	if w >= 1e-6:
		q = Quaternion(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x, w)
	else:
		q = Quaternion(-a.z, 0.0, a.x, 0.0) if absf(a.x) > absf(a.y) else Quaternion(0.0, -a.z, a.y, 0.0)
	return q.normalized()


## FQuat::Euler() = FQuat::Rotator().Euler() (UE 4.27): (Roll, Pitch, Yaw) degrees.
static func quat_euler_ue(q: Quaternion) -> Vector3:
	var st := q.z * q.x - q.w * q.y
	var yy := 2.0 * (q.w * q.z + q.x * q.y)
	var yx := 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
	var pitch: float; var yaw: float; var roll: float
	if st < -0.4999995:
		pitch = -90.0
		yaw = rad_to_deg(atan2(yy, yx))
		roll = _normalize_axis(-yaw - rad_to_deg(2.0 * atan2(q.x, q.w)))
	elif st > 0.4999995:
		pitch = 90.0
		yaw = rad_to_deg(atan2(yy, yx))
		roll = _normalize_axis(yaw - rad_to_deg(2.0 * atan2(q.x, q.w)))
	else:
		pitch = rad_to_deg(asin(2.0 * st))
		yaw = rad_to_deg(atan2(yy, yx))
		roll = rad_to_deg(atan2(-2.0 * (q.w * q.x + q.y * q.z), 1.0 - 2.0 * (q.x * q.x + q.y * q.y)))
	return Vector3(roll, pitch, yaw)


static func _normalize_axis(a: float) -> float:
	a = fmod(a, 360.0)
	if a < 0.0:
		a += 360.0
	if a > 180.0:
		a -= 360.0
	return a


static func ue_rotator_basis_g(r: Array) -> Basis:
	return u2g_basis(rotator_basis_ue(float(r[0]), float(r[1]), float(r[2])))


# =================================================================================================================
# Distributions: UE 4.27 FRawDistribution lookup tables exactly as DI2's exe evaluates them (FUN_1436effe0 float,
# FUN_1436f0260 vector): entry = clamp((t - TimeBias) * TimeScale, 0) -> index min(trunc, n-1), next min(i+1, n-1),
# alpha = frac. Op 1 none, 2 random (min..max per component, lock flags tie components), 3 extreme (min or max set).
# Cook-kept UDistribution objects (FC/FU/FCC/VC/VCC/FP/VP) are evaluated like their classes.
# =================================================================================================================

static func df(d, t: float, rng: RandomNumberGenerator, params := {}) -> float:
	if d == null:
		return 0.0
	if d is Dist:
		return d.f(t, rng, params)
	if d.has("op"):
		var v: Array = d["v"]
		var s: int = d["s"]
		var rel := maxf((t - float(d["tb"])) * float(d["ts"]), 0.0)
		var n: int = d["n"]
		var i := mini(int(rel), n - 1)
		var j := mini(i + 1, n - 1)
		var a := rel - floorf(rel)
		var op: int = d["op"]
		if op == 1:
			return lerpf(v[i * s], v[j * s], a)
		var r := rng.randf()
		if op == 2:
			var lo := lerpf(v[i * s], v[j * s], a)
			var hi := lerpf(v[i * s + 1], v[j * s + 1], a)
			return lerpf(lo, hi, r)
		var k := 1 if r > 0.5 else 0
		return lerpf(v[i * s + k], v[j * s + k], a)
	match d.get("d", ""):
		"FC":
			return float(d["c"])
		"FU":
			return lerpf(float(d["min"]), float(d["max"]), rng.randf())
		"FCC":
			return float(_curve(d["pts"], t))
		"FP":
			return _param_map(d, params.get(d["name"], null))
	return 0.0


static func dv(d, t: float, rng: RandomNumberGenerator, params := {}) -> Vector3:
	if d == null:
		return Vector3.ZERO
	if d is Dist:
		return d.v(t, rng, params)
	if d.has("op"):
		var v: Array = d["v"]
		var s: int = d["s"]
		var rel := maxf((t - float(d["tb"])) * float(d["ts"]), 0.0)
		var n: int = d["n"]
		var i := mini(int(rel), n - 1)
		var j := mini(i + 1, n - 1)
		var a := rel - floorf(rel)
		var op: int = d["op"]
		var e1 := i * s
		var e2 := j * s
		if op == 1:
			return Vector3(lerpf(v[e1], v[e2], a), lerpf(v[e1 + 1], v[e2 + 1], a), lerpf(v[e1 + 2], v[e2 + 2], a))
		if op == 2:
			var r := Vector3(rng.randf(), rng.randf(), rng.randf())
			match int(d["lock"]):
				1: r.y = r.x
				2: r.z = r.x
				3: r.z = r.y
				4: r.y = r.x; r.z = r.x
			var lo := Vector3(lerpf(v[e1], v[e2], a), lerpf(v[e1 + 1], v[e2 + 1], a), lerpf(v[e1 + 2], v[e2 + 2], a))
			var hi := Vector3(lerpf(v[e1 + 3], v[e2 + 3], a), lerpf(v[e1 + 4], v[e2 + 4], a), lerpf(v[e1 + 5], v[e2 + 5], a))
			return Vector3(lerpf(lo.x, hi.x, r.x), lerpf(lo.y, hi.y, r.y), lerpf(lo.z, hi.z, r.z))
		var k := 3 if rng.randf() > 0.5 else 0
		return Vector3(lerpf(v[e1 + k], v[e2 + k], a), lerpf(v[e1 + k + 1], v[e2 + k + 1], a), lerpf(v[e1 + k + 2], v[e2 + k + 2], a))
	match d.get("d", ""):
		"VC":
			return _lock(_v3(d["c"]), d.get("lock", "EDVLF_None"))
		"VU":
			var lo := _v3(d["min"]); var hi := _v3(d["max"])
			var r := _lock(Vector3(rng.randf(), rng.randf(), rng.randf()), d.get("lock", "EDVLF_None"))
			return Vector3(lerpf(lo.x, hi.x, r.x), lerpf(lo.y, hi.y, r.y), lerpf(lo.z, hi.z, r.z))
		"VCC":
			return _lock(_v3(_curve(d["pts"], t)), d.get("lock", "EDVLF_None"))
		"VP":
			var pv = params.get(d["name"], null)
			var inp: Array = d["in"]; var outp: Array = d["out"]; var c: Array = d["c"]
			var res := Vector3.ZERO
			for k in 3:
				var x: float = (pv[k] if pv is Vector3 else (float(pv) if pv != null else float(c[k])))
				res[k] = _map1(x, float(inp[0][k]), float(inp[1][k]), float(outp[0][k]), float(outp[1][k]),
						d["mode"][k] if d["mode"] is Array else "DPM_Normal")
			return res
	return Vector3.ZERO


## A compiled distribution: df / dv's math on typed fields. Lookup tables keep DI2's values as doubles (the JSON
## numbers), so results are bit-identical to evaluating the dictionary; constant tables (op 1, one entry) return
## the value directly (lerpf(x, x, a) == x). UDistribution objects other than FC / FU / VC / VU defer to df / dv.
class Dist:
	extends RefCounted
	const LUT := 0
	const FC := 1
	const FU := 2
	const VC := 3
	const VU := 4
	const OTHER := 5
	var kind := OTHER
	var op := 1
	var n := 1
	var s := 1
	var ts := 0.0
	var tb := 0.0
	var vals := PackedFloat64Array()
	var lock := 0
	var lock_s := "EDVLF_None"
	var constant := false
	var cf := 0.0
	var cv := Vector3.ZERO
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	var raw: Dictionary

	static func is_dist(d: Dictionary) -> bool:
		if d.has("op") and d.has("v"):
			return true
		return d.get("d", "") in ["FC", "FU", "FCC", "FP", "VC", "VU", "VCC", "VP"]

	func _init(d: Dictionary) -> void:
		raw = d
		if d.has("op"):
			kind = LUT
			op = int(d["op"]); n = int(d["n"]); s = int(d["s"]); ts = float(d["ts"]); tb = float(d["tb"])
			lock = int(d.get("lock", 0))
			for x in d["v"]:
				vals.append(float(x))
			constant = op == 1 and n == 1
			if constant:
				cf = vals[0]
				if vals.size() >= 3:
					cv = Vector3(vals[0], vals[1], vals[2])
			return
		lock_s = d.get("lock", "EDVLF_None")
		match d["d"]:
			"FC":
				kind = FC; cf = float(d["c"])
			"FU":
				kind = FU; lo.x = float(d["min"]); hi.x = float(d["max"])
			"VC":
				kind = VC; cv = DI2Particles._lock(DI2Particles._v3(d["c"]), lock_s)
			"VU":
				kind = VU; lo = DI2Particles._v3(d["min"]); hi = DI2Particles._v3(d["max"])

	func f(t: float, rng: RandomNumberGenerator, params: Dictionary) -> float:
		if kind == LUT:
			if constant:
				return cf
			var rel := maxf((t - tb) * ts, 0.0)
			var i := mini(int(rel), n - 1)
			var j := mini(i + 1, n - 1)
			var a := rel - floorf(rel)
			if op == 1:
				return lerpf(vals[i * s], vals[j * s], a)
			var r := rng.randf()
			if op == 2:
				var l := lerpf(vals[i * s], vals[j * s], a)
				var h := lerpf(vals[i * s + 1], vals[j * s + 1], a)
				return lerpf(l, h, r)
			var k := 1 if r > 0.5 else 0
			return lerpf(vals[i * s + k], vals[j * s + k], a)
		if kind == FC:
			return cf
		if kind == FU:
			return lerpf(lo.x, hi.x, rng.randf())
		return DI2Particles._df_raw(raw, t, rng, params)

	func v(t: float, rng: RandomNumberGenerator, params: Dictionary) -> Vector3:
		if kind == LUT:
			if constant:
				return cv
			var rel := maxf((t - tb) * ts, 0.0)
			var i := mini(int(rel), n - 1)
			var j := mini(i + 1, n - 1)
			var a := rel - floorf(rel)
			var e1 := i * s
			var e2 := j * s
			if op == 1:
				return Vector3(lerpf(vals[e1], vals[e2], a), lerpf(vals[e1 + 1], vals[e2 + 1], a), lerpf(vals[e1 + 2], vals[e2 + 2], a))
			if op == 2:
				var r := Vector3(rng.randf(), rng.randf(), rng.randf())
				match lock:
					1: r.y = r.x
					2: r.z = r.x
					3: r.z = r.y
					4: r.y = r.x; r.z = r.x
				var l := Vector3(lerpf(vals[e1], vals[e2], a), lerpf(vals[e1 + 1], vals[e2 + 1], a), lerpf(vals[e1 + 2], vals[e2 + 2], a))
				var h := Vector3(lerpf(vals[e1 + 3], vals[e2 + 3], a), lerpf(vals[e1 + 4], vals[e2 + 4], a), lerpf(vals[e1 + 5], vals[e2 + 5], a))
				return Vector3(lerpf(l.x, h.x, r.x), lerpf(l.y, h.y, r.y), lerpf(l.z, h.z, r.z))
			var k := 3 if rng.randf() > 0.5 else 0
			return Vector3(lerpf(vals[e1 + k], vals[e2 + k], a), lerpf(vals[e1 + k + 1], vals[e2 + k + 1], a), lerpf(vals[e1 + k + 2], vals[e2 + k + 2], a))
		if kind == VC:
			return cv
		if kind == VU:
			var r := DI2Particles._lock(Vector3(rng.randf(), rng.randf(), rng.randf()), lock_s)
			return Vector3(lerpf(lo.x, hi.x, r.x), lerpf(lo.y, hi.y, r.y), lerpf(lo.z, hi.z, r.z))
		return DI2Particles._dv_raw(raw, t, rng, params)


## df / dv on the raw dictionaries (FCC / FP / VCC / VP objects, and anything not compiled).
static func _df_raw(d: Dictionary, t: float, rng: RandomNumberGenerator, params: Dictionary) -> float:
	var saved = d
	return df(saved, t, rng, params)


static func _dv_raw(d: Dictionary, t: float, rng: RandomNumberGenerator, params: Dictionary) -> Vector3:
	var saved = d
	return dv(saved, t, rng, params)


static func _v3(a) -> Vector3:
	if a is Vector3:
		return a
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _lock(v: Vector3, lock: String) -> Vector3:
	match lock:
		"EDVLF_XY": v.y = v.x
		"EDVLF_XZ": v.z = v.x
		"EDVLF_YZ": v.z = v.y
		"EDVLF_XYZ": v.y = v.x; v.z = v.x
	return v


static func _param_map(d: Dictionary, val) -> float:
	var x := float(val) if val != null else float(d["c"])
	return _map1(x, float(d["in"][0]), float(d["in"][1]), float(d["out"][0]), float(d["out"][1]), d["mode"])


## UDistributionFloatParameterBase::GetValue: DPM_Direct passes through, DPM_Abs uses |x|, then clamp to the input
## range and map linearly onto the output range.
static func _map1(x: float, in0: float, in1: float, out0: float, out1: float, mode) -> float:
	if mode == "DPM_Direct":
		return x
	if mode == "DPM_Abs":
		x = absf(x)
	var g := 0.0 if in1 <= in0 else (out1 - out0) / (in1 - in0)
	return out0 + (clampf(x, in0, in1) - in0) * g


## FInterpCurve::Eval (CIM_Linear lerp, CIM_Constant step, every CIM_Curve* mode = Hermite with the cooked tangents).
static func _curve(pts: Array, t: float):
	var n := pts.size()
	if n == 0:
		return 0.0
	if t <= float(pts[0][0]) or n == 1:
		return pts[0][1]
	if t >= float(pts[n - 1][0]):
		return pts[n - 1][1]
	var i := 0
	while i < n - 1 and t >= float(pts[i + 1][0]):
		i += 1
	var p0: Array = pts[i]; var p1: Array = pts[i + 1]
	var diff := float(p1[0]) - float(p0[0])
	if diff <= 0.0 or p0[4] == "CIM_Constant":
		return p0[1]
	var a := (t - float(p0[0])) / diff
	if p0[4] == "CIM_Linear":
		return _lerp_any(p0[1], p1[1], a)
	var a2 := a * a; var a3 := a2 * a
	var h00 := 2 * a3 - 3 * a2 + 1; var h10 := a3 - 2 * a2 + a; var h01 := -2 * a3 + 3 * a2; var h11 := a3 - a2
	if p0[1] is Array:
		var out := []
		for k in 3:
			out.append(h00 * p0[1][k] + h10 * p0[3][k] * diff + h01 * p1[1][k] + h11 * p1[2][k] * diff)
		return out
	return h00 * p0[1] + h10 * p0[3] * diff + h01 * p1[1] + h11 * p1[2] * diff


static func _lerp_any(a, b, t: float):
	if a is Array:
		return [lerpf(a[0], b[0], t), lerpf(a[1], b[1], t), lerpf(a[2], b[2], t)]
	return lerpf(a, b, t)


# =================================================================================================================
# Component (UParticleSystemComponent)
# =================================================================================================================

func _activate() -> void:
	if seed_override >= 0:
		rng.seed = seed_override + _seed_count
		_seed_count += 1
	else:
		rng.randomize()
	_update_component(0.0)
	comp_old_loc = comp_loc
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	camera_ue = g2u(cam.global_position) if cam else comp_loc
	lod = _lod_for_distance(comp_loc.distance_to(camera_ue))
	var rust := use_rust and ClassDB.class_exists("DI2ParticleSim")
	var i := 0
	for ed in system.get("emitters", []):
		if ed == null:
			continue
		var e := Emitter.new(self, ed, i, rust)
		emitters.append(e)
		i += 1
	if rust:
		sim = ClassDB.instantiate("DI2ParticleSim")
		if sim.setup(ps_name, lod, rng.seed, params, Util.WORLD) != emitters.size():
			push_warning("DI2Particles: %s: Rust emitter list differs, using the GDScript simulation" % ps_name)
			sim = null
	if sim:
		var kinds := PackedInt32Array()
		var rids := PackedInt64Array()
		var tiw := PackedByteArray()
		for e: Emitter in emitters:
			e.init_renderer()
			kinds.append(e.kind)
			rids.append(e.mm.get_rid().get_id() if e.mm else 0)
			tiw.append(1 if e.time_in_w else 0)
		sim.configure(kinds, rids, tiw, comp_basis, comp_loc)
		sim_lights = sim.has_lights()
	else:
		for e: Emitter in emitters:
			e.init_instance()


## UParticleSystemComponent LOD (PARTICLESYSTEMLODMETHOD_Automatic): the highest LOD whose LODDistances entry the
## camera distance reaches, chosen when the system activates. DI2's systems: [0, 1500, 3000, 7500] cm.
## UNVERIFIED: the periodic re-check (UParticleSystem::LODDistanceCheckTime) is not ported.
func _lod_for_distance(dist_cm: float) -> int:
	var ds: Array = system.get("lod_distances", [0.0])
	var best := 0
	for k in ds.size():
		if dist_cm >= float(ds[k]):
			best = k
	return best


func _update_component(dt: float) -> void:
	var gx := global_transform
	comp_basis = g2u_basis(gx.basis.orthonormalized())
	comp_old_loc = comp_loc
	comp_loc = g2u(gx.origin)
	if dt > 0.0 and not just_registered:
		part_sys_velocity = (comp_loc - comp_old_loc) / dt
	else:
		part_sys_velocity = Vector3.ZERO


func _process(delta: float) -> void:
	if delta > 0.0 and advance(delta):
		queue_free()


## One component tick (emitters, events, render). Returns true once every emitter has completed. Tests call it
## with a fixed dt after set_process(false).
func advance(delta: float) -> bool:
	age += delta
	_update_component(delta)
	var cam := get_viewport().get_camera_3d()
	camera_ue = g2u(cam.global_position) if cam else comp_loc
	if sim:
		return _advance_rust(delta, cam)
	var t0 := Time.get_ticks_usec() if prof_on else 0
	for e: Emitter in emitters:
		e.tick(delta)
	just_registered = false
	var t1 := Time.get_ticks_usec() if prof_on else 0
	_dispatch_events(delta)
	var t2 := Time.get_ticks_usec() if prof_on else 0
	var done := true
	for e: Emitter in emitters:
		e.render(cam)
		if not e.has_completed():
			done = false
	if prof_on:
		var t3 := Time.get_ticks_usec()
		prof["tick"] += t1 - t0
		prof["events"] += t2 - t1
		prof["render"] += t3 - t2
	return done or age > LOOPING_LIFETIME_CAP


## Deterministic-state checksum of every live particle (benchmarks compare it before / after optimisations).
func checksum() -> float:
	if sim:
		return sim.checksum()
	var c := 0.0
	for e: Emitter in emitters:
		for i in e.n:
			c += e.loc[i].x * 0.001 + e.loc[i].y * 0.002 + e.loc[i].z * 0.003 + e.vel[i].length() * 0.0001
			c += e.size[i].x * 0.01 + e.col[i].r + e.col[i].a * 0.5 + e.rel[i] + e.rot[i] * 0.1 + e.dyn[i].g
	return c


## Checksum of the drawn instance data (transforms, colours, custom data) of every emitter.
func render_checksum() -> float:
	var c := 0.0
	for e: Emitter in emitters:
		if e.mm == null or e.mm.visible_instance_count <= 0:
			continue
		var buf := e.mm.buffer
		var stride := 20
		for k in mini(e.mm.visible_instance_count * stride, buf.size()):
			c += buf[k] * (1.0 + float(k % 7) * 0.01)
	return c


## advance() with the Rust simulation: tick, size the MultiMeshes to the live counts, render.
func _advance_rust(delta: float, cam: Camera3D) -> bool:
	var t0 := Time.get_ticks_usec() if prof_on else 0
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state if is_inside_tree() else null
	var done: bool = sim.tick(delta, comp_basis, comp_loc, part_sys_velocity, camera_ue, space)
	just_registered = false
	var t1 := Time.get_ticks_usec() if prof_on else 0
	_render_rust(cam)
	if prof_on:
		prof["tick"] += t1 - t0
		prof["render"] += Time.get_ticks_usec() - t1
	return done or age > LOOPING_LIFETIME_CAP


func _render_rust(cam: Camera3D) -> void:
	var counts: PackedInt32Array = sim.counts()
	var caps := PackedInt32Array()
	caps.resize(emitters.size())
	for k in emitters.size():
		var e: Emitter = emitters[k]
		var n: int = counts[k]
		e.n = n
		if e.mm:
			if e.mm.instance_count < n:
				e.mm.instance_count = maxi(n, e.mm.instance_count * 2)
			e.mm.visible_instance_count = n
			caps[k] = e.mm.instance_count
	sim.render(cam.global_transform if cam else Transform3D.IDENTITY, caps)
	if sim_lights:
		_update_lights(sim.lights())


## UParticleModuleLight's simple lights (UE 4.27 GatherSimpleLights; DI2Particles' Rust sim) as pooled OmniLight3Ds:
## colour = particle rgb * alpha * ColorScale, radius = RadiusScale * (Size.x + Size.y) / 2. UE's inverse-squared
## falloff (exponent 0) is 1 / (d_cm^2 + 1): Godot energy = colour / 10000 with attenuation 2 (d in m); an exponent
## falloff maps to Godot's range window without distance decay. Brightness against Godot's lighting (not DI2's
## physical units / exposure) is APPROXIMATED (recon/PARTICLES.md 5).
func _update_lights(L: PackedFloat32Array) -> void:
	var cnt := L.size() / 9
	while _lights.size() < cnt:
		var nl := OmniLight3D.new()
		nl.top_level = true
		nl.shadow_enabled = false
		add_child(nl)
		_lights.append(nl)
	for k in _lights.size():
		var l := _lights[k]
		if k >= cnt:
			l.visible = false
			continue
		var o := k * 9
		var c := Vector3(L[o + 3], L[o + 4], L[o + 5])
		var m := maxf(c.x, maxf(c.y, c.z))
		if m <= 0.0:
			l.visible = false
			continue
		l.visible = true
		l.global_position = Vector3(L[o], L[o + 1], L[o + 2])
		l.light_color = Color(c.x / m, c.y / m, c.z / m)
		var expo := L[o + 7]
		l.light_energy = m / 10000.0 if expo == 0.0 else m
		l.omni_attenuation = 2.0 if expo == 0.0 else 0.0
		l.omni_range = maxf(L[o + 6], 0.01)
		var fl := int(L[o + 8])
		l.shadow_enabled = (fl & 6) == 6


## Rebuild the draw data for `cam` without simulating (sprites face the camera; tests that move the camera).
func render_now(cam: Camera3D) -> void:
	if sim:
		_render_rust(cam)
		return
	for e: Emitter in emitters:
		e.render(cam)


## One particle's state (tests / debug): loc, vel, size, col, rel, rot, dyn (UE space).
func particle_state(ei: int, i: int) -> Dictionary:
	if sim:
		return sim.particle(ei, i)
	var e: Emitter = emitters[ei]
	if i >= e.n:
		return {}
	return {"loc": e.loc[i], "vel": e.vel[i], "size": e.size[i], "col": e.col[i], "rel": e.rel[i], "rot": e.rot[i], "dyn": e.dyn[i]}


## UParticleModuleEventGenerator reports -> every emitter's UParticleModuleEventReceiverSpawn with the same event
## type and name: ForceSpawn(SpawnCount) at the event location with InheritVelocityScale * the event velocity.
func _dispatch_events(dt: float) -> void:
	if events.is_empty():
		return
	var evs := events
	events = []
	for ev in evs:
		for e: Emitter in emitters:
			e.receive_event(ev, dt)


func report_event(kind: String, ev_name: String, loc_world: Vector3, vel_world: Vector3, dir: Vector3, normal: Vector3) -> void:
	events.append([kind, ev_name, loc_world, vel_world, dir, normal])


# =================================================================================================================
# Assets
# =================================================================================================================

static func texture(name: String) -> Texture2D:
	if name == "" or name == null:
		return null
	if _tex.has(name):
		return _tex[name]
	var info: Dictionary = db().get("textures", {}).get(name, {})
	var t: Texture2D = null
	if info.has("file"):
		var path: String = ASSET_DIR + info["file"]
		var bytes := FileAccess.get_file_as_bytes(path)
		var img := Image.new()
		if path.ends_with(".dds"):
			if img.load_dds_from_buffer(bytes) == OK:
				t = ImageTexture.create_from_image(img)
		elif path.ends_with(".vatpos") or path.ends_with(".vatnrm"):
			var w := bytes.decode_u32(4); var h := bytes.decode_u32(8); var c := bytes.decode_u32(12)
			var fmt := Image.FORMAT_RGBAH if c == 4 else Image.FORMAT_RGH
			img = Image.create_from_data(w, h, false, fmt, bytes.slice(16))
			t = ImageTexture.create_from_image(img)
	if t == null:
		push_warning("DI2Particles: texture %s not exported" % name)
	_tex[name] = t
	return t


## Volume texture (.vol, tools/build_particles.py: "DI2T", channel tag RGBA / L8__, w, h, d, then mip 0 slices;
## the builder swizzles PF_B8G8R8A8 to RGBA). No mips (sampled with filter_linear).
static func texture3d(name: String) -> Texture3D:
	if _tex.has(name):
		return _tex[name]
	var info: Dictionary = db().get("textures", {}).get(name, {})
	var t: ImageTexture3D = null
	if String(info.get("file", "")).ends_with(".vol"):
		var b := FileAccess.get_file_as_bytes(ASSET_DIR + info["file"])
		var w := b.decode_u32(8); var h := b.decode_u32(12); var d := b.decode_u32(16)
		var rgba := b.slice(4, 8).get_string_from_ascii() == "RGBA"
		var bpp := 4 if rgba else 1
		var fmt := Image.FORMAT_RGBA8 if rgba else Image.FORMAT_L8
		var slices: Array[Image] = []
		for z in d:
			slices.append(Image.create_from_data(w, h, false, fmt, b.slice(20 + z * w * h * bpp, 20 + (z + 1) * w * h * bpp)))
		t = ImageTexture3D.new()
		t.create(fmt, w, h, d, false, slices)
	if t == null:
		push_warning("DI2Particles: volume texture %s not exported" % name)
	_tex[name] = t
	return t


## .pmesh (tools/build_particles.py): UE-space cm positions/normals/tangents, UV0, UV1, colours, indices (UE
## winding). Built here in Godot mesh space (UE (x, z, y) * 0.01), one surface per section. The (x, z, y) mirror
## turns UE's front faces into Godot's (clockwise front faces), so the UE index order is kept as is.
static func mesh(name: String) -> ArrayMesh:
	if _mesh.has(name):
		return _mesh[name]
	var info: Dictionary = db().get("meshes", {}).get(name, {})
	if not info.has("file"):
		_mesh[name] = null
		return null
	var b := FileAccess.get_file_as_bytes(ASSET_DIR + info["file"])
	var nv := b.decode_u32(4); var ni := b.decode_u32(8)
	var off := 16
	var pos := b.slice(off, off + nv * 12).to_float32_array(); off += nv * 12
	var nrm := b.slice(off, off + nv * 12).to_float32_array(); off += nv * 12
	var tng := PackedFloat32Array()
	if b.decode_u32(12) & 1:
		tng = b.slice(off, off + nv * 16).to_float32_array(); off += nv * 16
	var uv0 := b.slice(off, off + nv * 8).to_float32_array(); off += nv * 8
	var uv1 := b.slice(off, off + nv * 8).to_float32_array(); off += nv * 8
	var colr := b.slice(off, off + nv * 16).to_float32_array(); off += nv * 16
	var idx := b.slice(off, off + ni * 4).to_int32_array()
	var P := PackedVector3Array(); P.resize(nv)
	var N := PackedVector3Array(); N.resize(nv)
	var TG := PackedFloat32Array(); TG.resize(nv * 4)
	var U0 := PackedVector2Array(); U0.resize(nv)
	var U1 := PackedVector2Array(); U1.resize(nv)
	var C := PackedColorArray(); C.resize(nv)
	for v in nv:
		P[v] = Vector3(pos[v * 3], pos[v * 3 + 2], pos[v * 3 + 1]) * UE_TO_M
		N[v] = Vector3(nrm[v * 3], nrm[v * 3 + 2], nrm[v * 3 + 1])
		if tng.size() > 0:
			TG[v * 4] = tng[v * 4]; TG[v * 4 + 1] = tng[v * 4 + 2]; TG[v * 4 + 2] = tng[v * 4 + 1]; TG[v * 4 + 3] = -tng[v * 4 + 3]
		else:
			TG[v * 4] = 1.0; TG[v * 4 + 3] = 1.0
		U0[v] = Vector2(uv0[v * 2], uv0[v * 2 + 1])
		U1[v] = Vector2(uv1[v * 2], uv1[v * 2 + 1])
		C[v] = Color(colr[v * 4], colr[v * 4 + 1], colr[v * 4 + 2], colr[v * 4 + 3])
	var am := ArrayMesh.new()
	for sec: Dictionary in info.get("sections", [{"first": 0, "count": ni}]):
		var I := PackedInt32Array()
		var first: int = sec["first"]
		for t in int(sec["count"]):
			I.append(idx[first + t])
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = P
		arr[Mesh.ARRAY_NORMAL] = N
		arr[Mesh.ARRAY_TANGENT] = TG
		arr[Mesh.ARRAY_TEX_UV] = U0
		arr[Mesh.ARRAY_TEX_UV2] = U1
		# no ARRAY_COLOR: Godot multiplies vertex colour into the MultiMesh instance colour, while DI2's mesh
		# particle VF keeps the particle colour separate (COLOR1); none of the transcribed PS read the mesh colour.
		arr[Mesh.ARRAY_INDEX] = I
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mesh[name] = am
	return am


## The sprite quad: corners at UV (0,0)..(1,1); the vertex is placed by the instance transform built in
## Emitter.render() (UE ParticleSpriteVertexFactory GetTangents, pivot -0.5).
static func quad() -> ArrayMesh:
	if _quad:
		return _quad
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0.5, 0.5, 0), Vector3(-0.5, 0.5, 0)])
	arr[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1), Vector3(0, 0, 1)])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	_quad = ArrayMesh.new()
	_quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return _quad


static func shader(file: String) -> Shader:
	if not _shader.has(file):
		_shader[file] = load("res://shaders/" + file)
	return _shader[file]


## A ShaderMaterial for one DI2 material instance on one emitter kind (sprite / mesh / gpu sprite), built from the
## decompiled master material (DI2ParticleMaterials) with the MI's flattened parameters.
static func material(mi_name: String, kind: int, required: Dictionary) -> Material:
	var key := "%s|%d|%d|%d" % [mi_name, kind, int(required.get("SubImages_Horizontal", 1)), int(required.get("SubImages_Vertical", 1))]
	if _mat.has(key):
		return _mat[key]
	# particles.json can list an MI with a null entry (not exported, e.g. CE_Explosions_ZombieExplosion_Suicider's):
	# build from an empty dict, i.e. the generic stand-in (UNVERIFIED #63).
	var mi_v = db().get("materials", {}).get(mi_name) if mi_name else null
	var mi: Dictionary = mi_v if mi_v is Dictionary else {}
	var m := DI2ParticleMaterials.build(mi_name, mi, kind, required)
	_mat[key] = m
	return m


# =================================================================================================================
# Emitter instance (FParticleEmitterInstance / FParticleSpriteEmitterInstance / FParticleMeshEmitterInstance)
# =================================================================================================================

class Emitter:
	enum Kind { SPRITE, MESH, GPU, NONE }
	var sys: DI2Particles
	var data: Dictionary
	var index := 0
	var name := ""
	var mods: Array = []
	var lod_d: Dictionary = {}
	var req: Dictionary = {}
	var spawn_mod: Dictionary = {}
	var type_mod: Dictionary = {}
	var spawn_list: Array = []
	var update_list: Array = []
	var spawning_list: Array = []      # UParticleModuleSpawnBase modules in the module list (SpawnPerUnit)
	var event_gen: Dictionary = {}
	var receivers: Array = []
	var kind := Kind.SPRITE
	var local_space := false
	var legacy_spawn := false
	var enabled := true
	var mesh_rotation_active := false
	var lock_axis := "EPAL_NONE"
	var pivot := Vector2(-0.5, -0.5)
	var engine: Dictionary
	# time (Tick_EmitterTimeSetup)
	var emitter_time := 0.0
	var seconds := 0.0
	var loop_count := 0
	var duration := 0.0
	var current_delay := 0.0
	var spawn_fraction := 0.0
	var burst_fired: Array = []
	var location := Vector3.ZERO
	var old_location := Vector3.ZERO
	var e2s := Transform3D.IDENTITY   # EmitterToSimulation (UE)
	var s2w := Transform3D.IDENTITY   # SimulationToWorld (UE)
	var spu_travel := 0.0             # SpawnPerUnit leftover
	var counter := 0
	# particles (SoA; index i is a live particle for i < n)
	var n := 0
	var loc := PackedVector3Array(); var old_loc := PackedVector3Array()
	var base_vel := PackedVector3Array(); var vel := PackedVector3Array()
	var base_size := PackedVector3Array(); var size := PackedVector3Array()
	var rel := PackedFloat32Array(); var oomlt := PackedFloat32Array()
	var rot := PackedFloat32Array(); var rot_rate := PackedFloat32Array(); var base_rot_rate := PackedFloat32Array()
	var col := PackedColorArray(); var base_col := PackedColorArray()
	var flags := PackedInt32Array()
	var dyn := PackedColorArray()
	var subuv := PackedFloat32Array(); var subuv_rt := PackedFloat32Array()
	# FMeshRotationPayloadData: InitRotation (+0xc), Rotation (+0x18), CurContinuousRotation (+0x24), RotationRate
	# (+0x30), RotationRateBase (+0x3c); degrees, Euler (X roll, Y pitch, Z yaw)
	var minit := PackedVector3Array(); var mrot := PackedVector3Array(); var mcont := PackedVector3Array()
	var mrot_rate := PackedVector3Array(); var mrot_rate_base := PackedVector3Array()
	var camoff := PackedVector2Array()
	var accel := PackedVector3Array()
	var coll_left := PackedInt32Array(); var coll_damp := PackedVector3Array(); var coll_damp_rot := PackedVector3Array()
	var coll_delay := PackedFloat32Array()
	var gpu_drag := PackedFloat32Array()
	var gpu_init := PackedColorArray()   # GPU emitters: initial size xy, rotation, rotation rate
	var _rq: PhysicsRayQueryParameters3D  # the collision module's reused ray query
	var rbuf := PackedFloat32Array()       # MultiMesh instance buffer (buffer_upload)
	# GPU emitters' render curves, compiled once (_gpu_compile)
	var g_ready := false
	var g_col := PackedFloat64Array(); var g_col_sc := Vector4.ONE; var g_col_bs := Vector4.ZERO
	var g_misc := PackedFloat64Array(); var g_misc_sc := Vector4.ONE; var g_misc_bs := Vector4.ZERO
	var g_inv0 := 1.0; var g_inv1 := 1.0
	var g_sbs := PackedFloat64Array([0.0, 0.0, 1.0, 1.0])
	# render
	var lights_only := false  # EmitterRenderMode ERM_LightsOnly: UE draws the Light module's lights, no particles
	var mmi: MultiMeshInstance3D
	var mm: MultiMesh
	var mat: Material
	var time_in_w := false
	# render constants (from Required / OrientationAxisLock, set in init_instance)
	enum Align { SQUARE, RECTANGLE, VELOCITY, FACING_CAMERA_POS, OTHER }
	var align := Align.SQUARE
	var lock_mode := 0          # 0 none, 1 ROTATE_X, 2 ROTATE_Y, 3 ROTATE_Z
	var sort_mode := 0          # 0 none, 1 age newest first, 2 age oldest first, 3 distance / view depth

	## render_only: the Rust simulation runs the modules; only the kind / Required / type data for the renderer.
	func _init(owner: DI2Particles, ed: Dictionary, i: int, render_only := false) -> void:
		sys = owner
		data = ed
		index = i
		name = ed.get("name", "None")
		mods = ed.get("modules", [])
		engine = DI2Particles.db().get("engine_modules", {})
		legacy_spawn = ed.get("legacy_spawn", false)
		var lods: Array = ed.get("lods", [])
		var li := clampi(sys.lod, 0, lods.size() - 1)
		lod_d = lods[li] if lods.size() > 0 else {}
		enabled = lod_d.get("enabled", true)
		req = mods[lod_d["required"]] if lod_d.get("required") != null else {}
		spawn_mod = mods[lod_d["spawn"]] if lod_d.get("spawn") != null else {}
		type_mod = mods[lod_d["type"]] if lod_d.get("type") != null else {}
		event_gen = mods[lod_d["events"]] if lod_d.get("events") != null else {}
		local_space = req.get("bUseLocalSpace", false)
		match type_mod.get("m", ""):
			"TypeDataMesh": kind = Kind.MESH
			"TypeDataGpu": kind = Kind.GPU
			"TypeDataRibbon", "TypeDataBeam2", "TypeDataAnimTrail": kind = Kind.NONE
		if ed.get("render", "ERM_Normal") == "ERM_None":
			kind = Kind.NONE
		lights_only = ed.get("render", "ERM_Normal") == "ERM_LightsOnly"
		if render_only:
			return
		for mi in lod_d.get("modules", []):
			var m: Dictionary = mods[mi]
			if not m.get("bEnabled", true):
				continue
			var t: String = m["m"]
			# UParticleModule*_Seeded: the base module with a RandomSeedInfo stream (the Rust simulation runs the
			# stream; this fallback draws from the system RNG: APPROXIMATED)
			var calls: Dictionary = engine.get(t, engine.get(t.trim_suffix("_Seeded"), {}))
			if kind == Kind.GPU:
				continue  # GPU emitters: spawn runs EmitterInfo.SpawnModules, the rest is the GPU simulation
			if calls.get("spawn", false):
				spawn_list.append(m)
			if calls.get("update", false):
				update_list.append(m)
			if t == "SpawnPerUnit":
				spawning_list.append(m)
			if t == "EventReceiverSpawn":
				receivers.append(m)
			if t in ["MeshRotation", "MeshRotationRate"]:
				mesh_rotation_active = true
			if t == "OrientationAxisLock":
				lock_axis = m.get("LockAxisFlags", "EPAL_NONE")
			if t == "PivotOffset":
				var po = m.get("PivotOffset", [0.0, 0.0])
				pivot = Vector2(float(po[0]), float(po[1])) - Vector2(0.5, 0.5)
		if kind == Kind.GPU:
			_gpu_lists()

	## GPU sprite emitters (UParticleModuleTypeDataGpu): spawn-time state comes from EmitterInfo.SpawnModules run on
	## the CPU (FGPUSpriteParticleEmitterInstance::BuildNewParticles); receivers/spawn-per-unit stay CPU side.
	func _gpu_lists() -> void:
		var info: Dictionary = type_mod.get("EmitterInfo", {})
		var names: Array = info.get("SpawnModules", [])
		for mi in lod_d.get("modules", []):
			var m: Dictionary = mods[mi]
			if not m.get("bEnabled", true):
				continue
			if m["m"] == "SpawnPerUnit":
				spawning_list.append(m)
			if m["m"] == "EventReceiverSpawn":
				receivers.append(m)
		# Match by class name order: the cooked list names module objects (e.g. "ParticleModuleLifetime_8").
		for nm in names:
			var cls := String(nm).rsplit("_", true, 1)[0].trim_prefix("ParticleModule")
			for mi in lod_d.get("modules", []):
				var m: Dictionary = mods[mi]
				if m["m"] == cls and m.get("bEnabled", true) and not spawn_list.has(m) and engine.get(cls, {}).get("spawn", false):
					spawn_list.append(m)
					break

	# --- FParticleEmitterInstance::Init / SetupEmitterDuration --------------------------------------------------
	func init_instance() -> void:
		location = sys.comp_loc
		old_location = location
		_update_transforms()
		burst_fired = []
		for b in spawn_mod.get("BurstList", []):
			burst_fired.append(false)
		_setup_duration()
		match req.get("ScreenAlignment", "PSA_Square"):
			"PSA_Square": align = Align.SQUARE
			"PSA_Rectangle": align = Align.RECTANGLE
			"PSA_Velocity": align = Align.VELOCITY
			"PSA_FacingCameraPosition": align = Align.FACING_CAMERA_POS
			_: align = Align.OTHER
		match lock_axis:
			"EPAL_ROTATE_X": lock_mode = 1
			"EPAL_ROTATE_Y": lock_mode = 2
			"EPAL_ROTATE_Z": lock_mode = 3
		match req.get("SortMode", "PSORTMODE_None"):
			"PSORTMODE_Age_NewestFirst": sort_mode = 1
			"PSORTMODE_Age_OldestFirst": sort_mode = 2
			"PSORTMODE_DistanceToView", "PSORTMODE_ViewProjDepth": sort_mode = 3
		if kind != Kind.NONE and enabled and not lights_only:
			_make_renderer()

	## Rust simulation: only the renderer lives here (DI2ParticleSim simulates and fills its MultiMesh buffer).
	func init_renderer() -> void:
		if kind != Kind.NONE and enabled and not lights_only:
			_make_renderer()

	func _setup_duration() -> void:
		current_delay = float(req.get("EmitterDelay", 0.0))
		if req.get("bEmitterDelayUseRange", false):
			current_delay = float(req.get("EmitterDelayLow", 0.0)) + (float(req.get("EmitterDelay", 0.0)) - float(req.get("EmitterDelayLow", 0.0))) * sys.rng.randf()
		var d := float(req.get("EmitterDuration", 1.0))
		if req.get("bEmitterDurationUseRange", false):
			d = float(req.get("EmitterDurationLow", 0.0)) + (d - float(req.get("EmitterDurationLow", 0.0))) * sys.rng.randf()
		duration = d + current_delay
		var loops := int(req.get("EmitterLoops", 0))
		if loop_count == 1 and req.get("bDelayFirstLoopOnly", false) and (loops == 0 or loops > 1):
			duration -= current_delay

	## UpdateTransforms: EmitterToComponent = FRotationTranslationMatrix(EmitterRotation, EmitterOrigin);
	## local space: EmitterToSimulation = EmitterToComponent, SimulationToWorld = ComponentToWorld;
	## world space: EmitterToSimulation = EmitterToComponent * ComponentToWorld, SimulationToWorld = identity.
	func _update_transforms() -> void:
		var er: Array = req.get("EmitterRotation", [0.0, 0.0, 0.0])
		var eo: Array = req.get("EmitterOrigin", [0.0, 0.0, 0.0])
		var e2c := Transform3D(DI2Particles.rotator_basis_ue(float(er[0]), float(er[1]), float(er[2])), Vector3(float(eo[0]), float(eo[1]), float(eo[2])))
		var c2w := Transform3D(sys.comp_basis, sys.comp_loc)
		if local_space:
			e2s = e2c
			s2w = c2w
		else:
			e2s = c2w * e2c
			s2w = Transform3D.IDENTITY

	# --- Tick ---------------------------------------------------------------------------------------------------
	func tick(dt: float) -> void:
		var first := seconds <= 0.0
		# Tick_EmitterTimeSetup
		if sys.just_registered:
			location = sys.comp_loc
			old_location = location
		else:
			old_location = location
			location = sys.comp_loc
		_update_transforms()
		seconds += dt
		var looped := false
		if not req.get("bUseLegacyEmitterTime", true):
			emitter_time += dt
			looped = duration > 0.0 and emitter_time >= duration
		else:
			emitter_time = seconds
			if duration > 1e-4:
				emitter_time = fmod(seconds, duration)
				looped = (seconds - duration * loop_count) >= duration
		var delay := current_delay
		if looped:
			loop_count += 1
			for k in burst_fired.size():
				burst_fired[k] = false
			if not req.get("bUseLegacyEmitterTime", true):
				emitter_time -= duration
			if req.get("bDurationRecalcEachLoop", false) or (req.get("bDelayFirstLoopOnly", false) and loop_count == 1):
				_setup_duration()
		if req.get("bDelayFirstLoopOnly", false) and loop_count > 0:
			delay = 0.0
		emitter_time -= delay
		if not enabled:
			emitter_time += delay
			return
		var P := DI2Particles.prof_fine
		var t0 := Time.get_ticks_usec() if P else 0
		if kind == Kind.MESH and mesh_rotation_active:
			_mesh_pre_tick()
		_kill_particles()
		_reset_particle_parameters(dt)
		if P:
			_prof("reset", t0)
		if kind == Kind.GPU:
			t0 = Time.get_ticks_usec() if P else 0
			_gpu_update(dt)
			if P:
				_prof("gpu_update", t0)
		else:
			for m: Dictionary in update_list:
				t0 = Time.get_ticks_usec() if P else 0
				_update_module(m, dt)
				if P:
					_prof("u_" + str(m["m"]), t0)
		# Tick_SpawnParticles
		t0 = Time.get_ticks_usec() if P else 0
		var loops := int(req.get("EmitterLoops", 0))
		if emitter_time >= 0.0:
			if loops == 0 or loop_count < loops or seconds < duration * loops or first:
				spawn_fraction = _spawn(dt)
		if P:
			_prof("spawn", t0)
			t0 = Time.get_ticks_usec()
		if n > 0:
			_integrate(dt)
		if P:
			_prof("integrate", t0)
		if kind == Kind.MESH and mesh_rotation_active:
			for i in n:
				mcont[i] += mrot_rate[i] * dt
		# FParticleEmitterInstance::Tick (DI2 0x143952490) restores the delay subtracted by the time setup
		emitter_time += delay

	func _prof(key: String, t0: int) -> void:
		DI2Particles.prof[key] = DI2Particles.prof.get(key, 0) + Time.get_ticks_usec() - t0

	## FParticleMeshEmitterInstance::Tick prologue (DI2 0x1439525f0), when a MeshRotation/MeshRotationRate module is
	## active: RotationRate = RotationRateBase; PSA_Velocity / PSA_AwayFromCenter: Rotation = InitRotation +
	## Euler(FindBetweenNormals(+X, velocity resp. location)) + CurContinuousRotation; otherwise (unless
	## FreezeRotation) Rotation = InitRotation + CurContinuousRotation. The epilogue (CurContinuousRotation +=
	## dt * RotationRate) runs after the base tick.
	func _mesh_pre_tick() -> void:
		var align: String = req.get("ScreenAlignment", "PSA_Square")
		for i in n:
			mrot_rate[i] = mrot_rate_base[i]
			if align == "PSA_Velocity" or align == "PSA_AwayFromCenter":
				var d := vel[i] if align == "PSA_Velocity" else loc[i]
				d = d.normalized() if d.length_squared() > 1e-8 else d
				var e := DI2Particles.quat_euler_ue(DI2Particles.find_between_normals_ue(Vector3(1, 0, 0), d))
				mrot[i] = minit[i] + e + mcont[i]
			elif (flags[i] & F_FREEZE_ROTATION) == 0:
				mrot[i] = minit[i] + mcont[i]

	## HasCompleted: loops forever when EmitterLoops == 0; else done once past Duration * Loops with no particles.
	func has_completed() -> bool:
		if not enabled:
			return true
		var loops := int(req.get("EmitterLoops", 0))
		if loops == 0 or seconds < duration * loops:
			return false
		return n <= 0

	# --- particles -----------------------------------------------------------------------------------------------
	func _add_particle() -> int:
		var i := n
		if loc.size() <= i:
			loc.append(Vector3.ZERO); old_loc.append(Vector3.ZERO); base_vel.append(Vector3.ZERO); vel.append(Vector3.ZERO)
			base_size.append(Vector3.ZERO); size.append(Vector3.ZERO); rel.append(0.0); oomlt.append(0.0)
			rot.append(0.0); rot_rate.append(0.0); base_rot_rate.append(0.0); col.append(Color(0, 0, 0, 0))
			base_col.append(Color(0, 0, 0, 0)); flags.append(0); dyn.append(Color(1, 1, 1, 1)); subuv.append(0.0)
			subuv_rt.append(0.0); mrot.append(Vector3.ZERO); mrot_rate.append(Vector3.ZERO); mrot_rate_base.append(Vector3.ZERO)
			minit.append(Vector3.ZERO); mcont.append(Vector3.ZERO)
			camoff.append(Vector2.ZERO); accel.append(Vector3.ZERO); coll_left.append(0); coll_damp.append(Vector3.ONE)
			coll_damp_rot.append(Vector3.ONE); coll_delay.append(0.0); gpu_drag.append(0.0); gpu_init.append(Color(0, 0, 0, 0))
		n += 1
		return i

	func _swap(a: int, b: int) -> void:
		for arr in [loc, old_loc, base_vel, vel, base_size, size, rel, oomlt, rot, rot_rate, base_rot_rate, col, base_col,
				flags, dyn, subuv, subuv_rt, minit, mrot, mcont, mrot_rate, mrot_rate_base, camoff, accel, coll_left, coll_damp,
				coll_damp_rot, coll_delay, gpu_drag, gpu_init]:
			var t = arr[a]
			arr[a] = arr[b]
			arr[b] = t

	func _kill(i: int) -> void:
		n -= 1
		if i != n:
			_swap(i, n)

	## KillParticles: RelativeTime > 1 dies (death events reported), swapped to the end of the list.
	func _kill_particles() -> void:
		var i := n - 1
		while i >= 0:
			if rel[i] > 1.0:
				_report(i, "EPET_Death")
				_kill(i)
			i -= 1

	## ResetParticleParameters (DI2 0x143946520): Velocity = BaseVelocity, Size = |BaseSize|, RotationRate =
	## BaseRotationRate, Color = BaseColor, RelativeTime += OneOverMaxLifetime * dt unless the particle still has
	## the JustSpawned flag and the emitter doesn't use legacy spawning (the flag is left for the integrator to
	## clear); camera offset payload reset to its base.
	func _reset_particle_parameters(dt: float) -> void:
		for i in n:
			vel[i] = base_vel[i]
			size[i] = base_size[i].abs()
			rot_rate[i] = base_rot_rate[i]
			col[i] = base_col[i]
			var js := (flags[i] & F_JUST_SPAWNED) != 0
			if not (js and not legacy_spawn):
				rel[i] += oomlt[i] * dt
			camoff[i].y = camoff[i].x

	## UpdateBoundingBox's integrator (DI2 0x143957390): OldLocation = Location; clear JustSpawned; skip when frozen
	## or (just spawned and not legacy spawning); Location += dt * Velocity unless FreezeTranslation; Rotation +=
	## dt * RotationRate unless FreezeRotation.
	func _integrate(dt: float) -> void:
		for i in n:
			old_loc[i] = loc[i]
			var js := (flags[i] & F_JUST_SPAWNED) != 0
			flags[i] &= ~F_JUST_SPAWNED
			if (flags[i] & F_FREEZE) != 0 or (js and not legacy_spawn):
				continue
			if (flags[i] & F_FREEZE_TRANSLATION) == 0:
				loc[i] += vel[i] * dt
			if (flags[i] & F_FREEZE_ROTATION) == 0:
				rot[i] = fmod(rot[i] + rot_rate[i] * dt, TAU)

	# --- Spawn (FParticleEmitterInstance::Spawn) ------------------------------------------------------------------
	func _spawn(dt: float) -> float:
		var spawn_rate := 0.0
		var burst := 0
		var old_left := spawn_fraction
		# UE 4.27 Spawn(): both start true; only the SpawnBase modules in the module list (SpawnPerUnit) can clear
		# them (GetSpawnAmount / GetBurstCount). The LOD spawn module's own bProcess* flags are not consulted.
		var process_rate := true
		var process_burst := true
		for m: Dictionary in spawning_list:
			var r := _spawn_per_unit(m, dt)
			spawn_rate += maxf(0.0, r[1])
			if not r[2]:
				process_rate = false
			if not m.get("bProcessBurstList", true):
				process_burst = false
		if process_rate:
			var rate_scale := DI2Particles.df(spawn_mod.get("RateScale"), emitter_time, sys.rng, sys.params)
			spawn_rate += DI2Particles.df(spawn_mod.get("Rate"), emitter_time, sys.rng, sys.params) * clampf(rate_scale, 0.0, rate_scale)
		if process_burst:
			burst += _burst_count(dt)
		spawn_rate = maxf(0.0, spawn_rate)
		if spawn_rate > 0.0 or burst > 0:
			var new_left := old_left + dt * spawn_rate
			var number := int(floor(new_left))
			var inc := 1.0 / spawn_rate if spawn_rate > 0.0 else 0.0
			var start := dt + old_left * inc - inc
			new_left -= number
			var init := e2s.origin
			_spawn_particles(number, start, inc, init, Vector3.ZERO)
			_spawn_particles(burst, 0.0, 0.0, init, Vector3.ZERO)
			return new_left
		return spawn_fraction

	## GetCurrentBurstRateOffset: each BurstList entry fires once per loop when EmitterTime >= Time;
	## Count, or CountLow + round(rand * (Count - CountLow)) when CountLow > -1; scaled by BurstScale.
	func _burst_count(_dt: float) -> int:
		var total := 0
		var lst: Array = spawn_mod.get("BurstList", [])
		for k in lst.size():
			if burst_fired[k]:
				continue
			var b: Dictionary = lst[k]
			if emitter_time >= float(b.get("Time", 0.0)):
				var c := int(b.get("Count", 0))
				var lo := int(b.get("CountLow", -1))
				if lo > -1:
					c = lo + roundi(sys.rng.randf() * float(c - lo))
				total += c
				burst_fired[k] = true
		if total > 0 and spawn_mod.has("BurstScale"):
			total = int(ceil(total * DI2Particles.df(spawn_mod["BurstScale"], emitter_time, sys.rng, sys.params)))
		return total

	## UParticleModuleSpawnPerUnit::GetSpawnAmount -> [number, rate, process_spawn_rate].
	func _spawn_per_unit(m: Dictionary, dt: float) -> Array:
		var unit := float(m.get("UnitScalar", 50.0))
		var ppu := DI2Particles.df(m.get("SpawnPerUnit"), emitter_time, sys.rng, sys.params) / unit
		var number := 0
		var rate := 0.0
		var moved := false
		if ppu >= 0.0:
			var tv := location - old_location
			if m.get("bIgnoreMovementAlongX", false): tv.x = 0.0
			if m.get("bIgnoreMovementAlongY", false): tv.y = 0.0
			if m.get("bIgnoreMovementAlongZ", false): tv.z = 0.0
			var dist := tv.length()
			var maxd := float(m.get("MaxFrameDistance", 0.0))
			if (maxd > 0.0 and dist > maxd) or dist > 1048576.0:
				dist = 0.0
				spu_travel = 0.0
			if dist > 0.0:
				if dist > float(m.get("MovementTolerance", 0.1)) * unit:
					moved = true
				var nl := (dist + spu_travel) * ppu
				number = int(floor(nl))
				rate = number / dt
				spu_travel = maxf(0.0, (dist + spu_travel) - number * unit)
		if m.get("bIgnoreSpawnRateWhenMoving", false):
			return [number, rate, not moved]
		return [number, rate, m.get("bProcessSpawnRate", true)]

	## SpawnParticles (UE 4.27): legacy spawning decrements SpawnTime / Interp before a particle, the newer
	## behaviour after it; spawn modules in order; PostSpawn; RelativeTime > 1 after spawn = not spawned.
	func _spawn_particles(count: int, start: float, inc: float, init_loc: Vector3, init_vel: Vector3) -> void:
		count = mini(count, DI2Particles.MAX_PARTICLES_PER_EMITTER - n)
		var st := start
		var interp := 1.0
		var interp_inc := 1.0 / count if (count > 0 and inc > 0.0) else 0.0
		for c in count:
			var i := _add_particle()
			if legacy_spawn:
				st -= inc
				interp -= interp_inc
			_pre_spawn(i, init_loc, init_vel)
			if kind == Kind.GPU:
				_gpu_spawn(i, st)
			else:
				for m: Dictionary in spawn_list:
					_spawn_module(m, i, st)
			_post_spawn(i, interp, st)
			if rel[i] > 1.0:
				_kill(i)
				continue
			_report(i, "EPET_Spawn")
			if not legacy_spawn:
				st -= inc
				interp -= interp_inc

	func _pre_spawn(i: int, init_loc: Vector3, init_vel: Vector3) -> void:
		loc[i] = init_loc; old_loc[i] = init_loc; base_vel[i] = init_vel; vel[i] = init_vel
		base_size[i] = Vector3.ZERO; size[i] = Vector3.ZERO; rel[i] = 0.0; oomlt[i] = 0.0
		rot[i] = 0.0; rot_rate[i] = 0.0; base_rot_rate[i] = 0.0
		col[i] = Color(0, 0, 0, 0); base_col[i] = Color(0, 0, 0, 0); flags[i] = 0
		dyn[i] = Color(1, 1, 1, 1); subuv[i] = 0.0; subuv_rt[i] = 0.0
		mrot[i] = Vector3.ZERO; mrot_rate[i] = Vector3.ZERO; mrot_rate_base[i] = Vector3.ZERO
		minit[i] = Vector3.ZERO; mcont[i] = Vector3.ZERO
		camoff[i] = Vector2.ZERO; accel[i] = Vector3.ZERO; coll_left[i] = 0
		coll_damp[i] = Vector3.ONE; coll_damp_rot[i] = Vector3.ONE; coll_delay[i] = 0.0; gpu_drag[i] = 0.0
		gpu_init[i] = Color(0, 0, 0, 0)

	## PostSpawn: world-space emitters spread this frame's particles back along the emitter's movement
	## (when it moved > 1 cm); OldLocation = Location; Location += Velocity * SpawnTime; counter + JustSpawned flag.
	func _post_spawn(i: int, interp: float, st: float) -> void:
		if not local_space and old_location.distance_squared_to(location) > 1.0:
			loc[i] += interp * (old_location - location)
		old_loc[i] = loc[i]
		loc[i] += vel[i] * st
		flags[i] |= (counter & 0x00FFFFFF) | F_JUST_SPAWNED
		counter += 1

	# --- module Spawn (DI2 exe: UParticleModule*::Spawn, vtable +0x240) ----------------------------------------------
	func _spawn_module(m: Dictionary, i: int, st: float) -> void:
		var r := sys.rng
		var P := sys.params
		var et := emitter_time
		match String(m["m"]).trim_suffix("_Seeded"):
			"Lifetime":
				# 0x14394eea0
				var life := DI2Particles.df(m.get("Lifetime"), et, r, P)
				if oomlt[i] > 0.0:
					oomlt[i] = 1.0 / (1.0 / oomlt[i] + life)
				else:
					oomlt[i] = 1.0 / life if life > 0.0 else 0.0
				if rel[i] <= 1.0:
					rel[i] = oomlt[i] * st
			"Size":
				# 0x14398d3c0: Size += StartSize; BaseSize += StartSize with Required UVFlippingMode signs.
				var s := DI2Particles.dv(m.get("StartSize"), et, r, P)
				size[i] += s
				var f := s
				match req.get("UVFlippingMode", "EParticleUVFlipMode::None"):
					"EParticleUVFlipMode::FlipUV": f = -s
					"EParticleUVFlipMode::FlipUOnly": f.x = -s.x
					"EParticleUVFlipMode::FlipVOnly": f.y = -s.y
					"EParticleUVFlipMode::RandomFlipUV":
						if r.randf() > 0.5: f = Vector3(-s.x, -s.y, -s.z)
					"EParticleUVFlipMode::RandomFlipUOnly":
						if r.randf() > 0.5: f.x = -s.x
					"EParticleUVFlipMode::RandomFlipVOnly":
						if r.randf() > 0.5: f.y = -s.y
					"EParticleUVFlipMode::RandomFlipUVIndependent":
						if r.randf() > 0.5: f.x = -s.x
						if r.randf() > 0.5: f.y = -s.y
				base_size[i] += f
			"SizeMultiplyLife":
				_size_multiply_life(m, i)
			"SizeScale":
				# 0x14398b870: Size = |BaseSize| * SizeScale(RelativeTime)
				size[i] = base_size[i].abs() * DI2Particles.dv(m.get("SizeScale"), rel[i], r, P)
			"Color":
				# 0x143989a20: Color = BaseColor = (StartColor, StartAlpha) at EmitterTime (alpha not clamped)
				var c := DI2Particles.dv(m.get("StartColor"), et, r, P)
				var a := DI2Particles.df(m.get("StartAlpha"), et, r, P)
				col[i] = Color(c.x, c.y, c.z, a); base_col[i] = col[i]
			"ColorOverLife":
				var c := DI2Particles.dv(m.get("ColorOverLife"), rel[i], r, P)
				var a := DI2Particles.df(m.get("AlphaOverLife"), rel[i], r, P)
				col[i] = Color(c.x, c.y, c.z, a); base_col[i] = col[i]
			"ColorScaleOverLife":
				_color_scale(m, i)
			"VelocityCone":
				_velocity_cone(m, i)
			"Velocity":
				var v := DI2Particles.dv(m.get("StartVelocity"), et, r, P)
				var from_origin := (loc[i] - e2s.origin)
				from_origin = from_origin.normalized() if from_origin.length_squared() > 1e-8 else Vector3.ZERO
				if local_space:
					v = sys_inverse_rotate(v) if m.get("bInWorldSpace", false) else e2s.basis * v
				elif not m.get("bInWorldSpace", false):
					v = e2s.basis * v
				v += from_origin * DI2Particles.df(m.get("StartVelocityRadial"), et, r, P)
				vel[i] += v; base_vel[i] += v
			"VelocityInheritParent":
				# 0x14398b9b0: Velocity += Scale * component velocity (into local space when local)
				var pv := sys.part_sys_velocity
				if local_space:
					pv = sys.comp_basis.inverse() * pv
				var sc := DI2Particles.dv(m.get("Scale"), et, r, P)
				var dvv := Vector3(pv.x * sc.x, pv.y * sc.y, pv.z * sc.z)
				vel[i] += dvv; base_vel[i] += dvv
			"VelocityOverLifetime":
				pass  # all DI2 hit uses are disabled or update-only; update handles it
			"AccelerationConstant":
				# 0x14394ea80
				var a := _accel_vec(m, _v3(m.get("Acceleration", [0, 0, 0])))
				vel[i] += a * st; base_vel[i] += a * st
			"Acceleration":
				# 0x14394e750: UsedAcceleration payload; Velocity += a * SpawnTime
				var a := _accel_vec(m, DI2Particles.dv(m.get("Acceleration"), et, r, P))
				accel[i] = a
				vel[i] += a * st; base_vel[i] += a * st
			"Location", "LocationWorldOffset":
				# 0x14398bc60 / 0x14398cdf0
				var o := DI2Particles.dv(m.get("StartLocation"), et, r, P)
				if m["m"] == "LocationWorldOffset":
					loc[i] += sys_inverse_rotate(o) if local_space else o
				else:
					loc[i] += e2s.basis * o
			"LocationPrimitiveSphere":
				_location_sphere(m, i)
			"LocationPrimitiveCylinder":
				_location_cylinder(m, i)
			"Rotation":
				rot[i] += DI2Particles.df(m.get("StartRotation"), et, r, P) * TAU
			"RotationRate":
				var rr := DI2Particles.df(m.get("StartRotationRate"), et, r, P) * TAU
				rot_rate[i] += rr; base_rot_rate[i] += rr
			"MeshRotation":
				# 0x14394f140: InitRotation = StartRotation * 360 (deg; + component rotation if bInheritParent)
				var mr := DI2Particles.dv(m.get("StartRotation"), et, r, P)
				if m.get("bInheritParent", false):
					var e := sys.comp_basis.get_euler()
					mr += Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z)) / 360.0
				minit[i] = mr * 360.0
				mrot[i] += minit[i]
			"MeshRotationRate":
				var rr := DI2Particles.dv(m.get("StartRotationRate"), et, r, P) * 360.0
				mrot_rate[i] += rr; mrot_rate_base[i] += rr
			"SubUV":
				subuv[i] = _subuv_index(m, i)
			"ParameterDynamic":
				_dynamic_params(m, i, true)
			"CameraOffset":
				# 0x1439897d0 (component scale is 1 here)
				var v := DI2Particles.df(m.get("CameraOffset"), rel[i], r, P)
				match m.get("UpdateMethod", "EPCOUM_DirectSet"):
					"EPCOUM_DirectSet": camoff[i] = Vector2(v, v)
					"EPCOUM_Additive": camoff[i].y += v
					_: camoff[i].y *= v
			"Collision":
				coll_damp[i] = DI2Particles.dv(m.get("DampingFactor"), et, r, P)
				coll_damp_rot[i] = DI2Particles.dv(m.get("DampingFactorRotation"), et, r, P)
				coll_left[i] = roundi(DI2Particles.df(m.get("MaxCollisions"), et, r, P))
				coll_delay[i] = DI2Particles.df(m.get("DelayAmount"), et, r, P)
			"LocationEmitter":
				_location_emitter(m, i)

	func _v3(a) -> Vector3:
		return DI2Particles._v3(a)

	func sys_inverse_rotate(v: Vector3) -> Vector3:
		return sys.comp_basis.inverse() * v

	## Acceleration space (0x14394ea80 / 0x14394e750): world-space emitters use it as is; local space rotates it by
	## EmitterToSimulation, or by the inverse component transform when bAlwaysInWorldSpace.
	func _accel_vec(m: Dictionary, a: Vector3) -> Vector3:
		if local_space:
			if m.get("bAlwaysInWorldSpace", false):
				return sys_inverse_rotate(a)
			return e2s.basis * a
		return a

	## 0x14398da10 (UParticleModuleVelocityCone::SpawnEx), as compiled in DI2:
	##   pitch = (float)(int)(Angle * 182.03784) degrees, yaw = (float)(int)(rand * 2pi * 10430) degrees,
	##   DefaultSpawnDirection = FRotationMatrix(pitch, yaw, 0) applied to (0,0,1) [its Z row];
	##   oriented onto Direction (Right = Up x Fwd, Up = Fwd x Right, rows Right/Up/Fwd), then the component
	##   transform (rotation and scale) unless local space or bInWorldSpace; velocity = dir * Velocity.
	func _velocity_cone(m: Dictionary, i: int) -> void:
		var r := sys.rng
		var ang := DI2Particles.df(m.get("Angle"), emitter_time, r, sys.params)
		var spd := DI2Particles.df(m.get("Velocity"), emitter_time, r, sys.params)
		var pitch := float(int(ang * 182.03784))
		var yaw := float(int(r.randf() * 65533.625))
		var dsd := DI2Particles.rotator_basis_ue(pitch, yaw, 0.0).z
		var fwd := _v3(m.get("Direction", [0, 0, 1]))
		fwd = fwd.normalized() if fwd.length_squared() >= 1e-8 else Vector3(0, 0, 1)
		var up := Vector3(0, 0, 1)
		var right := Vector3(1, 0, 0)
		if fwd != up and -fwd != up:
			right = up.cross(fwd)
			up = fwd.cross(right)
		else:
			up = fwd.cross(right)
			right = up.cross(fwd)
		right = right.normalized(); up = up.normalized()
		var sdir := right * dsd.x + up * dsd.y + fwd * dsd.z
		var ws: bool = m.get("bInWorldSpace", false)
		if not local_space and not ws:
			sdir = sys.comp_basis * sdir
		elif local_space and ws:
			sdir = sys_inverse_rotate(sdir)
		var v := sdir * spd
		vel[i] += v; base_vel[i] += v

	## 0x14398c610 + DetermineUnitDirection 0x14396ac70: per axis rand, 2r-1 / r / -r / 0 by the +/- flags;
	## SurfaceOnly normalizes; offset = dir * radius clamped per axis to |normalized dir| * radius (0 if neither flag);
	## + StartLocation; EmitterToSimulation; optional radial velocity (Velocity flag) * VelocityScale.
	func _location_sphere(m: Dictionary, i: int) -> void:
		var r := sys.rng
		var start := DI2Particles.dv(m.get("StartLocation"), emitter_time, r, sys.params)
		var u := Vector3(_axis_rand(m, "X", r.randf()), _axis_rand(m, "Y", r.randf()), _axis_rand(m, "Z", r.randf()))
		var nd := u.normalized() if u.length_squared() > 1e-8 else u
		if m.get("SurfaceOnly", false) and u.length_squared() > 1e-8:
			u = u.normalized()
		var rad := DI2Particles.df(m.get("StartRadius"), emitter_time, r, sys.params)
		var mx := nd.abs() * rad
		var o := u * rad
		var res := Vector3.ZERO
		for k in 3:
			var ax: String = "XYZ"[k]
			if m.get("Positive_" + ax, true) or m.get("Negative_" + ax, true):
				res[k] = clampf(o[k], -mx[k], mx[k])
		res += start
		loc[i] += e2s.basis * res
		if m.get("Velocity", false):
			var v := e2s.basis * ((res - start) * DI2Particles.df(m.get("VelocityScale"), emitter_time, r, sys.params))
			vel[i] += v; base_vel[i] += v

	func _axis_rand(m: Dictionary, ax: String, rv: float) -> float:
		var p: bool = m.get("Positive_" + ax, true)
		var q: bool = m.get("Negative_" + ax, true)
		if p and q:
			return rv * 2.0 - 1.0
		if p:
			return rv
		if q:
			return -rv
		return 0.0

	## UE 4.27 UParticleModuleLocationPrimitiveCylinder (radial in the plane normal to HeightAxis, random height).
	## UNVERIFIED in DI2's exe (2 uses, both in PS_Ranged_* trails).
	func _location_cylinder(m: Dictionary, i: int) -> void:
		var r := sys.rng
		var start := DI2Particles.dv(m.get("StartLocation"), emitter_time, r, sys.params)
		var rad := DI2Particles.df(m.get("StartRadius"), emitter_time, r, sys.params)
		var h := DI2Particles.df(m.get("StartHeight"), emitter_time, r, sys.params)
		var a := r.randf() * TAU
		var d := r.randf() if not m.get("SurfaceOnly", false) else 1.0
		var o := Vector3(cos(a) * rad * d, sin(a) * rad * d, (r.randf() - 0.5) * h)
		match m.get("HeightAxis", "PMLPC_HEIGHTAXIS_Z"):
			"PMLPC_HEIGHTAXIS_X": o = Vector3(o.z, o.x, o.y)
			"PMLPC_HEIGHTAXIS_Y": o = Vector3(o.x, o.z, o.y)
		loc[i] += e2s.basis * (o + start)

	## UE 4.27 UParticleModuleLocationEmitter: spawn at a particle of the named emitter (sequential), inheriting
	## its velocity / rotation. UNVERIFIED in DI2's exe.
	func _location_emitter(m: Dictionary, i: int) -> void:
		for e: Emitter in sys.emitters:
			if e.name == m.get("EmitterName", "") and e.n > 0:
				var k := counter % e.n
				var w := e.s2w * e.loc[k]
				loc[i] = (s2w.affine_inverse() * w) if local_space else w
				if m.get("InheritSourceVelocity", false):
					var sv := e.vel[k] * float(m.get("InheritSourceVelocityScale", 1.0))
					vel[i] += sv; base_vel[i] += sv
				if m.get("bInheritSourceRotation", false):
					rot[i] += e.rot[k] * float(m.get("InheritSourceRotationScale", 1.0))
				return

	func _size_multiply_life(m: Dictionary, i: int) -> void:
		# 0x14398b7e0 / 0x143993060: Size.xyz *= LifeMultiplier(RelativeTime) per MultiplyX/Y/Z
		var s := DI2Particles.dv(m.get("LifeMultiplier"), rel[i], sys.rng, sys.params)
		var z := size[i]
		if m.get("MultiplyX", true): z.x *= s.x
		if m.get("MultiplyY", true): z.y *= s.y
		if m.get("MultiplyZ", true): z.z *= s.z
		size[i] = z

	func _color_scale(m: Dictionary, i: int) -> void:
		# 0x143989b70 / 0x143990720: Color *= (ColorScale, AlphaScale) at RelativeTime (EmitterTime if bEmitterTime)
		var t := emitter_time if m.get("bEmitterTime", false) else rel[i]
		var c := DI2Particles.dv(m.get("ColorScaleOverLife"), t, sys.rng, sys.params)
		var a := DI2Particles.df(m.get("AlphaScaleOverLife"), t, sys.rng, sys.params)
		var k := col[i]
		col[i] = Color(k.r * c.x, k.g * c.y, k.b * c.z, k.a * a)

	## DetermineImageIndex (0x143937d90): Linear / Linear_Blend = SubImageIndex(RelativeTime) (Linear truncates);
	## Random / Random_Blend = rand * SubImages, re-rolled after RandomImageTime of relative time; None = 0.
	func _subuv_index(m: Dictionary, i: int) -> float:
		var interp: String = req.get("InterpolationMethod", "PSUVIM_None")
		var total := int(req.get("SubImages_Horizontal", 1)) * int(req.get("SubImages_Vertical", 1))
		match interp:
			"PSUVIM_Linear", "PSUVIM_Linear_Blend":
				var v := DI2Particles.df(m.get("SubImageIndex"), rel[i], sys.rng, sys.params)
				return floorf(v) if interp == "PSUVIM_Linear" else v
			"PSUVIM_Random", "PSUVIM_Random_Blend":
				var rit := float(req.get("RandomImageTime", 1.0))
				var v := subuv[i]
				if rit == 0.0 or rel[i] - subuv_rt[i] > rit or subuv_rt[i] == 0.0:
					v = sys.rng.randf() * total
					subuv_rt[i] = rel[i]
				return floorf(v) if interp == "PSUVIM_Random" else v
		return 0.0

	## UParticleModuleParameterDynamic (SpawnEx 0x14398d090, Update 0x143991d50): per parameter, ValueMethod
	## UserSet = ParamValue(RelativeTime, or EmitterTime if bUseEmitterTime); VelocityX/Y/Z/Mag multiply by the
	## particle velocity component (with the value only if bScaleVelocityByParamValue); AutoSet is left alone.
	func _dynamic_params(m: Dictionary, i: int, at_spawn: bool) -> void:
		_dynamic_params_c(_dp_compiled(m), i, at_spawn)

	## ParameterDynamic's per-parameter settings, compiled once per module (cached in the module data):
	## [update flags, then per parameter: value method (0 UserSet, 1 VelX, 2 VelY, 3 VelZ, 4 VelMag, 5 AutoSet),
	## use emitter time, evaluate the distribution, the distribution].
	static func _dp_compiled(m: Dictionary) -> Array:
		var c = m.get("_dp")
		if c != null:
			return c
		var out: Array = [int(m.get("UpdateFlags", 15))]
		var ps: Array = m.get("DynamicParams", [])
		for k in mini(ps.size(), 4):
			var p: Dictionary = ps[k]
			var vm: String = p.get("ValueMethod", "EDPV_UserSet")
			var code: int = {"EDPV_UserSet": 0, "EDPV_VelocityX": 1, "EDPV_VelocityY": 2, "EDPV_VelocityZ": 3,
				"EDPV_VelocityMag": 4, "EDPV_AutoSet": 5}.get(vm, 0)
			out.append([code, bool(p.get("bUseEmitterTime", false)),
				vm == "EDPV_UserSet" or bool(p.get("bScaleVelocityByParamValue", false)), p.get("ParamValue")])
		m["_dp"] = out
		return out

	func _dynamic_params_c(c: Array, i: int, at_spawn: bool) -> void:
		var flags_u: int = c[0]
		var cur := dyn[i]
		for k in c.size() - 1:
			if not at_spawn and ((flags_u >> k) & 1) == 0:
				continue
			var p: Array = c[k + 1]
			var vm: int = p[0]
			if vm == 5:
				continue
			var t := emitter_time if p[1] else rel[i]
			var velf := 1.0
			match vm:
				1: velf = vel[i].x
				2: velf = vel[i].y
				3: velf = vel[i].z
				4: velf = vel[i].length()
			var val := 1.0
			if p[2]:
				val = DI2Particles.df(p[3], t, sys.rng, sys.params)
			cur[k] = val * velf
		dyn[i] = cur

	# --- module Update (vtable +0x248) ------------------------------------------------------------------------------
	func _update_module(m: Dictionary, dt: float) -> void:
		var r := sys.rng
		var P := sys.params
		match m["m"]:
			"SizeMultiplyLife":
				var dl = m.get("LifeMultiplier")
				var mx: bool = m.get("MultiplyX", true)
				var my: bool = m.get("MultiplyY", true)
				var mz: bool = m.get("MultiplyZ", true)
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						var sm := DI2Particles.dv(dl, rel[i], r, P)
						var z := size[i]
						if mx: z.x *= sm.x
						if my: z.y *= sm.y
						if mz: z.z *= sm.z
						size[i] = z
			"SizeScale":
				var dss = m.get("SizeScale")
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						size[i] = base_size[i].abs() * DI2Particles.dv(dss, rel[i], r, P)
			"SizeScaleBySpeed":
				# 0x143993520: Size.xy = |BaseSize.xy| * clamp(SpeedScale * |Velocity|, 1, MaxScale); Size.z = |BaseSize.z|
				var ss: Array = m.get("SpeedScale", [1.0, 1.0]); var ms: Array = m.get("MaxScale", [1.0, 1.0])
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						var sp := vel[i].length()
						var fx := minf(maxf(float(ss[0]) * sp, 1.0), float(ms[0]))
						var fy := minf(maxf(float(ss[1]) * sp, 1.0), float(ms[1]))
						var b := base_size[i].abs()
						size[i] = Vector3(b.x * fx, b.y * fy, b.z)
			"ColorOverLife":
				var dc = m.get("ColorOverLife")
				var da = m.get("AlphaOverLife")
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						var c := DI2Particles.dv(dc, rel[i], r, P)
						col[i] = Color(c.x, c.y, c.z, DI2Particles.df(da, rel[i], r, P))
			"ColorScaleOverLife":
				var dc = m.get("ColorScaleOverLife")
				var da = m.get("AlphaScaleOverLife")
				var by_et: bool = m.get("bEmitterTime", false)
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						var t := emitter_time if by_et else rel[i]
						var c := DI2Particles.dv(dc, t, r, P)
						var a := DI2Particles.df(da, t, r, P)
						var k := col[i]
						col[i] = Color(k.r * c.x, k.g * c.y, k.b * c.z, k.a * a)
			"AccelerationDrag":
				# 0x1439547f0: c = DragCoefficientRaw(RelativeTime) every frame; d = Velocity * -c * dt added to
				# Velocity and BaseVelocity.
				var dd = m.get("DragCoefficientRaw")
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						var c := DI2Particles.df(dd, rel[i], r, P)
						var d := vel[i] * (-c * dt)
						vel[i] += d; base_vel[i] += d
			"AccelerationConstant":
				# 0x143953f40
				var a := _accel_vec(m, _v3(m.get("Acceleration", [0, 0, 0])))
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						vel[i] += a * dt; base_vel[i] += a * dt
			"Acceleration":
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						vel[i] += accel[i] * dt; base_vel[i] += accel[i] * dt
			"SubUV":
				var interp: String = req.get("InterpolationMethod", "PSUVIM_None")
				if interp == "PSUVIM_None":
					return
				if interp in ["PSUVIM_Random", "PSUVIM_Random_Blend"] and int(req.get("RandomImageChanges", 0)) == 0:
					return
				for i in n:
					if (flags[i] & F_FREEZE) == 0 and rel[i] <= 1.0:
						subuv[i] = _subuv_index(m, i)
			"ParameterDynamic":
				var dpc := _dp_compiled(m)
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						_dynamic_params_c(dpc, i, false)
			"CameraOffset":
				# 0x14398ecf0
				if m.get("bSpawnTimeOnly", false):
					return
				var dco = m.get("CameraOffset")
				var um: String = m.get("UpdateMethod", "EPCOUM_DirectSet")
				for i in n:
					if (flags[i] & F_FREEZE) == 0:
						var v := DI2Particles.df(dco, rel[i], r, P)
						match um:
							"EPCOUM_Additive": v += camoff[i].y
							"EPCOUM_Multiplicative": v *= camoff[i].y
						camoff[i].y = v
			"VelocityOverLifetime":
				# UE 4.27: Absolute sets Velocity = VelOverLife(t), else scales it. UNVERIFIED in DI2's exe.
				for i in n:
					var v := DI2Particles.dv(m.get("VelOverLife"), rel[i], r, P)
					if m.get("Absolute", false):
						if not local_space and not m.get("bInWorldSpace", false):
							v = sys.comp_basis * v
						vel[i] = v
					else:
						vel[i] = Vector3(vel[i].x * v.x, vel[i].y * v.y, vel[i].z * v.z)
			"Collision":
				_collision(m, dt)

	## UParticleModuleCollision::Update (UE 4.27; DI2 0x14398edd0 not transcribed line by line, UNVERIFIED):
	## trace OldLocation -> Location + Velocity*dt (+ Direction * Size / DirScalar) against the world
	## (WorldStatic/WorldDynamic, here Util.WORLD); a hit decrements MaxCollisions; while some remain the base
	## velocity reflects (MirrorByVector * DampingFactor) and the particle continues from the hit, else the
	## CollisionCompletionOption applies (Kill / Freeze*). Collision events are reported either way.
	func _collision(m: Dictionary, dt: float) -> void:
		var maxd := float(m.get("MaxCollisionDistance", 1000.0))
		if maxd < 1048576.0 and sys.camera_ue.distance_to(sys.comp_loc) > maxd:
			return
		var space := sys.get_world_3d().direct_space_state if sys.is_inside_tree() else null
		if space == null:
			return
		var dirscalar := float(m.get("DirScalar", 3.5))
		var opt: String = m.get("CollisionCompletionOption", "EPCC_Kill")
		if _rq == null:
			_rq = PhysicsRayQueryParameters3D.new()
			_rq.collision_mask = Util.WORLD
		var kill: Array = []
		for i in n:
			if (flags[i] & (F_IGNORE_COLLISIONS | F_FREEZE)) != 0:
				continue
			if coll_delay[i] > rel[i]:
				continue
			var l := loc[i] + vel[i] * dt
			var ol := old_loc[i]
			if local_space:
				l = s2w * l
				ol = s2w * ol
			var dirv := (l - ol)
			var dir := dirv.normalized() if dirv.length_squared() > 1e-8 else Vector3.ZERO
			var sz := size[i]
			var end := l + Vector3(dir.x * sz.x, dir.y * sz.y, dir.z * sz.z) / dirscalar
			if ol.is_equal_approx(end):
				continue
			_rq.from = DI2Particles.u2g(ol)
			_rq.to = DI2Particles.u2g(end)
			var hit := space.intersect_ray(_rq)
			if hit.is_empty():
				continue
			var hp := DI2Particles.g2u(hit["position"])
			var hn := DI2Particles.g2u_dir(hit["normal"])
			var tlen := (end - ol).length()
			var htime := (hp - ol).length() / tlen if tlen > 0.0 else 0.0
			coll_left[i] -= 1
			var world_vel := vel[i] if not local_space else s2w.basis * vel[i]
			_report_collision(hp, world_vel, dir, hn)
			if coll_left[i] > 0:
				var bv := base_vel[i] if not local_space else s2w.basis * base_vel[i]
				bv = (bv - 2.0 * bv.dot(hn) * hn) * coll_damp[i]
				base_vel[i] = bv if not local_space else s2w.basis.inverse() * bv
				base_rot_rate[i] *= coll_damp_rot[i].x
				var nv := (dir - 2.0 * dir.dot(hn) * hn) * dirv.length() * coll_damp[i]
				vel[i] = Vector3.ZERO
				var add := nv * (1.0 - htime)
				loc[i] += add if not local_space else s2w.basis.inverse() * add
			else:
				match opt:
					"EPCC_Kill": kill.append(i)
					"EPCC_Freeze": flags[i] |= F_FREEZE
					"EPCC_HaltCollisions": flags[i] |= F_IGNORE_COLLISIONS
					"EPCC_FreezeTranslation": flags[i] |= F_FREEZE_TRANSLATION
					"EPCC_FreezeRotation": flags[i] |= F_FREEZE_ROTATION
					"EPCC_FreezeMovement": flags[i] |= F_FREEZE_ROTATION | F_FREEZE_TRANSLATION
		kill.sort()
		kill.reverse()
		for i in kill:
			_kill(i)

	# --- events -------------------------------------------------------------------------------------------------
	func _report(i: int, typ: String) -> void:
		if event_gen.is_empty():
			return
		for ev: Dictionary in event_gen.get("Events", []):
			if ev.get("Type", "EPET_Spawn") != typ:
				continue
			var w := s2w * loc[i] if local_space else loc[i]
			var v := s2w.basis * vel[i] if local_space else vel[i]
			sys.report_event(typ, ev.get("CustomName", "None"), w, v, v.normalized(), Vector3.ZERO)

	func _report_collision(hit_loc: Vector3, v: Vector3, dir: Vector3, normal: Vector3) -> void:
		if event_gen.is_empty():
			return
		for ev: Dictionary in event_gen.get("Events", []):
			if ev.get("Type", "") == "EPET_Collision":
				sys.report_event("EPET_Collision", ev.get("CustomName", "None"), hit_loc, v, dir, normal)

	## UParticleModuleEventReceiverSpawn::ProcessParticleEvent (UE 4.27): matching type + name -> ForceSpawn
	## SpawnCount particles at the event (or the PSC) location, velocity = event velocity * InheritVelocityScale.
	func receive_event(ev: Array, dt: float) -> void:
		if not enabled:
			return
		for m: Dictionary in receivers:
			if m.get("EventGeneratorType", "") != ev[0] or m.get("EventName", "None") != ev[1]:
				continue
			var at: Vector3 = sys.comp_loc if m.get("bUsePSysLocation", false) else ev[2]
			var v := Vector3.ZERO
			if m.get("bInheritVelocity", false):
				var s := DI2Particles.dv(m.get("InheritVelocityScale"), emitter_time, sys.rng, sys.params)
				v = Vector3(ev[3].x * s.x, ev[3].y * s.y, ev[3].z * s.z)
			if local_space:
				at = s2w.affine_inverse() * at
				v = s2w.basis.inverse() * v
			var count := roundi(DI2Particles.df(m.get("SpawnCount"), emitter_time, sys.rng, sys.params))
			_spawn_particles(count, 0.0, 0.0, at, v)

	# --- GPU sprite emitters -------------------------------------------------------------------------------------
	## Spawn: the cooked EmitterInfo.SpawnModules on the CPU (FGPUSpriteParticleEmitterInstance::BuildNewParticles),
	## plus the per-particle drag coefficient sample (EmitterInfo.DragCoefficient).
	func _gpu_spawn(i: int, st: float) -> void:
		for m: Dictionary in spawn_list:
			_spawn_module(m, i, st)
		var info: Dictionary = type_mod.get("EmitterInfo", {})
		gpu_drag[i] = DI2Particles.df(info.get("DragCoefficient"), emitter_time, sys.rng, sys.params)
		var bs := base_size[i]
		gpu_init[i] = Color(bs.x, bs.y, rot[i], rot_rate[i])

	## GPU simulation step (UE 4.27 ParticleSimulationShader as compiled into FGPUSpriteResourceData): constant
	## acceleration, drag = sample * DragCoefficientScale + Bias, Euler integration. UNVERIFIED: DI2's
	## FParticleSimulationPS is not decompiled (recon/PARTICLES.md 6).
	func _gpu_update(dt: float) -> void:
		var rd: Dictionary = type_mod.get("ResourceData", {})
		var acc := DI2Particles._v3(rd.get("ConstantAcceleration", [0, 0, 0]))
		var ds := float(rd.get("DragCoefficientScale", 0.0)); var db := float(rd.get("DragCoefficientBias", 0.0))
		for i in n:
			var drag := gpu_drag[i] * ds + db
			base_vel[i] += acc * dt
			base_vel[i] -= base_vel[i] * drag * dt
			vel[i] = base_vel[i]

	# --- rendering ------------------------------------------------------------------------------------------------
	func _make_renderer() -> void:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		var mi_name = req.get("Material")
		if kind == Kind.MESH:
			var mname = type_mod.get("Mesh")
			var am := DI2Particles.mesh(mname) if mname else null
			if am == null:
				kind = Kind.NONE
				return
			mm.mesh = am
			if not type_mod.get("bOverrideMaterial", false):
				var secs: Array = DI2Particles.db().get("meshes", {}).get(mname, {}).get("sections", [])
				if secs.size() > 0 and secs[0].get("material"):
					mi_name = secs[0]["material"]
		else:
			mm.mesh = DI2Particles.quad()
		mat = DI2Particles.material(mi_name, kind, req)
		time_in_w = mat.has_meta("time_in_w")
		mmi = MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.top_level = true
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = AABB(Vector3(-1e4, -1e4, -1e4), Vector3(2e4, 2e4, 2e4))
		mmi.name = "%02d_%s" % [index, name]
		sys.add_child(mmi)
		mmi.global_transform = Transform3D.IDENTITY

	func render(cam: Camera3D) -> void:
		if mm == null:
			return
		if mm.instance_count < n:
			mm.instance_count = maxi(n, mm.instance_count * 2)
		mm.visible_instance_count = n
		if n == 0:
			return
		var view_cam := cam.global_transform if cam else Transform3D.IDENTITY
		var cam_pos_ue := DI2Particles.g2u(view_cam.origin)
		var order: Array = _sort_order(cam_pos_ue) if sort_mode != 0 else []
		var cam_right := DI2Particles.g2u_dir(view_cam.basis.x)
		var cam_up := -DI2Particles.g2u_dir(view_cam.basis.y)
		var is_mesh := kind == Kind.MESH
		var is_gpu := kind == Kind.GPU
		var use_buf := DI2Particles.buffer_upload
		if use_buf and rbuf.size() != mm.instance_count * 20:
			rbuf.resize(mm.instance_count * 20)
		for k in n:
			var i: int = order[k] if sort_mode != 0 else k
			var wl := s2w * loc[i] if local_space else loc[i]
			var co := Vector3.ZERO
			if camoff[i].y != 0.0:
				co = _camera_offset(camoff[i].y, cam_pos_ue - wl)
			var custom := dyn[i]
			if time_in_w:
				custom.a = rel[i]
			var xf: Transform3D
			if is_mesh:
				xf = _mesh_transform(i, wl + co, cam_pos_ue)
			else:
				xf = _sprite_transform(i, wl + co, cam_pos_ue, cam_right, cam_up)
			var c := col[i]
			if is_gpu:
				c = _gpu_color(i)
			if use_buf:
				# MultiMesh TRANSFORM_3D + colour + custom layout: basis rows with origin, rgba, custom
				var o := k * 20
				var bx := xf.basis.x; var by := xf.basis.y; var bz := xf.basis.z; var org := xf.origin
				rbuf[o] = bx.x; rbuf[o + 1] = by.x; rbuf[o + 2] = bz.x; rbuf[o + 3] = org.x
				rbuf[o + 4] = bx.y; rbuf[o + 5] = by.y; rbuf[o + 6] = bz.y; rbuf[o + 7] = org.y
				rbuf[o + 8] = bx.z; rbuf[o + 9] = by.z; rbuf[o + 10] = bz.z; rbuf[o + 11] = org.z
				rbuf[o + 12] = c.r; rbuf[o + 13] = c.g; rbuf[o + 14] = c.b; rbuf[o + 15] = c.a
				rbuf[o + 16] = custom.r; rbuf[o + 17] = custom.g; rbuf[o + 18] = custom.b; rbuf[o + 19] = custom.a
			else:
				mm.set_instance_transform(k, xf)
				mm.set_instance_color(k, c)
				mm.set_instance_custom_data(k, custom)
		if use_buf:
			RenderingServer.multimesh_set_buffer(mm.get_rid(), rbuf)

	## Cascade SortMode: Age_NewestFirst / OldestFirst / DistanceToView / ViewProjDepth (back to front).
	func _sort_order(cam_ue: Vector3) -> Array:
		var order := range(n)
		match sort_mode:
			1:
				order.sort_custom(func(a, b): return rel[a] < rel[b])
			2:
				order.sort_custom(func(a, b): return rel[a] > rel[b])
			3:
				var w := func(i): return (s2w * loc[i] if local_space else loc[i]).distance_squared_to(cam_ue)
				order.sort_custom(func(a, b): return w.call(a) > w.call(b))
		return order

	## GetCameraOffset (UE 4.27): push toward the camera by the offset, or far behind it when the offset would cross.
	func _camera_offset(off: float, to_cam: Vector3) -> Vector3:
		var lsq := to_cam.length_squared()
		var d := to_cam.normalized() if lsq > 0.0 else Vector3.ZERO
		if lsq > off * off:
			return d * off
		return d * off * 1048576.0

	## Sprite placement = UE ParticleSpriteVertexFactory GetTangents (decompiled DI2 VS 1249 / 2925 confirm it):
	## Right/Up = camera right / -camera up; PSA_Velocity: Right = normalize(CameraDir x MoveDir), Up = -MoveDir;
	## PSA_FacingCameraPosition: Right = normalize(CameraDir x Z), Up = CameraDir x Right; ROTATE_X/Y/Z axis lock:
	## Right = the locked component axis, Up = -normalize(Right x CameraDir), rotation bias pi/2 for ROTATE_Z.
	## Rotated by the particle rotation; corners at (uv + pivot) * size. PSA_Square uses Size.x for both axes.
	## The instance basis z carries (SubImageIndex, RelativeTime, 0) for the shader (the quad has z = 0).
	func _sprite_transform(i: int, wl: Vector3, cam_ue: Vector3, cam_right: Vector3, cam_up: Vector3) -> Transform3D:
		var cam_dir := (cam_ue - wl)
		cam_dir = cam_dir.normalized() if cam_dir.length_squared() > 1e-8 else Vector3(1, 0, 0)
		var right := cam_right
		var up := cam_up
		var rbias := 0.0
		if align == Align.VELOCITY:
			var md := (loc[i] - old_loc[i])
			if local_space:
				md = s2w.basis * md
			if md.length_squared() < 1e-12:
				md = s2w.basis * vel[i] if local_space else vel[i]
			md = md.normalized() if md.length_squared() > 1e-12 else Vector3(0, 0, 1)
			var rr := cam_dir.cross(md)
			right = rr.normalized() if rr.length_squared() > 1e-12 else right
			up = -md
		elif lock_mode != 0:
			var cb := sys.comp_basis
			right = cb.x if lock_mode == 1 else (cb.y if lock_mode == 2 else cb.z)
			var u2 := right.cross(cam_dir)
			up = -(u2.normalized() if u2.length_squared() > 1e-12 else u2)
			if lock_mode == 3:
				rbias = PI * 0.5
		elif align == Align.FACING_CAMERA_POS:
			var r2 := cam_dir.cross(Vector3(0, 0, 1))
			right = r2.normalized() if r2.length_squared() > 1e-12 else right
			up = cam_dir.cross(right)
		var ang := rot[i] + rbias
		var sr := sin(ang); var cr := cos(ang)
		var R := sr * up + cr * right
		var U := cr * up - sr * right
		var sz := Vector2(size[i].x, size[i].y)
		var gm := Vector4.ZERO
		if kind == Kind.GPU:
			gm = _gpu_misc(i)
			sz = _gpu_size(i, gm)
		var bs := base_size[i]
		var sx := absf(sz.x) * (-1.0 if bs.x < 0.0 else 1.0)
		var sy := absf(sz.y) * (-1.0 if bs.y < 0.0 else 1.0)
		if align == Align.SQUARE or align == Align.FACING_CAMERA_POS:
			sy = absf(sz.x) * (-1.0 if bs.y < 0.0 else 1.0)
		# quad corners are at +-0.5: shift by (pivot + 0.5) so UE's (uv + PivotOffset) placement holds
		var origin := wl + R * sx * (pivot.x + 0.5) + U * sy * (pivot.y + 0.5)
		var gx := DI2Particles.u2g_dir(R) * sx * DI2Particles.UE_TO_M
		var gy := DI2Particles.u2g_dir(U) * sy * DI2Particles.UE_TO_M  # quad +y = uv v = UE sprite "up" (screen down)
		var extra := Vector3(subuv[i] if kind != Kind.GPU else gm.z, rel[i], 0.0)
		return Transform3D(Basis(gx, gy, extra), DI2Particles.u2g(origin))

	## Mesh particle transform = DI2's FDynamicMeshEmitterData::CalculateParticleTransform (0x143965a10, via
	## GetParticleTransform 0x14397e2f0) for the non-TypeSpecific, non-camera-facing, unlocked case DI2's hit
	## emitters use: Scale(Size * component scale) * FRotationMatrix(MakeFromEuler(r, r, r) + MakeFromEuler(payload
	## Rotation)) * Translate(Location + CameraOffset), r = sprite rotation in degrees; local space then
	## LocalToWorld. (Velocity alignment lives in the payload, see _mesh_pre_tick.) TypeDataMesh camera facing /
	## AxisLockOption X..-Z / PSA_TypeSpecific MeshAlignment are UNVERIFIED here (not used by the hit set).
	func _mesh_transform(i: int, wl: Vector3, _cam_ue: Vector3) -> Transform3D:
		var r := rad_to_deg(rot[i])
		var m := mrot[i]
		var b := DI2Particles.rotator_basis_ue(r + m.y, r + m.z, r + m.x)
		if local_space:
			b = s2w.basis * b
		var s := size[i]
		b = b * Basis.from_scale(Vector3(s.x, s.y, s.z))
		return Transform3D(DI2Particles.u2g_basis(b), DI2Particles.u2g(wl))

	# GPU sprite render-time curves (DI2 GPU sprite VS 2971 / 8203): color = ColorCurve(t) * ColorScale + ColorBias,
	# size = InitialSize * MiscCurve.xy(t) * clamp(SpeedScale * |v|, 1, MaxScale), subimage = MiscCurve.z,
	# rotation = (InitialRotation + RotationRateScale * rate * t) * 2pi.
	## The GPU curves compiled once per emitter (_gpu_compile): samples as doubles (RGBA per sample), scale, bias.
	func _gpu_compile() -> void:
		var rd: Dictionary = type_mod.get("ResourceData", {})
		var info: Dictionary = type_mod.get("EmitterInfo", {})
		g_col = _gpu_samples(rd.get("QuantizedColorSamples", []))
		g_col_sc = _gpu_v4(rd.get("ColorScale"), Vector4.ONE)
		g_col_bs = _gpu_v4(rd.get("ColorBias"), Vector4.ZERO)
		g_misc = _gpu_samples(rd.get("QuantizedMiscSamples", []))
		g_misc_sc = _gpu_v4(rd.get("MiscScale"), Vector4.ONE)
		g_misc_bs = _gpu_v4(rd.get("MiscBias"), Vector4.ZERO)
		var inv: Array = info.get("InvMaxSize", [1.0, 1.0])
		g_inv0 = float(inv[0]); g_inv1 = float(inv[1])
		var sbs: Dictionary = rd.get("SizeBySpeed", {"X": 0, "Y": 0, "Z": 1, "W": 1})
		g_sbs = PackedFloat64Array([float(sbs["X"]), float(sbs["Y"]), float(sbs["Z"]), float(sbs["W"])])
		g_ready = true

	static func _gpu_samples(samples: Array) -> PackedFloat64Array:
		var out := PackedFloat64Array()
		for smp: Dictionary in samples:
			out.append(float(smp["R"])); out.append(float(smp["G"])); out.append(float(smp["B"])); out.append(float(smp["A"]))
		return out

	static func _gpu_v4(d, dflt: Vector4) -> Vector4:
		return Vector4(d["X"], d["Y"], d["Z"], d["W"]) if d is Dictionary else dflt

	## GPU curve sample (DI2 GPU sprite VS): lerp of the quantized samples at t / 255, * scale + bias.
	func _gpu_curve_c(sm: PackedFloat64Array, sc: Vector4, bs: Vector4, t: float) -> Vector4:
		var cnt := sm.size() / 4
		if cnt == 0:
			return Vector4.ZERO
		var x := clampf(t, 0.0, 1.0) * (cnt - 1)
		var a := int(floor(x)); var bi := mini(a + 1, cnt - 1); var f := x - a
		var o0 := a * 4; var o1 := bi * 4
		var v := Vector4(lerpf(sm[o0], sm[o1], f), lerpf(sm[o0 + 1], sm[o1 + 1], f), lerpf(sm[o0 + 2], sm[o1 + 2], f), lerpf(sm[o0 + 3], sm[o1 + 3], f)) / 255.0
		return v * sc + bs

	func _gpu_color(i: int) -> Color:
		if not g_ready:
			_gpu_compile()
		var c := _gpu_curve_c(g_col, g_col_sc, g_col_bs, rel[i])
		return Color(c.x, c.y, c.z, c.w)

	func _gpu_misc(i: int) -> Vector4:
		if not g_ready:
			_gpu_compile()
		return _gpu_curve_c(g_misc, g_misc_sc, g_misc_bs, rel[i])

	func _gpu_size(i: int, m: Vector4) -> Vector2:
		var sp := vel[i].length()
		var fx := minf(maxf(g_sbs[0] * sp, 1.0), g_sbs[2])
		var fy := minf(maxf(g_sbs[1] * sp, 1.0), g_sbs[3])
		var init := Vector2(absf(gpu_init[i].r) * g_inv0, absf(gpu_init[i].g) * g_inv1)
		return Vector2(init.x * m.x * fx, init.y * m.y * fy)
