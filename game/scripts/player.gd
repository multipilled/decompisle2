class_name Player
extends CharacterBody3D
## Dani (DI2's FemBerserker) in first person.
## Core: stats, movement, camera, animation playback and input routing. The moves live in
## player_melee.gd (DI2 standard/heavy attacks, impacts, rebounds), player_moves.gd (kicks, stomps,
## dodges, blocks + counters, drop kick, ground pound, weapon throw, curveballs, Fury, grapples, medkits)
## and player_ranged.gd (pistol). Numbers come from data/weapons.json and data/combat.json (DI2 data).

const DANI := preload("res://assets/di2/dani/dani_fp.glb")
## Weapon slots for testing (any DI2 weapon can be swapped in from the F3 catalogue).
const DEFAULT_LOADOUT := ["bat", "machete", "pistol"]
## Horizontal FOV like Unreal.
const BASE_FOV := 95.0
const ADS_FOV := 68.0
const LOOP_HINTS := ["_idle", "_walk", "_sprint", "_move_walk_f", "_move_sprint", "_charge_loop", "_heavy_hold",
	"_block_idle", "blocking_onehanded_idle", "blocking_twohanded_idle", "blocking_onehandedpistol_idle",
	"_ads_idle", "_walk_ads", "_throw_loop", "falling_loop", "groundpound_loop", "grapple_loop_close", "fury_idle"]

var data: Dictionary
var combat: Dictionary
var clip_info: Dictionary
var head: Node3D
var camera: Camera3D
var rig: Node3D
var rig_skel: Skeleton3D
var rig_anim: AnimationPlayer     # clip library only; DI2Anim drives the skeleton
var anim: DI2Anim
var cam_bone := -1
var cam_align := Basis.IDENTITY
var cam_rest := Basis.IDENTITY
var weapon_attach: BoneAttachment3D
var weapon_nodes := {}
var weapon_mats := {}
var weapon_blade := {}    # weapon -> [grip_local, tip_local] along the mesh's long axis
var arm_mats: Array = []
var weapon_skel := {}     # weapon -> its Skeleton3D (sockets hang off WP_Root / WP_Offset)
var weapon_anims := {}    # weapon -> AnimationPlayer of the gun mesh (slide / magazine), when it has one
var loadout: Array = DEFAULT_LOADOUT.duplicate()
var ammo := {}            # ranged weapon -> [mag, reserve] while holstered
var loaded_bases := {}    # class animation glbs merged into the rig ("medium2h", "short1h", ...)
## DI2 Requester KB IsHeadStompUnlocked (a skill); on for testing.
var head_stomp_unlocked := true
var catalog_open := false
var catalog_i := 0
var catalog_ids: Array = []
var weapon := "bat"
var weapon_away := {}     # weapon -> true while thrown and lying in the world

# Stats (DA_CharacterAttributeValues_Berserker_Female)
var level := 1
var max_health := 110.0
var health := 110.0
var max_stamina := 120.0
var stamina := 120.0
var stamina_delay := 0.0
var fury := 0.0
var medkits := 3
var dead := false
var durability := {}
var max_durability := {}
var mag := 15
var reserve := 90

# State machine
var state := "ready"
var state_t := 0.0
var move_scale := 1.0
var move_override := Vector3.ZERO
var override_t := 0.0
var lmb_held := false
var lmb_t := 0.0
var rmb_held := false
var was_on_floor := true
var air_t := 0.0

var melee: PlayerMelee
var moves: PlayerMoves
var ranged: PlayerRanged

# Camera / feedback
var pitch := 0.0
var shake := 0.0
var fov_kick := 0.0
var cam_anim_weight := 0.6
## BP_Base_Player CDO HeavyAttackHoldTransitionTime. BP_Base_MeleeWeaponItem registers it as the "Decision"
## playrate duration (AddPlayrateDuration bytecode), so a standard attack's Decision section lasts this long.
const HEAVY_ATTACK_HOLD_TRANSITION_TIME := 0.75
## Player state machine "UpperBody" of ABP_PlayerCharacter_1P (data/anim_graphs.json).
const UPPER_BODY_SM := "UpperBody"
## Paired animations (grapple, counter): the camera leans with camera_root (translation) and keeps a share of its
## rotation, while the moves module frames the zombie's face.
const PAIRED_CAM_WEIGHT := 0.25
var paired_cam := 0.0
var cam_rest_origin := Vector3.ZERO
const RIG_TO_CAM := Basis(Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0))
var roll := 0.0
var hurt_flash := 0.0
var hurt_dir := 0.0
var hurt_dir_t := 0.0
var hitmarker := 0.0
var hitmarker_kill := 0.0
var message := ""
var message_t := 0.0
var hint := ""
var hint_t := 0.0
var spawn_point := Vector3.ZERO
var popups: Array = []    # damage popups for the HUD: {pos, text, kind, t}


