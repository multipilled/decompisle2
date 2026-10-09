class_name PlayerMoves
extends RefCounted
## Dani's non-swing combat kit, built on DI2's own clips and data:
## block / perfect block (cooldown 1.5 s) -> counter (paired clips, 0.5 s window after 0.2 s), kicks
## (Kick / LowKick / LowestKick + LeftChain, Shove, head Stomp on downed or crawling zombies), dodges
## (F/B/L/R, i-frames, perfect dodge), Drop Kick (sprint + kick, 1.5 m blast, 40 stability force), Ground
## Pound (attack in the air), weapon throw + pickup, curveballs (pipe bomb, Molotov, shuriken), Fury
## (scream, claws, overhead smash), grapple struggle (bar starts 45%, +20% per press, 5 s timeout),
## medkits and Dani's kill-streak perks (Bloodlust +15% health, +20% stamina on 2 quick kills).

const CURVEBALLS := ["pipebomb", "molotov", "shuriken"]
const CURVEBALL_COOLDOWN := 12.0   # DI2 recharge times vary by curveball; shortened for testing
const PERFECT_WINDOW := 0.25
const DODGE_TIME := 0.4

var p: Player
var block_t := -10.0
var perfect_cd := 0.0
var counter_target: Zombie
var counter_window := 0.0
var counter_phase := ""
var counter_t := 0.0
var counter_seq := {}           # into / action / end level-sequence entries for the running counter
var counter_kill := false
var counter_struck := false
var kick_clip := ""
var kick_mon: DI2Anim.Montage
var dodge_mon: DI2Anim.Montage
var kick_hit := {}
var kick_damage := 6.0
var kick_force := 30.0
var kick_stomp := false
var kick_hit_time := 0.25        # montage PlayMontageNotify (the impact frame)
var kick_chain_from := 0.0       # first BP_Chainable window start
var kick_done := false
var dodge_t := 0.0
var dodge_dir := Vector3.ZERO
var dodge_move := {}
var dodge_recovery := {}
var dodge_len := 0.4
var dodge_recovering := false
var perfect_dodge_cd := 0.0
var dropkick_cd := 0.0
var dropkick_hit := false
var pounding := false
var throw_aiming := false
var throw_clips: Array = []
var thrown: Array = []          # ThrownWeapon nodes lying around / in flight
var curveball_i := 0
var curveball_cd := 0.0
var fury_active := false
var fury_prev_weapon := ""
var fury_t := 0.0
var smash_hit := false
var grapple_z: Zombie
var paired_z: Zombie              # zombie sharing Dani's origin for a paired animation
var grapple_bar := 0.0
var grapple_t := 0.0
var grapple_phase := ""
var kill_times: Array = []
var perk_cd := 0.0


func _init(owner: Player) -> void:
	p = owner


func cls_block() -> String:
	return {"bat": "twohanded", "machete": "onehanded", "pistol": "onehandedpistol"}[p.weapon]


func update(delta: float) -> void:
	perfect_cd -= delta
	counter_window -= delta
	perfect_dodge_cd -= delta
	dropkick_cd -= delta
	curveball_cd -= delta
	perk_cd -= delta
	if fury_active:
		fury_t -= delta
		p.fury = maxf(0.0, fury_t / 15.0)
		if fury_t <= 0.0:
			end_fury()
	match p.state:
		"block":
			_update_block()
		"kick":
			_update_kick()
		"dodge":
			_update_dodge(delta)
		"dropkick":
			_update_dropkick()
		"groundpound":
			if p.is_on_floor() and p.state_t > 0.1:
				_pound_impact()
		"throw_aim":
			p.move_scale = 0.6
		"throw":
			if p.state_t > 0.12 and throw_aiming:
				throw_aiming = false
				_spawn_thrown()
			if p.state_t > 0.55:
				p.set_state("ready")
				p.equip(p._next_weapon(1), true)
		"curveball":
			if p.state_t > 0.22 and p.get_meta("curveball_pending", false):
				p.set_meta("curveball_pending", false)
				_spawn_curveball()
			if p.state_t > 0.6:
				p.set_state("ready")
		"counter":
			_update_counter(delta)
		"grapple":
			_update_grapple(delta)
		"fury_scream":
			if p.state_t > p.clip_len("fury_scream") * 0.9:
				p.set_state("ready")
		"fury_smash":
			if not smash_hit and p.state_t > 0.45:
				smash_hit = true
				_area_blast(p.global_position - p.global_transform.basis.z * 1.2, 3.2, 70.0, "blunt", 60.0, true)
				p.add_shake(1.0)
			if p.state_t > p.clip_len("fury_overhead_smash") * 0.85:
				p.set_state("ready")
	if counter_window > 0.0 and counter_target and is_instance_valid(counter_target):
		p.show_hint("COUNTER  [LMB]", 0.1)


# --- Attack button routing ------------------------------------------------------------------------------

