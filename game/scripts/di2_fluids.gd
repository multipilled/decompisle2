class_name DI2Fluids
extends Node3D
## DI2's gameplay fluids (recon/RE_FLUIDS.md, data game/data/fluids.json from tools/build_fluids.py): the blood a hit
## CE throws (UCosmeticEffect_FluidParticle) flies as droplets (UFluidSimDropletManager) and lands as puddles
## (AFluidInstanceActor under AFluidManager: merge, add, spread, evaporate), drawn as M_FluidDecal decals.
##
## Droplets (0x141471940 / 0x141474370): every MinUpdateInterval (0.1 s) a droplet steps its ballistic path
## (pos += v dt + g dt^2 / 2, v += g dt, g = DefaultGravityZ -980 cm/s^2) and traces old -> new against the world
## (CollidesWith WorldStatic / WorldDynamic: characters don't stop it); a hit spawns the payload, Lifetime (5 s) ends it.
## DI2 traces asynchronously (the result lands next tick); the trace here is immediate.
## Payload (0x141465580 -> request 0x141456ea0): radius = the CE's Amount (cm). The nearest same-type puddle within
## MergeMaxRange whose reach accepts the point takes it (0x14145d810 / 0x141474c00): reach = R * k, k =
## Curve_FluidConsumption(R) when the type uses the curve, else SpawnDistanceRequirementWhenSkippingConsumption for
## R > MinimumPuddleSizeForSkippingConsumption (1 otherwise); accepted when R * k > R or the distance <= R * k.
## Adding (0x14142c790): R = sqrt(R^2 + r^2), capped (the cap's source, taken as MaxRadius, isn't traced; DI2 flows the
## overflow away, not ported); it restores the opacity and restarts the idle timer. Otherwise a new puddle
## (0x14143e8a0): R = max(r, MinRadius), target opacity = rand(MinOpacity, MaxOpacity), visual radius from
## StartingDecalRadiusMultiplierIfActorIsImpact * R * VisualRadiusMultiplier.
## Tick (0x141440f30): visual radius FInterpTo (VisualRadiusMultiplier * R, VisualRadiusInterpolationSpeed); restoring
## opacity FInterpTo (target, OpacityRestorationInterpolationSpeed); TimeIdleBeforeAutoEvaporate after the last change
## evaporation starts (0x1414464c0): rate = sqrt(EvaporationAreaPerSec / pi) * target opacity / R, opacity -= rate dt,
## gone at 0. The decals (0x14143aef0) are scaled so their DecalSize.Y / Z extents equal the visual radius, depth
## DecalSize.X, opacity -> M_FluidDecal; the decal's fade in (FadeInDelay / FadeInDuration) is taken from the type.
## Rendering (recon/RE_FLUIDS.md §5-6): DI2 draws M_FluidDecal coverage into a fluid buffer that FFluidComposePS then
## multiplies into the GBuffer (absorption, gloss). Here every puddle's coverage (di2_fluid_coverage.gdshader) is drawn
## into a top-down fluid map (a SubViewport over map_area, re-rendered only when a puddle changes), published as the
## global shader uniforms di2_fluid_*; world materials compose it with game/shaders/di2_fluid.gdshaderinc. Characters
## don't include it, as DI2's characters don't receive these decals. Only near-flat surfaces can show it (a top-down
## map); wall puddles are simulated but not drawn (UNVERIFIED #54).

const DATA_PATH := "res://data/fluids.json"
const CM := 0.01
const MAP_TEXEL := 0.025        # metres per fluid-map texel (recreation resolution; DI2's fluid buffer is per pixel)
const MAX_DROPLETS := 10000     # UFluidSimDropletManager's per-type cap (0x14146fd00)
const MAX_PUDDLES := 256        # DI2 pools its instances; the pool size isn't traced (recreation cap)

static var _db: Dictionary = {}
## The world x / z rectangle the fluid map covers (a scene may set it before the first fluid).
static var map_area := Rect2(-25.6, -25.6, 51.2, 51.2)
## World heights the map's height channel spans.
static var map_heights := Vector2(-10.0, 30.0)

var now := 0.0
var drops: Array[Dictionary] = []
var puddles: Array[Dictionary] = []
## In-flight fluid-sim projectiles (AFluidSimProjectile, recon/RE_FLUIDS.md §9.2).
var projs: Array[Dictionary] = []
var _vp: SubViewport
var _root: Node2D
var _cov_mat: ShaderMaterial
var _dirty := false


func _ready() -> void:
	_setup_map()


