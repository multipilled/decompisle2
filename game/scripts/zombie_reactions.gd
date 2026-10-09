class_name ZombieReactions
extends RefCounted
## DI2 hit reactions for a Zombie, chosen and run the way DI2's UHitDeathReactions component does
## (recon/HIT_REACTS.md, recon/ANIMATION.md 8):
##   select(): the impact's facts ({Hit}.* / {Victim}.* / {Attacker}.*, hit_facts) -> the archetype's HitReactTreeSet ->
##     one CT_HitReact_* tree -> its ordered responses (scripts/hit_react_trees.gd, data/hit_reacts.json);
##   execute(): each response as DI2 runs it:
##     MinorAnimatedFlinch       layered montage (LHR_UpperBody / LHR_FullBody slot) at the remapped max weight
##     MajorAnimatedFlinch       full-body montage (DefaultSlot), root motion, the AI waits for it
##     AnimatedKnockback         the same (stumbles / DuringRecovery)
##     KnockdownAction           KO montage; at its "HitReactRagdoll" notify the Ragdoll action takes over
##     DeathAction               death montage, ragdoll (dead) at the notify (zombie._die -> start_death)
##     Ragdoll                   Ragdoll action now
##     LaunchingImpact           LaunchCharacterAction: root + mesh point + angular impulses into the Ragdoll action
##     KnowledgeBaseCounter      a timed victim fact (StopActions, LegHitSlowdownCooldown ...)
##     SpawnablePart             jaw / eye parts (zombie.spawn_part / detach_part)
##   the Ragdoll action (BP_Action_Ragdoll_AI): on the ground and resting -> ZeroStabilityDuration 0.6 s -> stability
##     recharges over DA_AttributeType_AIKnockdownDuration (impacts while down: 1.0 s) -> StandUp action: the StandUp
##     anim set by StandingUpPosition, the ragdoll's last pose fading out over RagdollBlendOutTime (PoseSnapshot).
## Montages play through z.anim_ctl (DI2Anim, data/montages_zombie.json) and carry their root motion like a UE montage
## under RootMotionFromMontagesOnly. A montage whose sequences the body's glb lacks (hit_reacts.json clips_missing)
## is skipped and logged, never replaced by a similar clip. Paired clips (grapple, counter) keep the old path.

## BP_Action_Ragdoll_AI CDO: ZeroStabilityDuration, MinimumRechargeDuration; OnImpactReceived's TimeToFullyRecharge.
const RAGDOLL_ZERO_STABILITY := 0.6
const RAGDOLL_MIN_RECHARGE := 0.4
const RAGDOLL_IMPACT_RECHARGE := 1.0
## BP_Action_Ragdoll_AI: EnableCollisionDetection after 0.3 s; GuardingAgainstHitReactInterruption released 0.2 s after
## the ragdoll begins; StopActions released 0.3 s after it ends (BlueprintDecrementCounterFact delays).
const RAGDOLL_GUARD_RELEASE := 0.2
## BPC_PhysicalizedHitReact_AI CDO: RagdollBlendOutTime (ragdoll -> animation at the stand-up).
const RAGDOLL_BLEND_OUT := 1.0
const BLEND_OUT_CURVE := "Curve_PhysicalizedReactions_RagdollBlendWeightToPhysicsBlendWeight_BlendOut_AI"
## UStandUpCharacterAction ctor (exe 0x141df9cb0): +0xbc = 2.0, the longest capsule alignment to the get-up.
const STANDUP_ALIGN_MAX := 2.0
const STOP_ACTIONS_AFTER_RAGDOLL := 0.3

static var extra := {}

var z: Zombie
var report: Dictionary          # <body>.anims.json: per clip length + root track
var state := ""                 # "", "react", "ko", "ragdoll", "getup", "stun", "paired", "death"
var clip := ""
var t := 0.0                    # time into the current one-shot
var length := 0.0
var root: Array = []            # current clip's root track [[x, y, z, yaw], ...] (skeleton space, rel. frame 0)
var root_rate := 30.0
var prev_root := Vector4.ZERO
var downed := false             # lying on the ground (stomps / ground attacks)
var dying := false              # a DeathAction montage is playing on a dead zombie
var on_done: Callable
var mon: DI2Anim.Montage        # the montage of the current one-shot
var root_clip := ""             # clip whose root track prev_root was read from
var paired_active := false      # node sits on the paired sync origin; the clip's root bone holds the offset
var knockdown_range := Vector2(3.5, 5.0)   # DA_AIAttributeValues_<type>.KnockdownDuration (RandomInRange)
static var archetype_data: Array = []

var clock := 0.0                # seconds since spawn (timed knowledge-base facts)
var kb := {}                    # lower-case fact -> expiry (clock); KnowledgeBaseCounterResponse
var plan := {}                  # the current impact's selection: {facts, tree, responses, ...}
var last := {}                  # the last selection (logs / tests)
var ko_ragdoll_at := -1.0       # montage time of the KO / death montage's HitReactRagdoll notify
var action := ""                # DI2 action name of the running reaction (MajorAnimatedFlinch, AnimatedKnockback ...)
var am := ""                    # DI2 montage of the running reaction
var layered: DI2Anim.Montage    # the playing layered flinch
var rag_phase := ""             # ragdoll: "air", "settle", "recharge"
var rag_t := 0.0
var rag_rest_t := 0.0
var recharge_total := 0.0
var recharge_left := 0.0
var rag_collision := 0
var stand_position := ""        # StandingUpPosition of the current get-up
var snap_t := -1.0              # time into the ragdoll -> stand-up snapshot fade (-1 = none)
var death_args := []
var history: Array = []         # per-impact selections (tree + response log), newest last; tests read it


func _init(owner: Zombie) -> void:
	z = owner
	var path := "res://assets/di2/%s/%s.anims.json" % [z.body, z.body]
	report = Util.load_json(path) if FileAccess.file_exists(path) else {}
	if archetype_data.is_empty():
		archetype_data = Util.load_json("res://data/archetypes.json")
	if extra.is_empty():
		extra = Util.load_json("res://data/hit_react_extra.json")
	for a: Dictionary in archetype_data:
		if a["name"] == z.archetype and a.has("knockdown_duration"):
			knockdown_range = Vector2(a["knockdown_duration"][0], a["knockdown_duration"][1])


func busy() -> bool:
	return state != ""


func _has(name: String) -> bool:
	return z.anim.has_animation(name)


func _pick(candidates: Array) -> String:
	for c: String in candidates:
		if _has(c):
			return c
	return ""


# --- facts --------------------------------------------------------------------------------------------------------

## A timed knowledge-base fact is set.
func has_kb(fact: String) -> bool:
	return float(kb.get(fact.to_lower(), -1.0)) > clock


func _weapon_facts(id: String) -> Dictionary:
	return extra.get("weapons", {}).get(id, {}) if id != "" else {}


