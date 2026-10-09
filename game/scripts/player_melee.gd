class_name PlayerMelee
extends RefCounted
## DI2 melee: standard attacks, chains, impacts, rebounds and charged heavy attacks for Dani.
##
## Attack choice follows DA_AnimSet_StandardAttack_<class>: aiming at a head up close (ScalpContext) or at a
## downed/crawling zombie (DownContext) gives an overhead downward strike; aiming high (UpContext) an upward
## one; otherwise horizontal swings alternate sides (DI2's LeftHand fact) with a random 01/02/03 variant.
## Each swing plays DI2's own montages (data/montages.json, scripts/di2_anim.gd): the Antic montage, then the
## Attack montage (sections Attack -> Decision -> DecisionLoop; hit detection inside its BP_DetectHits window),
## then the Recovery montage. Their ScalePlayRate windows stretch the Antic to the weapon's anticipation time,
## play the Attack section at its attack speed and the Decision section over HeavyAttackHoldTransitionTime; each
## montage blends with DI2's own BlendIn / BlendOut (recon/ANIMATION.md).
##
## Hit detection traces the weapon itself: points along the weapon mesh are projected to the screen every
## frame of the hit window and rays go through them out to DI2's trace distance (bat 2.0 m, machete 1.84 m),
## so a strike lands exactly where the weapon is seen passing over the zombie.

const MODS := ["", "fire", "acid", "electric", "bleed"]
## The mod's level (DI2 BP_WeaponMod_<Name>_Level_1..3): which DA_WeaponModConfig entry applies.
var mod_level := 1

var p: Player
var phase := ""                 # antic, attack, dec, recovery, charge, heavy, lunge
var t := 0.0
var key := ""
var atk: Dictionary
var hand_left := true           # DI2 LeftHand: weapon currently held on the left (next swing starts there)
var queued := false
var hits := {}                  # zombie -> true for this swing
var impacted := false
var impact_side := ""
var prev_screen: Array = []
var hand_prev := {}               # hand weapons: last world position of each hand
var raw_prev: Array = []          # unanchored blade points of the previous frame
var sweep_motion := Vector2.ZERO  # accumulated on-screen travel of the blade tip this swing
var mon: DI2Anim.Montage           # montage of the current phase
var heavy := false
var charge := 0.0
var heavy_role: Dictionary = {}
var heavy_detect := Vector2.ZERO
var lunging := false
var chain_stacks := 0
var chain_t := 0.0
var mod_i := 0
var exhausted := false
var counter_bonus := false


func _init(owner: Player) -> void:
	p = owner


func reset() -> void:
	phase = ""
	queued = false
	heavy = false
	charge = 0.0


func cycle_mod() -> void:
	mod_i = (mod_i + 1) % MODS.size()
	p.say("Weapon mod: " + (MODS[mod_i].to_upper() if MODS[mod_i] != "" else "NONE"))


func mod() -> String:
	return MODS[mod_i]


func busy() -> bool:
	return phase != ""


# --- Input ------------------------------------------------------------------------------------------

func on_attack_pressed() -> void:
	if p.state in ["ready", "switch"] or (p.state == "attack" and phase in ["recovery", "dec"]):
		if phase in ["recovery", "dec"]:
			queued = true
		# Heavy decided by hold time in update(); a quick tap starts a light attack on release.
	elif p.state == "attack" and phase in ["antic", "attack"]:
		queued = true   # DI2 BP_Chainable: buffer the next swing


func on_attack_released() -> void:
	if p.state == "charge":
		_release_heavy()
	elif p.state in ["ready", "switch"] and p.lmb_t < 0.22:
		start_light()
	elif p.state == "attack" and phase == "recovery" and queued:
		start_light()


# --- Standard attacks -------------------------------------------------------------------------------

