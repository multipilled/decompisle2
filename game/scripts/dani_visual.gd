class_name DaniVisual
extends Node3D
## Dani's (DI2 FemBerserker) first-person look, built from game/data/dani_materials.json (tools/build_dani_materials.py).
##  - Every SK_FemBerserkerFP section gets game/shaders/player.gdshader with its MI chain's resolved values and DI2's
##    exact cooked textures (all mips, original BCn formats, loaded raw from game/assets/di2/dani/flesh/).
##  - The FP mesh is rebuilt with all 8 cooked bone influences (the glb keeps 4) and the UE bind position (CUSTOM0)
##    the materials' 3D noise reads.
##  - DI2's component setup (BP_Base_Player): the FP mesh casts no shadow; the hidden third-person body
##    (SK_FemBerserker, bOwnerNoSee + bCastHiddenShadow) is the player's shadow and runs the same pose.
##  - UPlayerHandsMaterialComponent hand blood (staged textures + flow animation) and the CE_Player_Autophage
##    PlayerHandMaterial effect (Fury veins). Sources and open items: recon/DANI.md.
## Hook-up: player.gd `arm_mats = DaniVisual.attach(self, rig)`; melee code calls DaniVisual.of(player).on_melee_hit(crit).

const DATA := "res://data/dani_materials.json"
const SHADER := "res://shaders/player.gdshader"
const VARIANTS := {"skin_staged_veinmap": 0, "skin_staged_cheapveins": 1, "skin": 2, "cloth": 3, "cloth_staged": 4}
const TEX_UNIFORMS := {
	"Diffuse Colour Map": "tex_diffuse", "Normal Map": "tex_normal", "Packed MRO Map (see tooltip!)": "tex_mro",
	"Packed ATA Map (see tooltip!)": "tex_ata", "Detail Normal Map": "tex_detail_normal",
	"Detail Roughness Map": "tex_detail_rough", "Detail DRO Map": "tex_detail_rough",
	"Zombie Veins Normal Map": "tex_veins_normal", "Staged Blood Map": "tex_staged_blood",
	"CutScene Blood Map": "tex_cutscene_blood", "const TV_Global3dNoise": "tex_noise3d"}
const SCALAR_UNIFORMS := {
	"Detail Tiling": "detail_tiling", "Detail Normal Strength": "detail_normal_strength",
	"Detail Roughness Strength": "detail_roughness_strength", "Roughness Adjustment": "roughness_adjustment",
	"Specular Occlusion Power": "specular_occlusion_power", "Desaturation": "desaturation",
	"Translucency Adjustment": "translucency_adjustment", "Base Subsurface Scattering": "base_sss",
	"Vein Subsurface Scattering": "vein_sss", "ZombieVeinBlendWeight": "zombie_vein_blend_weight",
	"Larger Veins Move Less": "larger_veins_move_less", "Distortion Noise Scale": "distortion_noise_scale",
	"Pulse Noise Scale": "pulse_noise_scale", "Pulse Noise Range Min": "pulse_range_min",
	"Pulse Noise Range Max": "pulse_range_max", "Min UV Distortion": "min_uv_distortion",
	"Max UV Distortion": "max_uv_distortion", "Freeze Amount": "freeze_amount",
	"Zombie Vein Skin Distort Falloff": "vein_skin_distort_falloff",
	"Distortion Noise Affects Vein Intensity": "distortion_affects_vein_intensity",
	"Vein Intensity Min": "vein_intensity_min", "Vein Intensity Max": "vein_intensity_max",
	"Zombie Vein Base Normals Distort": "vein_base_normals_distort", "Zombie Vein Skin Distort": "vein_skin_distort",
	"Zombie Vein Base Normal Flatten Power": "vein_base_normal_flatten_power", "Vein Mask Erode": "vein_mask_erode",
	"BlendWeight Normals Curve": "blendweight_normals_curve", "Vein Roughness": "vein_roughness",
	"Splatter Animation Phase": "splatter_animation_phase", "StagedSplatterMetalBlendPow": "staged_metal_blend_pow",
	"Force Cloth": "force_cloth", "Cloth Translucency": "cloth_translucency",
	"Sheen Colour Averaging Amount": "sheen_averaging", "Sheen Colour Desaturation": "sheen_desaturation",
	"Sheen Colour Multiplier": "sheen_multiplier", "FuryDeathDesaturationOverride": "fury_death_desaturation_override"}
