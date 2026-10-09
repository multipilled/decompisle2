class_name ZombieAnim
extends Node
## DI2 zombie animation on DI2Anim (recon/ANIMATION.md), after ABP_ZombieWalker (the zombie bodies' AnimClass):
##   * DINPCAnimInstance sets RootMotionMode RootMotionFromEverything (InternalConstructor 0x141bcb350 ->
##     SetRootMotionMode(2) 0x143468f00): DI2 moves zombies by the locomotion's and the montages' root motion.
##     zombie.gd moves standing zombies by root_motion() (locomotion + attack / AI montages, _rm_flag); reaction
##     montages carry their own root motion (zombie_reactions.gd);
##   * base layer = the Base_Locomotion / Crawler_Locomotion state machines: Idle plays the idle sequence, Move the
##     family's RunCombatFwd blend space (DA_AnimSetCollection_<Family>_Locomotion) sampled at the commanded speed
##     in cm/s like AnimState_Move.SpeedTarget, along its forward (Angle 0) samples since the port's zombies walk
##     straight at their target; transitions use DI2's CrossfadeDuration + BlendMode (data/anim_graphs.json);
##   * one-shots (attacks, reactions, falls, get-ups, paired) play as DI2's own montages (data/montages_zombie.json)
##     with their BlendIn / BlendOut, so a new hit crossfades even into the same clip.
##   * the face: DI2's facial sub-graph (FaceLayer below) over the 141 bones under `face`.
## The AnimationPlayer stays as the clip library; it is never advanced (manual mode). Its current_animation is
## kept on the dominant clip for logs, and a test that pauses it (z.anim.pause()) freezes this too.

const STATE_MACHINES := {false: "Base_Locomotion", true: "Crawler_Locomotion"}
## RunCombatFwd per family (DA_AnimSetCollection_<Family>_Locomotion; the Shambler body plays the Walker set with
## its LeftLeg personality, whose walk sequences are the ones in shambler.glb).
const MOVE_BS := {"walker": "BS_ZMB_Walker_Walk_F", "thug": "BS_ZMB_Thug_Walk",
	"shambler": "BS_ZMB_Shambler_Personality_LeftLeg_Walk_FB", "runner": "BS_ZMB_Runner_Run",
	"screamer": "BS_ZMB_Screamer_Walk", "slobber": "BS_ZMB_Slobber_Walk_Fwd", "suicider": "BS_ZMB_Suicider_Walk",
	"butcher": "BS_ZMB_Butcher_Combat_Walk"}
const CRAWL_BS := "BS_ZMB_Base_Crawler_Walk"
## Idle state: the Calm / Alert / Combat idle sets are chosen inside the state by BlendListByEnum on
## InternalCombatState, BlendTime 0.3 s, Linear (ABP_ZombieWalker AnimGraphNode_BlendListByEnum / _1).
const IDLE_SET_SWITCH := [0.3, "Linear"]
## Standing <-> crawler machine switch: the graph's BlendListByBool on bIsCrawler (0.3 s, Linear; recon/ANIMATION.md
## notes the node mapping as UNVERIFIED).
const CRAWLER_SWITCH := [0.3, "Linear"]

static var zdata := {}
static var clip_libs := {}   # body -> {"x:<DI2 sequence>": Animation} from game/assets/di2/zombie_clips/<body>_*.glb
var z: Zombie
var a: DI2Anim
var face: FaceLayer
var _pending := {}   # attack montage waiting for its wind-up: {name, d, rate, t, windup: Montage (null: locomotion layer)}
var windup_layer: WindUpLayer
var body := "walker"
var _logged := ""


func _init(owner: Zombie) -> void:
	z = owner
	body = owner.body
	process_physics_priority = -1   # before Zombie._physics_process (see _physics_process)
	if zdata.is_empty():
		zdata = Util.load_json("res://data/montages_zombie.json")


func _ready() -> void:
	a = DI2Anim.new(z.skeleton, z.anim)
	z.anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	# DI2 sequences the body glb lacks (attack lead-ins ...): tools/build_zombie_clips.py, montage segments "x:<seq>".
	if not clip_libs.has(body):
		var lib := {}
		var dir := "res://assets/di2/zombie_clips"
		for f in DirAccess.get_files_at(dir):
			if f.begins_with(body + "_") and f.ends_with(".glb"):
				var clips: Dictionary = FaceLayer._load_lib(dir.path_join(f))
				for n: String in clips:
					lib["x:" + n] = clips[n]
		clip_libs[body] = lib
	for n: String in clip_libs[body]:
		a.extra[n] = clip_libs[body][n]
	_load_root_tracks(body)
	var idle := "idle_calm" if a.has_clip("idle_calm") else "idle"
	var len := a.clip_len(idle)
	a.set_state("Idle:stand:" + idle, DI2Anim.Seq.new(idle, len, true, 1.0, randf() * len), 0.0, "Linear")
	_log_clip(idle)
	windup_layer = WindUpLayer.new(self)
	a.post_layers.append(windup_layer)   # the locomotion-layer wind-up sits under the face's LayeredBoneBlend
	face = FaceLayer.new(a, body)
	if face.ok:
		a.post_layers.append(face)
	# ABP_ZombieWalker "LayeredHitReactions": Slot LHR_UpperBody under LayeredBoneBlend_3 (branch spine_01, depth 0),
	# then Slot LHR_FullBody over the whole body (SKEL_ZombieStandard slot group LayeredHitReactions).
	var upper := PackedByteArray()
	upper.resize(a.nb)
	var sp := z.skeleton.find_bone("spine_01")
	for b in a.nb:
		upper[b] = 1 if sp >= 0 and (b == sp or Util.is_descendant_bone(z.skeleton, b, sp)) else 0
	var full := PackedByteArray()
	full.resize(a.nb)
	full.fill(1)
	a.layer_masks = {"LHR_UpperBody": upper, "LHR_FullBody": full}


func _process(delta: float) -> void:
	if not rm_locomotion:
		_tick(delta)


## With rm_locomotion the pose ticks in physics, before the Zombie's _physics_process (process_physics_priority -1)
## consumes its root motion in the same frame, as UE's CharacterMovementComponent ticks the pose (TickCharacterPose)
## and moves by its root motion in one step. Consumed a frame later, the capsule trails the drawn pose and the planted
## foot slips whenever the gait's root speed changes.
func _physics_process(delta: float) -> void:
	if rm_locomotion:
		_tick(delta)


func _tick(delta: float) -> void:
	if z.dead and not (z.reactions and z.reactions.dying):
		return
	if not z.anim.is_playing() and not z.dead:
		return   # paused by a test (autotest_flesh freezes the pose with z.anim.pause())
	if face and face.ok:
		# BP_Action_Grapple_Master_AI / BP_Action_Counter_Master_AI disable DA_AnimLayerGroup_NPC_CoopAction (holds
		# NPCFacial) while active: the paired grapple / counter clips' own face shows. The weight blends with the
		# component's DefaultDisable / DefaultEnable providers (UAnimationLayerComponent ctor 0x140c94c00: desired
		# 0.0 / 1.0, TransitionTime 0.33 s, linear: ULinearBlendLayerWeightProvider update 0x140c93e50).
		face.facial_target = 0.0 if z.reactions and z.reactions.state == "paired" else 1.0
		face.advance(delta)
	_attack_after_windup(delta)
	_wu_tick(delta)
	_rm_tick(delta)
	_rm_flag()
	_rm_before = _rm_sources()
	a.update(delta)
	_ff_scan(delta)
	_rm_accumulate()
	_log_clip(cur_clip())


func _log_clip(c: String) -> void:
	if c != _logged and c != "" and z.anim.has_animation(c):
		_logged = c
		z.anim.play(c)   # manual mode: only records the name; DI2Anim drives the pose


## The clip in front (the montage over the base state).
func cur_clip() -> String:
	var m := a.active()
	if m:
		return m.current_clip()
	var src = a.state_src()
	if src is DI2Anim.Seq:
		return src.clip
	if src is DI2Anim.BS and not src.samples.is_empty():
		var best := 0
		for i in src.weights.size():
			if src.weights[i] > src.weights[best]:
				best = i
		return src.samples[best][0]
	return ""


# --- montages ------------------------------------------------------------------------------------------------

## The DI2 montage for this body that plays `clip` ({} if none): {name, d} with this body's segment clip names.
func montage_for(clip: String) -> Dictionary:
	var mn: String = zdata.get("by_clip", {}).get(body, {}).get(clip, "")
	if mn == "" and zdata.get("montages", {}).has(clip):
		mn = clip   # a montage name (zombie_ai.gd attacks whose segments are the attacks2 "x:<seq>" clips)
	if mn != "":
		var md: Dictionary = zdata["montages"][mn]
		var segs: Array = md["segments"].get(body, [])
		if not segs.is_empty() and segs.all(func(s): return a.has_clip(s[0])):
			var d := md.duplicate()
			d["segments"] = segs
			return {"name": mn, "d": d}
	return {}


## Plays `clip` as DI2 does: its montage (BlendIn / BlendOut / sections / segments, an attack with its IntoStatic
## lead-in segments) when the body can play it whole; a clip DI2 only plays inside a montage the body can't play
## whole plays alone with that montage's BlendIn / BlendOut; else DI2's montage default (0.1 s HermiteCubic).
## `blend_in` < 0 keeps DI2's value. An attack montage DI2's regular attack sequence pairs with a FixedWindUpMontage
## (montages_zombie.json windup, from DA_AttackDef_*) plays that wind-up first; the attack follows after the wind-up
## Duration (_attack_after_windup). Returns the montage started now.
func play(clip: String, rate := 1.0, blend_in := -1.0) -> DI2Anim.Montage:
	if not a.has_clip(clip) and montage_for(clip).is_empty():
		return null
	if not _pending.is_empty() and _pending["windup"] == null:
		wu_end()   # a new montage interrupts the melee action's wind-up (UNVERIFIED: ramp-down vs instant reset)
	_pending = {}
	var m := montage_for(clip)
	var d: Dictionary
	var name := ""
	if not m.is_empty():
		d = m["d"]
		name = m["name"]
		var wu: Array = zdata.get("windup", {}).get(name, ["", 0.0, ""])
		if str(wu[0]) == "" and wu.size() > 2 and str(wu[2]) != "" and float(wu[1]) > 0.0 and blend_in < 0.0:
			# No FixedWindUpMontage: AIMeleeSubAction_VariableWindUp's begin (0x1410bad60) starts the locomotion-layer
			# wind-up (AnimInterest_Melee, FUN_141101e90) with WindUps[i].Duration; the attack montage follows once
			# the sub-action's progress (rate 1 / Duration, +0xf4) completes (recon/ANIMATION.md 11).
			wu_begin(str(wu[2]), float(wu[1]))
			_pending = {"name": name, "d": d, "rate": rate, "t": float(wu[1]), "windup": null}
			return null
		if str(wu[0]) != "" and blend_in < 0.0:
			var wd := _whole(str(wu[0]))
			if not wd.is_empty():
				# The wind-up holds its last frame if Duration outlasts it (AIMeleeSubAction_FixedWindUp is native:
				# hold vs. stretch is UNVERIFIED, recon/ANIMATION.md 9).
				wd["auto_blend_out"] = false
				var wm := a.play_data(str(wu[0]), wd, rate)
				_pending = {"name": name, "d": d, "rate": rate, "t": float(wu[1]), "windup": wm}
				return wm
	else:
		var length := a.clip_len(clip)
		d = {"length": length, "blend_in": [0.1, "HermiteCubic"], "blend_out": [0.1, "HermiteCubic"],
			"blend_out_trigger": -1.0, "auto_blend_out": true, "sections": [["Default", 0.0, null]],
			"segments": [[clip, 0.0, 0.0, length, 1.0, 1]], "rate": []}
		var bn: String = zdata.get("blend_by_clip", {}).get(body, {}).get(clip, "")
		if bn != "":
			var bd: Dictionary = zdata["montages"][bn]
			d["blend_in"] = bd["blend_in"]
			d["blend_out"] = bd["blend_out"]
		name = "clip:" + clip
	if blend_in >= 0.0:
		d = d.duplicate()
		d["blend_in"] = [blend_in, d["blend_in"][1]]
	return a.play_data(name, d, rate)