## The attacker's held weapon id (the player's KB WeaponClass is the held weapon's, whatever the move).
func _held_weapon(attacker: Node3D, hit: Dictionary) -> String:
	if attacker and attacker.get("weapon") != null:
		return str(attacker.get("weapon"))
	return str(hit.get("weapon", ""))


## Victim-side facts that change over time ({Victim}.X and bare).
func victim_facts() -> Dictionary:
	var v := {}
	var fam := z.family()
	var hd: Dictionary = HitReactTrees.archetype(fam).get("hit_death_reactions", {})
	# BP_Base_AI.InitHitReactBalacingData: CanBeLaunched ? LaunchWeightScalar : -1; the DT_EnemyGenericData row's CTIs.
	v["LaunchWeightScalar"] = float(hd.get("LaunchWeightScalar", 1.0)) if bool(hd.get("CanBeLaunched", false)) else -1.0
	for k: String in extra.get("victims", {}).get(fam, {}):
		v[k] = float(extra["victims"][fam][k])
	v["StabilityFraction"] = stability_fraction()
	v["Crawler"] = z.gore.is_crawling()
	v["Dead"] = z.dead
	v["Ragdoll"] = state == "ragdoll"
	v["RagdollLanded"] = state == "ragdoll" and rag_phase != "air"
	v["RagdollResting"] = state == "ragdoll" and rag_phase in ["settle", "recharge"]
	v["Knockdown"] = state in ["ko", "ragdoll"]
	v["Downed"] = downed
	v["StandingUp"] = state == "getup"
	v["AnimatedKnockback"] = state == "react" and action == "AnimatedKnockback"
	v["MajorAnimatedFlinch"] = state == "react" and action == "MajorAnimatedFlinch"
	v["Grapple"] = state == "paired"
	v["KOStun"] = has_kb("KOStun")
	v["Disoriented"] = z.gore.is_status_active("disoriented")
	var maxh := maxf(z.gore.get_max_health(), 1.0)
	v["HealthFraction"] = z.gore.get_health() / maxh
	# BPC_MultiPartHealth_<type> parts (gore-core ids) as HealthFraction_<PartId>; parts the port doesn't track read 1.
	var ps: Dictionary = z.gore.part_states()
	for id: String in {"head": "Head", "arm_left": "Arm_Left", "arm_right": "Arm_Right", "leg_left": "Leg_Left", "leg_right": "Leg_Right"}:
		var key: String = {"head": "Head", "arm_left": "Arm_Left", "arm_right": "Arm_Right", "leg_left": "Leg_Left", "leg_right": "Leg_Right"}[id]
		var p: Dictionary = ps.get(id, {})
		var frac := 1.0
		if not p.is_empty():
			frac = 0.0 if str(p.get("state", "intact")) == "severed" else float(p.get("health", 1.0)) / maxf(float(p.get("max", 1.0)), 1e-4)
		v["HealthFraction_" + key] = frac
	for k in ["HealthFraction_Torso_Bisectable", "HealthFraction_Arm_Left_Blade", "HealthFraction_Arm_Right_Blade"]:
		v[k] = 1.0 if k == "HealthFraction_Torso_Bisectable" else 0.0
	v["speed"] = Vector2(z.velocity.x, z.velocity.z).length() * 100.0
	var st: Dictionary = z.gore.status_states()
	v["statuseffect_electrocute"] = float(st.get("electrified", 0.0)) > 0.0
	for f: String in Zombie.ARCHETYPE_FACTS.get(z.family(), []):
		v[f] = true
	for f in HitReactTrees.archetype(fam).get("ArchetypeSpecificFacts", []):
		v[str(f)] = true
	for f: String in z.part_facts:
		v[f] = z.part_facts[f]
	# Scoped facts of the playing montages (BP_AnimNotifyState_ScopedFacts_* FactsArray windows).
	for f: String in _scoped_facts():
		v[f] = true
	# Attack sub-action facts (AIMeleeSubAction_*: native melee action phases; the port's attack montage stands in:
	# WindUp montages -> FixedWindUp, the attack montage -> Attack; UNVERIFIED boundaries).
	if z.attack_anim != "" and z.lock_time > 0.0:
		v["AIMeleeSubAction_FixedWindUp" if z.attack_anim.contains("windup") else "AIMeleeSubAction_Attack"] = true
	if state == "ragdoll" and rag_t < RAGDOLL_GUARD_RELEASE:
		v["GuardingAgainstHitReactInterruption"] = true
	for f: String in kb:
		if float(kb[f]) > clock:
			v[f] = true
	return v


## Facts of ScopedFacts notify windows on the playing montages: BP_ScopedFacts_<Fact>[_C] (FactsArray = [<Fact>] for
## every class the zombie montages use: Stumbling, GuardingAgainstHitReactInterruption, AttackRecoveryState ...).
func _scoped_facts() -> Array:
	var out := []
	for m: DI2Anim.Montage in z.anim_ctl.a.slot:
		if m.stopped or not m.d.has("notifies"):
			continue
		for n: Array in m.d["notifies"]:
			var nm := str(n[0])
			if float(n[2]) <= 0.0 or not nm.begins_with("BP_ScopedFacts_"):
				continue
			if m.pos >= float(n[1]) and m.pos < float(n[1]) + float(n[2]):
				out.append(nm.trim_prefix("BP_ScopedFacts_").trim_suffix("_C"))
	return out


func stability_fraction() -> float:
	if state == "ragdoll":
		# BPC_Base_Stability_AI drains stamina on Knockdown || Launch || Ragdoll; the Ragdoll action recharges it.
		if rag_phase != "recharge" or recharge_total <= 0.0:
			return 0.0
		return HitReactTrees.curve_keys(extra.get("curves", {}).get("Curve_StabilityRecharge_Float", []),
			1.0 - recharge_left / recharge_total)
	return z.gore.get_stability()