const MPC_UNIFORMS := {
	"StagedSplatterBloodDensity": "staged_blood_density", "StagedSplatterNormalsBlendThreshold": "staged_normals_blend_threshold",
	"StagedSplatterDynamicNormalsJitter": "staged_normals_jitter", "StagedSplatterDynamicNormalsStrength": "staged_normals_strength",
	"StagedSplatterEdgeContrast": "staged_edge_contrast", "StagedSplatterDriedBloodCavityPower": "staged_dried_cavity_power",
	"CutSceneHandBloodSplatter": "cutscene_hand_blood", "FurySkinRedIsolationScale": "fury_skin_red_isolation",
	"FurySkinRedDesaturation": "fury_skin_red_desat", "FurySkinNonRedDesaturation": "fury_skin_nonred_desat",
	"FuryClothNonRedDesaturation": "fury_cloth_nonred_desat", "ZombieVeinsCinematic": "zombie_veins_cinematic"}

var player: Node3D
var rig: Node3D
var skel: Skeleton3D
var data: Dictionary
var materials := {}            # MI name -> ShaderMaterial
var made: Array[ShaderMaterial] = []
var shader_one_sided: Shader
var shader_two_sided: Shader
var textures := {}             # texture name -> Texture2D / Texture3D
var skin8_ok := false
var skin8_note := ""

# --- PlayerHandsMaterialComponent state (recon/DANI.md 5) ---------------------------------------------------------------
var bloodiness := 0.0          # CurrentHandBloodinessValue
var blood_sections := []       # [{name, settings, mat, tex, phase}]
var flow_pending := false
var on_screen_since := 0.0
var increment_per_hit := 0.1   # MeleeArchetypeData.BloodinessIncrementPerHit (native default; no asset overrides it)
var critical_multiplier := 3.0
var stowed_time_for_clean := 5.0   # melee.StowedTimeForClean
var stowed_at := {}            # weapon id -> time it was put away
var last_weapon := ""
var autophage_keys: Array = []  # CE_Player_Autophage ZombieVeinBlendWeight curve
var vein_materials: Array[ShaderMaterial] = []

# --- third-person shadow body ------------------------------------------------------------------------------------------
var shadow_root: Node3D
var shadow_skel: Skeleton3D
var shadow_bone_map := PackedInt32Array()   # shadow bone -> FP bone (-1 = keep rest)


## Builds Dani's materials on the FP rig and returns them (player.gd keeps them as arm_mats).
static func attach(p: Node3D, rig_node: Node3D) -> Array[ShaderMaterial]:
	var v := DaniVisual.new()
	v.name = "DaniVisual"
	v.player = p
	v.rig = rig_node
	p.add_child(v)
	p.set_meta("dani_visual", v)
	v.build()
	return v.made


static func of(p: Node) -> DaniVisual:
	return p.get_meta("dani_visual") if p and p.has_meta("dani_visual") else null


func build() -> void:
	data = Util.load_json(DATA)
	shader_one_sided = load(SHADER)
	shader_two_sided = Shader.new()
	shader_two_sided.code = shader_one_sided.code.replace("render_mode cull_back,", "render_mode cull_disabled,")
	skel = Util.find_first(rig, "Skeleton3D")
	var native: Dictionary = data["hand_blood"]["native"]
	increment_per_hit = float(native["add_on_melee_hit"]["BloodinessIncrementPerHit_default"])
	critical_multiplier = float(native["add_on_melee_hit"]["critical_multiplier"])
	stowed_time_for_clean = float(native["melee.StowedTimeForClean"]["value"])
	for e: Dictionary in data["hand_blood"]["cosmetic_effects"]:
		if e["MaterialParameterName"] == "ZombieVeinBlendWeight":
			autophage_keys = e["curve_keys"]
	for mi: MeshInstance3D in Util.find_all(rig, "MeshInstance3D"):
		_build_mesh(mi)
	_setup_hand_blood()
	_build_shadow_body()
	process_priority = 100     # after player.gd has posed the rig this frame


# --- materials -----------------------------------------------------------------------------------------------------------