## Montage `mn`'s data with this body's segments, {} unless the body has every segment's clip.
func _whole(mn: String) -> Dictionary:
	var md: Dictionary = zdata.get("montages", {}).get(mn, {})
	var segs: Array = md.get("segments", {}).get(body, [])
	if segs.is_empty() or not segs.all(func(sg): return a.has_clip(sg[0])):
		return {}
	var d := md.duplicate()
	d["segments"] = segs
	return d


## DI2's melee action starts the attack montage once the wind-up Duration has passed (DA_AttackDef WindUps[].Duration)
## - unless something else took the slot (a hit reaction cancels the attack).
func _attack_after_windup(delta: float) -> void:
	if _pending.is_empty():
		return
	var wm: DI2Anim.Montage = _pending["windup"]
	if wm == null:
		if a.active() != null:   # a reaction montage took the DefaultGroup: the melee action is interrupted
			_pending = {}
			wu_end()
			return
	elif wm.stopped or a.active() != wm:
		_pending = {}
		return
	_pending["t"] = float(_pending["t"]) - delta
	if float(_pending["t"]) <= 0.0:
		var pd := _pending
		_pending = {}
		a.play_data(pd["name"], pd["d"], pd["rate"])
		if wm == null:
			# The wind-up sub-action ends as the attack starts (its end 0x1410af640 -> FUN_141103730: ramp down at
			# the same rate; the instant reset FUN_141104140 is its other branch - which flag the attack passes is
			# UNVERIFIED).
			wu_end()


# --- forward-foot tracker (DINPCAnimInstance +0x1100; recon/ANIMATION.md 12) -------------------------------------
var ff_foot := 0          # +0x11 EFoot of the last AnimNotify_ForwardFoot (0 BlendLeftFoot, 1 BlendRightFoot; ctor 0)
var ff_time := -1.0       # +0x14 world time it fired (ctor -1)
var ff_rate := -1.0       # +0x18 1 / anim seconds to the clip's next opposite-foot notify (ctor -1)
var _ff_prev := {}        # base-layer source instance id -> {clip: anim time last tick}
static var seq_of := {}   # body -> {port clip: DI2 sequence}


func _seq(clip: String) -> String:
	if clip.begins_with("x:"):
		return clip.substr(2)
	if not seq_of.has(body):
		var m := {}
		var clips: Dictionary = Util.load_json("res://assets/di2/%s/clips.json" % body)
		for g: String in clips:
			if clips[g] is String:
				m[g.trim_prefix("inplace:")] = clips[g]
		seq_of[body] = m
	return str(seq_of[body].get(clip, ""))


## Fires the AnimNotify_ForwardFoot notifies the base layer's players crossed this tick: UAnimNotify_ForwardFoot::Notify
## (vtable 0x1450f5248 slot 72, FUN_141110b00) -> FUN_141111e50 records the foot, the world time and 1 / the anim time
## to the clip's next opposite-foot notify (wrapping by the play length; the play length when there is none; 0.3 when
## that is 0). Every player with weight fires, oldest state first (UE notify queue order across states UNVERIFIED).
func _ff_scan(dt: float) -> void:
	var ffd: Dictionary = zdata.get("forward_foot", {})
	var seen := {}
	for e: Dictionary in a.states:
		var src = e["src"]
		var cur := {}
		if src is DI2Anim.Seq:
			cur[src.clip] = [src.time, src.length, dt * src.rate]
		elif src is DI2Anim.BS:
			for i in src.samples.size():
				if i < src.weights.size() and src.weights[i] > 1e-5:
					var l: float = src.samples[i][4]
					cur[src.samples[i][0]] = [src.sample_time(i), l, dt * (l / src.length_now() if src.unsynced and src.length_now() > 0.0 else float(src.samples[i][3]))]
		var key: int = src.get_instance_id()
		var prev: Dictionary = _ff_prev.get(key, {})
		for c: String in cur:
			var nf: Array = ffd.get(_seq(c), [])
			if nf.is_empty():
				continue
			var t1: float = cur[c][0]
			var t0: float = prev[c] if prev.has(c) else maxf(t1 - float(cur[c][2]), 0.0)
			var feet: Array = nf[1]
			for k in feet.size():
				var tn: float = feet[k][0]
				var hit := (tn > t0 and tn <= t1) if t1 >= t0 else (tn > t0 or tn <= t1)
				if hit:
					_ff_fire(feet, k, float(nf[0]))
		var keep := {}
		for c: String in cur:
			keep[c] = cur[c][0]
		seen[key] = keep
	_ff_prev = seen


func _ff_fire(feet: Array, k: int, length: float) -> void:
	var foot: int = feet[k][1]
	ff_foot = foot
	ff_time = _clock
	var j := (k + 1) % feet.size()
	while j != k and int(feet[j][1]) == foot:
		j = (j + 1) % feet.size()
	var d := float(feet[j][0]) - float(feet[k][0])
	if d <= 0.0:
		d += length
		if d == 0.0:
			ff_rate = 0.3
			return
	ff_rate = 1.0 / d


## FUN_1411088d0: the Move blend space's start time from the tracker. The heaviest sample at the entry input (the first
## of equals); its first ForwardFoot notify of the tracked foot (t1) and the next ForwardFoot notify after it (t2):
## t1 + (t2 - t1) * (now - ff_time) * ff_rate (the fraction only once a foot has fired), t1 without a t2, 0 without t1.
## In seconds of that sequence.
func _ff_start_position(src: DI2Anim.BS) -> float:
	var tg := src.targets()
	var lead := 0
	for i in tg.size():
		if tg[i] > tg[lead]:
			lead = i
	var nf: Array = zdata.get("forward_foot", {}).get(_seq(str(src.samples[lead][0])), [])
	if nf.is_empty():
		return 0.0
	var feet: Array = nf[1]
	var first := -1
	for k in feet.size():
		if first < 0:
			if int(feet[k][1]) == ff_foot:
				first = k
		else:
			var f := (_clock - ff_time) * ff_rate if ff_time >= 0.0 else 0.0
			return float(feet[first][0]) + (float(feet[k][0]) - float(feet[first][0])) * f
	return float(feet[first][0]) if first >= 0 else 0.0


# --- attack wind-up: AnimInterest_Melee (DINPCAnimInstance +0x1510; recon/ANIMATION.md 11) ---------------------------
var wu_amount := 0.0      # AttackWindUpAmount (+0x10)
var wu_state := 4         # +0x30: 0 begun, 1 ramping up, 2 ramping down, 3 held at 1, 4 inactive
var wu_rate := 0.0        # +0x2c: 1 / WindUps[i].Duration
var wu_chosen := ""       # ChosenWindUpDefinition (+0x38)
var wu_last := ""         # LastWindUpDefinition (+0x18): NativeUpdate FUN_141112af0 copies Chosen when set


## FUN_141101e90: (re)start the wind-up with `def` (a DA_WindUpDef_*) over `duration` seconds.
func wu_begin(def: String, duration: float) -> void:
	if wu_state != 4:
		wu_amount = 0.0
	wu_chosen = def
	wu_state = 0
	wu_rate = 1.0 / (duration if duration > 0.0 else 1.0)


## FUN_141103730: ramp the amount back down (an inactive or already falling wind-up is left alone).
func wu_end() -> void:
	if wu_state == 2 or wu_state == 4:
		return
	if wu_amount == 0.0:
		wu_state = 4
		wu_chosen = ""
		return
	wu_state = 2


## FUN_141118680 (vtable slot 3, ticked from FUN_14110e8d0 before the state machine): begun -> ramping (no step
## on that tick), amount += dt * rate up to 1 (held), or -= on the way down to 0 (then Chosen is cleared).
func _wu_tick(dt: float) -> void:
	match wu_state:
		0:
			wu_state = 1
		1:
			if wu_amount < 1.0:
				wu_amount = clampf(dt * wu_rate + wu_amount, 0.0, 1.0)
				if wu_amount == 1.0:
					wu_state = 3
		2:
			wu_amount = clampf(wu_amount - dt * wu_rate, 0.0, 1.0)
			if wu_amount == 0.0:
				wu_state = 4
				wu_chosen = ""
	if wu_chosen != "":
		wu_last = wu_chosen


## Plays DI2 montage `am` (data/montages_zombie.json, this body's segment clips) in its own slot: DefaultSlot /
## Ragdoll in the DefaultGroup, LHR_UpperBody / LHR_FullBody as layered slots in the LayeredHitReactions group
## (SKEL_ZombieStandard SlotGroups), so a layered flinch doesn't stop the full-body montage and vice versa.
## null when the body lacks one of its sequences (hit_reacts.json clips_missing): no stand-in clip is played.
func play_montage(am: String, rate := 1.0) -> DI2Anim.Montage:
	var md: Dictionary = zdata.get("montages", {}).get(am, {})
	if md.is_empty():
		return null
	var segs: Array = md["segments"].get(body, [])
	if segs.is_empty() or not segs.all(func(s): return a.has_clip(s[0])):
		return null
	var d := md.duplicate()
	d["segments"] = segs
	var slot_name := str(md.get("slot", "DefaultSlot"))
	if a.layer_masks.has(slot_name):
		d["group"] = "LayeredHitReactions"
		d["layer"] = slot_name
	return a.play_data(am, d, rate)


## Montage `am`'s notifies ([name, time, duration], montage time), [] if none.
func notifies(am: String) -> Array:
	return zdata.get("montages", {}).get(am, {}).get("notifies", [])


func stop() -> void:
	a.stop_montages(0.0)


# --- locomotion (base layer) --------------------------------------------------------------------------------

## The port's brain state -> DI2 base-layer state; `speed` in m/s (the commanded speed = SpeedTarget).
## With rm_locomotion (standing bodies with DI2's Start / Stop / TurnOnSpot sets) the base layer runs DI2's
## root-motion locomotion instead (_drive_rm): `want` = the world direction to move / face (zero = keep facing),
## `dest` = DistanceToFinalDestination in m.
func drive(state: String, speed: float, crawling: bool, want := Vector3.ZERO, dest := INF) -> void:
	if rm_locomotion and not crawling and LOCO_SETS.has(body):
		_drive_rm(state, speed, want, dest)
		return
	var st := ""
	var clip := ""
	match state:
		"Idle":
			st = "Idle"
			clip = "idle"
		"Alert":
			st = "Idle"
			clip = "alert"
		"Chase", "Walk", "Crawl":
			st = "Move"
		"CrawlIdle":
			st = "Idle"
			clip = "crawl_idle"
		_:
			return
	if face:
		# ECosmeticCombatState for the facial machine (Combat = 2). The port's brain states stand in for DI2's
		# combat state: Idle / CrawlIdle = Calm, Alert = Alert, moving at the target = Combat (UNVERIFIED mapping).
		face.combat_state = 0 if state in ["Idle", "CrawlIdle"] else (1 if state == "Alert" else 2)
	var key := "%s:%s:%s" % [st, "crawl" if crawling else "stand", clip]
	if a.state_key() == key:
		var src = a.state_src()
		if src is DI2Anim.BS:
			src.x = speed * 100.0
		return
	var src = null
	if st == "Move":
		src = _move_source(crawling, speed)
	elif a.has_clip(clip):
		src = DI2Anim.Seq.new(clip, a.clip_len(clip), clip != "alert")
	if src == null:
		return
	var prev := a.state_key()
	var tr := _transition(prev, st, crawling)
	a.set_state(key, src, tr[0], tr[1])