func _ready() -> void:
	data = Util.load_json("res://data/weapons.json")
	# Each weapon's animation class id. tools/build_class_data.py writes "class_id" into weapons.json, but a later
	# tools/build_weapons.py run rewrites the file without it, which left every weapon without its anim class (the
	# arms stood in the rest pose). The id is derived from the weapon's DI2 class asset, as that tool does.
	for w_id in data:
		var spec = data[w_id]
		if spec is Dictionary and str(spec.get("class_id", "")) == "" and str(spec.get("class", "")) != "":
			spec["class_id"] = ClassData.id_for(spec["class"])
	combat = Util.load_json("res://data/combat.json")
	clip_info = Util.load_json("res://assets/di2/dani/dani_fp.anims.json")
	var attrs: Dictionary = combat["dani"]["attributes"]
	max_health = attrs.get("MaxHealth", 110.0)
	max_stamina = attrs.get("StaminaMax", 120.0)
	health = max_health
	stamina = max_stamina
	spawn_point = global_position
	collision_layer = Util.PLAYER
	collision_mask = Util.WORLD | Util.ZOMBIE
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.33
	cap.height = 1.75
	cs.shape = cap
	cs.position.y = 0.875
	add_child(cs)

	head = Node3D.new()
	head.position.y = 1.62
	add_child(head)
	camera = Camera3D.new()
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.fov = BASE_FOV
	camera.near = 0.02
	camera.current = true
	head.add_child(camera)

	rig = DANI.instantiate()
	camera.add_child(rig)
	rig_skel = Util.find_first(rig, "Skeleton3D")
	rig_anim = Util.find_first(rig, "AnimationPlayer")
	rig_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	for a in rig_anim.get_animation_list():
		for hint_suffix in LOOP_HINTS:
			if a.ends_with(hint_suffix) or a.contains(hint_suffix):
				rig_anim.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	# Unreal 1P rigs look along +X with right = +Z; the camera bone is pinned to the Godot camera and its
	# animated rotation (swing follow-through, recoil) is fed back to the camera like UE's camera attachment.
	anim = DI2Anim.new(rig_skel, rig_anim)
	cam_bone = rig_skel.find_bone("camera_root")
	cam_rest = rig_skel.get_bone_global_rest(cam_bone).basis.orthonormalized()
	cam_rest_origin = rig_skel.get_bone_global_rest(cam_bone).origin
	cam_align = RIG_TO_CAM * cam_rest
	arm_mats = DaniVisual.attach(self, rig)   # DI2 FemBerserker materials, skin, shadow body, hand blood (dani_visual.gd)

	weapon_attach = BoneAttachment3D.new()
	weapon_attach.bone_name = "weapon_01_r"
	rig_skel.add_child(weapon_attach)
	for w_id in loadout:
		_ensure_weapon(w_id)
	catalog_ids = data.keys().filter(func(k): return data[k] is Dictionary and data[k].has("kind") and data[k].get("class_id", "") != "")
	catalog_ids.sort_custom(func(a, b): return [data[a]["kind"], str(data[a].get("base")), data[a]["name"]] < [data[b]["kind"], str(data[b].get("base")), data[b]["name"]])

	melee = PlayerMelee.new(self)
	moves = PlayerMoves.new(self)
	ranged = PlayerRanged.new(self)
	equip("bat", true)


## Loads a weapon's mesh, materials and gun animations the first time it is needed.
func _ensure_weapon(w_id: String) -> void:
	if weapon_nodes.has(w_id) or not data.has(w_id):
		return
	var spec: Dictionary = data[w_id]
	# Hand weapons (bare hands, DI2's FuryFists) have no mesh: an empty node stands in for it.
	var has_mesh: bool = spec.get("mesh", "") != "" and ResourceLoader.exists(spec["mesh"])
	if not has_mesh and spec.get("mesh_asset", "") != "":
		push_warning("weapon %s: mesh %s not found" % [w_id, spec["mesh"]])
	var inst: Node3D = load(spec["mesh"]).instantiate() if has_mesh else Node3D.new()
	weapon_attach.add_child(inst)
	inst.visible = false
	weapon_nodes[w_id] = inst
	weapon_mats[w_id] = Util.apply_prop_materials(inst, spec["mesh"].get_basename() + ".materials.json") if has_mesh else []
	weapon_skel[w_id] = Util.find_first(inst, "Skeleton3D")
	weapon_anims[w_id] = Util.find_first(inst, "AnimationPlayer")
	weapon_blade[w_id] = _blade_axis(inst)
	if spec.has("durability"):
		max_durability[w_id] = float(spec["durability"][1])
		durability[w_id] = max_durability[w_id]
	if spec["kind"] == "ranged":
		# Magazine: the gun's InventoryClipAmmoHandler.AmmoCapacity. Reserve: 5 magazines for testing (DI2's
		# reserve is inventory ammo, not a weapon value).
		var cap := int(spec.get("magazine", 12))
		var m = spec.get("modules")
		if m is Dictionary and not m.get("InlineAmmoConfigsWithSupportedFireModes", []).is_empty():
			var ah = m["InlineAmmoConfigsWithSupportedFireModes"][0].get("AmmoHandler", {})
			var c = ah.get("AmmoCapacity") if ah is Dictionary else null
			if c is Dictionary:
				c = c.get("Value")
			if c != null:
				cap = int(c)
		ammo[w_id] = [cap, cap * 5]


## The weapon's DI2 class (data/classes/<class_id>.json); its animations are merged into the rig on first use.
func cls(w_id := "") -> ClassData:
	var spec: Dictionary = data.get(w_id if w_id != "" else weapon, {})
	var c := ClassData.load_class(spec.get("class_id", ""))
	if c:
		ensure_class_anims(c)
	return c


func ensure_class_anims(c: ClassData) -> void:
	if loaded_bases.has(c.base) or not ResourceLoader.exists(c.glb):
		return
	loaded_bases[c.base] = true
	var src: Node = load(c.glb).instantiate()
	var ap: AnimationPlayer = Util.find_first(src, "AnimationPlayer")
	var lib: AnimationLibrary = rig_anim.get_animation_library("")
	for a in ap.get_animation_list():
		if lib.has_animation(a):
			continue
		var anim: Animation = ap.get_animation(a).duplicate()
		for hint_suffix in LOOP_HINTS:
			if a.ends_with(hint_suffix) or a.contains(hint_suffix):
				anim.loop_mode = Animation.LOOP_LINEAR
		lib.add_animation(a, anim)
	src.free()
	var report_path := c.glb.get_basename() + ".anims.json"
	if FileAccess.file_exists(report_path):
		clip_info.merge(Util.load_json(report_path))


## Clip DI2 plays for a class slot (e.g. "Select", "PlayerKnockbacks"), "" when the rig doesn't have it.
func slot_clip(slot: String, role := "main", facts := {}) -> String:
	var c := cls()
	if c == null:
		return ""
	var n := c.clip(slot, role, facts)
	return n if has_clip(n) else ""


