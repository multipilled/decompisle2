class_name PlayerRanged
extends RefCounted
## DI2 ranged weapons, driven by each gun's RangedWeaponModulesComponent (data/weapons.json "modules", resolved
## by tools/build_weapons.py) and its held-item class slots (Shoot / Reload / AimDownSights / AdditiveArm-
## Locomotion, data/classes/<class>.json):
##   ammo handler (AmmoCapacity), reload handler (Standard: Partial/FullReloadDuration; Looping: shell by shell),
##   fire mode: shot handler (Standard = N successive shots per press, DelayTimeBetweenShotsInBurst,
##   CooldownTimeBetweenBursts; Looping = automatic), spread handler (min/max, increment per shot, reduction per
##   second after a decay delay), recoil handler (per-shot increments, first-shot multiplier, smooth/decay times),
##   projectile spawner (hitscan swept sphere, single or burst pellets in a cone grid, damage / crit / force
##   quantities, distance falloff in cm), ADS handler (ZoomTransitionTime).
## Each shot / reload plays the arms montage and the gun's own "_Weapon" montage together.

## Weapons whose projectile creates a DI2 explosion on impact (weapon id -> data/explosions.json archetype):
## BP_Weapon_LegendaryRevolver fires BP_Projectile_ImpactCannon (ProjectileResponseCreateExplosion).
const PROJECTILE_EXPLOSIONS := {"legendary_revolver": "ImpactCannon"}

var p: Player
var ads := 0.0
var ads_phase := ""            # "", "in", "zoomed", "out"
var shot_cd := 0.0
var burst_left := 0
var burst_cd := 0.0
var spread := 0.0              # current spread in degrees above the minimum
var since_shot := 99.0
var recoil := Vector2.ZERO     # pending (pitch, yaw) degrees, applied over RecoilSmoothTime
var shots_in_burst := 0
var reload_t := 0.0
var reload_len := 0.0
var reload_partial := false
var reload_looping := false
var reload_stage := ""         # looping reloads: "into" / "loop" / "end"
var reload_clips: Array = []
var weapon_clips: Array = []
var trigger_held := false


func _init(owner: Player) -> void:
	p = owner


# --- Data -------------------------------------------------------------------------------------------------

func config() -> Dictionary:
	var m = p.w().get("modules")
	if m is Dictionary and not m.get("InlineAmmoConfigsWithSupportedFireModes", []).is_empty():
		return m["InlineAmmoConfigsWithSupportedFireModes"][0]
	return {}


func fire_mode() -> Dictionary:
	var fm: Array = config().get("FireModes", [])
	return fm[0] if not fm.is_empty() else {}


func _num(v, fallback: float) -> float:
	if v == null:
		return fallback
	if v is Array:
		return randf_range(float(v[0]), float(v[1]))
	if v is Dictionary:
		return _num(v.get("Value"), fallback)
	return float(v)


func capacity() -> int:
	return int(_num(config().get("AmmoHandler", {}).get("AmmoCapacity"), float(p.w().get("magazine", 12))))


func _facts() -> Dictionary:
	return {"ADSZoomed": ads_phase == "zoomed", "ADSZoomingIn": ads_phase == "in", "ADSZoomingOut": ads_phase == "out",
		"AmmoState": "AmmoEmpty" if p.mag <= 0 else ""}


## Clip for the ADS loop (zoomed idle or the additive ADS walk bob).
func ads_loop_clip(moving: bool) -> String:
	var c := p.cls()
	if c == null:
		return ""
	var n := c.clip("AdditiveArmLocomotion", "main", _facts()) if moving else ""
	if n == "" or not p.has_clip(n):
		n = c.clip("AimDownSights", "main", {"ADSZoomed": true})
	return n if p.has_clip(n) else ""


# --- Per frame --------------------------------------------------------------------------------------------

