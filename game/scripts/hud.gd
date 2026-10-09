class_name Hud
extends Control
## DI2 HUD rebuilt from the game's own UI art (UI/HUD textures, Scaleform reticle pieces exported with
## JPEXS) and fonts (Cheddar Gothic Sans for titles/numbers, Montserrat for text): segmented health bar +
## medkits, stamina strip, Fury splat meter, weapon circle with a rendered weapon icon, curveball, reticle +
## hit wedges, enemy name slates (level, rank, health, stability), damage popups, XP bar + LEVEL UP,
## hints with the grapple ring, hit-direction indicator, DEATH screen.

const UI := "res://assets/di2/ui/"

var player: Player
var progression: Progression
var show_debug := false
var show_help := true
var title_font: Font
var text_font: Font
var tex := {}
var weapon_icons := {}
var fury_frames: Array = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_font = load(UI + "CheddarGothicSansTwo.ttf")
	text_font = load(UI + "Montserrat.ttf")
	for n in ["T_HUD_Health_HealthBarTexture", "T_HUD_Health_StaminaBarTexture", "T_HUD_Stamina_BackgroundTexture",
			"T_HUD_HealthPack", "T_HUD_EquippedWeapon_Background", "T_HUD_Health_EnemyHealthBar", "T_HUD_Health_EnemyStaminaBar",
			"T_Icon_EnemyNameSlate_Rank_Common", "T_HUD_Fury_Texture_1", "T_HUD_Fury_Texture_3", "T_HUD_HintPopUp",
			"T_HUD_HintPopUp_Fury", "T_ElementalDamageType_Fire_D", "T_ElementalDamageType_Shock_D", "T_ElementalDamageType_Acid_D",
			"T_HUD_FailScreen_DeathScreen", "T_HUD_CenteralNotifications_BG_Ink", "T_Icon_Minigame_InnerRing", "T_Icon_Minigame_OuterRing",
			"T_HUD_PickUpLog_CommonSplatWhite", "reticle_dot", "reticle_cross", "reticle_circle", "hitmarker", "hitmarker_kill",
			"reticle_throw", "reticle_chevron", "T_HUD_WeaponWheel_TextBG"]:
		if ResourceLoader.exists(UI + n + ".png"):
			tex[n] = load(UI + n + ".png")
	for i in range(0, 30, 2):
		var f := UI + "T_HUD_Fury_Shockwave_Loop_%03d.png" % i
		if ResourceLoader.exists(f):
			fury_frames.append(load(f))



## Weapon slot image: the weapon mesh rendered once into a small viewport, built the first time a weapon is shown
## (stand-in until DI2's SWF_Icons_Items icons are extracted: recon/UNVERIFIED.md #21).
func weapon_icon(w: String) -> Texture2D:
	if weapon_icons.has(w):
		return weapon_icons[w]
	var data: Dictionary = player.data
	weapon_icons[w] = null
	if not data.has(w) or not ResourceLoader.exists(data[w].get("mesh", "")):
		return null
	var vp := SubViewport.new()
	vp.size = Vector2i(256, 256)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var inst: Node3D = load(data[w]["mesh"]).instantiate()
	vp.add_child(inst)
	Util.apply_prop_materials(inst, data[w]["mesh"].get_basename() + ".materials.json")
	var aabb := AABB()
	var first := true
	for mi: MeshInstance3D in Util.find_all(inst, "MeshInstance3D"):
		var a: AABB = mi.global_transform * mi.get_aabb()
		aabb = a if first else aabb.merge(a)
		first = false
	var size := aabb.size.length()
	var center := aabb.get_center()
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = size * 0.85
	vp.add_child(cam)
	cam.look_at_from_position(center + Vector3(0.0, 0.0, size) + Vector3(0.001, 0, 0), center, Vector3.UP)
	# Lay the long axis diagonally like DI2's weapon slot.
	inst.rotate_object_local(Vector3.FORWARD, 0.0)
	cam.rotate_object_local(Vector3.FORWARD, deg_to_rad(-40))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 30, 0)
	vp.add_child(light)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.6)
	e.background_mode = Environment.BG_CLEAR_COLOR
	env.environment = e
	vp.add_child(env)
	weapon_icons[w] = vp.get_texture()
	return weapon_icons[w]