## Weapons without TrailStart/TrailEnd sockets (hands, claws) strike with the hands.
func uses_hands(w_id: String) -> bool:
	return not data[w_id].get("sockets", {}).has("TrailStart")


## World-space blade segment [near the grip, tip] from the weapon's DI2 TrailEnd / TrailStart sockets.
func blade_points(w_id: String) -> Array:
	var sk: Skeleton3D = weapon_skel.get(w_id)
	var socks: Dictionary = data[w_id].get("sockets", {})
	if sk and socks.has("TrailStart") and socks.has("TrailEnd"):
		var pts := []
		for nm in ["TrailEnd", "TrailStart"]:
			var so: Dictionary = socks[nm]
			var bi := sk.find_bone(so["bone"])
			if bi < 0:
				break
			pts.append(sk.global_transform * sk.get_bone_global_pose(bi) * Vector3(so["pos"][0], so["pos"][1], so["pos"][2]))
		if pts.size() == 2:
			return pts
	var node: Node3D = weapon_nodes[w_id]
	var blade: Array = weapon_blade[w_id]
	return [node.global_transform * (blade[0] as Vector3), node.global_transform * (blade[1] as Vector3)]


## Long axis of a weapon mesh (weapon-root space): grip end near the hand, tip far from it. Only used when a
## mesh has no TrailStart/TrailEnd sockets.
func _blade_axis(inst: Node3D) -> Array:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var inv := inst.global_transform.affine_inverse()
	for mi: MeshInstance3D in Util.find_all(inst, "MeshInstance3D"):
		var aabb := mi.get_aabb()
		for i in 8:
			var c := inv * (mi.global_transform * aabb.get_endpoint(i))
			lo = lo.min(c)
			hi = hi.max(c)
	var size := hi - lo
	var axis := 0
	if size.y > size[axis]:
		axis = 1
	if size.z > size[axis]:
		axis = 2
	var mid := (lo + hi) * 0.5
	var a := mid
	var b := mid
	a[axis] = lo[axis]
	b[axis] = hi[axis]
	return [a, b] if a.length() < b.length() else [b, a]


# --- Helpers used by the move modules ---------------------------------------------------------------

func w() -> Dictionary:
	return data[weapon]


func wc() -> Dictionary:
	return combat["classes"].get(weapon, {})


## Gun-mesh AnimationPlayer of the held weapon (slide, magazine), or null.
func weapon_anim() -> AnimationPlayer:
	return weapon_anims.get(weapon)


func is_melee() -> bool:
	return w()["kind"] == "melee"


## Animation family of the held weapon's class (medium2h, short1h, handgun, ...).
func base() -> String:
	var c := cls()
	return c.base if c else ""


func has_clip(name: String) -> bool:
	return name != "" and rig_anim.has_animation(name)


func clip_len(name: String) -> float:
	return rig_anim.get_animation(name).length if has_clip(name) else 0.0


## Plays a bare clip in the montage slot with DI2's default montage blends (0.1 s HermiteCubic in and out, exe
## UAnimMontage ctor 0x1434b3ee0). Only for actions without DI2 montage data here; class actions use play_role.
func play(name: String, _blend := 0.12, speed := 1.0) -> bool:
	return has_clip(name) and anim.play_clip(name, speed) != null


## Plays a class item role ({"m": montage, "clips": [...]}) as its DI2 montage: DI2's BlendIn / BlendOut,
## sections, segments and playrate windows (data/montages.json). A role without montage data plays its first clip.
func play_role(role, rate := 1.0, start := 0.0) -> DI2Anim.Montage:
	if not role is Dictionary or role.is_empty():
		return null
	var mn := str(role.get("m", ""))
	if mn != "" and DI2Anim.montages.has(mn):
		var segs: Array = DI2Anim.montages[mn]["segments"]
		if not segs.is_empty() and segs.all(func(sg): return has_clip(sg[0])):
			return anim.play_montage(mn, rate, start)
	var clips: Array = role.get("clips", [])
	if not clips.is_empty() and has_clip(clips[0]):
		return anim.play_clip(clips[0], rate)
	return null


## Plays `role` when montage `m` starts blending out (in the same animation update, see DI2Anim.play_after);
## plays it now when `m` is gone. `cb` receives the new montage instance.
func play_role_after(m: DI2Anim.Montage, role, cb: Callable = Callable(), rate := 1.0, start := 0.0) -> bool:
	if not role is Dictionary or role.is_empty():
		return false
	var mn := str(role.get("m", ""))
	var ok: bool = mn != "" and DI2Anim.montages.has(mn) and DI2Anim.montages[mn]["segments"].all(func(sg): return has_clip(sg[0]))
	if ok and m != null and not m.stopped:
		return anim.play_after(m, mn, rate, start, cb)
	var nm := play_role(role, rate, start)
	if nm and cb.is_valid():
		cb.call(nm)
	return nm != null


## The role of the item DI2 picks for a class slot ({} when the class has none).
func slot_role(slot: String, role := "main", facts := {}) -> Dictionary:
	var c := cls()
	var it := c.pick(slot, facts) if c else {}
	var r = it.get(role)
	return r if r is Dictionary else {}


## The playing (not blending-out) montage, or null.
func montage() -> DI2Anim.Montage:
	return anim.active()


## True once montage `m` has started blending out (UE OnMontageBlendingOut) or is gone.
func montage_done(m: DI2Anim.Montage) -> bool:
	return m == null or m.stopped or m.pos >= m.length - 1e-3


## Clip currently shown in front (the montage over the base state), for logs and tests.
func cur_clip() -> String:
	var m := anim.active()
	if m:
		return m.current_clip()
	var src = anim.state_src()
	if src is DI2Anim.Seq:
		return src.clip
	if src is DI2Anim.BS and not src.samples.is_empty():
		var best := 0
		for i in src.weights.size():
			if src.weights[i] > src.weights[best]:
				best = i
		return src.samples[best][0]
	return ""