func update(delta: float) -> void:
	shot_cd = maxf(0.0, shot_cd - delta)
	burst_cd = maxf(0.0, burst_cd - delta)
	since_shot += delta
	var fm := fire_mode()
	var rec: Dictionary = fm.get("RecoilHandler", {})
	var sp: Dictionary = fm.get("SpreadHandler", {})
	if since_shot > _num(sp.get("SpreadDecayDelayAfterFiringInSeconds"), 0.5):
		spread = maxf(0.0, spread - _num(sp.get("SpreadReductionInDegreesPerSecond"), 2.0) * delta)
	var smooth := maxf(_num(rec.get("RecoilSmoothTime"), 0.05), 0.001)
	var kick := recoil * minf(1.0, delta / smooth)
	recoil -= kick
	p.pitch = clampf(p.pitch + deg_to_rad(kick.x), deg_to_rad(-85), deg_to_rad(85))
	p.rotate_y(deg_to_rad(kick.y))
	if p.is_melee() or p.moves.fury_active:
		ads = 0.0
		ads_phase = ""
		return
	var zoom_t := _num(fm.get("AimDownSightsHandler", {}).get("ZoomTransitionTime"), float(p.w().get("ads_time", 0.2)))
	if p.state in ["ready", "shoot"]:
		var was := ads
		ads = move_toward(ads, 1.0 if p.rmb_held else 0.0, delta / maxf(zoom_t, 0.01))
		if was < ads and ads < 1.0:
			_set_ads("in")
		elif was > ads and ads > 0.0:
			_set_ads("out")
		elif ads >= 1.0:
			_set_ads("zoomed")
		elif ads <= 0.0:
			ads_phase = ""
		_update_ads_walk()
		# Bursts and automatic fire keep going while the handler wants more shots.
		if burst_left > 0 and shot_cd <= 0.0:
			_shoot_once()
		elif trigger_held and fm.get("ShotHandler", {}).get("_type", "") == "LoopingShotHandler" and shot_cd <= 0.0 and p.state in ["ready", "shoot"]:
			_shoot_once()
	if p.state == "reload":
		ads = move_toward(ads, 0.0, delta * 8.0)
		reload_t += delta
		_update_reload()
	elif p.state == "shoot" and p.state_t > 0.12 and burst_left <= 0:
		p.set_state("ready")


## DI2 AdditiveArmLocomotion (#ADSZoomed): the ADS walk is an AAT_RotationOffsetMeshSpace montage in the
## AdditiveArmsLocomotion slot group, layered on the ADS pose while Dani moves; it blends out with its own BlendOut.
func _update_ads_walk() -> void:
	var cur := p.anim.active("AdditiveArmsLocomotionGroup")
	var moving := Vector2(p.velocity.x, p.velocity.z).length() > 0.5
	if ads_phase == "zoomed" and moving and p.state in ["ready", "shoot"]:
		if cur == null:
			p.play_role(p.slot_role("AdditiveArmLocomotion", "main", _facts()))
	elif cur != null:
		var bo: Array = cur.d.get("blend_out", [0.1, "HermiteCubic"])
		cur.stop(float(bo[0]), str(bo[1]))


## AimDownSights montages by phase (#ADSZoomingIn -> ADS_In, #ADSZoomed -> the looping ADS montage,
## #ADSZoomingOut -> ADS_Out, which blends back to the locomotion pose with its own BlendOut).
func _set_ads(phase: String) -> void:
	if ads_phase == phase:
		return
	ads_phase = phase
	if p.state == "ready":
		p.play_role(p.slot_role("AimDownSights", "main", _facts()))


# --- Shooting ---------------------------------------------------------------------------------------------

func trigger(pressed: bool) -> void:
	trigger_held = pressed
	if pressed:
		fire()


func fire() -> void:
	if p.is_melee() or p.state not in ["ready", "shoot"] or shot_cd > 0.0 or burst_cd > 0.0 or burst_left > 0:
		return
	if p.mag <= 0:
		reload()
		return
	var sh: Dictionary = fire_mode().get("ShotHandler", {})
	burst_left = int(_num(sh.get("NumberOfSuccessiveShotsBeforeEndShoot"), 1.0)) if sh.get("_type", "") != "LoopingShotHandler" else 1
	shots_in_burst = 0
	_shoot_once()


