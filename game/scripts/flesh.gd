class_name Flesh
extends RefCounted
## DI2 FLESH on a GoreBody, driven by DI2's own data:
##   data/hit_effects.json  HitEffectTrees + modular trees + damage-causer collections (tools/build_hit_effects.py):
##                          which cosmetic effects (CE_*) a hit plays
##   data/splatter.json     the SplatterMesh stamps and stored SplatterSets those effects carry, progressive-damage
##                          curves, pre-spawn tables (tools/build_splatter.py)
##   data/cosmetics.json    every cosmetic effect (its SplatterSet entries)
## Stamps are framed in bind-pose space (GoreBody.hit_ex's rest_* impact data) and drawn by flesh.gdshader.
## Readings that aren't in the data (blend of the progressive curves, frame conventions, channel use) are listed
## in recon/UNVERIFIED.md.

const STAMPS_DIR := "res://assets/di2/splatter/stamps/"
## DI2's empty mask texture: a stamp slot that uses it draws nothing.
const EMPTY_TEX := "T_BlackMaskAlpha_A"

static var hit_data := {}
static var splatter := {}
static var cosmetics := {}
static var weapons := {}
static var character_states := {}
## Time spent in the animated-splatter ticks (all bodies), ms: perf checks.
static var animator_ms := 0.0
static var viscera_parts := {}
static var _textures: Texture2DArray
static var _empty := -1


static func _ensure() -> void:
	if hit_data.is_empty():
		hit_data = Util.load_json("res://data/hit_effects.json")
		splatter = Util.load_json("res://data/splatter.json")
		cosmetics = Util.load_json("res://data/cosmetics.json")
		_empty = int(splatter["textures"].get(EMPTY_TEX, -1))


## DI2's HitFX stamp textures as one array (layer = index.json slot). Loaded raw: the textures keep data in
## channels whose alpha is 0, which the PNG importer would premultiply away.
static func textures() -> Texture2DArray:
	if _textures == null:
		var index: Dictionary = Util.load_json(STAMPS_DIR + "index.json")
		var images: Array[Image] = []
		images.resize(index.size())
		for n: String in index:
			var img := Image.load_from_file(STAMPS_DIR + n + ".png")
			img.convert(Image.FORMAT_RGBA8)
			img.generate_mipmaps()
			images[int(index[n])] = img
		_textures = Texture2DArray.new()
		_textures.create_from_images(images)
	return _textures


## A weapon's data/weapons.json entry ({} for none).
static func weapon(id: String) -> Dictionary:
	if weapons.is_empty():
		weapons = Util.load_json("res://data/weapons.json")
	var w: Variant = weapons.get(id, {})
	return w if w is Dictionary else {}


# --- Hit effect trees ------------------------------------------------------------------------------------------

## Cosmetic effects DI2's HitEffectTree `tree` plays for a hit: [[CE name, DirectionInterpolationFactor], ...].
## `causer_sets` are the damage causer's ObjectSet collections (CosmeticEffectDamageCauser nodes look keys up there).
static func evaluate(tree: String, facts: Dictionary, causer_sets: Array = []) -> Array:
	_ensure()
	var out := []
	var t: Dictionary = hit_data["trees"].get(tree, {})
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
				id = n["links"].get(module_result(n["module"], facts))
			"multi":
				for e: Array in n["effects"]:
					out.append([str(e[0]), float(e[1])])
				id = n.get("next")
			"ce":
				out.append([str(n["ce"]), 0.0])
				id = null
			"causer":
				for key: String in n["names"]:
					var ce := causer(causer_sets, key, facts)
					if ce != "":
						out.append([ce, 0.0])
				id = null
			"grid":
				# Surface-material rows (bullet impact particles / sound by physical material): VFX, not FLESH.
				id = n.get("next")
			_:
				id = null
	return out


## Result label of a ModularConditionalTree (CT_WeaponModType, CT_AttackType, CT_IsLarge ...), "" for none.
static func module_result(module: String, facts: Dictionary) -> String:
	_ensure()
	var t: Dictionary = hit_data["modules"].get(module, {})
	var id: Variant = t.get("start")
	var guard := 0
	while id != null and guard < 64:
		guard += 1
		var n: Dictionary = t["nodes"].get(id, {})
		match n.get("k", ""):
			"bool":
				id = n["t"] if DI2Expr.eval(n["expr"], facts) else n["f"]
			"result":
				return str(n["label"])
			_:
				return ""
	return ""