## The impact's facts. `hit` = the attacker's side (weapon, HeavyAttack, CriticalHit, ThrownAttack, Counter*, Kick,
## facts{}); `res` = GoreBody.hit_ex outcomes. Lower-case keys, scoped and bare (HitReactTrees).
func build_facts(res: Dictionary, hit: Dictionary, bone: String, dir: Vector3, force: float, heavy: bool, kind: String, attacker: Node3D, corpse: bool) -> Dictionary:
	var h := {}
	var weapon_id := str(hit.get("weapon", ""))
	var wf := _weapon_facts(weapon_id)
	var held := _weapon_facts(_held_weapon(attacker, hit))
	h["Force"] = float(hit.get("Force", force))
	h["KillingBlow"] = not corpse and not res.get("alive", true)
	h["HeavyAttack"] = bool(hit.get("HeavyAttack", heavy))
	for k in ["CriticalHit", "ThrownAttack", "CounterAction", "CounterPush", "CounterKill", "Slide", "ClassExclusiveKick",
			"FlyingKick", "ShoulderBarge", "GrappleKickExit", "PairedAnimImpact", "ControlledFallImpact", "Flurry", "Rapid",
			"FluidImpact", "ArmouredTorsoImpact"]:
		h[k] = bool(hit.get(k, false))
	h["Counter"] = h["CounterAction"] or h["CounterPush"] or h["CounterKill"] or bool(hit.get("isPaired", false)) and bool(hit.get("Counter", false))
	# Dani's kick plays CT_HitEffect_Kick (player_moves.gd); DI2's kick impact carries {Hit}.Kick.
	h["Kick"] = bool(hit.get("Kick", str(hit.get("tree", "")) == "CT_HitEffect_Kick"))
	var outs: Array = res.get("outcomes", [])
	h["Dismembered"] = outs.any(func(o: Dictionary) -> bool: return o.get("type", "") == "dismembered")
	h["Broken"] = outs.any(func(o: Dictionary) -> bool: return o.get("type", "") == "broken")
	# BP_DamageType_Blunt sets bCanDismember false, BP_DamageType_Sharp bCanBreak false (both default true).
	h["CanDismember"] = kind != "blunt"
	h["CanBreak"] = kind != "sharp"
	# FImpactSettings: bCanLaunch (default false), LaunchSettings (impact-provided), bCanCauseCosmeticFlinches
	# (default true) from the weapon's ImpactConfiguration (data/hit_react_extra.json).
	h["CanLaunch"] = bool(hit.get("CanLaunch", wf.get("can_launch", false) == true))
	h["OverrideLaunchSettings"] = wf.get("launch_settings") != null and str(wf.get("launch_settings", "")) != ""
	h["CanCauseCosmeticFlinches"] = bool(hit.get("CanCauseCosmeticFlinches", true))
	h["ImpactGameplayCategory"] = "Ranged" if kind == "projectile" else "Melee"
	h["ImpactEventType"] = "Radial" if hit.get("explosion_origin") is Vector3 else str(hit.get("ImpactEventType", ""))
	if wf.get("weapon_class"):
		h["WeaponClass"] = str(wf["weapon_class"])
	h["ImpactMod"] = str(hit.get("mod", "")) == "impact"
	for k: String in hit.get("facts", {}):
		h[k] = hit["facts"][k]
	# Body-part facts: every DT_ZombiePartBoneDefinition row listing the hit bone (UNVERIFIED #H4).
	var pb := HitReactTrees.part_bone(z.skeleton, bone)
	for p in HitReactTrees.part_ids(pb):
		h[p] = true
	# Direction facts (exe 0x1412c6a20): the unit vector toward the hit's source in the victim's frame (UE X forward,
	# Y right, Z up). Point impacts: -HitFromDirection (= -trace travel); radial: from the root toward the origin.
	var v := -dir
	if hit.get("explosion_origin") is Vector3:
		v = (hit["explosion_origin"] as Vector3) - z.global_position
	if v.length_squared() < 1e-8:
		v = -z.global_basis.z
	v = v.normalized()
	var fwd := -z.global_basis.z
	var right := z.global_basis.x
	var d := Vector3(v.dot(fwd), v.dot(right), v.y)
	for k: String in HitReactTrees.direction_facts(d):
		h[k] = true
	# Posture (exe 0x1412c6920): the root's forward against the root's up; the capsule stays upright (#H11).
	h[HitReactTrees.posture_fact(0.0)] = true
	var f := {}
	for k: String in h:
		f["hit." + k.to_lower()] = h[k]
		f[k.to_lower()] = h[k]
	var vf := victim_facts()
	# HitReactInterrupt (#H9): BP_Base_AIController.DetermineIfVulnerableDebug's rule, the only one in DI2's data -
	# KB.Evaluate(VulnerableRequirement_<the player's WeaponClass>); an unknown weapon class is not vulnerable.
	var wc := str(held.get("weapon_class", "")) if held.get("weapon_class") else ""
	var arch := HitReactTrees.archetype(z.family())
	var vk := lower_merge(f, vf)
	vf["HitReactInterrupt"] = wc != "" and DI2Expr.eval(str(arch.get("VulnerableRequirement_" + wc, "False")), vk)
	for k: String in vf:
		f["victim." + k.to_lower()] = vf[k]
		if not f.has(k.to_lower()):
			f[k.to_lower()] = vf[k]
	f["attacker.weaponstabbing"] = bool(Flesh.weapon(weapon_id).get("stabbing", false))
	f["attacker.isfurymode"] = bool(hit.get("IsFuryMode", false))
	f["_bone"] = bone
	return f


static func lower_merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := a.duplicate()
	for k: String in b:
		out["victim." + k.to_lower()] = b[k]
		if not out.has(k.to_lower()):
			out[k.to_lower()] = b[k]
	return out


# --- selection / execution ----------------------------------------------------------------------------------------

## Evaluates DI2's trees for an impact (before zombie.take_hit applies a kill, so a DeathAction can play).
func select(res: Dictionary, hit: Dictionary, bone: String, point: Vector3, dir: Vector3, force: float, heavy: bool, kind: String, attacker: Node3D, corpse: bool) -> Dictionary:
	var f := build_facts(res, hit, bone, dir, force, heavy, kind, attacker, corpse)
	var sel := HitReactTrees.evaluate(z.family(), f)
	plan = {"facts": f, "tree": sel["tree"], "responses": sel["responses"], "bone": bone, "point": point, "dir": dir,
		"force": float(f.get("hit.force", force)), "hit": hit, "attacker": attacker, "log": []}
	last = plan
	return plan


