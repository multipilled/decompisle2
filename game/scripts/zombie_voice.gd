class_name ZombieVoice
extends Node
## DI2 zombie vocal audio (recon/ZOMBIE_AUDIO.md has the DI2 source of every value here).
##   * the voice: the family's CT_Voice_<Family> tree picks a DamLoc voice (ZombieWalkerMale01 ...) and its
##     CharacterVoiceDefinition (hold times, mouth config) - data/zombie_audio.json `voice_trees`;
##   * UBreathingAudioComponent: the breathing state machine (EBreathingState, tick exe 0x141173b30, advance
##     0x141157bb0, breath out 0x141170980, play pending 0x14116c220), its vocal requests (HandleVocalEvent
##     0x1411658b0, HandleEvent 0x141163d00, quick inhale 0x141164c20) from the montages' AnimNotify_BreathingEvent /
##     BP_AnimNotify_AttackBreathingEvent_Exert(_Chained)_AI notifies and from the hit-react cosmetic effects'
##     CosmeticEffect_BreathingVocalEvent modules (CE_HitReact_Standard/Major/Dismemberment/Knockdown/Death_Zombie);
##   * DamLoc: a trigger resolves through the voice's base-voice-set chain, its rules (and its parents') are
##     evaluated, the best one plays a communication, a variation picks the voice's own file; DialogueList gives the
##     file's Wwise event (DX_Walker_Talk / Shout / ...) and Volume;
##   * Wwise: the event's object + bus volumes and the bus attenuation (distance curve + cone) set the player's
##     volume; the Meter on the zombie dialogue actor-mixer (FxShareSet 220051762: Peak, GameObject scope, attack 0,
##     release 0.1 s, hold 0, -48..0 dB) is run per 1024-sample frame over the file's measured peaks, the max over
##     the zombie's live meter instances is RTPC_Zombie_Mouth_Volume, and like DI2 (exe 0x141177340) it is read every
##     >= 1/30 s into ZombieAnim.FaceLayer.mouth_db.

const DATA_PATH := "res://data/zombie_audio.json"
const VOX := "res://assets/di2/zombie_vox/"

enum S { BREATHING_IN, INTERRUPTED_BREATHING_IN, HOLDING_BREATH_IN, BREATHING_OUT, VOCAL_BREATHING_OUT,
	HOLDING_BREATH_OUT, EXTERNAL_DIALOGUE_PLAYING_OUT, DEAD }
enum PlayType { UNINITIALIZED, INTERRUPT_PLAY_IMMEDIATELY, INTERRUPT_QUICK_INHALE_THEN_PLAY, WAIT_AND_PLAY_ON_NEXT_EXHALE }
const FLAG_DYING := 1                     # EVocalPlayFlags bit 0 DyingVocal
const FLAG_DONT_INTERRUPT := 2            # bit 1 DontInterruptOtherVocal
const FLAG_ALLOW_SAME_PRIORITY := 4       # bit 2 AllowThisDialogueTriggerToBeInterruptedBySamePriority
## EDialoguePriority (exe enum table): the trigger priorities the zombie voice sets use.
const PRIORITY := {"inactive": 0, "dynamicUsingContext": 1, "localBreathing": 2, "localExert": 3, "localRoar": 6,
	"localHitReact": 9, "globalDialogue": 20, "localDeath": 33}
const RTPC_POLL := 0.033333335            # UBreathingAudioComponent RTPC read period (exe 0x141177340)

static var data := {}
static var peaks := {}
static var _streams := {}

var z: Zombie
var voice := ""
var definition := ""
var family := "Walker"
var sets: Array = []                      # the voice's base voice sets, each [most derived, parent, ...]
var comp := {}                            # the component's tuning after BP CDO + CharacterVoiceDefinition
var player: AudioStreamPlayer3D
var head: BoneAttachment3D

# UBreathingAudioComponent state (exe field offsets in recon/ZOMBIE_AUDIO.md section 3)
var state := S.HOLDING_BREATH_OUT         # ctor: +0x434 = 5
var timer := 0.0                          # +0x46c
var mental := 0                           # +0x432: 0 calm, 1 alerted (SetMentalState from OnCombatStateChanged)
var grapple := false                      # +0x433
var waiting := false                      # +0x435: a line was requested and has not started yet
var pending := S.BREATHING_IN             # +0x436: the state the requested line plays as
var vocal_pending := 0                    # +0x448
var vocal_type := 0                       # +0x428
var vocal_flags := 0                      # +0x42c
var vocal_prio := 0                       # +0x430
var dying := false                        # +0x471
var pending_advance := false              # +0x470
var queue: Array = []                     # +0x4c8 deque: vocal requests that arrived while waiting
var vocal: Dictionary = {}                # +0x3f0: the pending vocal asset {trigger, context}
var blocked := false                      # +0x4f8 (BlockBreathingExpression)

