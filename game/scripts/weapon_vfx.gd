class_name WeaponVfx
## DI2 weapon cosmetics and world-impact effects (recon/WEAPON_VFX.md has the exe addresses and asset sources).
##
## Guns (UBaseProjectileSpawnModule / UHitscanProjectileSpawnModule, data/weapon_vfx.json "weapons"):
##   muzzle flash  - the gun's ObjectSet key "MuzzleFlare" (DA_EffectSetCollection_*), else MuzzleFlashEffectType,
##                   at MuzzleOriginBoneOrSocketName on the gun mesh;
##   casings       - the ObjectSet key "AmmoEject", else EjectedAmmoCasingsEffectType, at AmmoEjectBoneOrSocketName;
##                   pump guns eject from their shoot montage instead (BP_AnimNotify_SpawnParticleSystemOnWeapon);
##   tracer        - the ObjectSet key "Tracer", else ProjectileTracerEffectType, muzzle -> impact;
##   impact        - the weapon's ImpactConfiguration.EnvironmentEffectTree on a world hit, after DI2's cosmetic
##                   impact delay (distance / FakeProjectileSpeedForCosmeticImpactDelay).
## Melee: the same environment tree (CT_HitEffect_Weapon_Environment) where the sweep meets the world.
## Environment trees end in MaterialGridCosmeticEffect nodes: a CollisionEffectsRegistry row (Bullet_Pistol, Melee,
## MeleeSharp ...) x the surface's physical material -> a CE_Collision_* definition (particles, decal, sound).
## Particle systems run on DI2Particles; decals are boxes drawing DI2's decal material (weapon_vfx_decal_pom.gdshader).

const DATA_PATH := "res://data/weapon_vfx.json"

static var _db: Dictionary = {}


static func db() -> Dictionary:
	if _db.is_empty():
		var j: Variant = Util.load_json(DATA_PATH)
		_db = j if j is Dictionary else {}
	return _db


# --- World impacts ----------------------------------------------------------------------------------------------

## Physical material (PM_* name) of a world collider: its "di2_physical_material" meta, else this stand-in.
## DI2's own fallback for geometry without one is DefaultEngine.ini DefaultPhysMaterialName (PM_Default, surface
## Default). The test arena's floor / crates / wall have no DI2 material at all: PM_Concrete stands in for them
## (recon/UNVERIFIED.md "Arena surface").
static var default_physical_material := "PM_Concrete"
## Hit actor class for the registry's class columns ("Hit.ClassObjectIndex"): a collider's "di2_class" meta, else
## AActor (static world geometry), whose column (Actor) holds MakeCascadeDefinition for every bullet / melee row.
const DEFAULT_ACTOR_CLASS := "Actor"
const CASCADE := "MakeCascadeDefinition"
const INHERIT := "MakeInheritDefinition"


static func physical_material(collider: Object) -> String:
	if collider and collider.has_meta("di2_physical_material"):
		return str(collider.get_meta("di2_physical_material"))
	return default_physical_material


## A world hit: walks the weapon's ImpactConfiguration.EnvironmentEffectTree (UHitEffectsComponent dispatch
## 0x1415485f0: a victim that is not a character takes the impact's environment tree) and plays each gathered CE at
## the impact point (spawn loop 0x141556dd0) with the point-impact rotation (0x1414810b0) and the effect's
## DirectionInterpolationFactor (material-grid effects: 0, gather 0x1414942c0).
## kbs: the knowledge bases the impact context holds, in DI2's order [["Hit", {...}], ["Attacker", {...}],
## ["DamageCauser", {...}]] (bare fact names); tree expressions read them as {Scope}.Fact.
## Returns [[ce, factor], ...] as played.
static func world_impact(parent: Node, tree: String, kbs: Array, pos: Vector3, normal: Vector3, travel: Vector3,
		collider: Object) -> Array:
	var facts := {}
	for kb: Array in kbs:
		for k: String in kb[1]:
			facts[str(kb[0]) + "." + k] = kb[1][k]
	var pm := physical_material(collider)
	var ctx := {"kbs": kbs, "pm": pm,
		"surface": int(db().get("physical_materials", {}).get(pm, {}).get("surface", 0)),
		"class": str(collider.get_meta("di2_class")) if collider and collider.has_meta("di2_class") else DEFAULT_ACTOR_CLASS}
	var effects := evaluate(tree, facts, ctx)
	last_impact_at = Transform3D(Basis.looking_at(-normal, Vector3.UP if absf(normal.y) < 0.99 else Vector3.FORWARD), pos)
	for e: Array in effects:
		play_ce(parent, str(e[0]), pos, HitEffectSpawn.point_basis(normal, travel, float(e[1])))
	return effects