func _build_mesh(mi: MeshInstance3D) -> void:
	var src := mi.mesh as ArrayMesh
	if src == null:
		return
	var names: Array[String] = []
	for s in src.get_surface_count():
		var m := src.surface_get_material(s)
		names.append(m.resource_name if m else "")
	mi.mesh = _rebuild_skin8(src, _joint_to_bind(mi))
	# BP_Base_Player MeshFirstPerson: CastShadow false (the hidden TP body casts the player's shadow instead).
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for s in names.size():
		if not data["materials"].has(names[s]):
			push_warning("DaniVisual: no DI2 material data for section %s" % names[s])
			continue
		var mat := _material(names[s])
		mi.set_surface_override_material(s, mat)


func _material(name: String) -> ShaderMaterial:
	if materials.has(name):
		return materials[name]
	var e: Dictionary = data["materials"][name]
	var mat := ShaderMaterial.new()
	mat.resource_name = name
	mat.shader = shader_two_sided if bool(e["render"]["TwoSided"]["value"]) else shader_one_sided
	mat.set_shader_parameter("variant", VARIANTS[e["shader_variant"]])
	mat.set_shader_parameter("clip_value", float(e["render"]["OpacityMaskClipValue"]["value"]))
	var p: Dictionary = e["params"]
	for n: String in p["textures"]:
		var t: Dictionary = p["textures"][n]
		if t["used"] and t["value"] and TEX_UNIFORMS.has(n):
			var tex = _texture(t["value"])
			if tex:
				mat.set_shader_parameter(TEX_UNIFORMS[n], tex)
	for n: String in p["scalars"]:
		var sv = p["scalars"][n]["value"]
		if sv != null and SCALAR_UNIFORMS.has(n):
			mat.set_shader_parameter(SCALAR_UNIFORMS[n], float(sv))
	var sc: Dictionary = p["scalars"]
	if sc.has("Veins Normal Strength"):
		mat.set_shader_parameter("veins_normal_strength", _sv(sc, "Veins Normal Strength", 0.0) * _sv(sc, "Aggressive Veins Normal", 1.0))
	if sc.has("Veins Blood Density"):
		mat.set_shader_parameter("veins_blood_density", _sv(sc, "Veins Blood Density", 0.0) * _sv(sc, "Aggressive Veins Density", 1.0))
	var vec: Dictionary = p["vectors"]
	for n in ["Colour Tint", "Cloth Colour Tint"]:
		if vec.has(n) and vec[n]["value"] != null and vec[n]["used"]:
			var c: Array = vec[n]["value"]
			mat.set_shader_parameter("colour_tint", Vector3(c[0], c[1], c[2]))
	if vec.has("Veins Blood Colour") and vec["Veins Blood Colour"]["value"] != null:
		var c: Array = vec["Veins Blood Colour"]["value"]
		mat.set_shader_parameter("veins_blood_colour", Vector3(c[0], c[1], c[2]))
	for pair in [["Distortion Noise Speed", "distortion_noise_speed"], ["Pulse Noise Speed", "pulse_noise_speed"]]:
		if vec.has(pair[0]) and vec[pair[0]]["value"] != null:
			var c: Array = vec[pair[0]]["value"]
			mat.set_shader_parameter(pair[1], Vector3(c[0], c[1], c[2]))
	for pair in [["Distortion Noise Channel Mix", "distortion_mix_n"], ["Pulse Noise Channel Mix", "pulse_mix_n"]]:
		if vec.has(pair[0]) and vec[pair[0]]["value"] != null:
			mat.set_shader_parameter(pair[1], _channel_mix(vec[pair[0]]["value"]))
	for coll: String in data["mpc"]:
		for n: String in data["mpc"][coll]:
			var v = data["mpc"][coll][n]
			if MPC_UNIFORMS.has(n):
				mat.set_shader_parameter(MPC_UNIFORMS[n], float(v))
			elif n == "ChrFuryTint":
				mat.set_shader_parameter("fury_tint", Vector3(v[0], v[1], v[2]))
	var ssp = e.get("subsurface_profile")
	if ssp and data["subsurface_profiles"].has(ssp["value"]):
		mat.set_shader_parameter("sss_radius_m", _sss_radius_cm(data["subsurface_profiles"][ssp["value"]]) * 0.01)
	mat.set_shader_parameter("godot_sss_scale", float(ProjectSettings.get_setting(
		"rendering/environment/subsurface_scattering/subsurface_scattering_scale", 0.05)))
	if p["scalars"].has("ZombieVeinBlendWeight") and p["scalars"]["ZombieVeinBlendWeight"]["used"]:
		vein_materials.append(mat)
	materials[name] = mat
	made.append(mat)
	return mat