## The item DI2's StandardAttack anim set picks for the current facts (aliases: ScalpContext, DownContext,
## UpContext, StartOnLeft/Right, LeftHand, LaunchingAttack...) -> the swing description the phases use.
func _attack_from_item(item: Dictionary) -> Dictionary:
	var an: Dictionary = item.get("antic", {}) if item.get("antic") is Dictionary else {}
	var at: Dictionary = item.get("attack", {}) if item.get("attack") is Dictionary else {}
	var rc: Dictionary = item.get("recovery", {}) if item.get("recovery") is Dictionary else {}
	var attack_clips: Array = at.get("clips", [])
	var rec_clips: Array = rc.get("clips", [])
	var antic_clips: Array = an.get("clips", [])
	var main: String = attack_clips[0] if not attack_clips.is_empty() else ""
	var end_side := "right" if (main.contains("left_to_right") or main.ends_with("_r_attack")) else "left"
	return {"key": str(at.get("m", "")), "antic_role": an, "attack_role": at, "recovery_role": rc,
		"antic": antic_clips[0] if not antic_clips.is_empty() else "", "attack": main,
		"recovery": rec_clips.back() if not rec_clips.is_empty() else "",
		"detect": at["detect"] if at.get("detect") != null else [0.1, 0.34],
		"chain_attack": at.get("chain", []), "chain_recovery": rc.get("chain", []),
		"camera": at.get("camera"), "end": end_side, "from": "left" if end_side == "right" else "right"}


func start_light() -> void:
	var spec := p.w()
	var c := p.cls()
	if c == null:
		return
	var item := c.pick("StandardAttack", p.combat_facts(false))
	if item.is_empty():
		return
	var cost: float = spec["stamina_per_attack"]
	exhausted = p.stamina < cost * 0.25
	p.use_stamina(cost)
	atk = _attack_from_item(item)
	key = atk["key"]
	# DI2 HandPosition: where the weapon ends up after this swing.
	hand_left = atk["end"] == "left"
	heavy = false
	_begin_swing()


func _begin_swing() -> void:
	queued = false
	hits.clear()
	impacted = false
	prev_screen = []
	raw_prev = []
	sweep_motion = Vector2.ZERO
	p._set_playrate_durations()
	phase = "antic"
	t = 0.0
	p.set_state("attack")
	mon = p.play_role(atk["antic_role"])
	if mon == null:
		_enter_attack()
	else:
		p.play_role_after(mon, atk["attack_role"], _on_antic_blending_out.bind(atk))


## The Attack montage starts when the Antic one starts blending out (UE OnMontageBlendingOut), so the Antic's
## BlendOut and the Attack's BlendIn crossfade instead of dipping to the base pose (recon/ANIMATION.md UNVERIFIED:
## DI2's native melee action chains them).
func _enter_attack() -> void:
	_on_attack_started(p.play_role(atk["attack_role"]))


func _on_antic_blending_out(m: DI2Anim.Montage, swing: Dictionary) -> void:
	if phase == "antic" and atk == swing:
		_on_attack_started(m)


func _on_attack_started(m: DI2Anim.Montage) -> void:
	phase = "attack"
	t = 0.0
	mon = m
	p.add_shake(0.15)


## Montage time where section `name` starts (-1 if the montage has no such section).
static func section_start(m: DI2Anim.Montage, name: String) -> float:
	if m == null:
		return -1.0
	for sec: Array in m.sections:
		if str(sec[0]).to_lower() == name.to_lower():
			return float(sec[1])
	return -1.0


static func in_windows(windows, at: float) -> bool:
	for w in (windows if windows is Array else []):
		if at >= float(w[0]) and at <= float(w[1]):
			return true
	return false


# --- Heavy attacks ----------------------------------------------------------------------------------

## DI2 HeavyAttackIntro montage of the side picked by #LeftHand / #StartOnLeft: its Windup section runs into the
## looping Loop section, held until release.
func _start_charge() -> void:
	var c := p.cls()
	var item := c.pick("HeavyAttackIntro", p.combat_facts(true)) if c else {}
	p.set_state("charge")
	phase = "charge"
	charge = 0.0
	t = 0.0
	mon = p.play_role(item.get("main", {}) if not item.is_empty() else {})


func _charge_time() -> float:
	return float(p.w().get("heavy_charge_time", 1.2))


func _curve(points, x: float) -> float:
	if points == null or points.is_empty():
		return 1.0
	var prev: Array = points[0]
	for pt: Array in points:
		if x <= pt[0]:
			if pt[0] == prev[0]:
				return pt[1]
			return lerpf(prev[1], pt[1], (x - prev[0]) / (pt[0] - prev[0]))
		prev = pt
	return points[-1][1]


