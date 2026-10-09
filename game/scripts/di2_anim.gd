class_name DI2Anim
extends RefCounted
## UE-style animation evaluation for one Skeleton3D (recon/ANIMATION.md). The AnimationPlayer only serves as the
## clip library; this samples its Animations per bone and blends them the way UE 4.27 does:
##   * translation: weighted sum; rotation: weighted quaternion sum aligned to the first contributor, normalised
##     (FTransform::BlendFromIdentityAndAccumulate); bones a clip doesn't key take the reference pose;
##   * FAlphaBlend curves (EAlphaBlendOption) for every blend;
##   * a montage slot (FAnimMontageInstance): BlendIn / BlendOut with DI2's per-montage times and curves, sections
##     with NextSection links (loops), segments (StartPos, AnimStartTime/EndTime, AnimPlayRate, LoopingCount), auto
##     blend-out, a new montage stopping the playing ones with its own BlendIn, and DI2's
##     AnimNotifyState_ScalePlayRate windows (rate = window length / duration, or the duration itself);
##   * slot weighting over the base pose (FAnimInstanceProxy::SlotEvaluatePose): montage weights normalised when
##     they exceed 1, the base pose filling what's left;
##   * a base layer of state-machine states with UE standard-blend transitions (CrossfadeDuration + curve);
##     a state's pose is a looping/one-shot sequence or a 1D/2D blend space (normalised-time sync to the
##     highest-weight sample, TargetWeightInterpolationSpeedPerSec);
##   * post layers (`post_layers`, objects with apply(a)) run on the composed local pose before the mesh-space
##     additives, where the zombie graph's face LayeredBoneBlend sits (zombie_anim.gd FaceLayer).

static var montages := {}
static var cover_enabled := true      # set_covered optimisation switch (perf A/B in anim_capture.gd z_perf)
static var direct_enabled := true     # _direct() optimisation switch (equivalence test in anim_capture.gd z_perf)
static var profile := false           # accumulate per-phase update() time into `prof` (anim_capture.gd z_perf)
static var prof := {"advance": 0, "accumulate": 0, "compose": 0, "post": 0, "write": 0, "n": 0}
static var graphs := {}
static var _track_cache := {}       # Animation instance id -> [pos_tracks, pos_bones, rot_tracks, rot_bones] per skeleton key

var skel: Skeleton3D
var lib: AnimationPlayer
var nb := 0
var rest_pos := PackedVector3Array()
var rest_rot: Array[Quaternion] = []
var acc_pos := PackedVector3Array()
var acc_rot: Array[Quaternion] = []
var acc_wp := PackedFloat32Array()
var acc_wr := PackedFloat32Array()
var bone_of := {}                   # bone name -> index
var states: Array = []              # base layer, oldest first: {key, src, alpha: Blend}
var slot: Array = []                # montage instances, oldest first
var playrate_durations := {}        # DIAnimInstance::AddPlayrateDuration key -> seconds (or multiplier)
var paused := false
var last_usec := 0                  # cost of the last update() (profiling)
var root_lock := -1                 # bone index whose translation stays at rest (root), -1 = none
var bone_f := PackedFloat32Array()  # per-bone weight factor of the base state being added (BlendProfile transitions)
var _bf_on := false
var order := PackedInt32Array()     # bones, parents first (mesh-space additive pass)
var parent_of := PackedInt32Array()
var debug_additive := false
var extra := {}                     # clip name -> Animation from outside the library (zombie facial clips)
var post_layers: Array = []         # apply(a: DI2Anim) after composing the local pose (before additives)
## Layered slots in graph order (inner first): slot name -> per-bone mask (1 = the slot's LayeredBoneBlend branch).
## Montages whose `layer` names a slot here blend over the composed pose on those bones only (_layered_pass).
var layer_masks := {}
## A saved pose (UE PoseSnapshot, local space) blended over the composed pose by `snapshot_w` (the zombie graph's
## RagdollPoseSnapshotName / RagdollBlendWeight: the ragdoll's last pose fading into the stand-up montage).
var snapshot_w := 0.0
var snapshot_pos := PackedVector3Array()
var snapshot_rot: Array[Quaternion] = []
## Bones a post layer overwrites in full (the zombie face at Layer_Facial 1): not accumulated or composed, since
## their result is replaced anyway (set_covered). Saves the 141 face bones' work on every zombie.
var covered := PackedByteArray()
var cover_on := false
var _compose := PackedInt32Array()  # bones composed from the accumulators (all minus covered)
var _ucache := {}                   # Animation id -> its tracks minus the covered bones
var cover_fresh := false            # covered bones lost their values (cover just turned on): rewrite them all
var cover_dirty := PackedInt32Array()  # covered bones the layer changed this frame (written to the skeleton)
var _dcache := {}                   # Animation id -> [pos tracks, pos bones, rot tracks, rot bones] for the direct path


static func load_data() -> void:
	if montages.is_empty():
		montages = Util.load_json("res://data/montages.json")
	if graphs.is_empty():
		graphs = Util.load_json("res://data/anim_graphs.json")


func _init(skeleton: Skeleton3D, library: AnimationPlayer) -> void:
	load_data()
	skel = skeleton
	lib = library
	nb = skel.get_bone_count()
	rest_pos.resize(nb)
	acc_pos.resize(nb)
	acc_wp.resize(nb)
	acc_wr.resize(nb)
	rest_rot.resize(nb)
	acc_rot.resize(nb)
	bone_f.resize(nb)
	bone_f.fill(1.0)
	for b in nb:
		var r := skel.get_bone_rest(b)
		rest_pos[b] = r.origin
		rest_rot[b] = r.basis.get_rotation_quaternion()
		bone_of[skel.get_bone_name(b)] = b
	parent_of.resize(nb)
	var depth := {}
	for b in nb:
		parent_of[b] = skel.get_bone_parent(b)
		var dd := 0
		var x := b
		while x >= 0:
			x = skel.get_bone_parent(x)
			dd += 1
		depth[b] = dd
	var ids := range(nb)
	ids.sort_custom(func(p, q): return depth[p] < depth[q])
	order = PackedInt32Array(ids)
	for b in nb:
		_compose.append(b)