## DI2's hit-effect tree walk (same node semantics as Flesh.evaluate) with the MaterialGridCosmeticEffect leaves
## resolved against the collision effects registry.
static func evaluate(tree: String, facts: Dictionary, ctx: Dictionary) -> Array:
	Flesh._ensure()
	var out := []
	var t: Dictionary = Flesh.hit_data["trees"].get(tree, {})
	var grids: Dictionary = db().get("grid_nodes", {}).get(tree, {})
	var id: Variant = t.get("start")
	var guard := 0
	while id != null and guard < 256:
		guard += 1
		var n: Dictionary = t["nodes"].get(id, {})
		match n.get("k", ""):
			"bool":
				id = n["t"] if DI2Expr.eval(n["expr"], facts) else n["f"]
			"str":
				id = n["links"].get(str(DI2Expr.value(n["expr"], facts)), n.get("default"))
			"module":
				id = n["links"].get(Flesh.module_result(n["module"], facts))
			"multi":
				for e: Array in n["effects"]:
					out.append([str(e[0]), float(e[1])])
				id = n.get("next")
			"ce":
				out.append([str(n["ce"]), 0.0])
				id = null
			"grid":
				var ce := grid_pick(grids.get(id, {}), ctx)
				if ce != "":
					out.append([ce, 0.0])
				id = n.get("next")
			_:
				id = null
	return out


## UConditionalTreeNode_MaterialGridCosmeticEffect's pick (exe 0x1414893d0). The row is the knowledge-base string
## fact MaterialGridRowFactName when bPreferMaterialGridRowNameFromImpactKnowledgebase (an unscoped lookup: the first
## knowledge base of the impact context that has it, 0x140a3a6d0; the gun's held fact MaterialGridRow = Bullet_<type>
## sits in the attacker's), falling back to MaterialGridRow per bFallbackIfKBFactFailed / bFallbackIfKBFactEmpty.
## The column: the hit actor's class (ClassToCollidersMap, nearest ancestor), else the physical material
## (MaterialToCollidersMap), else the surface type (EPhysicalSurface = column index).
static func grid_pick(node: Dictionary, ctx: Dictionary) -> String:
	var regs: Dictionary = db().get("registries", {})
	var reg: Dictionary = regs.get(str(node.get("registry")) if node.get("registry") else str(db().get("default_registry", "")), {})
	if reg.is_empty():
		return ""
	var cls := class_column(reg, str(ctx.get("class", DEFAULT_ACTOR_CLASS)))
	var mat := int(reg.get("materials", {}).get(str(ctx.get("pm", "")), -1))
	var surf := int(ctx.get("surface", -1))
	var row := str(node["row"]) if node.get("row") != null else ""
	var fact := str(node.get("row_fact", "MaterialGridRow"))
	var found := false
	var s := ""
	if node.get("prefer_kb", false):
		for kb: Array in ctx.get("kbs", []):
			if (kb[1] as Dictionary).has(fact):
				found = true
				s = str(kb[1][fact])
				break
		if found:
			var e: Variant = grid_lookup(reg, s, cls, mat, surf)
			if e != null:
				return _ce_or_empty(e)
	# Fallback (0x141489791): bFallbackIfKBFactFailed always; else only when the fact was missing or empty.
	if node.get("fallback_failed", true) or ((not found or s == "") and node.get("fallback_empty", true)):
		return _ce_or_empty(grid_lookup(reg, row, cls, mat, surf))
	return ""


## UGameCollisionEffectsRegistry lookup (0x141432fb0): ColliderTable[row * N + column] as stored (null, a CE or a
## sentinel). A class column wins unless it holds MakeCascadeDefinition (it may hold null: no effect); else the
## material column, else the surface column.
static func grid_lookup(reg: Dictionary, row_name: String, cls: int, mat: int, surf: int) -> Variant:
	var row := int(reg.get("names", {}).get(row_name, -1))
	if row < 0:
		return null
	var n: int = (reg["colliders"] as Array).size()
	var table: Array = reg["table"]
	if cls >= 0:
		var e: Variant = table[row * n + cls]
		if e != CASCADE:
			return e
	var col := mat if mat >= 0 else surf
	if col < 0:
		return null
	return table[row * n + col]


static func _ce_or_empty(e: Variant) -> String:
	# The sentinels are empty CosmeticEffectsDefinitions: nothing to play.
	return "" if e == null or e == CASCADE or e == INHERIT else str(e)


## Class column (0x141431af0): the class or its nearest ancestor in ClassToCollidersMapSoft. The recreation's world
## colliders are plain actors ("Actor" -> the /Script/Engine.Actor column).
static func class_column(reg: Dictionary, cls: String) -> int:
	var classes: Dictionary = reg.get("classes", {})
	for k: String in classes:
		if k == cls or k.ends_with("." + cls) or k.ends_with("." + cls + "_C"):
			return int(classes[k])
	return int(classes.get("/Script/Engine.Actor", -1))


# --- Cosmetic effects (particles via DI2Particles, decals here) ---------------------------------------------------