## The fluid map and its global shader uniforms (project.godot [shader_globals] di2_fluid_*).
func _setup_map() -> void:
	if not ProjectSettings.has_setting("shader_globals/di2_fluid_map"):
		push_warning("DI2Fluids: project.godot has no di2_fluid_* shader globals; puddles are simulated but not drawn")
		return
	_vp = SubViewport.new()
	_vp.size = Vector2i(roundi(map_area.size.x / MAP_TEXEL), roundi(map_area.size.y / MAP_TEXEL))
	_vp.transparent_bg = true
	_vp.disable_3d = true
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_vp)
	_root = Node2D.new()
	_vp.add_child(_root)
	_cov_mat = ShaderMaterial.new()
	_cov_mat.shader = load("res://shaders/di2_fluid_coverage.gdshader")
	var comp: Dictionary = db().get("compose", {})
	var col: Array = comp.get("colors", {}).get("Blood", [0.88, 0.195553, 0.146666, 0.02])
	var fp: Dictionary = comp.get("fluid_params", {})
	var depth := float(db()["types"]["Blood"]["DecalSize"]["X"]) * CM
	RenderingServer.global_shader_parameter_set(&"di2_fluid_map", _vp.get_texture())
	RenderingServer.global_shader_parameter_set(&"di2_fluid_area", Vector4(map_area.position.x, map_area.position.y, map_area.size.x, map_area.size.y))
	RenderingServer.global_shader_parameter_set(&"di2_fluid_color", Vector4(col[0], col[1], col[2], col[3]))
	RenderingServer.global_shader_parameter_set(&"di2_fluid_params", Vector4(float(fp.get("FluidDensity", 10.0)), float(fp.get("FluidRoughness", 0.08)), float(comp.get("specular", 0.35)), depth))
	RenderingServer.global_shader_parameter_set(&"di2_fluid_height", map_heights)
	# FFluidComposePS's other colours: Water from FPostProcessSettings' defaults, Fuel / FuelEdge from every level's
	# BP_BasicTimeOfDay post process (compose.level_colors; recon/TEST_MAP.md).
	for pair in [["di2_fluid_fuel", "Fuel"], ["di2_fluid_fuel_edge", "FuelEdge"], ["di2_fluid_water", "Water"]]:
		var c: Array = comp.get("level_colors", {}).get(pair[1], comp.get("colors", {}).get(pair[1], [1.0, 1.0, 1.0, 0.0]))
		RenderingServer.global_shader_parameter_set(StringName(pair[0]), Vector4(c[0], c[1], c[2], c[3]))


static func db() -> Dictionary:
	if _db.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f == null:
			push_error("DI2Fluids: %s missing (run tools/build_fluids.py)" % DATA_PATH)
			return _db
		_db = JSON.parse_string(f.get_as_text())
	return _db


## The scene's fluid manager (one per current scene, created on demand).
static func of(node: Node) -> DI2Fluids:
	if node == null or not node.is_inside_tree():
		return null
	var scene: Node = node.get_tree().current_scene
	if scene == null:
		return null
	var m := scene.get_node_or_null("DI2Fluids") as DI2Fluids
	if m == null:
		m = DI2Fluids.new()
		m.name = "DI2Fluids"
		scene.add_child(m)
	return m


## A CE's fluid entries (and its nested CEs') at `pos`, oriented by the CE's spawn basis (+X = the effect forward;
## UCosmeticEffect_FluidParticle 0x14143ffa0). Returns how many droplets were requested.
static func emit_ce(node: Node, ce_name: String, pos: Vector3, base: Basis, depth := 0) -> int:
	var ce: Dictionary = DI2Particles.db().get("ce", {}).get(ce_name, {})
	if ce.is_empty() or depth > 8:
		return 0
	var m := of(node)
	if m == null:
		return 0
	var n := 0
	for f: Dictionary in (ce.get("fluid") if ce.get("fluid") is Array else []):
		n += m.emit(f, pos, base)
	for nested in ce.get("nested", []):
		if str(nested) != ce_name:
			n += emit_ce(node, str(nested), pos, base, depth + 1)
	return n


## One FluidParticle entry {type, speed, amount, spawn}: Speed (native default 1 cm/s) along the spawn transforms'
## X, Amount (default 50) each.
func emit(entry: Dictionary, pos: Vector3, base: Basis) -> int:
	var type := str(entry.get("type", "")).replace("DA_FluidTypeInfo_", "")
	var speed := float(entry["speed"]) if entry.get("speed") != null else 1.0
	var amount := float(entry["amount"]) if entry.get("amount") != null else 50.0
	var dirs: Array[Vector3] = []
	var spawn = entry.get("spawn")
	if spawn is Dictionary and str(spawn.get("_type", "")) == "SpawnMethodBurstProjectile":
		dirs = _burst_dirs(spawn, base)
	else:
		# No method, or SpawnMethodSingleProjectile (0x141595dd0 with no spread: the transform itself).
		dirs = [base.x.normalized()]
	for d in dirs:
		request(type, pos, d * speed * CM, amount)
	return dirs.size()