## Marks the bones a post layer will overwrite in full this frame (empty = none).
func set_covered(mask: PackedByteArray) -> void:
	var on := not mask.is_empty() and cover_enabled
	if on == cover_on and (not on or mask == covered):
		return
	cover_on = on
	cover_fresh = on
	covered = mask if on else PackedByteArray()
	_ucache.clear()
	_dcache.clear()
	_compose = PackedInt32Array()
	for b in nb:
		if not on or covered[b] == 0:
			_compose.append(b)


## _tracks minus the covered bones.
func _utracks(anim: Animation) -> Array:
	var key := anim.get_instance_id()
	if _ucache.has(key):
		return _ucache[key]
	var e := _tracks(anim)
	var out := []
	for k in [0, 2, 4]:
		var tr := PackedInt32Array()
		var bn := PackedInt32Array()
		var src_t: PackedInt32Array = e[k]
		var src_b: PackedInt32Array = e[k + 1]
		for i in src_t.size():
			if covered[src_b[i]] == 0:
				tr.append(src_t[i])
				bn.append(src_b[i])
		out.append(tr)
		out.append(bn)
	_ucache[key] = out
	return out


# --- UE FAlphaBlend::AlphaToBlendOption ------------------------------------------------------------------------

static func alpha(t: float, option: String) -> float:
	t = clampf(t, 0.0, 1.0)
	match option:
		"Cubic", "HermiteCubic":
			# CubicInterp(0, 0, 1, 0, a) and SmoothStep(0, 1, a) are the same curve.
			return t * t * (3.0 - 2.0 * t)
		"Sinusoidal":
			return clampf((sin(t * PI - PI * 0.5) + 1.0) * 0.5, 0.0, 1.0)
		"QuadraticInOut":
			return _ease_in_out(t, 2.0)
		"CubicInOut":
			return _ease_in_out(t, 3.0)
		"QuarticInOut":
			return _ease_in_out(t, 4.0)
		"QuinticInOut":
			return _ease_in_out(t, 5.0)
		"CircularIn":
			return 1.0 - sqrt(maxf(0.0, 1.0 - t * t))
		"CircularOut":
			return sqrt(maxf(0.0, 1.0 - (t - 1.0) * (t - 1.0)))
		"CircularInOut":
			return (1.0 - sqrt(maxf(0.0, 1.0 - 4.0 * t * t))) * 0.5 if t < 0.5 else sqrt(maxf(0.0, 1.0 - (2.0 * t - 2.0) * (2.0 * t - 2.0))) * 0.5 + 0.5
		"ExpIn":
			return 0.0 if t <= 0.0 else pow(2.0, 10.0 * (t - 1.0))
		"ExpOut":
			return 1.0 if t >= 1.0 else 1.0 - pow(2.0, -10.0 * t)
		"ExpInOut":
			if t < 0.5:
				return 0.0 if t <= 0.0 else pow(2.0, 10.0 * (2.0 * t - 1.0)) * 0.5
			return 1.0 if t >= 1.0 else (1.0 - pow(2.0, -10.0 * (2.0 * t - 1.0))) * 0.5 + 0.5
	return t   # Linear (and Custom without a curve)


static func _ease_in_out(t: float, e: float) -> float:
	# FMath::InterpEaseInOut(0, 1, t, e)
	return pow(t * 2.0, e) * 0.5 if t < 0.5 else 1.0 - pow((1.0 - t) * 2.0, e) * 0.5


## FAlphaBlend: a weight moving from `from` to `to` over `time` seconds along a curve.
class Blend:
	var from := 0.0
	var to := 1.0
	var time := 0.0
	var t := 0.0
	var option := "HermiteCubic"
	var value := 0.0

	func _init(f := 0.0, tgt := 1.0, seconds := 0.0, opt := "HermiteCubic") -> void:
		from = f
		to = tgt
		time = seconds
		option = opt
		value = tgt if seconds <= 0.0 else f

	func advance(dt: float) -> void:
		t += dt
		value = to if time <= 0.0 or t >= time else lerpf(from, to, DI2Anim.alpha(t / time, option))

	func done() -> bool:
		return time <= 0.0 or t >= time


# --- sampling -------------------------------------------------------------------------------------------------

func _tracks(anim: Animation) -> Array:
	var key := anim.get_instance_id() * 31 + skel.get_instance_id()
	if _track_cache.has(key):
		return _track_cache[key]
	var pt := PackedInt32Array()
	var pb := PackedInt32Array()
	var rt := PackedInt32Array()
	var rb := PackedInt32Array()
	# Godot's glTF import adds a one-key track holding the rest pose for every bone the clip doesn't key; for an
	# additive clip that rest rotation is not a delta, so those filler tracks are listed separately.
	var at := PackedInt32Array()
	var ab := PackedInt32Array()
	for i in anim.get_track_count():
		var bone := str(anim.track_get_path(i).get_concatenated_subnames())
		if not bone_of.has(bone):
			continue
		var b: int = bone_of[bone]
		match anim.track_get_type(i):
			Animation.TYPE_POSITION_3D:
				pt.append(i)
				pb.append(b)
			Animation.TYPE_ROTATION_3D:
				rt.append(i)
				rb.append(b)
				var filler: bool = anim.track_get_key_count(i) == 1 and anim.rotation_track_interpolate(i, 0.0).is_equal_approx(rest_rot[b])
				if not filler:
					at.append(i)
					ab.append(b)
	var e := [pt, pb, rt, rb, at, ab]
	_track_cache[key] = e
	return e


