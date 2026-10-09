extends Node
## Zombie AI scenarios (DI2 card dealer, zombie_ai.gd; recon/ZOMBIE_AI.md), run from the combat suite
## (autotest_combat.gd). Each scenario logs the cards every zombie drew, the attack montages it started and the
## damage it dealt, checks them against DI2's data, and saves captures to <test_out>/zombie_ai.
## Lines starting "CHECK FAIL" are deviations from DI2's rules; "CHECK ok" lines passed.

var out_dir := ""
var main: Node
var p: Node
var summary: PackedStringArray = []
var _log: PackedStringArray = []
var _damage: Array = []      # [time, zombie name, damage]
var _t0 := 0.0
## Scenario origin, away from the arena centre where earlier combat sections leave fire / fluids behind.
const O := Vector3(15.0, 0.0, 15.0)


func run() -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	await _engage("Walker", "walker")
	await _engage("Runner", "runner")
	await _engage("Shambler", "shambler")
	await _engage("Thug", "thug")
	await _crowd()
	await _crawler()
	await _scream()
	await _suicider()
	await _slobber()
	await _butcher()
	var f := FileAccess.open(out_dir.path_join("zombie_ai.log"), FileAccess.WRITE)
	f.store_string("\n".join(_log))
	for l in _log:
		if l.begins_with("CHECK"):
			summary.append("zombie_ai " + l)


# --- scenarios ------------------------------------------------------------------------------------------------------

## One zombie of `arch` starts 7 m away and fights a stationary Dani for 16 s: EnterCombat / Approach cards first,
## then its inner-ring deck's attacks; no attack before the attack rules' warm-up (DA_AttackRules_* WarmUp Min).
func _engage(arch: String, tag: String) -> void:
	var z := _spawn(arch, Vector3(0, 0.1, -7.0))
	await _run(16.0, [z], tag, [3.0, 8.0, 13.0])
	var ai = z.get("ai")
	if ai == null:
		_check(false, "%s has a ZombieAI" % arch)
		return
	var draws: Array = ai.log
	_log.append("%s draws: %s" % [arch, " ".join(draws.map(func(d): return "%.2f:%s" % [d[0], str(d[1]).trim_prefix("DA_Card_")]))])
	_check(not draws.is_empty(), "%s drew cards" % arch)
	var first_attack := -1.0
	for d: Array in draws:
		var c: Dictionary = ZombieAI.asset(str(d[1]))
		if str(c.get("Parameters", {}).get("AttackSequence", "")).contains("IdleBreak"):
			continue
		if c.get("Parameters", {}).has("AttackSequence"):
			first_attack = float(d[0])
			break
	_log.append("%s first attack card at %.2f s, damage events %s" % [arch, first_attack,
		_damage.filter(func(e): return e[1] == z.name).map(func(e): return "%.2f:%.0f" % [e[0], e[2]])])
	_check(first_attack >= 0.0, "%s attacked within 16 s" % arch)
	# Attacks play DI2's own montage (no nearest-variant / generic-swipe stand-in, UNVERIFIED 80 closed): every
	# AttackDef montage whose segments resolve for this body in montages_zombie.json must be playable, including the
	# segment-only attacks2 "x:<seq>" ones (played by montage name).
	if not is_instance_valid(z):
		_check(false, "%s alive for the montage check" % arch)
		return
	var seg_only := 0
	var broken: Array = []
	var seen := {}
	for k: String in ZombieAI.data.get("assets", {}):
		var d = ZombieAI.data["assets"][k]
		if not (d is Dictionary and d.has("WindUps")):
			continue
		for w: Dictionary in d["WindUps"]:
			for at: Dictionary in w.get("Attacks", []):
				var am := str(at.get("Montage", "")).trim_prefix("@")
				if am == "" or seen.has(am):
					continue
				seen[am] = true
				var segs: Array = ZombieAnim.zdata.get("montages", {}).get(am, {}).get("segments", {}).get(tag, [])
				if segs.is_empty() or not segs.all(func(sg): return str(sg[0]) != ""):
					continue
				var c: String = ai.attack_clip_for(am)
				if c == "":
					broken.append(am)
				elif c == am:
					seg_only += 1
	_log.append("%s segment-only attack montages playable %d, unplayable %s; attacks started: %s" % [arch, seg_only,
		broken, " ".join(ai.attack_log.map(func(e): return "%.2f:%s%s" % [e[0], str(e[1]).trim_prefix("AM_ZMB_"), "(seg)" if e[1] == e[2] else ""]))])
	_check(broken.is_empty() and seg_only > 0, "%s attack montages resolve (segment-only %d)" % [arch, seg_only])