## The CE a damage causer's collection gives `key` (first group whose expression holds, weighted item).
static func causer(sets: Array, key: String, facts: Dictionary) -> String:
	_ensure()
	for s: String in sets:
		for g: Dictionary in hit_data["causers"].get(s, {}).get(key, []):
			if DI2Expr.eval(g["expr"], facts):
				return str(_weighted(g["items"], 0, 1))
	return ""


static func _weighted(items: Array, w_at: int, v_at: int) -> Variant:
	var total := 0.0
	for it: Array in items:
		total += float(it[w_at])
	var r := randf() * total
	for it: Array in items:
		r -= float(it[w_at])
		if r <= 0.0:
			return it[v_at]
	return items.back()[v_at] if not items.is_empty() else null


# --- Stamps ----------------------------------------------------------------------------------------------------

## FLESH parts of the effects a hit plays: each CE's SplatterMesh stamps at the impact, and its stored
## SplatterSets. `impact` is GoreBody.hit_ex's result; `state` = {health: remaining fraction after the hit,
## htd: hits to death at this hit's damage}. Returns the stamps added.
static func apply_hit(gore: GoreBody, effects: Array, impact: Dictionary, state: Dictionary) -> int:
	_ensure()
	var made := 0
	for e: Array in effects:
		var ce: String = e[0]
		for st: Dictionary in splatter["presets"].get(ce, []):
			if _hit_stamp(gore, ce, st, float(e[1]), impact, state):
				made += 1
		for fx: Dictionary in cosmetics.get(ce, {}).get("effects", []):
			if fx.get("type") == "SplatterSet" and fx.get("SplatterSet") is Dictionary:
				made += apply_set(gore, str(fx["SplatterSet"]["n"]), false)
	return made


static func _hit_stamp(gore: GoreBody, ce: String, st: Dictionary, factor: float, impact: Dictionary, state: Dictionary) -> bool:
	var eff: Dictionary = splatter["effect_defaults"]
	var duration := float(st.get("Duration", eff["Duration"]))
	# Spawn orients once (the instance keeps that rotation relative to the bone).
	var f := orient(st, st.get("modifiers", {}), factor, impact)
	if duration <= 0.0:
		return _apply(gore, st, f, impact, state, 1.0)
	# DI2 animated splatter (Spawn's Duration > 0 branch): an instance re-applies the effect every tick.
	SplatterAnimator.on(gore).add({"st": st, "frame": f, "impact": impact, "state": state, "duration": duration,
		"curve": str(st.get("EffecsScaleCurve", "")),
		"absolute": bool(st.get("bEffectsScaleCurveWithAbsoluteTime", eff["bEffectsScaleCurveWithAbsoluteTime"])),
		"differences": float(st.get("ApplyDifferences", eff["ApplyDifferences"])),
		"threshold": float(st.get("ApplyThreshold", eff["ApplyThreshold"])), "t": 0.0, "prev": 0.0})
	return true


## DI2 UCosmeticEffect_SplatterMesh::Apply (exe 0x141258560): Modify (re-rolled every call), then with
## animFraction < 1 the strengths scale by it, then SplatterDecal (GoreBody bakes it into the render targets).
static func _apply(gore: GoreBody, st: Dictionary, f: Array, impact: Dictionary, state: Dictionary, anim_fraction: float) -> bool:
	var m := modify(st["info"], st.get("modifiers", {}), float(state.get("health", 1.0)), float(state.get("damage", 0.0)))
	var params := params_for(m["info"])
	if params.is_empty():
		return false
	if anim_fraction < 1.0:
		params["strength"] = anim_fraction
	var at: Vector3 = impact.get("rest_point", Vector3.ZERO)
	# DI2's default projection (bReferencePose is false in every preset): against the body as posed now, through
	# the bone the hit landed on (FSplatterVS_World + the skinned deform CS). Without a bone, bind pose.
	var ok := gore.add_stamp_posed(params, str(impact["bone"]), at, f[0], f[1], f[2]) if impact.get("bone", "") != "" 			else gore.add_stamp_rest(params, at, f[0], f[1], f[2], false)
	# UVisceraComponent::Splatter runs for every stamp: rupture damage on the body's viscera proxies.
	var z := gore.get_parent()
	if ok and z and z.has_method("viscera_splatter"):
		var info: Dictionary = m["info"]
		if anim_fraction < 1.0:
			info = info.duplicate()
			info["DisplacementScale"] = float(_v(info, "DisplacementScale")) * anim_fraction
		z.viscera_splatter(info, at, f, impact, state)
	return ok