## Runs the selected responses (the ones a death doesn't own; DeathAction / death Ragdoll wait for start_death()).
func execute() -> void:
	if plan.is_empty():
		return
	var lg: Array = plan["log"]
	for r: Dictionary in plan["responses"]:
		var cls := str(r.get("class", ""))
		match cls:
			"SpawnCosmeticEffectResponse":
				lg.append("CE " + str(r.get("Definition", "")))   # vocal / sound only (no zombie audio in the port)
			"KnowledgeBaseCounterResponse":
				# A timed victim fact; a missing Duration (PairedAnimImpact's StopActions) is native (#H10): one frame.
				kb[str(r.get("Fact", "")).to_lower()] = clock + float(r.get("Duration", 0.0))
				lg.append("KB %s %.2f" % [r.get("Fact", ""), float(r.get("Duration", 0.0))])
			"MinorAnimatedFlinchHitReactResponse":
				_flinch(r, "MinorAnimatedFlinch")
			"MajorAnimatedFlinchHitReactResponse":
				_flinch(r, "MajorAnimatedFlinch")
			"BP_AnimatedKnockbackHitReactResponse_AI_C", "AnimatedKnockbackHitReactResponse":
				_flinch(r, "AnimatedKnockback")
			"KnockdownActionResponse":
				_knockdown(r)
			"DeathActionResponse":
				plan["death"] = r
				lg.append("DeathAction (on death)")
			"RagdollResponse":
				if z.dead or bool(plan["facts"].get("hit.killingblow", false)):
					plan["death_ragdoll"] = true
					lg.append("Ragdoll (on death)")
				else:
					start_ragdoll({})
			"LaunchingImpactResponse":
				_launch(r)
			"SpawnablePartResponse":
				for s in r.get("Slots", []):
					var slot := str(s).get_slice("::", 1)
					if bool(r.get("bSpawn", false)):
						z.spawn_part(slot)
					if bool(r.get("bDetach", false)):
						z.detach_part(slot)
					lg.append("Part %s spawn=%s detach=%s" % [slot, r.get("bSpawn", false), r.get("bDetach", false)])
			"ProceduralHitReactResponse":
				# DA_ProceduralAnimationReactions_AI (ProceduralAnimationReactionComponent) is not ported; the impact's
				# physicalized reaction (physical_reaction.gd) runs for every hit in zombie.take_hit.
				lg.append("ProceduralHitReact strength %.0f" % HitReactTrees.remap(r.get("StrengthQueryValueRemapSettings", {}),
					DI2Expr.num(DI2Expr.value(str(r.get("StrengthQueryValueExpression", "0")), plan["facts"])), plan["facts"]))
			"ApplyStatusEffectResponse":
				# BP_StatusEffect_KnockdownStun (LargeSpecial knockdown): KOStun until stability recovers (UNVERIFIED).
				kb["kostun"] = clock + float(r.get("StatusEffectDuration", 0.0))
				lg.append("Status " + str(r.get("StatusEffectType", "")))
			_:
				lg.append(cls + " (not ported)")
	history.append({"tree": plan["tree"], "responses": lg})
	if history.size() > 64:
		history = history.slice(-64)


## The full-body flinch / knockback montages DI2 plays as actions (MajorAnimatedFlinch, AnimatedKnockback) and the
## layered MinorAnimatedFlinch: the anim set's montage, play rate 1 + uniform(negative, positive deviation) and the
## max weight from the range remapper (both native samplings, UNVERIFIED #H13).
func _flinch(r: Dictionary, act: String) -> void:
	var lg: Array = plan["log"]
	if z.dead or (act != "MinorAnimatedFlinch" and state in ["ko", "ragdoll", "getup", "paired", "death"]):
		lg.append(act + " ignored (" + state + ")")
		return
	var f: Dictionary = plan["facts"]
	var vel_local := Vector3(z.velocity.dot(-z.global_basis.z), z.velocity.dot(z.global_basis.x), z.velocity.y) * 100.0
	var name := HitReactTrees.pick_montage(z.family(), str(r.get("AnimSetName", "")), f, vel_local.length(), vel_local)
	if name == "":
		lg.append("%s %s: no montage" % [act, r.get("AnimSetName", "")])
		return
	var rate := 1.0 + randf_range(float(r.get("MontagePlayRateNegativeDeviation", 0.0)), float(r.get("MontagePlayRatePositiveDeviation", 0.0)))
	var m := z.anim_ctl.play_montage(name, rate)
	if m == null:
		lg.append("%s %s: %s has no clip in %s" % [act, r.get("AnimSetName", ""), name, z.body])
		return
	var cap := 1.0
	if bool(r.get("bSpecifyMaxMontagePlayWeightUsingRangeRemapper", false)):
		var q := DI2Expr.num(DI2Expr.value(str(r.get("MaxMontagePlayWeightQueryValueExpression", "0")), f))
		cap = HitReactTrees.remap(r.get("MaxMontagePlayWeightQueryValueRemapSettings", {}), q, f)
	cap = clampf(cap + float(r.get("MontagePlayWeightDeviation", 0.0)) * randf(), 0.0, 1.0)
	if cap < 1.0:
		var bi: Array = m.d.get("blend_in", [0.1, "HermiteCubic"])
		m.weight = DI2Anim.Blend.new(0.0, cap, float(bi[0]), str(bi[1]))
	lg.append("%s %s -> %s rate %.2f weight %.2f" % [act, r.get("AnimSetName", ""), name, rate, cap])
	if act == "MinorAnimatedFlinch" and m.layer != "":
		layered = m
		return
	_start_montage(m, name, act, "react")
	z.attack_anim = ""


func _start_montage(m: DI2Anim.Montage, name: String, act: String, new_state: String) -> void:
	if paired_active:
		_commit_paired_root()
	mon = m
	am = name
	action = act
	state = new_state
	clip = m.current_clip()
	t = 0.0
	length = m.length
	root_clip = ""


## KnockdownActionResponse: the KO montage (anim set or ReactionMontageChoices); its "HitReactRagdoll" notify hands the
## body to the Ragdoll action (the 149 KO montages all end with it). Without the montage's clip the ragdoll starts now.
func _knockdown(r: Dictionary) -> void:
	var lg: Array = plan["log"]
	if z.dead or state in ["ko", "ragdoll", "getup", "paired"]:
		lg.append("KnockdownAction ignored (" + ("dead" if z.dead else state) + ")")
		return
	var name := _action_montage(r)
	var m: DI2Anim.Montage = z.anim_ctl.play_montage(name, 1.0) if name != "" else null
	if m == null:
		lg.append("KnockdownAction %s: %s -> ragdoll now" % [r.get("AnimSetName", ""), "no clip for " + name if name != "" else "no montage"])
		start_ragdoll({})
		return
	_start_montage(m, name, "Knockdown", "ko")
	ko_ragdoll_at = _ragdoll_notify(name, m.length)
	_hold_until_ragdoll(m)
	downed = true
	z.attack_anim = ""
	lg.append("KnockdownAction %s -> %s ragdoll at %.2f" % [r.get("AnimSetName", ""), name, ko_ragdoll_at])


func _action_montage(r: Dictionary) -> String:
	var choices: Array = r.get("ReactionMontageChoices", [])
	if not choices.is_empty():
		return str(choices[randi() % choices.size()])
	var vel_local := Vector3(z.velocity.dot(-z.global_basis.z), z.velocity.dot(z.global_basis.x), z.velocity.y) * 100.0
	return HitReactTrees.pick_montage(z.family(), str(r.get("AnimSetName", "")), plan.get("facts", {}), vel_local.length(), vel_local)


## The KO / death montages put HitReactRagdoll at their very end with a 0 s blend-out; UE fires the notify on that
## update, before the montage blends out, so the ragdoll starts from the last KO frame. Here the montage holds that
## frame until start_ragdoll() takes over (it may run a frame later than the animation update).
func _hold_until_ragdoll(m: DI2Anim.Montage) -> void:
	m.d = m.d.duplicate()
	m.d["auto_blend_out"] = false