func has_clip(name: String) -> bool:
	return name != "" and (extra.has(name) or lib.has_animation(name) or lib.has_animation(_imported(name)))


func clip(name: String) -> Animation:
	return extra[name] if extra.has(name) else lib.get_animation(name if lib.has_animation(name) else _imported(name))


## Godot's scene importer drops a "_loop" / "-loop" name suffix (and sets the loop mode instead), so DI2's clip names
## such as scream_loop or paired_counter_loop are stored without it. Map DI2's name to the stored one.
static func _imported(name: String) -> String:
	return name.left(-5) if name.to_lower().ends_with("_loop") or name.to_lower().ends_with("-loop") else name


func clip_len(name: String) -> float:
	return clip(name).length if has_clip(name) else 0.0


## Adds `w` x clip `name` at `time` to the accumulation buffers. `ref_root`: the clip gives its root motion to the
## capsule, so its root bone poses at the reference pose (UAnimSequence::ResetRootBoneForRootMotion, RootMotionRootLock
## RefPose) instead of the clip's frame 0 that merge_anims holds it at (= AnimFirstFrame).
func add(name: String, time: float, w: float, ref_root := false) -> void:
	if w <= 1e-5 or not has_clip(name):
		return
	var anim := clip(name)
	var e := _utracks(anim) if cover_on else _tracks(anim)
	var rb0: int = bone_of.get("root", -1) if ref_root else -1
	var pt: PackedInt32Array = e[0]
	var pb: PackedInt32Array = e[1]
	for i in pt.size():
		var b := pb[i]
		var wb := w * bone_f[b] if _bf_on else w
		acc_pos[b] += (rest_pos[b] if b == rb0 else anim.position_track_interpolate(pt[i], time)) * wb
		acc_wp[b] += wb
	var rt: PackedInt32Array = e[2]
	var rb: PackedInt32Array = e[3]
	for i in rt.size():
		var b := rb[i]
		var wb := w * bone_f[b] if _bf_on else w
		var q := rest_rot[b] if b == rb0 else anim.rotation_track_interpolate(rt[i], time)
		if acc_rot[b].dot(q) < 0.0:
			q = -q
		acc_rot[b] += q * wb
		acc_wr[b] += wb


# --- base layer (state machine) ---------------------------------------------------------------------------------

## A looping or one-shot sequence player.
class Seq:
	var clip := ""
	var time := 0.0
	var rate := 1.0
	var loop := true
	var length := 0.0

	func _init(c: String, len_s: float, looping := true, r := 1.0, start := 0.0) -> void:
		clip = c
		length = len_s
		loop = looping
		rate = r
		time = start

	func advance(dt: float) -> void:
		time += dt * rate
		if loop and length > 0.0:
			time = fposmod(time, length)
		else:
			time = clampf(time, 0.0, length)

	func contribute(a: DI2Anim, w: float) -> void:
		a.add(clip, time, w)

	func finished() -> bool:
		return not loop and time >= length - 1e-4