## Ticks DI2's animated splatter instances on one GoreBody (exe 0x141259120, recon/RE_FLESH.md "Animated splatter"):
##   t += dt; s = EffecsScaleCurve(absolute ? t : min(t / Duration, 1)), or min(t / Duration, 1) without a curve;
##   a = s - prev * ApplyDifferences; skipped while (a <= 0 or a < ApplyThreshold) and t < Duration;
##   otherwise Apply(animFraction = a) (strengths x a when a < 1), prev = s; the instance ends at t >= Duration.
## Every application is baked into the render targets like DI2's (ADD for Decal, MAX for MaxDecal), so the
## increments accumulate exactly as there.
class SplatterAnimator extends Node:
	var gore: GoreBody
	var live: Array[Dictionary] = []

	static func on(g: GoreBody) -> SplatterAnimator:
		var a := g.get_node_or_null("SplatterAnimator") as SplatterAnimator
		if a == null:
			a = SplatterAnimator.new()
			a.name = "SplatterAnimator"
			a.gore = g
			g.add_child(a)
		return a

	func add(rec: Dictionary) -> void:
		live.append(rec)

	func _process(dt: float) -> void:
		var t0 := Time.get_ticks_usec()
		_tick(dt)
		Flesh.animator_ms += (Time.get_ticks_usec() - t0) / 1000.0

	func _tick(dt: float) -> void:
		for i in range(live.size() - 1, -1, -1):
			var r: Dictionary = live[i]
			r["t"] += dt
			var t: float = r["t"]
			var dur: float = r["duration"]
			var lin := minf(t / dur, 1.0)
			var s := lin
			if r["curve"] != "":
				s = Flesh.curve(r["curve"], t if r["absolute"] else lin)
			var a: float = s - float(r["prev"]) * float(r["differences"])
			if (a <= 0.0 or a < float(r["threshold"])) and t < dur:
				continue
			Flesh._apply(gore, r["st"], r["frame"], r["impact"], r["state"], a)
			r["prev"] = s
			if t >= dur:
				live.remove_at(i)


## DI2's FSplatterModifiers application (exe 0x141245180, recon/RE_FLESH.md "Modify"). `h` = the hit's
## HealthRemainingAsFractionOfMaxHealth (after the hit, not clamped), `d` = DamageAsFractionOfMaxHealth.
## Returns {info: the modified SplatterMeshInfo values, strength: the strength curves' sum (1 without curves)}.
static func modify(info_in: Dictionary, mods: Dictionary, h: float, d: float) -> Dictionary:
	_ensure()
	var info := info_in.duplicate()
	for k in ["UVScale", "DepthScale", "DisplacementScale", "TextureInfluence", "SplatterType"]:
		info[k] = _v(info_in, k)
	var eff: Dictionary = splatter["effect_defaults"]
	var alt_w: Array = mods.get("AlternateWoundTextures", [])
	var alt_s: Array = mods.get("AlternateSecondaryTextures", [])
	var max_blend := float(mods.get("MaxBlendThreshold", eff["MaxBlendThreshold"]))
	var uv_var := float(mods.get("UVScaleVariation", eff["UVScaleVariation"]))
	var depth_var := float(mods.get("DepthVariation", eff["DepthVariation"]))
	# Native early out: no HealthRemaining curve, MaxBlendThreshold >= 1, no variation, no alternates.
	var health_curves := false
	for k: String in ["HealthRemainingToScaleCurve", "HealthRemainingtToStrengthCurve", "HealthRemainingToRuptureLimitCurve",
			"HealthRemainingToRuptureDepthCurve", "HealthRemainingToRuptureRadiusCurve", "HealthRemainingToRuptureCountCurve"]:
		health_curves = health_curves or mods.has(k)
	if not health_curves and max_blend >= 1.0 and uv_var == 0.0 and depth_var == 0.0 and alt_w.is_empty() and alt_s.is_empty():
		return {"info": info, "strength": 1.0}
	var htd := (100.0 / (d * 100.0)) * h if d > 0.0 else INF
	if h > max_blend and htd > float(mods.get("HitsToDeathMaxBlendThreshold", eff["HitsToDeathMaxBlendThreshold"])) \
			and str(info["SplatterType"]) == "Decal":
		info["SplatterType"] = "MaxDecal"
	var scale: Variant = _pair(mods, "HealthRemainingToScaleCurve", "HitsToDeathToScaleCurve", h, htd)
	if scale != null:
		info["UVScale"] = float(info["UVScale"]) * float(scale)
	var strength: Variant = _pair(mods, "HealthRemainingtToStrengthCurve", "HitsToDeathToStrengthCurve", h, htd)
	if strength != null:
		info["DisplacementScale"] = float(info["DisplacementScale"]) * float(strength)
		info["RuptureDamageMultiplier"] = float(_v(info, "RuptureDamageMultiplier")) * float(strength)
		if bool(mods.get("bApplyStrengthVariationToTextureInfluence", eff["bApplyStrengthVariationToTextureInfluence"])):
			info["TextureInfluence"] = float(info["TextureInfluence"]) * float(strength)
	# (The rupture limit / depth / radius / count curve pairs exist in the native code but no data sets them.)
	info["UVScale"] = float(info["UVScale"]) + _rand1() * uv_var
	info["DepthScale"] = float(info["DepthScale"]) + _rand1() * depth_var
	if not alt_w.is_empty():
		info["DisplacementDecalTexture"] = alt_w[mini(int(randf() * alt_w.size()), alt_w.size() - 1)]
	if not alt_s.is_empty():
		info["DiffuseDecalTexture"] = alt_s[mini(int(randf() * alt_s.size()), alt_s.size() - 1)]
	return {"info": info, "strength": float(strength) if strength != null else 1.0}