## Montage time of a KO / death montage's HitReactRagdoll notify (named "HitReactRagdoll" or "Hit React Ragdoll").
func _ragdoll_notify(name: String, fallback: float) -> float:
	for n: Array in z.anim_ctl.notifies(name):
		if str(n[0]).replace(" ", "") == "HitReactRagdoll":
			return float(n[1])
	return fallback


## zombie._die: a DeathAction plays its montage first and ragdolls at the notify (true = handled here); an already
## ragdolled body just stays down. false = zombie starts its death ragdoll now.
func start_death(hit_bone: String, dir: Vector3, force: float) -> bool:
	if state == "ragdoll" and z.ragdoll:
		state = ""
		rag_phase = ""
		downed = true
		return true
	if not plan.get("facts", {}).get("hit.killingblow", false):
		return false
	var r := {}
	for x: Dictionary in plan.get("responses", []):
		match str(x.get("class", "")):
			"DeathActionResponse":
				r = x
				break
			"LaunchingImpactResponse":
				# CT_HitReact_Death_Zombie -> Launch_Zombie: the dead body is launched (ragdoll with the impulses).
				var s := _launch_settings(_launch_asset(x))
				if s.is_empty():
					return false
				var imp := LaunchMath.impulses(s, z, plan, extra)
				plan["log"].append("Launch (death) root %s angular %s" % [imp["root"], imp["angular"]])
				z._start_ragdoll(hit_bone, Vector3.ZERO, 0.0)
				_apply_impulses.call_deferred(imp)
				return true
			"RagdollResponse":
				return false
	if r.is_empty():
		return false
	var name := _action_montage(r)
	var rate := 1.0 + randf_range(float(r.get("MontagePlayRateNegativeDeviation", 0.0)), float(r.get("MontagePlayRatePositiveDeviation", 0.0)))
	var m: DI2Anim.Montage = z.anim_ctl.play_montage(name, rate) if name != "" else null
	if m == null:
		plan["log"].append("DeathAction: %s -> ragdoll now" % ("no clip for " + name if name != "" else "no montage"))
		return false
	_start_montage(m, name, "Death", "death")
	dying = true
	death_args = [hit_bone, dir, force]
	ko_ragdoll_at = _ragdoll_notify(name, m.length)
	_hold_until_ragdoll(m)
	plan["log"].append("DeathAction %s rate %.2f ragdoll at %.2f" % [name, rate, ko_ragdoll_at])
	# zombie._physics_process stops on death: the montage runs on ZombieAnim, the hand-off on a timer.
	z.get_tree().create_timer(maxf(ko_ragdoll_at / maxf(rate, 0.05), 0.0), false, true).timeout.connect(_death_ragdoll)
	return true


func _death_ragdoll() -> void:
	if not dying or not is_instance_valid(z):
		return
	dying = false
	state = ""
	z._start_ragdoll(death_args[0], death_args[1], death_args[2])


# --- ragdoll / launch / stand-up ----------------------------------------------------------------------------------

## The Ragdoll action (RagdollCharacterAction + BP_Action_Ragdoll_AI) on a living zombie. `imp`: the launch's
## {root (m/s), point: [[velocity m/s, world point, bone]], angular (deg/s)}.
func start_ragdoll(imp: Dictionary) -> void:
	if state == "ragdoll" or z.dead:
		return
	if paired_active:
		_commit_paired_root()
	z.anim_ctl.a.stop_montages(0.0)
	if z.ragdoll == null:
		z.ragdoll = PhysicalBoneSimulator3D.new()
		z.skeleton.add_child(z.ragdoll)
		z._build_ragdoll(z.ragdoll, func(b: int) -> bool: return not z._is_gone(b))
	z.ragdoll.active = true
	z.ragdoll.influence = 1.0
	z.ragdoll.physical_bones_start_simulation()
	z.phys.active = false
	rag_collision = z.collision_layer
	z.collision_layer = 0   # DI2 switches the capsule to the RagdollPawn profile; the port's capsule just steps aside
	state = "ragdoll"
	action = "Ragdoll"
	rag_phase = "air"
	rag_t = 0.0
	rag_rest_t = 0.0
	recharge_total = 0.0
	recharge_left = 0.0
	downed = true
	mon = null
	clip = ""
	z.attack_anim = ""
	if not imp.is_empty():
		_apply_impulses.call_deferred(imp)
	plan.get("log", []).append("Ragdoll")


## The pose the ragdoll shows, per bone in world space: a simulated bone is its body's transform without the body
## offset (PhysicalBone3D body_offset); a bone without a body hangs off its parent with its animated local pose. (The
## skeleton's bone poses keep the animation's values; the simulator only overrides what is drawn.)
func ragdoll_world_pose() -> Array:
	var skel := z.skeleton
	var n := skel.get_bone_count()
	var by_bone := {}
	if z.ragdoll and z.ragdoll.active:
		for b: PhysicalBone3D in _bodies():
			by_bone[skel.find_bone(b.bone_name)] = b
	var out := []
	out.resize(n)
	for b in z.anim_ctl.a.order:
		if by_bone.has(b):
			var pb: PhysicalBone3D = by_bone[b]
			out[b] = pb.global_transform * pb.body_offset.affine_inverse()
		else:
			var par := skel.get_bone_parent(b)
			out[b] = ((out[par] as Transform3D) if par >= 0 else skel.global_transform) * skel.get_bone_pose(b)
	return out


func _bodies() -> Array:
	var out := []
	if z.ragdoll:
		for c in z.ragdoll.get_children():
			if c is PhysicalBone3D:
				out.append(c)
	return out


## The launch's impulses when the Ragdoll action's physics starts (RagdollStateComponent, exe 0x141284eb0 ->
## 0x14126b5c0 / 0x14126b820 / 0x141269d90): the root velocity (capped at 10000 cm/s) added to every body (mesh vfunc
## +0xa68, all bodies below the root), each mesh impulse as a velocity change on its bone's body (vfunc +0x5f8,
## AddImpulse(v, Bone, bVelChange); 10000 cm/s cap; a bone without a body: its nearest ancestor with one), the angular
## velocity (capped at 3600 deg/s, in radians) added to every body (vfunc +0x7c8).
func _apply_impulses(imp: Dictionary) -> void:
	# The bodies take velocities once they simulate (the first physics step after physical_bones_start_simulation).
	await z.get_tree().physics_frame
	if not is_instance_valid(z) or z.ragdoll == null:
		return
	var bodies := _bodies()
	if bodies.is_empty():
		return
	var rv: Vector3 = (imp.get("root", Vector3.ZERO) as Vector3).limit_length(100.0)
	var av: Vector3 = (imp.get("angular", Vector3.ZERO) as Vector3).limit_length(3600.0)
	for b: PhysicalBone3D in bodies:
		b.linear_velocity += rv
		b.angular_velocity += av * (PI / 180.0)
	var by_bone := {}
	for b: PhysicalBone3D in bodies:
		by_bone[str(b.bone_name)] = b
	for p: Array in imp.get("point", []):
		var bi := z.skeleton.find_bone(str(p[2]))
		while bi >= 0 and not by_bone.has(z.skeleton.get_bone_name(bi)):
			bi = z.skeleton.get_bone_parent(bi)
		if bi >= 0:
			(by_bone[z.skeleton.get_bone_name(bi)] as PhysicalBone3D).linear_velocity += (p[0] as Vector3).limit_length(100.0)