## Returns true when the attack press was used for something else (counter, grapple mash, ground pound).
func on_attack_pressed() -> bool:
	if p.state == "grapple":
		_mash()
		return true
	if counter_window > 0.0 and counter_target and is_instance_valid(counter_target) and not counter_target.dead:
		_start_counter()
		return true
	if not p.is_on_floor() and p.air_t > 0.15 and p.state in ["ready", "jump"] and p.is_melee():
		_start_ground_pound()
		return true
	return false


func on_kick_pressed() -> bool:
	if p.state == "grapple":
		_mash()
		return true
	if Input.is_action_pressed("sprint") and p.state == "ready" and p.is_on_floor() and Vector2(p.velocity.x, p.velocity.z).length() > 3.5:
		_start_dropkick()
		return true
	return false


# --- Block / perfect block / counter ----------------------------------------------------------------------

## DI2 block: the class's BlockIn (side from {Self}.HandPosition) -> BlockPose loop; BlockOut on release.
func block_pressed() -> void:
	if p.state not in ["ready", "switch"] and not (p.state == "attack" and p.melee.phase == "recovery"):
		return
	var facts := p.combat_facts(false)
	p.melee.reset()
	p.set_state("block")
	block_t = Time.get_ticks_msec() * 0.001
	var bin := p.play_role(p.slot_role("BlockIn", "main", facts))
	if bin == null:
		p.play_role(p.slot_role("BlockPose"))
	else:
		p.play_role_after(bin, p.slot_role("BlockPose"))


## BlockIn's montage runs into BlockPose (a looping section); BlockSuccess / PerfectBlock return to it, BlockOut
## ends the block. Each montage blends with its own DI2 BlendIn / BlendOut.
func _update_block() -> void:
	p.move_scale = 0.5
	if not p.rmb_held:
		p.play_role(p.slot_role("BlockOut"))
		p.set_state("switch")
		return
	var pose := p.slot_role("BlockPose")
	var m := p.montage()
	if not pose.is_empty() and (m == null or (m.name != str(pose.get("m", "")) and p.montage_done(m))):
		p.play_role(pose)


## Called when a zombie attack lands on Dani. Returns true if the hit was fully handled here.
func absorb_hit(damage: float, z: Zombie) -> bool:
	if p.state == "dodge":
		if dodge_t < 0.28 and perfect_dodge_cd <= 0.0:
			_perfect_dodge(z)
		return true
	if p.state in ["grapple", "counter"]:
		return true
	var to := z.global_position - p.global_position
	to.y = 0
	var facing := to.normalized().dot(-p.global_transform.basis.z) > 0.25
	if p.state == "block" and facing:
		var since := Time.get_ticks_msec() * 0.001 - block_t
		if since <= PERFECT_WINDOW and perfect_cd <= 0.0:
			perfect_cd = float(p.combat["dani"]["perfect_block"]["cooldown"])
			p.play_role(p.slot_role("PerfectBlock"))
			p.stamina = minf(p.max_stamina, p.stamina + 1.5)
			z.stagger(to.normalized(), 30.0)
			p.popup(z.global_position + Vector3.UP * 1.8, "BLOCKED", "blocked")
			p.say("PERFECT BLOCK", 1.0)
			p.hit_pause(0.08, 0.05)
			p.add_shake(0.4)
			counter_target = z
			counter_window = 0.2 + float(p.combat["dani"]["counter_minigame"]["window"]) + 0.3
			return true
		# Regular block: no damage, but it costs stamina; an empty bar breaks the guard.
		p.use_stamina(damage * 1.2)
		p.popup(z.global_position + Vector3.UP * 1.8, "BLOCKED", "blocked")
		if p.stamina > 0.0:
			p.play_role(p.slot_role("BlockSuccess"))
			p.add_shake(0.25)
			return true
		p.play_role(p.slot_role("BlockFail"))
		p.say("GUARD BROKEN", 1.0)
		p.set_state("knockback")
		p._hurt(damage * 0.5, z.global_position)
		return true
	return false


## DI2 counter after a perfect block: CounterInto (level sequence picked by the zombie's approach direction,
## {action}.ApproachDirection), then CounterMinigameStagePassed (the strike) and CounterSuccessEnemy (push) or
## CounterFatalityEnemy (kill) when the strike will finish it. Each sequence carries Dani's and the zombie's clip.
func _start_counter() -> void:
	var z := counter_target
	counter_window = 0.0
	counter_target = null
	var c := p.cls()
	var to := z.global_position - p.global_position
	to.y = 0.0
	var fwd := -p.global_transform.basis.z
	var approach := rad_to_deg(fwd.signed_angle_to(to.normalized(), Vector3.UP)) if to.length() > 0.01 else 0.0
	var facts := p.combat_facts(false)
	facts["action.ApproachDirection"] = approach
	var into := c.pick("CounterInto", facts) if c else {}
	var main: Dictionary = into.get("main", {}) if not into.is_empty() else {}
	if not p.is_melee() or main.get("clips", []).is_empty():
		# No paired sequence for this weapon: a guaranteed counter-strength swing instead.
		p.melee.counter_bonus = true
		p.melee.start_light()
		return
	_sync_paired(z)
	var dmg := p.level_damage(p.w()["damage"][1]) * float(p.w().get("counter_damage_multiplier", 1.0))
	counter_kill = z.gore.get_health() <= dmg
	counter_struck = false
	counter_seq = {"into": main, "action": c.pick("CounterMinigameStagePassed", facts).get("main", {}),
		"end": (c.pick("CounterFatalityEnemy" if counter_kill else "CounterSuccessEnemy", facts))}
	p.set_state("counter")
	counter_phase = "into"
	counter_t = 0.0
	p.set_meta("counter_z", z)
	_play_pair(main)