## C_HealthRemaining(h) + C_HitsToDeath(htd); a missing curve adds 0; null when neither exists.
static func _pair(mods: Dictionary, health_curve: String, htd_curve: String, h: float, htd: float) -> Variant:
	if not mods.has(health_curve) and not mods.has(htd_curve):
		return null
	var v := 0.0
	if mods.has(health_curve):
		v += curve(str(mods[health_curve]), h)
	if mods.has(htd_curve):
		v += curve(str(mods[htd_curve]), htd)
	return v


## DI2's rand-in-[-1, 1]: (rand() & 0x7fff) * 6.103702e-05 - 1.
static func _rand1() -> float:
	return float(randi() & 0x7fff) * 6.103702e-05 - 1.0


## A DI2 CurveFloat (FRichCurve::Eval: per-key Linear / Constant / Cubic Bezier from the tangents, constant
## extrapolation). Keys are [time, value, interp, arrive tangent, leave tangent].
static func curve(name: String, x: float) -> float:
	_ensure()
	var keys: Array = splatter["curves"].get(name, [])
	if keys.is_empty():
		return 0.0
	if x <= float(keys[0][0]):
		return float(keys[0][1])
	for i in range(1, keys.size()):
		if x < float(keys[i][0]):
			var a: Array = keys[i - 1]
			var b: Array = keys[i]
			var dt := float(b[0]) - float(a[0])
			var t := (x - float(a[0])) / dt if dt > 0.0 else 0.0
			match str(a[2]):
				"K":
					return float(a[1])
				"C":
					var p0 := float(a[1])
					var p3 := float(b[1])
					var p1 := p0 + float(a[4]) * dt / 3.0
					var p2 := p3 - float(b[3]) * dt / 3.0
					var u := 1.0 - t
					return u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
				_:
					return lerpf(float(a[1]), float(b[1]), t)
	return float(keys.back()[1])