## USpawnMethodBurstProjectile (0x141595800): count in [MinProjectileCount, MaxProjectileCount] (native 3 / 3),
## yaw in [MinHorizontal, MaxHorizontal], pitch in [MinVertical, MaxVertical] (native +-45). DI2 places them over a
## shuffled DistributionGrid (MT19937 + LCG within a cell); here uniformly per grid cell (UNVERIFIED #25).
func _burst_dirs(s: Dictionary, base: Basis) -> Array[Vector3]:
	var lo := int(s.get("MinProjectileCount", 3))
	var hi := int(s.get("MaxProjectileCount", 3))
	var count := randi_range(lo, maxi(lo, hi))
	var h0 := float(s.get("MinHorizontalConeSizeInDegrees", -45.0))
	var h1 := float(s.get("MaxHorizontalConeSizeInDegrees", 45.0))
	var v0 := float(s.get("MinVerticalConeSizeInDegrees", -45.0))
	var v1 := float(s.get("MaxVerticalConeSizeInDegrees", 45.0))
	var gw := maxi(1, int(s.get("DistributionGridWidthCellCount", 2)))
	var gh := maxi(1, int(s.get("DistributionGridHeightCellCount", 2)))
	var out: Array[Vector3] = []
	# Without bUseDistributionGridForRandomPlacement (native default on, ctor 0x141d4be00) the burst draws each angle
	# uniformly over the cone (0x141595800: DeviationScaleWithinCell 1, one LCG draw per angle).
	var grid := bool(s.get("bUseDistributionGridForRandomPlacement", true))
	for i in count:
		var cx := (i % gw + randf()) / gw if grid else randf()
		var cy := (int(i / gw) % gh + randf()) / gh if grid else randf()
		var yaw := deg_to_rad(lerpf(h0, h1, cx))
		var pit := deg_to_rad(lerpf(v0, v1, cy))
		# UE yaw turns about the effect's Z (Godot basis.y), pitch about its Y (Godot basis.z).
		var d := Basis(base.y.normalized(), yaw) * (Basis(base.z.normalized(), pit) * base.x)
		out.append(d.normalized())
	return out


## Drops every droplet and puddle (tests).
func clear() -> void:
	drops.clear()
	projs.clear()
	for p in puddles:
		_end_states(p)
		_free_quad(p)
	puddles.clear()


## FluidManager request (0x14142e080): a droplet of `type` at `pos` (m) with `vel` (m/s) and payload radius `amount` (cm).
func request(type: String, pos: Vector3, vel: Vector3, amount: float) -> void:
	if not db().get("types", {}).has(type) or drops.size() >= MAX_DROPLETS:
		return
	drops.append({"type": type, "pos": pos, "vel": vel, "t0": now, "last": now, "radius": amount})


func _physics_process(delta: float) -> void:
	now += delta
	_tick_droplets()
	_tick_projectiles(delta)
	_tick_puddles(delta)
	_tick_states()
	if _dirty and _vp:
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		_dirty = false


func _tick_droplets() -> void:
	if drops.is_empty():
		return
	var g := Vector3(0, float(db().get("gravity_z", -980.0)) * CM, 0)
	var space := get_world_3d().direct_space_state
	var keep: Array[Dictionary] = []
	for d in drops:
		var cfg: Dictionary = db()["droplets"].get(d["type"], {})
		if now - float(d["t0"]) >= float(cfg.get("Lifetime", 5.0)):
			continue
		var dt := now - float(d["last"])
		if dt < float(cfg.get("MinUpdateInterval", 0.1)):
			keep.append(d)
			continue
		var p0: Vector3 = d["pos"]
		var v: Vector3 = d["vel"]
		var p1 := p0 + v * dt + g * (dt * dt * 0.5)
		var q := PhysicsRayQueryParameters3D.create(p0, p1, Util.WORLD)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			_payload(d["type"], hit["position"], hit["normal"], float(d["radius"]))
			continue
		d["pos"] = p1
		d["vel"] = v + g * dt
		d["last"] = now
		keep.append(d)
	drops = keep


func _type(t: String) -> Dictionary:
	return db()["types"][t]


## Where a landing droplet goes: into the nearest accepting puddle, else a new one. Returns that puddle.
func _payload(type: String, at: Vector3, normal: Vector3, r_cm: float) -> Dictionary:
	var ti := _type(type)
	var mgr: Dictionary = db().get("manager", {})
	var max_range := float(mgr.get("MergeMaxRange", 256.0))
	var best: Dictionary = {}
	var best_d := INF
	for p in puddles:
		if p["type"] != type or p.get("gone", false):
			continue
		var dist := (p["pos"] as Vector3).distance_to(at) / CM
		if dist > max_range or dist >= best_d:
			continue
		var r := float(p["radius"])
		var k := 1.0
		if bool(ti.get("bUseCurveForSpawnDistanceWhenSkippingConsmuption", false)):
			k = _curve(db().get("consumption_curve", []), r)
		elif r > float(ti["MinimumPuddleSizeForSkippingConsumption"]):
			k = float(ti["SpawnDistanceRequirementWhenSkippingConsumption"])
		var reach := r * k
		if reach > r or dist <= reach:
			best = p
			best_d = dist
	if not best.is_empty():
		_add(best, r_cm)
		return best
	if puddles.size() >= MAX_PUDDLES:
		var old: Dictionary = puddles.pop_front()
		_end_states(old)
		_free_quad(old)
	var np := _new_puddle(type, at, normal, r_cm)
	puddles.append(np)
	return np


func _add(p: Dictionary, r_cm: float) -> void:
	var ti := _type(p["type"])
	var r := sqrt(float(p["radius"]) ** 2 + r_cm * r_cm)
	p["radius"] = minf(r, float(ti["MaxRadius"]))
	# The restore (0x14143cdf0) clears only the idle evaporation flag; a forced one (a burning puddle) keeps going.
	if int(p["evap_flags"]) & EVAP_IDLE:
		_set_evap(p, EVAP_IDLE, false)
		p["restoring"] = true
	p["idle"] = 0.0