## Plays one paired level sequence: Dani's 1P clip and the zombie's side.
func _play_pair(seq: Dictionary) -> void:
	var clips: Array = seq.get("clips", [])
	if not clips.is_empty():
		p.play(clips[0], 0.05)
	var z: Zombie = p.get_meta("counter_z", null) if p.has_meta("counter_z") else null
	var zc: Array = seq.get("zombie", [])
	if z and is_instance_valid(z) and not z.dead and not zc.is_empty():
		z.reactions.play_paired(zc[0])


func _update_counter(delta: float) -> void:
	var z: Zombie = p.get_meta("counter_z", null)
	counter_t += delta
	if z == null or not is_instance_valid(z):
		_end_paired()
		p.set_state("ready")
		return
	if not z.dead:
		_frame_paired(z, delta)
	var cm := p.montage()
	var done := p.montage_done(cm)
	match counter_phase:
		"into":
			if done:
				counter_phase = "action"
				counter_t = 0.0
				_play_pair(counter_seq["action"])
		"action":
			if not counter_struck and cm and counter_t >= cm.length * 0.35:
				counter_struck = true
				var dmg := p.level_damage(p.w()["damage"][1]) * float(p.w().get("counter_damage_multiplier", 1.0))
				if counter_kill:
					dmg = z.gore.get_health() + 50.0
				var head := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(z.skeleton.find_bone("head")).origin
				var dir := -p.camera.global_basis.z
				var res := z.take_hit("head", head, p.camera.global_basis.x, dir, dmg, p.w()["damage_type"], true, 2.0, float(p.w().get("force", 25.0)), dir, p,
					{"weapon": p.weapon, "isPaired": true, "CounterKill": counter_kill, "CounterAction": not counter_kill, "mod": p.melee.mod()})
				p.popup(head, str(roundi(dmg)), "crit")
				p.hit_pause(0.12, 0.04)
				p.add_shake(1.0)
				p.add_blood(0.15)
				p.on_damage_dealt(dmg, not res.get("alive", true), z)
			if done:
				counter_phase = "end"
				counter_t = 0.0
				var end: Dictionary = counter_seq["end"]
				for role in end:
					if end[role] is Dictionary and not end[role].get("clips", []).is_empty():
						_play_pair(end[role])
						break
		"end":
			if done:
				_end_paired()
				p.set_state("ready")


## DI2 paired animations share one origin: Dani turns to the zombie, the zombie is put on her root with her
## facing, and each clip's own root bone places the bodies (the Walker's sits ~0.8 m in front, turned to face her).
func _sync_paired(z: Zombie) -> void:
	var to := z.global_position - p.global_position
	to.y = 0.0
	if to.length() > 0.05:
		p.rotation.y = atan2(-to.x, -to.z)
	z.global_position = Vector3(p.global_position.x, z.global_position.y, p.global_position.z)
	z.rotation.y = p.rotation.y
	z.velocity = Vector3.ZERO
	p.velocity = Vector3.ZERO
	p.add_collision_exception_with(z)
	z.add_collision_exception_with(p)
	paired_z = z


## Paired shots keep the zombie's face just below the centre of the screen (camera_root's own motion rides on
## top at a reduced weight, see Player.paired_cam).
func _frame_paired(z: Zombie, delta: float) -> void:
	var head := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(z.skeleton.find_bone("head")).origin
	var to := head - p.camera.global_position
	var want := asin(clampf(to.normalized().y, -1.0, 1.0)) + deg_to_rad(6.0)
	p.pitch = lerpf(p.pitch, want, minf(1.0, delta * 6.0))


func _end_paired() -> void:
	if paired_z and is_instance_valid(paired_z):
		p.remove_collision_exception_with(paired_z)
		paired_z.remove_collision_exception_with(p)
	paired_z = null


# --- Kicks / stomp / shove ---------------------------------------------------------------------------------