func _process(_delta: float) -> void:
	queue_redraw()


# --- Drawing helpers --------------------------------------------------------------------------------

func _t(name: String) -> Texture2D:
	return tex.get(name)


func _bar(t: Texture2D, rect: Rect2, frac: float, fill: Color, back: Color) -> void:
	if t == null:
		draw_rect(rect, back)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * frac, rect.size.y)), fill)
		return
	draw_texture_rect(t, rect, false, back)
	var src := Rect2(Vector2.ZERO, Vector2(t.get_width() * clampf(frac, 0.0, 1.0), t.get_height()))
	draw_texture_rect_region(t, Rect2(rect.position, Vector2(rect.size.x * clampf(frac, 0.0, 1.0), rect.size.y)), src, fill)


func _text(font: Font, pos: Vector2, s: String, size: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0, outline := 6) -> void:
	if outline > 0:
		draw_string_outline(font, pos, s, align, width, size, outline, Color(0, 0, 0, col.a * 0.85))
	draw_string(font, pos, s, align, width, size, col)


func _tex_centered(t: Texture2D, c: Vector2, size: float, col := Color.WHITE) -> void:
	if t == null:
		return
	var aspect := float(t.get_width()) / maxf(1.0, t.get_height())
	var s := Vector2(size * aspect, size) if aspect >= 1.0 else Vector2(size, size / aspect)
	draw_texture_rect(t, Rect2(c - s * 0.5, s), false, col)


# --- HUD ------------------------------------------------------------------------------------------

func _draw() -> void:
	if player == null:
		return
	var vs := get_viewport_rect().size
	var c := vs * 0.5
	var k := vs.y / 1080.0

	_draw_enemy_slates(k)
	_draw_popups(k)
	_draw_reticle(c, k)
	_draw_player_status(vs, k)
	_draw_weapon(vs, k)
	_draw_progression(vs, k)
	_draw_hint(c, k)
	_draw_hurt(c, vs, k)
	if player.message_t > 0.0 and player.message != "":
		_text(title_font, Vector2(0, c.y - 190 * k), player.message, int(42 * k), Color(1, 1, 1, minf(1.0, player.message_t * 2.0)), HORIZONTAL_ALIGNMENT_CENTER, vs.x)
	if player.dead:
		draw_rect(Rect2(Vector2.ZERO, vs), Color(0, 0, 0, 0.55))
		var d := _t("T_HUD_FailScreen_DeathScreen")
		if d:
			draw_texture_rect(d, Rect2(Vector2.ZERO, vs), false)
		_text(text_font, Vector2(0, vs.y * 0.82), "Press ENTER to respawn", int(26 * k), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, vs.x)
	if show_debug:
		_draw_debug(k)
	if show_help:
		_draw_help(vs, k)
	if player.catalog_open:
		_draw_catalog(vs, k)