func first_clip(names: Array) -> String:
	for n: String in names:
		if has_clip(n):
			return n
	return ""


func set_state(s: String) -> void:
	state = s
	state_t = 0.0


func say(text: String, seconds := 2.0) -> void:
	message = text
	message_t = seconds


func show_hint(text: String, seconds := 0.6) -> void:
	hint = text
	hint_t = seconds


func use_stamina(amount: float) -> void:
	stamina = max(0.0, stamina - amount)
	stamina_delay = float(data["player"]["stamina_regen_delay"])


func add_shake(amount: float) -> void:
	shake = max(shake, amount)


func hit_pause(seconds: float, scale := 0.05) -> void:
	Engine.time_scale = Main.time_scale * scale
	await get_tree().create_timer(seconds, true, false, true).timeout
	Engine.time_scale = Main.time_scale


func popup(pos: Vector3, text: String, kind := "default") -> void:
	popups.append({"pos": pos, "text": text, "kind": kind, "t": 0.0})


# --- DI2 knowledge-base facts --------------------------------------------------------------------------
## Primitive values DI2's expression aliases are written against (data/expression_aliases.json:
## ScalpContext, DownContext, UpContext, HeavyGroundContext, Knockback*, StartOnLeft, ...). Everything that
## isn't directly measurable here is listed in recon/UNVERIFIED.md.

## DI2 CharacterContext of a zombie bone (Core/CharacterContexts/DA_Context_*), light or heavy set.
const LIGHT_CONTEXT := {"head": "Head", "neck_01": "Head", "neck_02": "Head", "spine_05": "Torso", "spine_04": "Torso",
	"spine_03": "Torso", "spine_02": "Stomach", "spine_01": "Stomach", "pelvis": "Stomach",
	"upperarm_l": "LeftArm_Upper", "lowerarm_l": "LeftArm_Lower", "hand_l": "LeftHand",
	"upperarm_r": "RightArm_Upper", "lowerarm_r": "RightArm_Lower", "hand_r": "RightHand",
	"thigh_l": "LeftLeg_Upper", "calf_l": "LeftLeg_Lower", "foot_l": "LeftFoot",
	"thigh_r": "RightLeg_Upper", "calf_r": "RightLeg_Lower", "foot_r": "RightFoot"}
## Stand-ins until DI2's native weapon camera-pitch thresholds are recovered (recon/UNVERIFIED.md).
const WEAPON_LOW_PITCH := -28.0
const WEAPON_UP_PITCH := 24.0
const WEAPON_FLOOR_PITCH := -60.0


static var contexts := {}
const LIGHT_SET := ["Head", "Torso", "Stomach", "LeftArm_Upper", "LeftArm_Lower", "LeftHand", "RightArm_Upper",
	"RightArm_Lower", "RightHand", "LeftLeg_Upper", "LeftLeg_Lower", "LeftFoot", "RightLeg_Upper", "RightLeg_Lower", "RightFoot"]
## DA_*MeleeAutoAimSettings: ContextSelectErrorDistance 1.5 (Scalar), DynamicContextScaleMultipliers.GlobalScaleMultiplier 1.5.
const CONTEXT_ERROR := 1.5
const CONTEXT_SCALE := 1.5


## DI2 aim-target context for a zombie (data/character_contexts.json = Core/CharacterContexts/DA_Context_*):
## every context of the light or heavy set is scored by how far its point sits from the crosshair on screen,
## in units of its radius (WorldSpaceRadius, else the bone's hitbox radius as DI2 uses mesh collision there),
## within the auto-aim error distance, divided by its AutoAimBonusScoreWeighting; the best one wins, then its
## children replace it when their conditions hold. The scoring formula itself is native (recon/UNVERIFIED.md).
func select_context(z: Zombie, heavy: bool) -> Dictionary:
	if contexts.is_empty():
		contexts = Util.load_json("res://data/character_contexts.json")
	var centre := get_viewport().get_visible_rect().size * 0.5
	var focal := centre.x / tan(deg_to_rad(camera.fov) * 0.5)
	var best := {}
	var best_score := INF
	var names: Array = LIGHT_SET if not heavy else LIGHT_SET.map(func(n): return n + "_Heavy") + ["Neck_Heavy"]
	for n: String in names:
		var key := "DA_Context_" + n
		if not contexts.has(key):
			continue
		var cdef: Dictionary = contexts[key]
		var bone_name: String = cdef["bone"] if cdef["bone"] != null else ("thigh_l" if n.contains("LeftLeg_Upper") else "thigh_r")
		var bi := z.skeleton.find_bone(bone_name)
		if bi < 0 or z.hitboxes.all(func(a): return not is_instance_valid(a) or a.get_meta("bone") != bone_name) and not n.begins_with("Torso") and not n.begins_with("Stomach") and not n.begins_with("Neck"):
			continue
		var pt := _context_point(z, bone_name)
		if camera.is_position_behind(pt):
			continue
		var dist := camera.global_position.distance_to(pt)
		var radius: float = (float(cdef["radius_cm"]) * 0.01) if cdef["radius_cm"] != null else _hitbox_radius(z, bone_name)
		var radius_px := maxf(radius * CONTEXT_SCALE * focal / maxf(dist, 0.05), 1.0)
		var d_px := camera.unproject_position(pt).distance_to(centre)
		if d_px > radius_px * CONTEXT_ERROR:
			continue
		var score := (d_px / radius_px) / maxf(float(cdef["weight"]), 0.01)
		if score < best_score:
			best_score = score
			best = {"name": key, "bone": bone_name, "point": pt}
	if best.is_empty():
		return {}
	# Child contexts (Head -> HeadCrawler / Scalp / HeadStomp) by their victim / requester conditions.
	for ch: Dictionary in contexts[best["name"]].get("children", []):
		var ok := true
		match ch["victim"]:
			"Crawler": ok = z.gore.is_crawling()
			"Knockdown": ok = z.is_down()
		if ch["requester"] == "IsHeadStompUnlocked":
			ok = ok and head_stomp_unlocked
		if ch["context"] == "DA_Context_Scalp":
			ok = ok and _scalp_facing(z)
		if ok and ch["victim"] != "" or (ok and ch["context"] == "DA_Context_Scalp"):
			best["name"] = ch["context"]
			break
	return best