## DI2 Knockbacks slot: HeadStomp / Shove / Kick / LowKick / LowestKick picked by DI2's aliases (camera pitch
## bands, crouch/slide, the HeadStomp context on a knocked-down zombie, the left-hand chain variants). The hit
## lands on the montage's PlayMontageNotify; the next kick can chain from its first BP_Chainable window.
func kick() -> void:
	var chaining := p.state == "kick" and kick_chain_from > 0.0 and kick_mon != null and kick_mon.pos >= kick_chain_from
	if p.state not in ["ready", "block", "switch"] and not chaining and not (p.state == "attack" and p.melee.phase == "recovery"):
		return
	var c := p.cls()
	var facts := p.combat_facts(false)
	var item := c.pick("Knockbacks", facts) if c else {}
	var m: Dictionary = item.get("main", {}) if not item.is_empty() else {}
	var clips: Array = m.get("clips", [])
	if clips.is_empty():
		return
	var attrs: Dictionary = p.combat["dani"]["attributes"]
	kick_stomp = DI2Expr.eval("#KnockbackHeadStomp", facts)
	var shove := DI2Expr.eval("#KnockbackShove", facts)
	kick_clip = clips[0]
	kick_hit_time = 0.25
	for ev: Array in m.get("events", []):
		if ev[0] == "PlayMontageNotify":
			kick_hit_time = float(ev[1])
	var chain: Array = m.get("chain", [])
	kick_chain_from = float(chain[0][0]) if not chain.is_empty() else 0.0
	kick_force = float(attrs.get("KickForce", 30.0))
	if kick_stomp:
		kick_damage = float(attrs.get("ClassExclusiveKickDamage", 60.0))
	elif shove:
		kick_damage = 2.0
	else:
		kick_damage = 6.0
		p.use_stamina(float(p.data["kick"]["stamina"]))
	p.melee.reset()
	kick_hit.clear()
	kick_done = false
	p.set_state("kick")
	kick_mon = p.play_role(m)
	# DI2 alternates the kick leg with the weapon side for the next one.
	p.melee.hand_left = not p.melee.hand_left


## Kick area: BP_Base_Player's KickComponentEditorTool capsule (radius 100 cm, half height 100 cm, 72 cm ahead).
func _update_kick() -> void:
	p.move_scale = 0.3
	# Montage time: the hit lands on the montage's PlayMontageNotify.
	var at := kick_mon.pos if kick_mon else p.state_t
	if not kick_done and at >= kick_hit_time:
		kick_done = true
		var fwd := -p.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var centre := p.global_position + fwd * 0.72 + Vector3.UP * 1.0
		for z: Zombie in p.get_tree().get_nodes_in_group("zombies"):
			if z.dead or kick_hit.has(z):
				continue
			var rel := z.global_position + Vector3.UP * 1.0 - centre
			if Vector2(rel.x, rel.z).length() > 1.0 + 0.3 or absf(rel.y) > 1.0 + 0.3:
				continue
			kick_hit[z] = true
			var bone := "head" if kick_stomp else ("spine_03" if not kick_clip.contains("kicklow") else "thigh_l")
			var bi := z.skeleton.find_bone(bone)
			var point := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(bi).origin if bi >= 0 else z.global_position + Vector3.UP
			var into := (point - p.camera.global_position).normalized()
			var dmg := p.level_damage(kick_damage)
			# Kicks: DI2's CT_HitEffect_Kick (the asset that assigns it to kicks wasn't found; recon/UNVERIFIED.md).
			var res := z.take_hit(bone, point, fwd if not kick_stomp else Vector3.DOWN, into, dmg, "blunt", kick_stomp, 1.0, kick_force, fwd, p, {"weapon": "", "tree": "CT_HitEffect_Kick"})
			p.popup(res.get("point", point), str(roundi(dmg)), "default")
			p.hitmarker = 0.18
			p.on_damage_dealt(dmg, not res.get("alive", true), z)
			p.hit_pause(0.06, 0.05)
			p.add_shake(0.6 if kick_stomp else 0.4)
	if p.montage_done(kick_mon) and kick_done:
		p.set_state("ready")


# --- Dodge ----------------------------------------------------------------------------------------------

## DI2 Dodges slot: Forward / Right / Left / Back by {dodge}.StickHeadingDeg (0 = forward, clockwise), then
## the item's recovery montage. Push strength follows Curve_Dodge_StrengthOverTime_Float.
func dodge() -> void:
	if p.state not in ["ready", "block", "switch"] and not (p.state == "attack" and p.melee.phase in ["recovery", "dec"]):
		return
	var cost: float = p.data["player"]["dodge_stamina"]
	if p.stamina < cost:
		p.say("Too tired")
		return
	p.use_stamina(cost)
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input.length() < 0.2:
		input = Vector2(0, 1)
	var heading := fposmod(rad_to_deg(atan2(input.x, -input.y)), 360.0)
	var facts := {"dodge.StickHeadingDeg": heading}
	var c := p.cls()
	var item := c.pick("Dodges", facts) if c else {}
	dodge_move = item.get("movement", {}) if not item.is_empty() else {}
	dodge_recovery = item.get("recovery", {}) if not item.is_empty() else {}
	dodge_len = float(dodge_move["len"]) if dodge_move.get("len") != null else DODGE_TIME
	dodge_dir = (p.global_transform.basis * Vector3(input.x, 0, input.y)).normalized()
	dodge_t = 0.0
	dodge_recovering = false
	p.melee.reset()
	p.set_state("dodge")
	dodge_mon = p.play_role(dodge_move)
	if dodge_mon:
		p.play_role_after(dodge_mon, dodge_recovery, _on_dodge_recovery)