## F3: every DI2 weapon archetype with its class and source stats (Up/Down, PgUp/PgDn, Enter).
func _draw_catalog(vs: Vector2, k: float) -> void:
	var ids: Array = player.catalog_ids
	var x := 60.0 * k
	var w := vs.x * 0.62
	draw_rect(Rect2(Vector2(x - 20 * k, 40 * k), Vector2(w, vs.y - 80 * k)), Color(0, 0, 0, 0.82))
	_text(title_font, Vector2(x, 90 * k), "WEAPONS  (%d)   [F3 close, Enter equip into slot %d]" % [ids.size(), player.loadout.find(player.weapon) + 1], int(30 * k), Color.WHITE)
	var rows := int((vs.y - 200 * k) / (26 * k))
	var start := clampi(player.catalog_i - rows / 2, 0, maxi(0, ids.size() - rows))
	for r in rows:
		var i := start + r
		if i >= ids.size():
			break
		var spec: Dictionary = player.data[ids[i]]
		var y := 130 * k + r * 26 * k
		var sel: bool = i == player.catalog_i
		if sel:
			draw_rect(Rect2(Vector2(x - 10 * k, y - 20 * k), Vector2(w - 20 * k, 25 * k)), Color(0.75, 0.15, 0.1, 0.6))
		var stats := ""
		if spec["kind"] == "melee":
			stats = "%s %s  dmg %s  force %s  reach %.2f" % [spec.get("damage_type", ""), spec.get("attacker_weight", ""), str(spec.get("damage")), str(spec.get("force")), float(spec.get("reach", 0))]
		else:
			stats = "dmg %s  mag %s" % [str(spec.get("damage")), str(player.ranged.capacity() if ids[i] == player.weapon else spec.get("magazine"))]
		_text(text_font, Vector2(x, y), "%-28s %-30s %s" % [spec["name"].substr(0, 28), str(spec.get("class_id", "")).substr(0, 30), stats], int(17 * k), Color.WHITE if sel else Color(0.85, 0.85, 0.85), HORIZONTAL_ALIGNMENT_LEFT, w, 3)


func _draw_player_status(vs: Vector2, k: float) -> void:
	var x := 48.0 * k
	var y := vs.y - 150.0 * k
	# Fury splat meter above the health bar.
	var fury_rect := Rect2(Vector2(x - 10 * k, y - 70 * k), Vector2(300 * k, 96 * k))
	_bar(_t("T_HUD_Fury_Texture_3"), fury_rect, player.fury, Color(1.0, 0.42, 0.08) if not player.moves.fury_active else Color(1.0, 0.15, 0.05), Color(0.08, 0.06, 0.05, 0.85))
	if player.fury >= 1.0 and not player.moves.fury_active and not fury_frames.is_empty():
		var frame: Texture2D = fury_frames[int(Time.get_ticks_msec() / 60.0) % fury_frames.size()]
		draw_texture_rect(frame, Rect2(fury_rect.position + Vector2(-20, -30) * k, Vector2(160, 160) * k), false, Color(1, 0.6, 0.2, 0.9))
		_text(title_font, fury_rect.position + Vector2(12 * k, 62 * k), "FURY  [V]", int(30 * k), Color(1, 0.75, 0.3))
	# Health: DI2's segmented white texture, tinted.
	var hp := player.health / player.max_health
	var hcol := Color(0.86, 0.12, 0.1) if hp > 0.3 else Color(1.0, 0.25 + 0.2 * sin(Time.get_ticks_msec() * 0.01), 0.15)
	_bar(_t("T_HUD_Health_HealthBarTexture"), Rect2(Vector2(x, y), Vector2(330 * k, 76 * k)), hp, hcol, Color(0.1, 0.08, 0.08, 0.75))
	_text(title_font, Vector2(x + 340 * k, y + 54 * k), str(roundi(player.health)), int(40 * k), Color.WHITE)
	# Medkits.
	var mk := _t("T_HUD_HealthPack")
	if mk:
		draw_texture_rect(mk, Rect2(Vector2(x, y - 4 * k - 44 * k), Vector2(44, 44) * k), false)
	_text(title_font, Vector2(x + 8 * k, y - 14 * k), "+", int(36 * k), Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, -1, 4)
	_text(text_font, Vector2(x + 52 * k, y - 14 * k), "x%d  [H]" % player.medkits, int(20 * k), Color(0.9, 0.9, 0.9))
	# Stamina strip on its grunge backing.
	var srect := Rect2(Vector2(x - 8 * k, y + 80 * k), Vector2(350 * k, 48 * k))
	var bg := _t("T_HUD_Stamina_BackgroundTexture")
	if bg:
		draw_texture_rect(bg, srect, false, Color(1, 1, 1, 0.9))
	_bar(_t("T_HUD_Health_StaminaBarTexture"), Rect2(srect.position + Vector2(24, 18) * k, Vector2(300 * k, 12 * k)), player.stamina / player.max_stamina, Color(0.95, 0.9, 0.7), Color(0.2, 0.2, 0.2, 0.6))