## UE BlendSpace / BlendSpace1D player: per-sample target weights from the input (with the asset's exported
## GridSamples: UE 4.27 GetRawSamplesFromBlendInput, bilinear over the grid; without: 1D linear between the two
## neighbouring samples, 2D an inverse-distance stand-in), moved towards the targets at
## TargetWeightInterpolationSpeedPerSec. Synced players follow the highest-weight sample's clip time; `unsynced`
## players (no sync group: the zombie Start / Stop / TurnOnSpot nodes) advance normalised time by
## dt / sum(w_i * len_i / rate_i) (UBlendSpaceBase::GetAnimationLengthFromSampleData; exe FUN_1411502d0).
class BS:
	var samples: Array = []         # [[clip, x, y, rate_scale, length]]
	var weights := PackedFloat32Array()
	var speed := 0.0
	var x := 0.0
	var y := 0.0
	var phase := 0.0
	var two_d := false
	var started := false
	var unsynced := false
	var loop := true                # unsynced only: false holds the last frame (one-shot Start / Stop / TurnOnSpot)
	var grid: Array = []            # GridSamples: per grid point up to 3 [source sample index, weight]
	var axes: Array = []            # [{min, max, grid}] X (, Y)
	var local_of := {}              # source sample index -> index in `samples` (missing clips are skipped)
	var markers: Array = []         # synced only: per sample its sync markers [[time, name], ...] (time order) or []
	var mtime := {}                 # synced with markers: sample index -> its marker-synced time (s)

	func _init(a: DI2Anim, data: Dictionary, clips: Array = []) -> void:
		speed = float(data.get("weight_speed", 0.0))
		two_d = data.get("type", "") == "BlendSpace"
		grid = data.get("grid", [])
		axes = data.get("axes", [])
		var src: Array = data["samples"]
		for i in src.size():
			var s: Array = src[i]
			var clip: String = clips[i] if i < clips.size() else str(s[0])
			if clip == "" or not a.has_clip(clip):
				continue
			local_of[i] = samples.size()
			samples.append([clip, float(s[1]), float(s[2]), float(s[3]), a.clip_len(clip)])
		weights.resize(samples.size())

	## UE 4.27 UBlendSpaceBase::GetRawSamplesFromBlendInput: clamp to the axis range, n = (v - min) / cell, bilinear
	## over the 4 surrounding grid points (element X * (GridNumY + 1) + Y; out of range skipped), sum per sample,
	## drop weights below ZERO_ANIMWEIGHT_THRESH (1e-5), normalise.
	func _grid_targets() -> PackedFloat32Array:
		var t := PackedFloat32Array()
		t.resize(samples.size())
		var ax: Dictionary = axes[0]
		var nx := int(ax["grid"])
		var fx := (clampf(x, float(ax["min"]), float(ax["max"])) - float(ax["min"])) / ((float(ax["max"]) - float(ax["min"])) / nx)
		var ny := 0
		var fy := 0.0
		if two_d and axes.size() > 1:
			var ay: Dictionary = axes[1]
			ny = int(ay["grid"])
			fy = (clampf(y, float(ay["min"]), float(ay["max"])) - float(ay["min"])) / ((float(ay["max"]) - float(ay["min"])) / ny)
		var ix := floori(fx)
		var iy := floori(fy)
		var rx := fx - ix
		var ry := fy - iy
		var corners := [[ix, iy, (1.0 - rx) * (1.0 - ry)], [ix + 1, iy, rx * (1.0 - ry)],
			[ix, iy + 1, (1.0 - rx) * ry], [ix + 1, iy + 1, rx * ry]]
		for c: Array in corners:
			var gx: int = c[0]
			var gy: int = c[1]
			if c[2] <= 0.0 or gx < 0 or gx > nx or gy < 0 or gy > ny:
				continue
			var e := gx * (ny + 1) + gy
			if e >= grid.size():
				continue
			for p: Array in grid[e]:
				var li: int = local_of.get(int(p[0]), -1)
				if li >= 0:
					t[li] += float(p[1]) * float(c[2])
		var total := 0.0
		for i in t.size():
			if t[i] < 1e-5:
				t[i] = 0.0
			total += t[i]
		if total > 0.0:
			for i in t.size():
				t[i] /= total
		return t

	## Seconds one normalised cycle takes at the current weights (FUN_1411502d0).
	func length_now() -> float:
		var l := 0.0
		for i in samples.size():
			if weights[i] > 0.0 and float(samples[i][3]) > 0.0:
				l += weights[i] * float(samples[i][4]) / float(samples[i][3])
		return l

	func targets() -> PackedFloat32Array:
		var t := PackedFloat32Array()
		t.resize(samples.size())
		if samples.is_empty():
			return t
		if not grid.is_empty() and not axes.is_empty():
			return _grid_targets()
		if not two_d:
			var lo := -1
			var hi := -1
			for i in samples.size():
				var sx: float = samples[i][1]
				if sx <= x and (lo < 0 or sx > float(samples[lo][1])):
					lo = i
				if sx >= x and (hi < 0 or sx < float(samples[hi][1])):
					hi = i
			if lo < 0:
				lo = hi
			if hi < 0:
				hi = lo
			if lo == hi:
				t[lo] = 1.0
			else:
				var f := (x - float(samples[lo][1])) / (float(samples[hi][1]) - float(samples[lo][1]))
				t[lo] = 1.0 - f
				t[hi] = f
			return t
		# 2D: inverse-distance over the three nearest samples (stand-in for UE's grid triangulation, which isn't
		# exported; recon/ANIMATION.md UNVERIFIED).
		var near: Array = []
		for i in samples.size():
			var d := Vector2(float(samples[i][1]) / 180.0, float(samples[i][2]) / 240.0).distance_to(Vector2(x / 180.0, y / 240.0))
			near.append([d, i])
		near.sort_custom(func(p, q): return p[0] < q[0])
		if near[0][0] < 1e-4:
			t[near[0][1]] = 1.0
			return t
		var sum := 0.0
		for k in mini(3, near.size()):
			sum += 1.0 / near[k][0]
		for k in mini(3, near.size()):
			t[near[k][1]] = (1.0 / near[k][0]) / sum
		return t

	func advance(dt: float) -> void:
		var tg := targets()
		if speed > 0.0 and started:
			var total := 0.0
			for i in weights.size():
				weights[i] = move_toward(weights[i], tg[i], speed * dt)
				total += weights[i]
			if total > 1e-5:
				for i in weights.size():
					weights[i] /= total
		else:
			weights = tg
		started = true
		var lead := 0
		for i in weights.size():
			if weights[i] > weights[lead]:
				lead = i
		if samples.is_empty():
			return
		if unsynced:
			var tl := length_now()
			if tl > 0.0:
				phase = fposmod(phase + dt / tl, 1.0) if loop else minf(phase + dt / tl, 1.0)
			return
		var ll: float = samples[lead][4]
		if ll > 0.0:
			phase = fposmod(phase + dt * float(samples[lead][3]) / ll, 1.0)
		_marker_sync(lead)

	## UE 4.27 marker-based sync inside the blend space (UBlendSpaceBase::TickAssetPlayer with markers): the heaviest
	## sample leads on its own clock; every other weighted sample with markers takes the leader's position between its
	## previous and next marker (FMarkerSyncAnimPosition: names + fraction) at the same fraction between its own pair of
	## those markers, the occurrence nearest ahead of its last time. Samples without markers keep normalised sync.
	func _marker_sync(lead: int) -> void:
		mtime = {}
		if markers.size() != samples.size() or (markers[lead] as Array).size() < 2:
			return
		var lm: Array = markers[lead]
		var ll: float = samples[lead][4]
		var lt := phase * ll
		var k := -1
		for j in lm.size():
			if float(lm[j][0]) <= lt:
				k = j
		var pk := k if k >= 0 else lm.size() - 1
		var nk := (pk + 1) % lm.size()
		var tp: float = float(lm[pk][0]) - (ll if k < 0 else 0.0)
		var tn: float = float(lm[nk][0]) + (ll if nk <= pk and k >= 0 else 0.0)
		var alpha := (lt - tp) / (tn - tp) if tn > tp else 0.0
		var pn: String = lm[pk][1]
		var nn: String = lm[nk][1]
		for i in samples.size():
			if i == lead or i >= weights.size() or weights[i] <= 1e-4 or (markers[i] as Array).size() < 2:
				continue
			var fm: Array = markers[i]
			var fl: float = samples[i][4]
			var prev_t: float = _last.get(i, phase * fl)
			var best := -1.0
			var best_d := INF
			for j in fm.size():
				var j1 := (j + 1) % fm.size()
				if fm[j][1] != pn or fm[j1][1] != nn:
					continue
				var a0: float = fm[j][0]
				var a1: float = float(fm[j1][0]) + (fl if j1 <= j else 0.0)
				var t := fposmod(a0 + alpha * (a1 - a0), fl)
				var d := fposmod(t - prev_t, fl)
				if d < best_d:
					best_d = d
					best = t
			if best >= 0.0:
				mtime[i] = best
		_last = mtime.duplicate()

	var _last := {}

	## Sample `i`'s play time (s): marker-synced when it has a match, else the shared normalised phase.
	func sample_time(i: int) -> float:
		return float(mtime[i]) if mtime.has(i) else phase * float(samples[i][4])

	func contribute(a: DI2Anim, w: float) -> void:
		for i in samples.size():
			if weights[i] > 1e-4:
				a.add(samples[i][0], sample_time(i), w * weights[i])

	func finished() -> bool:
		return false