func _shoot_once() -> void:
	if p.mag <= 0:
		burst_left = 0
		return
	var spec := p.w()
	var fm := fire_mode()
	var sh: Dictionary = fm.get("ShotHandler", {})
	var sp: Dictionary = fm.get("SpreadHandler", {})
	var rec: Dictionary = fm.get("RecoilHandler", {})
	var ps: Dictionary = fm.get("ProjectileSpawner", {})
	p.mag -= 1
	burst_left = maxi(0, burst_left - 1)
	shot_cd = _num(sh.get("DelayTimeBetweenShotsInBurst"), float(spec.get("delay_between_shots", 0.2)))
	if burst_left == 0 and sh.get("_type", "") != "LoopingShotHandler":
		burst_cd = _num(sh.get("CooldownTimeBetweenBursts"), 0.0)
	since_shot = 0.0
	p.set_state("shoot")
	var c := p.cls()
	var item := c.pick("Shoot", _facts()) if c else {}
	p.play_role(item.get("main", {}) if not item.is_empty() else {})
	var gun := p.weapon_anim()
	var gun_clips: Array = item.get("weapon", {}).get("clips", [])
	if gun and not gun_clips.is_empty() and gun.has_animation(gun_clips[0]):
		gun.stop()
		gun.play(gun_clips[0])
	# Spread (degrees) and recoil (degrees per shot) from the handlers.
	var spread_deg := _num(sp.get("MinSpreadInDegrees"), 1.0) + spread
	spread = minf(spread + _num(sp.get("SpreadIncrementPerShotInDegrees"), 0.5),
		_num(sp.get("MaxSpreadInDegrees"), 2.5) - _num(sp.get("MinSpreadInDegrees"), 1.0))
	var first := shots_in_burst == 0
	shots_in_burst += 1
	var mult := _num(rec.get("FirstShotInBurstRecoilMultiplier"), 1.0) if first else 1.0
	recoil += Vector2(randf_range(_num(rec.get("MinVerticalRecoilIncrementPerShotInDegrees"), 0.7), _num(rec.get("MaxVerticalRecoilIncrementPerShotInDegrees"), 1.0)),
		randf_range(_num(rec.get("MinHorizontalRecoilIncrementPerShotInDegrees"), -0.15), _num(rec.get("MaxHorizontalRecoilIncrementPerShotInDegrees"), 0.15))) * mult
	p.add_shake(0.2)
	var cam := p.camera.global_transform
	var method = ps.get("ProjectileSpawnMethod")
	var count := 1
	var cone := Vector4.ZERO
	if method is Dictionary and method.get("_type", "") == "SpawnMethodBurstProjectile":
		count = int(_num(method.get("MinProjectileCount"), 1.0))
		cone = Vector4(_num(method.get("MinHorizontalConeSizeInDegrees"), 0.0), _num(method.get("MaxHorizontalConeSizeInDegrees"), 0.0),
			_num(method.get("MinVerticalConeSizeInDegrees"), 0.0), _num(method.get("MaxVerticalConeSizeInDegrees"), 0.0))
	var aim_spread := spread_deg * (0.3 if ads > 0.5 else 1.0)
	var r := deg_to_rad(aim_spread) * sqrt(randf())
	var a := randf() * TAU
	var aim_dir := (cam.basis * Basis(Vector3.FORWARD, a) * Basis(Vector3.RIGHT, r) * Vector3.FORWARD).normalized()
	WeaponVfx.on_shot(p, item)  # DI2 muzzle flash, casings, gun-montage particle notifies (recon/WEAPON_VFX.md)
	for i in count:
		var dir := aim_dir
		if count > 1:
			# Pellets: DI2 spreads them over a grid inside the cone; sampled uniformly per cell here.
			var gw := int(_num(method.get("DistributionGridWidthCellCount"), 3.0))
			var gh := int(_num(method.get("DistributionGridHeightCellCount"), 3.0))
			var cx := (i % gw + randf()) / gw
			var cy := (int(i / gw) % gh + randf()) / gh
			var yaw := deg_to_rad(lerpf(cone.x, cone.y, cx))
			var pit := deg_to_rad(lerpf(cone.z, cone.w, cy))
			dir = (Basis(cam.basis.y, yaw) * Basis(cam.basis.x, pit) * aim_dir).normalized()
		_hitscan(cam.origin, dir, ps)