## LaunchingImpactResponse -> LaunchCharacterAction (exe 0x1413e2830, 0x1411bc500, 0x1411a4e00, 0x1411a5e10,
## 0x1411a5240, 0x1411a3d50): the launch settings (the impact's own when bUseImpactProvidedLaunchSettings and the
## impact provides some, else OverrideLaunchSettings), then with bApplyRagdoll (ULaunchSettings ctor default true;
## no dumped settings clear it) the Ragdoll action with the root, mesh point and angular impulses.
func _launch(r: Dictionary) -> void:
	var lg: Array = plan["log"]
	if z.dead or state == "ragdoll":
		lg.append("Launch ignored (" + ("dead" if z.dead else state) + ")")
		return
	var asset := _launch_asset(r)
	var s := _launch_settings(asset)
	if s.is_empty():
		lg.append("Launch: no settings (%s)" % asset)
		return
	var imp := LaunchMath.impulses(s, z, plan, extra)
	lg.append("Launch %s root %s point %d angular %s" % [asset, imp["root"], (imp["point"] as Array).size(), imp["angular"]])
	if bool(s.get("bApplyRagdoll", true)):
		start_ragdoll(imp)


## LaunchingImpactResponse::Execute (0x1413e2830): bUseImpactProvidedLaunchSettings (default true) takes the impact's
## settings (the weapon's ImpactConfiguration.LaunchSettings; the response returns if it provides none), else
## OverrideLaunchSettings.
func _launch_asset(r: Dictionary) -> String:
	if bool(r.get("bUseImpactProvidedLaunchSettings", true)):
		var w = _weapon_facts(str(plan["hit"].get("weapon", ""))).get("launch_settings")
		return str(w) if w != null else ""
	var o = r.get("OverrideLaunchSettings")
	return str(o) if o != null else ""


func _launch_settings(asset: String) -> Dictionary:
	if asset == "":
		return {}
	var s: Dictionary = extra.get("launch_settings", {}).get(asset, {})
	if s.is_empty():
		s = HitReactTrees.launch_settings(asset)
	return s


func _update_ragdoll(delta: float) -> void:
	rag_t += delta
	var bodies := _bodies()
	var lin := 0.0
	var ang := 0.0
	var low := INF
	for b: PhysicalBone3D in bodies:
		lin = maxf(lin, b.linear_velocity.length())
		ang = maxf(ang, b.angular_velocity.length())
		low = minf(low, b.global_position.y)
	match rag_phase:
		"air":
			# RagdollLanded / RagdollResting are native (RagdollStateComponent); the port: every body slower than
			# 0.2 m/s and 30 deg/s after the first 0.3 s (UNVERIFIED thresholds).
			if rag_t > 0.3 and lin < 0.2 and ang < deg_to_rad(30.0):
				rag_rest_t += delta
				if rag_rest_t > 0.1:
					rag_phase = "settle"
					rag_rest_t = 0.0
			else:
				rag_rest_t = 0.0
		"settle":
			# OnRagdollAndOnGround -> ZeroStabilityDuration timer -> OnZeroStabilityDurationOver.
			rag_rest_t += delta
			if rag_rest_t >= RAGDOLL_ZERO_STABILITY:
				rag_phase = "recharge"
				recharge_total = maxf(randf_range(knockdown_range.x, knockdown_range.y), RAGDOLL_MIN_RECHARGE)
				recharge_left = recharge_total
		"recharge":
			recharge_left -= delta
			if recharge_left <= 0.0:
				_stand_up()


## A hit while ragdolled (BP_Action_Ragdoll_AI OnImpactReceived after the zero-stability timer): the stability
## recharge restarts with TimeToFullyRecharge 1.0 s.
func ragdoll_impact() -> void:
	if state == "ragdoll" and rag_phase == "recharge":
		recharge_total = RAGDOLL_IMPACT_RECHARGE
		recharge_left = RAGDOLL_IMPACT_RECHARGE


## The StandUp action: StandingUpPosition from the lying body, the StandUp anim set's montage, the ragdoll's last pose
## as a PoseSnapshot fading out over RagdollBlendOutTime, the node placed so the get-up starts where the body lies.
func _stand_up() -> void:
	var skel := z.skeleton
	stand_position = standing_up_position()
	var f := victim_facts()
	f["StandingUpPosition"] = stand_position
	var lf := HitReactTrees.lower_keys(f)
	for k: String in f:
		lf["victim." + k.to_lower()] = f[k]
	var name := HitReactTrees.pick_montage(z.family(), "StandUp", lf)
	# The ragdoll pose, kept in world space while the node moves.
	var world := ragdoll_world_pose()
	z.ragdoll.physical_bones_stop_simulation()
	z.ragdoll.queue_free()
	z.ragdoll = null
	z.collision_layer = rag_collision
	z.phys.active = true
	z.gore.reset_stability()
	var m: DI2Anim.Montage = z.anim_ctl.play_montage(name, 1.0) if name != "" else null
	if m != null:
		_align_to_lying(name, world)
	# Snapshot = the ragdoll's world pose expressed under the node where it now stands.
	var a := z.anim_ctl.a
	a.snapshot_pos.resize(a.nb)
	a.snapshot_rot.resize(a.nb)
	var inv := skel.global_transform.affine_inverse()
	for b in a.nb:
		var p := skel.get_bone_parent(b)
		var g: Transform3D = inv * (world[b] as Transform3D)
		var local := g if p < 0 else (inv * (world[p] as Transform3D)).affine_inverse() * g
		a.snapshot_pos[b] = local.origin
		a.snapshot_rot[b] = local.basis.get_rotation_quaternion()
	a.snapshot_w = 1.0
	snap_t = 0.0
	plan.get("log", []).append("StandUp %s -> %s" % [stand_position, name])
	if m == null:
		downed = false
		state = ""
		snap_t = 0.0
		return
	_start_montage(m, name, "StandUp", "getup")