func _on_dodge_recovery(m: DI2Anim.Montage) -> void:
	if p.state == "dodge":
		dodge_recovering = true
		dodge_mon = m


func _update_dodge(delta: float) -> void:
	dodge_t += delta
	var strength := p.melee._curve(p.combat["dodge"].get("strength_curve"), dodge_t)
	var dist: float = p.data["player"]["dodge_distance"]
	p.move_override = dodge_dir * dist / DODGE_TIME * strength
	p.override_t = 0.05
	# DodgeMovement montage, then the item's DodgeRecovery montage once the movement one blends out.
	if not dodge_recovering and (dodge_t >= dodge_len or p.montage_done(dodge_mon)):
		dodge_recovering = true
		dodge_mon = p.play_role(dodge_recovery)
	if dodge_recovering and p.montage_done(dodge_mon):
		p.set_state("ready")


func _perfect_dodge(z: Zombie) -> void:
	perfect_dodge_cd = 1.0
	p.say("PERFECT DODGE", 1.0)
	p.popup(z.global_position + Vector3.UP * 1.8, "DODGED", "blocked")
	z.stagger(-(p.global_position - z.global_position).normalized(), 12.0)
	# DodgeSuccess: a moment of slow motion to punish.
	Engine.time_scale = Main.time_scale * 0.35
	await p.get_tree().create_timer(0.7, true, false, true).timeout
	Engine.time_scale = Main.time_scale


# --- Drop kick / ground pound -------------------------------------------------------------------------------

func _start_dropkick() -> void:
	if dropkick_cd > 0.0:
		p.say("Drop Kick recharging")
		return
	dropkick_cd = 6.0
	dropkick_hit = false
	p.melee.reset()
	p.set_state("dropkick")
	p.play("skill_dropkick", 0.04)
	p.velocity.y = 3.0


func _update_dropkick() -> void:
	var fwd := -p.global_transform.basis.z
	if p.state_t < 0.5:
		p.move_override = fwd * 7.5
		p.override_t = 0.05
	if not dropkick_hit and p.state_t > 0.3:
		dropkick_hit = true
		var dk: Dictionary = p.combat["dani"]["dropkick"]
		var dmg := float(p.combat["dani"]["attributes"].get("ClassExclusiveKickDamage", 60.0))
		_area_blast(p.global_position + fwd * 1.2 + Vector3.UP * 0.9, float(dk["radius"]) + 0.3, dmg, "blunt", float(dk["stability_force"]), true)
		p.add_shake(0.8)
	if p.state_t > maxf(p.clip_len("skill_dropkick"), 0.9) * 0.9:
		p.set_state("ready")


func _start_ground_pound() -> void:
	pounding = true
	p.melee.reset()
	p.set_state("groundpound")
	p.play(p.first_clip(["skill_groundpound_into", "skill_groundpound_falling_loop"]), 0.04)
	p.velocity.y = -16.0


func _pound_impact() -> void:
	pounding = false
	p.play("skill_groundpound", 0.03)
	_area_blast(p.global_position, 3.5, 30.0, "blunt", 40.0, true)
	Fx.shockwave(p.get_parent(), p.global_position)
	p.add_shake(1.0)
	p.set_state("switch")


func on_landed(_air_time: float) -> void:
	if p.state == "groundpound":
		_pound_impact()


## Radial hit: every zombie within `radius` takes a hit on its nearest bone (+ stability blast).
func _area_blast(center: Vector3, radius: float, damage: float, kind: String, force: float, launch: bool) -> void:
	for z: Zombie in p.get_tree().get_nodes_in_group("zombies"):
		if z.dead:
			continue
		var d := z.global_position.distance_to(Vector3(center.x, z.global_position.y, center.z))
		if d > radius:
			continue
		var fall := 1.0 - 0.5 * d / radius
		var dir := (z.global_position - center)
		dir.y = 0
		dir = dir.normalized() if dir.length() > 0.01 else -p.global_transform.basis.z
		var bone := "spine_03"
		var bi := z.skeleton.find_bone(bone)
		var point := z.skeleton.global_transform * z.skeleton.get_bone_global_pose(bi).origin
		var dmg := p.level_damage(damage) * fall
		var res := z.take_hit(bone, point, dir, dir, dmg, kind, launch, 1.0, force * fall, dir + Vector3.UP * 0.3, p)
		p.popup(point, str(roundi(dmg)), "heavy")
		p.on_damage_dealt(dmg, not res.get("alive", true), z)
		p.hitmarker = 0.2