func _new_puddle(type: String, at: Vector3, normal: Vector3, r_cm: float) -> Dictionary:
	var ti := _type(type)
	var r := maxf(r_cm, float(ti["MinRadius"]))
	var target := randf_range(float(ti["MinOpacity"]), float(ti["MaxOpacity"]))
	var p := {"type": type, "pos": at, "normal": normal, "radius": r, "opacity": target, "target": target,
		"restoring": false, "evap_flags": 0, "forced": 0.0, "rate": 0.0, "idle": 0.0, "age": 0.0, "quad": null,
		"states": {},
		"visual": float(ti["StartingDecalRadiusMultiplierIfActorIsImpact"]) * r * float(ti["VisualRadiusMultiplier"])}
	_update_quad(p)
	return p


## UE FMath::FInterpTo (0x141f27800).
static func _finterp(cur: float, target: float, dt: float, speed: float) -> float:
	if speed <= 0.0 or (target - cur) * (target - cur) < 1e-8:
		return target
	return cur + (target - cur) * clampf(dt * speed, 0.0, 1.0)


func _tick_puddles(dt: float) -> void:
	var keep: Array[Dictionary] = []
	for p in puddles:
		var ti := _type(p["type"])
		p["age"] = float(p["age"]) + dt
		if p["restoring"]:
			p["opacity"] = _finterp(p["opacity"], p["target"], dt, float(ti["OpacityRestorationInterpolationSpeed"]))
			if float(p["opacity"]) >= float(p["target"]):
				p["restoring"] = false
		if int(p["evap_flags"]) != 0 and not p["restoring"]:
			p["opacity"] = float(p["opacity"]) - dt * float(p["rate"])
			if float(p["opacity"]) <= 0.0:
				_end_states(p)
				_free_quad(p)
				continue
		if not (int(p["evap_flags"]) & EVAP_IDLE) and float(ti["TimeIdleBeforeAutoEvaporate"]) > 0.0:
			p["idle"] = float(p["idle"]) + dt
			if float(p["idle"]) >= float(ti["TimeIdleBeforeAutoEvaporate"]):
				_set_evap(p, EVAP_IDLE, true)
		p["visual"] = _finterp(p["visual"], float(ti["VisualRadiusMultiplier"]) * float(p["radius"]), dt, float(ti["VisualRadiusInterpolationSpeed"]))
		_update_quad(p)
		keep.append(p)
	puddles = keep


## The puddle's coverage quad in the fluid map: the visual radius around its position, colour (height, opacity).
## Only changes reach the RenderingServer, and the map re-renders once per physics frame that had any.
func _update_quad(p: Dictionary) -> void:
	if _root == null:
		return
	var ti := _type(p["type"])
	var fade := 1.0
	var fd := float(ti.get("FadeInDuration", 0.0))
	if fd > 0.0:
		fade = clampf((float(p["age"]) - float(ti.get("FadeInDelay", 0.0))) / fd, 0.0, 1.0)
	var o := clampf(float(p["opacity"]) * fade * float(ti.get("OpacityMultiplier", 1.0)), 0.0, 1.0)
	var q: ColorRect = p["quad"]
	if q == null:
		q = ColorRect.new()
		q.material = _cov_mat
		q.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(q)
		p["quad"] = q
	var at: Vector3 = p["pos"]
	var rad := float(p["visual"]) * CM / MAP_TEXEL
	var centre := Vector2(at.x - map_area.position.x, at.z - map_area.position.y) / MAP_TEXEL
	var rect := Rect2(centre - Vector2(rad, rad), Vector2(rad, rad) * 2.0)
	var hn := clampf((at.y - map_heights.x) / (map_heights.y - map_heights.x), 0.0, 1.0)
	# g / b = 1 - the decal's Fluid Type r / b, FFluidComposePS's type-selector sources (di2_fluid.gdshaderinc).
	var ft: Array = ti.get("FluidTypeColor", [0.0, 1.0, 1.0, 0.0])
	var col := Color(hn, 1.0 - float(ft[0]), 1.0 - float(ft[2]), o)
	if not q.position.is_equal_approx(rect.position) or not q.size.is_equal_approx(rect.size):
		q.position = rect.position
		q.size = rect.size
		_dirty = true
	if not q.color.is_equal_approx(col):
		q.color = col
		_dirty = true


func _free_quad(p: Dictionary) -> void:
	if p.get("quad") is ColorRect and is_instance_valid(p["quad"]):
		(p["quad"] as Node).queue_free()
		_dirty = true


static func _curve(keys: Array, x: float) -> float:
	if keys.is_empty():
		return 1.0
	if x <= float(keys[0][0]):
		return float(keys[0][1])
	for i in range(1, keys.size()):
		if x <= float(keys[i][0]):
			var a: Array = keys[i - 1]
			var b: Array = keys[i]
			return lerpf(float(a[1]), float(b[1]), (x - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-6))
	return float(keys[-1][1])


# --- Evaporation flags, fluid-sim projectiles, transmittable states (recon/RE_FLUIDS.md §9) -------------------------

const EVAP_IDLE := 1     # AFluidInstanceActor +0x358 bit 1: idle evaporation (TimeIdleBeforeAutoEvaporate)
const EVAP_FORCED := 2   # bit 2: a state's ForcedEvaporationAreaPerSecond (+0x35C)
## AFluidInstanceActor ctor 0x1414237d0: MinimumOpacityRequirementForAOE (+0x2D4). The fluid CanTransmit (slot 178,
## 0x141429900) needs opacity >= it; below it the transmitter tick (0x141471850) destroys the AOE.
const MIN_OPACITY_FOR_AOE := 0.3
var _aoe_ids := 0