## Switches the base layer to `key` (a state-machine state), crossfading over `seconds` with `option` like UE's
## standard transition blend. The previous output keeps evaluating under the blend.
## `bprofile`: the transition's BlendProfile as {bone index: BlendScale} ({} = none).
func set_state(key: String, src, seconds: float, option: String, bprofile := {}) -> void:
	if not states.is_empty() and states[-1]["key"] == key:
		return
	var b := Blend.new(0.0, 1.0, seconds if not states.is_empty() else 0.0, option)
	states.append({"key": key, "src": src, "alpha": b, "bprofile": bprofile})


func state_key() -> String:
	return states[-1]["key"] if not states.is_empty() else ""


func state_src():
	return states[-1]["src"] if not states.is_empty() else null


# --- montage slot -------------------------------------------------------------------------------------------------

class Montage:
	var name := ""
	var d: Dictionary
	var pos := 0.0
	var play_rate := 1.0
	var weight: Blend
	var stopped := false
	var segs: Array = []
	var sections: Array = []
	var length := 0.0
	var windows: Array = []           # [key, start, end, by_length]
	var owner_anim: DI2Anim
	var group := "DefaultGroup"       # skeleton slot group: Montage_Play only stops montages of its own group
	var additive := false             # AdditiveArms* slots: applied as a mesh-space rotation additive
	var layer := ""                   # zombie layered hit-react slot (LHR_UpperBody / LHR_FullBody): _layered_pass
	## Segment clip -> its sequence's RootMotionRootLock for clips whose root motion goes to the capsule (set by the
	## owner, e.g. ZombieAnim._rm_flag); "RefPose" clips pose the root bone at the reference pose (add(ref_root)).
	## `rm_set`: the owner has decided.
	var ref_root := {}
	var rm_set := false
	## Montage to start the moment this one starts blending out (UE: Montage_Play from OnMontageBlendingOut),
	## in the same update, so a zero-time BlendOut / BlendIn pair (DI2's dodges) hands over without a frame of the
	## base pose: {name, d, rate, start, cb}.
	var next_play: Dictionary = {}

	func section_at(p: float) -> int:
		var best := 0
		for i in sections.size():
			if float(sections[i][1]) <= p + 1e-5:
				best = i
		return best

	func section_end(i: int) -> float:
		return float(sections[i + 1][1]) if i + 1 < sections.size() else length

	func next_section(i: int) -> int:
		var nx = sections[i][2]
		if nx == null or str(nx) == "" or str(nx) == "None":
			return -1
		var want := str(nx).to_lower()   # FName: case-insensitive (DI2's Shoot montage links "Shoot" -> "OUt")
		for j in sections.size():
			if str(sections[j][0]).to_lower() == want:
				return j
		return -1

	## DI2 AnimNotifyState_ScalePlayRate: inside a window the instance PlayRate is (window length / duration) or the
	## duration itself (bScaleByNotifyLength false); the notify's end sets it back to 1 (exe 0x14113e6b0 /
	## 0x141140130). A key without a registered duration leaves the rate alone.
	func rate_at(p: float) -> float:
		var ended := false
		for w in windows:
			var v = owner_anim.playrate_durations.get(w[0])
			if v == null or float(v) <= 0.0:
				continue
			if p >= float(w[1]) - 1e-5 and p < float(w[2]) - 1e-5:
				return (float(w[2]) - float(w[1])) / float(v) if w[3] else float(v)
			if p >= float(w[2]) - 1e-5:
				ended = true
		return 1.0 if ended else play_rate

	func advance(dt: float) -> void:
		weight.advance(dt)
		var remaining := dt
		for _i in 16:
			if remaining <= 0.0:
				break
			var si := section_at(pos)
			var end := section_end(si)
			var r := maxf(rate_at(pos), 1e-4)
			if pos + remaining * r < end - 1e-6:
				pos += remaining * r
				break
			remaining -= (end - pos) / r
			var nx := next_section(si)
			if nx < 0:
				pos = end
				break
			if nx == si and end - float(sections[si][1]) < 1e-3:
				pos = float(sections[si][1])   # a zero-length loop section holds its pose
				break
			pos = float(sections[nx][1])
		_auto_blend_out()

	## FAnimMontageInstance auto blend-out: in a section with no next section, once the time left reaches the
	## BlendOut time (or BlendOutTriggerTime), blend out so it ends with the montage.
	func _auto_blend_out() -> void:
		if stopped or not bool(d.get("auto_blend_out", true)):
			return
		var si := section_at(pos)
		if next_section(si) >= 0:
			return
		var bo: Array = d.get("blend_out", [0.1, "HermiteCubic"])
		var trig: float = float(d.get("blend_out_trigger", -1.0))
		var left := length - pos
		var custom := trig >= 0.0
		if left <= maxf(trig if custom else float(bo[0]), 1e-4):
			stop(float(bo[0]) if custom else left, str(bo[1]))

	func stop(seconds: float, option: String) -> void:
		if stopped:
			return
		stopped = true
		weight = Blend.new(weight.value, 0.0, seconds, option)

	func dead() -> bool:
		return stopped and weight.done()

	## The clip + clip time this montage shows at `p` (segment StartPos, AnimStartTime/EndTime, PlayRate, loops).
	func sample(p: float) -> Array:
		var pick: Array = segs[-1] if not segs.is_empty() else []
		for s: Array in segs:
			var span := (float(s[3]) - float(s[2])) / maxf(absf(float(s[4])), 1e-4) * maxi(1, int(s[5]))
			if p < float(s[1]) + span - 1e-6:
				pick = s
				break
		if pick.is_empty():
			return ["", 0.0]
		var rate := float(pick[4])
		var seg_len := float(pick[3]) - float(pick[2])
		var local := maxf(0.0, p - float(pick[1])) * absf(rate)
		if int(pick[5]) > 1 and seg_len > 0.0:
			local = fposmod(local, seg_len) if local < seg_len * int(pick[5]) else seg_len
		local = minf(local, seg_len)
		return [pick[0], float(pick[3]) - local if rate < 0.0 else float(pick[2]) + local]

	func contribute(a: DI2Anim, w: float) -> void:
		var s := sample(pos)
		a.add(s[0], s[1], w, ref_root.get(s[0], "") == "RefPose")

	func current_clip() -> String:
		return sample(pos)[0]