## DI2 HeavyAttack (or Lunge): the montage the anim set picks from the heavy contexts
## (HeavyGroundContext, LegsHeavyContext, HeadAndNeckHeavy, StomachAndTorsoHeavy, LeftHand).
func _release_heavy() -> void:
	if charge < 0.2:
		start_light()
		return
	var c := p.cls()
	var spec := p.w()
	p.use_stamina(float(spec["stamina_per_attack"]) * float(spec.get("heavy_stamina_multiplier", 2.0)))
	heavy = true
	hits.clear()
	impacted = false
	prev_screen = []
	raw_prev = []
	sweep_motion = Vector2.ZERO
	var facts := p.combat_facts(true)
	var moving_fwd := Input.get_vector("move_left", "move_right", "move_forward", "move_back").y < -0.5
	lunging = false
	var item := {}
	if moving_fwd and charge > 0.6 and c and c.has_slot("Lunge"):
		item = c.pick("Lunge", facts)
		lunging = not item.is_empty()
		if lunging:
			var fwd := -p.global_transform.basis.z
			p.move_override = fwd * 6.0
			p.override_t = 0.3
	if item.is_empty() and c:
		item = c.pick("HeavyAttack", facts)
	var m: Dictionary = item.get("main", {}) if not item.is_empty() else {}
	heavy_role = m
	var det: Array = m["detect"] if m.get("detect") != null else [0.0, float(m.get("len", 1.0))]
	heavy_detect = Vector2(det[0], det[1])
	hand_left = not hand_left
	phase = "heavy"
	t = 0.0
	p.set_state("attack")
	mon = p.play_role(m)
	p.fov_kick = 4.0
	p.add_shake(0.35)


# --- Per frame ----------------------------------------------------------------------------------------

func update(delta: float) -> void:
	chain_t -= delta
	if chain_t <= 0.0:
		chain_stacks = 0
	if p.state in ["ready", "switch"] and p.lmb_held and p.lmb_t >= 0.22 and p.is_melee() and phase == "":
		_start_charge()
		return
	if phase == "":
		return
	t += delta
	match phase:
		"antic":
			p.move_scale = 0.45
			if p.montage_done(mon):
				_enter_attack()
		"attack":
			p.move_scale = 0.45
			# Montage time: the BP_DetectHits window and the Decision section (AttackDecisionEntered).
			var mt := mon.pos if mon else t
			var det: Array = atk["detect"]
			if mt >= det[0] and mt <= det[1] + 0.02:
				_sweep()
			var dec := section_start(mon, "Decision")
			if mon == null or (dec >= 0.0 and mt >= dec) or p.montage_done(mon):
				phase = "dec"
				t = 0.0
		"dec":
			# AttackDecisionEntered (Decision section start): a buffered press chains the next swing (BP_Chainable
			# covers the Decision section); a held button keeps the montage in Decision, whose ScalePlayRate window
			# stretches it to HeavyAttackHoldTransitionTime, and holding to its end becomes a heavy attack; otherwise
			# the Recovery montage plays from the AttackDec time reached - its first segment is the clip the
			# Decision section plays (466 of 480 DI2 attack items), so it continues the motion and its own BlendOut
			# (1.2 s for the bat) returns the arms to the locomotion pose (recon/ANIMATION.md UNVERIFIED: the native
			# OnAttackDecisionEntered listeners).
			var mt := mon.pos if mon else 0.0
			var dec := section_start(mon, "Decision")
			var loop_at := section_start(mon, "DecisionLoop")
			if queued and (mon == null or in_windows(atk["chain_attack"], mt) or atk["chain_attack"].is_empty()):
				_chain_next()
			elif p.lmb_held and mon and loop_at >= 0.0 and mt < loop_at - 1e-4 and not p.montage_done(mon):
				pass
			elif p.lmb_held and p.is_melee() and mon and loop_at >= 0.0:
				queued = false
				_start_charge()
			else:
				phase = "recovery"
				t = 0.0
				var rd: Dictionary = DI2Anim.montages.get(str(atk["recovery_role"].get("m", "")), {})
				var segs: Array = rd.get("segments", [])
				var start := 0.0
				if mon and dec >= 0.0 and segs.size() > 1 and not mon.segs.is_empty() and segs[0][0] == mon.segs[-1][0]:
					start = clampf(mt - dec, 0.0, float(segs[1][1]))
				mon = p.play_role(atk["recovery_role"], 1.0, start)
		"recovery":
			# Chainable through the Recovery montage (its BP_Chainable window); the montage's own BlendOut (e.g.
			# 1.2 s for the bat) carries the arms back to the locomotion pose while Dani is already free to act.
			var mt := mon.pos if mon else 0.0
			if queued and (mon == null or in_windows(atk["chain_recovery"], mt)):
				_chain_next()
			elif p.montage_done(mon):
				phase = ""
				p.set_state("ready")
		"charge":
			p.move_scale = 0.5
			charge = minf(1.0, charge + delta / _charge_time())
			if charge >= 1.0 and int(t * 10) % 4 == 0:
				p.add_shake(0.08)
			if not p.lmb_held:
				_release_heavy()
		"heavy":
			p.move_scale = 0.3
			var mt := mon.pos if mon else t
			if mt >= heavy_detect.x and mt <= heavy_detect.y + 0.03:
				_sweep()
			# Free again at the montage's Recovery section or its first BP_Chainable window; the montage keeps
			# playing underneath and blends out with its own BlendOut (e.g. 1.0 s Cubic for the bat).
			var free_at := section_start(mon, "Recovery")
			var ch: Array = heavy_role.get("chain", [])
			if not ch.is_empty():
				free_at = float(ch[0][0]) if free_at < 0.0 else minf(free_at, float(ch[0][0]))
			var free := p.montage_done(mon) or (free_at >= 0.0 and mt >= free_at)
			if queued and free:
				_chain_next()
			elif free:
				phase = ""
				p.set_state("ready")