## 0x1414464c0: set / clear one evaporation flag. When any flag stays set the rate is recomputed:
## sqrt(A / pi) * target opacity / R, A = the forced area when EVAP_FORCED is set, else EvaporationAreaPerSec.
func _set_evap(p: Dictionary, bit: int, on: bool) -> void:
	var old := int(p["evap_flags"])
	var f := (old | bit) if on else (old & ~bit)
	p["evap_flags"] = f
	if f == old:
		return
	if f == 0:
		p["rate"] = 0.0
		return
	var area := float(p["forced"]) if f & EVAP_FORCED else float(_type(p["type"])["EvaporationAreaPerSec"])
	var r := float(p["radius"]) if float(p["radius"]) >= 0.0 else 1.0
	p["rate"] = maxf(0.0001, sqrt(area / PI) * float(p["target"]) / r)


## An AFluidSimProjectile (BP_Fluid_Projectile_<Type>, data fluids.json "projectiles"): UE projectile movement
## (DIProjectileMovementComponent: gravity scale 1, MaxSpeed 3000, no bounce) with a 5 cm sphere that blocks only
## WorldStatic / WorldDynamic (collision profile FluidSimProjectile). On its first blocking hit its
## SpawnFluidActorCollisionResponse spawns the payload puddle at the impact with the creation params' radius and
## InitialActiveStates. pos / vel in m and m/s; `normal` = the surface it starts on (the first sweep starts off it).
func spawn_projectile(cls: String, pos: Vector3, vel: Vector3, radius_cm: float, states: Array,
		instigator: Node = null, normal := Vector3.ZERO) -> void:
	var cfg: Dictionary = db().get("projectiles", {}).get(cls, {})
	if cfg.is_empty():
		push_warning("DI2Fluids: no projectile %s" % cls)
		return
	var type := str(cfg.get("FluidTypeInfo", "")).replace("DA_FluidTypeInfo_", "")
	projs.append({"cls": cls, "type": type, "pos": pos + normal * 0.001, "vel": vel, "t0": now,
		"radius": radius_cm if radius_cm > 0.0 else float(cfg.get("FluidPayloadRadius", 32.0)),
		"states": states, "instigator": instigator})


## UProjectileMovementComponent::TickComponent / ComputeMoveDelta: v' = LimitVelocity(v + g dt) (MaxSpeed),
## delta = v dt + (v' - v) dt / 2, swept against the world; no bounce, so the first blocking hit ends it.
func _tick_projectiles(dt: float) -> void:
	if projs.is_empty():
		return
	var space := get_world_3d().direct_space_state
	var keep: Array[Dictionary] = []
	for pr in projs:
		var cfg: Dictionary = db()["projectiles"][pr["cls"]]
		var g := Vector3(0, float(db().get("gravity_z", -980.0)) * float(cfg.get("ProjectileGravityScale", 1.0)) * CM, 0)
		var v: Vector3 = pr["vel"]
		var v2: Vector3 = (v + g * dt).limit_length(float(cfg.get("MaxSpeed", 3000.0)) * CM)
		var p0: Vector3 = pr["pos"]
		var p1 := p0 + v * dt + (v2 - v) * (0.5 * dt)
		var hit := _sweep(space, p0, p1, float(cfg.get("CollisionRadius", 5.0)) * CM)
		if not hit.is_empty():
			var pud := _payload(pr["type"], hit["position"], hit["normal"], float(pr["radius"]))
			for s in pr["states"]:
				activate_state(pud, str(s).replace("ETransmittableStatus::", ""), pr["instigator"])
			continue
		if now - float(pr["t0"]) > 30.0:   # recreation safety: a projectile that never lands (fell off the map)
			continue
		pr["pos"] = p1
		pr["vel"] = v2
		keep.append(pr)
	projs = keep


## The 5 cm sphere's sweep from a to b, approximated by the centre's ray extended by the radius along the motion
## (a shape cast misses the surface the projectile spawns touching): {position, normal} of the first world hit, else {}.
func _sweep(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, radius: float) -> Dictionary:
	var d := b - a
	if d.length_squared() < 1e-12:
		return {}
	var q := PhysicsRayQueryParameters3D.create(a, b + d.normalized() * radius, Util.WORLD)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	return {"position": hit["position"], "normal": hit["normal"]}


## The type's UFluidStateTransmitterConfig for a status (after StateTransmitterStatusTypeRemapping), or {}.
func _state_config(type: String, status: String) -> Dictionary:
	var ti := _type(type)
	for kv in ti.get("StateTransmitterStatusTypeRemapping", []):
		if str(kv.get("Key", "")).ends_with("::" + status):
			status = str(kv["Value"]).split("::")[-1]
	for kv in ti.get("StateTransmitterConfigs", []):
		if str(kv.get("Key", "")).ends_with("::" + status):
			var v = kv.get("Value")
			var on := str(v.get("ObjectName", "")) if v is Dictionary else str(v)
			var n := on.split("'")[1] if "'" in on else on
			return db().get("state_configs", {}).get(n, {})
	return {}