## UAnimInstance::Montage_Play: every playing montage blends out with the new montage's BlendIn (UE4.27
## StopAllMontagesByGroupName), the new instance blends in from 0 with it.
func play_montage(name: String, rate := 1.0, start := 0.0) -> Montage:
	var d: Dictionary = montages.get(name, {})
	return _play(name, d, rate, start) if not d.is_empty() else null


## A bare clip played like a montage, for the few 1P actions this port has no DI2 montage for (level-sequence
## pairs, legacy dani_fp clips). Default blends = DI2's montage default (0.1 s HermiteCubic, exe 0x1434b3ee0).
func play_clip(clip: String, rate := 1.0, blend_in := 0.1, blend_out := 0.1, option := "HermiteCubic") -> Montage:
	if not has_clip(clip):
		return null
	var length := clip_len(clip)
	var d := {"length": length, "blend_in": [blend_in, option], "blend_out": [blend_out, option],
		"blend_out_trigger": -1.0, "auto_blend_out": true, "sections": [["Default", 0.0, null]],
		"segments": [[clip, 0.0, 0.0, length, 1.0, 1]], "rate": []}
	return _play("clip:" + clip, d, rate, 0.0)


## Montage_Play with montage data given directly (zombie montages per body).
func play_data(name: String, d: Dictionary, rate := 1.0, start := 0.0) -> Montage:
	return _play(name, d, rate, start)


func _play(name: String, d: Dictionary, rate: float, start: float) -> Montage:
	var bi: Array = d.get("blend_in", [0.1, "HermiteCubic"])
	var grp := str(d.get("group", "DefaultGroup"))
	for m: Montage in slot:
		if m.group == grp:
			m.stop(float(bi[0]), str(bi[1]))
	var m := Montage.new()
	m.group = grp
	m.additive = bool(d.get("additive", false))
	m.layer = str(d.get("layer", ""))
	m.name = name
	m.d = d
	m.owner_anim = self
	m.length = float(d["length"])
	m.segs = d["segments"]
	m.sections = d["sections"] if not d["sections"].is_empty() else [["Default", 0.0, null]]
	m.windows = d.get("rate", [])
	m.play_rate = rate
	m.pos = clampf(start, 0.0, m.length)
	m.weight = Blend.new(0.0, 1.0, float(bi[0]), str(bi[1]))
	slot.append(m)
	return m


## Queues montage `name` (data/montages.json) to start when `m` starts blending out; `cb` gets the new instance.
func play_after(m: Montage, name: String, rate := 1.0, start := 0.0, cb: Callable = Callable()) -> bool:
	var d: Dictionary = montages.get(name, {})
	if m == null or d.is_empty():
		return false
	m.next_play = {"name": name, "d": d, "rate": rate, "start": start, "cb": cb}
	return true


func stop_montages(seconds: float, option := "HermiteCubic") -> void:
	for m: Montage in slot:
		m.stop(seconds, option)


## The newest montage of `group` that is not blending out (UE Montage_IsActive / GetCurrentActiveMontage), or null.
func active(group := "DefaultGroup") -> Montage:
	for i in range(slot.size() - 1, -1, -1):
		if not slot[i].stopped and slot[i].group == group:
			return slot[i]
	return null


func montage_weight() -> float:
	var w := 0.0
	for m: Montage in slot:
		if not m.additive and m.layer == "":
			w += m.weight.value
	return w


# --- evaluation ----------------------------------------------------------------------------------------------