## One CosmeticEffectsDefinition at a world transform: its ParticleSystem links (HitEffectSpawn.play: link rotation,
## bForceNotAttached, desaturation, nested CEs) and its Decal effects. AudioEvent / PhysicalizedWorld entries are not
## ported (recon/WEAPON_VFX.md §6). Returns the decals spawned.
## Seconds after which DI2 stops effects the hit actor does not take over (spawn loop 0x141556dd0: 0x140cbfde0(handle,
## 10.0) -> a world timer that stops the effect).
const STOP_UNOWNED_EFFECTS_AFTER := 10.0


static func play_ce(parent: Node, ce: String, pos: Vector3, base: Basis, ps_params := {}) -> Array:
	HitEffectSpawn.play(parent, ce, pos, base, ps_params)
	var decals := []
	for d: Dictionary in db().get("ce_decals", {}).get(ce, []):
		var n := spawn_decal(parent, d, pos, base)
		if n:
			decals.append(n)
	return decals


## UCosmeticEffect_Decal spawn (vtable 0x144d327e8 slot 0x258 = 0x140ccb930):
##   rotation = spawn rotator + (DecalExtraRotation + DecalRandomRotation * FRand per axis) (0x140cc1fa0; FRotator
##   addition, rand() order roll, yaw, pitch; FRand = (rand() & 0x7fff) / 32767);
##   size = DecalSize * (1 + DecalSizePercentageOffsetRange / 100 * (2 * FRand - 1));
##   then the component (0x140cc2aa0): SetSortOrder, SetFadeIn if bApplyCustomFadeInSettings, SetFadeOut(FadeStartDelay,
##   FadeDuration), SetFadeScreenSize(1 / FadeDistance), destroyed when the fade-out finishes.
## Native defaults (ctor 0x140cd3cf0): DecalSize (8, 16, 16), rotations 0, SizePercentageOffsetRange 10, SortOrder 0,
## FadeIn 5 s + 2 s, FadeStartDelay 10, FadeDuration 5, FadeDistance 400, DestroyFadeDuration 5.
## How decals are drawn: "decal" = a Godot Decal (default): DI2's DBuffer semantics (colour / normal / roughness blended
## into the surface before lighting) and it only lands on the world layers (cull_mask DECAL_LAYERS: never on characters,
## Fx.CHARACTER_LAYER), but without the parallax occlusion; "pom" = the full transcription of FDeferredDecalPS 861
## (weapon_vfx_decal_pom.gdshader: POM, edge fade) as a depth-reading box, which also paints on characters inside the
## box (recon/WEAPON_VFX.md section 5).
static var decal_renderer := "decal"
## Visual layers a world decal may affect: the world layer only (characters use Fx.CHARACTER_LAYER).
const DECAL_LAYERS := 1