func _chain_next() -> void:
	queued = false
	if p.lmb_held and p.lmb_t >= 0.22:
		_start_charge()
	else:
		start_light()


# --- Weapon trace -------------------------------------------------------------------------------------

func _blade_screen() -> Array:
	var cam := p.camera
	var out := []
	var node: Node3D
	var a: Vector3
	var b: Vector3
	if p.uses_hands(p.weapon):
		# Hand weapons (fists, claws, DI2's FuryFists) have no trail sockets: trace the hand that is moving
		# fastest (the striking one), from the wrist out past the knuckles.
		var best := Vector3.ZERO
		var best_speed := -1.0
		# Standard attacks lead with the hand on their start side (a left_to_right swipe is the left hand);
		# heavies trace whichever hand is moving fastest.
		var hands: Array = ["hand_l", "hand_r"] if heavy else (["hand_l"] if atk.get("from", "left") == "left" else ["hand_r"])
		for hn in hands:
			var hb := p.rig_skel.find_bone(hn)
			var hp := p.rig_skel.global_transform * p.rig_skel.get_bone_global_pose(hb).origin
			var speed: float = hp.distance_to(hand_prev.get(hn, hp))
			hand_prev[hn] = hp
			if speed > best_speed:
				best_speed = speed
				best = hp
		a = best
		b = best + (best - cam.global_position).normalized() * 0.25
	else:
		# DI2's blade line: the weapon skeleton's TrailEnd -> TrailStart sockets.
		var pts := p.blade_points(p.weapon)
		a = pts[0]
		b = pts[1]
	for i in 6:
		var wp := a.lerp(b, i / 5.0)
		if cam.is_position_behind(wp):
			continue
		out.append(cam.unproject_position(wp))
	return out


## DI2 lands swings on the crosshair's line: the weapon's real motion decides when and in which direction the
## sweep travels, and the sweep is anchored so its path crosses the screen centre (perpendicular spread kept small).
func _anchor(pts: Array) -> Array:
	if not raw_prev.is_empty() and raw_prev.size() == pts.size():
		sweep_motion += (pts[-1] as Vector2) - (raw_prev[-1] as Vector2)
	raw_prev = pts
	var vertical := key.begins_with("down") or key.begins_with("up")
	if sweep_motion.length() > 40.0:
		vertical = absf(sweep_motion.y) > absf(sweep_motion.x)
	var c := p.get_viewport().get_visible_rect().size * 0.5
	var tip: Vector2 = pts[-1]
	var out := []
	for sp: Vector2 in pts:
		if vertical:
			out.append(Vector2(c.x + (sp.x - tip.x) * 0.25, sp.y))
		else:
			out.append(Vector2(sp.x, c.y + (sp.y - tip.y) * 0.25))
	return out


