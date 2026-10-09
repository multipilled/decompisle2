class_name Zombie
extends CharacterBody3D
## DI2 zombie driven by the Rust gore core (GoreBody): limb health, dismemberment, wounds and brain.

## DI2 body per archetype family (name prefix, as in tools/convert_archetypes.py LOCO):
## [folder under res://assets/di2 holding <folder>.glb / .materials.json / .anims.json, gore gradient].
## Families without their own export yet use the Walker body. The Thug's own material
## (MI_ThugMaleBodyA) uses DI2's Walker wound gradient.
const BODIES := {
	# P2 variant bodies (tools/archetype_bodies.py VARIANTS): [mesh folder, gore gradient, class body whose clips it
	# plays (scripts/body_variant.gd)]. Listed first: body_for() takes the first prefix match ("Walker_Burning" vs
	# "Walker"). SK_BurningWalker01's skin MIs (MI_WalkerMaleLrgUpperA / HeadA) set Wound Gradient Map = T_GoreGradWalker.
	"Walker_Burning": ["walker_burning", "T_GoreGradWalker.png", "walker"],
	"Runner_Burning": ["runner_burning", "T_GoreGradRunner.png", "runner"],  # SK_BurningRunner01 (skin MIs: T_GoreGradRunner)
	"Walker_Fireman": ["walker_fireman", "T_GoreGradWalker.png", "walker"],  # SK_BurningFiremanWalker01 (skin MIs: T_GoreGradWalker)
	"Runner_Fireman": ["runner_fireman", "T_GoreGradRunner.png", "runner"],  # SK_BurningFiremanRunner01 (skin MIs: T_GoreGradRunner)
	"Walker_Shocking": ["walker_shocking", "T_GoreGradWalker.png", "walker"],  # SK_ShockingWalker01 (skin MIs: T_GoreGradWalker) (lower body MI_RunnerMaleLowerA: T_GoreGradRunner; one gradient per body, UNVERIFIED 98)
	"Runner_Shocking": ["runner_shocking", "T_GoreGradRunner.png", "runner"],  # SK_ShockingRunner01 (skin MIs: T_GoreGradRunner)
	"Walker_Caustic": ["walker_caustic", "T_GoreGradWalker.png", "walker"],  # SK_WalkerMaleCaustic01 (skin MIs: T_GoreGradWalker)
	"Runner_Caustic": ["runner_caustic", "T_GoreGradRunner.png", "runner"],  # SK_RunnerMaleCaustic01 (skin MIs: T_GoreGradRunner)
	"Walker_Spiky": ["walker_spiky", "T_GoreGradWalker.png", "walker"],  # SK_SpikyWalker01 (skin MIs: T_GoreGradWalker)
	"Runner_Spiky": ["runner_spiky", "T_GoreGradRunner.png", "runner"],  # SK_SpikyRunner01 (skin MIs: T_GoreGradRunner)
	"Walker_Vicious": ["walker_vicious", "T_GoreGradWalker.png", "walker"],  # SK_ViciousWalker01 (skin MIs: T_GoreGradWalker)
	"Runner_Vicious": ["runner_vicious", "T_GoreGradRunner.png", "runner"],  # SK_ViciousRunner01 (skin MIs: T_GoreGradRunner)
	"Walker_FuelTank": ["walker_fueltank", "T_GoreGradWalker.png", "walker"],  # SK_FuelTank01 (skin MIs: T_GoreGradWalker)
	"Walker_WaterTank": ["walker_watertank", "T_GoreGradWalker.png", "walker"],  # SK_WaterTank01 (skin MIs: T_GoreGradWalker)
	"Walker_Corrosive": ["walker_corrosive", "T_GoreGradWalker.png", "walker"],  # SK_Corrosive01 (skin MIs: T_GoreGradWalker)
	"Walker_GrenadeVest": ["walker_grenadevest", "T_GoreGradWalker.png", "walker"],  # SK_GrenadeVest01 (skin MIs: T_GoreGradWalker)
	"Walker_InsectSwarm": ["walker_insectswarm", "T_GoreGradWalker.png", "walker"],  # SK_InsectSwarm01 (skin MIs: T_GoreGradWalker)
	"Walker_Radio": ["walker_radio", "T_GoreGradWalker.png", "walker"],  # SK_Radio01 (skin MIs: T_GoreGradWalker)
	"Walker_RiotGear_Light": ["walker_riotgear_light", "T_GoreGradWalker.png", "walker"],  # SK_RiotGearHelmetTorso (skin MIs: T_GoreGradWalker)
	"Walker_RiotGear_Medium": ["walker_riotgear_medium", "T_GoreGradWalker.png", "walker"],  # SK_RiotGearNoHelmet (skin MIs: T_GoreGradWalker)
	"Walker_RiotGear_VeryLight": ["walker_riotgear_verylight", "T_GoreGradWalker.png", "walker"],  # SK_RiotGearTorsoOnly (skin MIs: T_GoreGradWalker)
	"Walker_RiotGear_Heavy": ["walker_riotgear_heavy", "T_GoreGradWalker.png", "walker"],  # SK_RiotGearWalker01 (skin MIs: T_GoreGradWalker)
	"Runner": ["runner", "T_GoreGradRunner.png"],
	# BP_Screamer_Generic's first mesh SK_Screamer01 (tools/archetype_bodies.py); MI_ScreamerUpperA / LowerA /
	# HeadAVarD set Wound Gradient Map = T_GoreGradScreamer.
	"Screamer": ["screamer", "T_GoreGradScreamer.png"],
	# Same pipeline: SK_SlobberA (skin = T_GoreGradShambler), SK_Butcher01 and SK_SuiciderA (skin = T_GoreGradWalker).
	"Slobber": ["slobber", "T_GoreGradShambler.png"],
	"Butcher": ["butcher", "T_GoreGradWalker.png"],
	"Suicider": ["suicider", "T_GoreGradWalker.png"],
	"Shambler": ["shambler", "T_GoreGradShambler.png"],
	"Thug": ["thug", "T_GoreGradWalker.png"],
	"Walker": ["walker", "T_GoreGradWalker.png"],
}
const LOOPING := ["idle", "idle_calm", "walk_slow", "walk", "walk_fast", "crawl", "crawl_slow", "crawl_idle"]
const WALK_CLIPS := ["walk_slow", "walk", "walk_fast"]
const CRAWL_CLIPS := ["crawl_slow", "crawl"]
## Walker pelvis height (m) in the shared DI2 skeleton; bigger bodies scale hitboxes by theirs.
const REF_PELVIS_HEIGHT := 1.028
const ATTACK_ANIMS := {
	"LeftHandSwipe": "attack_swipe_l", "RightHandSwipe": "attack_swipe_r",
	"Grapple": "attack_grapple", "Bite": "attack_bite",
}
## hitbox bone -> [end bone (or "" to extrapolate), radius, extrapolated length]
const HITBOXES := {
	"head": ["", 0.11, 0.18], "neck_01": ["head", 0.065, 0.0],
	"spine_01": ["spine_03", 0.16, 0.0], "spine_03": ["neck_01", 0.17, 0.0], "pelvis": ["spine_01", 0.16, 0.0],
	"upperarm_l": ["lowerarm_l", 0.06, 0.0], "lowerarm_l": ["hand_l", 0.05, 0.0], "hand_l": ["", 0.05, 0.12],
	"upperarm_r": ["lowerarm_r", 0.06, 0.0], "lowerarm_r": ["hand_r", 0.05, 0.0], "hand_r": ["", 0.05, 0.12],
	"thigh_l": ["calf_l", 0.085, 0.0], "calf_l": ["foot_l", 0.065, 0.0], "foot_l": ["ball_l", 0.055, 0.0],
	"thigh_r": ["calf_r", 0.085, 0.0], "calf_r": ["foot_r", 0.065, 0.0], "foot_r": ["ball_r", 0.055, 0.0],
}

@export var archetype := "Walker"
## DI2 rations attacks so a crowd doesn't swing all at once: at most this many attackers at a time.
const MAX_ATTACKERS := 2
static var attack_tokens := 0
static var clip_speeds := {}  # body folder -> {clip: root-motion speed (m/s) from <body>.anims.json}
var body := "walker"
## Folder of the mesh and its per-mesh data (glb, materials, deform, subsections, dismember, character state, viscera).
## Same as `body` (the clip / anim-data folder) except for the P2 variant bodies, which play their class body's clips.
var mesh_body := "walker"
const BodyVariant := preload("res://scripts/body_variant.gd")
var clip_speed: Dictionary
var body_scale := 1.0         # body size relative to the Walker (hitbox radii, collision capsule)
var has_token := false
var token_t := 0.0
var target: Node3D
var visual: Node3D
var skeleton: Skeleton3D
var anim: AnimationPlayer
var anim_ctl: ZombieAnim       # DI2 montages + locomotion state machine on DI2Anim (scripts/zombie_anim.gd)
var gore: GoreBody
var dangling: DanglingLimbs
var phys: PhysicalReaction      # DI2 "Reaction" physical-animation profile: per-body hit impacts
var hitboxes: Array[Area3D] = []
var dead := false
var lock_time := 0.0          # one-shot animation priority (hits, falls, attacks)
var attack_anim := ""
var last_hit_part := ""
var lost_leg_side := "l"
var knock := Vector3.ZERO     # kick / heavy-hit shove
## DI2 pre-spawn splatter facts the spawner sets (StartingHealthFrac, PreSpawnSplatter_LeftArmMissing ...).
var spawn_facts := {}
## Hit particles on/off (tests measure their cost).
static var hit_particles := true
## DI2's fluid emission from hit CEs (droplets -> puddles); tests turn it off to time the rest.
static var hit_fluids := true
## --legacy-hitboxes: the old BoneAttachment3D hitboxes that follow every skeleton update (perf comparison only).
static var legacy_hitboxes := OS.get_cmdline_user_args().has("--legacy-hitboxes")
## FDamageEffectSet's native defaults (ctor 0x141c63830) for fluid fields an effect asset leaves unset; build_gradual_damage
## already resolves them into data/gradual_damage.json, this is the fallback for older data.
const GRADUAL_FLUID_DEFAULTS := {"FluidAmount": 20.0, "FluidStrength": 2.0, "EmissionVelocity": 20.0}
## DI2's BP_Base_<Class> ArchetypeSpecificFacts (the class's knowledge-base facts, e.g. {Victim}.LargeSpecial).
const ARCHETYPE_FACTS := {
	"Walker": ["IsWalker", "CanFeast", "CanBangOnSurface", "UseInnerRingIdleBreakDuringForcedSearchBehaviour", "AllowGrappleInterruption"],
	"Runner": ["IsRunner", "CanBangOnSurface", "UseInnerRingIdleBreakDuringForcedSearchBehaviour", "StopIdleBreaksAgainstWall"],
	"Shambler": ["IsShambler", "CanFeast", "CanBangOnSurface", "Frail", "UseInnerRingIdleBreakDuringForcedSearchBehaviour"],
	"Thug": ["IsThug", "SuppressCounterable", "LargeSpecial", "CanBangOnSurface"],
	"Screamer": ["IsScreamer", "SuppressCounterable", "LargeSpecial"],
	"Slobber": ["IsSlobber", "SuppressCounterable", "LargeSpecial", "CanBangOnSurface"],
	"Butcher": ["IsButcher", "MediumSpecial", "CanFeast", "StopIdleBreaksAgainstWall"],
	"Mutator": ["IsMutator", "SuppressCounterable"],
	"Suicider": ["IsSuicider", "CorpseCannotBeFeastedOn"],
	"Reformer": ["IsReformer", "SuppressCounterable", "LargeSpecial"],
	"Whipper": ["IsWhipper", "SuppressCounterable", "LargeSpecial"],
}
## The DI2 initial splatter set this zombie spawned with ("" for none).
var initial_splatter := ""
## Index of the DI2 MaterialVariants outfit this zombie spawned with (-1 = none).
var outfit_variant := -1
## Hits this zombie has taken (DI2 FLESH logging / tests).
var flesh_log: Array = []
## DI2 spawnable parts per slot (LeftEye / RightEye / Jaw): {node, spawned, detached, deleted} (UDamageRepercussions).
var parts := {}
## Knowledge-base facts set by spawned parts (SpawnablePart.SpawnedFact), read by the hit facts.
var part_facts := {}
## DI2 viscera proxy state (UVisceraComponent map value): proxy key -> {damage, gibbed, final, k (variant index)}.
var viscera_state := {}
## The last hit's impact (GoreBody.hit_ex result + rest-space sweep / alignment): frames DI2's dismember cut.
var last_impact := {}
## DI2 bone breaks (GoreBody.di2_break): break child bone -> {point, normal} in bind pose, where DI2's
## ManipulateConstraint moves that child's physics joint (the re-skinned segment hinges there).
var break_points := {}
## Cut bones of limbs a pre-spawn SplatterSet removed (no hitboxes are built under them).
var prespawn_cuts: Array[int] = []
## DI2's DamageEffectsPropagation component (burning / corroded spreading over the body nodes).
var propagation: DamagePropagation
## The movement capsule: DI2's root component (radial impacts spawn their hit effects at its centre).
var root_shape: CollisionShape3D
## Set while a bisection's dismember runs (its viscera take BisectionCut's rules).
var _bisecting := false
var ragdoll: PhysicalBoneSimulator3D
## DI2 hit reactions / knockdowns / get-ups / stun / paired clips (scripts/zombie_reactions.gd).
var reactions: ZombieReactions
## DI2's card-dealer combat AI (zombie_ai.gd, recon/ZOMBIE_AI.md): approach / strafe / attacks / grapples.
var ai: ZombieAI
## DI2 zombie voice: breathing / vocals and the voice-metered mouth (scripts/zombie_voice.gd, recon/ZOMBIE_AUDIO.md).
var voice: ZombieVoice
## Enemy level (DI2 scales health +10% of base per level) and who gets the XP.
var level := 1
var last_attacker: Node3D
signal died(zombie: Zombie)