## DI2's stamp orientation (exe 0x141238ae0, recon/RE_FLESH.md "Orient"), in bind-pose space, returned as the
## [x, y, z] frame the shader projects with (x = projection axis; image +u along y, +v along z).
## The effect's spawn direction is its spawn rotation's forward: impact["spawn_forward"].call(factor) when the hit
## supplies it (HitEffectSpawn: DI2's point / radial impact rotation, recon/RE_FLESH.md "Hit-effect spawn transform"),
## else the outward surface normal (a CE spawned at a transform, e.g. DamagePropagation's node X).
## bApplySplatterUsingFlippedRotation (default true) negates it.
static func orient(st: Dictionary, mods: Dictionary, factor: float, impact: Dictionary) -> Array:
	var eff: Dictionary = splatter["effect_defaults"]
	var flipped := bool(st.get("bApplySplatterUsingFlippedRotation", eff["bApplySplatterUsingFlippedRotation"]))
	var world_up := bool(st.get("bAlignToWorldUp", eff["bAlignToWorldUp"]))
	var variation := float(mods.get("AlignmentVariation", eff["AlignmentVariation"]))
	var n: Vector3 = impact.get("rest_normal", Vector3.ZERO)
	var into: Vector3 = impact.get("rest_into", -n)
	if n.length_squared() < 0.5:
		n = -into
	var dir := n
	if impact.get("spawn_forward") is Callable:
		var fwd: Vector3 = (impact["spawn_forward"] as Callable).call(factor)
		if fwd.length_squared() > 0.25:
			dir = fwd.normalized()
	var x := -dir if flipped else dir
	var up: Vector3 = impact.get("rest_up", Vector3.UP)
	# UE builds Y = Up x X (world-up frame, or the roll-0 rotator of X); through the bind-pose mirror that is
	# X x Up here.
	var y := Vector3.ZERO
	var sweep: Vector3 = impact.get("rest_sweep", Vector3.ZERO)
	var align: Vector3 = impact.get("rest_align", Vector3.ZERO)
	if not world_up and variation < 180.0 and sweep.length_squared() > 1e-8 and align.length_squared() > 1e-8:
		var nn := sweep.cross(align).normalized()
		if absf(nn.dot(dir)) >= 0.99:
			nn = sweep.cross(dir).normalized()
		y = dir.cross(nn).normalized()
		if y.dot(sweep) < 0.0:
			y = -y
	else:
		y = x.cross(up)
		if y.length_squared() < 1e-8:
			y = x.cross(Vector3.RIGHT)
		y = y.normalized()
	var z := y.cross(x).normalized()
	if not world_up:
		var roll := deg_to_rad(_rand1() * variation + float(mods.get("AlignmentAngle", eff["AlignmentAngle"])))
		var c := cos(roll)
		var sn := sin(roll)
		var y2 := y * c + z * sn
		z = z * c - y * sn
		y = y2
	# Image +v runs down the stamp's Z (world up for aligned stamps, so drips run down; UNVERIFIED #32).
	return [x, y, -z]


const SPLATTER_TYPES := {"None": 0, "Decal": 1, "Dismember": 2, "DismemberWithDecal": 3, "SoftInfluenceUpdate": 4,
	"BoneBreak": 8, "BoneBreakWithDecal": 9, "ApplyMin": 16, "MinDecal": 17, "ApplyMax": 32, "MaxDecal": 33,
	"ClearToValue": 64, "ClearSplatter": 80, "RequiresSplatter": 81, "RequiresMeshEdit": 138, "ClearAll": 80}


## GoreBody stamp parameters from a (modified) SplatterMeshInfo, packed like DI2's splatter batch
## (exe FUN_1409fe910 / 0x140a0db30, recon/RE_FLESH.md "Batch packing"): decal box UVScale wide and +-DepthScale
## deep (cm -> m), ScaleVec.x = 1 / (1 - DepthFadeStart), WoundScale = (DisplacementScale, FluidSplatter, Bruising)
## x TextureInfluence, FXScale = (FluidDrips, Cauterisation, 1, 1) x TextureInfluence, RangeParams, flags.
static func params_for(info: Dictionary) -> Dictionary:
	var disp := int(info.get("DisplacementDecalTexture", -1))
	var diff := int(info.get("DiffuseDecalTexture", -1))
	disp = -1 if disp == _empty else disp
	diff = -1 if diff == _empty else diff
	if disp < 0 and diff < 0:
		return {}
	var ti := float(_v(info, "TextureInfluence"))
	var stype := int(SPLATTER_TYPES.get(str(_v(info, "SplatterType")), 1))
	var flags := (1 if stype & 16 else 0) | (2 if stype & 32 else 0) \
		| (4 if bool(_v(info, "bAbsoluteDeformation")) else 0) | (8 if bool(_v(info, "bSubtractive")) else 0) \
		| int({"ClothOnly": 16, "ClothNever": 32}.get(str(_v(info, "ClothingInteraction")), 0))
	var disp_scale := float(_v(info, "DisplacementScale"))
	return {
		"half_size": float(_v(info, "UVScale")) * 0.5 / 100.0,
		"depth": maxf(float(_v(info, "DepthScale")), 0.001) / 100.0,
		"fade_gain": 1.0 / clampf(1.0 - float(_v(info, "DepthFadeStart")), 1e-4, 1.0),
		"angle_wrap": clampf(float(_v(info, "AngleWrap")), 0.0, 1.0),
		"displacement_tex": disp,
		"diffuse_tex": diff,
		"flags": flags,
		"cloth_depth": float(_v(info, "ClothingDepthScale")),
		"cloth_displacement": float(_v(info, "ClothingDisplacementScale")),
		"wound_r": disp_scale * ti,
		"wound_g": float(_v(info, "FluidSplatterAmount")) * ti,
		"wound_b": float(_v(info, "BruisingAmount")) * ti,
		"fx_r": float(_v(info, "FluidDripsAmount")) * ti,
		"fx_g": float(_v(info, "CauterisationAmount")) * ti,
		"fx_b": ti,
		"fx_a": ti,
		"range_min": float(_v(info, "InputMinimum")),
		"range_size": float(_v(info, "InputRange")),
		"displacement": disp_scale,
	}