## StandingUpPosition of the lying body (UStandUpCharacterAction, exe 0x141209860 -> 0x141209680): with the actor's up
## vector U and the ragdoll root transform's X (forward) / Y (right) axes, U.X <= -cos 45 -> FaceDown, >= cos 45 ->
## FaceUp, else U.Y <= -cos 45 -> OnRightSide, else OnLeftSide (EStandUpOrientation 0..3). The anim set reads the
## fact as 'Front' / 'Back' / 'Left' / 'Right' (FaceDown -> Front: the enum -> FName table 0x141209920 isn't read; the
## pairing follows the KO_Recovery_F/B/L/R first frames, recon/ANIMATION.md). The ragdoll root transform (native,
## RagdollStateComponent +0x9c0) stands in as the pelvis carrying the character's rest-pose facing.
const STANDUP_NAMES := ["Front", "Back", "Left", "Right"]


func standing_up_position() -> String:
	var skel := z.skeleton
	var pb := skel.find_bone("pelvis")
	if pb < 0:
		return "Back"
	var axes := _pelvis_facing_axes()
	var g := (ragdoll_world_pose()[pb] as Transform3D).basis.orthonormalized()
	var fwd: Vector3 = g * axes[0]
	var right: Vector3 = g * axes[1]
	var up := z.global_basis.y.normalized()
	var d1 := up.dot(fwd)
	var o := 0
	if d1 <= -0.70710677:
		o = 0
	elif d1 >= 0.70710677:
		o = 1
	else:
		o = 3 if up.dot(right) <= -0.70710677 else 2
	return STANDUP_NAMES[o]


## The character's forward / right in the pelvis bone's frame, from the rest pose standing on the node.
func _pelvis_facing_axes() -> Array:
	var skel := z.skeleton
	var pb := skel.find_bone("pelvis")
	var rest := (z.global_transform.affine_inverse() * skel.global_transform * skel.get_bone_global_rest(pb)).basis.orthonormalized()
	var inv := rest.inverse()
	return [(inv * Vector3(0, 0, -1)).normalized(), (inv * Vector3(1, 0, 0)).normalized()]


## Turns and moves the node so the get-up montage's first-frame pelvis lands on the lying pelvis (heading and ground
## position); DI2 aligns the capsule to the montage's start over <= STANDUP_ALIGN_MAX seconds using its root motion.
func _align_to_lying(name: String, world: Array) -> void:
	var skel := z.skeleton
	var pb := skel.find_bone("pelvis")
	if pb < 0:
		return
	var cur: Transform3D = world[pb]
	var seg: Array = z.anim_ctl.zdata["montages"][name]["segments"].get(z.body, [])
	if seg.is_empty():
		return
	var c := str(seg[0][0])
	var xf := _clip_bone_world(c, "pelvis", float(seg[0][2]))
	var h_cur := Vector2(cur.basis.x.x, cur.basis.x.z)
	var h_new := Vector2(xf.basis.x.x, xf.basis.x.z)
	if h_cur.length() > 0.2 and h_new.length() > 0.2:
		var dyaw := -h_new.angle_to(h_cur)
		var pivot := cur.origin
		var rel := z.global_position - pivot
		z.global_position = pivot + rel.rotated(Vector3.UP, dyaw)
		z.rotate_y(dyaw)
	var moved := _clip_bone_world(c, "pelvis", float(seg[0][2]))
	z.global_position += Vector3(cur.origin.x - moved.origin.x, 0.0, cur.origin.z - moved.origin.z)


## World pose of `bone` if clip `c` were shown at `time` on the node as it stands.
func _clip_bone_world(c: String, bone: String, time := 0.0) -> Transform3D:
	var skel := z.skeleton
	var an := z.anim.get_animation(c)
	var chain := []
	var b := skel.find_bone(bone)
	while b >= 0:
		chain.push_front(b)
		b = skel.get_bone_parent(b)
	var xf := Transform3D.IDENTITY
	for bi: int in chain:
		var bn := skel.get_bone_name(bi)
		var pos := skel.get_bone_rest(bi).origin
		var rot := skel.get_bone_rest(bi).basis.get_rotation_quaternion()
		var tp := an.find_track(NodePath("%s:%s" % [_skel_path(an), bn]), Animation.TYPE_POSITION_3D)
		var tr := an.find_track(NodePath("%s:%s" % [_skel_path(an), bn]), Animation.TYPE_ROTATION_3D)
		if tp >= 0:
			pos = an.position_track_interpolate(tp, time)
		if tr >= 0:
			rot = an.rotation_track_interpolate(tr, time)
		xf = xf * Transform3D(Basis(rot), pos)
	return skel.global_transform * xf


var _skel_track_path := ""


func _skel_path(an: Animation) -> String:
	if _skel_track_path == "":
		for i in an.get_track_count():
			var np := an.track_get_path(i)
			if np.get_subname_count() > 0:
				_skel_track_path = str(np).get_slice(":", 0)
				break
	return _skel_track_path


# --- legacy entry points ------------------------------------------------------------------------------------------

## A stability hit without a wound (perfect blocks, shoves, grapple-exit push): DI2's trees with the shove as the
## impact (spine_03, no damage).
func on_stagger(push: Vector3, force: float, attacker: Node3D = null) -> void:
	if z.dead:
		return
	if attacker == null and is_instance_valid(z.target):
		attacker = z.target   # the player's held weapon is the KB WeaponClass the vulnerability rule reads
	select({"alive": true, "outcomes": []}, {"Force": force}, "spine_03", z.global_position, push.normalized(), force, force >= 35.0, "blunt", attacker, false)
	execute()


func stun_start() -> void:
	if z.dead or state in ["ko", "ragdoll", "getup", "paired"]:
		return
	var c := _pick(["statusfx_electrocuted_start_01", "statusfx_electrocuted_loop_01"])
	if c != "":
		_start(c, "stun")


## DI2 Disoriented status (BP_StatusEffect_Disoriented, a BP_Base_StatusEffect_Stun): on an AI it raises the KB
## counter facts StopActions and StopEngagementOpportunity (ReceiveBegin / ReceiveEnd) and runs
## DA_ActionDefinition_Stun_Disorientated_AI: IntoAnimSet "Disorientated" (DA_AnimSet_Disorientated_Zombie), then
## OutroAnimSet "DisorientatedEnd" once the status ends (z.gore.is_status_active("disoriented")). AnimPlayRate 1 +- 20 %
## (AnimPlayRateVariationPercentage 20); the anim set's random stream is seeded with RandomInteger(20).
## UNVERIFIED: the Into set is re-picked when its montage ends while the status lasts (DI2 loop behaviour).
var _diso_rng := RandomNumberGenerator.new()

func disoriented_start() -> void:
	if z.dead or state in ["ko", "ragdoll", "getup", "paired", "death"]:
		return
	kb["stopactions"] = INF
	kb["stopengagementopportunity"] = INF
	_diso_rng.seed = randi_range(0, 19)
	_play_set("Disorientated", "disoriented")


func _diso_end() -> void:
	kb.erase("stopactions")
	kb.erase("stopengagementopportunity")
	if not _play_set("DisorientatedEnd", "react"):
		_finish()