func _draw_weapon(vs: Vector2, k: float) -> void:
	var r := 92.0 * k
	var cc := Vector2(vs.x - 150 * k, vs.y - 150 * k)
	var bg := _t("T_HUD_EquippedWeapon_Background")
	if bg:
		draw_texture_rect(bg, Rect2(cc - Vector2(r, r), Vector2(r, r) * 2), false, Color(1, 1, 1, 0.92))
	var icon: Texture2D = weapon_icon(player.weapon)
	if icon and not player.moves.fury_active:
		draw_texture_rect(icon, Rect2(cc - Vector2(r, r) * 0.82, Vector2(r, r) * 1.64), false)
	var spec := player.w()
	var name: String = "FURY" if player.moves.fury_active else spec["name"].to_upper()
	_text(title_font, Vector2(vs.x - 520 * k, vs.y - 196 * k), name, int(34 * k), Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT, 260 * k)
	if player.is_melee() and not player.moves.fury_active:
		var dur: float = player.durability[player.weapon] / player.max_durability[player.weapon]
		var col := Color(0.55, 0.85, 0.35) if dur > 0.5 else (Color(0.95, 0.7, 0.2) if dur > 0.0 else Color(0.5, 0.5, 0.5))
		_bar(null, Rect2(Vector2(vs.x - 430 * k, vs.y - 182 * k), Vector2(170 * k, 8 * k)), dur, col, Color(0, 0, 0, 0.6))
		if dur <= 0.0:
			_text(text_font, Vector2(vs.x - 520 * k, vs.y - 150 * k), "BROKEN  [T]", int(20 * k), Color(1, 0.4, 0.3), HORIZONTAL_ALIGNMENT_RIGHT, 260 * k)
	elif not player.is_melee():
		_text(title_font, Vector2(vs.x - 520 * k, vs.y - 140 * k), "%d" % player.mag, int(56 * k), Color.WHITE if player.mag > 0 else Color(1, 0.3, 0.3), HORIZONTAL_ALIGNMENT_RIGHT, 200 * k)
		_text(text_font, Vector2(vs.x - 315 * k, vs.y - 148 * k), "/ %d" % player.reserve, int(22 * k), Color(0.85, 0.85, 0.85))
	# Weapon mod icon.
	var mod := player.melee.mod()
	var mod_tex: String = {"fire": "T_ElementalDamageType_Fire_D", "electric": "T_ElementalDamageType_Shock_D", "acid": "T_ElementalDamageType_Acid_D"}.get(mod, "")
	if mod_tex != "":
		_tex_centered(_t(mod_tex), cc + Vector2(-r * 0.8, r * 0.8), 34 * k, {"fire": Color(1, 0.5, 0.2), "electric": Color(0.5, 0.8, 1), "acid": Color(0.6, 0.9, 0.2)}[mod])
	elif mod == "bleed":
		_text(text_font, cc + Vector2(-r, r), "BLEED", int(16 * k), Color(0.9, 0.2, 0.2))
	# Curveball slot.
	var cb: String = PlayerMoves.CURVEBALLS[player.moves.curveball_i]
	var cbc := Vector2(vs.x - 300 * k, vs.y - 70 * k)
	draw_circle(cbc, 30 * k, Color(0.05, 0.05, 0.05, 0.8))
	var ready := player.moves.curveball_cd <= 0.0
	if not ready:
		draw_arc(cbc, 30 * k, -PI / 2, -PI / 2 + TAU * (1.0 - player.moves.curveball_cd / PlayerMoves.CURVEBALL_COOLDOWN), 32, Color(1, 1, 1, 0.7), 4 * k)
	_text(text_font, cbc + Vector2(-90 * k, 52 * k), cb.capitalize() + "  [Q]", int(17 * k), Color.WHITE if ready else Color(0.6, 0.6, 0.6), HORIZONTAL_ALIGNMENT_CENTER, 180 * k)