# DamLoc speaker state
var line: Dictionary = {}                 # the playing line {file, event, prio, t, len, rule_end, state}
var kb := {}                              # {SpeakerDialogue} facts (SetFactToNow times)
var shuffle := {}                         # communication -> remaining variation bag
var clock := 0.0

# Wwise meter (FxShareSet 220051762)
var meters: Array = []                    # [{blocks: PackedInt32Array, t, value, done}]
var rtpc := -48.0                         # RTPC_Zombie_Mouth_Volume on this game object (STMG default -48)
var _frame_acc := 0.0
var _last_poll := -1e9
var _last_plan = null
var _montage_pos := {}
var _was_dead := false
var log_lines: Array = []                 # [frame, time, file, trigger, state] for tests (--voicelog=<file>)
static var _args_read := false
static var _log_path := ""
static var _muted := false                # background autotests stay silent (the meter runs on game time anyway)


func _init(owner: Zombie) -> void:
	z = owner
	name = "ZombieVoice"


func _exit_tree() -> void:
	if _log_path == "" or voice == "":
		return
	var f := FileAccess.open(_log_path, FileAccess.READ_WRITE if FileAccess.file_exists(_log_path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line(JSON.stringify({"zombie": z.archetype, "family": family, "voice": voice, "definition": definition,
			"lines": log_lines}))


static func _load() -> void:
	if not _args_read:
		_args_read = true
		for a: String in OS.get_cmdline_user_args():
			if a.begins_with("--voicelog="):
				_log_path = a.get_slice("=", 1)
			if a.contains("test=") and not OS.get_cmdline_user_args().has("--voiceaudio"):
				_muted = true
	if data.is_empty():
		data = Util.load_json(DATA_PATH)
		var pf := FileAccess.open(VOX + "peaks.json", FileAccess.READ)
		if pf:
			peaks = JSON.parse_string(pf.get_as_text())


func _ready() -> void:
	_load()
	if data.is_empty():
		set_process(false)
		return
	family = z.family()
	_pick_voice()
	head = BoneAttachment3D.new()
	head.name = "Voice_head"
	head.bone_name = str(comp.get("AttachName", "head"))
	z.skeleton.add_child(head)
	player = AudioStreamPlayer3D.new()
	player.name = "Vox"
	# DI2's bus attenuation curves and cone are applied in volume_db (_apply_volume); Godot only pans.
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	player.max_distance = 0.0
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	head.add_child(player)


# --- voice choice -------------------------------------------------------------------------------------------------

## CT_Voice_<Family>: boolean nodes test the character's facts (Female: the port's bodies are male casuals),
## string nodes the SpecialVariant (none here), voice-node chains list the candidates (picked uniformly: the tree's
## choice among a chain is native, UNVERIFIED).
func _pick_voice() -> void:
	var tree: Dictionary = data["voice_trees"].get(family.to_lower(), data["voice_trees"]["walker"])
	var facts := {"Female": false, "SpecialVariant": ""}
	var node = tree
	while node != null and not node.has("voices"):
		if node.has("bool"):
			node = node["true"] if bool(facts.get(node["bool"], false)) else node["false"]
		elif node.has("string"):
			node = node["links"].get(str(facts.get(node["string"], "")), node["default"])
		else:
			node = null
	var cands: Array = node["voices"] if node != null else []
	var have: Array = data.get("voices_converted", [])
	cands = cands.filter(func(v): return have.has(v["voice"]))
	if cands.is_empty():
		return
	var pick: Dictionary = cands[randi() % cands.size()]
	voice = pick["voice"]
	definition = pick["definition"]
	# UBreathingAudioComponent ctor -> BPC_BreathingAudio_AI CDO -> the CharacterVoiceDefinition's values (its
	# asset, else the UCharacterVoiceDefinition ctor default).
	comp = (data["component"] as Dictionary).duplicate(true)
	var defaults: Dictionary = data["definition_native_defaults"]
	var def: Dictionary = data["voice_definitions"].get(definition, {})
	for k in defaults:
		comp[k] = def.get(k, defaults[k])
	for k in def:
		comp[k] = def[k]
	sets = []
	for s: Dictionary in data["voices"][voice]["sets"]:
		var chain := []
		var b = s["base"]
		while b != null:
			chain.append(b)
			b = data["base_voice_sets"][b]["parent"]
		sets.append(chain)


# --- tick ---------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if voice == "":
		return
	clock += delta
	_update_facts()
	_poll_notifies()
	_poll_hit_reacts()
	if z.dead and not _was_dead:
		_was_dead = true
		on_killed()
	_tick(delta)
	_advance_line(delta)
	_run_meter(delta)
	_apply_volume()
	# UBreathingAudioComponent polls the RTPC on its game object every >= 1/30 s of world time (exe 0x141177340).
	if clock - _last_poll >= RTPC_POLL:
		_last_poll = clock
		if z.anim_ctl and z.anim_ctl.face:
			z.anim_ctl.face.mouth_db = rtpc


## exe 0x141173b30 (the breathing part).
func _tick(delta: float) -> void:
	if not waiting:
		if not queue.is_empty():
			var q: Dictionary = queue.pop_front()
			handle_vocal_event(q["asset"], q["type"], q["flags"])
		if waiting or state == S.EXTERNAL_DIALOGUE_PLAYING_OUT:
			timer += delta
			return
		if pending_advance and _can_advance():
			pending_advance = false
			_advance()
		timer += delta
		if (state == S.HOLDING_BREATH_IN or state == S.HOLDING_BREATH_OUT) and not waiting and _can_advance():
			var hold := 0.0
			var key := "In" if state == S.HOLDING_BREATH_IN else "Out"
			if grapple:
				hold = float(comp.get("GrappleHoldBreath%sTime" % key, 0.0))
			elif mental == 0:
				hold = float(comp.get("CalmHoldBreath%sTime" % key, 0.0))
			else:
				hold = float(comp.get("AlertedHoldBreath%sTime" % key, 0.0))
			if hold <= timer:
				_advance()
	else:
		timer += delta


## exe 0x141168680: holding states wait while BlockBreathingExpression holds; playing lines always finish.
func _can_advance() -> bool:
	var playing := state in [S.BREATHING_IN, S.BREATHING_OUT, S.VOCAL_BREATHING_OUT, S.EXTERNAL_DIALOGUE_PLAYING_OUT]
	if not blocked:
		return true
	return state == S.INTERRUPTED_BREATHING_IN or playing


## exe 0x141157bb0.
func _advance() -> void:
	if (vocal_flags & FLAG_DYING) == 0 and dying:
		state = S.DEAD
		timer = 0.0
		dying = false
	if state == S.DEAD:
		return
	match state:
		S.BREATHING_IN:
			state = S.HOLDING_BREATH_IN
			timer = 0.0
		S.INTERRUPTED_BREATHING_IN, S.HOLDING_BREATH_IN:
			_breath_out()
		S.BREATHING_OUT, S.VOCAL_BREATHING_OUT, S.EXTERNAL_DIALOGUE_PLAYING_OUT:
			state = S.HOLDING_BREATH_OUT
			timer = 0.0
		S.HOLDING_BREATH_OUT:
			waiting = true
			pending = S.BREATHING_IN
	if waiting:
		_play_pending()


## exe 0x141170980: the next exhale is the pending vocal when there is one.
func _breath_out() -> void:
	if vocal_pending == 0:
		waiting = true
		pending = S.BREATHING_OUT
	elif vocal_pending == 1:
		waiting = true
		pending = S.VOCAL_BREATHING_OUT
	vocal_pending = 0


## exe 0x14116c220 (bUseDialogueTriggers path): play the line for `pending` through DamLoc.
func _play_pending() -> void:
	var trig: Array
	var ctx := {}
	var prio_override := -1
	match pending:
		S.BREATHING_IN:
			trig = comp["BreathInTrigger"]
		S.INTERRUPTED_BREATHING_IN:
			trig = comp["QuickBreathInTrigger"]
			prio_override = vocal_prio          # dynamicUsingContext: the interrupting vocal's priority
		S.BREATHING_OUT:
			trig = comp["BreathOutTrigger"]
		S.VOCAL_BREATHING_OUT:
			trig = vocal.get("trigger", [])
			ctx = vocal.get("context", {})
			if vocal_flags & FLAG_DYING:
				ctx["Dying"] = true
		_:
			waiting = false
			return
	var started := _start_trigger(trig, ctx, pending, prio_override)
	if started:
		waiting = false
		state = pending
		timer = 0.0
	else:
		# No rule / line for this voice: the request ends at once (the dialogue system's failure path is native,
		# UNVERIFIED) - the machine moves on as if the line had played.
		if pending == S.VOCAL_BREATHING_OUT:
			_clear_vocal()
			vocal_pending = 0
		waiting = false
		state = pending
		timer = 0.0
		pending_advance = true


## exe 0x1411658b0 HandleVocalEvent(VocalAsset, VocalPlayType, VocalPlayFlags).
func handle_vocal_event(asset: Dictionary, play_type: int, flags: int) -> void:
	if voice == "" or (asset.get("trigger", []) as Array).is_empty():
		return
	if waiting:
		queue.append({"asset": asset, "type": play_type, "flags": flags})
		return
	if state == S.DEAD:
		if (flags & FLAG_DYING) == 0:
			return
		play_type = PlayType.INTERRUPT_PLAY_IMMEDIATELY
		dying = true
	var cur_dying := (vocal_flags & FLAG_DYING) != 0
	if not (((not cur_dying) and not dying) or (flags & FLAG_DYING) != 0):
		return
	if (flags & FLAG_DONT_INTERRUPT) != 0 and vocal_type != 0:
		return
	var prio := 0
	if play_type == PlayType.INTERRUPT_QUICK_INHALE_THEN_PLAY:
		prio = _trigger_priority(asset["trigger"])
		if state == S.INTERRUPTED_BREATHING_IN and prio <= int(line.get("prio", 0)):
			return
	vocal_prio = prio
	pending_advance = false
	if mental == 0:
		play_type = PlayType.INTERRUPT_PLAY_IMMEDIATELY   # calm zombies always play at once
	_clear_vocal()
	vocal = asset
	match play_type:
		PlayType.INTERRUPT_PLAY_IMMEDIATELY:
			_stop_line()
			vocal_flags = flags
			vocal_pending = 1
			_breath_out()
			_play_pending()
		PlayType.INTERRUPT_QUICK_INHALE_THEN_PLAY:
			_quick_inhale()
		PlayType.WAIT_AND_PLAY_ON_NEXT_EXHALE:
			vocal_pending = 1
	vocal_type = play_type
	vocal_flags = flags


## exe 0x141163d00 HandleEvent(EBreathingEvent): Light / Normal / Heavy exert play the ExertTrigger with the
## ExertType context fact.
func handle_event(event: String, play_type: int, flags: int) -> void:
	var et: String = {"LightExert": "Light", "Exert": "Normal", "HeavyExert": "Heavy"}.get(event, "")
	if et == "":
		return
	handle_vocal_event({"trigger": comp["ExertTrigger"], "context": {"ExertType": et}}, play_type, flags)


## exe 0x141164c20 with true: interrupt with a quick inhale, then the vocal.
func _quick_inhale() -> void:
	match state:
		S.BREATHING_IN, S.INTERRUPTED_BREATHING_IN:
			# the breath-in keeps playing (its priority raised to the vocal's) and the vocal follows it
			line["prio"] = maxi(int(line.get("prio", 0)), vocal_prio)
			state = S.INTERRUPTED_BREATHING_IN
			timer = 0.0
			vocal_pending = 1
		S.HOLDING_BREATH_IN:
			state = S.INTERRUPTED_BREATHING_IN
			timer = 0.0
			vocal_pending = 1
			_advance()
		S.BREATHING_OUT, S.VOCAL_BREATHING_OUT, S.EXTERNAL_DIALOGUE_PLAYING_OUT, S.HOLDING_BREATH_OUT:
			if state != S.HOLDING_BREATH_OUT:
				_stop_line()
			waiting = true
			pending = S.INTERRUPTED_BREATHING_IN
			timer = 0.0
			vocal_pending = 1
			_play_pending()


func _clear_vocal() -> void:   # exe 0x14115a230
	vocal = {}
	vocal_type = 0
	vocal_flags = 0


## OnActorJustKilled / OnActorKilled (exe 0x14116aad0 / 0x14116ab90): the zombies' definitions leave
## bHasDyingVocalAsset false, so no vocal here (the death CE plays it); breathing stops unless a dying vocal plays.
func on_killed() -> void:
	if (vocal_flags & FLAG_DYING) == 0:
		state = S.DEAD
		timer = 0.0
		if line.get("state", -1) == S.VOCAL_BREATHING_OUT:
			_clear_vocal()
		pending_advance = false
		_stop_line()
	else:
		dying = true


# --- inputs ---------------------------------------------------------------------------------------------------------

func _update_facts() -> void:
	# OnCombatStateChanged -> SetMentalState: Calm 0 -> 0, Alert / Combat -> 1 (BPC_BreathingAudio_AI ubergraph);
	# the combat state is ZombieAnim's ECosmeticCombatState stand-in.
	var cs := 0
	if z.anim_ctl and z.anim_ctl.face:
		cs = int(z.anim_ctl.face.combat_state)
	mental = 0 if cs == 0 else 1
	grapple = z.reactions != null and str(z.reactions.state) == "paired"
	# BlockBreathingExpression "#BlockBreathingRequirements" over the montage scoped facts.
	var f := {"Hidden": false, "StatusEffectOutro": false}
	if z.reactions:
		for s: String in z.reactions._scoped_facts():
			f[s] = true
	for m: DI2Anim.Montage in z.anim_ctl.a.slot:
		var nd: Dictionary = data["montages"].get(m.name, {})
		for w: Array in nd.get("block_breathing", []):
			if m.pos >= float(w[0]) and m.pos < float(w[1]):
				f["AnimationBreathingBlock"] = true
	blocked = DI2Expr.eval(str(comp.get("BlockBreathingExpression", "")), f)


## Montage notifies (AnimNotify_BreathingEvent and the AttackBreathingEvent BPs) crossed since the last frame.
## UAnimNotify_BreathingEvent: Event Vocal -> HandleVocalEvent(VocalAsset, VocalPlayType, VocalPlayFlags), else
## HandleEvent(Event, VocalPlayType, VocalPlayFlags).
func _poll_notifies() -> void:
	var live := {}
	for m: DI2Anim.Montage in z.anim_ctl.a.slot:
		var id := m.get_instance_id()
		live[id] = true
		var nd: Dictionary = data["montages"].get(m.name, {})
		var prev: float = _montage_pos.get(id, -1e-4)
		_montage_pos[id] = m.pos
		if nd.is_empty() or m.weight.value <= 1e-5 or m.pos <= prev:
			continue
		for ev: Dictionary in nd.get("events", []):
			var t := float(ev["time"])
			if t > prev and t <= m.pos + 1e-6:
				_fire_notify(ev)
	for id in _montage_pos.keys():
		if not live.has(id):
			_montage_pos.erase(id)


func _fire_notify(ev: Dictionary) -> void:
	var pt := _play_type(str(ev.get("play_type", "InterruptQuickInhaleThenPlay")))
	var fl := int(ev.get("flags", 0))
	if str(ev.get("event", "Exert")) == "Vocal":
		handle_vocal_event({"trigger": ev.get("trigger", []), "context": {}}, pt, fl)
	else:
		handle_event(str(ev.get("event", "Exert")), pt, fl)


static func _play_type(s: String) -> int:
	return {"InterruptPlayImmediately": 1, "InterruptQuickInhaleThenPlay": 2, "WaitAndPlayOnNextExhale": 3}.get(s, 0)


## The hit-react tree's SpawnCosmeticEffectResponse CEs: their CosmeticEffect_BreathingVocalEvent modules
## (data/cosmetics.json) call HandleVocalEvent with the CE's VocalAsset / VocalPlayType / VocalPlayFlags and the
## hit facts named in CosmeticEffectFactsToUse as the vocal's context.
func _poll_hit_reacts() -> void:
	if z.reactions == null:
		return
	var p: Dictionary = z.reactions.last
	if p.is_empty() or is_same(p, _last_plan):
		return
	_last_plan = p
	for r: Dictionary in p.get("responses", []):
		if str(r.get("class", "")) != "SpawnCosmeticEffectResponse":
			continue
		for e: Dictionary in _cosmetic(str(r.get("Definition", ""))).get("effects", []):
			if str(e.get("type", "")) != "BreathingVocalEvent":
				continue
			var dt: Dictionary = e.get("VocalAsset", {}).get("DialogueTrigger", {})
			var trig := [str(dt.get("BaseVoiceSet", {}).get("NameStorage", "None")),
				str(dt.get("Trigger", {}).get("NameStorage", "None"))]
			var ctx := {}
			for fu: Dictionary in e.get("CosmeticEffectFactsToUse", []):
				var kbn := str(fu.get("KnowledgeBaseObjectName", {}).get("NameStorage", "")).to_lower()
				var fact := str(fu.get("FactName", {}).get("NameStorage", ""))
				ctx[fact] = p.get("facts", {}).get(kbn + "." + fact.to_lower(), false)
			handle_vocal_event({"trigger": trig, "context": ctx},
				_play_type(str(e.get("VocalPlayType", "")).get_slice("::", 1)), int(e.get("VocalPlayFlags", 0)))


static var _ce_data := {}


static func _cosmetic(name: String) -> Dictionary:
	if _ce_data.is_empty():
		_ce_data = Util.load_json("res://data/cosmetics.json")
	return _ce_data.get(name, {})


# --- DamLoc ---------------------------------------------------------------------------------------------------------

## The trigger key a (BaseVoiceSet, Trigger) reference names: the trigger of that name defined on the set or its
## nearest ancestor.
func _base_trigger(bvs: String, trig: String) -> String:
	var b = bvs
	while b != null and data["base_voice_sets"].has(b):
		if (data["base_voice_sets"][b]["triggers"] as Array).has(trig):
			return "%s.%s" % [b, trig]
		b = data["base_voice_sets"][b]["parent"]
	return ""


## The speaker's own version of a trigger: the most derived trigger in the voice's set chains that is (or derives
## from) the referenced one; its rules plus its parents' rules are the candidates (derived first). UNVERIFIED: the
## DamLoc lookup is native; this reproduces the data's inheritance (e.g. BreathingZombieWalker.BreathIn only adds
## the grapple rule to BreathingZombie.BreathIn's).
func _resolve(trig: Array) -> Array:
	if trig.size() < 2:
		return []
	var base := _base_trigger(str(trig[0]), str(trig[1]))
	if base == "":
		base = _base_trigger(str(sets[0][-1]) if not sets.is_empty() else "", str(trig[1]))
	var name := str(trig[1])
	for chain: Array in sets:
		for b: String in chain:
			var key := "%s.%s" % [b, name]
			if not data["triggers"].has(key):
				continue
			var k = key
			var anc := []
			while k != null:
				anc.append(k)
				k = data["triggers"][k]["parent"]
			if base == "" or anc.has(base):
				return anc
	return []


func _trigger_priority(trig: Array) -> int:
	var anc := _resolve(trig)
	if anc.is_empty():
		return 0
	return int(PRIORITY.get(str(data["triggers"][anc[0]]["priority"]), 0))


## Evaluates the trigger's rules and plays the best one's communication. Returns false when nothing plays.
func _start_trigger(trig: Array, ctx: Dictionary, as_state: int, prio_override: int) -> bool:
	var anc := _resolve(trig)
	if anc.is_empty():
		return false
	var facts := _speaker_facts(ctx)
	var best: Dictionary = {}
	var best_cx := -1
	for k: String in anc:
		for r: Dictionary in data["triggers"][k]["rules"]:
			# CriteriaComplexity = criteria count + CriteriaBoost (precomputed in the data): the most specific rule
			# that holds wins, the first one on ties (UNVERIFIED tie rule).
			if int(r["complexity"]) > best_cx and _criteria(str(r["criteria"]), facts):
				best = r
				best_cx = int(r["complexity"])
	if best.is_empty():
		return false
	for a: Dictionary in best.get("BeginActions", []):
		_kb_action(a)
	var comm := ""
	for a: Dictionary in best.get("PerformActions", []):
		if str(a.get("action", "")) == "PlayCommunication":
			comm = "%s.%s" % [a.get("BaseVoiceSetName", ""), a.get("CommunicationName", "")]
	var file := _variation(comm)
	if file == "":
		return false
	var prio := int(PRIORITY.get(str(data["triggers"][anc[0]]["priority"]), 0))
	if prio == PRIORITY["dynamicUsingContext"] and prio_override >= 0:
		prio = prio_override
	return _play_file(file, prio, best.get("EndActions", []), as_state, trig)


## DamLoc VariationPlayType Shuffle: a shuffled bag of the voice's variations, refilled when empty (no immediate
## repeat across refills). UNVERIFIED (native).
func _variation(comm: String) -> String:
	var c: Dictionary = data["communications"].get(voice, {}).get(comm, {})
	var files: Array = c.get("files", [])
	if files.is_empty():
		return ""
	var bag: Array = shuffle.get(comm, [])
	if bag.is_empty():
		bag = files.duplicate()
		bag.shuffle()
		if bag.size() > 1 and str(bag[0]) == str(shuffle.get(comm + "#last", "")):
			bag.push_back(bag.pop_front())
	var f := str(bag.pop_front())
	shuffle[comm] = bag
	shuffle[comm + "#last"] = f
	return "%s/%s" % [voice, f]


func _speaker_facts(ctx: Dictionary) -> Dictionary:
	var cs: int = int(z.anim_ctl.face.combat_state) if z.anim_ctl and z.anim_ctl.face else 0
	var f := {"Speaker.CombatState": ["Calm", "Alert", "Combat"][clampi(cs, 0, 2)],
		"Speaker.WithinGrapple": grapple,
		"Speaker.InRunAttackWindUp": z.attack_anim.contains("windup") and family == "Runner" and z.lock_time > 0.0}
	for k in ctx:
		f["Context." + str(k)] = ctx[k]
	return f


## DamLoc criteria: DI2 KB expressions plus timeSince({SpeakerDialogue}.Fact, default) (seconds since the fact was
## set to now, default when never set); rnd(a, b) re-rolls per evaluation (DI2Expr).
func _criteria(expr: String, facts: Dictionary) -> bool:
	if expr == "":
		return true
	var e := expr
	var rx := RegEx.create_from_string("timeSince\\(\\{(\\w+)\\}\\.(\\w+),\\s*([0-9.]+)\\)")
	for m in rx.search_all(expr):
		var key := "%s.%s" % [m.get_string(1), m.get_string(2)]
		var v := float(m.get_string(3))
		if kb.has(key):
			v = clock - float(kb[key])
		e = e.replace(m.get_string(0), str(v))
	var rx2 := RegEx.create_from_string("\\{(\\w+)\\}\\.(\\w+)")
	for m in rx2.search_all(e):
		var key := "%s.%s" % [m.get_string(1), m.get_string(2)]
		if kb.has(key) and not facts.has(key):
			facts[key] = kb[key]
	return DI2Expr.eval(e, facts)


func _kb_action(a: Dictionary) -> void:
	var key := "%s.%s" % [a.get("KnowledgeBase", ""), a.get("Fact", "")]
	match str(a.get("action", "")):
		"SetFactToNow":
			kb[key] = clock
		"IncrementFact":
			kb[key] = float(kb.get(key, 0.0)) + 1.0
		"DecrementFact":
			kb[key] = float(kb.get(key, 0.0)) - 1.0


# --- playback -------------------------------------------------------------------------------------------------------

func _play_file(file: String, prio: int, end_actions: Array, as_state: int, trig: Array) -> bool:
	var meta: Dictionary = data["lines"].get(file, {})
	var pk: Dictionary = peaks.get(file, {})
	var stream := _stream(file)
	if stream == null or pk.is_empty():
		return false
	_stop_line()
	line = {"file": file, "event": str(meta.get("event", "")), "volume_db": float(meta.get("volume_db", 0.0)),
		"prio": prio, "t": 0.0, "len": float(pk["samples"]) / float(pk["rate"]), "end": end_actions,
		"state": as_state, "trigger": trig}
	player.stream = stream
	_apply_volume()
	if not _muted:
		player.play()
	# a new Wwise voice: a fresh meter instance on this game object
	meters.append({"blocks": pk["peak_db100"], "t": 0.0, "value": -48.0, "done": false, "voice": file})
	log_lines.append([Engine.get_process_frames(), snappedf(clock, 0.001), file,
		"%s.%s" % [trig[0], trig[1]] if trig.size() > 1 else "", as_state, snappedf(stream.get_length(), 0.001),
		snappedf(float(line["len"]), 0.001), snappedf(player.volume_db, 0.01)])
	if log_lines.size() > 200:
		log_lines = log_lines.slice(-200)
	return true


static func _stream(file: String) -> AudioStreamOggVorbis:
	if not _streams.has(file):
		_streams[file] = AudioStreamOggVorbis.load_from_file(VOX + file + ".ogg")
	return _streams[file]


## The line's own clock (game time, so captures at --fixed-fps match the meter); its end is the line ending.
func _advance_line(delta: float) -> void:
	if line.is_empty():
		return
	line["t"] = float(line["t"]) + delta
	if float(line["t"]) >= float(line["len"]):
		_on_line_finished()


func _on_line_finished() -> void:
	if line.is_empty():
		return
	var ended := line
	line = {}
	if player.playing:
		player.stop()
	for a: Dictionary in ended.get("end", []):
		_kb_action(a)
	# the meter instance of a voice that ends by itself keeps metering silence until it decays to Min
	for m: Dictionary in meters:
		if str(m["voice"]) == str(ended["file"]):
			m["done"] = true
	if int(ended.get("state", -1)) == S.VOCAL_BREATHING_OUT:
		_clear_vocal()
	if state == int(ended.get("state", -1)) or (state == S.INTERRUPTED_BREATHING_IN and int(ended["state"]) == S.BREATHING_IN):
		_advance()


## A line stopped by the state machine: the Wwise voice stops and its meter instance terminates at once (the
## meter's Term flags it and the next frame callback reads its Min, exe 0x14421e410 / 0x14421e6e0).
func _stop_line() -> void:
	if line.is_empty():
		return
	var f := str(line["file"])
	line = {}
	if player.playing:
		player.stop()
	meters = meters.filter(func(m): return str(m["voice"]) != f)


# --- Wwise meter + volume -------------------------------------------------------------------------------------------

## AkMeterFX per 1024-sample frame (exe 0x14421dcf6 level, 0x14421d800 ballistics): level = clamp(peak dB, Min,
## Max); rising: value = level (attack 0); falling: value = max(value - 10 dB * frame / release, level) (hold 0).
## The global callback (0x14421e6e0) sets the RTPC to the max over the game object's instances, no ramp.
func _run_meter(delta: float) -> void:
	var m_cfg: Dictionary = data["meter"]
	var frame := float(m_cfg["frame_samples"]) / float(m_cfg["sample_rate"])
	var mn := float(m_cfg["min"])
	var mx := float(m_cfg["max"])
	var rel := float(m_cfg["release"])
	var att := float(m_cfg["attack"])
	_frame_acc += delta
	while _frame_acc >= frame:
		_frame_acc -= frame
		if meters.is_empty():
			continue
		var top := -INF
		var keep := []
		for m: Dictionary in meters:
			var blocks: Array = m["blocks"]
			var k := int(float(m["t"]) / frame)
			var level := mn
			if not bool(m["done"]) and k < blocks.size():
				level = clampf(float(blocks[k]) * 0.01, mn, mx)
			m["t"] = float(m["t"]) + frame
			var v := float(m["value"])
			if level > v:
				v = level if att == 0.0 else minf(v + frame / att * 10.0, level)
			else:
				v = level if rel == 0.0 else maxf(v - frame / rel * 10.0, level)
			m["value"] = v
			top = maxf(top, v)
			var ended := bool(m["done"]) or k >= blocks.size()
			if not (ended and v <= mn):
				keep.append(m)
		meters = keep
		rtpc = top


## Wwise gain for the line: DamLoc line Volume + the event's actor-mixer / bus volumes + the bus attenuation curve
## at the listener distance (UE cm) + the bus cone (Talk: 90/185 deg, -0.5 dB; Shout/Scream: 220/360, -3 dB).
func _apply_volume() -> void:
	if line.is_empty() or player == null:
		return
	var ev: Dictionary = data["wwise"]["events"].get(str(line["event"]), {})
	var db := float(line["volume_db"]) + float(ev.get("object_volume_db", 0.0)) + float(ev.get("bus_volume_db", 0.0))
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var att: Dictionary = data["wwise"]["attenuations"].get(str(ev.get("attenuation", "")), {})
	if cam and not att.is_empty():
		var to_l := cam.global_position - player.global_position
		var dist_cm := to_l.length() * 100.0
		var curves: Array = att["curves"]
		var vi := int(att["curve_map"][0])
		if vi >= 0 and vi < curves.size():
			db += _curve_db(curves[vi]["points"], dist_cm)
		var cone = att.get("cone")
		if cone != null and to_l.length() > 1e-3:
			var fwd := -z.global_transform.basis.z
			var ang := rad_to_deg(fwd.angle_to(to_l.normalized()))
			var inside := float(cone[0]) * 0.5
			var outside := float(cone[1]) * 0.5
			var a := clampf((ang - inside) / maxf(outside - inside, 1e-3), 0.0, 1.0)
			db += float(cone[2]) * a
	player.volume_db = db


## Attenuation volume curve (AkCurveScaling dB: values stored as linear gain - 1), Wwise interpolation shapes.
static func _curve_db(pts: Array, x: float) -> float:
	if pts.is_empty():
		return 0.0
	var y := float(pts[-1][1])
	if x <= float(pts[0][0]):
		y = float(pts[0][1])
	else:
		for i in pts.size() - 1:
			var a: Array = pts[i]
			var b: Array = pts[i + 1]
			if x <= float(b[0]):
				var t := (x - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-6)
				y = lerpf(float(a[1]), float(b[1]), _interp(str(a[2]), t))
				break
	var lin := y + 1.0
	return -96.0 if lin <= 1e-5 else 20.0 * log(lin) / log(10.0)


## Wwise AkCurveInterpolation shapes (Log3/Log1/Exp1/Exp3/SCurve/InvSCurve/Sine/SineRecip/Linear/Constant).
static func _interp(kind: String, t: float) -> float:
	match kind:
		"Constant":
			return 0.0
		"Linear":
			return t
		"Log3":
			return 1.0 - pow(1.0 - t, 3.0)
		"Log1":
			return 1.0 - pow(1.0 - t, 1.41)
		"Exp1":
			return pow(t, 1.41)
		"Exp3":
			return pow(t, 3.0)
		"Sine":
			return sin(t * PI * 0.5)
		"SineRecip":
			return 1.0 - cos(t * PI * 0.5)
		"SCurve":
			return 0.5 - 0.5 * cos(t * PI)
		"InvSCurve":
			return (asin(2.0 * t - 1.0) / PI) + 0.5
	return t