## Scatter radius of a SubsurfaceProfile in cm. Only overridden fields are serialised; the exe's default struct
## (recon/DEFERRED_LIGHTING.md 7.3) has bEnableBurley false, MeanFreePathDistance 2.6748, WorldUnitScale 0.1,
## ScatterRadius 1.2. Burley profiles (SSP_DefaultLightSkinFP) scatter over MeanFreePathDistance x WorldUnitScale cm
## (UE 4.27 property semantics: 0.1 = 1 unit is 1 mm; unverified in DI2's kernel build), separable ones over ScatterRadius.
static func _sss_radius_cm(p: Dictionary) -> float:
	if bool(p.get("bEnableBurley", false)):
		return float(p.get("MeanFreePathDistance", 2.6748)) * float(p.get("WorldUnitScale", 0.1))
	return float(p.get("ScatterRadius", 1.2))


static func _sv(sc: Dictionary, n: String, dflt: float) -> float:
	return float(sc[n]["value"]) if sc.has(n) and sc[n]["value"] != null else dflt


## M_Skin's preshader for the noise channel mixes (cb5[14] / cb5[21]): v / length(v / sqrt(v)), opcodes 20 = Sqrt and
## 22 = Length (recon/DANI.md 4.4; x/0 taken as 0, unverified).
static func _channel_mix(c: Array) -> Vector4:
	var v := Vector4(c[0], c[1], c[2], c[3])
	var q := Vector4()
	for i in 4:
		var s := sqrt(maxf(v[i], 0.0))
		q[i] = v[i] / s if s > 0.0 else 0.0
	var l := q.length()
	return v / l if l > 0.0 else Vector4()


func _texture(name: String):
	if textures.has(name):
		return textures[name]
	var t: Dictionary = data["textures"].get(name, {})
	var tex = null
	if t.has("file"):
		var path: String = t["file"]
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			push_warning("DaniVisual: missing %s" % path)
		elif path.ends_with(".dds"):
			var img := Image.new()
			if img.load_dds_from_buffer(bytes) == OK:
				tex = ImageTexture.create_from_image(img)
			else:
				push_warning("DaniVisual: cannot decode %s" % path)
		elif path.ends_with(".rgba3d"):
			var w := int(t["width"])
			var h := int(t["height"])
			var slices: Array[Image] = []
			for z in int(t["depth"]):
				slices.append(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes.slice(z * w * h * 4, (z + 1) * w * h * 4)))
			var t3 := ImageTexture3D.new()
			t3.create(Image.FORMAT_RGBA8, w, h, slices.size(), false, slices)
			tex = t3
	textures[name] = tex
	return tex


# --- 8 bone influences + UE bind position --------------------------------------------------------------------------------

## glTF skin joint index -> Godot skin bind index, by bone name (the importer does not keep the glTF joint order).
func _joint_to_bind(mi: MeshInstance3D) -> PackedInt32Array:
	var out := PackedInt32Array()
	var joints: Array = data["fp_mesh"]["skin8"].get("joints", [])
	var by_name := {}
	if mi.skin:
		for b in mi.skin.get_bind_count():
			var nm := str(mi.skin.get_bind_name(b))
			if nm == "" and skel and mi.skin.get_bind_bone(b) >= 0:
				nm = skel.get_bone_name(mi.skin.get_bind_bone(b))
			by_name[nm] = b
	for j in joints.size():
		out.append(by_name.get(joints[j], -1))
	return out


## CUSTOM0 = UE bind position in cm (glTF (x, z, y) m -> UE (x, y, z)): the TEXCOORD2/3 the materials' 3D noise reads.
static func _bind_cm(arrays: Array) -> void:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom := PackedFloat32Array()
	custom.resize(verts.size() * 4)
	for i in verts.size():
		custom[i * 4] = verts[i].x * 100.0
		custom[i * 4 + 1] = verts[i].z * 100.0
		custom[i * 4 + 2] = verts[i].y * 100.0
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	# the importer's CUSTOM1-3 hold glTF TEXCOORD_3+ (all zero: the cooked mesh has one UV channel); not used here
	arrays[Mesh.ARRAY_CUSTOM1] = null
	arrays[Mesh.ARRAY_CUSTOM2] = null
	arrays[Mesh.ARRAY_CUSTOM3] = null