# --- Weapon throw ---------------------------------------------------------------------------------------

func throw_pressed() -> void:
	if not p.is_melee() or fury_active or p.state not in ["ready", "switch"]:
		return
	throw_aiming = true
	p.set_state("throw_aim")
	# DI2 AimThrow slot (left-hand variant by {Self}.HandPosition): Throw_Into -> Throw_Loop -> Throw.
	var item := p.cls().pick("AimThrow", p.combat_facts(false)) if p.cls() else {}
	throw_clips = item.get("main", {}).get("clips", []) if not item.is_empty() else []
	if not throw_clips.is_empty():
		p.play(throw_clips[0], 0.05)


func throw_released() -> void:
	if p.state != "throw_aim":
		return
	p.set_state("throw")
	if throw_clips.size() > 2:
		p.play(throw_clips[2], 0.03)


func _spawn_thrown() -> void:
	var tw := ThrownWeapon.new()
	tw.player = p
	tw.weapon = p.weapon
	p.get_parent().add_child(tw)
	var xf := p.camera.global_transform
	tw.global_position = xf.origin - xf.basis.z * 0.6 + xf.basis.x * 0.15
	tw.launch(-xf.basis.z * 19.0 + Vector3.UP * 1.2)
	thrown.append(tw)
	p.weapon_away[p.weapon] = true
	p.weapon_nodes[p.weapon].visible = false


func pickup() -> void:
	for tw: ThrownWeapon in thrown:
		if is_instance_valid(tw) and tw.landed and tw.global_position.distance_to(p.global_position) < 2.6:
			p.weapon_away.erase(tw.weapon)
			thrown.erase(tw)
			var wname := tw.weapon
			tw.queue_free()
			p.say("Picked up " + p.data[wname]["name"])
			p.equip(wname, true)
			return


# --- Curveballs -------------------------------------------------------------------------------------------

func cycle_curveball() -> void:
	curveball_i = (curveball_i + 1) % CURVEBALLS.size()
	p.say("Curveball: " + CURVEBALLS[curveball_i].capitalize())


func curveball() -> void:
	if curveball_cd > 0.0 or p.state not in ["ready", "switch"]:
		if curveball_cd > 0.0:
			p.say("Curveball recharging (%d s)" % ceili(curveball_cd), 1.0)
		return
	curveball_cd = CURVEBALL_COOLDOWN
	p.set_meta("curveball_pending", true)
	p.set_state("curveball")
	p.play(p.first_clip(["carry1h_throw_grenade_throw"]), 0.05)


func _spawn_curveball() -> void:
	var cb := Curveball.new()
	cb.kind = CURVEBALLS[curveball_i]
	cb.player = p
	p.get_parent().add_child(cb)
	var xf := p.camera.global_transform
	cb.global_position = xf.origin - xf.basis.z * 0.5 + xf.basis.x * 0.2
	var speed := 22.0 if cb.kind == "shuriken" else 13.0
	cb.launch(-xf.basis.z * speed + Vector3.UP * (0.5 if cb.kind == "shuriken" else 3.5))


# --- Fury -----------------------------------------------------------------------------------------------

func start_fury() -> void:
	if fury_active:
		return
	if p.fury < 1.0:
		p.say("Fury not ready (%d%%)" % roundi(p.fury * 100.0), 1.0)
		return
	fury_active = true
	fury_t = 15.0
	p.melee.reset()
	# DI2 Fury: Dani fights with BP_Weapon_FuryFists (its own damage, force, timings and the FuryFists class).
	fury_prev_weapon = p.weapon
	p.equip("fury_fists", true)
	p.set_state("fury_scream")
	p.play("fury_scream", 0.05)
	Fx.shockwave(p.get_parent(), p.global_position)
	p.add_shake(0.9)
	for z: Zombie in p.get_tree().get_nodes_in_group("zombies"):
		if not z.dead and z.global_position.distance_to(p.global_position) < 4.0:
			z.stagger((z.global_position - p.global_position).normalized(), 25.0)
	p.say("FURY", 1.5)


func fury_smash() -> void:
	p.melee.reset()
	smash_hit = false
	p.set_state("fury_smash")
	p.play("fury_overhead_smash", 0.05)


func end_fury() -> void:
	fury_active = false
	p.fury = 0.0
	p.set_state("ready")
	if fury_prev_weapon != "":
		p.equip(fury_prev_weapon, true)
	p.set_state("ready")
	p.say("Fury ended", 1.0)


# --- Grapple ---------------------------------------------------------------------------------------------