func _transition(prev: String, to: String, crawling: bool) -> Array:
	if prev == "":
		return [0.0, "Linear"]
	var parts := prev.split(":")
	if (parts[1] == "crawl") != crawling:
		return CRAWLER_SWITCH
	if parts[0] == "Idle" and to == "Idle":
		return IDLE_SET_SWITCH
	var sm: Dictionary = DI2Anim.graphs.get("state_machines", {}).get("zombie_walker", {}).get(STATE_MACHINES[crawling], {})
	for t: Array in sm.get("transitions", []):
		if t[0] == parts[0] and t[1] == to:
			return [float(t[2]), str(t[3])]
	return [0.0, "Linear"]


## The Move state's pose: the forward (Angle 0) samples of the family's walk blend space where this body has their
## sequences, as a 1D blend space on Speed (cm/s) with the asset's TargetWeightInterpolationSpeedPerSec and sample
## RateScales. A body without those sequences (the Runner's glb holds Combat_Run_*_F, its BS_ZMB_Runner_Run uses
## Run_*_02) gets its own walk clips placed at their measured root speeds (recon/ANIMATION.md: approximation).
func _move_source(crawling: bool, speed: float):
	var bs_name: String = CRAWL_BS if crawling else MOVE_BS.get(body, "")
	var bs: Dictionary = DI2Anim.graphs.get("blend_spaces", {}).get(bs_name, {})
	var samples := []
	if not bs.is_empty():
		var clips: Array = _bs_clips(bs)
		for i in bs["samples"].size():
			var s: Array = bs["samples"][i]
			var c: String = clips[i] if i < clips.size() else ""
			if rm_locomotion and not crawling:
				c = drift_clip.get(body, {}).get(c, c)
			if absf(float(s[1])) < 1e-3 and c != "" and a.has_clip(c):
				samples.append([c, float(s[2]), 0.0, float(s[3])])
	var interp := float(bs.get("weight_speed", 0.0))
	if samples.size() < 2:
		samples = []
		for c: String in (Zombie.CRAWL_CLIPS if crawling else Zombie.WALK_CLIPS):
			var pc: String = drift_clip.get(body, {}).get(c, c) if rm_locomotion and not crawling else c
			if a.has_clip(pc):
				samples.append([pc, float(z.clip_speed.get(c, 0.0)) * 100.0, 0.0, 1.0])
	if samples.is_empty():
		return null
	var src := DI2Anim.BS.new(a, {"type": "BlendSpace1D", "weight_speed": interp, "samples": samples})
	src.x = speed * 100.0
	# The Move players are in sync group "Locomotion" (GroupIndex 4, CanBeLeader): their samples sync by marker.
	var sm: Dictionary = zdata.get("sync_markers", {})
	for s: Array in src.samples:
		src.markers.append(sm.get(_seq(str(s[0])), []))
	return src


# --- face ---------------------------------------------------------------------------------------------------------