## Rebuilds the FP surfaces with the cooked 8 influences (dani_fp.skin8.bin, glb vertex order) and the CUSTOM0 bind
## position. Falls back to the imported 4 influences if the vertex layout or the joint mapping doesn't match.
func _rebuild_skin8(src: ArrayMesh, j2b: PackedInt32Array) -> ArrayMesh:
	var bytes := FileAccess.get_file_as_bytes(data["fp_mesh"]["skin8"]["file"])
	var off := 0
	var dst := ArrayMesh.new()
	var agree := 0
	var total := 0
	var ok := not bytes.is_empty() and not j2b.is_empty() and not j2b.has(-1)
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var n: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		_bind_cm(arrays)
		var flags := Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		if ok and off + 4 <= bytes.size():
			# the record's vertices (glb order) on a 1 mm grid; Godot's importer reorders vertices, so match by position
			var count := bytes.decode_u32(off)
			off += 4
			var grid := {}
			for r in count:
				var at := off + r * 36
				var key := Vector3i((Vector3(bytes.decode_float(at), bytes.decode_float(at + 4), bytes.decode_float(at + 8)) * 1000.0).round())
				if not grid.has(key):
					grid[key] = []
				grid[key].append(at)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var old_b: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var old_w: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var per_old := old_b.size() / maxi(n, 1)
			var bones := PackedInt32Array()
			var weights := PackedFloat32Array()
			bones.resize(n * 8)
			weights.resize(n * 8)
			for i in n:
				var key := Vector3i((verts[i] * 1000.0).round())
				var rec := -1
				var best := 1e9
				for dx in range(-1, 2):
					for dy in range(-1, 2):
						for dz in range(-1, 2):
							for at in grid.get(key + Vector3i(dx, dy, dz), []):
								var d := verts[i].distance_squared_to(Vector3(bytes.decode_float(at), bytes.decode_float(at + 4), bytes.decode_float(at + 8)))
								if d < best:
									best = d
									rec = at
				if rec < 0:
					ok = false
					break
				for k in 8:
					var wk: float = bytes[rec + 28 + k] / 255.0
					bones[i * 8 + k] = j2b[bytes.decode_u16(rec + 12 + k * 2)] if wk > 0.0 else 0
					weights[i * 8 + k] = wk
				# the cooked 4 heaviest must be the imported 4 influences
				var a := {}
				for k in per_old:
					if old_w[i * per_old + k] > 0.0:
						a[old_b[i * per_old + k]] = true
				var b := {}
				for k in 4:
					if weights[i * 8 + k] > 0.0:
						b[bones[i * 8 + k]] = true
				agree += int(a.keys().all(func(x): return b.has(x)) and a.size() == b.size())
				total += 1
			off += count * 36
			arrays[Mesh.ARRAY_BONES] = bones
			arrays[Mesh.ARRAY_WEIGHTS] = weights
			flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		else:
			ok = false
		dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
		dst.surface_set_name(s, src.surface_get_name(s))
		dst.surface_set_material(s, src.surface_get_material(s))
	skin8_ok = ok and total > 0 and agree >= int(total * 0.99)
	skin8_note = "8 influences: %s (top-4 agreement %d/%d)" % ["on" if skin8_ok else "OFF", agree, total]
	if not skin8_ok:
		push_warning("DaniVisual: " + skin8_note + "; keeping the imported 4-influence mesh")
		var keep := ArrayMesh.new()
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			_bind_cm(arrays)
			keep.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
				Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			keep.surface_set_material(s, src.surface_get_material(s))
		return keep
	return dst


# --- hand blood (UPlayerHandsMaterialComponent) -----------------------------------------------------------------------------

func _setup_hand_blood() -> void:
	var settings: Dictionary = data["hand_blood"]["BloodSettings"]
	var secs: Array = data["fp_mesh"]["sections"]
	for hd: Dictionary in data["fp_mesh"]["character_material_masks"]["PlayerHandsData"]:
		var key: String = hd["BloodSettingsName"]
		if key == "None" or not settings.has(key):
			continue
		var mname: String = secs[int(hd["SectionID"])]["material"]
		if not materials.has(mname):
			continue
		var e: Dictionary = data["materials"][mname]
		var cur = e["params"]["textures"].get("Staged Blood Map", {}).get("value")
		var phase := _sv(e["params"]["scalars"], "Splatter Animation Phase", 0.5)
		blood_sections.append({"name": mname, "settings": settings[key], "mat": materials[mname], "tex": cur, "phase": phase})
		materials[mname].set_shader_parameter("splatter_animation_phase", phase)
	_on_rep()