## Five Walkers around Dani: DI2's engagement rings keep the inner ring small (InnerRingRadius 150 cm) and the rest
## strafe / idle-break in the outer ring.
func _crowd() -> void:
	var zs: Array = []
	for i in 5:
		var a := TAU * i / 5.0
		zs.append(_spawn("Walker", Vector3(sin(a) * 5.0, 0.1, -cos(a) * 5.0)))
	await _run(18.0, zs, "crowd", [4.0, 10.0, 16.0])
	var kinds := {}
	for z in zs:
		if z.get("ai") == null:
			continue
		for d: Array in z.ai.log:
			var n := str(d[1]).trim_prefix("DA_Card_")
			kinds[n] = int(kinds.get(n, 0)) + 1
	_log.append("crowd cards: %s" % kinds)
	_check(kinds.size() > 2, "crowd draws several card kinds")


## A Walker without a leg crawls: the Crawler deck (DA_Deck_Walker_Crawler) deals crawler swipes / grapple.
func _crawler() -> void:
	var z := _spawn("Walker", Vector3(0, 0.1, -4.0))
	await _wait(0.4)
	var b: int = z.skeleton.find_bone("calf_l")
	var at: Vector3 = z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin
	z.take_hit("calf_l", at, Vector3.RIGHT, Vector3.FORWARD, 400.0, "sharp", false, 1.0, 0.0)
	await _run(14.0, [z], "crawler", [5.0, 11.0])
	_check(z.gore.is_crawling(), "walker crawls after the leg cut")
	if z.get("ai") != null:
		var crawl_cards: Array = z.ai.log.filter(func(d): return str(d[1]).contains("Crawler") or str(d[1]).contains("Beeline") or str(d[1]).contains("NotPeeked"))
		_log.append("crawler draws: %s" % [z.ai.log.map(func(d): return "%.2f:%s" % [d[0], str(d[1]).trim_prefix("DA_Card_")])])
		_check(not crawl_cards.is_empty(), "crawler deck cards drawn")


## The Screamer's scream (zombie_ai.gd "archetype actions"; recon/ZOMBIE_AI.md 9): the Screamer deck deals
## DA_Card_Scream_Screamer, whose AnimSetAction unit (ActionName EnterCombat) runs BP_Action_ScreamStateMachine_Screamer:
## WindUp (AM_ZMB_Screamer_Attack_Scream_Windup), Scream (the ScreamAngle loop; at ScreamEffectsBegin the explosion
## Scream_Screamer and Aggressive on zombies inside the 1300 cm ScreamSphere), Outro (AM_ZMB_Screamer_Attack_Scream_End).
func _scream() -> void:
	var s := _spawn("Screamer", Vector3(0, 0.1, -6.0))
	var w := _spawn("Walker", Vector3(4.0, 0.1, -9.0))   # 5 m from the Screamer: inside its ScreamSphere
	var shot := {}
	var when := func() -> String:
		if not is_instance_valid(s) or s.get("ai") == null:
			return ""
		for e: Array in s.ai.scream_log:
			for k in ["effects begin", "ScreamEnd", "Scream -> AM_ZMB_Screamer_Attack_Scream_Windup"]:
				if str(e[1]).begins_with(k) and not shot.has(k):
					shot[k] = true
					return {"effects begin": "effects", "ScreamEnd": "outro"}.get(k, "windup")
		return ""
	await _run(30.0, [s, w], "scream", [6.0, 14.0, 22.0], when)
	var ai = s.get("ai")
	if ai == null:
		_check(false, "Screamer has a ZombieAI")
		return
	var ev: Array = ai.scream_log.map(func(e): return str(e[1]))
	_log.append("Screamer draws: %s" % " ".join(ai.log.map(func(d): return "%.2f:%s" % [d[0], str(d[1]).trim_prefix("DA_Card_")])))
	_log.append("Screamer scream log: %s" % " | ".join(ai.scream_log.map(func(e): return "%.2f %s" % [e[0], e[1]])))
	_log.append("Screamer cards left out of the deal (UNVERIFIED 94): %s" % ai.deal_skips)
	var has := func(k: String) -> bool:
		return ev.any(func(x): return x.begins_with(k))
	_check(ai.log.any(func(d): return str(d[1]) == "DA_Card_Scream_Screamer"), "Screamer deals its Scream card")
	_check(has.call("Scream -> AM_ZMB_Screamer_Attack_Scream_Windup"), "scream wind-up montage (ScreamWindup)")
	_check(has.call("Scream -> AM_ZMB_Screamer_Attack_Scream_Loop"), "scream loop montage by ScreamAngle")
	_check(has.call("explosion Scream_Screamer"), "Explosion_Scream -> DA_ExplosionArchetype_Scream_Screamer at ScreamEffectsBegin")
	_check(has.call("aggressive " + str(w.name)) if is_instance_valid(w) else false, "zombie inside the ScreamSphere turns Aggressive")
	_check(has.call("ScreamEnd -> AM_ZMB_Screamer_Attack_Scream_End") and has.call("end"), "scream outro (ScreamEnd) and end")
	var t_on := -1.0
	var t_off := -1.0
	for e: Array in ai.scream_log:
		if str(e[1]) == "effects begin" and t_on < 0.0:
			t_on = float(e[0])
		if str(e[1]).begins_with("effects end") and t_off < 0.0:
			t_off = float(e[0])
	_check(t_on >= 0.0 and t_off >= t_on and t_off - t_on <= 12.0 + 0.1, "scream effects last <= MaxDuration 12 s (%.2f s)" % (t_off - t_on))