## DI2's zombie face (recon/ANIMATION.md 7, data/zombie_facial.json from tools/build_zombie_facial.py):
##   ABP_ZombieWalker LayeredBoneBlend: the 141 bones under `face` (DI2's baked PerBoneBlendWeights) come from the
##   SubInstance ABP_ZombieWalkerFacial at weight Layer_Facial, in local space, after the body graph and montages;
##   ABP_ZombieWalkerFacial: a state machine WAIT (ref pose) -> Idle <-> Combat (InternalCombatState == Combat),
##   0.2 s HermiteCubic crossfades (bSkipFirstUpdateTransition: no transition on the first update). Each state is
##   LayeredBoneBlend(base = AnimSetSequencePlayer of Facial.Idle_Calm / Idle_Combat, blend = the MouthMovement
##   blend space, the face bones minus eye_r / eye_l, weight Layer_ProceduralMouth);
##   FAnimNode_AnimSetSequencePlayer::UpdateAssetPlayer (exe 0x141175170): a looping player whose sequence has less
##   than ResolveRemainingTime (0.1 s) left re-resolves its anim set (a new pick, AnimSetSelectionOrder_Random /
##   _Single) and restarts at StartPosition, without a crossfade;
##   layer weights: NPCFacial / NPCProceduralMouth BaseLayerWeightProvider = ULinearBlendLayerWeightProvider native
##   defaults (DesiredLayerWeight 1.0, TransitionTime 0.33 s; exe 0x140c94c90); the Dead group disables NPCFacial;
##   the mouth blend space BS_ZMB_Facial_<Family>_Additives (6 face poses on Horizontal x Vertical, weights moved at
##   TargetWeightInterpolationSpeedPerSec 7) is driven by UBreathingAudioComponent (exe 0x141173b30): Horizontal = 0
##   (only a debug sine CVar drives it), Vertical = -0.03589682 * 2^((RTPC_Zombie_Mouth_Volume dB + 48) / 10), the
##   zombie voice's Wwise meter level, remapped by the DA_BreathingAudioMouthDamLocWalker config (identity here).
##   The port has no zombie voice audio, so the level stays at the meter floor (-48 dB): Vertical -0.036.
class FaceLayer:
	static var data := {}
	static var libs := {}              # body -> {clip name: Animation} from <body>_facial.glb
	static var mouth_cache := {}       # body -> per mouth sample [pos per slot, rot per slot]
	var ok := false
	var a: DI2Anim
	var bones := PackedInt32Array()    # face slot -> skeleton bone
	var slot_of := PackedInt32Array()  # skeleton bone -> face slot (-1)
	var in_mouth := PackedByteArray()  # per slot: 1 = procedural-mouth mask, 0 = eye (idle sequence only)
	var rest_p := PackedVector3Array()
	var rest_r: Array[Quaternion] = []
	var w_facial := 1.0                # Layer_Facial
	var facial_target := 1.0
	var w_mouth := 1.0                 # Layer_ProceduralMouth
	var layer_rate := 1.0 / 0.33       # InverseTransitionTime
	var combat_state := 0              # ECosmeticCombatState: Calm 0, Alert 1, Combat 2
	var sets := {}                     # "Idle" / "Combat" -> {clips, order}
	var trans := {}                    # "From>To" -> [seconds, option]
	var player := {}
	var states: Array = []             # [{name, clip, time, len, alpha: DI2Anim.Blend}], oldest first
	var updates := 0
	var mouth_db := -48.0              # RTPC_Zombie_Mouth_Volume (no voice audio: the meter floor)
	var mouth_h := 0.0
	var bs: Dictionary
	var bs_w := PackedFloat32Array()
	var mouth_pose: Array = []
	var _mouth_dirty := true           # the blended mouth pose changes only with the blend-space weights
	var eye_slots := PackedInt32Array()
	var all_slots := PackedInt32Array()
	var cover_mask := PackedByteArray()  # skeleton bones this layer overwrites at full weight (DI2Anim.set_covered)
	var _tcache := {}                  # clip + mode -> [pos slots, pos tracks, rot slots, rot tracks]
	var _p := PackedVector3Array()
	var _r: Array[Quaternion] = []
	var _sp := PackedVector3Array()
	var _sr: Array[Quaternion] = []
	var _mp := PackedVector3Array()
	var _mr: Array[Quaternion] = []

	func _init(anim: DI2Anim, body: String) -> void:
		a = anim
		if data.is_empty():
			data = Util.load_json("res://data/zombie_facial.json")
		var bd: Dictionary = data.get("bodies", {}).get(body, {})
		if bd.is_empty():
			return
		if not libs.has(body):
			libs[body] = _load_lib(str(bd["glb"]))
		for n: String in libs[body]:
			a.extra["face:" + n] = libs[body][n]
		slot_of.resize(a.nb)
		slot_of.fill(-1)
		var mouth := {}
		for n: String in data["mouth_bones"]:
			mouth[n] = true
		for n: String in data["face_bones"]:
			if a.bone_of.has(n):
				var b: int = a.bone_of[n]
				slot_of[b] = bones.size()
				bones.append(b)
				in_mouth.append(1 if mouth.has(n) else 0)
				rest_p.append(a.rest_pos[b])
				rest_r.append(a.rest_rot[b])
		var nf := bones.size()
		cover_mask.resize(a.nb)
		cover_mask.fill(0)
		for b in bones:
			cover_mask[b] = 1
		for sl in nf:
			all_slots.append(sl)
			if in_mouth[sl] == 0:
				eye_slots.append(sl)
		_p.resize(nf)
		_sp.resize(nf)
		_mp.resize(nf)
		_r.resize(nf)
		_sr.resize(nf)
		_mr.resize(nf)
		var lw: Dictionary = data["layer_weight"]
		layer_rate = 1.0 / float(lw["transition"])
		w_facial = float(lw["desired"])
		facial_target = w_facial
		w_mouth = float(lw["desired"])
		sets = {"Idle": bd["Idle"], "Combat": bd["Combat"]}
		var sm: Dictionary = data["state_machine"]
		for t: Array in sm["transitions"]:
			trans["%s>%s" % [t[0], t[1]]] = [float(t[2]), str(t[3])]
		player = sm["player"]
		bs = data["blend_spaces"][bd["mouth_bs"]]
		if not mouth_cache.has(body):
			var poses := []
			for smp: Array in bs["samples"]:
				var pp := rest_p.duplicate()
				var rr: Array[Quaternion] = rest_r.duplicate()
				_sample("face:" + str(smp[0]), 0.0, pp, rr, false)
				poses.append([pp, rr])
			mouth_cache[body] = poses
		mouth_pose = mouth_cache[body]
		_set_state(str(sm["initial"]), 0.0, "Linear")
		bs_w = _bs_targets()
		ok = nf > 0 and not libs[body].is_empty()

	static func _load_lib(path: String) -> Dictionary:
		var out := {}
		var ps := load(path) as PackedScene
		if ps == null:
			push_warning("FaceLayer: no facial clips at " + path)
			return out
		var inst := ps.instantiate()
		var ap := Util.find_first(inst, "AnimationPlayer") as AnimationPlayer
		if ap:
			for n in ap.get_animation_list():
				out[str(n)] = ap.get_animation(n)
		inst.free()
		return out

	## Face-slot tracks of a clip: all face bones, or (eyes_only) the bones outside the mouth mask.
	func _ftracks(clip: String, eyes_only: bool) -> Array:
		var key := clip + ("|e" if eyes_only else "")
		if _tcache.has(key):
			return _tcache[key]
		var e := a._tracks(a.clip(clip))
		var out := [PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
		for k in [0, 2]:
			var tr: PackedInt32Array = e[k]
			var bn: PackedInt32Array = e[k + 1]
			for i in tr.size():
				var s := slot_of[bn[i]]
				if s >= 0 and (not eyes_only or in_mouth[s] == 0):
					out[k].append(s)
					out[k + 1].append(tr[i])
		_tcache[key] = out
		return out

	func _sample(clip: String, time: float, pp: PackedVector3Array, rr: Array[Quaternion], eyes_only: bool) -> void:
		if not a.has_clip(clip):
			return
		var anim := a.clip(clip)
		var f := _ftracks(clip, eyes_only)
		var ps: PackedInt32Array = f[0]
		var pt: PackedInt32Array = f[1]
		for i in ps.size():
			pp[ps[i]] = anim.position_track_interpolate(pt[i], time)
		var rs: PackedInt32Array = f[2]
		var rt: PackedInt32Array = f[3]
		for i in rs.size():
			rr[rs[i]] = anim.rotation_track_interpolate(rt[i], time)

	## AnimSetSequencePlayer resolve: a pick from the state's anim set, restarting at StartPosition.
	func _resolve(st: Dictionary) -> void:
		var clips: Array = sets.get(st["name"], {}).get("clips", [])
		st["clip"] = ""
		if clips.is_empty():
			return
		# AnimSetSelectionOrder_Random over items of weight 1.0: uniform, repeats allowed (UNVERIFIED).
		var c := "face:" + str(clips[randi() % clips.size()])
		if not a.has_clip(c):
			return
		st["clip"] = c
		st["len"] = a.clip_len(c)
		st["time"] = clampf(float(player["StartPosition"]), 0.0, st["len"])

	func _set_state(name: String, seconds: float, option: String) -> void:
		var st := {"name": name, "clip": "", "time": 0.0, "len": 0.0,
			"alpha": DI2Anim.Blend.new(0.0, 1.0, seconds if not states.is_empty() else 0.0, option)}
		if name != "WAIT":
			_resolve(st)
		states.append(st)

	func advance(dt: float) -> void:
		w_facial = move_toward(w_facial, facial_target, dt * layer_rate)
		a.set_covered(cover_mask if w_facial >= 1.0 - 1e-4 else PackedByteArray())
		updates += 1
		var cur: String = states[-1]["name"]
		var want := cur
		if updates > 1:   # bSkipFirstUpdateTransition
			if cur == "WAIT":
				want = "Idle"   # isReady: set on the first update that has the parent instance
			elif cur == "Idle" and combat_state == 2:
				want = "Combat"
			elif cur == "Combat" and combat_state != 2:
				want = "Idle"
		if want != cur:
			var t: Array = trans.get("%s>%s" % [cur, want], [0.2, "HermiteCubic"])
			_set_state(want, t[0], t[1])
		for st: Dictionary in states:
			st["alpha"].advance(dt)
			if st["clip"] != "":
				st["time"] += dt * float(player["PlayRate"])
				if bool(player["bLoopAnimation"]) and st["len"] - st["time"] < float(player["ResolveRemainingTime"]):
					_resolve(st)
		for i in range(states.size() - 1, 0, -1):
			if states[i]["alpha"].done():
				states = states.slice(i)
				break
		# Mouth blend space: per-sample weights towards the targets at TargetWeightInterpolationSpeedPerSec.
		var tg := _bs_targets()
		var old := bs_w.duplicate()
		var total := 0.0
		for i in bs_w.size():
			bs_w[i] = move_toward(bs_w[i], tg[i], float(bs["weight_speed"]) * dt)
			total += bs_w[i]
		if total > 1e-5:
			for i in bs_w.size():
				bs_w[i] /= total
		for i in bs_w.size():
			if absf(bs_w[i] - old[i]) > 1e-6:
				_mouth_dirty = true

	## UBreathingAudioComponent -> (Horizontal, Vertical) of the mouth blend space.
	func mouth_input() -> Vector2:
		var m: Dictionary = data["mouth"]
		var v := float(m["scale"]) * pow(2.0, (mouth_db - float(m["floor_db"])) * 0.1)
		var cfg: Dictionary = m["config"]
		var mn := clampf(float(cfg["min"]), 0.0, 1.0)
		var mx := 1.0
		if float(cfg["max"]) >= 0.0 and mn <= minf(float(cfg["max"]), 1.0):
			mx = minf(float(cfg["max"]), 1.0)
		var av := absf(v)
		var out := (av * (mx - mn) + mn) * signf(v) if not bool(cfg["clamp"]) else clampf(av, mn, mx) * signf(v)
		return Vector2(mouth_h, out)

	## Target sample weights: the samples sit on a Horizontal {-1, 0, 1} x Vertical {-1, 0} lattice, which UE's grid
	## (GridNum 2 x 4, the asset's GridSamples) interpolates bilinearly; Vertical above 0 repeats the 0 row.
	func _bs_targets() -> PackedFloat32Array:
		var t := PackedFloat32Array()
		t.resize(bs["samples"].size())
		var inp := mouth_input()
		var ax: Array = bs["axes"]
		var x := clampf(inp.x, float(ax[0][0]), float(ax[0][1]))
		var y := clampf(inp.y, float(ax[1][0]), 0.0)
		var x0 := minf(floorf(x), 0.0) if x < 1.0 else 0.0
		var fx := x - x0
		var y0 := -1.0
		var fy := y - y0
		for i in t.size():
			var s: Array = bs["samples"][i]
			var sx := float(s[1])
			var sy := float(s[2])
			var wx := (1.0 - fx) if is_equal_approx(sx, x0) else (fx if is_equal_approx(sx, x0 + 1.0) else 0.0)
			var wy := (1.0 - fy) if is_equal_approx(sy, y0) else (fy if is_equal_approx(sy, y0 + 1.0) else 0.0)
			t[i] = wx * wy
		return t

	static func _acc(p: PackedVector3Array, r: Array[Quaternion], s: int, pv: Vector3, rv: Quaternion, w: float) -> void:
		p[s] += pv * w
		if r[s].dot(rv) < 0.0:
			rv = -rv
		r[s] += rv * w

	static func _nlerp(q0: Quaternion, q1: Quaternion, w: float) -> Quaternion:
		if q0.dot(q1) < 0.0:
			q1 = -q1
		var q := q0 * (1.0 - w) + q1 * w
		return q.normalized() if q.length_squared() > 1e-12 else q0

	func apply(an: DI2Anim) -> void:
		if w_facial <= 1e-4:
			return
		var nf := bones.size()
		# Mouth pose: the blend-space samples are static two-frame poses, so it only changes with the weights.
		var mouth_changed := false
		if w_mouth > 1e-4 and _mouth_dirty:
			_mouth_dirty = false
			mouth_changed = true
			_mp.fill(Vector3.ZERO)
			for sl in nf:
				_mr[sl] = Quaternion(0, 0, 0, 0)
			for i in bs_w.size():
				if bs_w[i] > 1e-4:
					var mp: PackedVector3Array = mouth_pose[i][0]
					var mr: Array[Quaternion] = mouth_pose[i][1]
					for sl in nf:
						_acc(_mp, _mr, sl, mp[sl], mr[sl], bs_w[i])
			for sl in nf:
				_mr[sl] = _mr[sl].normalized() if _mr[sl].length_squared() > 1e-12 else rest_r[sl]
		# Facial state machine, the newest state over the older ones (standard blend). With the mouth layer at full
		# weight every state's mouth-mask bones are the mouth pose, so only the eyes need the states.
		var eyes_only := w_mouth >= 1.0 - 1e-4
		var slots := eye_slots if eyes_only else all_slots
		for sl in slots:
			_p[sl] = Vector3.ZERO
			_r[sl] = Quaternion(0, 0, 0, 0)
		var scale := 1.0
		for i in range(states.size() - 1, -1, -1):
			var st: Dictionary = states[i]
			var al: float = st["alpha"].value if i > 0 else 1.0
			var w := scale * al
			scale *= 1.0 - al
			if w > 1e-5:
				for sl in slots:
					_sp[sl] = rest_p[sl]
					_sr[sl] = rest_r[sl]
				if st["clip"] != "":
					_sample(st["clip"], st["time"], _sp, _sr, eyes_only)
				for sl in slots:
					var pv := _sp[sl]
					var rv := _sr[sl]
					if in_mouth[sl] == 1 and w_mouth > 1e-4:
						pv = pv.lerp(_mp[sl], w_mouth)
						rv = _nlerp(rv, _mr[sl], w_mouth)
					_acc(_p, _r, sl, pv, rv, w)
			if scale <= 1e-5:
				break
		var full := w_facial >= 1.0 - 1e-4
		# At full weight DI2Anim leaves the covered (face) bones alone, so only what changed needs writing: the
		# eyes every frame, the mouth-mask bones when the mouth pose changes or the cover was just set.
		var out_slots := all_slots
		if full and an.cover_on and eyes_only and not mouth_changed and not an.cover_fresh:
			out_slots = eye_slots
		an.cover_fresh = false
		for sl in out_slots:
			var b := bones[sl]
			var pv: Vector3
			var q: Quaternion
			if eyes_only and in_mouth[sl] == 1:
				pv = _mp[sl]
				q = _mr[sl]
			else:
				pv = _p[sl]
				q = _r[sl].normalized() if _r[sl].length_squared() > 1e-12 else rest_r[sl]
			if full:
				an.acc_pos[b] = pv
				an.acc_rot[b] = q
			else:
				an.acc_pos[b] = an.acc_pos[b].lerp(pv, w_facial)
				an.acc_rot[b] = _nlerp(an.acc_rot[b], q, w_facial)
		if an.cover_on:
			for sl in out_slots:
				an.cover_dirty.append(bones[sl])


# --- root motion (DINPCAnimInstance RootMotionMode = RootMotionFromEverything) ---------------------------------------

## DI2 moves zombies by their animation's root motion (recon/ANIMATION.md 3.6): every source of the base pose (and,
## with rm_montages, the montages) contributes its own root track's delta between this frame's clip times, weighted
## like its pose (FRootMotionMovementParams accumulate). Root tracks come from merge_anims / build_zombie_clips
## (<body>.anims.json and zombie_clips/<body>_*.anims.json: [x, y, z, yaw] per frame, skeleton space, relative to
## frame 0; yaw is UE yaw, positive = a right turn). root_motion() hands the accumulated motion to the mover.
static var root_tracks := {}       # body -> {clip: [frames, rate]}
var rm_montages := false           # every montage's root motion (off: _rm_flag picks the ones the capsule takes)
## Set by whoever moves the capsule by root_motion(): locomotion then plays the clips with their pelvis drift
## (merge_anims' "inplace:" variants strip it, which only suits a capsule moved at the brain's speed).
var rm_locomotion := false
static var drift_clip := {}        # body -> {inplace clip: the same DI2 sequence merged with its drift}
var rm_acc := Vector4.ZERO         # skeleton-space delta since the last root_motion(): x, y, z (m), turn (rad about +Y)
var _rm_before: Array = []


static func _load_root_tracks(body: String) -> Dictionary:
	if root_tracks.has(body):
		return root_tracks[body]
	var clips: Dictionary = Util.load_json("res://assets/di2/%s/clips.json" % body)
	var by_seq := {}
	for g: String in clips:
		if clips[g] is String and not g.begins_with("inplace:"):
			by_seq[clips[g]] = g
	var alt := {}
	for g: String in clips:
		if clips[g] is String and g.begins_with("inplace:") and by_seq.has(clips[g]):
			alt[g.trim_prefix("inplace:")] = by_seq[clips[g]]
	drift_clip[body] = alt
	var out := {}
	var rep: Dictionary = Util.load_json("res://assets/di2/%s/%s.anims.json" % [body, body])
	for c: String in rep:
		var r = rep[c].get("root")
		if r != null:
			out[c] = [r, float(rep[c].get("rate", 30.0))]
	var dir := "res://assets/di2/zombie_clips"
	for f in DirAccess.get_files_at(dir):
		if f.begins_with(body + "_") and f.ends_with(".anims.json"):
			var x: Dictionary = Util.load_json(dir.path_join(f))
			for s: String in x:
				if x[s].get("root") != null:
					out["x:" + s] = [x[s]["root"], float(x[s].get("rate", 30.0))]
	root_tracks[body] = out
	return out


## Root sample of `clip` at `t` (linear between frames), Vector4(x, y, z, yaw); zero when the clip has no motion.
func _root_at(clip: String, t: float) -> Vector4:
	var rt: Array = root_tracks.get(body, {}).get(clip, [])
	if rt.is_empty():
		return Vector4.ZERO
	var fr: Array = rt[0]
	var f := clampf(t * float(rt[1]), 0.0, float(fr.size() - 1))
	var i := mini(int(f), fr.size() - 2) if fr.size() > 1 else 0
	var u := f - i
	var p: Array = fr[i]
	var q: Array = fr[mini(i + 1, fr.size() - 1)]
	return Vector4(lerpf(p[0], q[0], u), lerpf(p[1], q[1], u), lerpf(p[2], q[2], u), lerpf(p[3], q[3], u))


## [key, clip, time, weight, loops] of everything posing the body this frame (base states; montages with rm_montages).
func _rm_sources() -> Array:
	var out := []
	var mw := a.montage_weight()
	var base_scale := 1.0 - minf(mw, 1.0)
	var scale := 1.0
	for i in range(a.states.size() - 1, -1, -1):
		var e: Dictionary = a.states[i]
		var al: float = e["alpha"].value if i > 0 else 1.0
		var w := base_scale * scale * al
		scale *= 1.0 - al
		var src = e["src"]
		if w > 1e-5:
			if src is DI2Anim.Seq:
				out.append([src.get_instance_id(), src.clip, src.time, w, src.loop])
			elif src is DI2Anim.BS:
				for k in src.samples.size():
					if src.weights[k] > 1e-4:
						out.append([src.get_instance_id() * 64 + k, src.samples[k][0], src.sample_time(k),
							w * src.weights[k], src.loop])
		if scale <= 1e-5:
			break
	var mon_scale := 1.0 / mw if mw > 1.0 else 1.0
	for m: DI2Anim.Montage in a.slot:
		if (rm_montages or not m.ref_root.is_empty()) and not m.additive and m.weight.value > 1e-4:
			var smp := m.sample(m.pos)
			out.append([m.get_instance_id(), smp[0], smp[1], m.weight.value * mon_scale, false, m, m.pos])
	return out


## Decides once per montage, before it first poses the body, whether its root motion moves the capsule: DI2's
## DINPCAnimInstance extracts root motion from everything (RootMotionFromEverything, ctor 0x141bcb350 ->
## SetRootMotionMode(2)), montages included, from each segment sequence with bEnableRootMotion (montages_zombie.json
## root_motion, with its RootMotionRootLock). The port applies it where zombie.gd moves the capsule by root_motion():
## standing root-motion locomotion and montages zombie_reactions does not own (attacks, wind-ups, the AI's anim-set
## montages). zombie_reactions moves the capsule itself, and paired clips keep the paired offset in their held root.
func _rm_flag() -> void:
	for m: DI2Anim.Montage in a.slot:
		if m.rm_set:
			continue
		m.rm_set = true
		if not rm_locomotion or m.additive or m.layer != "" or (z.reactions and z.reactions.state != ""):
			continue
		var locks: Dictionary = zdata.get("root_motion", {})
		var seqs: Array = m.d.get("seqs", [])
		for i in m.segs.size():
			var c := str(m.segs[i][0])
			var seq := str(seqs[i]) if i < seqs.size() else _seq(c)
			if locks.has(seq):
				m.ref_root[c] = str(locks[seq]).trim_suffix("!")


## Root delta of montage `m` from position p0 to p1 across its segments (FAnimTrack::ExtractRootMotionFromTrackRange:
## each segment's part of the range from its own sequence, composed in order), as Vector4(local x, y, z in the root
## frame at p0, turn about +Y). Forward play only.
func _montage_root_delta(m: DI2Anim.Montage, p0: float, p1: float) -> Vector4:
	var out := Vector4.ZERO
	for s: Array in m.segs:
		var rate := float(s[4])
		var c := str(s[0])
		if rate <= 0.0 or int(s[5]) != 1 or not m.ref_root.has(c):
			continue
		var t_from := float(s[1])
		var t_to := t_from + (float(s[3]) - float(s[2])) / rate
		var pa := maxf(p0, t_from)
		var pb := minf(p1, t_to)
		if pb <= pa:
			continue
		var r0 := _root_at(c, float(s[2]) + (pa - t_from) * rate)
		var d := _root_at(c, float(s[2]) + (pb - t_from) * rate) - r0
		var local := Basis(Vector3.UP, out.w) * (Basis(Vector3.UP, r0.w) * Vector3(d.x, d.y, d.z))
		out += Vector4(local.x, local.y, local.z, -d.w)
	return out


## Adds this frame's root delta (sources sampled before and after DI2Anim.update) to rm_acc, each source's motion
## expressed in its root's frame at the earlier time so the mover can apply it in the actor's current frame.
func _rm_accumulate() -> void:
	var before := {}
	for s: Array in _rm_before:
		before[s[0]] = s
	for s: Array in _rm_sources():
		if s.size() > 5 and before.has(s[0]) and not s[5].ref_root.is_empty():
			# A montage with root motion: across its segment boundaries too (the IntoStatic -> attack hand-over).
			rm_acc += _montage_root_delta(s[5], float(before[s[0]][6]), float(s[6])) * float(s[3])
			continue
		if not before.has(s[0]) or before[s[0]][1] != s[1]:
			continue
		var t0: float = before[s[0]][2]
		var t1: float = s[2]
		var r0 := _root_at(s[1], t0)
		var d: Vector4
		if t1 + 1e-5 < t0 and s[4]:   # looped: to the end, then from the start
			var length := a.clip_len(s[1])
			d = (_root_at(s[1], length) - r0) + _root_at(s[1], t1)
		else:
			d = _root_at(s[1], t1) - r0
		var local := Basis(Vector3.UP, r0.w) * Vector3(d.x, d.y, d.z)   # into the root frame at t0 (UE yaw -> -turn)
		rm_acc += Vector4(local.x, local.y, local.z, -d.w) * float(s[3])


## The accumulated root motion for the mover, then reset: {velocity (world, m/s), yaw (rad about +Y), active}.
func root_motion(delta: float) -> Dictionary:
	var d := rm_acc
	rm_acc = Vector4.ZERO
	var world := z.skeleton.global_basis * Vector3(d.x, d.y, d.z)
	return {"velocity": world / maxf(delta, 1e-4), "yaw": d.w, "active": not z.dead}


# --- root-motion locomotion (rm_locomotion) ----------------------------------------------------------------------
## DI2's Base_Locomotion with its Starts / Stops / TurnOnSpot states (exe: Idle FUN_14114a060, Start FUN_14114b1f0,
## TurnOnSpot FUN_14114b6e0, Move steering in FUN_141129580, turn-vs-start FUN_141126cc0, stop test FUN_141117920,
## steering spring FUN_14116ed50; recon/ANIMATION.md 3.6). The base pose's root motion moves and turns the capsule
## (root_motion()); steering adds the spring's yaw on top.
## Per family: DA_AnimSetCollection_<Family>_Locomotion (Start / Stops sets / TurnOnSpot). The Shambler plays the
## Walker set with DA_AnimSetCollection_Shambler_Pers_LeftLeg on top (Start_FB, WalkToIdle stops); its glb lacks
## 36 / 41 of those Start sequences and 5 / 20 of the stops, so a set missing any sample clip is not played and the
## state falls back to DI2's direct Idle <-> Move edges (UNVERIFIED stand-in for the missing clips).
const LOCO_SETS := {
	"walker": {"start": "BS_ZMB_Walker_Start", "stop": ["BS_ZMB_Walker_Stop_LFoot", "BS_ZMB_Walker_Stop_RFoot"],
		"turn": "BS_ZMB_Walker_TurnonSpot"},
	"shambler": {"start": "BS_ZMB_Walker_Personality_LeftLeg_Start_FB",
		"stop": ["BS_ZMB_Walker_Personality_LeftLeg_WalkToIdle_LFoot_FB", "BS_ZMB_Walker_Personality_LeftLeg_WalkToIdle_RFoot_FB"],
		"turn": "BS_ZMB_Walker_TurnonSpot"},
	"thug": {"start": "BS_ZMB_Thug_Start", "stop": ["BS_ZMB_Thug_Stop_LFoot", "BS_ZMB_Thug_Stop_RFoot"],
		"turn": "BS_ZMB_Thug_TurnOnSpot"},
	"runner": {"start": "BS_ZMB_Runner_Start_02", "stop": ["BS_ZMB_Runner_Stop_LFoot", "BS_ZMB_Runner_Stop_RFoot"],
		"turn": "BS_ZMB_Runner_TurnOnSpot"},
	# Specials: Starts / TurnOnSpot / Stops of DA_AnimSetCollection_<Class>_Locomotion (the Butcher body's
	# _Butcher_Standing_Locomotion, BP_Base_Butcher), the Stops sets' Stop_LFoot / Stop_RFoot groups
	# (DA_AnimSet_<Class>_Stops; the Butcher's is DA_AnimSet_Runner_Stops). Clips: zombie_clips/<body>_loco.
	"screamer": {"start": "BS_ZMB_Screamer_Start", "stop": ["BS_ZMB_Screamer_Stop_LFoot", "BS_ZMB_Screamer_Stop_RFoot"],
		"turn": "BS_ZMB_Screamer_TurnOnSpot"},
	"slobber": {"start": "BS_ZMB_Slobber_Start", "stop": ["BS_ZMB_Slobber_Stop_LFoot", "BS_ZMB_Slobber_Stop_RFoot"],
		"turn": "BS_ZMB_Slobber_TurnOnSpot"},
	"suicider": {"start": "BS_ZMB_Suicider_Start", "stop": ["BS_ZMB_Suicider_Stop_LFoot", "BS_ZMB_Suicider_Stop_RFoot"],
		"turn": "BS_ZMB_Suicider_TurnOnSpot"},
	"butcher": {"start": "BS_ZMB_Butcher_Combat_Start", "stop": ["BS_ZMB_Runner_Stop_LFoot", "BS_ZMB_Runner_Stop_RFoot"],
		"turn": "BS_ZMB_Butcher_Combat_TurnOnSpot"},
}
## AnimState_Move's ForwardStrafeBlendSpace / BackwardStrafeBlendSpace: the anim sets ABP_ZombieWalker names
## (ForwardStrafeBlendSpaceAnimSetName "Locomotion.RunCombatFwd", BackwardStrafeBlendSpaceAnimSetName
## "Locomotion.RunCombatBwd"; Move entry FUN_1411291b0 resolves them) from DA_AnimSetCollection_<Family>_Locomotion. The
## Shambler body's DA_AnimSetCollection_Shambler_Pers_LeftLeg maps both to its LeftLeg Walk_FB blend space.
const MOVE_SETS := {"walker": ["BS_ZMB_Walker_Walk_F", "BS_ZMB_Walker_Walk_B"],
	"thug": ["BS_ZMB_Thug_Walk", "BS_ZMB_Thug_Walk_B"], "runner": ["BS_ZMB_Runner_Run", "BS_ZMB_Runner_RunB"],
	"shambler": ["BS_ZMB_Shambler_Personality_LeftLeg_Walk_FB", "BS_ZMB_Shambler_Personality_LeftLeg_Walk_FB"],
	"screamer": ["BS_ZMB_Screamer_Walk", "BS_ZMB_Screamer_WalkB"], "slobber": ["BS_ZMB_Slobber_Walk_Fwd", "BS_ZMB_Slobber_Walk_Bwd"],
	"suicider": ["BS_ZMB_Suicider_Walk", "BS_ZMB_Suicider_Walk_Bwd"], "butcher": ["BS_ZMB_Butcher_Combat_Walk", "BS_ZMB_Butcher_Combat_Walk_B"]}
## LocomotionStruct Move fields (ctor FUN_1410fa530; reflected offsets from the exe's FPropertyParams):
## YawForwardAnimationMax +0x1880 135, BoundaryBlendDegree +0x1884 10, MaxStrafePivotYaw +0x1888 90 (no family
## overrides them), FwdBwdLerpingSpeed +0x188c 2.0 (DA_LocomotionDefinition_Walker 3.0). MoveStrafeSteeringSpeed
## +0x1840 equals MoveSteeringSpeed (180, no overrides), so strafing steers like Move.
const YAW_FORWARD_MAX := 135.0
const BOUNDARY_BLEND := 10.0
const MAX_STRAFE_PIVOT := 90.0
const FWD_BWD_LERP := {"walker": 3.0}   # others: the ctor's 2.0
## ABP_ZombieWalker BlendListByBool_3 (bActiveValue = AnimState_Move.bPrimarySystem): BlendTime 1.0, QuarticInOut.
const STRAFE_SWAP := [1.0, "QuarticInOut"]
## LocomotionStruct (instance +0x1838; ctor defaults FUN_1410fa530, DA_LocomotionDefinition_<Family> overrides):
## MoveSteeringSpeed +0x183c (Move, FUN_141129580), StartsSteeringAngleThreshold +0x1844, StartsSteeringSpeed
## +0x1848 (Start, FUN_14114b1f0), TurnOnSpotSteeringSpeed +0x184c, TurnOnSpotSteeringLagTime +0x1850 (FUN_14114b6e0).
const LOCO_DEF := {
	"walker": {"move_steer": 180.0, "start_steer_angle": 120.0, "start_steer": 140.0, "tos_steer": 90.0, "tos_lag": 0.05},
	"thug": {"move_steer": 180.0, "start_steer_angle": 120.0, "start_steer": 140.0, "tos_steer": 90.0, "tos_lag": 0.05},
	"runner": {"move_steer": 180.0, "start_steer_angle": 120.0, "start_steer": 140.0, "tos_steer": 180.0, "tos_lag": 0.02},
	"shambler": {"move_steer": 180.0, "start_steer_angle": 60.0, "start_steer": 15.0, "tos_steer": 0.0, "tos_lag": 0.05},
	"screamer": {"move_steer": 180.0, "start_steer_angle": 60.0, "start_steer": 15.0, "tos_steer": 0.0, "tos_lag": 0.05},
	"suicider": {"move_steer": 180.0, "start_steer_angle": 60.0, "start_steer": 15.0, "tos_steer": 0.0, "tos_lag": 0.05},
	"butcher": {"move_steer": 180.0, "start_steer_angle": 120.0, "start_steer": 140.0, "tos_steer": 90.0, "tos_lag": 0.05},
	# DA_LocomotionDefinition_Slobber: MoveSteeringSpeed / MoveStrafeSteeringSpeed 120, StartsSteeringSpeed 60,
	# TurnOnSpotSteeringSpeed 15, TurnOnSpotThreshold 15.
	"slobber": {"move_steer": 120.0, "start_steer_angle": 60.0, "start_steer": 60.0, "tos_steer": 15.0, "tos_lag": 0.05,
		"tos_threshold": 15.0},
}
const TURN_THRESHOLD := 10.0       # TurnOnSpotThreshold +0x185c (ctor default; LOCO_DEF tos_threshold overrides)
const TURN_DELAY := 0.3            # +0x18a8
const TURN_LEAD := 0.2             # TurnOnSpotLeadTime +0x18ac
const TURN_MIN_WEIGHT := 0.25      # Idle state MinStateWeightForTurnOnSpot (+0x70)
const TURN_ROT_SPEED := [0.0, 100.0, 100.0]   # TurnOnSpotRotationSpeed Calm / Alert / Combat +0x189c / a0 / a4
const FACING_PRIORITY_DIST := 2.0  # MaxDistanceToPrioritiseFacingDirection +0x18b4 (200 cm)
const MOVE_STEER_LAG := 0.2        # FUN_141129580 -> FUN_14111b2f0(..., 0.2)
const START_STEER_LAG := 0.2       # FUN_14114b1f0 -> FUN_141173540(..., 0.2)
## Duration (FUN_1411615a0): the weighted time of the samples' first AnimNotify_LocomotionTransition of the state's
## ETransition (FUN_141150550 / FUN_141162050; montages_zombie.json loco_transition) when every weighted sample has one;
## otherwise the blend-space length at the input minus these margins (Start / TurnOnSpot MaxRemainingTimeToExit, Stop
## MaxRemainingTimeToIdle).
const MARGIN := {"Starts": 0.2, "Stops": 0.4, "TurnOnSpot": 0.2}
const EXIT_TRANSITION := {"Starts": 0, "Stops": 1, "TurnOnSpot": 3}   # ETransition: EndStopToMove / EndMoveToStop / EndTurnOnSpot

var _loco := ""                    # Idle / Starts / Move / Stops / TurnOnSpot ("" before the first drive)
var _loco_t := 0.0                 # time in the state
var _loco_dur := 0.0               # the state's Duration
var _loco_src = null               # the state's source (BS / Seq)
var _loco_n := 0                   # unique key suffix (set_state ignores a repeated key)
var _clock := 0.0
var _combat := 0                   # 0 Calm / 1 Alert / 2 Combat
var _turn_t0 := -1.0               # Idle: when the facing error first reached the threshold (-1 = not)
var _turn_a0 := 0.0
var _want := Vector3.ZERO
var _speed_cm := 0.0               # SpeedTarget (cm/s) of the last move
var _start_dir := Vector3.ZERO     # Start: the initial move direction (+0x70)
var _steer_on := false             # Start: steering latch (+0x7c)
var _steer_vel := 0.0              # steering spring velocity (deg/s, + = right like UE)
var loco_log: Array = []           # [clock, state, input x, input y, Duration] per state entry (anim_capture)
static var _fk_cache := {}         # Animation id -> {bone: [pos track, rot track]}


## A Locomotion blend space for this body, or null when it is missing or any sample clip is.
func _set_bs(name: String):
	if name == "":
		return null
	var bs: Dictionary = DI2Anim.graphs.get("blend_spaces", {}).get(name, {})
	if bs.is_empty():
		return null
	var clips: Array = _bs_clips(bs)
	if clips.size() != bs["samples"].size():
		return null
	for c: String in clips:
		if not a.has_clip(c):
			return null
	var src := DI2Anim.BS.new(a, bs, clips)
	src.unsynced = true
	src.loop = true    # the Start / Stop / TurnOnSpot players have bLoop = true in the ABP CDO
	return src


## UE yaw (deg, + = a right turn) from the actor's facing to world direction `d`.
func _ue_angle(d: Vector3) -> float:
	var h := Vector3(d.x, 0.0, d.z)
	if h.length_squared() < 1e-6:
		return 0.0
	var fwd := -z.global_basis.z
	fwd.y = 0.0
	return -rad_to_deg(fwd.normalized().signed_angle_to(h.normalized(), Vector3.UP))


## Blend-space source at input (x, y) with its weights set: [src, Duration] or [null, 0].
func _loco_bs(name: String, x: float, y: float, state: String) -> Array:
	var src = _set_bs(name)
	if src == null:
		return [null, 0.0]
	src.x = x
	src.y = y
	src.weights = src.targets()
	src.started = true
	var dur := _notify_duration(src, int(EXIT_TRANSITION.get(state, -1)))
	if dur < 0.0:
		dur = maxf(src.length_now() - float(MARGIN.get(state, 0.0)), 0.0)
	return [src, dur]


## FUN_141150550: sum over the samples with weight in (0, 1] of weight * the sequence's first LocomotionTransition
## notify of type `mode`, over the weights' sum; -1 when a weighted sample has none (FUN_1411615a0 then falls back to
## length - margin). The weighted-average form is UNVERIFIED (the return arithmetic is in XMM registers the decompile
## drops).
func _notify_duration(src: DI2Anim.BS, mode: int) -> float:
	if mode < 0:
		return -1.0
	var lt: Dictionary = zdata.get("loco_transition", {})
	var sum := 0.0
	var wsum := 0.0
	for i in src.samples.size():
		var w := clampf(src.weights[i], 0.0, 1.0)
		if w <= 0.0:
			continue
		var t := -1.0
		for n: Array in lt.get(_seq(str(src.samples[i][0])), []):
			if int(n[1]) == mode:
				t = float(n[0])
				break
		if t < 0.0:
			return -1.0
		sum += w * t
		wsum += w
	return sum / wsum if wsum > 0.0 else -1.0


## Root motion of `src` from phase `from_phase` (its own phase when < 0) to Duration's end: weighted
## Vector4(x, y, z, yaw) in root units (UE yaw).
func _bs_root_ahead(src, dur: float, from_phase := -1.0) -> Vector4:
	var l: float = src.length_now()
	if l <= 0.0:
		return Vector4.ZERO
	var p0: float = src.phase if from_phase < 0.0 else from_phase
	var p1 := minf(dur / l, 1.0)
	if p0 >= p1:
		return Vector4.ZERO
	var out := Vector4.ZERO
	for i in src.samples.size():
		if src.weights[i] > 0.0:
			var len_i: float = src.samples[i][4]
			out += (_root_at(src.samples[i][0], p1 * len_i) - _root_at(src.samples[i][0], p0 * len_i)) * src.weights[i]
	return out


func _enter(state: String, src, dur: float, x := 0.0, y := 0.0) -> void:
	var prev := _loco if _loco != "" else "Idle"
	_loco_n += 1
	var key := "%s:stand:rm%d" % [state, _loco_n]
	var tr: Array = _transition("%s:stand:" % prev, state, false) if _loco != "" else [0.0, "Linear"]
	if prev == state:
		tr = IDLE_SET_SWITCH if state == "Idle" else [0.0, "Linear"]
	a.set_state(key, src, tr[0], tr[1], _bprofile("%s->%s" % [prev, state]) if prev != state else {})
	_loco = state
	_loco_t = 0.0
	_loco_dur = dur
	_loco_src = src
	_steer_vel = 0.0
	_steer_on = false
	loco_log.append([snappedf(_clock, 0.001), state, snappedf(x, 0.1), snappedf(y, 0.1), snappedf(dur, 0.001)])
	if loco_log.size() > 64:
		loco_log.pop_front()
	if src is DI2Anim.BS:
		_log_clip(src.samples[_lead(src)][0])


func _lead(src) -> int:
	var best := 0
	for i in src.weights.size():
		if src.weights[i] > src.weights[best]:
			best = i
	return best


func _enter_idle(clip: String) -> void:
	if not a.has_clip(clip):
		clip = "idle"
	_enter("Idle", DI2Anim.Seq.new(clip, a.clip_len(clip), clip != "alert"), 0.0)
	_turn_t0 = -1.0


func _enter_move() -> void:
	# Move entry FUN_1411291b0: bForward (+0xb8) = |StrafeAngle| <= YawForwardAnimationMax, BackwardBlendValue (+0xa4)
	# 0 / 1 to match, bPrimarySystem (+0x98) on, PrimaryStrafeAngle (+0x9c) and the last angle (+0xbc) = the angle.
	var ang := _strafe_angle()
	_mv_fwd = absf(ang) <= YAW_FORWARD_MAX
	_mv_angle = ang
	_mv_old = null
	var src = _move_bs(ang) if rm_locomotion and MOVE_SETS.has(body) else null
	if src == null:
		src = _move_source(false, _speed_cm / 100.0)
	if src != null:
		if src is DI2Anim.BS and not src.samples.is_empty():
			# AnimState_Move.BlendSpaceStartPosition (Move entry FUN_1411291b0 -> FUN_1411088d0), bound to the Move
			# players' StartPosition; FAnimNode_BlendSpacePlayer::Reinitialize (UE 4.27) clamps it to [0, 1] as the
			# normalised play time.
			src.phase = clampf(_ff_start_position(src), 0.0, 1.0)
		_enter("Move", src, 0.0, ang, _speed_cm)


# --- strafing Move (AnimState_Move, ABP_ZombieWalker Move state; recon/ANIMATION.md 14) ---------------------------
var move_dir := Vector3.ZERO      # world direction the AI moves in (zombie_ai.gd strafe cards); ZERO = toward _want
var _mv_fwd := true               # AnimState_Move +0xb8: the forward blend space is the target
var _mv_angle := 0.0              # +0xbc: the angle the active system plays
var _mv_old: MoveBS = null        # the other system while BlendListByBool_3 crossfades to the new one


## FUN_141135f00: the signed angle (deg) from the facing direction (FUN_141106040: +0x1800 when it is a unit vector,
## else the actor's forward) to the movement velocity (+0x167c), 0 without velocity. UE sign: + = to the right.
## The port's velocity direction is the AI's move_dir (strafes) or the direction to its goal (UNVERIFIED: desired vs
## actual velocity at +0x167c).
func _strafe_angle() -> float:
	if _speed_cm <= 0.0:
		return 0.0
	return _ue_angle(move_dir if move_dir.length_squared() > 1e-6 else _want)


## The Move state's pose source: ABP_ZombieWalker's TwoWayBlend_8 of BlendSpacePlayer_6 (ForwardStrafeBlendSpace) and
## _7 (BackwardStrafeBlendSpace) at X = StrafeAngle, Y = SpeedTarget, Alpha = BackwardBlendValue.
func _move_bs(ang: float) -> MoveBS:
	var sets: Array = MOVE_SETS[body]
	var f := _full_bs(str(sets[0]))
	if f == null:
		return null
	var b := _full_bs(str(sets[1])) if sets[1] != sets[0] else null
	var m := MoveBS.new(a, f, b)
	m.back = 0.0 if _mv_fwd else 1.0
	m.x = ang
	m.y = _speed_cm
	m.prime()
	# Move's players are in sync group "Locomotion" (GroupIndex 4, CanBeLeader): their samples sync by marker.
	var sm: Dictionary = zdata.get("sync_markers", {})
	for s: Array in m.samples:
		m.markers.append(sm.get(_seq(str(s[0])), []))
	return m


## The body's clip per sample of blend space `bs`: anim_graphs.json's list for the body, else each sample's DI2
## sequence resolved here (the body glb's clip for it, else the "x:<sequence>" clip of zombie_clips/<body>_loco).
func _bs_clips(bs: Dictionary) -> Array:
	var clips: Array = bs.get("clips", {}).get(body, [])
	if not clips.is_empty():
		return clips
	_seq("")   # fills seq_of[body]
	if not clip_of_seq.has(body):
		var m := {}
		for c: String in seq_of[body]:
			if a.has_clip(c) and not m.has(seq_of[body][c]):
				m[seq_of[body][c]] = c
		clip_of_seq[body] = m
	for s: Array in bs.get("samples", []):
		var seq := str(s[0])
		clips.append("x:" + seq if a.has_clip("x:" + seq) else str(clip_of_seq[body].get(seq, "")))
	return clips

static var clip_of_seq := {}   # body -> {DI2 sequence: body clip}


## A 2D blend space from anim_graphs.json with every sample the body has (missing ones skipped; GridSamples refer to
## the source indices). Root-motion locomotion plays the clips with their pelvis drift (drift_clip).
func _full_bs(name: String) -> DI2Anim.BS:
	var bs: Dictionary = DI2Anim.graphs.get("blend_spaces", {}).get(name, {})
	if bs.is_empty():
		return null
	var clips: Array = _bs_clips(bs).duplicate()
	for i in clips.size():
		var c := str(clips[i])
		if c.begins_with("inplace:"):
			c = c.trim_prefix("inplace:")
			clips[i] = drift_clip.get(body, {}).get(c, c)
	var src := DI2Anim.BS.new(a, bs, clips)
	return null if src.samples.size() < 2 else src


## Move tick FUN_14114a510 (after its transition checks): BackwardBlendValue = FInterpConstantTo (FUN_141f277a0)
## toward bForward ? 0 : 1 at FwdBwdLerpingSpeed; bForward flips once ||angle| - YawForwardAnimationMax| >=
## BoundaryBlendDegree; an angle within MaxStrafePivotYaw of the last one updates the active system's angle, a bigger
## jump swaps bPrimarySystem (the other system takes the new angle, the old one keeps its last) through
## BlendListByBool_3 (STRAFE_SWAP).
func _move_tick(dt: float) -> void:
	var m := _loco_src as MoveBS
	if m == null:
		return
	m.back = move_toward(m.back, 0.0 if _mv_fwd else 1.0, dt * float(FWD_BWD_LERP.get(body, 2.0)))
	var ang := _strafe_angle()
	var e := absf(ang) - YAW_FORWARD_MAX
	if BOUNDARY_BLEND <= absf(e):
		_mv_fwd = e < 0.0
	var d := wrapf(_mv_angle - ang, -180.0, 180.0)
	if absf(d) < MAX_STRAFE_PIVOT:
		m.x = ang
	else:
		var n := _move_bs(ang)
		if n != null:
			n.back = m.back
			n.phase = m.phase
			_loco_n += 1
			a.set_state("Move:stand:rm%d" % _loco_n, n, STRAFE_SWAP[0], STRAFE_SWAP[1], _bprofile("MoveSwap"))
			_mv_old = m
			_loco_src = n
			loco_log.append([snappedf(_clock, 0.001), "MoveSwap", snappedf(ang, 0.1), snappedf(_speed_cm, 0.1), 0.0])
			m = n
	_mv_angle = ang
	m.y = _speed_cm
	if _mv_old != null:
		if a.states.any(func(s): return s["src"] == _mv_old):
			_mv_old.y = _speed_cm   # both systems read SpeedTarget and BackwardBlendValue
			_mv_old.back = m.back
		else:
			_mv_old = null


## The BlendProfile ABP_ZombieWalker uses on Base_Locomotion transition `edge` ("Starts->Move", "MoveSwap" = Move's
## BlendListByBool_3) as {bone index: BlendScale} (montages_zombie.json loco_profiles / blend_profiles, from the
## skeleton's BlendToRootMotion: Root 20, Pelvis 3); {} without one.
func _bprofile(edge: String) -> Dictionary:
	var pn := str(zdata.get("loco_profiles", {}).get(edge, ""))
	if pn == "":
		return {}
	var out := {}
	var prof: Dictionary = zdata.get("blend_profiles", {}).get(pn, {})
	for bn: String in prof:
		for k: String in a.bone_of:
			if k.to_lower() == bn.to_lower():
				out[a.bone_of[k]] = float(prof[bn])
	return out


## TwoWayBlend of two synced blend-space players as one source: both players' samples in one list (the forward ones
## weighted 1 - back, the backward ones back), so root motion, the foot tracker and marker sync treat them as the one
## sync group they are in DI2. Each player keeps its own TargetWeightInterpolationSpeedPerSec.
class MoveBS extends DI2Anim.BS:
	var fwd: DI2Anim.BS
	var bwd: DI2Anim.BS
	var back := 0.0                 # AnimState_Move.BackwardBlendValue

	func _init(an: DI2Anim, f: DI2Anim.BS, b: DI2Anim.BS) -> void:
		super(an, {"samples": []})
		fwd = f
		bwd = b
		samples = f.samples.duplicate()
		if b != null:
			samples.append_array(b.samples)
		weights.resize(samples.size())

	func _player(p: DI2Anim.BS, dt: float) -> void:
		p.x = x
		p.y = y
		var tg := p.targets()
		if p.speed > 0.0 and p.started:
			var total := 0.0
			for i in p.weights.size():
				p.weights[i] = move_toward(p.weights[i], tg[i], p.speed * dt)
				total += p.weights[i]
			if total > 1e-5:
				for i in p.weights.size():
					p.weights[i] /= total
		else:
			p.weights = tg
		p.started = true

	## Both players' weights at the current input (before the first tick).
	func prime() -> void:
		_player(fwd, 0.0)
		if bwd != null:
			_player(bwd, 0.0)
		weights = targets()

	func targets() -> PackedFloat32Array:
		var t := PackedFloat32Array()
		var bk := back if bwd != null else 0.0
		for w in fwd.weights:
			t.append(w * (1.0 - bk))
		if bwd != null:
			for w in bwd.weights:
				t.append(w * bk)
		return t

	func advance(dt: float) -> void:
		_player(fwd, dt)
		if bwd != null:
			_player(bwd, dt)
		super.advance(dt)   # speed 0: weights = targets(); phase and marker sync over both players' samples


## TurnOnSpot vs Start with move input (FUN_141126cc0): turn first when the facing error is over the threshold, the
## destination is within MaxDistanceToPrioritiseFacingDirection and the turn is shorter than the start. Not ported:
## its CVar (taken as on), FUN_141120000 and the post-turn distance check (UNVERIFIED).
func _start_or_turn(dest: float) -> void:
	var ang := _ue_angle(_want)
	var sets: Dictionary = LOCO_SETS[body]
	var st := _loco_bs(sets["start"], ang, _speed_cm, "Starts")
	if absf(ang) >= _turn_threshold() and dest < FACING_PRIORITY_DIST:
		var rs: float = TURN_ROT_SPEED[_combat]
		var tn := _loco_bs(sets["turn"], ang, rs, "TurnOnSpot")
		if tn[0] != null and (st[0] == null or tn[0].length_now() < st[0].length_now()):
			_enter("TurnOnSpot", tn[0], tn[1], ang, rs)
			return
	if st[0] == null:
		_enter_move()   # no Start set for this body: DI2's Idle -> Move edge (0.2 s)
		return
	_start_dir = Vector3(_want.x, 0.0, _want.z).normalized()
	_enter("Starts", st[0], st[1], ang, _speed_cm)


## Stop: DA_AnimSet_<Family>_Stops picks Stop_LFoot / Stop_RFoot by the native BlendingFoot tag, which isn't decoded.
## Stand-in (UNVERIFIED): the set whose leading sample's first frame has the feet placed most like the current pose.
func _enter_stop() -> void:
	var ang := _ue_angle(_want)
	var cands := []
	for n: String in LOCO_SETS[body]["stop"]:
		var r := _loco_bs(n, ang, _speed_cm, "Stops")
		if r[0] != null:
			cands.append(r)
	if cands.is_empty():
		_enter_idle("alert" if _combat >= 1 else "idle")   # DI2's Move -> Idle edge (0.8 s ExpOut)
		return
	var pick: Array = cands[0]
	var fl: int = a.bone_of.get("foot_l", -1)
	var fr: int = a.bone_of.get("foot_r", -1)
	if cands.size() > 1 and fl >= 0 and fr >= 0:
		var cur := z.skeleton.get_bone_global_pose(fl).origin - z.skeleton.get_bone_global_pose(fr).origin
		var best := INF
		for c: Array in cands:
			var clip: String = c[0].samples[_lead(c[0])][0]
			var d := (_fk_pos(clip, 0.0, fl) - _fk_pos(clip, 0.0, fr)).distance_to(cur)
			if d < best:
				best = d
				pick = c
	_enter("Stops", pick[0], pick[1], ang, _speed_cm)


## Skeleton-space position of `bone` in `clip` at `t` (FK over the clip's tracks, rest pose where a bone has none).
func _fk_pos(clip: String, t: float, bone: int) -> Vector3:
	var anim := a.clip(clip)
	var id := anim.get_instance_id()
	if not _fk_cache.has(id):
		var m := {}
		var tr: Array = a._tracks(anim)
		for k in tr[0].size():
			m[tr[1][k]] = [tr[0][k], -1]
		for k in tr[2].size():
			var e: Array = m.get(tr[3][k], [-1, -1])
			e[1] = tr[2][k]
			m[tr[3][k]] = e
		_fk_cache[id] = m
	var tracks: Dictionary = _fk_cache[id]
	var xf := Transform3D.IDENTITY
	var b := bone
	while b >= 0:
		var e: Array = tracks.get(b, [-1, -1])
		var pos: Vector3 = anim.position_track_interpolate(e[0], t) if e[0] >= 0 else a.rest_pos[b]
		var rot: Quaternion = anim.rotation_track_interpolate(e[1], t) if e[1] >= 0 else a.rest_rot[b]
		xf = Transform3D(Basis(rot), pos) * xf
		b = a.parent_of[b]
	return xf.origin


## One physics step of DI2's locomotion states (see LOCO_SETS).
func _drive_rm(state: String, speed: float, want: Vector3, dest: float) -> void:
	var moving := state in ["Chase", "Walk"] and speed > 0.01
	_want = want
	if moving:
		_speed_cm = speed * 100.0
	var idle_clip := "alert" if state == "Alert" else "idle"
	if state in ["Idle", "Alert", "Chase", "Walk", "Attack"]:
		# InternalCombatState stand-in: an attacking zombie runs DI2's melee action, i.e. it is in Combat (the
		# Combat sets are where ABP_ZombieWalker blends the Idle / Starts wind-up; UNVERIFIED mapping).
		_combat = 0 if state == "Idle" else (1 if state == "Alert" else 2)
		if face:
			face.combat_state = _combat
	match _loco:
		"":
			_enter_idle(idle_clip)
		"Idle":
			if moving:
				_start_or_turn(dest)
				return
			if state in ["Idle", "Alert"] and _loco_src is DI2Anim.Seq and _loco_src.clip != idle_clip \
					and a.has_clip(idle_clip):
				_enter_idle(idle_clip)   # Calm / Alert idle sets (BlendListByEnum 0.3 s)
			_idle_turn()
		"Starts":
			if _loco_t >= _loco_dur:
				if _stop_test(dest):
					_enter_stop()
				else:
					_enter_move()
		"Move":
			if moving:
				if _loco_src is DI2Anim.BS and not _loco_src is MoveBS:
					_loco_src.x = _speed_cm   # the 1D fallback source (MoveBS takes angle / speed in _move_tick)
			elif _stop_test(dest):
				_enter_stop()
		"Stops":
			if _loco_t >= _loco_dur:
				_enter_idle(idle_clip)
		"TurnOnSpot":
			# FUN_14114b6e0 only ever raises bTransitionToIdle (+0x29), once Duration has passed (or +0x171c is set);
			# nothing writes bTransitionToStart (+0x28), so DI2's TurnOnSpot -> Starts edge never fires: the turn plays
			# out, goes to Idle (0.4 s) and Idle starts the move.
			if _loco_t >= _loco_dur:
				_enter_idle(idle_clip)


## Idle without move input (FUN_14114a060): once the facing error has stayed >= TurnOnSpotThreshold for Delay and the
## Idle state's weight is >= MinStateWeightForTurnOnSpot, turn to the error extrapolated LeadTime ahead.
func _idle_turn() -> void:
	var ang := _ue_angle(_want)
	if absf(ang) < _turn_threshold():
		_turn_t0 = -1.0
		return
	if _turn_t0 < 0.0:
		_turn_t0 = _clock
		_turn_a0 = ang
		return
	var el := _clock - _turn_t0
	if el < TURN_DELAY or a.states.is_empty() or a.states[-1]["src"] != _loco_src \
			or a.states[-1]["alpha"].value < TURN_MIN_WEIGHT:
		return
	var tgt := fposmod(ang + (ang - _turn_a0) / el * TURN_LEAD + 180.0, 360.0) - 180.0
	var rs: float = TURN_ROT_SPEED[_combat]
	var tn := _loco_bs(LOCO_SETS[body]["turn"], tgt, rs, "TurnOnSpot")
	if tn[0] != null:
		_enter("TurnOnSpot", tn[0], tn[1], tgt, rs)


## FUN_141117920: stop once DistanceToFinalDestination <= the stop's root travel (the leading stop set at the current
## input). The port's brain gives no path: zombie.gd passes 0 when it stops commanding speed, else INF (UNVERIFIED).
func _stop_test(dest: float) -> bool:
	if dest <= 0.0:
		return true
	if not is_finite(dest):
		return false
	var r := _loco_bs(LOCO_SETS[body]["stop"][0], _ue_angle(_want), _speed_cm, "Stops")
	if r[0] == null:
		return false
	var d := _bs_root_ahead(r[0], r[1], 0.0)
	return dest <= Vector2(d.x, d.z).length()


## Per frame: state time, and the steering spring's yaw into rm_acc (Starts after its latch, Move, TurnOnSpot). The
## spring's target is the facing error minus the yaw the playing clips still turn before the state's Duration ends
## (the exe computes the remaining angle in FUN_141173540 / FUN_14111b2f0; subtracting the clip's own remaining turn
## is UNVERIFIED).
func _rm_tick(delta: float) -> void:
	_clock += delta
	if _loco == "" or not rm_locomotion:
		return
	_loco_t += delta
	if _loco == "Move" and not z.dead:
		_move_tick(delta)
	if a.states.is_empty() or a.states[-1]["src"] != _loco_src or z.dead or _want.length_squared() < 1e-6:
		return
	if a.active() != null:
		return   # under a montage zombie.gd keeps the capsule turn (UNVERIFIED: whether DI2 steers under the slot)
	var defs: Dictionary = LOCO_DEF.get(body, LOCO_DEF["walker"])
	var maxs := 0.0
	var lag := 0.0
	match _loco:
		"Starts":
			if not _steer_on:
				var fwd := -z.global_basis.z
				fwd.y = 0.0
				var cosv := clampf(fwd.normalized().dot(_start_dir), -1.0, 1.0)
				_steer_on = rad_to_deg(acos(cosv)) < float(defs["start_steer_angle"])
				if not _steer_on:
					return
			maxs = defs["start_steer"]
			lag = START_STEER_LAG
		"Move":
			maxs = defs["move_steer"]
			lag = MOVE_STEER_LAG
		"TurnOnSpot":
			maxs = defs["tos_steer"]
			lag = defs["tos_lag"]
		_:
			return
	var rem := _ue_angle(_want)
	if _loco != "Move" and _loco_src is DI2Anim.BS:
		rem -= rad_to_deg(_bs_root_ahead(_loco_src, _loco_dur).w)
	rm_acc.w -= deg_to_rad(steer_step(rem, maxs, lag, delta))   # UE right turn = -yaw about +Y


## TurnOnSpotThreshold (+0x185c) of the body's family.
func _turn_threshold() -> float:
	return float(LOCO_DEF.get(body, LOCO_DEF["walker"]).get("tos_threshold", TURN_THRESHOLD))


## FUN_14116ed50: critically damped spring on the remaining yaw (deg), velocity clamped to `max_speed` deg/s; returns
## this frame's yaw step (deg, UE sign).
func steer_step(remaining: float, max_speed: float, lag: float, dt: float) -> float:
	if dt <= 0.0:
		return 0.0
	var rw := fposmod(remaining + 180.0, 360.0) - 180.0
	if lag <= 0.0:
		_steer_vel = rw / dt
	else:
		var om := 2.0 / lag
		var x := om * dt
		var e := 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
		var temp := (-rw * om + _steer_vel) * dt
		_steer_vel = (_steer_vel - temp * om) * e
	_steer_vel = clampf(_steer_vel, -max_speed, max_speed)
	return fposmod(_steer_vel * dt + 540.0, 360.0) - 180.0


## The base locomotion state name (anim_capture / tests).
func loco_state() -> String:
	return _loco


## ABP_ZombieWalker's locomotion-layer attack wind-up, driven by AnimInterest_Melee.AttackWindUpAmount (`amount`) and
## LastWindUpDefinition's sequences (montages_zombie.json windup_defs; recon/ANIMATION.md 11), per Base_Locomotion state:
##   Idle (Combat set, BlendListByEnum_1 [0,1,2]): TwoWayBlend_10 -> SequenceEvaluator(WindUpIdleAdditive, a full pose)
##     at WindUpSamplePosition = its length * clamp(amount), alpha WindUpBlendValue = clamp(amount * 10) (FUN_14114e4e0);
##   Starts (Combat, BlendListByEnum_2 [0,0,1]): ApplyAdditive_2 (alpha = amount) of WindUpStartAdditive at the
##     evaluator's unbound ExplicitTime 0.55 s (CDO; past the 0.5 s clips, so their last frame);
##   Stops / TurnOnSpot: ApplyAdditive_3 / _4 of WindUpStartAdditive at amount * its length, alpha
##     MapRangeClamped(amount, 0, 0.1, 0, 1) (ubergraph 540-825, 1329-1511);
##   Move: TwoWayBlend_7 to the WindUpRun blend space by amount - not ported (its Cycle clips aren't extracted; UNVERIFIED).
## DI2 blends these inside the state machine, under the montage slots; here they act on the composed pose, weighted by
## each state's share of the base layer and by the base layer's share under DefaultSlot montages. Local-space
## additives apply like FTransform::BlendFromIdentityAndAccumulate (rotation delta * base, translation added).
class WindUpLayer:
	static var add_cache := {}         # body -> {sequence: {rate, frames, bones: {name: Array}}}
	var zc: ZombieAnim

	func _init(owner: ZombieAnim) -> void:
		zc = owner
		if not add_cache.has(zc.body):
			var f := "res://assets/di2/zombie_clips/%s_windup.additive.json" % zc.body
			add_cache[zc.body] = Util.load_json(f) if FileAccess.file_exists(f) else {}

	func apply(an: DI2Anim) -> void:
		if zc.wu_amount <= 0.0 or zc.wu_last == "":
			return
		var wd: Dictionary = zc.zdata.get("windup_defs", {}).get(zc.wu_last, {})
		if wd.is_empty():
			return
		var amount := clampf(zc.wu_amount, 0.0, 1.0)
		var base := 1.0 - minf(an.montage_weight(), 1.0)
		if base <= 1e-5:
			return
		var w_idle := 0.0
		var w_start := 0.0
		var w_stop := 0.0
		var scale := 1.0
		for i in range(an.states.size() - 1, -1, -1):
			var al: float = an.states[i]["alpha"].value if i > 0 else 1.0
			var w := scale * al
			match str(an.states[i]["key"]).get_slice(":", 0):
				"Idle":
					if zc._combat == 2:
						w_idle += w * clampf(amount * 10.0, 0.0, 1.0)
				"Starts":
					if zc._combat == 2:
						w_start += w * amount
				"Stops", "TurnOnSpot":
					w_stop += w * clampf(amount / 0.1, 0.0, 1.0)
			scale *= 1.0 - al
			if scale <= 1e-5:
				break
		var idle_clip := "x:" + str(wd.get("idle", ""))
		if w_idle * base > 1e-4 and an.has_clip(idle_clip):
			_blend_full(an, idle_clip, an.clip_len(idle_clip) * amount, w_idle * base)
		var adds: Dictionary = add_cache[zc.body].get(str(wd.get("start", "")), {})
		if not adds.is_empty():
			if w_start * base > 1e-4:
				_add(an, adds, 0.55, w_start * base)
			if w_stop * base > 1e-4:
				_add(an, adds, float(adds["length"]) * amount, w_stop * base)

	func _blend_full(an: DI2Anim, clip: String, t: float, w: float) -> void:
		var anim := an.clip(clip)
		var e := an._tracks(anim)
		var pt: PackedInt32Array = e[0]
		var pb: PackedInt32Array = e[1]
		for i in pt.size():
			var b := pb[i]
			if b != an.root_lock and not (an.cover_on and an.covered[b]):
				an.acc_pos[b] = an.acc_pos[b].lerp(anim.position_track_interpolate(pt[i], t), w)
		var rt: PackedInt32Array = e[2]
		var rb: PackedInt32Array = e[3]
		for i in rt.size():
			var b := rb[i]
			if not (an.cover_on and an.covered[b]):
				an.acc_rot[b] = an.acc_rot[b].slerp(anim.rotation_track_interpolate(rt[i], t), w)

	func _add(an: DI2Anim, clip: Dictionary, t: float, w: float) -> void:
		var n := int(clip["frames"])
		var f := clampf(t * float(clip["rate"]), 0.0, float(n - 1))
		var i0 := floori(f)
		var i1 := mini(i0 + 1, n - 1)
		var r := f - i0
		var bones: Dictionary = clip["bones"]
		for bn: String in bones:
			var b: int = an.bone_of.get(bn, -1)
			if b < 0 or (an.cover_on and an.covered[b]):
				continue
			var k0: Array = bones[bn][i0]
			var k1: Array = bones[bn][i1]
			var q0 := Quaternion(k0[0], k0[1], k0[2], k0[3])
			var q1 := Quaternion(k1[0], k1[1], k1[2], k1[3])
			var q := q0.slerp(q1, r)
			an.acc_rot[b] = (Quaternion.IDENTITY.slerp(q, w) * an.acc_rot[b]).normalized()
			if b != an.root_lock:
				an.acc_pos[b] += Vector3(lerpf(k0[4], k1[4], r), lerpf(k0[5], k1[5], r), lerpf(k0[6], k1[6], r)) * w