## A melee weapon hit landed (DI2 weapon on-hit -> AddHandBloodiness): + BloodinessIncrementPerHit, x3 on a critical.
func on_melee_hit(critical := false, increment := -1.0) -> void:
	add_bloodiness((increment_per_hit if increment < 0.0 else increment) * (critical_multiplier if critical else 1.0))


func add_bloodiness(delta: float) -> void:
	var v := clampf(bloodiness + delta, 0.0, 1.0)
	if v != bloodiness:
		bloodiness = v
		_on_rep()


## DI2 FUN_141823630 / FUN_1416eaa20: hands back to clean.
func clean_hands() -> void:
	if bloodiness > 0.0:
		bloodiness = 0.0
		_on_rep()


## OnRep_CurrentHandBloodinessValue: per section, the highest stage whose RequiredScore <= value; a change resets the
## flow phase to 0 and queues the flow animation.
func _on_rep() -> void:
	for s: Dictionary in blood_sections:
		var want := ""
		for st: Dictionary in s["settings"]["stages_highest_to_lowest"]:
			if float(st["RequiredScore"]) <= bloodiness:
				want = st["texture"]
				break
		if want != "" and want != s["tex"]:
			s["tex"] = want
			s["mat"].set_shader_parameter("tex_staged_blood", _texture(want))
			s["phase"] = 0.0
			s["mat"].set_shader_parameter("splatter_animation_phase", 0.0)
			flow_pending = true


func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# On-screen time of the hands (DI2 reads a timestamp from the owner, recon/DANI.md 5.3: taken as "rig visible since").
	if rig and not rig.is_visible_in_tree():
		on_screen_since = now
	if flow_pending:
		_flow(delta, now)
	_stow_clean(now)
	_autophage()
	_pose_shadow_body()


## TickComponent flow animation (FUN_14182b780 / FUN_141559630).
func _flow(delta: float, now: float) -> void:
	flow_pending = false
	for s: Dictionary in blood_sections:
		var st: Dictionary = s["settings"]
		if float(s["phase"]) == 0.0 and now - on_screen_since < float(st["RequiredOnScreenTimeBeforeAnimation"]):
			flow_pending = true
			return
		var raw := float(s["phase"]) + delta / maxf(float(st["FlowAnimationDuration"]), 1.1920929e-07)
		s["phase"] = clampf(raw, 0.0, 1.0)
		s["mat"].set_shader_parameter("splatter_animation_phase", s["phase"])
		flow_pending = flow_pending or raw < 1.0


## FUN_141700550: equipping a weapon that was stowed longer than melee.StowedTimeForClean cleans weapon and hands.
func _stow_clean(now: float) -> void:
	var w = player.get("weapon") if player else null
	if w == null:
		return
	var cur := str(w)
	if cur == last_weapon:
		return
	if last_weapon != "":
		stowed_at[last_weapon] = now
	if stowed_at.has(cur) and now - float(stowed_at[cur]) > stowed_time_for_clean:
		clean_hands()
	last_weapon = cur


## CE_Player_Autophage (CosmeticEffect_PlayerHandMaterial): ZombieVeinBlendWeight = curve(OverallFuryProgress) while Fury
## runs. OverallFuryProgress is taken as the elapsed fraction of the port's Fury timer (unverified, recon/DANI.md 5.4).
func _autophage() -> void:
	var moves = player.get("moves") if player else null
	var active: bool = moves != null and bool(moves.get("fury_active"))
	var w := 0.0
	if active:
		w = _curve(autophage_keys, 1.0 - float(player.get("fury")))
	for m in vein_materials:
		m.set_shader_parameter("zombie_vein_blend_weight", w)


## UE FRichCurve, cubic keys (Hermite with the stored tangents).
static func _curve(keys: Array, t: float) -> float:
	if keys.is_empty():
		return 0.0
	if t <= float(keys[0]["time"]):
		return float(keys[0]["value"])
	for i in range(1, keys.size()):
		var k0: Dictionary = keys[i - 1]
		var k1: Dictionary = keys[i]
		if t <= float(k1["time"]):
			var dt := float(k1["time"]) - float(k0["time"])
			var u := (t - float(k0["time"])) / dt
			var p0 := float(k0["value"])
			var p1 := float(k1["value"])
			var m0 := float(k0["leave"]) * dt
			var m1 := float(k1["arrive"]) * dt
			var u2 := u * u
			var u3 := u2 * u
			return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
	return float(keys[-1]["value"])