func _draw_reticle(c: Vector2, k: float) -> void:
	var state := player.state
	if player.weapon == "pistol" and player.is_melee() == false and not player.moves.fury_active:
		if player.ranged.ads > 0.5:
			_tex_centered(_t("reticle_dot"), c, 6 * k)
		else:
			_tex_centered(_t("reticle_cross"), c, (36 + player.ranged.spread * 12) * k, Color(1, 1, 1, 0.9))
	elif state in ["throw_aim", "curveball"]:
		_tex_centered(_t("reticle_throw"), c, 70 * k)
	else:
		_tex_centered(_t("reticle_dot"), c, 7 * k, Color(1, 1, 1, 0.85))
	if player.hitmarker > 0.0:
		_tex_centered(_t("hitmarker"), c, 34 * k * (1.0 + (0.18 - player.hitmarker)), Color(1, 1, 1, clampf(player.hitmarker * 6.0, 0.0, 1.0)))
	if player.hitmarker_kill > 0.0:
		_tex_centered(_t("hitmarker_kill"), c, 44 * k, Color(1, 1, 1, clampf(player.hitmarker_kill * 4.0, 0.0, 1.0)))
	if player.state == "charge":
		var f: float = player.melee.charge
		draw_arc(c, 26 * k, -PI / 2, -PI / 2 + TAU * f, 48, Color(1, 0.55, 0.15) if f < 1.0 else Color(1, 0.2, 0.1), 3 * k)


func _draw_enemy_slates(k: float) -> void:
	var cam := player.camera
	for z: Zombie in get_tree().get_nodes_in_group("zombies"):
		if z.dead or not is_instance_valid(z.skeleton):
			continue
		var d := z.global_position.distance_to(player.global_position)
		if d > 16.0:
			continue
		var head_i := z.skeleton.find_bone("head")
		var top := z.global_position + Vector3.UP * 2.05 * z.body_scale
		if head_i >= 0:
			top = z.skeleton.global_transform * z.skeleton.get_bone_global_pose(head_i).origin + Vector3.UP * 0.38
		if cam.is_position_behind(top):
			continue
		var hp := z.gore.get_health() / maxf(1.0, z.gore.get_max_health())
		var stab := z.gore.get_stability()
		if hp >= 0.999 and stab >= 0.999 and d > 6.0:
			continue
		var sp := cam.unproject_position(top)
		var s := clampf(1.4 - d * 0.05, 0.65, 1.2) * k
		var w := 150.0 * s
		_bar(_t("T_HUD_Health_EnemyHealthBar"), Rect2(sp - Vector2(w * 0.5, 0), Vector2(w, 10 * s)), hp, Color(1, 1, 1), Color(0.1, 0.1, 0.1, 0.7))
		_bar(_t("T_HUD_Health_EnemyStaminaBar"), Rect2(sp + Vector2(-w * 0.5, 13 * s), Vector2(w, 5 * s)), stab, Color(1, 1, 1, 0.95), Color(0.1, 0.1, 0.1, 0.6))
		var rank := _t("T_Icon_EnemyNameSlate_Rank_Common")
		if rank:
			draw_texture_rect(rank, Rect2(sp + Vector2(-w * 0.5 - 34 * s, -12 * s), Vector2(30, 30) * s), false)
		_text(title_font, sp + Vector2(-w * 0.5 - 29 * s, 10 * s), str(z.level), int(20 * s), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, 20 * s, 3)
		var st: Dictionary = z.gore.status_states()
		var ix := 0.0
		for sname: String in ["burning", "electrified", "caustic"]:
			if st.get(sname, 0.0) > 0.0:
				var tn: String = {"burning": "T_ElementalDamageType_Fire_D", "electrified": "T_ElementalDamageType_Shock_D", "caustic": "T_ElementalDamageType_Acid_D"}[sname]
				_tex_centered(_t(tn), sp + Vector2(-w * 0.5 + 10 * s + ix, -14 * s), 18 * s)
				ix += 22 * s