static func spawn_decal(parent: Node, d: Dictionary, pos: Vector3, base: Basis) -> Node3D:
	var mi_name := str((d.get("DecalMaterial") as Dictionary).get("n", "")) if d.get("DecalMaterial") is Dictionary else ""
	var use_pom := decal_renderer == "pom"
	var mat: ShaderMaterial = decal_material(mi_name) if use_pom else null
	var tex: Dictionary = db().get("decal_materials", {}).get(mi_name, {}).get("godot_decal", {}) if not use_pom else {}
	if (use_pom and mat == null) or (not use_pom and tex.is_empty()):
		if mi_name != "" and not _warned.has(mi_name):
			_warned[mi_name] = true
			push_warning("WeaponVfx: decal material %s has no port (master %s)" % [mi_name,
				db().get("decal_materials", {}).get(mi_name, {}).get("master", "?") if db().get("decal_materials", {}).get(mi_name) else "?"])
		return null
	var extra: Dictionary = d.get("DecalExtraRotation", {})
	var rnd: Dictionary = d.get("DecalRandomRotation", {})
	var r_roll := _frand() * float(rnd.get("Roll", 0.0))
	var r_yaw := _frand() * float(rnd.get("Yaw", 0.0))
	var r_pitch := _frand() * float(rnd.get("Pitch", 0.0))
	# The impact's FRotator + the effect's rotator, component-wise (FRotator operator+).
	var spawn := DI2Particles.quat_euler_ue(Quaternion(DI2Particles.g2u_basis(base.orthonormalized())))  # (roll, pitch, yaw)
	var pitch := spawn.y + float(extra.get("Pitch", 0.0)) + r_pitch
	var yaw := spawn.z + float(extra.get("Yaw", 0.0)) + r_yaw
	var roll := spawn.x + float(extra.get("Roll", 0.0)) + r_roll
	var size_d: Dictionary = d.get("DecalSize", {"X": 8.0, "Y": 16.0, "Z": 16.0})
	var range_pct := float(d.get("DecalSizePercentageOffsetRange", 10.0))
	var scale := (float(randi() & 0x7fff) * range_pct * 6.103702e-07 - range_pct * 0.01) + 1.0
	var size := Vector3(float(size_d.get("X", 8.0)), float(size_d.get("Y", 16.0)), float(size_d.get("Z", 16.0))) * scale
	var g := DI2Particles.u2g_basis(DI2Particles.rotator_basis_ue(pitch, yaw, roll))
	# UE axes in Godot coordinates: X = g.x, Y = g.z, Z = g.y (u2g_basis swaps the y / z columns). The decal box spans
	# +-DecalSize and projects along UE +X; DI2's PS 861 maps uv = (OS.z, OS.y) * 0.5 + 0.5 and its tangent normal
	# (x, y, z) to (Z, Y, -X).
	var ux := g.x.normalized()
	var uy := g.z.normalized()
	var uz := g.y.normalized()
	var node: Node3D
	var fade_set: Callable
	if use_pom:
		var box := MeshInstance3D.new()
		box.mesh = _decal_box()
		box.material_override = mat
		box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# SortOrder: decals with a higher order draw on top (UDecalComponent::SetSortOrder).
		box.sorting_offset = float(d.get("SortOrder", 0)) * 0.001
		parent.add_child(box)
		# Node basis = (X * Size.X, Z * Size.Z, Y * Size.Y) on a 2 x 2 x 2 box (weapon_vfx_decal_pom.gdshader).
		box.global_transform = Transform3D(Basis(ux * size.x * DI2Particles.UE_TO_M, uz * size.z * DI2Particles.UE_TO_M,
			uy * size.y * DI2Particles.UE_TO_M), pos)
		box.set_instance_shader_parameter("decal_fade", 1.0)
		fade_set = func(a: float) -> void: box.set_instance_shader_parameter("decal_fade", a)
		node = box
	else:
		# Godot Decal: projects along local -Y over the local XZ face, uv = (x, z) * 0.5 + 0.5, tangent normal
		# (x, y, z) -> local (x, z, y) with the green channel flipped (the composed _normal texture undoes the flip).
		# So local X = UE Z (U), local Z = UE Y (V), local Y = -UE X (out of the surface; = Z x X after the axis mirror).
		var dec := Decal.new()
		dec.size = Vector3(size.z * 2.0, size.x * 2.0, size.y * 2.0) * DI2Particles.UE_TO_M
		dec.texture_albedo = _decal_texture(str(tex.get("albedo", "")))
		dec.texture_normal = _decal_texture(str(tex.get("normal", "")))
		dec.texture_orm = _decal_texture(str(tex.get("orm", "")))
		dec.albedo_mix = 1.0
		dec.normal_fade = 0.0
		# PS 861's opacity ramp sat(4 - 4 |OS.x|) along the projection axis: Godot's fade is (1 - |y|)^fade; a small
		# exponent keeps the decal at full strength through the box like DI2 (APPROXIMATED, recon/UNVERIFIED.md).
		dec.upper_fade = 0.05
		dec.lower_fade = 0.05
		dec.cull_mask = DECAL_LAYERS
		dec.sorting_offset = float(d.get("SortOrder", 0))
		parent.add_child(dec)
		dec.global_transform = Transform3D(Basis(uz, -ux, uy), pos)
		fade_set = func(a: float) -> void: dec.modulate.a = a
		node = dec
	_decal_fades(node, d, fade_set)
	return node


static var _warned: Dictionary = {}


static var _box: BoxMesh


static func _decal_box() -> BoxMesh:
	if _box == null:
		_box = BoxMesh.new()
		_box.size = Vector3(2.0, 2.0, 2.0)
	return _box


static var _decal_mats: Dictionary = {}


## ShaderMaterial for one DI2 decal material instance (data/weapon_vfx.json "decal_materials": the MI's texture /
## scalar / vector overrides over its master's defaults). Only M_DecalPOM_DNR is transcribed; other masters return
## null (warned once).
static func decal_material(mi_name: String) -> ShaderMaterial:
	if _decal_mats.has(mi_name):
		return _decal_mats[mi_name]
	var info: Dictionary = db().get("decal_materials", {}).get(mi_name, {})
	var mat: ShaderMaterial = null
	if info.get("master", "") == "M_DecalPOM_DNR":
		mat = ShaderMaterial.new()
		mat.shader = load("res://shaders/weapon_vfx_decal_pom.gdshader")
		var tex: Dictionary = info.get("textures", {})
		var bind := {"01 - Diffuse Colour Map": "diffuse_map", "02 - Packed ARA Map (see tooltip!)": "ara_map",
			"03 - Normal Map": "normal_map", "Height Map (see tooltip!)": "height_map"}
		for param: String in bind:
			if tex.get(param):
				var t := _decal_texture(str(tex[param]))
				if t:
					mat.set_shader_parameter(bind[param], t)
		var sc: Dictionary = info.get("scalars", {})
		mat.set_shader_parameter("pom_depth", float(sc.get("Depth", 0.03)))
		mat.set_shader_parameter("roughness_adjust", float(sc.get("05 - Roughness Adjustment", 0.0)))
		var tint: Array = info.get("vectors", {}).get("04 - Diffuse Colour Tint", [1.0, 1.0, 1.0, 1.0])
		mat.set_shader_parameter("diffuse_tint", Vector3(float(tint[0]), float(tint[1]), float(tint[2])))
		var mpc: Dictionary = db().get("mpc", {})
		mat.set_shader_parameter("pom_min_steps", float(mpc.get("POMMinSteps", 4.0)))
		mat.set_shader_parameter("pom_max_steps", float(mpc.get("POMMaxSteps", 25.0)))
	elif mi_name != "":
		push_warning("WeaponVfx: decal material %s (master %s) is not transcribed" % [mi_name, info.get("master", "?")])
	_decal_mats[mi_name] = mat
	return mat


