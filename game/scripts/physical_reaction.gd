class_name PhysicalReaction
extends SkeletonModifier3D
## DI2 hit impacts. PA_ZombieStandard's PhysicalAnimation profiles drive every physics body back to the animated
## pose with acceleration springs (stiffness = OrientationStrength, damping = AngularVelocityStrength). A hit spins
## the struck body away from the blow; the joints hand part of it to the parents, the children lag behind it, and
## each body then springs back with DI2's own values: stiff spine (900/90), firm limbs (500/50), and in the
## Reaction profile a loose head (200/20) and floppy hands (112/12), which gives the strike its flesh-and-bone feel.

const SUBSTEPS := 4
const MAX_SPIN := 18.0      # rad/s added by one blow
const MAX_ANGLE := 1.1      # rad, keeps a stack of hits from folding a bone over

static var spec: Dictionary = {}

var profile := "Reaction"
var bones: Array[int] = []           # simulated bones, parents before children
var parent_of := {}                  # bone -> nearest simulated ancestor (or -1)
var children_of := {}                # bone -> simulated children
var stiffness := {}                  # bone -> OrientationStrength
var damping := {}                    # bone -> AngularVelocityStrength
var mass := {}
var angle := {}                      # bone -> rotation vector (skeleton space) added on top of the animation
var spin := {}                       # bone -> angular velocity (skeleton space)
var awake := 0.0
var peak := 0.0                      # largest reaction angle since the last reset (radians), for tests/debug
var _last_ms := 0


static func load_spec() -> Dictionary:
	if spec.is_empty():
		spec = JSON.parse_string(FileAccess.get_file_as_string("res://data/ragdoll_zombie_standard.json"))
	return spec


func _ready() -> void:
	var skel := get_skeleton()
	var by_bone := {}
	for b: Dictionary in load_spec()["bodies"]:
		var i := skel.find_bone(b["bone"])
		if i < 0 or b["kinematic"]:
			continue
		by_bone[i] = b
	var ids: Array = by_bone.keys()
	ids.sort_custom(func(a, b): return _depth(skel, a) < _depth(skel, b))
	for i: int in ids:
		bones.append(i)
		var b: Dictionary = by_bone[i]
		set_profile_values(i, b)
		mass[i] = maxf(0.5, float(b["mass"]))
		angle[i] = Vector3.ZERO
		spin[i] = Vector3.ZERO
		children_of[i] = []
		var p := skel.get_bone_parent(i)
		while p >= 0 and not by_bone.has(p):
			p = skel.get_bone_parent(p)
		parent_of[i] = p
		if p >= 0:
			children_of[p].append(i)


func set_profile_values(i: int, b: Dictionary) -> void:
	var pr: Array = b["profiles"].get(profile, b["profiles"].get("Default", [500.0, 50.0, false]))
	stiffness[i] = float(pr[0])
	damping[i] = float(pr[1])


func _depth(skel: Skeleton3D, bone: int) -> int:
	var d := 0
	while bone >= 0:
		bone = skel.get_bone_parent(bone)
		d += 1
	return d


## The simulated body a hit on `bone` lands on: the bone itself, else its first simulated child, else an ancestor.
func body_for(bone: int) -> int:
	if stiffness.has(bone):
		return bone
	var skel := get_skeleton()
	for c in skel.get_bone_children(bone):
		if stiffness.has(c):
			return c
	var p := skel.get_bone_parent(bone)
	while p >= 0 and not stiffness.has(p):
		p = skel.get_bone_parent(p)
	return p


## A blow of `force` (DI2 force units: bat 25, kick 30) along `push` landing at world `point` on `bone_name`.
func hit(bone_name: String, point: Vector3, push: Vector3, force: float) -> void:
	var skel := get_skeleton()
	var b := body_for(skel.find_bone(bone_name))
	if b < 0 or push.length() < 1e-4:
		return
	var to_skel := skel.global_transform.affine_inverse()
	var p := to_skel * point
	var j := (to_skel.basis * push).normalized() * force
	var origin := skel.get_bone_global_pose(b).origin
	var r := p - origin
	if r.length() < 0.03:
		r = (skel.get_bone_global_pose(b).basis * Vector3.UP).normalized() * 0.1
	# Angular impulse / body inertia (rod about its end: m r^2 / 3).
	var kick := r.cross(j) / (float(mass[b]) * maxf(r.length_squared(), 0.01) / 3.0) * 0.035
	if kick.length() > MAX_SPIN:
		kick = kick.normalized() * MAX_SPIN
	spin[b] += kick
	# Through the constraints: the parents take a share by mass, the children lag the other way.
	var share := 0.5
	var c := b
	var up: int = parent_of[c]
	while up >= 0 and share > 0.05:
		spin[up] += kick * share * float(mass[c]) / float(mass[up])
		share *= 0.5
		c = up
		up = parent_of[c]
	for ch: int in children_of[b]:
		spin[ch] -= kick * 0.35
	awake = 2.0


func _process_modification() -> void:
	var skel := get_skeleton()
	if skel == null:
		return
	var now := Time.get_ticks_msec()
	var dt := clampf((now - _last_ms) * 0.001, 0.0, 0.05) if _last_ms > 0 else 0.0
	_last_ms = now
	if awake <= 0.0:
		return
	awake -= dt
	var h := dt / SUBSTEPS
	for i in bones:
		var k: float = stiffness[i]
		var cdamp: float = damping[i]
		var a: Vector3 = angle[i]
		var w: Vector3 = spin[i]
		for s in SUBSTEPS:
			w += (-k * a - cdamp * w) * h
			a += w * h
		if a.length() > MAX_ANGLE:
			a = a.normalized() * MAX_ANGLE
		angle[i] = a
		spin[i] = w
		peak = maxf(peak, a.length())
	# Apply parents first so each local pose is rebuilt against its parent's reacted pose.
	for i in bones:
		var a: Vector3 = angle[i]
		if a.length() < 1e-4:
			continue
		var off := Basis(a.normalized(), a.length())
		var g := skel.get_bone_global_pose(i)
		var parent := skel.get_bone_parent(i)
		var pg := skel.get_bone_global_pose(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		var new_global := off * g.basis.orthonormalized()
		skel.set_bone_pose_rotation(i, (pg.inverse() * new_global).get_rotation_quaternion())