# --- hidden third-person shadow body ------------------------------------------------------------------------------------

## BP_Base_Player CharacterMesh0 (SK_FemBerserker): bOwnerNoSee + bCastHiddenShadow, same AnimClass as the FP mesh
## (ABP_PlayerCharacter_1P) -> in first person it is invisible but casts the player's shadow with the FP pose.
func _build_shadow_body() -> void:
	var path: String = data["tp_shadow_mesh"].get("glb", "")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if path == "" or doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		push_warning("DaniVisual: no third-person shadow body (%s)" % path)
		return
	shadow_root = doc.generate_scene(state)
	shadow_root.top_level = true
	add_child(shadow_root)
	shadow_skel = Util.find_first(shadow_root, "Skeleton3D")
	for mi: MeshInstance3D in Util.find_all(shadow_root, "MeshInstance3D"):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			mi.set_surface_override_material(s, _shadow_material(m.resource_name if m else ""))
	if shadow_skel and skel:
		shadow_bone_map.resize(shadow_skel.get_bone_count())
		for b in shadow_skel.get_bone_count():
			shadow_bone_map[b] = skel.find_bone(shadow_skel.get_bone_name(b))


## Depth-only material for the shadow pass: DI2's opacity mask (ATA.r, hair data .a) with the MI's clip value;
## translucent sections cast no shadow (UE default for translucency).
func _shadow_material(name: String) -> ShaderMaterial:
	var e: Dictionary = data["materials"].get(name, {})
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	var blend: String = e.get("render", {}).get("BlendMode", {}).get("value", "BLEND_Opaque")
	var two: bool = e.get("render", {}).get("TwoSided", {}).get("value", false)
	var tex = null
	var chan := 0
	for pair in [["Packed ATA Map (see tooltip!)", 0], ["Packed Hair Data Map", 3]]:
		var t: Dictionary = e.get("params", {}).get("textures", {}).get(pair[0], {})
		if t.get("used", false) and t.get("value"):
			tex = _texture(t["value"])
			chan = pair[1]
	var code := "shader_type spatial;\nrender_mode unshaded, %s;\nuniform sampler2D mask : filter_linear_mipmap, repeat_enable;\n" % ("cull_disabled" if two else "cull_back")
	code += "uniform int chan = 0;\nuniform float clip_value = 0.3333;\nuniform bool has_mask = false;\nuniform bool translucent = false;\n"
	code += "void fragment() {\n\tif (translucent) { discard; }\n\tALBEDO = vec3(0.0);\n"
	code += "\tif (has_mask) { ALPHA = texture(mask, UV)[chan]; ALPHA_SCISSOR_THRESHOLD = clip_value; }\n}\n"
	sh.code = code
	mat.shader = sh
	mat.set_shader_parameter("translucent", blend == "BLEND_Translucent")
	if tex and blend == "BLEND_Masked":
		mat.set_shader_parameter("mask", tex)
		mat.set_shader_parameter("chan", chan)
		mat.set_shader_parameter("has_mask", true)
		mat.set_shader_parameter("clip_value", float(e["render"]["OpacityMaskClipValue"]["value"]))
	return mat


## Same pose as the FP mesh, but standing on the capsule: the port pitches the FP rig with the camera, DI2 attaches
## both meshes to the capsule, so the head pitch is taken out of the shadow body's transform.
func _pose_shadow_body() -> void:
	if shadow_root == null or skel == null:
		return
	shadow_root.visible = rig.is_visible_in_tree()
	var head: Node3D = player.get("head")
	var cam: Node3D = player.get("camera")
	if head and cam:
		shadow_root.global_transform = player.global_transform * Transform3D(Basis.IDENTITY, head.position) * cam.transform * rig.transform
	if shadow_skel:
		for b in shadow_bone_map.size():
			var fb := shadow_bone_map[b]
			if fb >= 0:
				shadow_skel.set_bone_pose_position(b, skel.get_bone_pose_position(fb))
				shadow_skel.set_bone_pose_rotation(b, skel.get_bone_pose_rotation(fb))
				shadow_skel.set_bone_pose_scale(b, skel.get_bone_pose_scale(fb))