const DECAL_TEX_DIR := "res://assets/di2/weapon_vfx/decals/"
static var _decal_tex: Dictionary = {}


static func _decal_texture(name: String) -> Texture2D:
	if _decal_tex.has(name):
		return _decal_tex[name]
	var img := Image.load_from_file(ProjectSettings.globalize_path(DECAL_TEX_DIR + name + ".png"))
	var t: Texture2D = null
	if img:
		img.generate_mipmaps()
		t = ImageTexture.create_from_image(img)
	else:
		push_warning("WeaponVfx: missing decal texture %s (run tools/weapon_vfx/build_weapon_vfx.py)" % name)
	_decal_tex[name] = t
	return t


## UDecalComponent fades (0x140cc2aa0): SetFadeIn(FadeInStartDelay, FadeInDuration) when bApplyCustomFadeInSettings,
## SetFadeOut(FadeStartDelay, FadeDuration), destroyed when the fade-out ends. The shader's opacity reads the lifetime
## fade (DecalParams.y; UE 4.27: clamp(min(1 - (t - FadeStartDelay) / FadeDuration, (t - FadeInStartDelay) /
## FadeInDuration), 0, 1)). Effects the hit actor doesn't take over are stopped after 10 s (spawn loop 0x141556dd0 ->
## 0x140cbfde0): a decal's stop (vtable slot 0x280, 0x140cbf4e0) restarts the fade-out with
## SetFadeOut(DestroyFadeStartDelay, DestroyFadeDuration + 0.1). The screen-size fade (SetFadeScreenSize(1 /
## FadeDistance), DecalParams.x) is not ported (recon/UNVERIFIED.md).
static func _decal_fades(node: Node3D, d: Dictionary, fade_set: Callable) -> void:
	var fade_in := bool(d.get("bApplyCustomFadeInSettings", false))
	var in_delay := float(d.get("FadeInStartDelay", 5.0))
	var in_dur := float(d.get("FadeInDuration", 2.0))
	var out_delay := float(d.get("FadeStartDelay", 10.0))
	var out_dur := float(d.get("FadeDuration", 5.0))
	var stop_delay := float(d.get("DestroyFadeStartDelay", 0.0))
	var stop_dur := float(d.get("DestroyFadeDuration", 5.0)) + 0.1
	var state := {"t": 0.0}
	var timer := Timer.new()
	timer.wait_time = 1.0 / 30.0
	timer.autostart = true
	node.add_child(timer)
	timer.timeout.connect(func() -> void:
		state["t"] += timer.wait_time
		var t: float = state["t"]
		var o_delay := out_delay
		var o_dur := out_dur
		var o_from := 0.0
		if t >= STOP_UNOWNED_EFFECTS_AFTER:
			o_delay = stop_delay
			o_dur = stop_dur
			o_from = STOP_UNOWNED_EFFECTS_AFTER
		var a := 1.0
		if o_dur > 0.0 or o_delay > 0.0:
			a = minf(a, clampf(1.0 - (t - o_from - o_delay) / maxf(o_dur, 0.0001), 0.0, 1.0))
		if fade_in:
			a = minf(a, clampf((t - in_delay) / maxf(in_dur, 0.0001), 0.0, 1.0))
		fade_set.call(a)
		if (o_dur > 0.0 or o_delay > 0.0) and t >= o_from + o_delay + o_dur:
			node.queue_free())


static func _frand() -> float:
	return float(randi() & 0x7fff) / 32767.0


# --- Guns ---------------------------------------------------------------------------------------------------------

## UBaseProjectileSpawnModule / UHitscanProjectileSpawnModule native defaults (ctors 0x1415e4f30 / 0x1415b5950); the
## cooked spawner properties (data/weapon_vfx.json weapons.<id>.spawner) override them.
const SPAWNER_DEFAULTS := {
	"RayTraceDistance": 10000.0,
	"MuzzleOriginBoneOrSocketName": "Muzzle",
	"AmmoEjectBoneOrSocketName": "AmmoEject",
	"MuzzleFlashEffectType": null,
	"EjectedAmmoCasingsEffectType": null,
	"ProjectileTracerEffectType": null,
	"bCosmeticImpactTimeDelayEnabled": true,
	"FakeProjectileSpeedForCosmeticImpactDelay": 15000.0,
	"MaxTracerLifetime": 2.0,
	"MaxFakeProjectileCosmeticImpactDelay": 0.25,
}
## FCosmeticEffect-from-ObjectSet keys of the module's cosmetic structs (ctors): WeaponShootMuzzleCosmeticEffect
## "MuzzleFlare", WeaponAmmoEjectCosmeticEffect "AmmoEject", ProjectileTracerCosmeticEffect "Tracer" (none of DI2's
## guns sets a direct Definition).
const KEY_MUZZLE := "MuzzleFlare"
const KEY_EJECT := "AmmoEject"
const KEY_TRACER := "Tracer"