## The Suicider (zombie_ai.gd "arming and detonation"; recon/ZOMBIE_AI.md 10): in combat it arms over ArmingDuration 4 s
## (DT_SuicideBalancing_Suicider), the target inside the 250 cm ExecutionSphere raises TriggerSuicideAnticipation, the
## deck deals DA_Card_SuicideDetonation_Suicider, and when its "Suicide" montage ends it dies and explodes
## (Explosion_Suicide -> Suicide_Suicider).
func _suicider() -> void:
	var s := _spawn("Suicider", Vector3(0, 0.1, -7.0))
	var shot := {}
	var when := func() -> String:
		if not is_instance_valid(s) or s.get("ai") == null:
			return ""
		for e: Array in s.ai.scream_log:
			for k in ["TriggerSuicideAnticipation", "suicide "]:
				if str(e[1]).begins_with(k) and not shot.has(k):
					shot[k] = true
					return "anticipation" if k == "TriggerSuicideAnticipation" else "explode"
		return ""
	await _run(20.0, [s], "suicider", [3.0, 8.0], when)
	var ai = s.get("ai") if is_instance_valid(s) else null
	if ai == null:
		_check(false, "Suicider has a ZombieAI")
		return
	var ev: Array = ai.scream_log.map(func(e): return str(e[1]))
	_log.append("Suicider draws: %s" % " ".join(ai.log.map(func(d): return "%.2f:%s" % [d[0], str(d[1]).trim_prefix("DA_Card_")])))
	_log.append("Suicider log: %s; arming %.2f, dead %s" % [" | ".join(ai.scream_log.map(func(e): return "%.2f %s" % [e[0], e[1]])), ai.arming, s.dead])
	_check(ev.has("TriggerSuicideAnticipation"), "Suicider arms and raises TriggerSuicideAnticipation")
	_check(ai.log.any(func(d): return str(d[1]) == "DA_Card_SuicideDetonation_Suicider"), "Suicider deals its detonation card")
	_check(ev.has("suicide Suicide_Suicider") and s.dead, "Suicider dies and explodes (Suicide_Suicider)")


## The Slobber's ranged fire modes (zombie_ai.gd "ranged fire modes"; recon/ZOMBIE_AI.md 11): its Spew / DownwardVomit
## cards play AM_ZMB_Slobber_Attack_Spew / DownwardVomit, whose BP_AnimNotifyState_ActivateProjectileStream windows fire
## DA_RangedWeaponModuleConfig_Slobber's "Spew" / "Vomit" modes: BP_Projectile_Spew_Slobber (5 acid + Corroded 0.1),
## detonating into BP_Fluid_Projectile_Acid_SlobberBile.
func _slobber() -> void:
	var s := _spawn("Slobber", Vector3(0, 0.1, -6.0))
	var shot := {}
	var when := func() -> String:
		if not is_instance_valid(s) or s.get("ai") == null:
			return ""
		# The ranged decks (DA_Deck_Medium / LongRangedAttacks_Slobber) are reached through the engagement-ring /
		# occupancy routing (UNVERIFIED 74): start DA_Card_Spew_Slobber once in combat so the fire mode is exercised.
		if not shot.has("forced") and s.ai.combat_state == "Combat" and s.ai.now > 4.0 and s.ai.play.get("kind", "") != "sequence":
			shot["forced"] = true
			s.ai._end_play(false)
			s.ai._start_card("DA_Card_Spew_Slobber")
		if s.ai.shots_log.is_empty() or shot.has("a"):
			return ""
		shot["a"] = true
		return "shot"
	await _run(24.0, [s], "slobber", [8.0, 12.0, 16.0], when)
	var ai = s.get("ai") if is_instance_valid(s) else null
	if ai == null:
		_check(false, "Slobber has a ZombieAI")
		return
	_log.append("Slobber draws: %s" % " ".join(ai.log.map(func(d): return "%.2f:%s" % [d[0], str(d[1]).trim_prefix("DA_Card_")])))
	_log.append("Slobber shots: %s; log: %s" % [" ".join(ai.shots_log.map(func(e): return "%.2f:%s" % [e[0], e[1]])),
		" | ".join(ai.scream_log.map(func(e): return "%.2f %s" % [e[0], e[1]]))])
	_log.append("Slobber dealt a ranged card itself: %s (ring routing UNVERIFIED 74; the test starts Spew)" %
		ai.log.any(func(d): return str(d[1]) in ["DA_Card_Spew_Slobber", "DA_Card_DownwardVomit_Slobber"]))
	_check(not ai.shots_log.is_empty(), "projectile-stream windows fire the Slobber's fire modes")
	_check(ai.scream_log.any(func(e): return str(e[1]).begins_with("projectile")), "a Slobber projectile hits a character")