func _draw_popups(k: float) -> void:
	var cam := player.camera
	for pp: Dictionary in player.popups:
		var pos: Vector3 = pp["pos"] + Vector3.UP * (0.25 + pp["t"] * 0.45)
		if cam.is_position_behind(pos):
			continue
		var sp := cam.unproject_position(pos)
		var t: float = pp["t"]
		# DI2 popup: pops in large, settles, fades out.
		var pop := 1.0 + 0.6 * maxf(0.0, 1.0 - t / 0.12)
		var a := clampf(1.0 - (t - 0.6) / 0.6, 0.0, 1.0)
		var kind: String = pp["kind"]
		var col: Color = {"crit": Color(1, 0.85, 0.15), "heavy": Color(1, 0.6, 0.25), "maimed": Color(1, 0.3, 0.2), "blocked": Color(0.8, 0.8, 0.8),
			"vulnerable": Color(1, 0.95, 0.4), "perk": Color(0.5, 1, 0.5)}.get(kind, Color.WHITE)
		col.a = a
		var size := int((44 if kind == "crit" else (30 if kind in ["maimed", "blocked", "vulnerable", "perk"] else 36)) * k * pop)
		_text(title_font, sp - Vector2(150 * k, 0), pp["text"], size, col, HORIZONTAL_ALIGNMENT_CENTER, 300 * k, int(6 * k))


func _draw_progression(vs: Vector2, k: float) -> void:
	if progression == null:
		return
	var w := 520 * k
	var x := (vs.x - w) * 0.5
	var y := vs.y - 26 * k
	draw_rect(Rect2(Vector2(x, y), Vector2(w, 6 * k)), Color(0, 0, 0, 0.55))
	draw_rect(Rect2(Vector2(x, y), Vector2(w * progression.fraction(), 6 * k)), Color(0.95, 0.85, 0.45))
	_text(title_font, Vector2(x - 70 * k, y + 10 * k), "LV %d" % progression.level, int(24 * k), Color.WHITE)
	if progression.gain_t > 0.0:
		_text(text_font, Vector2(x + w + 12 * k, y + 8 * k), "+%d XP" % progression.last_gain, int(20 * k), Color(0.95, 0.85, 0.45, minf(1.0, progression.gain_t)))
	if progression.level_up_t > 0.0:
		var a := minf(1.0, progression.level_up_t)
		var ink := _t("T_HUD_CenteralNotifications_BG_Ink")
		var r := Rect2(Vector2(vs.x * 0.5 - 360 * k, 120 * k), Vector2(720 * k, 150 * k))
		if ink:
			draw_texture_rect(ink, r, false, Color(1, 1, 1, a))
		_text(title_font, Vector2(0, 200 * k), "LEVEL UP", int(70 * k), Color(1, 0.9, 0.5, a), HORIZONTAL_ALIGNMENT_CENTER, vs.x)
		_text(text_font, Vector2(0, 240 * k), "Level %d  -  health, stamina and weapon damage increased" % progression.level, int(22 * k), Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_CENTER, vs.x)