## Effects the last world impact played ([[ce, factor], ...]) and where (-Z = into the surface); tests read them.
static var last_impact: Array = []
static var last_impact_at := Transform3D.IDENTITY


static func spawner(wid: String) -> Dictionary:
	var out := SPAWNER_DEFAULTS.duplicate()
	out.merge(db().get("weapons", {}).get(wid, {}).get("spawner", {}), true)
	return out


## World transform of a socket on the held gun mesh (SkeletalMeshSocket: bone, RelativeLocation / Rotation in UE
## bone space; the gun glbs keep UE bone frames as (x, z, y) * 0.01 like every DI2 skeleton here).
static func socket_transform(p: Player, wid: String, socket: String) -> Transform3D:
	var so: Dictionary = db().get("weapons", {}).get(wid, {}).get("sockets", {}).get(socket, {})
	var sk: Skeleton3D = p.weapon_skel.get(wid)
	var node: Node3D = p.weapon_nodes.get(wid)
	if so.is_empty() or sk == null:
		return node.global_transform if node else p.camera.global_transform
	var bi := sk.find_bone(str(so.get("bone", "")))
	var bone_xf := sk.global_transform * (sk.get_bone_global_pose(bi) if bi >= 0 else Transform3D.IDENTITY)
	var loc: Array = so.get("loc", [0, 0, 0])
	var rot: Array = so.get("rot", [0, 0, 0])
	var local := Transform3D(DI2Particles.ue_rotator_basis_g(rot), DI2Particles.u2g(Vector3(float(loc[0]), float(loc[1]), float(loc[2]))))
	return bone_xf * local


## The weapon's facts for its effect-set groups ("FireMod == true", "FireModLevel1 == true", ...): the held mod as
## DI2's mod facts. Which knowledge base FUN_141146570 reads with the module's empty context is not traced
## (recon/UNVERIFIED.md); the weapon's own mod state is used.
static func weapon_facts(p: Player) -> Dictionary:
	var f := {}
	var mod_fact: String = {"fire": "FireMod", "electric": "ShockMod", "shock": "ShockMod", "acid": "AcidMod",
		"bleed": "BleedMod", "impact": "ImpactMod", "tearing": "TearingMod"}.get(p.melee.mod(), "")
	for m in ["FireMod", "ShockMod", "AcidMod", "BleedMod", "ImpactMod", "TearingMod"]:
		f[m] = m == mod_fact
		for lvl in [1, 2, 3]:
			f[m + "Level%d" % lvl] = m == mod_fact and p.melee.mod_level == lvl
	return f


## FCosmeticEffect-from-ObjectSet (0x1415fdc80): the CE of `key` in the gun's ObjectSet collections - the first group
## whose expression holds, a weighted random item (AnimSetSelectionOrder_Random).
static func object_set_ce(wid: String, key: String, facts: Dictionary) -> String:
	var w: Dictionary = db().get("weapons", {}).get(wid, {})
	for s: String in w.get("effect_sets", []):
		for g: Dictionary in db().get("effect_sets", {}).get(s, {}).get(key, []):
			if DI2Expr.eval(str(g.get("expr", "")), facts):
				var items: Array = g.get("items", [])
				if items.is_empty():
					return ""
				var total := 0.0
				for it: Array in items:
					total += float(it[0])
				var r := randf() * total
				for it: Array in items:
					r -= float(it[0])
					if r <= 0.0:
						return str(it[1])
				return str(items.back()[1])
	return ""