func _context_point(z: Zombie, bone_name: String) -> Vector3:
	var bi := z.skeleton.find_bone(bone_name)
	var g := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(bi)
	var spec: Array = Zombie.HITBOXES.get(bone_name, ["", 0.1, 0.0])
	var end := z.skeleton.find_bone(spec[0]) if spec[0] != "" else -1
	if end >= 0:
		return (g.origin + z.skeleton.global_transform * z.skeleton.get_bone_global_pose(end).origin) * 0.5
	return g * Vector3(spec[2] * 0.5, 0.0, 0.0) if spec[2] > 0.0 else g.origin


func _hitbox_radius(z: Zombie, bone_name: String) -> float:
	var spec: Array = Zombie.HITBOXES.get(bone_name, ["", 0.1, 0.0])
	return float(spec[1]) * z.body_scale


func target_context(z: Zombie, bone: String, heavy: bool) -> String:
	var ctx: String = LIGHT_CONTEXT.get(bone, "Torso")
	if heavy:
		if bone in ["neck_01", "neck_02"]:
			return "DA_Context_Neck_Heavy"
		if ctx == "Torso" and w().get("damage_type") == "sharp" and w().get("attacker_weight") in ["medium", "weighty"]:
			ctx = "Stomach"   # DA_Context_Torso_Heavy -> Stomach_Heavy child for sharp medium/large weapons
		return "DA_Context_%s_Heavy" % ctx
	if ctx == "Head":
		# DA_Context_Head children: HeadCrawler (victim Crawler), Scalp (SOC_Scalp, 45 deg forward limit),
		# HeadStomp (victim Knockdown + requester IsHeadStompUnlocked).
		if z.gore.is_crawling():
			return "DA_Context_HeadCrawler"
		if z.is_down():
			return "DA_Context_HeadStomp"
		if _scalp_facing(z):
			return "DA_Context_Scalp"
	return "DA_Context_" + ctx


## DA_Context_Scalp: the view onto the head is within 45 degrees of the scalp socket's forward vector.
func _scalp_facing(z: Zombie) -> bool:
	var hb := z.skeleton.find_bone("head")
	if hb < 0:
		return false
	# SKEL_ZombieStandard socket SOC_Scalp: bone head, location (19, 0.44, 0) cm, no rotation -> its forward is
	# the head bone's +X (UE (x, y, z) -> Godot bone-local (x, z, y)).
	var head_x := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(hb)
	var fwd := head_x.basis.x.normalized()
	var to_eye := (camera.global_position - head_x * Vector3(0.19, 0.0, 0.0044)).normalized()
	return rad_to_deg(acos(clampf(fwd.dot(to_eye), -1.0, 1.0))) <= 45.0


func combat_facts(heavy := false) -> Dictionary:
	var f := {}
	var aim := aim_info(3.0)
	var pitch_deg := rad_to_deg(pitch)
	f["Self.CameraPitch"] = pitch_deg
	f["Self.WeaponLowCameraPitch"] = WEAPON_LOW_PITCH
	f["Self.WeaponUpCameraPitch"] = WEAPON_UP_PITCH
	f["Self.WeaponFloorCameraPitch"] = WEAPON_FLOOR_PITCH
	f["Self.Crouch"] = false
	f["Self.Slide"] = false
	f["Self.HandPosition"] = "Left" if melee.hand_left else "Right"
	f["Self.InChain"] = melee.chain_stacks > 0
	f["Self.HeavyAttack"] = heavy
	f["Self.IsHeadStompUnlocked"] = true
	f["IsHeadStompUnlocked"] = true
	f["Self.TargetBodyContextName"] = ""
	var ctx := {}
	var z_aim: Zombie = aim["zombie"] if not aim.is_empty() else _nearest_in_view()
	if z_aim:
		ctx = select_context(z_aim, heavy)
	f["Self.HasAimTarget"] = not ctx.is_empty()
	f["Self.HasAimTargetContext"] = not ctx.is_empty()
	if not ctx.is_empty():
		var z: Zombie = z_aim
		f["Self.TargetBodyContextName"] = ctx["name"]
		f["Self.TargetPointRelativeHeightOffsetFromEyePos"] = (ctx["point"].y - camera.global_position.y) * 100.0
		var zs := camera.unproject_position(z.global_position + Vector3.UP * 1.2)
		f["Self.TargetActorScreenSpaceYawOffset"] = (get_viewport().get_visible_rect().size.x * 0.5 - zs.x) / (get_viewport().get_visible_rect().size.x * 0.5)
		f["Target.Crawler"] = z.gore.is_crawling()
		f["Target.Downed"] = z.is_down()
		f["Target.Knockdown"] = z.is_down()
		f["Target.HealthFraction"] = z.gore.get_health() / maxf(z.gore.get_max_health(), 1.0)
		f["Target.Ragdoll"] = z.dead
		f["Target.StandUp"] = z.reactions.state == "getup"
		f["Target.AllowDeterministicHeavyAttack"] = true
		f["Target.DisallowHeavyGroundContext"] = false
	return f


## The closest living zombie in front within melee targeting range (DI2's actor selection is native).
func _nearest_in_view() -> Zombie:
	var near: Array = zombies_in_front(3.0, 0.5)
	return near[0] if not near.is_empty() else null