func _sweep() -> void:
	var cur := _blade_screen()
	if cur.is_empty():
		return
	cur = _anchor(cur)
	if prev_screen.size() != cur.size():
		prev_screen = cur
	var cam := p.camera
	# MeleeSweepParams.TraceDistance (StabTraceDistance for stabbing weapons).
	var reach: float = p.w().get("stab_reach" if p.w().get("stabbing", false) else "reach", 2.0)
	var space := p.get_world_3d().direct_space_state
	var steps := 4
	for sidx in steps:
		var f := float(sidx + 1) / steps
		for i in cur.size():
			var sp: Vector2 = (prev_screen[i] as Vector2).lerp(cur[i], f)
			var origin := cam.project_ray_origin(sp)
			var dir := cam.project_ray_normal(sp)
			Zombie.sync_hitboxes()   # hitboxes are posed on demand (zombie.gd)
			var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * reach, Util.WORLD | Util.HITBOX)
			q.collide_with_areas = true
			q.exclude = [p.get_rid()]
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				continue
			if not hit["collider"] is Area3D:
				# Hard surface before any zombie: DI2 rebound.
				if hits.is_empty() and not impacted and origin.distance_to(hit["position"]) < reach * 0.85:
					WeaponVfx.melee_world_hit(p, hit, dir)  # DI2 environment hit effects / decals (recon/WEAPON_VFX.md)
					_rebound(hit["position"], hit["normal"])
					return
				continue
			var area: Area3D = hit["collider"]
			var z: Zombie = area.get_meta("zombie")
			if hits.has(z):
				continue
			hits[z] = true
			# Swing direction = how the weapon moves across the screen, as a world-space tangent.
			var moved: Vector2 = (cur[i] as Vector2) - (prev_screen[i] as Vector2)
			var swing := (cam.global_basis.x * moved.x - cam.global_basis.y * moved.y).normalized()
			if swing.length() < 0.1:
				swing = cam.global_basis.x * (1.0 if not hand_left else -1.0)
			_strike(z, area.get_meta("bone"), hit["position"], swing, dir, sp)
	prev_screen = cur


## Environment rebound: the class's Rebound slot (ReboundMontage = ImpactTo + AttackDec, then its recovery).
## DI2 gates it with the weapon's ReboundChanceCurve (Curve_ImpactRebound_EnvOnly) and ReboundInternalCooldown;
## the curve's input is native (recon/UNVERIFIED.md), so every environment hit rebounds here.
func _rebound(at: Vector3, normal: Vector3) -> void:
	var c := p.cls()
	var item := c.pick("Rebound", p.combat_facts(false)) if c else {}
	p.add_shake(0.5)
	p.hit_pause(0.05, 0.1)
	var rb: Dictionary = item.get("rebound", {}) if item.get("rebound") is Dictionary else {}
	var m := p.play_role(rb)
	if m:
		# ReboundMontage (ImpactTo + its Decision section) then the item's recovery montage, like a swing.
		mon = m
		atk["chain_attack"] = rb.get("chain", [])
		atk["recovery_role"] = item.get("recovery", {}) if item.get("recovery") is Dictionary else {}
		atk["chain_recovery"] = atk["recovery_role"].get("chain", [])
		phase = "dec"
		t = 0.0
	impacted = true
	hits[p] = true


## The held weapon's blade axis (TrailStart -> TrailEnd sockets): DI2's SourceObjectAlignment hit fact.
func _blade_axis() -> Vector3:
	if not p.weapon_nodes.has(p.weapon):
		return Vector3.ZERO
	var pts := p.blade_points(p.weapon)
	return ((pts[0] as Vector3) - (pts[1] as Vector3)).normalized() if pts.size() == 2 else Vector3.ZERO