## The BODIES entry an archetype spawns with: [asset folder, gore gradient].
static func body_for(archetype_name: String) -> Array:
	for family: String in BODIES:
		if archetype_name.begins_with(family):
			return BODIES[family]
	return BODIES["Walker"]


## The mesh's DI2 InitialAttachmentSpec (hat ...): each static-mesh part on its socket bone with DI2's relative
## transform (converted by tools/build_character_states.py).
## DI2 CharacterInitialState MaterialVariants: one alternative outfit (source -> replacement materials) per spawn.
## The pick is uniform (how DI2 chooses is UNVERIFIED #39, like the wound-set variant).
func _apply_material_variant() -> int:
	var variants: Array = Flesh.character_state(mesh_body).get("material_variants", [])
	if variants.is_empty():
		return -1
	var pick := randi() % variants.size()
	for sub: Dictionary in variants[pick]:
		if sub.get("source") and sub.get("replacement") and sub["source"] != sub["replacement"]:
			gore.substitute_material(sub["source"], sub["replacement"])
	return pick


func _attach_initial_parts() -> void:
	for part: Dictionary in Flesh.character_state(mesh_body).get("attachment_parts", []):
		var path = part.get("glb")
		if path == null or not ResourceLoader.exists(path) or skeleton.find_bone(part["socket"]) < 0:
			continue
		var att := BoneAttachment3D.new()
		att.bone_name = part["socket"]
		att.name = "Attach_" + str(part.get("name", "part"))
		skeleton.add_child(att)
		var node := (load(path) as PackedScene).instantiate() as Node3D
		var q: Array = part["quat"]
		var o: Array = part["origin"]
		var sc: Array = part["scale"]
		node.transform = Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized()).scaled(Vector3(sc[0], sc[1], sc[2])), Vector3(o[0], o[1], o[2]))
		# The part's DI2 material (tools/pack_materials.py manifest next to its glb) through the flesh shader.
		var manifest_path: String = str(path).get_basename() + ".materials.json"
		var manifest: Dictionary = Util.load_json(manifest_path) if FileAccess.file_exists(manifest_path) else {}
		for mi: MeshInstance3D in Util.find_all(node, "MeshInstance3D"):
			mi.layers = Fx.CHARACTER_LAYER
			for si in mi.mesh.get_surface_count():
				var src := mi.mesh.surface_get_material(si)
				var entry: Dictionary = manifest.get(src.resource_name if src else "", {})
				if entry.is_empty():
					continue
				mi.set_surface_override_material(si, _flesh_material(entry, str(path).get_base_dir()))
		att.add_child(node)


## DI2 render sections whose mesh is shared between bodies (SK_Skeleton, SK_SkeletonBreak, SK_ZombieViscera:
## data/viscera_parts.json `shared_mesh`), skinned onto this body's skeleton by bone name before GoreBody sets up,
## so they are body sections like the rest (materials, subsections, InitiallyHiddenMask).
func _attach_shared_sections() -> void:
	for s: Dictionary in Flesh.viscera_body(mesh_body).get("sections", []):
		if not s.has("shared_mesh") or not ResourceLoader.exists(str(s["glb"])):
			continue
		var scene := (load(s["glb"]) as PackedScene).instantiate()
		var part_skel := Util.find_first(scene, "Skeleton3D") as Skeleton3D
		for mi: MeshInstance3D in Util.find_all(scene, "MeshInstance3D"):
			var skin := (mi.skin as Skin).duplicate() as Skin if mi.skin else null
			if skin and part_skel:
				# Rebind by bone name: the part's own skeleton orders its bones differently.
				for i in skin.get_bind_count():
					var bname := skin.get_bind_name(i)
					if bname == &"" and skin.get_bind_bone(i) >= 0:
						bname = part_skel.get_bone_name(skin.get_bind_bone(i))
					skin.set_bind_name(i, bname)
					skin.set_bind_bone(i, skeleton.find_bone(bname))
			mi.get_parent().remove_child(mi)
			mi.owner = null
			# A stable name: copies of the visual (severed pieces, gibs) find their GoreBody surface by name.
			mi.name = "Shared_%s_%s" % [str(s["glb"]).get_file().get_basename(), mi.name]
			skeleton.add_child(mi)
			mi.skin = skin
			mi.skeleton = mi.get_path_to(skeleton)
			mi.layers = Fx.CHARACTER_LAYER
			mi.set_meta("di2_glb", s["glb"])
		scene.free()