## One projectile's cosmetics (UHitscanProjectileSpawnModule shot handling 0x1415dca10):
##   tracer (0x1415dea40) from the muzzle socket (the trace start for a continued segment) to the impact point, or
##   to trace start + direction * RayTraceDistance on a miss: CE "Tracer" from the ObjectSet, else
##   ProjectileTracerEffectType, at the start, rotated to the travel direction; with the cosmetic impact delay
##   enabled its instance parameters are Velocity = FakeProjectileSpeedForCosmeticImpactDelay and
##   Lifetime = min(distance / that speed, MaxTracerLifetime);
##   world impact (0x1415d7260): the impact request is deferred by min(distance from the trace start /
##   FakeProjectileSpeedForCosmeticImpactDelay, MaxFakeProjectileCosmeticImpactDelay) when
##   bCosmeticImpactTimeDelayEnabled.
## `hit` is the recreation's trace result ({} on a miss). Character hits keep their own path (zombie.take_hit).
static func on_projectile(p: Player, trace_start: Vector3, dir: Vector3, hit: Dictionary) -> void:
	var wid := p.weapon
	var sp := spawner(wid)
	var muzzle := socket_transform(p, wid, str(sp["MuzzleOriginBoneOrSocketName"])).origin
	var end: Vector3 = hit["position"] if not hit.is_empty() else trace_start + dir * float(sp["RayTraceDistance"]) * DI2Particles.UE_TO_M
	tracer(p, wid, muzzle, end, sp)
	if hit.is_empty() or hit.get("collider") is Area3D:
		return
	var delay := 0.0
	if sp["bCosmeticImpactTimeDelayEnabled"] and float(sp["FakeProjectileSpeedForCosmeticImpactDelay"]) > 0.0:
		delay = trace_start.distance_to(hit["position"]) * DI2Particles.M_TO_UE / float(sp["FakeProjectileSpeedForCosmeticImpactDelay"])
	delay = minf(delay, float(sp["MaxFakeProjectileCosmeticImpactDelay"]))
	var parent := p.get_parent()
	var kbs := impact_kbs(p, wid)
	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var collider: Object = hit["collider"]
	var tree := str(db().get("weapons", {}).get(wid, {}).get("env_tree", ""))
	if delay <= 0.0:
		last_impact = world_impact(parent, tree, kbs, pos, normal, dir, collider)
	else:
		p.get_tree().create_timer(delay, false).timeout.connect(func() -> void:
			if is_instance_valid(parent):
				last_impact = world_impact(parent, tree, kbs, pos, normal, dir, collider))


static func tracer(p: Player, wid: String, from: Vector3, to: Vector3, sp: Dictionary) -> void:
	var d := to - from
	var dist_cm := d.length() * DI2Particles.M_TO_UE
	var dir := d.normalized() if d.length_squared() > 1e-8 else -p.camera.global_basis.z
	# FVector::Rotation() of the travel (roll 0), at the start, scale 1.
	var base := HitEffectSpawn.point_basis(dir, Vector3.ZERO, 0.0)
	var params := {}
	var speed := float(sp["FakeProjectileSpeedForCosmeticImpactDelay"])
	if sp["bCosmeticImpactTimeDelayEnabled"] and speed > 0.0:
		params = {"Velocity": speed, "Lifetime": minf(dist_cm / speed, float(sp["MaxTracerLifetime"]))}
	var parent := p.get_parent()
	var ce := object_set_ce(wid, KEY_TRACER, weapon_facts(p))
	if ce != "":
		HitEffectSpawn.play(parent, ce, from, base, params)
	elif sp.get("ProjectileTracerEffectType"):
		DI2Particles.play_ps(parent, str(sp["ProjectileTracerEffectType"]), Transform3D(base, from), false, params)


## The impact context's knowledge bases for the environment tree, in the dispatch's order (0x1415485f0): Hit (the
## impact's facts: ImpactConfiguration.CustomImpactFacts and the hit's mod facts), Attacker (Dani, holding the
## weapon: its FactsSetWhenHeld, e.g. MaterialGridRow = Bullet_Pistol), DamageCauser (the weapon). A world victim
## adds no Victim scope unless the actor has the HasVictimContext tag.
static func impact_kbs(p: Player, wid: String) -> Array:
	var w: Dictionary = db().get("weapons", {}).get(wid, {})
	var hit := {}
	for k: String in w.get("impact_facts", {}):
		hit[k] = w["impact_facts"][k]
	var mf := weapon_facts(p)
	for k: String in ["FireMod", "ShockMod", "AcidMod", "BleedMod", "ImpactMod", "TearingMod"]:
		hit[k] = mf[k]
	var attacker := {}
	for k: String in w.get("held_facts", {}):
		attacker[k] = w["held_facts"][k]
	return [["Hit", hit], ["Attacker", attacker], ["DamageCauser", {}]]


## Melee sweep meeting the world (the recreation's rebound point): the weapon's environment tree at the hit with
## HitFromDirection = the sweep trace direction (melee request 0x1410ab130).
static func melee_world_hit(p: Player, hit: Dictionary, travel: Vector3) -> void:
	var wid := p.weapon
	var tree := str(db().get("weapons", {}).get(wid, {}).get("env_tree", ""))
	if tree == "" or hit.is_empty():
		return
	last_impact = world_impact(p.get_parent(), tree, impact_kbs(p, wid), hit["position"], hit["normal"], travel, hit.get("collider"))