## UStateTransmitterComponent activation (slot 168 0x14146cc50) + the fluid override (slot 175 0x141434f70):
## the config's AreaOfEffectClass becomes an AOE on the puddle (its instigator = the status's), the transmit timer
## starts (FirstTransmitDelay, then every InitialTransmitTick), the CosmeticEffect plays with Radius =
## VisualRadiusMultiplier x R, and ForcedEvaporationAreaPerSecond[status] sets the forced evaporation flag.
func activate_state(p: Dictionary, status: String, instigator: Node = null) -> bool:
	if p.is_empty() or p.get("gone", false):
		return false
	var cfg := _state_config(p["type"], status)
	if cfg.is_empty() or (p["states"] as Dictionary).has(status):
		return false
	var st := {"cfg": cfg, "instigator": instigator, "t_next": now + float(cfg.get("FirstTransmitDelay", 0.0)),
		"radius": float(cfg.get("InitialTransmitRadius", 1.0)), "tick": float(cfg.get("InitialTransmitTick", 1.0)),
		"aoe": {}, "ps": []}
	var aoe_cls = cfg.get("AreaOfEffectClass")
	if aoe_cls != null and db().get("aoe", {}).has(str(aoe_cls)):
		_aoe_ids += 1
		st["aoe"] = {"id": _aoe_ids, "cls": str(aoe_cls), "data": db()["aoe"][str(aoe_cls)], "next": {}}
	p["states"][status] = st
	_play_state_effect(p, st)
	var forced := float((cfg.get("ForcedEvaporationAreaPerSecond", {}) as Dictionary).get(status, 0.0))
	if forced > 0.0:
		p["forced"] = forced
		_set_evap(p, EVAP_FORCED, true)
	return true


## Slot 176 (0x141436e70) for every active state: forced evaporation off, effects stopped; the puddle is gone.
func _end_states(p: Dictionary) -> void:
	var states: Dictionary = p.get("states", {})
	for st: Dictionary in states.values():
		for ps in st["ps"]:
			if is_instance_valid(ps):
				(ps as Node).queue_free()   # DI2Particles has no Deactivate yet: the system is removed
	if not states.is_empty() and p.has("evap_flags"):
		p["forced"] = 0.0
		_set_evap(p, EVAP_FORCED, false)
	p["states"] = {}
	p["gone"] = true


## The config's CosmeticEffect (CE_Fluid_State_Flammable -> PS_Burning_Liquid) at the puddle, UE Z along its normal
## (the puddle's rotation from the ImpactNormal), with the PS instance parameters the fluid transmitter drives
## (0x141434f70 / 0x1414421f0): "Radius" = VisualRadiusMultiplier x R, "Opacity" = (o, o, o).
func _play_state_effect(p: Dictionary, st: Dictionary) -> void:
	var ce: Dictionary = DI2Particles.db().get("ce", {}).get(str(st["cfg"].get("CosmeticEffect", "")), {})
	if ce.is_empty():
		return
	var n: Vector3 = p["normal"] if (p["normal"] as Vector3).length_squared() > 0.0 else Vector3.UP
	var b := DI2Particles.u2g_basis(_ue_make_from_z(DI2Particles.g2u_dir(n.normalized())))
	for link: Dictionary in ce.get("ps", []):
		var ps := DI2Particles.play_ps(self, str(link["ps"]), Transform3D(b, p["pos"]), false, _state_params(p))
		if ps:
			st["ps"].append(ps)


func _state_params(p: Dictionary) -> Dictionary:
	var o := float(p["opacity"])
	return {"Radius": float(_type(p["type"])["VisualRadiusMultiplier"]) * float(p["radius"]), "Opacity": Vector3(o, o, o)}


## UE FRotationMatrix::MakeFromZ (0x141f2b7c0) as a UE basis (columns X, Y, Z): up = (0, 0, 1) unless |Z.z| >= 1 -
## KINDA_SMALL_NUMBER, then (1, 0, 0); X = normalize(up x Z), Y = Z x X.
static func _ue_make_from_z(z: Vector3) -> Basis:
	var up := Vector3(0, 0, 1) if absf(z.z) < 1.0 - 1e-4 else Vector3(1, 0, 0)
	var x := up.cross(z).normalized()
	return Basis(x, z.cross(x), z)


## UE FRotationMatrix::MakeFromX: up as above from |X.z|; Y = normalize(up x X), Z = X x Y.
static func _ue_make_from_x(x: Vector3) -> Basis:
	var up := Vector3(0, 0, 1) if absf(x.z) < 1.0 - 1e-4 else Vector3(1, 0, 0)
	var y := up.cross(x).normalized()
	return Basis(x, y, x.cross(y))


## Per physics frame: each active state's transmit timer and AOE; the fluid transmitter's tick (0x1414421f0) keeps
## the effect's Radius / Opacity parameters on the puddle.
func _tick_states() -> void:
	for p in puddles:
		var states: Dictionary = p["states"]
		if states.is_empty():
			continue
		for status: String in states.keys():
			var st: Dictionary = states[status]
			for ps in st["ps"]:
				if is_instance_valid(ps):
					(ps as DI2Particles).params = _state_params(p)
			var can := float(p["opacity"]) >= MIN_OPACITY_FOR_AOE
			if not can:
				st["aoe"] = {}
			if can and now >= float(st["t_next"]):
				st["t_next"] = float(st["t_next"]) + float(st["tick"])
				_transmit(p, status, st)
			if not (st["aoe"] as Dictionary).is_empty():
				_tick_aoe(p, st)