## A flesh-shader material from a materials-manifest entry (plain section: no stamps of its own).
static func _flesh_material(entry: Dictionary, dir: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/flesh.gdshader")
	m.set_shader_parameter("layer", {"skin": 0, "cloth": 1, "muscle": 2, "bone": 3, "organs": 4, "eye": 5, "hair": 6}.get(entry.get("layer", "cloth"), 7))
	m.set_shader_parameter("two_sided", entry.get("two_sided", true))
	m.set_shader_parameter("use_alpha_clip", entry.get("masked", false))
	m.set_shader_parameter("alpha_clip", float(entry.get("clip", 0.333)))
	for slot in ["albedo", "normal", "mro", "ata"]:
		if entry.has(slot) and ResourceLoader.exists(dir.path_join(entry[slot])):
			m.set_shader_parameter(slot + "_tex", load(dir.path_join(entry[slot])))
			m.set_shader_parameter("has_" + slot, true)
	return m


## DI2 archetype family this zombie's body and data tables use (Walker, Runner, Shambler, Thug ...).
func family() -> String:
	for f: String in ["Runner", "Shambler", "Thug", "Screamer", "Slobber", "Whipper", "Reformer", "Walker"]:
		if archetype.begins_with(f):
			return f
	return "Walker"


func _ready() -> void:
	collision_layer = Util.ZOMBIE
	collision_mask = Util.WORLD | Util.PLAYER | Util.ZOMBIE

	var spec := body_for(archetype)
	mesh_body = spec[0]
	body = spec[2] if spec.size() > 2 else spec[0]
	var base := "res://assets/di2/%s/%s" % [mesh_body, mesh_body]
	if mesh_body != body and not ResourceLoader.exists(base + ".glb"):
		# A variant body not built / imported yet: spawn on its class body (loudly) instead of failing every later call.
		push_warning("Zombie %s: variant body %s missing, using class body %s" % [archetype, mesh_body, body])
		mesh_body = body
		base = "res://assets/di2/%s/%s" % [mesh_body, mesh_body]
	if not clip_speeds.has(body):
		var speeds := {}
		var report: Dictionary = Util.load_json("res://assets/di2/%s/%s.anims.json" % [body, body])
		for clip: String in report:
			speeds[clip] = float(report[clip]["root_speed"])
		clip_speeds[body] = speeds
	clip_speed = clip_speeds[body]
	visual = (load(base + ".glb") as PackedScene).instantiate()
	visual.rotation.y = Util.UE_TO_GODOT_YAW
	add_child(visual)
	for mi in Util.find_all(visual, "MeshInstance3D"):
		mi.layers = Fx.CHARACTER_LAYER
	skeleton = Util.find_first(visual, "Skeleton3D")
	anim = Util.find_first(visual, "AnimationPlayer")
	if anim == null:  # P2 variant body: a mesh-only glb borrowing its class body's clips
		anim = BodyVariant.borrow_clips(visual, mesh_body)
	for a in LOOPING:
		if anim.has_animation(a):
			anim.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	# DI2-style animation (scripts/zombie_anim.gd): `anim` stays the clip library, ZombieAnim drives the pose.
	anim_ctl = ZombieAnim.new(self)
	add_child(anim_ctl)
	# DI2 moves standing zombies by their animation's root motion (RootMotionFromEverything) with the Base_Locomotion
	# Starts / Stops / TurnOnSpot states (zombie_anim.gd _drive_rm); _physics_process applies root_motion().
	anim_ctl.rm_locomotion = ZombieAnim.LOCO_SETS.has(anim_ctl.body)
	var pelvis := skeleton.find_bone("pelvis")
	if pelvis >= 0:
		var rest := global_transform.affine_inverse() * skeleton.global_transform * skeleton.get_bone_global_rest(pelvis)
		body_scale = rest.origin.y / REF_PELVIS_HEIGHT

	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3 * body_scale
	cap.height = 1.7 * body_scale
	cs.shape = cap
	cs.position.y = cap.height * 0.5
	add_child(cs)
	root_shape = cs

	_attach_shared_sections()
	gore = GoreBody.new()
	gore.archetype = archetype
	gore.materials_manifest = base + ".materials.json"
	gore.deform_path = base + ".deform.bin"  # DI2 per-vertex deform stream, when decoded (recon/DEFORM_STREAM.md)
	gore.subsections_path = base + ".subsections.json"  # DI2 subsections (viscera / skull / bone culling)
	gore.gore_gradient = spec[1]
	gore.seed = randi()
	gore.skeleton_path = NodePath("../" + str(get_path_to(skeleton)))
	# DI2 draws every wound as a FLESH splatter stamp (Flesh / flesh.gdshader); gore-core's wound fields stay the
	# gameplay record only.
	gore.procedural_wounds = false
	add_child(gore)
	gore.set_stamp_textures(Flesh.textures())
	# DI2's starting look: the mesh's CharacterInitialState wound set (one of its InitialSplatterSetVariants),
	# then the archetype's pre-spawn splatter (missing limbs, reduced starting health).
	initial_splatter = Flesh.apply_initial_state(gore, mesh_body)
	outfit_variant = _apply_material_variant()
	_attach_initial_parts()
	Flesh.apply_prespawn(gore, family(), spawn_facts)

	propagation = DamagePropagation.new()
	add_child(propagation)
	propagation.setup(self)

	dangling = DanglingLimbs.new()
	skeleton.add_child(dangling)
	phys = PhysicalReaction.new()
	skeleton.add_child(phys)
	_build_hitboxes()
	gore.set_level(level, 0.1)
	# DI2's AccumulatingEffectComponent: the class's recipient config (DefaultAI / Specials) per effect type.
	var acc := AccumulatingEffects.config_for(archetype)
	for t: String in acc:
		gore.set_accumulating_def(t, acc[t])
	reactions = ZombieReactions.new(self)
	voice = ZombieVoice.new(self)
	add_child(voice)


func _build_hitboxes() -> void:
	for bone_name: String in HITBOXES:
		var bone := skeleton.find_bone(bone_name)
		if bone < 0:
			continue
		# Limbs a pre-spawn SplatterSet cut off have no hitboxes.
		if prespawn_cuts.any(func(c: int) -> bool: return Util.is_descendant_bone(skeleton, bone, c)):
			continue
		var spec: Array = HITBOXES[bone_name]
		var end := skeleton.find_bone(spec[0]) if spec[0] != "" else -1
		# A plain top-level holder posed on demand (sync_hitboxes) instead of a BoneAttachment3D following every
		# skeleton update: 17 attachments + areas cost ~0.1-0.15 ms physics per animated zombie.
		var att := Node3D.new()
		if legacy_hitboxes:
			att = BoneAttachment3D.new()
			(att as BoneAttachment3D).bone_name = bone_name
		att.name = "Hitbox_" + bone_name
		att.top_level = not legacy_hitboxes
		att.set_meta("bone_idx", bone)
		skeleton.add_child(att)
		att.global_transform = skeleton.global_transform * skeleton.get_bone_global_pose(bone)
		var area := Area3D.new()
		area.collision_layer = Util.HITBOX
		area.collision_mask = 0
		area.monitoring = false
		area.set_meta("bone", bone_name)
		area.set_meta("zombie", self)
		area.add_child(Util.capsule_for(skeleton, bone, Util.bone_segment(skeleton, bone, end, spec[2] * body_scale), spec[1] * body_scale))
		att.add_child(area)
		hitboxes.append(area)
	add_to_group(&"zombie_hitboxes")
	if not legacy_hitboxes and not skeleton.skeleton_updated.is_connected(_cache_hitbox_poses):
		skeleton.skeleton_updated.connect(_cache_hitbox_poses)


## Poses every zombie's hitboxes on the current bone transforms. Call right before a query on Util.HITBOX (weapon
## traces, overlap queries): the areas don't follow the skeleton between queries. Pushes the transform to the physics
## server directly (Node3D transform notifications are flushed later), so the query that follows sees it.
static func sync_hitboxes() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		for z in tree.get_nodes_in_group(&"zombie_hitboxes"):
			(z as Zombie)._sync_own_hitboxes()


var _hitbox_sync_key := []
var _hitbox_poses := {}      # bone index -> skeleton-space pose at the last skeleton_updated
var _hitbox_pose_serial := 0


## skeleton_updated: the final pose (after the SkeletonModifier3Ds, which Godot only keeps until the next update; a
## later get_bone_global_pose can return the unmodified pose). Where BoneAttachment3D reads it; only the 17 poses
## are kept here, no node or physics updates.
func _cache_hitbox_poses() -> void:
	for area in hitboxes:
		if is_instance_valid(area):
			var bi := int(area.get_parent().get_meta("bone_idx"))
			_hitbox_poses[bi] = skeleton.get_bone_global_pose(bi)
	_hitbox_pose_serial += 1


func _sync_own_hitboxes() -> void:
	if legacy_hitboxes or not is_instance_valid(skeleton) or not skeleton.is_inside_tree():
		return
	var sk := skeleton.global_transform
	# Several queries in one tick (pellets, a swing's sub-steps) pose once while nothing moved.
	var key := [_hitbox_pose_serial, sk]
	if key == _hitbox_sync_key:
		return
	_hitbox_sync_key = key
	for area in hitboxes:
		if not is_instance_valid(area) or area.is_queued_for_deletion():
			continue
		var holder := area.get_parent() as Node3D
		var bi := int(holder.get_meta("bone_idx"))
		var pose: Transform3D = _hitbox_poses[bi] if _hitbox_poses.has(bi) else skeleton.get_bone_global_pose(bi)
		var xf := sk * pose
		holder.global_transform = xf
		PhysicsServer3D.area_set_transform(area.get_rid(), xf * area.transform)


## Called by weapons. Returns the GoreBody result dictionary.
## `dir` = weapon travel (swing tangent / bullet path), `into` = view ray into the body (wound projection axis).
## `force` is DI2's weapon/kick Force attribute (bat 25, kick 30): the core turns it into stability damage
## and the reaction tier. `push` is the direction the hit shoves the body (defaults to `dir`).
func take_hit(bone: String, point: Vector3, dir: Vector3, into: Vector3, damage: float, kind: String, heavy: bool, limb_mult: float, force: float, push := Vector3.ZERO, attacker: Node3D = null, hit := {}) -> Dictionary:
	# A corpse keeps taking hits like DI2's (its parts still deplete, FLESH and particles still play; gore-core
	# Body::apply_corpse_hit): no reactions, statuses or kill.
	var corpse := dead
	if attacker and not corpse:
		last_attacker = attacker
	var health_before := gore.get_health()
	if hit.get("damage_type", "") != "":
		gore.set_next_damage_type(str(hit["damage_type"]))   # a weapon mod's converted element (damage modifiers only)
	var res: Dictionary = gore.hit_ex(bone, point, dir, into, damage, kind, heavy, limb_mult, force)
	# What frames a DI2 dismember cut from this hit (enriched by _flesh with the sweep / blade alignment).
	last_impact = res.duplicate()
	last_impact["force"] = float(hit.get("Force", force))
	last_impact["heavy"] = heavy
	last_impact["dir_world"] = (dir if dir.length_squared() > 1e-8 else into).normalized()
	# GoreBody refines the hitbox impact to the exact spot on the posed mesh (and the bone under it).
	point = res.get("point", point)
	bone = res.get("bone", bone)
	# DI2's hit-react trees pick this impact's responses now, before a kill below needs its DeathAction.
	reactions.select(res, hit, bone, point, (dir if dir.length_squared() > 1e-8 else into).normalized(), force, heavy, kind, attacker, corpse)
	# FLESH for physical hits, and for any hit that names its own victim tree (explosions of every damage type).
	if (kind in ["blunt", "sharp", "projectile", "explosive"] or hit.has("tree")) and damage > 0.0:
		var hit_with_force := hit.duplicate()
		if not hit_with_force.has("Force"):
			hit_with_force["Force"] = force   # {Hit}.Force: the weapon's DI2 Force (x the heavy force curve)
		# DI2's HitFromDirection: normalize(TraceEnd - TraceStart) of the hit trace = the sweep (melee) / shot travel.
		hit_with_force["dir_world"] = (dir if dir.length_squared() > 1e-8 else into).normalized()
		if corpse:
			hit_with_force["KillingBlow"] = false
		# DI2's hit particles come from the tree's CEs (DI2Particles); the recreation's burst stands in otherwise.
		if _flesh(res, damage, health_before, heavy, hit_with_force, attacker) == 0:
			Fx.blood_burst(get_parent(), point, -into + Vector3.UP * 0.25, 8 + int(damage * 0.5), 2.8)
	if corpse or ragdoll != null:
		_ragdoll_impulse(bone, dir, force)
		reactions.ragdoll_impact()
	else:
		phys.hit(bone, point, dir + into * 0.5, force)
	var staggered := false
	for o: Dictionary in res.get("outcomes", []):
		match o["type"]:
			"reaction":
				pass   # gore-core's tier only drains its stability meter; DI2's trees pick the reaction (reactions)
			"status":
				_on_status_started(o["status"], point, bone)
			"damaged":
				last_hit_part = o["part"]
			"dismembered":
				_sever(o["bone"], dir, o["force"] * force)
				if o["part"].begins_with("leg"):
					lost_leg_side = "l" if o["part"].ends_with("left") else "r"
			"crushed":
				_burst_head(o["bone"], point, dir)
			"broken":
				_di2_break(o.get("bone", bone))
				dangling.set_broken(gore.broken_bones())
				if o["part"].begins_with("leg"):
					lost_leg_side = "l" if o["part"].ends_with("left") else "r"
			"staggered":
				staggered = true
			"killed":
				var cut := _bisection_bone(res, hit, point)
				if cut != "":
					_bisecting = true
					_sever(cut, dir, force)
					_bisecting = false
					flesh_log.append({"bisected": cut})
				_die(bone, dir, force)
	# DI2's bisection rule ({Hit}.KillingBlow || {Victim}.Dead, CT_HitReact_Bisect_Zombie) also halves corpses.
	if corpse and not res.is_empty():
		var cut := _bisection_bone(res, hit, point)
		if cut != "" and not gore.is_bone_severed(cut):
			_bisecting = true
			_sever(cut, dir, force)
			_bisecting = false
			flesh_log.append({"bisected": cut})
	reactions.execute()
	return res


## DI2 FLESH for a hit: the weapon's victim HitEffectTree picks the cosmetic effects (CT_HitEffect_<Blunt|Sharp|
## Ranged>_Victim ...), whose SplatterMesh stamps / SplatterSets go on the body. `hit` carries the attacker's
## side of DI2's hit facts: weapon (id in weapons.json), CriticalHit, HeavyAttack, ThrownAttack, isPaired,
## CounterAction / CounterPush / CounterKill, mod (fire / acid / electric / bleed / impact / tearing), tree.
## Returns how many of the hit's CEs played DI2 particles.
func _flesh(res: Dictionary, damage: float, health_before: float, heavy: bool, hit: Dictionary, attacker: Node3D) -> int:
	var weapon_id: String = hit.get("weapon", attacker.get("weapon") if attacker and attacker.get("weapon") != null else "")
	var spec: Dictionary = Flesh.weapon(weapon_id)
	var he: Dictionary = spec.get("hit_effects", {})
	var tree_v: Variant = hit.get("tree", he.get("victim"))
	var tree: String = tree_v if tree_v is String else ""   # some DI2 weapons carry no victim tree (null)
	if tree == "":
		return 0
	var facts := hit_facts(res, damage, heavy, hit, spec)
	facts.merge(part_facts)   # spawned parts' SpawnedFacts live in the zombie's knowledge base
	var effects := Flesh.evaluate(tree, facts, he.get("causer_sets", []))
	# DI2's splatter facts (exe 0x14123f640): DamageAsFractionOfMaxHealth = damage / max and
	# HealthRemainingAsFractionOfMaxHealth = (health before - damage) / max, unclamped. Damage = what the core
	# applied (head / limb multipliers included); a killing blow counts at least the requested damage.
	var maxh := maxf(gore.get_max_health(), 1.0)
	var applied := health_before - gore.get_health()
	if not res.get("alive", true):
		applied = maxf(applied, damage)
	var state := {"health": (health_before - applied) / maxh, "damage": applied / maxh}
	# Melee: DI2's SweepDirection (the swing) and SourceObjectAlignment (the weapon's blade axis) frame the stamp.
	var impact := res.duplicate()
	if hit.get("align") is Vector3 and (hit["align"] as Vector3).length_squared() > 1e-6:
		impact["rest_sweep"] = res.get("rest_dir", Vector3.ZERO)
		impact["rest_align"] = gore.world_dir_to_rest(res.get("bone", ""), res.get("point", Vector3.ZERO), hit["align"])
	last_impact.merge(impact, true)
	# The splatter CEs' Orient reads the effect's spawn rotation forward (HitEffectSpawn, recon/RE_FLESH.md
	# "Hit-effect spawn transform"): a point impact's from the impact normal and HitFromDirection by the CE's factor;
	# a radial impact spawns at the root capsule's centre facing away from the origin (factor unused). The cut / break
	# frames (last_impact) keep the hit point.
	var hb := str(res.get("bone", ""))
	var hp: Vector3 = res.get("point", global_position)
	if hit.get("explosion_origin") is Vector3:
		var root: Vector3 = root_shape.global_position if root_shape else global_position
		var fwd := gore.world_dir_to_rest(hb, root, (root - (hit["explosion_origin"] as Vector3)).normalized())
		impact["rest_point"] = gore.world_point_to_rest(hb, root)
		impact["spawn_forward"] = func(_f: float) -> Vector3: return fwd
	else:
		var n_w: Vector3 = res.get("normal", Vector3.ZERO)
		var d_w: Vector3 = hit.get("dir_world", Vector3.ZERO)
		impact["spawn_forward"] = func(f: float) -> Vector3: return gore.world_dir_to_rest(hb, hp, HitEffectSpawn.point_basis(n_w, d_w, f).x)
	var made := Flesh.apply_hit(gore, effects, impact, state)
	apply_part_effects(effects)
	var played := _play_hit_particles(effects, res, hit)
	flesh_log.append({"tree": tree, "effects": effects, "stamps": made, "state": state, "part": facts.get("_part", ""), "particles": played})
	return played


## The viscera / spawnable-part halves of the cosmetic effects a hit played (data/viscera_parts.json
## `cosmetic_effects`): UCosmeticEffect_Viscera culls subsections by name (0x141256350), UCosmeticEffect_SpawnablePart
## deletes, or spawns and detaches, each slot (0x141255ad0; defaults bSpawn / bDetach true, bDelete false).
func apply_part_effects(effects: Array) -> void:
	var table: Dictionary = Flesh.viscera_effects()
	for e: Array in effects:
		for fx: Dictionary in table.get(str(e[0]), {}).get("effects", []):
			match fx.get("type", ""):
				"CosmeticEffect_Viscera":
					for n in fx.get("cull", []):
						gore.cull_subsection(n)
					for n in fx.get("unhide", []):
						gore.show_subsection(n)
				"CosmeticEffect_SpawnablePart":
					for slot in fx.get("slots", []):
						if fx.get("delete", false):
							delete_part(slot)
						else:
							if fx.get("spawn", true):
								spawn_part(slot)
							if fx.get("detach", true):
								detach_part(slot)


func _part_spec(slot: String) -> Dictionary:
	for p: Dictionary in Flesh.viscera_body(mesh_body).get("spawnable_parts", []):
		if p.get("slot") == slot:
			return p
	return {}


## DI2 SpawnPart (0x1412a4950): hide OriginalPartToHide (abort if that hid nothing), attach the part at its socket,
## stamp its PresetSplatter, set its SpawnedFact.
func spawn_part(slot: String) -> bool:
	var st: Dictionary = parts.get(slot, {})
	var p := _part_spec(slot)
	if st.get("spawned", false) or p.is_empty() or (p.get("spec", []) as Array).is_empty():
		return false
	if not gore.cull_subsection(p.get("original_part_to_hide", "")):
		return false
	var spec: Dictionary = p["spec"][0]
	if not ResourceLoader.exists(str(spec.get("glb", ""))):
		return false
	var att := BoneAttachment3D.new()
	att.bone_name = p["socket"]["bone"]
	skeleton.add_child(att)
	var node := (load(spec["glb"]) as PackedScene).instantiate() as Node3D
	var sock: Dictionary = p["socket"]["gl"]
	var loc: Dictionary = spec.get("location", {}).get("gl", {})
	node.transform = _gl_xform(sock) * _gl_xform(loc)
	if spec.get("actor_class", "") == "BP_Part_Jaw_C":
		# BP_Part_Jaw OnSpawn: hang from a random side, roll a = +-10 deg, drop |sin(a) * 5| cm (UE local -Z).
		var a := 10.0 if randf() < 0.5 else -10.0
		node.transform = node.transform * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-a)), Vector3(0, -absf(sin(deg_to_rad(a)) * 5.0) * 0.01, 0))
	var mats: Dictionary = spec.get("materials", {})
	var dir := str(spec["glb"]).get_base_dir()
	for mi: MeshInstance3D in Util.find_all(node, "MeshInstance3D"):
		mi.layers = Fx.CHARACTER_LAYER
		for si in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(si)
			var entry: Dictionary = mats.get(src.resource_name if src else "", {}).duplicate()
			if entry.is_empty():
				continue
			# Part materials are plain M_Skin instances (MI_*EyePop, MI_*Jaw): no splatter, drawn like viscera / bone,
			# whatever layer the packer guessed from the name.
			var chain: Array = entry.get("mi_chain", [])
			if not chain.is_empty() and chain.back() == "M_Skin" and not entry.get("splatter", false) and entry.get("layer") == "eye":
				entry["layer"] = "organs"
			mi.set_surface_override_material(si, _flesh_material(entry, dir))
	att.add_child(node)
	if p.get("preset_splatter"):
		Flesh.apply_set(gore, str(p["preset_splatter"]), false)
	if p.get("spawned_fact"):
		part_facts[str(p["spawned_fact"])] = true
	parts[slot] = {"node": node, "attach": att, "spawned": true, "detached": false, "deleted": false}
	return true


## DI2 DetachPart (0x1412a4660): spawned, not detached / deleted, and detachable (the jaw; eyes never detach).
## BP_Part_Jaw OnDetach: keep the world transform, simulate on PA_JawFalling (one box on jaw_02), 30 kg, with the
## head bone's velocity; despawned under the "Limb" rules.
func detach_part(slot: String) -> bool:
	var st: Dictionary = parts.get(slot, {})
	if not st.get("spawned", false) or st.get("detached", false) or st.get("deleted", false):
		return false
	var spec: Dictionary = _part_spec(slot)["spec"][0]
	if spec.get("actor_class", "") != "BP_Part_Jaw_C":
		return false
	var node: Node3D = st["node"]
	var xf := node.global_transform
	var rb := RigidBody3D.new()
	rb.collision_layer = Util.DEBRIS
	rb.collision_mask = Util.WORLD | Util.DEBRIS
	rb.mass = 30.0
	get_parent().add_child(rb)
	rb.add_to_group("gore_debris")
	rb.global_transform = xf
	node.get_parent().remove_child(node)
	rb.add_child(node)
	node.transform = Transform3D.IDENTITY
	var box := BoxShape3D.new()
	box.size = Vector3(0.0870, 0.0726, 0.1196)   # PA_JawFalling box, UE (X, Z, Y) cm -> m
	var cs := CollisionShape3D.new()
	cs.shape = box
	rb.add_child(cs)
	# DI2 adds the head bone's physics velocity here; the port's animated body has none to read (UNVERIFIED #47).
	st["detached"] = true
	(st["attach"] as Node).queue_free()
	get_tree().create_timer(60.0).timeout.connect(rb.queue_free)   # same "Limb" despawn as severed limbs here
	return true