## Plays the montage anim set `set_name` picks for this zombie (ZombieAI.pick_set_montage) in `new_state`.
func _play_set(set_name: String, new_state: String) -> bool:
	var arch: String = z.ai.arch if z.ai != null else z.family()
	var name := ZombieAI.pick_set_montage(arch, set_name, victim_facts(), _diso_rng)
	var m: DI2Anim.Montage = z.anim_ctl.play_montage(name, 1.0 + randf_range(-0.2, 0.2)) if name != "" else null
	if m == null:
		return false
	mon = m
	clip = ""
	am = name
	action = ""
	root = []
	state = new_state
	t = 0.0
	length = m.length
	return true


func play_paired(name: String, then: Callable = Callable()) -> bool:
	if not _has(name):
		return false
	_start(name, "paired")
	on_done = then
	return true


func _start(name: String, new_state: String) -> void:
	# Entering or leaving a paired sequence changes where the body hangs off the node: no crossfade across it.
	var snap := (new_state == "paired") != paired_active
	if paired_active and new_state != "paired":
		_commit_paired_root()
	paired_active = new_state == "paired"
	clip = name
	state = new_state
	action = ""
	am = ""
	t = 0.0
	root_clip = ""
	mon = z.anim_ctl.play(name, 1.0, 0.0 if snap else -1.0)
	length = mon.length if mon else z.anim.get_animation(name).length


func _root_at(time: float) -> Vector4:
	if root.is_empty():
		return Vector4.ZERO
	var f := clampf(time * root_rate, 0.0, root.size() - 1.0)
	var i := int(f)
	var j := mini(i + 1, root.size() - 1)
	var a: Array = root[i]
	var b: Array = root[j]
	var w := f - i
	return Vector4(lerpf(a[0], b[0], w), lerpf(a[1], b[1], w), lerpf(a[2], b[2], w), lerpf(a[3], b[3], w))


## Advances the reaction. Returns true while it owns the zombie (no brain movement / attacks).
func update(delta: float) -> bool:
	clock += delta
	if state != "disoriented" and kb.get("stopactions", 0.0) == INF and not z.gore.is_status_active("disoriented"):
		kb.erase("stopactions")   # the status ended while another reaction played (ReceiveEnd decrements)
		kb.erase("stopengagementopportunity")
	if snap_t >= 0.0:
		_update_snapshot(delta)
	if layered and layered.dead():
		layered = null
	if state == "":
		return has_kb("StopActions")
	t += delta
	if state == "ragdoll":
		_update_ragdoll(delta)
		return true
	if state == "disoriented":
		if not z.gore.is_status_active("disoriented"):
			_diso_end()
		elif mon == null or mon.dead() or mon.pos >= mon.length - 1e-3:
			if not _play_set("Disorientated", "disoriented"):
				_diso_end()
		return true
	if state == "stun":
		if not z.gore.is_stunned():
			var e := _pick(["statusfx_electrocuted_end_01"])
			if e != "" and clip != e:
				_start(e, "react")
			else:
				_finish()
			return true
		if t >= length and clip != "statusfx_electrocuted_loop_01" and _has("statusfx_electrocuted_loop_01"):
			_start("statusfx_electrocuted_loop_01", "stun")
		elif t >= length:
			_start(clip, "stun")
		_apply_root(delta)
		return true
	_apply_root(delta)
	if mon:
		clip = mon.current_clip()
	if state == "ko" and mon and mon.pos >= ko_ragdoll_at - 1e-4:
		start_ragdoll({})
		return true
	var ended := t >= length if mon == null else (mon.pos >= mon.length - 1e-3 or mon.dead())
	if ended:
		match state:
			"getup":
				downed = false
				_finish()
			_:
				_finish()
	return true


## The PoseSnapshot weight: 1 -> 0 over RagdollBlendOutTime, shaped by the blend-out curve (time fraction -> weight
## out of the physics pose, BPC_PhysicalizedHitReact_AI RagdollBlendOutWeightToPhysicsBlendWeight).
func _update_snapshot(delta: float) -> void:
	snap_t += delta
	var a := z.anim_ctl.a
	var x := clampf(snap_t / RAGDOLL_BLEND_OUT, 0.0, 1.0)
	var keys: Array = extra.get("curves", {}).get(BLEND_OUT_CURVE, [])
	var out_w := HitReactTrees.curve_keys(keys, x) if not keys.is_empty() else x
	a.snapshot_w = clampf(1.0 - out_w, 0.0, 1.0)
	if x >= 1.0:
		a.snapshot_w = 0.0
		snap_t = -1.0


## The montage's root motion this frame: the root track of the clip its current segment plays, at that clip's
## time, as a delta from the previous frame, scaled by the montage weight (FRootMotionMovementParams blend).
func _apply_root(delta: float) -> void:
	var w := 1.0
	var at := t
	var c := clip
	if mon:
		var smp := mon.sample(mon.pos)
		c = smp[0]
		at = smp[1]
		w = mon.weight.value if not mon.dead() else 0.0
	if c != root_clip:
		root_clip = c
		var info: Dictionary = report.get(c, {})
		root = info.get("root", []) if info.get("root") != null else []
		root_rate = float(info.get("rate", 30.0))
		prev_root = _root_at(at)
	var cur := _root_at(at)
	var d := (cur - prev_root) * w
	prev_root = cur
	# Root track is in skeleton space; the visual carries the Unreal->Godot yaw.
	var world := z.skeleton.global_basis * Vector3(d.x, d.y, d.z)
	var v := world / maxf(delta, 1e-4)
	z.velocity = Vector3(v.x, z.velocity.y - 9.8 * delta if not z.is_on_floor() else -0.1, v.z)
	if absf(d.w) > 1e-5:
		z.rotate_y(d.w)
	z.move_and_slide()


func _finish() -> void:
	state = ""
	clip = ""
	action = ""
	am = ""
	root = []
	z.lock_time = 0.0
	if on_done.is_valid():
		var cb := on_done
		on_done = Callable()
		cb.call()
	if paired_active and state != "paired":
		_commit_paired_root()
		# The node took the paired root offset: cut the paired montage so the offset isn't shown twice.
		z.anim_ctl.a.stop_montages(0.0)


## Moves the paired clip's root-bone offset (position and facing) onto the node, so the body stays where it is
## once a normal clip (root at rest) takes over.
func _commit_paired_root() -> void:
	paired_active = false
	var skel := z.skeleton
	var ri := skel.find_bone("root")
	if ri < 0:
		return
	var pose := skel.get_bone_global_pose(ri)
	var rest := skel.get_bone_global_rest(ri)
	var off := skel.global_basis.orthonormalized() * (pose.origin - rest.origin)
	z.global_position += Vector3(off.x, 0.0, off.z)
	var px := pose.basis.x
	var rx := rest.basis.x
	z.rotate_y(atan2(-px.z, px.x) - atan2(-rx.z, rx.x))