## What's under the crosshair (for DI2's attack contexts): {zombie, bone, point, dist, area}.
func aim_info(reach := 3.0) -> Dictionary:
	var xf := camera.global_transform
	Zombie.sync_hitboxes()   # hitboxes are posed on demand (zombie.gd)
	var q := PhysicsRayQueryParameters3D.create(xf.origin, xf.origin - xf.basis.z * reach, Util.WORLD | Util.HITBOX)
	q.collide_with_areas = true
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not hit["collider"] is Area3D:
		return {}
	var area: Area3D = hit["collider"]
	return {"zombie": area.get_meta("zombie"), "bone": area.get_meta("bone"), "point": hit["position"],
		"dist": xf.origin.distance_to(hit["position"]), "area": area}


## Zombies in front within `reach` and `cone` (dot), nearest first.
func zombies_in_front(reach: float, cone := 0.5) -> Array:
	var fwd := -global_transform.basis.z
	var out := []
	for z: Zombie in get_tree().get_nodes_in_group("zombies"):
		if z.dead:
			continue
		var to := z.global_position - global_position
		to.y = 0
		if to.length() < reach and (to.length() < 0.4 or to.normalized().dot(fwd) > cone):
			out.append(z)
	out.sort_custom(func(a, b): return a.global_position.distance_to(global_position) < b.global_position.distance_to(global_position))
	return out


func add_blood(amount: float) -> void:
	for m: ShaderMaterial in weapon_mats[weapon]:
		var cur = m.get_shader_parameter("blood_amount")
		m.set_shader_parameter("blood_amount", min(1.0, (float(cur) if cur != null else 0.0) + amount))
	for m: ShaderMaterial in arm_mats:
		var cur = m.get_shader_parameter("blood_amount")
		m.set_shader_parameter("blood_amount", min(0.6, (float(cur) if cur != null else 0.0) + amount * 0.3))


## Dealt damage feeds Fury (DI2 builds Fury from combat; kills add the zombie's FuryReward).
func on_damage_dealt(amount: float, killed: bool, z: Zombie) -> void:
	if not moves.fury_active:
		fury = min(1.0, fury + amount * 0.0006)
		if killed and z:
			fury = min(1.0, fury + float(combat["progression"]["enemy_fury"].get(z.body.capitalize(), 0.04)))
	if killed:
		moves.on_kill()


# --- Input ------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not dead and state != "grapple":
		var sens := 0.0022 * (0.6 if ranged.ads > 0.5 else 1.0)
		rotate_y(-event.relative.x * sens)
		pitch = clamp(pitch - event.relative.y * sens, deg_to_rad(-85), deg_to_rad(85))
	if dead:
		if event.is_action_pressed("respawn"):
			respawn()
		return
	if event.is_action_pressed("attack"):
		lmb_held = true
		lmb_t = 0.0
		if moves.on_attack_pressed():
			return
		if is_melee() or moves.fury_active:
			melee.on_attack_pressed()
		else:
			ranged.trigger(true)
	elif event.is_action_released("attack"):
		lmb_held = false
		if is_melee() or moves.fury_active:
			melee.on_attack_released()
		else:
			ranged.trigger(false)
	elif event.is_action_pressed("block"):
		rmb_held = true
		if is_melee() or moves.fury_active:
			moves.block_pressed()
	elif event.is_action_released("block"):
		rmb_held = false
	elif event.is_action_pressed("kick"):
		if not moves.on_kick_pressed():
			moves.kick()
	elif event.is_action_pressed("dodge"):
		moves.dodge()
	elif event.is_action_pressed("reload"):
		ranged.reload()
	elif event.is_action_pressed("throw_weapon"):
		moves.throw_pressed()
	elif event.is_action_released("throw_weapon"):
		moves.throw_released()
	elif event.is_action_pressed("curveball"):
		moves.curveball()
	elif event.is_action_pressed("cycle_curveball"):
		moves.cycle_curveball()
	elif event.is_action_pressed("fury"):
		moves.start_fury()
	elif event.is_action_pressed("medkit"):
		moves.medkit()
	elif event.is_action_pressed("interact"):
		moves.pickup()
	elif event.is_action_pressed("cycle_mod"):
		melee.cycle_mod()
	elif event.is_action_pressed("repair"):
		for k in durability:
			durability[k] = max_durability[k]
		say("Weapons repaired")
	elif event.is_action_pressed("catalog"):
		catalog_open = not catalog_open
		catalog_i = maxi(0, catalog_ids.find(weapon))
	elif catalog_open and event is InputEventKey and event.pressed:
		_catalog_key(event.keycode)
	elif event is InputEventKey and event.pressed and event.keycode >= KEY_1 and event.keycode <= KEY_8:
		var slot: int = event.keycode - KEY_1
		if slot < loadout.size():
			equip(loadout[slot])
	elif event.is_action_pressed("weapon_next"):
		equip(_next_weapon(1))
	elif event.is_action_pressed("weapon_prev"):
		equip(_next_weapon(-1))


func _next_weapon(step: int) -> String:
	var i := loadout.find(weapon)
	var n := loadout.size()
	for k in range(1, n + 1):
		var c: String = loadout[(i + step * k + n * 4) % n]
		if not weapon_away.get(c, false):
			return c
	return weapon


## F3 catalogue: every DI2 weapon; Enter puts the highlighted one into the current slot and equips it.
func _catalog_key(key: int) -> void:
	match key:
		KEY_UP:
			catalog_i = (catalog_i - 1 + catalog_ids.size()) % catalog_ids.size()
		KEY_DOWN:
			catalog_i = (catalog_i + 1) % catalog_ids.size()
		KEY_PAGEUP:
			catalog_i = maxi(0, catalog_i - 10)
		KEY_PAGEDOWN:
			catalog_i = mini(catalog_ids.size() - 1, catalog_i + 10)
		KEY_ENTER, KEY_KP_ENTER:
			var pick: String = catalog_ids[catalog_i]
			var slot := maxi(0, loadout.find(weapon))
			if not loadout.has(pick):
				loadout[slot] = pick
			catalog_open = false
			equip(pick, true)
		KEY_ESCAPE:
			catalog_open = false