func _strike(z: Zombie, bone: String, point: Vector3, swing: Vector3, ray: Vector3, screen: Vector2) -> void:
	var spec := p.w()
	var fury := p.moves.fury_active
	# Corpses take the hit's gore and impact feel only: no damage numbers, kill credit, perks or build-up
	# (whether DI2 shows numbers on corpses is not verified).
	var corpse := z.dead
	var dmg: float = p.level_damage(randf_range(spec["damage"][0], spec["damage"][1]))
	var crit := randf() < float(spec.get("crit_chance", 0.03))
	if crit:
		dmg *= float(spec.get("crit_multiplier", 1.3))
	var force: float = spec.get("force", 15.0)
	var kind: String = spec["damage_type"]
	if heavy:
		dmg *= _curve(p.w().get("heavy_intensity_curve"), charge)
		force *= _curve(p.w().get("heavy_force_curve"), charge) * 2.5
	if counter_bonus:
		dmg *= 2.5
		force *= 3.0
	if not fury and p.durability.get(p.weapon, 1.0) <= 0.0:
		dmg *= 0.4
	if exhausted:
		dmg *= 0.5
	# Dani's Berserker perk: consecutive hits build up to +35% damage (7% per stack, 5 stacks, 3 s).
	var perk: Dictionary = p.combat["dani"]["perks"]["chain_damage"]
	dmg *= 1.0 + float(perk["per_stack"]) * chain_stacks
	chain_stacks = mini(chain_stacks + 1, int(perk["max_stacks"]))
	chain_t = float(perk["duration"])

	var push := swing
	if key.begins_with("down"):
		push = (swing + Vector3.DOWN).normalized()
	var res: Dictionary = z.take_hit(bone, point, swing, ray, dmg, kind, heavy, float(spec.get("limb_damage_multiplier", 1.0)), force, push, p,
		{"weapon": p.weapon, "CriticalHit": crit, "HeavyAttack": heavy, "mod": mod(), "align": _blade_axis(),
		"damage_type": mod()})   # DI2 mods convert the Physical damage to their element (ConvertDamageTypeAndQuantityCommand)
	var pos: Vector3 = res.get("point", point)
	var killed: bool = not res.get("alive", true)
	var maimed := false
	for o: Dictionary in res.get("outcomes", []):
		if o["type"] in ["dismembered", "crushed", "broken"]:
			maimed = true
	if corpse:
		killed = false
	if mod() != "" and not killed and not corpse:
		# DI2's mod build-up: the level's OnHitAccumulatingEffects (+0.25 on heavy attacks), scaled by the weapon's
		# level (Dani's here) against the zombie's.
		z.accumulate(AccumulatingEffects.mod_effects(mod(), mod_level, false, {"Hit.HeavyAttack": heavy}), p.level, true, pos, bone)
	if not corpse:
		p.popup(pos, str(roundi(dmg)), "crit" if crit else ("heavy" if heavy else "default"))
	if maimed and not corpse:
		p.popup(pos + Vector3.UP * 0.15, "MAIMED", "maimed")
	if z.gore.get_stability() <= 0.01 and not killed:
		p.popup(pos + Vector3.UP * 0.3, "VULNERABLE", "vulnerable")
	p.hitmarker = 0.18
	if killed or maimed:
		p.hitmarker_kill = 0.35
	if not corpse:
		p.on_damage_dealt(dmg, killed, z)

	# Impact feel: the weapon's MeleeArchetypeData.ImpactPauseSettings and WeaponCameraShakeScaleMin/Max.
	# Duration / EaseOut left unset by a weapon use the struct's native default, which isn't in the data: the
	# Rake's explicit 0.08 s / 0.04 s stands in (recon/UNVERIFIED.md #16).
	var ip: Dictionary = spec.get("impact_pause", {})
	var dur: float = ip["duration"] if ip.get("duration") != null else 0.08
	var ease: float = ip["ease_out"] if ip.get("ease_out") != null else 0.04
	p.hit_pause(dur + ease, ip["slowdown"] if ip.get("slowdown") != null else 0.05)
	var shake_range: Array = spec.get("camera_shake", [0.7, 0.8])
	p.add_shake(lerpf(shake_range[0], shake_range[1], randf()))
	if not fury:
		p.add_blood(0.06)
		var dv := DaniVisual.of(p)
		if dv:
			dv.on_melee_hit(crit)
		p.durability[p.weapon] = max(0.0, p.durability[p.weapon] - float(spec.get("durability_loss_per_hit", 0.6)))
		if p.durability[p.weapon] <= 0.0:
			p.say(spec["name"] + " is broken! (T to repair)")
	counter_bonus = false