## DI2 DeletePart (0x1412a43a0): spawned and not detached / deleted; the original subsection stays hidden.
func delete_part(slot: String) -> bool:
	var st: Dictionary = parts.get(slot, {})
	if not st.get("spawned", false) or st.get("detached", false) or st.get("deleted", false):
		return false
	(st["attach"] as Node).queue_free()
	st["deleted"] = true
	return true


## DI2 UVisceraComponent::Splatter (0x141256940, recon/VISCERA_PARTS.md §4.1) for one applied stamp: rupture damage
## on the viscera proxies its box reaches. `info` = the stamp's modified FSplatterMeshInfo, `o` / `fr` its bind-pose
## origin and frame [projection axis, +u, +v] (metres; DI2 works in cm).
func viscera_splatter(info: Dictionary, o: Vector3, fr: Array, impact: Dictionary, state: Dictionary) -> void:
	var asset: Dictionary = Flesh.viscera_asset(str(Flesh.viscera_body(mesh_body).get("viscera", "")))
	if asset.is_empty():
		return
	var stype := int(Flesh.SPLATTER_TYPES.get(str(Flesh._v(info, "SplatterType")), 1))
	if (stype & 1) == 0 or str(Flesh._v(info, "RuptureInteraction")) == "NoRupture":
		return
	var max_count := int(Flesh._v(info, "MaximumRuptureCount"))
	var mult := float(Flesh._v(info, "RuptureDamageMultiplier"))
	var off := float(Flesh._v(info, "RuptureDamageOffset"))
	if max_count <= 0 or (mult < 1e-4 and off < 1e-4):
		return
	var uv := float(Flesh._v(info, "UVScale"))
	# As compiled: the radius adds RuptureDepthOffset (+0x80); RuptureRadiusOffset isn't read.
	var radius := float(Flesh._v(info, "RuptureRadiusMultiplier")) * uv + float(Flesh._v(info, "RuptureDepthOffset"))
	var depth := float(Flesh._v(info, "RuptureDepthMultiplier")) * float(Flesh._v(info, "DepthScale")) + float(Flesh._v(info, "RuptureDepthOffset"))
	var n: Vector3 = (fr[0] as Vector3).normalized()
	var tt: Vector3 = (fr[1] as Vector3).normalized()
	var bb: Vector3 = (fr[2] as Vector3).normalized()
	var oc := o * 100.0
	var falloff_on := float(Flesh._v(info, "RuptureFalloffFactor")) > 1e-4 and uv > 1e-4
	var limit := float(Flesh._v(info, "RuptureLimitFraction"))
	var ruptured := 0
	for proxy: Dictionary in Flesh.viscera_candidates(asset):
		var box: Dictionary = proxy["box"]["gl"]
		var c := Vector3(box["t"][0], box["t"][1], box["t"][2]) * 100.0
		var q: Array = box["q"]
		var r := Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized())
		var he: Array = box["half_extents"]
		var axes := [r.x * float(he[0]) * 100.0, r.y * float(he[1]) * 100.0, r.z * float(he[2]) * 100.0]
		var d := n.dot(c) - n.dot(oc)
		var rn := 0.0
		var rt := 0.0
		var rb := 0.0
		for a: Vector3 in axes:
			rn += absf(n.dot(a))
			rt += absf(tt.dot(a))
			rb += absf(bb.dot(a))
		var lat := 0.25 * (rb + rt) + 0.5 * radius
		if not (d - rn < depth and (c - oc - n * d).length_squared() < lat * lat):
			continue
		var key: String = proxy["key"]
		var st: Dictionary = viscera_state.get(key, {"damage": 0.0, "gibbed": false, "final": false, "k": 0})
		var thr := float(proxy.get("rupture_threshold", 1.0))
		if st["gibbed"] or st["final"] or float(st["damage"]) >= thr:
			continue
		if (stype & 0x21) == 0x21 and proxy.get("ignore_max_blend", true):
			continue
		var fo := 1.0
		if falloff_on:
			fo = 1.0 - minf((oc - c).length_squared() / (uv * uv), 1.0)
			if fo <= 1e-4:
				continue
		var amount := (uv * 0.01 * fo * float(Flesh._v(info, "DisplacementScale")) * mult + off) * fo
		# ApplyProxyDamage (0x14124f570).
		var cap := thr * limit
		var old := float(st["damage"])
		if old >= cap:
			continue
		st["damage"] = minf(old + amount, cap)
		viscera_state[key] = st
		if not proxy.get("hold_final_state", false) and float(st["damage"]) >= thr:
			_rupture(proxy, impact, state)
			ruptured += 1
			if ruptured >= max_count:
				break
		else:
			_switch_variants(asset, proxy, old, float(st["damage"]), thr, impact, state)


## A proxy ruptures: its RuptureEffects play at the hit and its spawnable-part slots detach (or are deleted).
func _rupture(proxy: Dictionary, impact: Dictionary, state: Dictionary) -> void:
	var ce = proxy.get("rupture_effects")
	if ce:
		Flesh.apply_hit(gore, [[str(ce), 0.0]], impact, state)
		apply_part_effects([[str(ce), 0.0]])
	for slot in proxy.get("spawnable_part_slots", []):
		if not detach_part(slot):
			delete_part(slot)


## SwitchVariant (0x141258ad0): a threshold (percent of RuptureThreshold) crossed by this damage step swaps the
## proxy's subsections (and its switchable group's) for the variant's exposed ones.
func _switch_variants(asset: Dictionary, proxy: Dictionary, old: float, now: float, thr: float, impact: Dictionary, state: Dictionary) -> void:
	var ths: Array = proxy.get("switchable_thresholds", [])
	var vars: Array = proxy.get("switchable_variants", [])
	var key: String = proxy["key"]
	var st: Dictionary = viscera_state[key]
	var k := int(st["k"])
	if k >= ths.size() or k >= vars.size() or vars[k] == null:
		return
	var p_old := 100.0 * old / (thr + 1e-4)
	var p_new := 100.0 * now / (thr + 1e-4)
	if not (float(ths[k]) > p_old and float(ths[k]) <= p_new):
		return
	var variant: Dictionary = Flesh.viscera_variant(asset, str(vars[k]))
	for px: Dictionary in Flesh.viscera_switch_group(asset, proxy):
		# HideProxy: its subsections, broken subsections and every variant's subsections.
		for nme in px.get("subsections", []) + px.get("broken_subsections", []):
			gore.cull_subsection(nme)
		for vk in px.get("switchable_variants", []):
			for nme in Flesh.viscera_variant(asset, str(vk)).get("subsections", []):
				gore.cull_subsection(nme)
		var pst: Dictionary = viscera_state.get(px["key"], {"damage": 0.0, "gibbed": false, "final": false, "k": 0})
		pst["k"] = int(pst["k"]) + 1
		if px.get("hold_final_state", false) and int(pst["k"]) >= (px.get("switchable_variants", []) as Array).size():
			pst["final"] = true
		viscera_state[px["key"]] = pst
	for nme in variant.get("subsections", []):
		gore.show_subsection(nme)
	if variant.get("activation_effects"):
		Flesh.apply_hit(gore, [[str(variant["activation_effects"]), 0.0]], impact, state)
		apply_part_effects([[str(variant["activation_effects"]), 0.0]])


static func _gl_xform(d: Dictionary) -> Transform3D:
	var t: Array = d.get("t", [0, 0, 0])
	var q: Array = d.get("q", [0, 0, 0, 1])
	var qq := Quaternion(q[0], q[1], q[2], q[3])
	if qq.length_squared() < 1e-8:
		qq = Quaternion.IDENTITY
	return Transform3D(Basis(qq.normalized()), Vector3(t[0], t[1], t[2]))


## DI2 hit facts ({Hit}.X / {Victim}.X / {Attacker}.X, and the hit's facts bare for anim-set groups).
func hit_facts(res: Dictionary, damage: float, heavy: bool, hit: Dictionary, spec: Dictionary) -> Dictionary:
	# The hit part: the first "damaged" outcome (a radial hit's part-damage events follow it).
	var part := ""
	for o: Dictionary in res.get("outcomes", []):
		if o["type"] == "damaged":
			part = str(o.get("part", ""))
			break
	var h := {
		"CriticalHit": bool(hit.get("CriticalHit", false)),
		"HeavyAttack": bool(hit.get("HeavyAttack", heavy)),
		"ThrownAttack": bool(hit.get("ThrownAttack", false)),
		"CounterAction": bool(hit.get("CounterAction", false)),
		"CounterPush": bool(hit.get("CounterPush", false)),
		"CounterKill": bool(hit.get("CounterKill", false)),
		"RequestedDamage": damage,
		"DamageAsFractionOfMaxHealth": damage / maxf(gore.get_max_health(), 1.0),
		"KillingBlow": bool(hit.get("KillingBlow", not res.get("alive", true))),
		"Force": float(hit.get("Force", 0.0)),
		"Dismembered": res.get("outcomes", []).any(func(o: Dictionary) -> bool: return o.get("type", "") == "dismembered"),
	}
	# Hit zone: gore-core part ids -> DI2's Head / Arm_Left / ... facts.
	if part != "":
		var zone := "_".join(Array(part.split("_")).map(func(x: String) -> String: return x.capitalize()))
		h[zone] = true
	# Weapon mods (CT_WeaponModType): exactly one of FireMod / ShockMod / AcidMod / BleedMod / ImpactMod / TearingMod.
	var mod_fact: String = {"fire": "FireMod", "electric": "ShockMod", "shock": "ShockMod", "acid": "AcidMod",
		"bleed": "BleedMod", "impact": "ImpactMod", "tearing": "TearingMod"}.get(str(hit.get("mod", "")), "")
	for m in ["FireMod", "ShockMod", "AcidMod", "BleedMod", "ImpactMod", "TearingMod"]:
		h[m] = m == mod_fact
	# The weapon's ImpactConfiguration.CustomImpactFacts (Pistol, Shotgun, Harvester, CrowdControl ...).
	for k: String in spec.get("hit_effects", {}).get("facts", {}):
		h[k] = spec["hit_effects"]["facts"][k]
	# Impact facts the source adds itself (an explosion's ImpactKB: Thrown, Nail_Bomb, Fire_Bomb,
	# RadialToBodyPartDamageMultiplier ...).
	for k: String in hit.get("facts", {}):
		h[k] = hit["facts"][k]
	var facts := {}
	for k: String in h:
		facts["Hit." + k] = h[k]
		facts[k] = h[k]
	facts["Victim.HealthMax"] = gore.get_max_health()
	facts["Victim.Dead"] = dead or not res.get("alive", true)
	# The victim's class facts: DI2's BP_Base_<Class>.ArchetypeSpecificFacts (CT_IsLarge reads Large / LargeSpecial).
	facts["Victim.Large"] = false
	for f: String in ARCHETYPE_FACTS.get(archetype, []):
		facts["Victim." + f] = true
	facts["Attacker.WeaponStabbing"] = bool(spec.get("stabbing", false))
	facts["isPaired"] = bool(hit.get("isPaired", false))
	facts["_part"] = part
	return facts


## Stability hit without a wound (perfect blocks, shoves, explosions' blast).
func stagger(push: Vector3, force := 20.0) -> void:
	if dead:
		return
	gore.stagger()
	gore.stability_hit(force, force >= 35.0)
	reactions.on_stagger(push, force)


func is_down() -> bool:
	return reactions != null and reactions.downed