## One transmit (0x14145f430): every other puddle with a config for the status is a receiver; it is reached when the
## 3D distance <= the transmit radius + the transmitter's R (bAddOwnerRadiusToTransmitRadius) + its own R
## (bAddOwnerRadiusToReceiveRadius). Reached receivers activate the status with the same instigator.
func _transmit(p: Dictionary, status: String, st: Dictionary) -> void:
	var cfg: Dictionary = st["cfg"]
	if not bool(cfg.get("bIsTransmitter", true)):
		return
	var reach_cm := float(st["radius"]) + (float(p["radius"]) if bool(cfg.get("bAddOwnerRadiusToTransmitRadius", true)) else 0.0)
	for q in puddles:
		if q == p or (q["states"] as Dictionary).has(status) or q.get("gone", false):
			continue
		var qc := _state_config(q["type"], status)
		if qc.is_empty() or not bool(qc.get("bIsReceiver", true)):
			continue
		var r := reach_cm + (float(q["radius"]) if bool(qc.get("bAddOwnerRadiusToReceiveRadius", true)) else 0.0)
		if (q["pos"] as Vector3).distance_to(p["pos"]) / CM <= r:
			activate_state(q, status, st["instigator"])


## The status's AOE (UAreaOfEffectBase sphere of radius R, AutoResizeToOwnerCollisionRadius) on the zombies.
## Per zombie (the receiver tick 0x1412b5ce0): AOEs are listed by AreaOfEffectCategory; with MultipleOverlapRule 0 only
## the first overlapping AOE of a category applies; its first application comes DelayTimeBeforeFirstEffectApplication
## after the overlap starts, then every EffectApplicationTickInterval. Vertical rule (0x14129af70): with
## bRestrictRelativeVerticalAreaDimensions the zombie's capsule [z - h, z + h] (z in the puddle's frame) must reach
## [Minimum, Maximum]RelativeVerticalOffsetAllowed.
func _tick_aoe(p: Dictionary, st: Dictionary) -> void:
	var a: Dictionary = st["aoe"]
	var d: Dictionary = a["data"]
	var cat := str(d.get("AreaOfEffectCategory", ""))
	var r_m := float(p["radius"]) * CM
	var n: Vector3 = (p["normal"] as Vector3).normalized() if (p["normal"] as Vector3).length_squared() > 0.0 else Vector3.UP
	var nexts: Dictionary = a["next"]
	for zn in get_tree().get_nodes_in_group("zombies"):
		var z := zn as Zombie
		if z == null or z.root_shape == null:
			continue
		var zid := z.get_instance_id()
		var cap := z.root_shape.shape as CapsuleShape3D
		var c := (z.root_shape as Node3D).global_position
		var hh := cap.height * 0.5
		var seg := maxf(hh - cap.radius, 0.0)
		var rel := c - (p["pos"] as Vector3)
		var along := clampf(rel.dot(Vector3.UP), -seg, seg)
		var inside := (rel - Vector3.UP * along).length() <= r_m + cap.radius
		if inside and bool(d.get("bRestrictRelativeVerticalAreaDimensions", false)):
			var zl := rel.dot(n) / CM
			var h_cm := hh / CM
			inside = not (zl - h_cm > float(d.get("MaximumRelativeVerticalOffsetAllowed", 10.0))) \
				and not (zl + h_cm < float(d.get("MinimumRelativeVerticalOffsetAllowed", 0.0)))
		var key := "di2_aoe_" + cat
		if not inside:
			nexts.erase(zid)
			if z.has_meta(key) and int(z.get_meta(key)) == int(a["id"]):
				z.remove_meta(key)
			continue
		if not nexts.has(zid):
			nexts[zid] = now + float(d.get("DelayTimeBeforeFirstEffectApplication", 0.0))
		# The category list's first AOE applies (MultipleOverlapRule 0): the first one to claim the zombie, while
		# it still overlaps.
		var claim := int(z.get_meta(key)) if z.has_meta(key) else 0
		if claim != 0 and claim != int(a["id"]) and _aoe_alive(claim, zid):
			continue
		z.set_meta(key, int(a["id"]))
		if now < float(nexts[zid]):
			continue
		nexts[zid] = float(nexts[zid]) + float(d.get("EffectApplicationTickInterval", 1.0))
		_aoe_apply(p, st, z)


func _aoe_alive(id: int, zid: int) -> bool:
	for p in puddles:
		for st: Dictionary in (p["states"] as Dictionary).values():
			var a: Dictionary = st["aoe"]
			if not a.is_empty() and int(a["id"]) == id:
				return (a["next"] as Dictionary).has(zid)
	return false