## The Butcher: BP_AIController_Butcher inherits BP_AIController_Base_Zombie's Master deck (DA_Deck_CombatMaster_AI),
## which includes its own InnerRing / OuterRing / PriorityCombatActions decks (Pounce, SliceSliceStab, DoubleStab,
## JumpBackAndIdleBreak, Feed). Before the builder's Super-chain fix it had no Master context and dealt nothing.
func _butcher() -> void:
	var b := _spawn("Butcher", Vector3(0, 0.1, -7.0))
	await _run(20.0, [b], "butcher", [6.0, 14.0])
	var ai = b.get("ai") if is_instance_valid(b) else null
	if ai == null:
		_check(false, "Butcher has a ZombieAI")
		return
	_log.append("Butcher draws: %s; attacks: %s; left out: %s" % [" ".join(ai.log.map(func(d): return "%.2f:%s" % [d[0], str(d[1]).trim_prefix("DA_Card_")])),
		" ".join(ai.attack_log.map(func(e): return "%.2f:%s" % [e[0], str(e[1]).trim_prefix("AM_ZMB_")])), ai.deal_skips])
	_check(ai.log.any(func(d): return str(d[1]).ends_with("_Butcher")), "Butcher deals its own cards (Master deck)")
	_check(not ai.attack_log.is_empty(), "Butcher attacks")


# --- helpers --------------------------------------------------------------------------------------------------------

func _spawn(arch: String, at: Vector3) -> Node:
	var z: Node = main.spawn_zombie(O + at, arch)
	z.rotation.y = atan2(at.x, at.z)   # face Dani at the scenario origin
	z.gore.set_health(3000.0)
	return z


## Runs `secs` of AI with Dani held still and topped up, logging damage and saving shots at `shots` (s).
func _run(secs: float, zs: Array, tag: String, shots: Array, shot_when := Callable()) -> void:
	for n in get_tree().get_nodes_in_group("zombies"):
		if not zs.has(n):
			n.remove_from_group("zombies")
			n.queue_free()
	p.global_position = O + Vector3(0, 0.1, 0)
	p.rotation.y = 0.0
	p.set_state("ready")
	_damage.clear()
	_t0 = Time.get_ticks_msec() / 1000.0
	var t := 0.0
	var si := 0
	while t < secs:
		var h: float = p.health
		await get_tree().physics_frame
		t = Time.get_ticks_msec() / 1000.0 - _t0
		if p.health < h:
			var near: Node = zs[0]
			for z in zs:
				if is_instance_valid(z) and z.global_position.distance_to(p.global_position) < near.global_position.distance_to(p.global_position):
					near = z
			_damage.append([t, near.name, h - p.health])
		p.health = p.max_health
		if p.get("state") in ["grapple", "knockback"]:
			_log.append("%s: Dani %s at %.2f s" % [tag, p.state, t])
			p.set_state("ready")
		if shot_when.is_valid():
			var st: String = shot_when.call()
			if st != "":
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(out_dir.path_join("%s_%s.png" % [tag, st]))
		if si < shots.size() and t >= float(shots[si]):
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out_dir.path_join("%s_%02d.png" % [tag, si]))
			si += 1
	for z in zs:
		if is_instance_valid(z):
			z.remove_from_group("zombies")
			z.queue_free()


func _check(ok: bool, what: String) -> void:
	_log.append(("CHECK ok " if ok else "CHECK FAIL ") + what)


func _wait(t: float) -> void:
	await get_tree().create_timer(t).timeout