func _sever(bone_name: String, dir: Vector3, force: float) -> void:
	var cut := skeleton.find_bone(bone_name)
	# A ragdolled corpse drops the severed subtree's bodies (the piece gets its own ragdoll below).
	if ragdoll:
		for pb in ragdoll.get_children():
			if pb is PhysicalBone3D and Util.is_descendant_bone(skeleton, skeleton.find_bone((pb as PhysicalBone3D).bone_name), cut):
				pb.queue_free()
	# Areas whose holder an earlier removal freed (a burst head, an earlier cut) drop out first.
	hitboxes = hitboxes.filter(func(a): return is_instance_valid(a) and not a.is_queued_for_deletion() and is_instance_valid(a.get_parent()) and not a.get_parent().is_queued_for_deletion())
	for area in hitboxes:
		var b := skeleton.find_bone(area.get_meta("bone"))
		if Util.is_descendant_bone(skeleton, b, cut):
			area.get_parent().queue_free()
	hitboxes = hitboxes.filter(func(a): return not Util.is_descendant_bone(skeleton, skeleton.find_bone(a.get_meta("bone")), cut))

	# Duplicate the visual, freeze its pose, keep only the severed subtree (shader mask) and throw it.
	var piece := visual.duplicate() as Node3D
	var pa := Util.find_first(piece, "AnimationPlayer")
	if pa:
		pa.free()
	for n in Util.find_all(piece, "BoneAttachment3D") + Util.find_all(piece, "SkeletonModifier3D"):
		n.free()
	for a in Util.find_all(piece, "Area3D"):
		if a.has_meta("zombie"):   # the duplicated hitbox holders
			a.get_parent().free()
	var pskel: Skeleton3D = Util.find_first(piece, "Skeleton3D")
	for i in skeleton.get_bone_count():
		pskel.set_bone_pose(i, skeleton.get_bone_pose(i))
	gore.configure_piece(piece, bone_name)
	# DI2's dismember splits the mesh (body / limb triangles) and paints the cut band; DI2 draws no caps. Without DI2
	# data for the body or a region on the bone, the recreation's caps close the cut.
	var di2 := _di2_cut(piece, bone_name)
	if not di2:
		gore.add_cut_caps(piece, bone_name)

	var bone_world := skeleton.global_transform * skeleton.get_bone_global_pose(cut)
	# DI2's BP_DismemberedLimb_AI is the mesh simulating its physics asset (BPC_RagdollSleep_AI, PM_Flesh_Dismembered):
	# the piece is a ragdoll of the severed subtree's PA_ZombieStandard bodies, given DI2's limb velocity.
	if di2:
		var sim := PhysicalBoneSimulator3D.new()
		pskel.add_child(sim)
		var made := _build_ragdoll(sim, func(b: int) -> bool: return Util.is_descendant_bone(skeleton, b, cut), bone_name)
		if not made.is_empty():
			get_parent().add_child(piece)
			piece.add_to_group("gore_debris")
			piece.global_transform = visual.global_transform
			sim.physical_bones_start_simulation()
			# The bones above the subtree aren't simulated: carry them with the subtree's top body so vertices
			# weighted across the cut don't stretch back to where the limb was.
			var anchor := ""
			for nm: String in made.keys():
				if anchor == "" or _depth(skeleton.find_bone(nm)) < _depth(skeleton.find_bone(anchor)):
					anchor = nm
			var follow := PieceFollower.new()
			follow.setup(pskel, made[anchor])
			piece.add_child(follow)
			# Dismember.HeavyAttackForceScalar / ForceScalar (3.5) x the hit's Force (cm/s), held for 2 frames.
			_hold_bones_velocity(made.values(), dir.normalized() * 3.5 * float(last_impact.get("force", 0.0)) * 0.01, 2)
			get_tree().create_timer(60.0).timeout.connect(piece.queue_free)
			return
		sim.free()
	var rb := RigidBody3D.new()
	rb.collision_layer = Util.DEBRIS
	rb.collision_mask = Util.WORLD | Util.DEBRIS
	rb.mass = 6.0 if bone_name.begins_with("thigh") else (4.0 if bone_name.begins_with("calf") or bone_name.begins_with("neck") else 2.5)
	get_parent().add_child(rb)
	rb.add_to_group("gore_debris")
	rb.global_transform = Transform3D(bone_world.basis.orthonormalized(), bone_world.origin)
	rb.add_child(piece)
	piece.global_transform = visual.global_transform
	# Collision capsule along the severed bone chain.
	var end := -1
	for c in skeleton.get_bone_count():
		if skeleton.get_bone_parent(c) == cut and HITBOXES.has(skeleton.get_bone_name(c)):
			end = c
	var seg := Util.bone_segment(skeleton, cut, end, 0.25)
	# Cut mid-bone (DI2's cut positions): the piece only starts at the cut plane.
	seg[0] = (seg[0] as Vector3).lerp(seg[1], gore.cut_fraction(bone_name))
	# The body sits on the cut bone, so the bone-local capsule applies as is.
	rb.add_child(Util.capsule_for(skeleton, cut, seg, 0.07))
	if di2:
		# DI2: limb velocity = (Dismember.HeavyAttackForceScalar if heavy else Dismember.ForceScalar, both 3.5) x the
		# hit's Force along the hit direction (UE cm/s), held for Dismember.ForceVelFrameCount = 2 frames.
		_hold_velocity(rb, dir.normalized() * 3.5 * float(last_impact.get("force", 0.0)) * 0.01, 2)
	else:
		var push: Vector3 = (dir.normalized() * 2.2 + Vector3.UP * 1.4) * clampf(force * 0.06, 0.6, 2.5)
		rb.apply_impulse(push * rb.mass, Vector3(randf_range(-0.05, 0.05), 0.05, 0))
		rb.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6))
	if not di2:
		# DI2's dismember blood is its gradual effect's particle system and fluid (_gradual_particles / _fluid).
		Fx.blood_burst(get_parent(), bone_world.origin, dir + Vector3.UP, 40, 3.5)
		# DI2 cuts spawn their gibs through LimbCut (_spawn_gib); the recreation's chunks stand in otherwise.
		Fx.gibs(get_parent(), bone_world.origin, dir, 2)
	get_tree().create_timer(60.0).timeout.connect(rb.queue_free)


## The hit tree's cosmetic effects' particle systems (DI2Particles, recon/PARTICLES.md), spawned the way DI2's hit
## effects dispatch does (HitEffectSpawn, recon/RE_FLESH.md "Hit-effect spawn transform"): a point impact at the
## ImpactPoint, attached at the hit bone, rotated from the impact normal and the hit's travel direction by each
## CE's DirectionInterpolationFactor; a radial impact (explosion) at the root capsule's centre, facing away from
## the origin, factor unused. Returns how many CEs played.
func _play_hit_particles(effects: Array, res: Dictionary, hit: Dictionary) -> int:
	if not hit_particles and not hit_fluids:
		return 0
	var db_ce: Dictionary = DI2Particles.db().get("ce", {})
	var played := 0
	var parent: Node = self
	var pos: Vector3
	var radial: bool = hit.get("explosion_origin") is Vector3
	var base := Basis.IDENTITY
	if radial:
		pos = root_shape.global_position if root_shape else global_position
		base = HitEffectSpawn.radial_basis(pos, hit["explosion_origin"])
	else:
		pos = res.get("point", global_position)
		var bone := str(res.get("bone", ""))
		if bone != "" and skeleton.find_bone(bone) >= 0:
			parent = _hit_attachment(bone)
	for e: Array in effects:
		var ce := str(e[0])
		if not db_ce.has(ce):
			continue
		if not radial:
			base = HitEffectSpawn.point_basis(res.get("normal", Vector3.ZERO), hit.get("dir_world", Vector3.ZERO), float(e[1]))
		if hit_particles and HitEffectSpawn.play(parent, ce, pos, base) > 0:
			played += 1
		# The CE's UCosmeticEffect_FluidParticle entries: blood droplets -> puddles (DI2Fluids).
		if hit_fluids:
			DI2Fluids.emit_ce(self, ce, pos, base)
	return played


func _hit_attachment(bone: String) -> BoneAttachment3D:
	var nm := "Hit_" + bone
	var att := skeleton.get_node_or_null(nm) as BoneAttachment3D
	if att == null:
		att = BoneAttachment3D.new()
		att.name = nm
		att.bone_name = bone
		skeleton.add_child(att)
	return att


## DI2's gradual damage effect for a dismember (data/gradual_damage.json, DA_ContextualGradualDamageEffectList_AI:
## the first candidate whose requirement holds): MajorCut when the cut bone is in its spine / clavicle list,
## Decapitate when the head comes off (#Beheaded), else Dismember. Its InitialEffect is a DismemberWithDecal:
## GoreBody.di2_cut splits the mesh and bakes the radial cut band (RE_DISMEMBER.md §2.1, §13.2).
## DI2 BoneBreak_AI (data/gradual_damage.json): a BoneBreak (8, no decal) at the hit bone's break region: the mesh
## past the break plane is re-skinned onto the break child (RE_DISMEMBER.md §7, §13.3).
func _di2_break(bone_name: String) -> void:
	if last_impact.is_empty():
		return
	var fr := Flesh.orient({}, {}, 0.0, last_impact)
	var br: Dictionary = gore.di2_break(bone_name, last_impact.get("rest_point", Vector3.ZERO), fr[0], fr[1], fr[2])
	if br.get("ok", false):
		break_points[str(br["child"])] = {"point": br["point"], "normal": br["normal"]}
		flesh_log.append({"di2_break": bone_name, "child": br["child"]})
		# The break's gradual effect (BoneBreak_AI): its over-time instance and InitialEffect fluid (0x14129a8e0).
		var eff: Dictionary = Flesh.gradual_damage().get("effects", {}).get(_gradual_effect_name(bone_name, true), {})
		if not eff.is_empty():
			_gradual_particles(eff, last_impact)
			_gradual_over_time(eff, fr, last_impact.duplicate())
			_gradual_initial_fluid(eff, last_impact)


## DI2 bisection (recon/RE_DISMEMBER.md §12.4): CT_HitReact_Death_Zombie starts with CT_HitReact_Bisect_Zombie:
## bisect when CanBisect ({Hit} ImpactData.bCanCauseBisection; the impact KB writer 0x1413cc2d0) and #CanBeBisected
## (({Hit}.KillingBlow || {Victim}.Dead) && {Hit}.Torso_Bisectable && !{Hit}.ArmouredTorsoImpact &&
## {Victim}.HealthFraction_Torso_Bisectable <= 0.65), then BisectionChance >= 1 (thrown: CanBisectWhenThrown) or
## BisectionChance >= rnd(0, 1). UBisectionTriggerResponse (0x14125b8c0) then cuts at one of the
## DamageRepercussions BisectableParts' bones (Torso_Bisectable: spine_04 / 03 / 02): for a point impact the bone
## whose safe-region socket is nearest the hit (0x14124f2a0 / 0x1412a0610), for a radial one a random bone of the
## part (0x14124fb90); the cut is a dismember at that bone (0x1412b3ec0 -> 0x14129a8e0, bBisect). Returns the bone,
## or "" for no bisection. Only archetypes whose MultiPartHealth has Torso_Bisectable can be bisected (Thug,
## Screamer, Slobber, Whipper, Reformer; not Walker / Runner / Shambler).
func _bisection_bone(res: Dictionary, hit: Dictionary, point: Vector3) -> String:
	var parts: Dictionary = gore.part_states()
	if not parts.has("Torso_Bisectable"):
		return ""
	var tb: Dictionary = parts["Torso_Bisectable"]
	if str(tb.get("state", "")) == "severed" or float(tb["health"]) > 0.65 * float(tb["max"]):
		return ""
	var radial := hit.has("explosion_origin")
	var on_part := false
	for o: Dictionary in res.get("outcomes", []):
		if o["type"] == "damaged":
			on_part = on_part or str(o.get("part", "")) == "Torso_Bisectable"
			if not radial:
				break   # a point hit's zone is its first (direct) part
	if not on_part:
		return ""
	# CanBisect / BisectionChance: the weapon's (or explosion's) ImpactData; ArmouredTorsoImpact is never set here.
	var spec: Dictionary = Flesh.weapon(str(hit.get("weapon", "")))
	var can := bool(hit.get("CanBisect", spec.get("can_bisect", false)))
	var chance := float(hit.get("BisectionChance", 1.0))
	if not can:
		return ""
	if chance >= 1.0:
		if bool(hit.get("ThrownAttack", false)) and not bool(hit.get("CanBisectWhenThrown", false)):
			return ""
	elif chance < randf():
		return ""
	var bones := ["spine_04", "spine_03", "spine_02"]
	if radial:
		return bones[randi() % bones.size()]
	var best := ""
	var bd := INF
	for b: String in bones:
		var bi := skeleton.find_bone(b)
		if bi < 0:
			continue
		var xf := skeleton.global_transform * skeleton.get_bone_global_pose(bi)
		for loc: Vector3 in gore.safe_region_points(b):
			var dd := (xf * loc).distance_squared_to(point)
			if dd < bd:
				bd = dd
				best = b
	return best


## A stored SplatterSet cut this zombie's limb off at spawn (pre-spawn missing limbs, crawler sets): drop the
## severed subtree's hitboxes like a live cut does (no piece: the limb was never there).
func on_prespawn_cut(bone_name: String) -> void:
	var cut := skeleton.find_bone(bone_name)
	if cut < 0:
		return
	prespawn_cuts.append(cut)
	_viscera_limb_cut(null, bone_name)
	for area in hitboxes:
		if is_instance_valid(area) and Util.is_descendant_bone(skeleton, skeleton.find_bone(area.get_meta("bone")), cut):
			area.get_parent().queue_free()
	hitboxes = hitboxes.filter(func(a): return is_instance_valid(a) and not a.is_queued_for_deletion() and not Util.is_descendant_bone(skeleton, skeleton.find_bone(a.get_meta("bone")), cut))
	if bone_name.begins_with("thigh") or bone_name.begins_with("calf"):
		lost_leg_side = "l" if bone_name.ends_with("_l") else "r"


## DI2's accumulating effects from one applier (AccumulatingEffects: a weapon mod's on-hit values, an explosion's
## AccumulatingEffectsToApply): each {type, value, apply_max, can_extend} goes to the meter (GoreBody.accumulate),
## level-scaled by Curve_AccumulatingEffectsLevelScaling(this zombie's level - source_level) when `scaled`.
## `point` / `bone`: where a status that begins here starts its propagation (the triggering hit).
## Returns the statuses that began.
func accumulate(effects: Array, source_level: int, scaled := true, point := Vector3.INF, bone := "spine_03") -> Array:
	var started := []
	if dead:
		return started
	var k := AccumulatingEffects.level_scale(level, source_level) if scaled else 1.0
	for e: Dictionary in effects:
		var r: Dictionary = gore.accumulate(str(e["type"]), float(e["value"]) * k, bool(e.get("apply_max", false)),
			bool(e.get("can_extend", false)))
		if r.get("started", false):
			var st: String = {"Burning": "burning", "Electrocuted": "electrified", "Corroded": "caustic", "Bleed": "bleeding", "Weakened": "weakened", "Disoriented": "disoriented"}.get(str(e["type"]), str(e["type"]))
			var at := point
			if at == Vector3.INF:
				var bi := skeleton.find_bone(bone)
				at = skeleton.global_transform * skeleton.get_bone_global_pose(bi).origin if bi >= 0 else global_position
			_on_status_started(st, at, bone)
			started.append(st)
		if r.get("killed", false) and not dead:
			_die(bone, Vector3.UP, 5.0)   # as a status kill (take_events "killed_by_status")
	return started