static func _v(info: Dictionary, key: String) -> Variant:
	return info[key] if info.has(key) else splatter["defaults"].get(key, 0.0)


# --- Stored sets ------------------------------------------------------------------------------------------------

## A DI2 SplatterSet (stored stamps in component space, converted to bind pose by build_splatter).
## Dismember-only and subtractive entries aren't drawn (recon/UNVERIFIED.md).
static func apply_set(gore: GoreBody, set_name: String, persistent: bool) -> int:
	_ensure()
	var made := 0
	for en: Dictionary in splatter["sets"].get(set_name, []):
		var info: Dictionary = en["info"]
		var stype := int(SPLATTER_TYPES.get(str(_v(info, "SplatterType")), 1))
		# DI2 clears (RE_DISMEMBER.md §9): ClearToValue 64 / ClearSplatter 80, whole sections.
		if stype == 64 or stype == 80:
			gore.clear_splatter(stype == 80, float(_v(info, "DisplacementClearValue")))
			continue
		var axes: Array = en["axes"]
		# Dismember entries (2 / 3): the limb is cut off at spawn (GoreBody.prespawn_dismember, DI2's mesh edit).
		if stype == 2 or stype == 3:
			var cut := gore.prespawn_dismember(int(_v(info, "BoneIndex")), _vec(en["loc"]), _vec(axes[0]), _vec(axes[1]), -_vec(axes[2]),
				float(_v(info, "UVScale")), params_for(info) if stype == 3 else {}, stype == 3)
			if cut != "":
				made += 1
				var z := gore.get_parent()
				if z and z.has_method("on_prespawn_cut"):
					z.on_prespawn_cut(cut)
			continue
		# Only types with the Decal bit paint (BoneBreak goes through DI2's re-skin pass).
		if stype & 1 == 0:
			continue
		var p := params_for(info)
		if p.is_empty():
			continue
		# DI2 decal frame from the stored Orientation R: projection R.X, image +u R.Y, image +v -R.Z.
		if gore.add_stamp_rest(p, _vec(en["loc"]), _vec(axes[0]), _vec(axes[1]), -_vec(axes[2]), persistent):
			made += 1
	return made


## The body mesh's DI2 CharacterInitialState (data/character_states.json): one of its InitialSplatterSetVariants
## goes on as persistent stamps. Which variant DI2 picks is native (taken as uniform random; UNVERIFIED #39).
## Returns the set applied ("" for none).
## A body's DI2 viscera / subsection / spawnable-part data (data/viscera_parts.json, tools/build_viscera_parts.py).
static func viscera_body(body_folder: String) -> Dictionary:
	if viscera_parts.is_empty() and FileAccess.file_exists("res://data/viscera_parts.json"):
		viscera_parts = Util.load_json("res://data/viscera_parts.json")
	return viscera_parts.get("bodies", {}).get(body_folder, {})