func equip(name: String, instant := false) -> void:
	if weapon_away.get(name, false):
		say("That weapon is on the ground (E to pick it up)")
		return
	if (name == weapon and not instant) or (state not in ["ready", "block"] and not instant):
		return
	_ensure_weapon(name)
	if not weapon_nodes.has(name):
		return
	if data.get(weapon, {}).get("kind") == "ranged":
		ammo[weapon] = [mag, reserve]
	if data[name]["kind"] == "ranged":
		mag = ammo[name][0]
		reserve = ammo[name][1]
	for k in weapon_nodes:
		weapon_nodes[k].visible = (k == name) and not moves.fury_active
	weapon = name
	ranged.ads = 0.0
	melee.reset()
	_set_playrate_durations()
	set_state("switch")
	play_role(slot_role("Select", "main", {"UseQuickSelectAnims": instant}))


## DIAnimInstance::AddPlayrateDuration calls of BP_Base_MeleeWeaponItem (bytecode): the weapon's
## MeleeArchetypeData WeaponStandardAttackAnticipationTime / WeaponStandardAttackSpeed /
## WeaponStandardAttackRepetitionTime and the player's HeavyAttackHoldTransitionTime, read by the montages'
## AnimNotifyState_ScalePlayRate windows. Ranged weapons register none.
func _set_playrate_durations() -> void:
	var spec := w()
	anim.playrate_durations = {}
	if spec.get("kind") != "melee":
		return
	var k := 0.7 if melee and melee.exhausted else 1.0   # port stand-in for exhausted swings (pre-existing 0.7)
	anim.playrate_durations = {"Anticipation": float(spec.get("anticipation", 0.4)) / k,
		"AttackSpeed": float(spec.get("attack_speed", 1.0)) * k,
		"Repetition": float(spec.get("repetition", 0.4)) / k,
		"Decision": HEAVY_ATTACK_HOLD_TRANSITION_TIME}


## Zombie grab (DI2 grapple); see PlayerMoves.start_grapple.
func start_grapple(z: Zombie) -> bool:
	return moves.start_grapple(z)


# --- Damage taken -----------------------------------------------------------------------------------

## A zombie attack lands on Dani. Dodge i-frames, blocks, perfect blocks and grapples are resolved here.
func take_zombie_hit(damage: float, z: Zombie) -> void:
	if dead:
		return
	if moves.absorb_hit(damage, z):
		return
	_hurt(damage, z.global_position)
	if damage >= 18.0 and state in ["ready", "attack"]:
		set_state("knockback")
		if play_role(slot_role("PlayerKnockbacks")) == null:
			play_role(slot_role("PlayerStuns"))


func _hurt(damage: float, from: Vector3) -> void:
	health -= damage
	hurt_flash = 0.45
	hurt_dir_t = 1.2
	var to := from - global_position
	hurt_dir = atan2(to.x, to.z) - rotation.y
	add_shake(0.6)
	roll = deg_to_rad(randf_range(-4.0, 4.0))
	if health <= 0.0:
		die()


func die() -> void:
	dead = true
	health = 0.0
	set_state("dead")
	say("", 0.0)


func respawn() -> void:
	dead = false
	health = max_health
	stamina = max_stamina
	global_position = spawn_point
	velocity = Vector3.ZERO
	set_state("ready")


func set_level(lv: int) -> void:
	# DI2 grows Dani's base stats with level (estimate: +4% health / +2% stamina per level).
	level = lv
	var attrs: Dictionary = combat["dani"]["attributes"]
	var frac := health / max_health
	max_health = attrs.get("MaxHealth", 110.0) * (1.0 + 0.04 * (lv - 1))
	max_stamina = attrs.get("StaminaMax", 120.0) * (1.0 + 0.02 * (lv - 1))
	health = max_health * frac


## Weapon damage at Dani's level (DI2 weapons scale with level; estimate +10% of base per level).
func level_damage(base_damage: float) -> float:
	return base_damage * (1.0 + 0.1 * (level - 1))


# --- Frame ------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var p: Dictionary = data["player"]
	if not is_on_floor():
		velocity.y -= 14.0 * delta
		air_t += delta
	if dead:
		velocity.x = 0
		velocity.z = 0
		move_and_slide()
		return

	state_t += delta
	if lmb_held:
		lmb_t += delta
	stamina_delay -= delta
	if stamina_delay <= 0.0 and state not in ["block", "charge"]:
		stamina = min(max_stamina, stamina + float(p["stamina_regen"]) * delta)

	move_scale = 1.0
	melee.update(delta)
	moves.update(delta)
	ranged.update(delta)
	if state in ["switch", "knockback"] and state_t > 0.05 and montage_done(montage()):
		set_state("ready")

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (global_transform.basis * Vector3(input.x, 0, input.y)).normalized()
	var sprint := Input.is_action_pressed("sprint") and state == "ready" and ranged.ads < 0.1 and input.y < -0.1
	var speed := float(p["sprint_speed"] if sprint else p["walk_speed"]) * move_scale
	if override_t > 0.0:
		override_t -= delta
		velocity.x = move_override.x
		velocity.z = move_override.z
	elif state in ["grapple", "counter", "dead"]:
		velocity.x = 0
		velocity.z = 0
	else:
		velocity.x = move_toward(velocity.x, dir.x * speed, 40.0 * delta)
		velocity.z = move_toward(velocity.z, dir.z * speed, 40.0 * delta)
	if Input.is_action_just_pressed("jump") and is_on_floor() and state == "ready":
		velocity.y = 4.6
		set_state("jump")
	move_and_slide()

	if is_on_floor() and not was_on_floor:
		moves.on_landed(air_t)
		if state == "jump":
			play(_landing_clip(air_t), 0.05)
			set_state("switch")
	if is_on_floor():
		air_t = 0.0
	was_on_floor = is_on_floor()

	_update_base()