func _hitscan(origin: Vector3, dir: Vector3, ps: Dictionary) -> void:
	var spec := p.w()
	var radius := _num(ps.get("SweptSphereRadius"), 2.0) * 0.01 if ps.get("bUseSweptSphereOverRay", false) else 0.0
	Zombie.sync_hitboxes()   # hitboxes are posed on demand (zombie.gd)
	var space := p.get_world_3d().direct_space_state
	var hit := {}
	if radius > 0.0:
		var q := PhysicsShapeQueryParameters3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		q.shape = sphere
		q.transform = Transform3D(Basis.IDENTITY, origin)
		q.motion = dir * 120.0
		q.collision_mask = Util.WORLD | Util.HITBOX
		q.collide_with_areas = true
		q.exclude = [p.get_rid()]
		var frac := space.cast_motion(q)
		if frac[1] < 1.0:
			var rq := PhysicsRayQueryParameters3D.create(origin, origin + dir * (120.0 * frac[1] + radius * 4.0), Util.WORLD | Util.HITBOX)
			rq.collide_with_areas = true
			rq.exclude = [p.get_rid()]
			hit = space.intersect_ray(rq)
			if hit.is_empty():
				q.transform = Transform3D(Basis.IDENTITY, origin + dir * 120.0 * frac[1])
				q.motion = Vector3.ZERO
				var near := space.get_rest_info(q)
				if not near.is_empty():
					hit = {"position": near["point"], "normal": near["normal"], "collider": instance_from_id(near["collider_id"])}
	else:
		var rq := PhysicsRayQueryParameters3D.create(origin, origin + dir * 120.0, Util.WORLD | Util.HITBOX)
		rq.collide_with_areas = true
		rq.exclude = [p.get_rid()]
		hit = space.intersect_ray(rq)
	WeaponVfx.on_projectile(p, origin, dir, hit)  # DI2 tracer + world impact effects / decals (recon/WEAPON_VFX.md)
	if hit.is_empty():
		return
	# Rounds whose projectile carries a ProjectileResponseCreateExplosion (BP_Projectile_ImpactCannon ->
	# DA_ExplosionArchetype_ImpactCannon) explode where they land, on any surface, besides their point impact.
	if PROJECTILE_EXPLOSIONS.has(p.weapon):
		DI2Explosion.spawn(p.get_parent(), PROJECTILE_EXPLOSIONS[p.weapon], hit["position"], p, p.level_damage(1.0))
	if not hit["collider"] is Area3D:
		return
	var area: Area3D = hit["collider"]
	var z: Zombie = area.get_meta("zombie")
	var bone: String = area.get_meta("bone")
	var dist_cm := origin.distance_to(hit["position"]) * 100.0
	var df: Dictionary = ps.get("DistanceBasedDamageFalloff", {})
	var fall := 0.0
	if ps.get("bApplyDistanceBasedDamageFalloff", false) and df.get("ScalarStartRange") != null and df.get("ScalarEndRange") != null:
		fall = clampf(inverse_lerp(float(df["ScalarStartRange"]), float(df["ScalarEndRange"]), dist_cm), 0.0, 1.0)
	var dmg := p.level_damage(_num(ps.get("DamageQuantity"), _num(spec.get("damage"), 20.0))) * lerpf(1.0, _num(df.get("ScaleMultiplierAppliedAtEndRange"), 0.5), fall)
	# Head / neck hits: DI2's CriticalDamageQuantity (recon/UNVERIFIED.md: how DI2 applies it is native).
	var crit := bone in ["head", "neck_01"]
	if crit:
		dmg *= _num(ps.get("CriticalDamageQuantity"), 1.0)
	var force := _num(ps.get("ForceQuantity"), 10.0)
	var corpse := z.dead
	var res := z.take_hit(bone, hit["position"], dir, dir, dmg, "projectile", false, float(spec.get("limb_damage_multiplier", 1.0)), force, dir, p,
		{"weapon": p.weapon, "mod": p.melee.mod(), "damage_type": p.melee.mod()})
	if p.melee.mod() != "" and res.get("alive", false):
		# DI2's ranged mod build-up (DA_WeaponModConfig_RangedDefault): OnHit (+0.25 on headshots), weapon-level scaled.
		z.accumulate(AccumulatingEffects.mod_effects(p.melee.mod(), p.melee.mod_level, true, {"Hit.Head": bone == "head"}),
			p.level, true, res.get("point", hit["position"]), bone)
	var pos: Vector3 = res.get("point", hit["position"])
	if corpse:
		return   # a corpse takes the shot's gore only (no numbers or kill credit)
	p.popup(pos, str(roundi(dmg)), "crit" if crit else "default")
	for o: Dictionary in res.get("outcomes", []):
		if o["type"] in ["dismembered", "crushed"]:
			p.popup(pos + Vector3.UP * 0.15, "MAIMED", "maimed")
			p.hitmarker_kill = 0.35
	p.hitmarker = 0.18
	p.on_damage_dealt(dmg, not res.get("alive", true), z)