## BP_Base_AOE_DamageOverTime UpdateActorAffected -> CanAffectTarget -> RequestImpactOnTarget (bytecode,
## recon/RE_FLUIDS.md §9.4): alive and not #ImmuneToPuddleDamage (an empty expression); damage = HazardDamageToApply,
## x StatusEffectScalar when the IgnoreDamageKbFact (IsOnFire) holds, x Strength (1), DamageType Fire, level-scaled
## (ScaledToInstigatorLevelFallbackToVictimLevel: the instigator's level_damage); AccumulatingEffectsToApply =
## AccumulatingEffectsToUpdate (Burning 0.3, can extend; scaling policy ScaledBasedOnInstigatorLevel). The general
## impact has no hit bone: it lands at the hitbox bone nearest the AOE origin (its AttackOrigin).
func _aoe_apply(p: Dictionary, st: Dictionary, z: Zombie) -> void:
	if z.dead:
		return
	var d: Dictionary = st["aoe"]["data"]
	var inst: Node = st["instigator"] if is_instance_valid(st["instigator"]) else null
	var dmg := float(d.get("HazardDamageToApply", 0.0))
	var fact := str((d.get("IgnoreDamageKbFact", {}) as Dictionary).get("NameStorage", "None"))
	if fact == "IsOnFire" and float(z.gore.status_states().get("burning", 0.0)) > 0.0:
		dmg *= float(d.get("StatusEffectScalar", 1.0))
	dmg *= float(d.get("Strength", 1.0))
	if inst and inst.has_method("level_damage"):
		dmg = float(inst.call("level_damage", dmg))
	var origin: Vector3 = p["pos"]
	var bone := "pelvis"
	var best := INF
	for area: Area3D in z.hitboxes:
		var dd := area.global_position.distance_squared_to(origin)
		if dd < best:
			best = dd
			bone = str(area.get_meta("bone"))
	var sk := z.skeleton
	var bi := sk.find_bone(bone)
	var point := sk.global_transform * sk.get_bone_global_pose(bi).origin if bi >= 0 else z.global_position
	var dir := (point - origin).normalized()
	var was_dead := z.dead
	var res := z.take_hit(bone, point, dir, dir, dmg, DI2Explosion._kind(str(d.get("DamageType", ""))), false, 1.0, 0.0,
		Vector3.ZERO, inst as Node3D, {"weapon": "", "ThrownAttack": false})
	var effects := []
	for e: Dictionary in (d.get("AccumulatingEffectsToUpdate", {}) as Dictionary).get("AccumulatingEffects", []):
		effects.append({"type": str(e["EffectType"]).split("::")[-1], "value": float(e["ValueToApply"]),
			"apply_max": bool(e.get("bApplyMaxValue", false)), "can_extend": bool(e.get("CanExtendEffectDuration", false))})
	if not z.dead and not effects.is_empty():
		var lvl: int = inst.get("level") if inst and inst.get("level") != null else z.level
		z.accumulate(effects, lvl, true, point, bone)
	if inst and inst.has_method("on_damage_dealt") and not res.is_empty() and not was_dead:
		inst.call("on_damage_dealt", dmg, not res.get("alive", true), z)


## BP_MolotovCocktail_Projectile's two InvokeCollisionLocationResponses (fluids.json "molotov_spawns"): the collision
## transform is MakeFromZ(ImpactNormal) at the ImpactPoint (0x1415a1bd0); each ProjectileResponseSpawnProjectile
## (0x1415b1010) turns its SpawnDirectionAxis of that transform into the spawn X (MakeFromX), its burst
## (0x141595800, uniform yaw / pitch in the cone when bUseDistributionGridForRandomPlacement is off, DeviationScale 1)
## gives the directions, speed = rand(OverrideInitalProjectileSpeedRangedMin, Max), plus
## FractionOfParentVelocityToInherit x the bottle's velocity (bInheritParentProjectileVelocity, ctor 0x141589b90).
static func molotov_burst(node: Node, at: Vector3, normal: Vector3, bottle_vel: Vector3, instigator: Node = null) -> int:
	var m := of(node)
	if m == null:
		return 0
	var col := _ue_make_from_z(DI2Particles.g2u_dir(normal.normalized()))
	var n := 0
	for sp: Dictionary in db().get("molotov_spawns", []):
		var axis: Vector3 = {"EAxis::X": col.x, "EAxis::Y": col.y, "EAxis::Z": col.z}.get(str(sp.get("SpawnDirectionAxis", "EAxis::X")), col.x)
		var base := DI2Particles.u2g_basis(_ue_make_from_x(axis))
		var cp: Dictionary = sp.get("CreationParams", {})
		var init: Dictionary = cp.get("FluidActorInitialState", {})
		for d in m._burst_dirs(sp.get("CustomSpawnMethod", {}), base):
			var speed := float(cp.get("OverrideInitalProjectileSpeed", 0.0))
			if bool(cp.get("bRandomRangeInitialProjectileSpeed", false)):
				speed = randf_range(float(cp.get("OverrideInitalProjectileSpeedRangedMin", 0.0)), float(cp.get("OverrideInitalProjectileSpeedRangedMax", 0.0)))
			var v := d * speed * CM + bottle_vel * float(sp.get("FractionOfParentVelocityToInherit", 1.0))
			m.spawn_projectile(str(sp["ProjectileType"]), at, v, float(init.get("FluidPayloadRadius", 0.0)),
				init.get("InitialActiveStates", []), instigator, normal.normalized())
			n += 1
	return n


## The burning puddles (tests / HUD).
func burning_puddles() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in puddles:
		if (p["states"] as Dictionary).has("Burning"):
			out.append(p)
	return out