## A DI2 VisceraAsset (data/viscera_parts.json `viscera_assets`), with lookups cached on it.
static func viscera_asset(name: String) -> Dictionary:
	viscera_body("walker")
	var a: Dictionary = viscera_parts.get("viscera_assets", {}).get(name, {})
	if not a.is_empty() and not a.has("_by_key"):
		var by_key := {}
		for p: Dictionary in a.get("proxies", []):
			by_key[p["key"]] = p
		var by_id := {}
		for p: Dictionary in a.get("proxies", []):
			by_id[int(p.get("proxy_id", -1))] = p
		var variants := {}
		for v: Dictionary in a.get("switchable_variants", []):
			variants[v["key"]] = v
		a["_by_key"] = by_key
		a["_by_id"] = by_id
		a["_variants"] = variants
		# Rupture candidates (0x140ed1f80): every can_rupture proxy under a can_rupture group.
		var cands: Array = []
		for g: Dictionary in a.get("groups", []):
			if not g.get("can_rupture", false):
				continue
			var stack: Array = g.get("children", []).duplicate()
			while not stack.is_empty():
				var k: String = stack.pop_back()
				if by_key.has(k):
					var p: Dictionary = by_key[k]
					if p.get("can_rupture", false) and not cands.has(p):
						cands.append(p)
					stack.append_array(p.get("children", []).filter(func(c: String) -> bool: return by_key.has(c)))
				else:
					for sg: Dictionary in a.get("switchable_groups", []):
						if sg["key"] == k:
							for pid in sg.get("proxy_ids", []):
								if by_id.has(int(pid)) and by_id[int(pid)].get("can_rupture", false) and not cands.has(by_id[int(pid)]):
									cands.append(by_id[int(pid)])
		a["_candidates"] = cands
	return a


static func viscera_candidates(asset: Dictionary) -> Array:
	return asset.get("_candidates", [])


static func viscera_variant(asset: Dictionary, key: String) -> Dictionary:
	return asset.get("_variants", {}).get(key, {})


## The proxies that switch together with `proxy` (its VisceraSwitchableGroup), or just itself.
static func viscera_switch_group(asset: Dictionary, proxy: Dictionary) -> Array:
	var pid := int(proxy.get("proxy_id", -1))
	for sg: Dictionary in asset.get("switchable_groups", []):
		if pid in sg.get("proxy_ids", []).map(func(x) -> int: return int(x)):
			return sg["proxy_ids"].map(func(x) -> Dictionary: return asset["_by_id"].get(int(x), proxy))
	return [proxy]


## DI2 gradual damage effects (data/gradual_damage.json, tools/build_gradual_damage.py).
static var _gradual := {}
static func gradual_damage() -> Dictionary:
	if _gradual.is_empty() and FileAccess.file_exists("res://data/gradual_damage.json"):
		_gradual = Util.load_json("res://data/gradual_damage.json")
	return _gradual


## DI2 cosmetic effects with viscera / spawnable-part halves (data/viscera_parts.json `cosmetic_effects`).
static func viscera_effects() -> Dictionary:
	viscera_body("walker")
	return viscera_parts.get("cosmetic_effects", {})


static func character_state(body_folder: String) -> Dictionary:
	if character_states.is_empty() and FileAccess.file_exists("res://data/character_states.json"):
		character_states = Util.load_json("res://data/character_states.json")
	return character_states.get(body_folder, {})


static func apply_initial_state(gore: GoreBody, body_folder: String) -> String:
	var variants: Array = character_state(body_folder).get("splatter_variants", [])
	if variants.is_empty():
		return ""
	# A variant without a SplatterSet (null in character_states.json) spawns clean.
	var pick: String = str(variants[randi() % variants.size()].get("set", ""))
	if pick == "" or pick == "<null>":
		return ""
	apply_set(gore, pick, true)
	return pick


## DA_AnimSet_PreSpawnSplatter_<archetype>: the first group whose expression holds (PreSpawnSplatter_LeftArmMissing,
## StartingHealthFrac ...) picks one weighted item; its sets go on as persistent stamps. Returns the sets applied.
static func apply_prespawn(gore: GoreBody, archetype: String, facts: Dictionary) -> Array:
	_ensure()
	var applied := []
	for g: Dictionary in splatter["prespawn"].get(archetype, []):
		if g["items"].is_empty() or not DI2Expr.eval(g["expr"], facts):
			continue
		var items := []
		for it: Dictionary in g["items"]:
			items.append([float(it["weight"]), it["sets"]])
		for s: String in _weighted(items, 0, 1):
			apply_set(gore, s, true)
			applied.append(s)
		break
	return applied


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