# --- Reload -----------------------------------------------------------------------------------------------

func reload() -> void:
	if p.is_melee() or p.state not in ["ready", "shoot"] or p.reserve <= 0 or p.mag >= capacity():
		return
	var rh: Dictionary = config().get("ReloadHandler", {})
	reload_partial = p.mag > 0
	reload_looping = rh.get("_type", "") == "LoopingReloadHandler"
	reload_len = _num(rh.get("PartialReloadDuration") if reload_partial else rh.get("FullReloadDuration"),
		float(p.w().get("reload_partial" if reload_partial else "reload_full", 1.8)))
	reload_t = 0.0
	burst_left = 0
	p.set_state("reload")
	var c := p.cls()
	var item := c.pick("Reload", _facts()) if c else {}
	reload_clips = item.get("main", {}).get("clips", [])
	weapon_clips = item.get("weapon", {}).get("clips", [])
	reload_stage = "into"
	if not reload_looping:
		# Standard reloads: the arms montage is stretched to the handler's Partial/FullReloadDuration.
		var md: Dictionary = DI2Anim.montages.get(str(item.get("main", {}).get("m", "")), {})
		var length := float(md.get("length", p.clip_len(reload_clips[0]) if not reload_clips.is_empty() else reload_len))
		p.play_role(item.get("main", {}), length / maxf(reload_len, 0.01))
		var gun := p.weapon_anim()
		if gun and not weapon_clips.is_empty() and gun.has_animation(weapon_clips[0]):
			gun.play(weapon_clips[0], -1, gun.get_animation(weapon_clips[0]).length / maxf(reload_len, 0.01))
		return
	_play_reload_stage(0)


func _play_reload_stage(i: int) -> void:
	if i >= reload_clips.size():
		return
	var arms: String = reload_clips[i]
	var gun := p.weapon_anim()
	if reload_looping:
		p.play(arms, 0.06)
	else:
		# Standard reloads: the montage is stretched to the handler's Partial/FullReloadDuration.
		p.play(arms, 0.08, p.clip_len(arms) / maxf(reload_len, 0.01))
	if gun and i < weapon_clips.size() and gun.has_animation(weapon_clips[i]):
		var wl := gun.get_animation(weapon_clips[i]).length
		gun.play(weapon_clips[i], -1, wl / maxf(reload_len, 0.01) if not reload_looping else 1.0)


func _update_reload() -> void:
	if not reload_looping:
		if reload_t >= reload_len:
			var take := mini(capacity() - p.mag, p.reserve)
			p.mag += take
			p.reserve -= take
			p.set_state("ready")
		return
	# Looping (shell by shell): into -> loop per round -> end; each loop adds one round.
	var done := p.montage_done(p.montage())
	match reload_stage:
		"into":
			if done:
				reload_stage = "loop"
				_play_reload_stage(1)
		"loop":
			if done:
				if p.reserve > 0 and p.mag < capacity():
					p.mag += 1
					p.reserve -= 1
				if p.mag >= capacity() or p.reserve <= 0 or trigger_held:
					reload_stage = "end"
					_play_reload_stage(2)
				else:
					_play_reload_stage(1)
		"end":
			if done:
				p.set_state("ready")