## ABP_PlayerCharacter_1P "UpperBody" state machine under the Arms slot: Idle plays the class's UpperBodyIdle,
## Move its UpperBodyWalkRunSprintBlendSpace, InAir its UpperBodyJumpInto; transitions crossfade with DI2's
## CrossfadeDuration / BlendMode (data/anim_graphs.json, e.g. Idle->Move 0.5 s Cubic, Move->Idle 0.6 s
## Sinusoidal). The transition rules (bTransitionToMove ...) are native: moving = > 0.5 m/s as before
## (recon/ANIMATION.md UNVERIFIED).
func _update_base() -> void:
	var c := cls()
	if c == null:
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	var st := "Idle"
	if not is_on_floor() and air_t > 0.05:
		st = "InAir"
	elif speed > 0.5:
		st = "Move"
	var key := st + "@" + c.id
	if anim.state_key() == key:
		if st == "Move":
			anim.state_src().x = _walk_run_sprint_x(speed)
		return
	var prev := anim.state_key()
	var tr := _transition(prev.get_slice("@", 0), st)
	if prev.get_slice("@", 1) != c.id:
		tr = [0.0, "Linear"]   # class switch: the state's asset is swapped in place (under the Select montage)
	var src = null
	match st:
		"Move":
			var bs: Dictionary = slot_role("UpperBodyWalkRunSprintBlendSpace")
			var bsd: Dictionary = DI2Anim.graphs.get("blend_spaces", {}).get(bs.get("bs", ""), {})
			if not bsd.is_empty():
				src = DI2Anim.BS.new(anim, bsd)
				src.x = _walk_run_sprint_x(speed)
		"InAir":
			var n := c.clip("UpperBodyJumpInto")
			if has_clip(n):
				src = DI2Anim.Seq.new(n, clip_len(n), false)
	if src == null:
		var idle := c.clip("UpperBodyIdle")
		if not has_clip(idle):
			return
		src = DI2Anim.Seq.new(idle, clip_len(idle), true)
	anim.set_state(key, src, tr[0], tr[1])


## [CrossfadeDuration, BlendMode] of the UpperBody transition from -> to (0 s when DI2 has none).
func _transition(from: String, to: String) -> Array:
	var sm: Dictionary = DI2Anim.graphs.get("state_machines", {}).get("player_1p", {}).get(UPPER_BODY_SM, {})
	for t: Array in sm.get("transitions", []):
		if t[0] == from and t[1] == to:
			return [float(t[2]), str(t[3])]
	return [0.0, "Linear"]


## WalkRunSprintBlendSpaceNormalizedVelocity: DI2 computes it natively from NormalizedWalkRunVelocityMagnitude and
## NormalizedSprintVelocityMagnitude (AnimInterest_Player_Locomotion_UpperBody +0x140 / +0x13C, the blend-space
## input at +0x138). The blend spaces put walk at 1 and sprint at 2, so walk speed -> 1 and sprint speed -> 2
## here (recon/ANIMATION.md UNVERIFIED: the native normalisation).
func _walk_run_sprint_x(speed: float) -> float:
	var pl: Dictionary = data["player"]
	var walk := float(pl["walk_speed"])
	var spr := float(pl["sprint_speed"])
	return clampf(speed / maxf(walk, 0.01), 0.0, 1.0) + clampf((speed - walk) / maxf(spr - walk, 0.01), 0.0, 1.0)


## UpperBodyLanding holds the 1 m / 3 m / 9 m landings.
func _landing_clip(air: float) -> String:
	var want := "light_1m" if air < 0.9 else ("med_3m" if air < 1.6 else "high_9m")
	var c := cls()
	for it: Dictionary in (c.all_items("UpperBodyLanding") if c else []):
		for n: String in it.get("main", {}).get("clips", []):
			if n.contains(want) and has_clip(n):
				return n
	return ""


func _process(delta: float) -> void:
	anim.update(delta)
	head.rotation.x = pitch
	# Camera bone follow-through (UE camera attached to camera_root) + shake.
	var cam_delta := Basis.IDENTITY
	if cam_bone >= 0:
		var pose := rig_skel.get_bone_global_pose(cam_bone)
		rig.transform = Transform3D(cam_align, Vector3.ZERO) * pose.affine_inverse()
		# Skeleton-space delta of the camera bone from its rest, expressed in camera axes.
		var d := RIG_TO_CAM * (pose.basis.orthonormalized() * cam_rest.inverse()) * RIG_TO_CAM.inverse()
		paired_cam = move_toward(paired_cam, 1.0 if state in ["grapple", "counter"] else 0.0, delta * 5.0)
		cam_delta = Basis.IDENTITY.slerp(d.orthonormalized(), lerpf(cam_anim_weight, PAIRED_CAM_WEIGHT, paired_cam))
		camera.position = RIG_TO_CAM * (pose.origin - cam_rest_origin) * paired_cam
	shake = max(0.0, shake - delta * 2.5)
	var s := shake * shake
	var jitter := Basis.from_euler(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * s * 0.02)
	roll = lerpf(roll, 0.0, minf(1.0, delta * 8.0))
	camera.basis = cam_delta * jitter * Basis(Vector3.FORWARD, roll)
	fov_kick = move_toward(fov_kick, 0.0, delta * 20.0)
	camera.fov = lerpf(BASE_FOV, ADS_FOV, ranged.ads) + fov_kick
	head.position.y = move_toward(head.position.y, 0.4 if dead else 1.62, delta * (2.0 if dead else 4.0))
	hurt_flash = max(0.0, hurt_flash - delta)
	hurt_dir_t = max(0.0, hurt_dir_t - delta)
	hitmarker = max(0.0, hitmarker - delta)
	hitmarker_kill = max(0.0, hitmarker_kill - delta)
	message_t = max(0.0, message_t - delta)
	hint_t = max(0.0, hint_t - delta)
	for pp in popups:
		pp["t"] += delta
	popups = popups.filter(func(pp): return pp["t"] < 1.2)