## A DI2 status began (the meter filled): its look and reaction.
func _on_status_started(status: String, point: Vector3, bone: String) -> void:
	if status == "electrified":
		reactions.stun_start()
		_electrocute_look()
	elif status in ["burning", "caustic"]:
		_begin_propagation(status, point, bone)
	elif status == "disoriented":
		# BP_StatusEffect_Disoriented ReceiveBegin AddDeviationModifier: its accumulating duration x
		# RandomFloatInRange(DeviationModifierMin 0.85, DeviationModifierMax 1.15) (Multiplicative modifier).
		gore.set_status_duration_deviation("disoriented", randf_range(0.85, 1.15))
		# BP_Base_StatusEffect_Stun on an AI: StopActions / StopEngagementOpportunity and the Disorientated anim sets
		# (zombie_reactions, the reactions owner's hook).
		if reactions.has_method("disoriented_start"):
			reactions.call("disoriented_start")
	# Weakened: gore-core raises physical damage taken while it runs (status.rs); its look
	# (CE_StatusEffect_Weakened_Burst, PS_Enemy_Weakened_StatusFX) waits for the particle port.
	Fx.status_burst(self, status)


## DI2 DOT statuses' "Begin Propagation Effect" (BP_StatusEffect_DamageOverTime): StartEffectWithParameters(
## 'Burning' / 'Corroded', the status origin (the hit), EncodeSplatterMeshDamageParamsForPropagation(Health,
## MaxHealth, EstimatedDamage) (exe 0x14123f750: damage = est / max, health remaining = (health - est) / max), 1.0).
## EstimatedDamage = the zombie status's InitialDamage (BP_StatusEffect_Burning_Zombie 30, BP_Base_StatusEffect_-
## Corroded 15) before DI2's damage estimate modifiers (UNVERIFIED #52).
const DOT_INITIAL_DAMAGE := {"burning": 30.0, "caustic": 15.0}


func _begin_propagation(status: String, point: Vector3, bone: String) -> void:
	var maxh := maxf(gore.get_max_health(), 1.0)
	var est: float = DOT_INITIAL_DAMAGE[status]
	propagation.start_effect({"burning": "Burning", "caustic": "Corroded"}[status], point, bone, 1.0,
		{"health": (gore.get_health() - est) / maxh, "damage": est / maxh})


## BP_Base_StatusEffect_Electrocute ReceiveBegin: CE_StatusEffect_Electrocute spawned on the mesh at the spine_01
## socket with a zero rotation (its 3 m SplatterMesh, Duration 8 s, cauterisation 5), and the ElectrocuteAdditive
## anim-set montage (animation side). The spawn forward (the zombie's) is the effect direction Orient flips.
func _electrocute_look() -> void:
	var b := skeleton.find_bone("spine_01")
	if b < 0:
		return
	var at := skeleton.global_transform * skeleton.get_bone_global_pose(b).origin
	var fwd := -global_basis.z
	var rest_x: Vector3 = gore.world_dir_to_rest("spine_01", at, fwd)
	var maxh := maxf(gore.get_max_health(), 1.0)
	Flesh.apply_hit(gore, [["CE_StatusEffect_Electrocute", 0.0]], {"bone": "spine_01",
		"rest_point": gore.world_point_to_rest("spine_01", at), "rest_normal": rest_x, "rest_into": -rest_x,
		"rest_up": gore.world_dir_to_rest("spine_01", at, Vector3.UP)},
		{"health": gore.get_health() / maxh, "damage": 25.0 / maxh})


## DI2 UVisceraComponent::LimbCut (exe 0x1412450a0, recon/RE_DISMEMBER.md §12.3 "LimbCut"), once for the body
## (bIsLimb 0, plane normal +N towards the limb) and once for the severed piece (bIsLimb 1, plane -N; 0x1412b62b0):
## - a Torso-owned group (Guts, Skeleton) keeps everything on the body and is culled from the limb;
## - a Limb-owned group whose bone isn't the cut bone or above it is untouched on the body and culled from the limb;
## - otherwise each of its proxies (0x140eccd60) is tested against the plane (oriented box, extents x the group's
##   CutMargin; 0x1440a3070: +1 past the plane, 0 straddling, -1 short of it) per CutBias: Cull from 0, Body from 1
##   on the body / 0 on the limb, Limb the reverse, BodySentinel culled on the limb, LimbSentinel on the body,
##   BoxCentre only its centre (from 1; 2x extents from 0 once ruptured). A proxy at or past its threshold is culled,
##   straddling ones alternating between culled and gibbed (gib = culled and its GibbableSectionAttachment spawned:
##   not ported, UNVERIFIED #50).
func _viscera_limb_cut(piece: Node, cut_bone: String, bisect := false) -> void:
	var vb := Flesh.viscera_body(mesh_body)
	var asset := Flesh.viscera_asset(str(vb.get("viscera", "")))
	if asset.is_empty():
		return
	var pl: Dictionary = gore.last_cut_plane()
	if not pl.get("ok", false):
		return
	var o: Vector3 = pl["origin"]
	var nrm: Vector3 = pl["normal"]
	var cut := skeleton.find_bone(cut_bone)
	var passes := [false, true] if piece != null else [false]
	var culled := {"body": [], "limb": []}
	for limb_pass: bool in passes:
		var n := -nrm if limb_pass else nrm
		var w := n.dot(o)
		for g: Dictionary in asset.get("groups", []):
			var members := _group_proxies(asset, g)
			var gb := skeleton.find_bone(str(g.get("bone", "")))
			var limb_owned := str(g.get("ownership", "Torso")) == "Limb"
			if bisect and limb_owned:
				# BisectionCut (0x141236160 -> 0x140ecc800): a Limb-owned group goes whole to the side its bone is on
				# (below the cut bone = the upper piece); Torso-owned groups are cut per proxy below.
				var below := gb >= 0 and cut >= 0 and Util.is_descendant_bone(skeleton, gb, cut)
				if below != limb_pass:
					for p: Dictionary in members:
						_limb_cut_cull(p, piece, limb_pass, culled)
				continue
			var affected := (bisect and not limb_owned) or (limb_owned and gb >= 0 and cut >= 0 \
				and (gb == cut or Util.is_descendant_bone(skeleton, cut, gb)))
			if not affected:
				if limb_pass:
					for p: Dictionary in members:
						_limb_cut_cull(p, piece, true, culled)
				continue
			var margin := float(g.get("cut_margin", 0.25))
			var straddle := 0
			for p: Dictionary in members:
				var scale := margin
				var thr := 0
				match str(p.get("cut_bias", "Cull")):
					"Body":
						thr = 0 if limb_pass else 1
					"Limb":
						thr = 1 if limb_pass else 0
					"BodySentinel":
						if limb_pass:
							_limb_cut_cull(p, piece, true, culled)
						continue
					"LimbSentinel":
						if not limb_pass:
							_limb_cut_cull(p, piece, false, culled)
						continue
					"BoxCentre":
						var ruptured := float(viscera_state.get(p["key"], {}).get("damage", 0.0)) >= float(p.get("rupture_threshold", 1.0))
						scale = 2.0 if ruptured else 0.0
						thr = 0 if ruptured else 1
				var side := _box_side(n, w, p["box"]["gl"], scale)
				if side < thr:
					continue
				if side == 0:
					# Straddling: culled on both meshes; on the one where (count & 1) == bIsLimb it also spawns its
					# GibbableSectionAttachment (visitor +0x10).
					if (straddle & 1) == int(limb_pass) and piece != null:
						_spawn_gib(asset, p)
					straddle += 1
				_limb_cut_cull(p, piece, limb_pass, culled)
	flesh_log.append({"limb_cut": cut_bone, "culled": culled})


## A proxy's VisceraGibbableSubSection (BP_SkeletalMeshSubSectionAttachment_Gib, VISCERA_PARTS.md §4.3): a copy of
## the body, as posed at the cut, showing only its SubSectionNamesToSpawn, detached with physics (SpawnOnDetach-
## Module). Its collider is the proxy's box (DI2's PA_ZombieViscera* bodies aren't exported) and it inherits the
## body's velocity (UNVERIFIED #50); despawned with the limbs' "Limb" rule (60 s here).
func _spawn_gib(asset: Dictionary, p: Dictionary) -> void:
	var gib := {}
	for g: Dictionary in asset.get("gibs", []):
		if g.get("key", "") == p.get("gib", "") or g.get("proxy", "") == p.get("name", ""):
			gib = g
			break
	if gib.is_empty():
		return
	var copy := visual.duplicate() as Node3D
	var pa := Util.find_first(copy, "AnimationPlayer")
	if pa:
		pa.free()
	for n in Util.find_all(copy, "BoneAttachment3D") + Util.find_all(copy, "SkeletonModifier3D"):
		n.free()
	for a in Util.find_all(copy, "Area3D"):
		if a.has_meta("zombie"):   # the duplicated hitbox holders
			a.get_parent().free()
	var cskel: Skeleton3D = Util.find_first(copy, "Skeleton3D")
	for i in skeleton.get_bone_count():
		cskel.set_bone_pose(i, skeleton.get_bone_pose(i))
	gore.configure_gib(copy, PackedStringArray(gib.get("spawn_subsections", [])))
	# The proxy box (bind pose) carried to the world through its bone as posed now.
	var box: Dictionary = p["box"]["gl"]
	var t: Array = box["t"]
	var he: Array = box.get("half_extents", [0.05, 0.05, 0.05])
	var bone := skeleton.find_bone(str(p.get("rupture_bone", "")))
	if bone < 0:
		bone = skeleton.find_bone(str(gib.get("socket", "spine_01")))
	var c := Vector3(t[0], t[1], t[2])
	if bone >= 0:
		c = skeleton.global_transform * (skeleton.get_bone_global_pose(bone) * skeleton.get_bone_global_rest(bone).affine_inverse()) * c
	var rb := RigidBody3D.new()
	rb.collision_layer = Util.DEBRIS
	rb.collision_mask = Util.WORLD | Util.DEBRIS
	rb.mass = 1.0
	get_parent().add_child(rb)
	rb.add_to_group("gore_debris")
	rb.global_position = c
	rb.add_child(copy)
	copy.global_transform = visual.global_transform
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(maxf(float(he[0]), 0.02), maxf(float(he[1]), 0.02), maxf(float(he[2]), 0.02)) * 2.0
	shape.shape = bs
	var q: Array = box["q"]
	shape.basis = skeleton.global_basis * Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized())
	rb.add_child(shape)
	rb.linear_velocity = velocity
	get_tree().create_timer(60.0).timeout.connect(rb.queue_free)
	flesh_log.append({"gib": gib.get("name", ""), "proxy": p.get("name", "")})


## The proxies under a viscera group (FUN_140ebf5f0, nested children included; switchable groups through their
## proxy ids, as the rupture candidates walk them).
func _group_proxies(asset: Dictionary, g: Dictionary) -> Array:
	var by_key: Dictionary = asset.get("_by_key", {})
	var by_id: Dictionary = asset.get("_by_id", {})
	var out := []
	var stack: Array = (g.get("children", []) as Array).duplicate()
	while not stack.is_empty():
		var k: String = stack.pop_front()
		if by_key.has(k):
			if not out.has(by_key[k]):
				out.append(by_key[k])
				stack.append_array(by_key[k].get("children", []))
		else:
			for sg: Dictionary in asset.get("switchable_groups", []):
				if sg["key"] == k:
					for pid in sg.get("proxy_ids", []):
						if by_id.has(int(pid)) and not out.has(by_id[int(pid)]):
							out.append(by_id[int(pid)])
	return out


## FUN_1440a3070: an oriented box (glTF bind pose: centre t, rotation q, half extents x `scale`) against the plane
## n.x = w: +1 wholly past it, 0 straddling, -1 short of it.
static func _box_side(n: Vector3, w: float, box: Dictionary, scale: float) -> int:
	var t: Array = box["t"]
	var q: Array = box["q"]
	var he: Array = box.get("half_extents", [0, 0, 0])
	var r := Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized())
	var c := Vector3(t[0], t[1], t[2])
	var d := n.dot(c) - w
	var rad := absf(n.dot(r.x)) * float(he[0]) * scale + absf(n.dot(r.y)) * float(he[1]) * scale + absf(n.dot(r.z)) * float(he[2]) * scale
	if d - rad > 0.0:
		return 1
	return 0 if d + rad >= 0.0 else -1


## The visitor's cull (vtable +8, 0x14123daf0): the proxy is marked gibbed and its subsections hidden, on the body
## or on the piece.
func _limb_cut_cull(p: Dictionary, piece: Node, on_limb: bool, culled: Dictionary) -> void:
	# Everything the proxy can show: its subsections, broken ones and its switchable / ruptured variants'.
	var names: Array = (p.get("subsections", []) as Array) + (p.get("broken_subsections", []) as Array)
	var asset := Flesh.viscera_asset(str(Flesh.viscera_body(mesh_body).get("viscera", "")))
	for v: Dictionary in asset.get("switchable_variants", []):
		if v.get("proxy", "") == p.get("name", ""):
			names.append_array(v.get("subsections", []))
	if on_limb:
		if piece == null:
			return
		for nm in names:
			gore.cull_piece_subsection(piece, str(nm))
		culled["limb"].append(p.get("name", ""))
	else:
		var st: Dictionary = viscera_state.get(p["key"], {"damage": 0.0, "gibbed": false, "final": false, "k": 0})
		st["gibbed"] = true
		viscera_state[p["key"]] = st
		for nm in names:
			gore.cull_subsection(str(nm))
		culled["body"].append(p.get("name", ""))


## Moves a severed piece's non-simulated bones rigidly with its top physical bone: each frame the skeleton's
## roots get the transform that bone moved by since the cut.
class PieceFollower extends Node:
	var skel: Skeleton3D
	var body: PhysicalBone3D
	var body0 := Transform3D.IDENTITY
	var roots := {}

	func setup(s: Skeleton3D, pb: PhysicalBone3D) -> void:
		skel = s
		body = pb
		body0 = pb.global_transform
		for b in skel.get_bone_count():
			if skel.get_bone_parent(b) < 0:
				roots[b] = skel.get_bone_pose(b)

	func _physics_process(_dt: float) -> void:
		if skel == null or not is_instance_valid(body):
			return
		# How far the top body moved in the world since the cut, carried into skeleton space (the physics body is
		# the truth: the simulator's bone poses would feed this offset back in).
		var sk := skel.global_transform
		var delta := sk.affine_inverse() * (body.global_transform * body0.affine_inverse()) * sk
		for b: int in roots:
			var t: Transform3D = delta * (roots[b] as Transform3D)
			skel.set_bone_pose_position(b, t.origin)
			skel.set_bone_pose_rotation(b, t.basis.get_rotation_quaternion())