## A shot's cosmetics (UBaseProjectileSpawnModule shot cosmetics 0x141606560), then the gun montage's particle
## notifies:
##   muzzle flash (0x1416059b0): the ObjectSet CE "MuzzleFlare" attached to the gun mesh at
##     MuzzleOriginBoneOrSocketName (spawned at the socket's world transform, follows it); without one,
##     MuzzleFlashEffectType via SpawnEmitterAttached at that socket (zero offset, KeepRelativeOffset, auto-destroy),
##     kept in MuzzleFXParticleSystemComponent and re-activated (reset) on the next shot while it is alive;
##   casings: the ObjectSet CE "AmmoEject" at AmmoEjectBoneOrSocketName's world transform, else
##     EjectedAmmoCasingsEffectType via SpawnEmitterAtLocation there (world space, not attached);
##   then the LocalPlayerShootCosmeticEffect / camera shake / force feedback (0x141605800) and the ShootLifetime CE
##     (0x141606030; no DI2 gun's collection has one) - not ported here (no camera / rumble CEs in this project).
## `weapon_item` is the class slot item the shot plays (its "weapon" montage carries the notifies).
static func on_shot(p: Player, weapon_item: Dictionary) -> void:
	var wid := p.weapon
	var sp := spawner(wid)
	var facts := weapon_facts(p)
	# Muzzle flash.
	var muzzle_socket := str(sp["MuzzleOriginBoneOrSocketName"])
	var mxf := socket_transform(p, wid, muzzle_socket)
	var holder := socket_node(p, wid, muzzle_socket)
	var ce := object_set_ce(wid, KEY_MUZZLE, facts)
	if ce != "":
		HitEffectSpawn.play(holder, ce, mxf.origin, mxf.basis.orthonormalized())
	elif sp.get("MuzzleFlashEffectType"):
		var key := wid + ":" + muzzle_socket
		var psc: DI2Particles = _muzzle_psc.get(key)
		if psc and is_instance_valid(psc) and not psc.is_queued_for_deletion():
			psc.queue_free()  # ActivateSystem(reset): restart from scratch
		_muzzle_psc[key] = DI2Particles.play_ps(holder, str(sp["MuzzleFlashEffectType"]), mxf.orthonormalized(), true)
	# Casings.
	var exf := socket_transform(p, wid, str(sp["AmmoEjectBoneOrSocketName"]))
	var ece := object_set_ce(wid, KEY_EJECT, facts)
	if ece != "":
		HitEffectSpawn.play(p.get_parent(), ece, exf.origin, exf.basis.orthonormalized())
	elif sp.get("EjectedAmmoCasingsEffectType"):
		DI2Particles.play_ps(p.get_parent(), str(sp["EjectedAmmoCasingsEffectType"]), exf, false)
	montage_notifies(p, wid, weapon_item)


static var _muzzle_psc: Dictionary = {}


## A node that follows a gun socket (BoneAttachment3D on the gun skeleton + the socket's local transform).
static func socket_node(p: Player, wid: String, socket: String) -> Node3D:
	var so: Dictionary = db().get("weapons", {}).get(wid, {}).get("sockets", {}).get(socket, {})
	var sk: Skeleton3D = p.weapon_skel.get(wid)
	if so.is_empty() or sk == null:
		return p.weapon_nodes.get(wid, p) as Node3D
	var nm := "WeaponVfx_" + socket
	var att := sk.get_node_or_null(nm) as BoneAttachment3D
	if att == null:
		att = BoneAttachment3D.new()
		att.name = nm
		att.bone_name = str(so.get("bone", ""))
		sk.add_child(att)
		var loc: Array = so.get("loc", [0, 0, 0])
		var rot: Array = so.get("rot", [0, 0, 0])
		var n := Node3D.new()
		n.name = "Socket"
		n.transform = Transform3D(DI2Particles.ue_rotator_basis_g(rot), DI2Particles.u2g(Vector3(float(loc[0]), float(loc[1]), float(loc[2]))))
		att.add_child(n)
	return att.get_node("Socket") as Node3D


## BP_AnimNotify_SpawnParticleSystemOnWeapon notifies of the gun's montage (pump-action shell ejects): the
## ParticleSystemTemplate at InSocket on the gun mesh, at the notify's montage time (data/weapon_vfx.json
## montage_notifies; times are montage seconds at play rate 1, as the shoot montages play).
static func montage_notifies(p: Player, wid: String, weapon_item: Dictionary) -> void:
	var m := str(weapon_item.get("weapon", {}).get("m", ""))
	for n: Dictionary in db().get("montage_notifies", {}).get(m, []):
		var ps := str(n.get("ps", ""))
		var socket := str(n.get("socket", ""))
		p.get_tree().create_timer(float(n.get("t", 0.0)), false).timeout.connect(func() -> void:
			if not is_instance_valid(p) or p.weapon != wid:
				return
			var xf := socket_transform(p, wid, socket)
			DI2Particles.play_ps(socket_node(p, wid, socket), ps, xf.orthonormalized(), NOTIFY_ATTACHED))


## BP_AnimNotify_SpawnParticleSystemOnWeapon.Received_Notify: SpawnAttached (CDO true) -> SpawnEmitterAttached(Template,
## the montage mesh, InSocket, zero offset, CDO Scale (1, 1, 1), KeepRelativeOffset, auto-destroy); only for the
## current perspective's weapon child actor.
const NOTIFY_ATTACHED := true