func _draw_hint(c: Vector2, k: float) -> void:
	if player.hint_t <= 0.0:
		return
	var bg := _t("T_HUD_HintPopUp")
	var r := Rect2(Vector2(c.x - 230 * k, c.y + 120 * k), Vector2(460 * k, 44 * k))
	if bg:
		draw_texture_rect(bg, r, false, Color(1, 1, 1, 0.92))
	_text(text_font, r.position + Vector2(0, 30 * k), player.hint, int(22 * k), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, 0)
	if player.state == "grapple":
		var outer := _t("T_Icon_Minigame_OuterRing")
		var inner := _t("T_Icon_Minigame_InnerRing")
		var rc := c + Vector2(0, 40 * k)
		if outer:
			_tex_centered(outer, rc, 140 * k, Color(1, 1, 1, 0.9))
		if inner:
			_tex_centered(inner, rc, 140 * k * maxf(0.15, player.moves.grapple_bar), Color(1, 0.3, 0.2, 0.95))
		draw_arc(rc, 74 * k, -PI / 2, -PI / 2 + TAU * player.moves.grapple_bar, 48, Color(1, 1, 1), 5 * k)


func _draw_hurt(c: Vector2, vs: Vector2, k: float) -> void:
	if player.hurt_flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, vs), Color(0.6, 0.0, 0.0, player.hurt_flash * 0.45))
	if player.hurt_dir_t > 0.0:
		var a := -player.hurt_dir + PI
		draw_arc(c, 230 * k, a - 0.35, a + 0.35, 24, Color(0.9, 0.1, 0.05, minf(1.0, player.hurt_dir_t)), 10 * k)


func _draw_debug(k: float) -> void:
	var y := 30.0 * k
	_text(text_font, Vector2(24 * k, y), "FPS %d   time x%.2f   zombies %d   state %s" % [Engine.get_frames_per_second(), Main.time_scale, get_tree().get_nodes_in_group("zombies").size(), player.state], int(16 * k), Color(0.8, 1, 0.8), HORIZONTAL_ALIGNMENT_LEFT, -1, 3)
	var aim := player.aim_info(40.0)
	if aim.is_empty():
		return
	var z: Zombie = aim["zombie"]
	y += 24 * k
	_text(text_font, Vector2(24 * k, y), "%s lv%d  hp %d/%d  stability %d%%  %s  aiming at %s" % [z.archetype, z.level, roundi(z.gore.get_health()), roundi(z.gore.get_max_health()), roundi(z.gore.get_stability() * 100), "DOWN" if z.is_down() else ("CRAWLER" if z.gore.is_crawling() else ""), aim["bone"]], int(18 * k), Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, -1, 3)
	var parts: Dictionary = z.gore.part_states()
	for key in parts:
		y += 20 * k
		var st: Dictionary = parts[key]
		var col := Color(0.6, 1, 0.6) if st["state"] == "intact" else (Color(1, 0.8, 0.3) if st["state"] == "broken" else Color(1, 0.35, 0.3))
		_text(text_font, Vector2(36 * k, y), "%-12s %5.1f / %5.1f  %s" % [key, maxf(0.0, st["health"]), st["max"], st["state"]], int(16 * k), col, HORIZONTAL_ALIGNMENT_LEFT, -1, 3)


func _draw_help(vs: Vector2, k: float) -> void:
	var lines := [
		"LMB attack (hold: charged heavy, + W: lunge)   RMB block (tap before a hit: perfect block -> LMB counter)",
		"F kick (stomps downed / crawling zombies)   Shift+F drop kick   LMB in the air: ground pound   Alt/C dodge",
		"G hold+release: throw weapon (E pick up)   Q curveball (Tab cycle)   V Fury   H medkit   M weapon mod   T repair",
		"1 bat  2 machete  3 pistol (RMB aim, R reload)   K spawn  J archetype  Z slow-mo  F2 debug  F1 hide help",
	]
	var y := 60.0 * k
	for l in lines:
		_text(text_font, Vector2(0, y), l, int(16 * k), Color(1, 1, 1, 0.75), HORIZONTAL_ALIGNMENT_CENTER, vs.x, 3)
		y += 22 * k