func _hold_bones_velocity(bones: Array, v: Vector3, frames: int) -> void:
	for i in frames + 1:
		for pb in bones:
			if is_instance_valid(pb):
				(pb as PhysicalBone3D).linear_velocity = v
		if i < frames:
			await get_tree().physics_frame


func _hold_velocity(rb: RigidBody3D, v: Vector3, frames: int) -> void:
	rb.linear_velocity = v
	for i in frames:
		await get_tree().physics_frame
		if not is_instance_valid(rb):
			return
		rb.linear_velocity = v


func _di2_cut(piece: Node, bone_name: String) -> bool:
	if last_impact.is_empty():
		return false
	var gd := Flesh.gradual_damage()
	var eff_name := _gradual_effect_name(bone_name, false)
	var eff: Dictionary = gd.get("effects", {}).get(eff_name, {})
	if eff.is_empty():
		return false
	var info: Dictionary = eff["initial"]["info"]
	var params := Flesh.params_for(info)
	if params.is_empty():
		return false
	var fr := Flesh.orient({}, {}, 0.0, last_impact)
	var ok := gore.di2_cut(piece, bone_name, last_impact.get("rest_point", Vector3.ZERO), fr[0], fr[1], fr[2],
		float(Flesh._v(info, "UVScale")), params, str(Flesh._v(info, "SplatterType")) == "DismemberWithDecal")
	if ok:
		flesh_log.append({"di2_cut": bone_name, "effect": eff_name})
		_viscera_limb_cut(piece, bone_name, _bisecting)
		_gradual_particles(eff, last_impact)
		_gradual_over_time(eff, fr, last_impact.duplicate())
		_gradual_initial_fluid(eff, last_impact)
	return ok


## The wound's gradual damage effect (DA_ContextualGradualDamageEffectList_AI, 0x1412a1120): the first candidate whose
## requirement holds, with {Hit}.Dismember / {Hit}.BoneBreak from the wound type, {Hit}.BoneName and #Beheaded.
func _gradual_effect_name(bone_name: String, breaking: bool) -> String:
	for c: Dictionary in Flesh.gradual_damage().get("candidates", []):
		var expr := " ".join((c.get("requirements", []) as Array).map(func(r: Dictionary) -> String: return str(r.get("OwnerKBExpression", ""))))
		if expr.contains("{Hit}.BoneName"):
			if breaking and expr.contains("{Hit}.Dismember"):
				continue
			var bones := []
			for m in RegEx.create_from_string("BoneName == \"(\\w+)\"").search_all(expr):
				bones.append(m.get_string(1))
			if bone_name in bones:
				return str(c["effect"])
		elif expr.contains("#Beheaded"):
			if not breaking and bone_name in ["head", "neck_01", "neck_02"]:
				return str(c["effect"])
		elif expr.strip_edges() == "{Hit}.Dismember":
			if not breaking:
				return str(c["effect"])
		elif expr.strip_edges() == "{Hit}.BoneBreak":
			if breaking:
				return str(c["effect"])
	return ""


## The gradual effect's ParticleSystem (+0x310; RequestGradualDamageEffect 0x1412ae1f0 -> spawn-attached 0x143745a30):
## attached to the wound bone at the wound transform (the hit location, rotation LastHitRotation: writer untraced, the
## hit's travel direction here as for the over-time fluid, UNVERIFIED #54), auto-destroying.
func _gradual_particles(eff: Dictionary, impact: Dictionary) -> void:
	var ps := str(eff.get("particle_system", "")) if eff.get("particle_system") != null else ""
	var bone := str(impact.get("bone", ""))
	if ps == "" or not hit_particles or skeleton.find_bone(bone) < 0:
		return
	var fwd: Vector3 = impact.get("dir_world", Vector3.ZERO)
	var base := HitEffectSpawn.point_basis(fwd, fwd, 1.0) if fwd.length_squared() > 1e-8 else Basis.IDENTITY
	DI2Particles.play_ps(_hit_attachment(bone), ps, Transform3D(base, impact.get("point", global_position)), true)


## The wound's InitialEffect fluid (0x14129a8e0, after RequestGradualDamageEffect): one request at the hit location
## (LastHitLocation) with FVector::ZeroVector velocity (the request's 0x146cbd598 compare) and InitialEffect.FluidAmount.
## FluidStrength rides along as a set optional to the payload (flow strength: not ported).
func _gradual_initial_fluid(eff: Dictionary, impact: Dictionary) -> void:
	var fl: Variant = eff.get("initial", {}).get("fluid")
	if not (fl is Dictionary) or not ((fl as Dictionary).get("FluidType") is Dictionary):
		return
	var t := _fluid_type_name(fl["FluidType"])
	var amount_v: Variant = fl["FluidAmount"] if fl.get("FluidAmount") != null else GRADUAL_FLUID_DEFAULTS.get("FluidAmount")
	if amount_v == null:
		return
	var amount := float(amount_v)
	var fm := DI2Fluids.of(self)
	if fm and hit_fluids:
		fm.request(t, impact.get("point", global_position), Vector3.ZERO, amount)


static func _fluid_type_name(ref: Dictionary) -> String:
	return str(ref.get("ObjectName", "")).get_slice("'", 1).replace("DA_FluidTypeInfo_", "")


## The gradual effect's over-time instance (RequestGradualDamageEffect 0x1412ae1f0 -> timer callback 0x14129b260,
## recon/RE_DISMEMBER.md §2.1, RE_FLUIDS.md §8). The timer period is 0.2 s when OverTimeEffect's splatter does
## anything ((SplatterType & 0xFE) != 0 or a decal texture), else EmmissionPeriod when it has a FluidType (none if < 0),
## else Duration (none if <= 0). Each update, dt = the period: elapsed += dt; with a FluidType and n * EmmissionPeriod
## <= elapsed, one fluid request (n += 1) at the wound (the hit point carried by the bone) with velocity = the hit's
## forward, held in the bone's frame, x EmissionVelocity and FluidAmount; then a splatter type != None re-applies the
## splatter (Modify'd, DisplacementScale x dt / Duration, the other amounts not scaled) at the wound transform; the
## instance ends once elapsed >= Duration. The wound's forward is DI2's LastHitRotation (writer untraced: the hit's
## travel direction here, UNVERIFIED #54).
func _gradual_over_time(eff: Dictionary, fr: Array, impact: Dictionary) -> void:
	var ot: Dictionary = eff.get("over_time", {})
	var info: Dictionary = ot.get("info", {})
	var fluid: Dictionary = ot["fluid"] if ot.get("fluid") is Dictionary else {}
	var duration := float(eff.get("duration", 0.0))
	var em_period := float(eff.get("emission_period", 0.0))
	var bone := str(impact.get("bone", ""))
	var b := skeleton.find_bone(bone)
	if b < 0:
		return
	var stype := str(Flesh._v(info, "SplatterType"))
	var textures := false
	for k in ["DiffuseDecalTexture", "DisplacementDecalTexture", "InternalDisplacementDecalTexture"]:
		textures = textures or Flesh._v(info, k) != null
	var fluid_type := _fluid_type_name(fluid["FluidType"]) if fluid.get("FluidType") is Dictionary else ""
	var period := 0.0
	if (int(Flesh.SPLATTER_TYPES.get(stype, 1)) & 0xFE) != 0 or textures:
		period = 0.2
	elif fluid_type != "":
		period = em_period
		if period < 0.0:
			return
	else:
		period = duration
		if period <= 0.0:
			return
	# The wound in the bone's frame (the instance's relative transform).
	var bone_xf := skeleton.global_transform * skeleton.get_bone_global_pose(b)
	var local_point: Vector3 = bone_xf.affine_inverse() * (impact.get("point", bone_xf.origin) as Vector3)
	var local_fwd: Vector3 = bone_xf.basis.inverse() * (impact.get("dir_world", Vector3.ZERO) as Vector3)
	var amount_v: Variant = fluid["FluidAmount"] if fluid.get("FluidAmount") != null else GRADUAL_FLUID_DEFAULTS.get("FluidAmount")
	var speed_v: Variant = fluid["EmissionVelocity"] if fluid.get("EmissionVelocity") != null else GRADUAL_FLUID_DEFAULTS.get("EmissionVelocity")
	if amount_v == null or speed_v == null:
		fluid_type = ""   # an unknown native default: no emission rather than a guess
	var amount := float(amount_v) if amount_v != null else 0.0
	var speed := float(speed_v) if speed_v != null else 0.0
	var splat := stype != "None" and not info.is_empty()
	var elapsed := 0.0
	var emitted := 0
	while is_instance_valid(gore) and is_inside_tree():
		await get_tree().create_timer(maxf(period, 0.0), false, true).timeout
		if not is_instance_valid(gore) or not is_inside_tree():
			return
		var dt := maxf(period, get_physics_process_delta_time())
		elapsed += dt
		if fluid_type != "" and emitted * em_period <= elapsed:
			emitted += 1
			var xf := skeleton.global_transform * skeleton.get_bone_global_pose(b)
			var fm := DI2Fluids.of(self)
			if fm and hit_fluids:
				fm.request(fluid_type, xf * local_point, (xf.basis * local_fwd) * speed * DI2Fluids.CM, amount)
		if splat and duration > 0.0:
			var tick := info.duplicate()
			tick["DisplacementScale"] = float(Flesh._v(info, "DisplacementScale")) * dt / duration
			var params := Flesh.params_for(tick)
			if not params.is_empty():
				gore.add_stamp_posed(params, bone, impact.get("rest_point", Vector3.ZERO), fr[0], fr[1], fr[2])
		if duration <= 0.0 or elapsed >= duration:
			return


func _burst_head(bone_name: String, point: Vector3, dir: Vector3) -> void:
	var cut := skeleton.find_bone(bone_name)
	for area in hitboxes:
		if is_instance_valid(area) and Util.is_descendant_bone(skeleton, skeleton.find_bone(area.get_meta("bone")), cut):
			area.get_parent().queue_free()
	if cut >= 0:
		gore.add_cut_caps(null, bone_name)
	# The Walker's own skull, brain and jaw pieces fly from where they sat, with DI2's breakage shards.
	var head := skeleton.find_bone("head")
	var from_rest := Transform3D.IDENTITY
	if head >= 0:
		from_rest = skeleton.global_transform * skeleton.get_bone_global_pose(head) * skeleton.get_bone_global_rest(head).affine_inverse()
	Fx.gibs(get_parent(), point, dir, 6, "Head", from_rest)
	Fx.blood_burst(get_parent(), point, Vector3.UP + dir * 0.5, 60, 4.0)


func _release_token() -> void:
	if has_token:
		has_token = false
		attack_tokens = max(0, attack_tokens - 1)


func _exit_tree() -> void:
	_release_token()


func _die(hit_bone: String, dir: Vector3, force: float) -> void:
	if dead:
		return
	_release_token()
	dead = true
	died.emit(self)
	collision_layer = 0
	anim.stop(true)   # keep the pose: the ragdoll starts from the animated pose (ZombieAnim stops on `dead`)
	dangling.active = false
	phys.active = false
	# DI2's death tree: a DeathAction montage ragdolls at its notify, a launch ragdolls with its impulses.
	if not reactions.start_death(hit_bone, dir, force):
		_start_ragdoll(hit_bone, dir, force)
	get_tree().create_timer(90.0).timeout.connect(queue_free)


## DI2's PA_ZombieStandard: its bodies (shapes, masses, damping) and its constraints (cone/twist limits about
## DI2's constraint frames). Bodies a few joints apart never collide with each other, like the physics asset's
## disabled pairs, so the solver can't pry the neck or shoulders apart.
func _start_ragdoll(hit_bone: String, dir: Vector3, force: float) -> void:
	ragdoll = PhysicalBoneSimulator3D.new()
	skeleton.add_child(ragdoll)
	var made := _build_ragdoll(ragdoll, func(bone: int) -> bool: return not _is_gone(bone))
	ragdoll.physical_bones_start_simulation()
	var hb := skeleton.find_bone(hit_bone)
	var body := phys.body_for(hb) if hb >= 0 else -1
	var pb_hit: PhysicalBone3D = made.get(hit_bone, made.get(skeleton.get_bone_name(body) if body >= 0 else "spine_03", made.get("spine_03")))
	if pb_hit:
		pb_hit.apply_central_impulse(dir.normalized() * clamp(force, 5.0, 60.0) * 0.6 + Vector3.UP * 2.0)


## A hit on a ragdolled corpse pushes the hit bone's body (the recreation's death-impulse scale; DI2's corpse impulse
## from the impact's PhysicalizedReactionMagnitude / WorldSpaceImpulseMagnitude is not traced, UNVERIFIED).
func _ragdoll_impulse(bone: String, dir: Vector3, force: float) -> void:
	if ragdoll == null or force <= 0.0:
		return
	var b := skeleton.find_bone(bone)
	while b >= 0:
		var pb := ragdoll.get_node_or_null("PB_" + skeleton.get_bone_name(b)) as PhysicalBone3D
		if pb:
			pb.apply_central_impulse(dir.normalized() * clamp(force, 5.0, 60.0) * 0.6)
			return
		b = skeleton.get_bone_parent(b)