func start_grapple(z: Zombie) -> bool:
	if p.state in ["grapple", "counter", "dodge", "dead"] or fury_active:
		return false
	if p.state == "block" and Time.get_ticks_msec() * 0.001 - block_t <= PERFECT_WINDOW:
		return false
	var mg: Dictionary = p.combat["dani"]["grapple_minigame"]
	grapple_z = z
	grapple_bar = float(mg["start"])
	grapple_t = 0.0
	grapple_phase = "into"
	p.melee.reset()
	p.set_state("grapple")
	_sync_paired(z)
	p.play("paired_grapple_into", 0.05)
	z.reactions.play_paired("paired_grapple_into")
	return true


func _mash() -> void:
	if grapple_phase in ["into", "loop"]:
		grapple_bar = minf(1.0, grapple_bar + float(p.combat["dani"]["grapple_minigame"]["per_press"]))
		p.add_shake(0.15)
		if grapple_phase == "loop" and grapple_bar >= 1.0:
			_grapple_end(true)


func _update_grapple(delta: float) -> void:
	var z := grapple_z
	grapple_t += delta
	if z == null or not is_instance_valid(z) or z.dead:
		_end_paired()
		p.set_state("ready")
		return
	_frame_paired(z, delta)
	var mg: Dictionary = p.combat["dani"]["grapple_minigame"]
	match grapple_phase:
		"into":
			if grapple_t >= p.clip_len("paired_grapple_into") * 0.95:
				grapple_phase = "loop"
				grapple_t = 0.0
				if grapple_bar >= 1.0:
					_grapple_end(true)
					return
				p.play("paired_grapple_loop_close", 0.05)
				z.reactions.play_paired("paired_grapple_loop_close")
		"loop":
			grapple_bar = maxf(0.0, grapple_bar - delta * 0.12)
			p.show_hint("STRUGGLE  [F / LMB]", 0.1)
			if grapple_t >= float(mg["timeout"]) or grapple_bar <= 0.0:
				_grapple_end(false)
			elif z.reactions.state == "" or z.reactions.t >= z.reactions.length * 0.95:
				z.reactions.play_paired("paired_grapple_loop_close")
		"exit":
			if grapple_t > 0.05 and p.montage_done(p.montage()):
				_end_paired()
				p.set_state("ready")


func _grapple_end(won: bool) -> void:
	var z := grapple_z
	grapple_phase = "exit"
	grapple_t = 0.0
	if won:
		p.play("paired_grapple_exit_push", 0.05)
		z.reactions.play_paired("paired_grapple_exit_push", func(): z.stagger(-p.global_transform.basis.z, 60.0))
		p.say("Broke free!", 1.0)
	else:
		p.play("paired_grapple_bite", 0.05)
		z.reactions.play_paired("paired_grapple_bite")
		p._hurt(38.0 * z.level_damage_scale(), z.global_position)


# --- Medkits / perks ----------------------------------------------------------------------------------

func medkit() -> void:
	if p.medkits <= 0 or p.health >= p.max_health:
		return
	p.medkits -= 1
	p.health = minf(p.max_health, p.health + p.max_health * 0.5)
	p.say("Medkit used (%d left)" % p.medkits, 1.5)


func on_kill() -> void:
	var now := Time.get_ticks_msec() * 0.001
	kill_times.append(now)
	kill_times = kill_times.filter(func(t): return now - t < 3.0)
	var perks: Dictionary = p.combat["dani"]["perks"]
	if kill_times.size() >= int(perks["bloodlust_health"]["kills"]) and perk_cd <= 0.0:
		perk_cd = float(perks["bloodlust_health"]["cooldown"])
		p.health = minf(p.max_health, p.health + p.max_health * float(perks["bloodlust_health"]["health_fraction"]))
		p.stamina = minf(p.max_stamina, p.stamina + p.max_stamina * float(perks["kill_streak_stamina"]["stamina_fraction"]))
		p.popup(p.global_position + Vector3.UP * 1.0 - p.global_transform.basis.z * 1.0, "BLOODLUST", "perk")
		kill_times.clear()


# --- Thrown weapon and curveball projectiles ------------------------------------------------------------------