func update(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	if paused:
		dt = 0.0
	for e: Dictionary in states:
		e["alpha"].advance(dt)
		e["src"].advance(dt)
	# Drop states fully covered by a newer one that finished blending in.
	for i in range(states.size() - 1, 0, -1):
		if states[i]["alpha"].done():
			states = states.slice(i)
			break
	for m: Montage in slot.duplicate():
		var was_stopped := m.stopped
		m.advance(dt)
		if m.stopped and not was_stopped and not m.next_play.is_empty():
			var np := m.next_play
			m.next_play = {}
			var nm := _play(np["name"], np["d"], np["rate"], np["start"])
			if np["cb"] is Callable and (np["cb"] as Callable).is_valid():
				(np["cb"] as Callable).call(nm)
	slot = slot.filter(func(m): return not m.dead())
	if profile:
		prof["advance"] += Time.get_ticks_usec() - t0
		prof["n"] += 1
	evaluate()
	last_usec = Time.get_ticks_usec() - t0


func evaluate() -> void:
	var t0 := Time.get_ticks_usec() if profile else 0
	var mw := montage_weight()
	if direct_enabled and mw <= 1e-5 and states.size() == 1 and states[0]["src"] is Seq:
		_direct(states[0]["src"])
		_finish(t0, Time.get_ticks_usec() if profile else 0)
		return
	if cover_on:
		for b in _compose:   # covered bones keep their last values (the layer rewrites only what changes)
			acc_pos[b] = Vector3.ZERO
			acc_rot[b] = Quaternion(0, 0, 0, 0)
	else:
		acc_pos.fill(Vector3.ZERO)
		for b in nb:
			acc_rot[b] = Quaternion(0, 0, 0, 0)
	acc_wp.fill(0.0)
	acc_wr.fill(0.0)
	var base_scale := 1.0 - minf(mw, 1.0)
	var mon_scale := 1.0 / mw if mw > 1.0 else 1.0
	# Montages first so their rotations set the hemisphere reference where they dominate.
	for m: Montage in slot:
		if not m.additive and m.layer == "":
			m.contribute(self, m.weight.value * mon_scale)
	if base_scale > 1e-5:
		var scale := 1.0
		var bscale := {}   # bone -> its own running scale once a newer transition's BlendProfile names it
		for i in range(states.size() - 1, -1, -1):
			var a: float = states[i]["alpha"].value if i > 0 else 1.0
			var bp: Dictionary = states[i].get("bprofile", {}) if i > 0 else {}
			for b: int in bp:
				if not bscale.has(b):
					bscale[b] = scale
			_bf_on = not bscale.is_empty()
			for b: int in bscale:
				# DI2's transition with a BlendProfile (state machine 0x1434dba80, BlendListBase 0x143099750): next pose
				# Alpha x BlendScale, previous (1 - Alpha) / BlendScale, normalised per bone (0x143514480).
				var ab := a
				if bp.has(b):
					var s2: float = float(bp[b]) * float(bp[b])
					ab = a * s2 / (a * s2 + 1.0 - a) if a * s2 + 1.0 - a > 1e-9 else a
				var w := scale * a
				bone_f[b] = float(bscale[b]) * ab / w if w > 1e-9 else 0.0
				bscale[b] = float(bscale[b]) * (1.0 - ab)
			states[i]["src"].contribute(self, base_scale * scale * a)
			scale *= 1.0 - a
			if scale <= 1e-5 and bscale.values().all(func(v): return v <= 1e-5):
				break
		if _bf_on:
			bone_f.fill(1.0)
			_bf_on = false
	var t1 := Time.get_ticks_usec() if profile else 0
	for b in _compose:
		var p := acc_pos[b]
		var wp := acc_wp[b]
		if wp < 1.0:
			p += rest_pos[b] * (1.0 - wp)
		elif wp > 1.0 + 1e-4:
			p /= wp
		var q := acc_rot[b]
		var wr := acc_wr[b]
		if wr < 1.0:
			var r := rest_rot[b]
			if q.dot(r) < 0.0:
				r = -r
			q += r * (1.0 - wr)
		q = q.normalized() if q.length_squared() > 1e-12 else rest_rot[b]
		if b == root_lock:
			p = rest_pos[b]
		acc_pos[b] = p
		acc_rot[b] = q
	_finish(t0, t1)


## Post layers, mesh-space additives and the skeleton write (the end of evaluate()).
func _finish(t0: int, t1: int) -> void:
	var t2 := Time.get_ticks_usec() if profile else 0
	if not layer_masks.is_empty():
		for ln: String in layer_masks:
			_layered_pass(ln)
	if snapshot_w > 1e-4 and snapshot_pos.size() == nb:
		for b in _compose:
			var q := snapshot_rot[b]
			if acc_rot[b].dot(q) < 0.0:
				q = -q
			acc_pos[b] = acc_pos[b].lerp(snapshot_pos[b], snapshot_w)
			acc_rot[b] = (acc_rot[b] * (1.0 - snapshot_w) + q * snapshot_w).normalized()
	for l in post_layers:
		l.apply(self)
	var additive_on := false
	for m: Montage in slot:
		if m.additive and m.weight.value > 1e-4:
			_apply_mesh_rotation_additive(m, m.weight.value)
			additive_on = true
	var t3 := Time.get_ticks_usec() if profile else 0
	if cover_on and not additive_on:
		# Covered bones keep their skeleton pose unless their layer changed them (cover_dirty).
		for b in _compose:
			skel.set_bone_pose_position(b, acc_pos[b])
			skel.set_bone_pose_rotation(b, acc_rot[b])
		for b in cover_dirty:
			skel.set_bone_pose_position(b, acc_pos[b])
			skel.set_bone_pose_rotation(b, acc_rot[b])
	else:
		for b in nb:
			skel.set_bone_pose_position(b, acc_pos[b])
			skel.set_bone_pose_rotation(b, acc_rot[b])
	cover_dirty.clear()
	if profile:
		var t4 := Time.get_ticks_usec()
		prof["accumulate"] += t1 - t0
		prof["compose"] += t2 - t1
		prof["post"] += t3 - t2
		prof["write"] += t4 - t3


## A layered montage slot over the composed pose (ABP_ZombieWalker "LayeredHitReactions": Slot LHR_UpperBody under a
## LayeredBoneBlend on spine_01 depth 0, weight 1, local space; Slot LHR_FullBody over that): the slot's montages
## make one pose (weights normalised to 1, unkeyed bones at the reference pose, FAnimInstanceProxy::SlotEvaluatePose)
## that replaces the masked bones by the slot weight min(sum of weights, 1). Covered bones are left to their layer.
func _layered_pass(layer_name: String) -> void:
	var ms: Array = []
	var total := 0.0
	for m: Montage in slot:
		if m.layer == layer_name and m.weight.value > 1e-4:
			ms.append(m)
			total += m.weight.value
	if ms.is_empty():
		return
	var mask: PackedByteArray = layer_masks[layer_name]
	var base_p := acc_pos.duplicate()
	var base_r: Array[Quaternion] = acc_rot.duplicate()
	for b in _compose:
		acc_pos[b] = Vector3.ZERO
		acc_rot[b] = Quaternion(0, 0, 0, 0)
		acc_wp[b] = 0.0
		acc_wr[b] = 0.0
	for m: Montage in ms:
		m.contribute(self, m.weight.value / total)
	var a := minf(total, 1.0)
	for b in _compose:
		if mask[b] == 0:
			acc_pos[b] = base_p[b]
			acc_rot[b] = base_r[b]
			continue
		var p := acc_pos[b]
		if acc_wp[b] < 1.0:
			p += rest_pos[b] * (1.0 - acc_wp[b])
		var q := acc_rot[b]
		if acc_wr[b] < 1.0:
			var r := rest_rot[b]
			if q.dot(r) < 0.0:
				r = -r
			q += r * (1.0 - acc_wr[b])
		q = q.normalized() if q.length_squared() > 1e-12 else rest_rot[b]
		var bq := base_r[b]
		if bq.dot(q) < 0.0:
			q = -q
		acc_pos[b] = base_p[b].lerp(p, a)
		acc_rot[b] = (bq * (1.0 - a) + q * a).normalized()
		if b == root_lock:
			acc_pos[b] = rest_pos[b]


## The whole pose is one sequence at full weight (no montage, one base state): sample it straight into the pose -
## the same result as accumulating it at weight 1 (bones it doesn't key, and Godot's one-key rest fillers, = rest).
func _direct(src: Seq) -> void:
	var anim := clip(src.clip)
	if anim == null:
		return
	var key := anim.get_instance_id()
	var d: Array = _dcache.get(key, [])
	if d.is_empty():
		var e := _utracks(anim) if cover_on else _tracks(anim)
		d = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
		for k in [0, 2]:
			var tr: PackedInt32Array = e[k]
			var bn: PackedInt32Array = e[k + 1]
			for i in tr.size():
				var b := bn[i]
				if anim.track_get_key_count(tr[i]) == 1:
					var v = anim.position_track_interpolate(tr[i], 0.0) if k == 0 else anim.rotation_track_interpolate(tr[i], 0.0)
					if (k == 0 and (v as Vector3).is_equal_approx(rest_pos[b])) or (k == 2 and (v as Quaternion).is_equal_approx(rest_rot[b])):
						continue
				d[k].append(tr[i])
				d[k + 1].append(b)
		_dcache[key] = d
	for b in _compose:
		acc_pos[b] = rest_pos[b]
		acc_rot[b] = rest_rot[b]
	var t := src.time
	var pt: PackedInt32Array = d[0]
	var pb: PackedInt32Array = d[1]
	for i in pt.size():
		acc_pos[pb[i]] = anim.position_track_interpolate(pt[i], t)
	var rt: PackedInt32Array = d[2]
	var rb: PackedInt32Array = d[3]
	for i in rt.size():
		acc_rot[rb[i]] = anim.rotation_track_interpolate(rt[i], t).normalized()
	if root_lock >= 0:
		acc_pos[root_lock] = rest_pos[root_lock]


## FAnimationRuntime::AccumulateMeshSpaceRotationAdditiveToLocalPose for an AAT_RotationOffsetMeshSpace montage:
## the pose's rotations go to mesh space, each keyed bone's mesh rotation is pre-multiplied by its delta (slerped
## from identity by the weight, FTransform::BlendFromIdentityAndAccumulate), and the pose goes back to local
## space. Additive translation deltas are not applied (recon/ANIMATION.md).
func _apply_mesh_rotation_additive(m: Montage, w: float) -> void:
	var s := m.sample(m.pos)
	if not has_clip(s[0]):
		return
	var anim := clip(s[0])
	var e := _tracks(anim)
	var rt: PackedInt32Array = e[4]
	var rb: PackedInt32Array = e[5]
	var delta := {}
	for i in rt.size():
		var q := anim.rotation_track_interpolate(rt[i], s[1])
		delta[rb[i]] = Quaternion.IDENTITY.slerp(q.normalized(), w) if w < 1.0 else q.normalized()
	if delta.is_empty():
		return
	var mesh: Array[Quaternion] = []
	mesh.resize(nb)
	for b in order:
		var pq := parent_of[b]
		mesh[b] = (mesh[pq] * acc_rot[b]) if pq >= 0 else acc_rot[b]
	var mesh_new: Array[Quaternion] = mesh.duplicate()
	for b: int in delta:
		mesh_new[b] = (delta[b] * mesh[b]).normalized()
	var before := acc_rot.duplicate() if debug_additive else []
	for b in order:
		var pq := parent_of[b]
		acc_rot[b] = (mesh_new[pq].inverse() * mesh_new[b]).normalized() if pq >= 0 else mesh_new[b]
	if debug_additive:
		var ch := []
		for b in nb:
			var ang := rad_to_deg(before[b].angle_to(acc_rot[b]))
			if ang > 2.0:
				ch.append("%s %.1f%s" % [skel.get_bone_name(b), ang, " (keyed)" if delta.has(b) else ""])
		print("ADDITIVE %s t=%.3f changed: %s" % [s[0], s[1], ", ".join(ch.slice(0, 25))])
		debug_additive = false