## PA_ZombieStandard's bodies and constraints as PhysicalBone3Ds under `sim` (a PhysicalBoneSimulator3D on this
## zombie's skeleton or on a severed piece's copy, same bone order), for the bones `keep` accepts. Returns
## {bone name: PhysicalBone3D}.
func _build_ragdoll(sim: PhysicalBoneSimulator3D, keep: Callable, root_bone := "") -> Dictionary:
	var spec := PhysicalReaction.load_spec()
	var joints := {}
	for c: Dictionary in spec["constraints"]:
		joints[c["child"]] = c
	var bodies: Array = spec["bodies"].filter(func(b): return not b["kinematic"] and skeleton.find_bone(b["bone"]) >= 0)
	# A severed piece whose cut bone has no PA body (e.g. spine_04: PA_ZombieStandard goes spine_03 -> neck /
	# clavicles) gets a small one there, so its top bodies joint to it instead of falling apart.
	if root_bone != "" and not bodies.any(func(b): return b["bone"] == root_bone):
		bodies.append({"bone": root_bone, "mass": 4.0, "linear_damp": 0.1, "angular_damp": 0.3, "kinematic": false,
			"shapes": [{"type": "sphere", "radius": 0.08, "center": [0, 0, 0]}]})
	bodies.sort_custom(func(a, b): return _depth(skeleton.find_bone(a["bone"])) < _depth(skeleton.find_bone(b["bone"])))
	var made := {}
	for b: Dictionary in bodies:
		var bone := skeleton.find_bone(b["bone"])
		if not keep.call(bone):
			continue
		var pb := PhysicalBone3D.new()
		pb.name = "PB_" + b["bone"]
		pb.bone_name = b["bone"]
		pb.collision_layer = Util.DEBRIS
		pb.collision_mask = Util.WORLD | Util.DEBRIS
		pb.mass = maxf(0.5, float(b["mass"]))
		pb.linear_damp = float(b["linear_damp"])
		pb.angular_damp = maxf(0.3, float(b["angular_damp"]))
		pb.friction = 0.9
		for sh: Dictionary in b["shapes"]:
			pb.add_child(_ragdoll_shape(sh))
		var j: Dictionary = joints.get(b["bone"], {})
		if j.is_empty() or not made.has(_ragdoll_parent(bone, made)):
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
		else:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_6DOF
			pb.joint_offset = Transform3D(_basis9(j["basis"]), _vec3(j["pos"]) * body_scale)
			# UE: twist about the primary axis (x), swing1 about z, swing2 about y. 0 = locked, -1 = free.
			for pair in [["x", j["twist"]], ["y", j["swing2"]], ["z", j["swing1"]]]:
				var lim: float = pair[1]
				pb.set("joint_constraints/%s/angular_limit_enabled" % pair[0], lim >= 0.0)
				pb.set("joint_constraints/%s/angular_limit_upper" % pair[0], maxf(lim, 0.0))
				pb.set("joint_constraints/%s/angular_limit_lower" % pair[0], -maxf(lim, 0.0))
				pb.set("joint_constraints/%s/linear_limit_enabled" % pair[0], true)
				pb.set("joint_constraints/%s/linear_limit_upper" % pair[0], 0.0)
				pb.set("joint_constraints/%s/linear_limit_lower" % pair[0], 0.0)
		sim.add_child(pb)
		made[b["bone"]] = pb
	# Collision exceptions between bodies within three joints of each other.
	var names: Array = made.keys()
	for a in names.size():
		for c in range(a + 1, names.size()):
			if _joint_hops(skeleton.find_bone(names[a]), skeleton.find_bone(names[c]), made) <= 3:
				made[names[a]].add_collision_exception_with(made[names[c]])
	return made


func _ragdoll_shape(sh: Dictionary) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var at := _vec3(sh["center"]) * body_scale
	match sh["type"]:
		"capsule":
			var c := CapsuleShape3D.new()
			c.radius = float(sh["radius"]) * body_scale
			c.height = maxf(float(sh["height"]) * body_scale, c.radius * 2.0 + 0.001)
			cs.shape = c
			cs.transform = Transform3D(_basis9(sh["basis"]), at)
		"sphere":
			var sp := SphereShape3D.new()
			sp.radius = float(sh["radius"]) * body_scale
			cs.shape = sp
			cs.position = at
		"box":
			var bx := BoxShape3D.new()
			bx.size = _vec3(sh["size"]) * body_scale
			cs.shape = bx
			cs.transform = Transform3D(_basis9(sh["basis"]), at)
	return cs


func _vec3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _basis9(a: Array) -> Basis:
	return Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])).orthonormalized()


## Bone (or an ancestor) cut off or burst: no ragdoll body for it.
func _is_gone(bone: int) -> bool:
	var b := bone
	while b >= 0:
		if HITBOXES.has(skeleton.get_bone_name(b)):
			return _is_severed(b)
		b = skeleton.get_bone_parent(b)
	return false


func _ragdoll_parent(bone: int, made: Dictionary) -> String:
	var p := skeleton.get_bone_parent(bone)
	while p >= 0 and not made.has(skeleton.get_bone_name(p)):
		p = skeleton.get_bone_parent(p)
	return skeleton.get_bone_name(p) if p >= 0 else ""


func _joint_hops(a: int, b: int, made: Dictionary) -> int:
	var chain_a := []
	var x := a
	while x >= 0:
		if made.has(skeleton.get_bone_name(x)):
			chain_a.append(x)
		x = skeleton.get_bone_parent(x)
	var hops := 0
	x = b
	while x >= 0:
		if made.has(skeleton.get_bone_name(x)):
			var i := chain_a.find(x)
			if i >= 0:
				return i + hops
			hops += 1
		x = skeleton.get_bone_parent(x)
	return 99


func _depth(bone: int) -> int:
	var d := 0
	while bone >= 0:
		bone = skeleton.get_bone_parent(bone)
		d += 1
	return d


func _is_severed(bone: int) -> bool:
	return not hitboxes.any(func(a): return is_instance_valid(a) and a.get_meta("bone") == skeleton.get_bone_name(bone))


func _play_once(name: String, lock: float, _blend := 0.12) -> void:
	if anim.has_animation(name) or not anim_ctl.montage_for(name).is_empty():
		anim_ctl.play(name)   # as DI2's montage for the clip (its BlendIn / BlendOut), see zombie_anim.gd
		lock_time = lock


func _physics_process(delta: float) -> void:
	if dead:
		return
	for e in gore.take_events():
		if e == "killed_by_status":
			_die("spine_03", Vector3.UP, 5.0)
			return
	lock_time = max(lock_time - delta, 0.0)
	if reactions.update(delta):
		anim_ctl.root_motion(delta)   # zombie_reactions moves the capsule by the montage; drop the base layer's share
		return
	var to_target := Vector3.ZERO
	var dist := 99.0
	var can_see := false
	if is_instance_valid(target) and not target.get("dead"):
		to_target = target.global_position - global_position
		to_target.y = 0
		dist = to_target.length()
		can_see = dist < 30.0
	var cmd: Dictionary = gore.think(delta, dist, can_see)
	# The Rust brain keeps stagger / fall-to-crawl / death; DI2's card dealer decides everything else.
	if ai == null:
		ai = ZombieAI.new(self, family())
	if str(cmd.get("anim", "")) in ["Stagger", "Fall", "Death"]:
		ai.interrupt()
	else:
		cmd = ai.think(delta, dist, can_see, target)
	var crawling := gore.is_crawling()

	var use_rm := anim_ctl.rm_locomotion and not crawling
	var rm: Dictionary = anim_ctl.root_motion(delta) if use_rm else {}
	# Facing. Root-motion locomotion turns by the clips plus DI2's steering spring (zombie_anim.gd _rm_tick); while a
	# montage plays (attacks) the capsule keeps the CharMoveComp turn (UNVERIFIED: DI2's attack facing).
	if use_rm:
		rotation.y += float(rm["yaw"])
	if cmd.get("face", false) and dist > 0.05 and (not use_rm or anim_ctl.a.active() != null):
		var want := atan2(-to_target.x, -to_target.z)
		# Standing: BP_Base_Walker CharMoveComp (DIAICharacterMovementComponent) RotationRate Yaw 110 deg/s.
		rotation.y = rotate_toward(rotation.y, want, delta * deg_to_rad(110.0 if not crawling else 90.0))

	# Locomotion along facing (DI2 zombies steer straight at you in open ground).
	var speed: float = cmd.get("speed", 0.0)
	var fwd := -global_transform.basis.z
	if use_rm:
		velocity.x = rm["velocity"].x + knock.x
		velocity.z = rm["velocity"].z + knock.z
	else:
		velocity.x = fwd.x * speed + knock.x
		velocity.z = fwd.z * speed + knock.z
	knock = knock.move_toward(Vector3.ZERO, delta * 6.0)
	velocity.y = velocity.y - 9.8 * delta if not is_on_floor() else -0.1
	move_and_slide()

	# Attacks (only with an attack token).
	token_t -= delta
	if has_token and token_t <= 0.0:
		_release_token()
	var attack: String = cmd.get("attack", "")
	# DI2 rations attackers with AttackRules (zombie_ai.gd), not a token count: an AI attack always starts.
	if attack != "" and (ai != null or has_token or attack_tokens < MAX_ATTACKERS):
		if not has_token:
			attack_tokens += 1
			has_token = true
		token_t = float(cmd.get("attack_len", 1.6))
		if str(cmd.get("clip", "")) != "":
			attack_anim = str(cmd["clip"])
		elif crawling:
			attack_anim = "crawl_attack_l" if gore.arm_usable(true) else "crawl_attack_r"
		else:
			attack_anim = _attack_clip(attack, dist)
		_play_once(attack_anim, float(cmd.get("attack_len", anim.get_animation(attack_anim).length * 0.85 if anim.has_animation(attack_anim) else 0.9)), 0.1)
	var dmg: float = cmd.get("damage", 0.0)
	if dmg > 0.0 and has_token and is_instance_valid(target) and target.has_method("take_zombie_hit"):
		if dist < 2.1 and to_target.normalized().dot(fwd) > 0.4:
			if not ((ai.is_grapple() if ai != null else attack_anim.begins_with("attack_grapple")) and target.has_method("start_grapple") and target.start_grapple(self)):
				target.take_zombie_hit(dmg * level_damage_scale(), self)

	# Root-motion locomotion: the direction to face / move and DistanceToFinalDestination. The port's brain has no
	# path: 0 when it commands no speed (stop now), else unbounded (UNVERIFIED stand-in for the AI's path distance).
	var rm_want := to_target.normalized() if cmd.get("face", false) and dist > 0.05 else Vector3.ZERO
	var rm_dest := 0.0 if speed <= 0.0 else INF
	anim_ctl.move_dir = cmd.get("move_dir", Vector3.ZERO)   # strafe cards: AnimState_Move StrafeAngle (zombie_anim.gd _strafe_angle)
	if lock_time > 0.0:
		if use_rm:
			anim_ctl.drive("Attack", 0.0, crawling, rm_want, 0.0)   # the base locomotion keeps stepping under the montage
		return
	_drive_animation(cmd.get("anim", "Idle"), speed, crawling, rm_want, rm_dest)


func _drive_animation(state: String, speed: float, crawling: bool, face_dir := Vector3.ZERO, dest := INF) -> void:
	var want := ""
	match state:
		"Idle":
			want = "idle"
		"Alert":
			want = "alert"
		"Chase", "Walk":
			want = _nearest_clip(WALK_CLIPS, speed)
		"Crawl":
			want = _nearest_clip(CRAWL_CLIPS, speed)
		"CrawlIdle":
			want = "crawl_idle"
		"Stagger":
			if anim_ctl.rm_locomotion and not crawling:
				anim_ctl.drive(state, 0.0, crawling, face_dir, 0.0)
			return   # the brain's stagger window only pauses it: DI2's hit-react trees play the reaction (zombie_reactions.gd)
		"Fall":
			_play_once("fall_leg_" + lost_leg_side, 1.2, 0.1)
			return
		"Attack", "CrawlAttack":
			if anim_ctl.rm_locomotion and not crawling:
				anim_ctl.drive(state, 0.0, crawling, face_dir, 0.0)
			return
	# DI2 Base_Locomotion / Crawler_Locomotion state machine with its blend spaces (zombie_anim.gd).
	anim_ctl.drive(state, speed, crawling, face_dir, dest)


## The locomotion clip whose measured root-motion speed is closest to `speed`, so playback rate stays near 1.
func _nearest_clip(clips: Array, speed: float) -> String:
	var best: String = clips[0]
	for c: String in clips:
		if anim.has_animation(c) and absf(clip_speed.get(c, 0.0) - speed) < absf(clip_speed.get(best, 0.0) - speed):
			best = c
	return best


## DI2 picks swipe length by distance (Short / Med / Long) and alternates hands and heights.
func _attack_clip(card: String, dist: float) -> String:
	var length := "short" if dist < 1.2 else ("med" if dist < 1.7 else "long")
	var height := "horiz" if randf() < 0.6 else "vert"
	var c := ""
	match card:
		"LeftHandSwipe":
			c = "attack_swipe_lh_%s_attack_%s" % [height, length]
		"RightHandSwipe":
			c = "attack_swipe_rh_%s_attack_%s" % [height, length]
		"Grapple":
			c = "attack_grapple_intomoving_med"
		"Bite":
			c = "attack_bite_attack_short" if dist < 1.2 else "attack_bite_attack_med"
	if not anim.has_animation(c):
		c = ATTACK_ANIMS.get(card, "attack_swipe_r")
	return c


## DI2's Curve_DamageModifierConfig_EnemyDamageScaling by (enemy level - player level).
func level_damage_scale() -> float:
	var player_level: int = target.get("level") if target and target.get("level") != null else 1
	var diff := clampi(level - player_level, -5, 5)
	var keys := [[-5, 0.25], [-4, 0.5], [-3, 1.0], [0, 1.0], [1, 1.25], [2, 1.35], [5, 1.4]]
	for i in range(keys.size() - 1):
		if diff >= keys[i][0] and diff <= keys[i + 1][0]:
			var w := float(diff - keys[i][0]) / float(keys[i + 1][0] - keys[i][0])
			return lerpf(keys[i][1], keys[i + 1][1], w)
	return 1.0