class ThrownWeapon extends Node3D:
	var player: Player
	var weapon := ""
	var vel := Vector3.ZERO
	var spin := Vector3.ZERO
	var landed := false
	var flying := true
	var hit_zombies := {}

	func launch(v: Vector3) -> void:
		vel = v
		spin = Vector3(randf_range(14, 18), 0, 0)
		var inst: Node3D = load(player.data[weapon]["mesh"]).instantiate()
		add_child(inst)
		Util.apply_prop_materials(inst, player.data[weapon]["mesh"].get_basename() + ".materials.json")

	func _physics_process(delta: float) -> void:
		if not flying:
			return
		vel.y -= 9.8 * delta
		var from := global_position
		var to := from + vel * delta
		Zombie.sync_hitboxes()   # hitboxes are posed on demand (zombie.gd)
		var q := PhysicsRayQueryParameters3D.create(from, to, Util.WORLD | Util.HITBOX)
		q.collide_with_areas = true
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit and hit["collider"] is Area3D:
			var area: Area3D = hit["collider"]
			var z: Zombie = area.get_meta("zombie")
			if not hit_zombies.has(z) and not z.dead:
				hit_zombies[z] = true
				var spec: Dictionary = player.data[weapon]
				var dmg: float = player.level_damage(spec["damage"][1]) * 1.3
				var res := z.take_hit(area.get_meta("bone"), hit["position"], vel.normalized(), vel.normalized(), dmg, spec["damage_type"], true, float(spec.get("limb_damage_multiplier", 1.0)), float(spec.get("force", 15.0)) * 1.5, vel.normalized(), player,
					{"weapon": weapon, "ThrownAttack": true})
				player.popup(res.get("point", hit["position"]), str(roundi(dmg)), "heavy")
				player.hitmarker = 0.2
				player.on_damage_dealt(dmg, not res.get("alive", true), z)
				vel *= 0.25
		elif hit:
			global_position = hit["position"] + hit["normal"] * 0.05
			_land()
			return
		global_position = to
		rotate_object_local(Vector3.RIGHT, spin.x * delta)
		if global_position.y < 0.05:
			global_position.y = 0.05
			_land()

	func _land() -> void:
		flying = false
		landed = true
		rotation = Vector3(PI / 2, randf() * TAU, 0)


class Curveball extends Node3D:
	var player: Player
	var kind := "pipebomb"
	var vel := Vector3.ZERO
	var fuse := 2.0
	var flying := true

	func launch(v: Vector3) -> void:
		vel = v
		var path := "res://assets/di2/throwables/%s.glb" % kind
		var inst: Node3D = load(path).instantiate()
		add_child(inst)
		Util.apply_prop_materials(inst, path.get_basename() + ".materials.json")

	func _physics_process(delta: float) -> void:
		if not flying:
			fuse -= delta
			if fuse <= 0.0 and kind == "pipebomb":
				_explode()
			return
		vel.y -= 9.8 * delta * (0.2 if kind == "shuriken" else 1.0)
		var from := global_position
		var to := from + vel * delta
		Zombie.sync_hitboxes()   # hitboxes are posed on demand (zombie.gd)
		var q := PhysicsRayQueryParameters3D.create(from, to, Util.WORLD | Util.HITBOX)
		q.collide_with_areas = true
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		rotate_y(delta * 12.0)
		if hit:
			global_position = hit["position"]
			if kind == "molotov":
				_ignite(hit["position"], hit["normal"])
			elif kind == "shuriken" and hit["collider"] is Area3D:
				var area: Area3D = hit["collider"]
				var z: Zombie = area.get_meta("zombie")
				var dmg := player.level_damage(35.0)
				var res := z.take_hit(area.get_meta("bone"), hit["position"], vel.normalized(), vel.normalized(), dmg, "sharp", true, 1.5, 10.0, vel.normalized(), player)
				z.take_hit(area.get_meta("bone"), res.get("point", hit["position"]), vel.normalized(), vel.normalized(), 15.0, "bleed", false, 0.0, 0.0, Vector3.ZERO, player)
				player.popup(res.get("point", hit["position"]), str(roundi(dmg)), "heavy")
				player.on_damage_dealt(dmg, not res.get("alive", true), z)
				queue_free()
			elif kind == "pipebomb":
				vel = Vector3.ZERO
				flying = false
			else:
				queue_free()
			return
		global_position = to
		if global_position.y < 0.05:
			global_position.y = 0.05
			if kind == "molotov":
				_ignite(global_position, Vector3.UP)
			else:
				flying = false

	func _explode() -> void:
		player.add_shake(clampf(1.4 - player.global_position.distance_to(global_position) * 0.08, 0.2, 1.2))
		# DI2's DA_ExplosionArchetype_PipeBomb through its explosion action (DI2Explosion); the player's weapon level
		# stands in for the bomb's ExplosionDamage attribute.
		DI2Explosion.spawn(get_parent(), "PipeBomb", global_position, player, player.level_damage(1.0))
		queue_free()

	func _ignite(at: Vector3, normal: Vector3) -> void:
		flying = false
		# DI2's BP_MolotovCocktail_Projectile on world collision (recon/RE_FLUIDS.md §9.1): its
		# InvokeParentProjectileLocationResponse runs DA_ExplosionArchetype_Molotov (fire damage, Burning build-up), and
		# two InvokeCollisionLocationResponses spawn the burning petrol (BP_Fluid_Projectile_Petrol bursts -> burning
		# puddles whose BP_AOE_DamageOverTime_Fluid_Burning does the lingering fire damage), DI2Fluids.molotov_burst.
		DI2Explosion.spawn(get_parent(), "Molotov", at, player, player.level_damage(1.0))
		DI2Fluids.molotov_burst(get_parent(), at, normal, vel, player)
		queue_free()
