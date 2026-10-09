class_name ZombieAI
extends RefCounted
## DI2's zombie combat AI: the card dealer (AICardDealerComponent + CardGenerator_* decks, plugin CardDealer) and the
## card player (ActionCardPlayer) of each archetype's BP_AIController, driven from game/data/zombie_ai.json
## (tools/build_zombie_ai.py). Every decision is a card drawn from the deck of the current context; cards play actions
## (attack sequences, approach, strafe, idle breaks). AttackRules gate attacks with warm-ups and cooldowns.
## Semantics: recon/ZOMBIE_AI.md (section numbers in comments). Distances in DI2 cm unless named _m.

static var data := {}
static var clock := 0.0           # shared AI time (s); advanced by every agent's tick (max of their clocks)

var z: Zombie
var arch := "Walker"
var ctl := {}
var counters := {}                # dealer counters (CardDealerCounterModification)
var facts := {}                   # own knowledge-base facts set by cards / generators (name -> value)
var fact_times := {}              # fact name -> time it was set (AttackRules WarmUpStartedFactName)
var warmups := {}                 # rules Name -> [start fact value, sampled warm-up] (AttackRules_%s_WarmUp[Generated])
var context := "Master"
var combat_state := "Calm"
var combat_t0 := -1.0
var now := 0.0
var rng := RandomNumberGenerator.new()
var play := {}                    # card in play: {name, card, kind, t, units, unit, path, ...}
var log: Array = []               # [time, card] draws (tests)
var attack_log: Array = []        # [time, montage, clip] attack montages started (tests)
var deal_skips := {}              # card -> times left out of the deal (no playable montage; tests)
var _last_dist := 0.0
var _target_facts := {}
var _self_facts := {}
var arch_data := {}               # archetypes.json entry (tools/convert_archetypes.py from DA_AIAttributeValues_<Type>)


static func _load() -> void:
	if data.is_empty():
		data = Util.load_json("res://data/zombie_ai.json")


func _init(zombie: Zombie, archetype: String, seed := 0) -> void:
	_load()
	z = zombie
	# The AI controller of the zombie's DI2 class (BP_AIController_<Class>): its archetype name's class prefix
	# (Butcher_Revenant -> Butcher), else the body family passed in.
	arch = archetype if data.get("controllers", {}).has(archetype) else "Walker"
	for k: String in data.get("controllers", {}):
		if str(zombie.archetype).begins_with(k):
			arch = k
	ctl = data["controllers"][arch]
	rng.seed = seed if seed != 0 else randi()
	_set_fact("CanEnterCombat", true)   # BT_Base_Zombie: BTTask_AddKnowledgeBaseFacts CanEnterCombat = true
	for a in Util.load_json("res://data/archetypes.json"):
		if a.get("name") == str(zombie.get("archetype")):
			arch_data = a


## A card's attack field from archetypes.json (LeftHandSwipe carries DI2's AIAttributeValues at multiplier 1:
## damage = BaseDamageAttribute, cooldown = AttackSpacingDuration).
func _arch_attack(field: String, dflt: float) -> float:
	for c in arch_data.get("attacks", []):
		if c.get("name") == "LeftHandSwipe":
			return float(c.get(field, dflt))
	return dflt


## Locomotion speed request (m/s): DI2's AIMovementSpeedData (DA_MovementSpeed_<Type>, the character's MovementSpeedData):
## the first BaseValues entry whose expression holds gives BaseSpeed (RNG, cm/s) clamped to [ClampedMin, ClampedMax].
## UNVERIFIED: re-sampled only when the matching entry changes; DA_MovementSpeedModifier_<Type> not applied.
var _speed_entry := -1
var _speed := 0.0

func move_speed(_dist_m := 0.0) -> float:
	var entries: Array = data.get("move_speeds", {}).get(arch, [])
	for i in entries.size():
		var en: Dictionary = entries[i]
		if not DI2Expr.eval(str(en.get("expr", "")), _self_facts):
			continue
		if i != _speed_entry:
			_speed_entry = i
			_speed = clampf(sample(en.get("speed", {}), 0.0), float(en.get("min", 0.0)), float(en.get("max", 1000.0)))
		return _speed / 100.0
	var lo: Dictionary = arch_data.get("locomotion", {})
	return float(lo.get("walk_speed", 0.6))


static func asset(n: String) -> Dictionary:
	return data.get("assets", {}).get(n.trim_prefix("@"), {})


# --- tick ----------------------------------------------------------------------------------------------------------

## One AI step. Returns the brain command zombie.gd consumes: {speed, face, anim, attack ("" or a card name when an
## attack montage starts), clip (body clip to play), damage, move_dir (world, for strafes)}.
func think(delta: float, dist_m: float, can_see: bool, target: Node3D) -> Dictionary:
	now += delta
	clock = maxf(clock, now)
	_status_tick()
	var cmd := {"speed": 0.0, "face": false, "anim": "Idle", "attack": "", "clip": "", "damage": 0.0}
	_update_combat_state(can_see, dist_m)
	_suicider_tick(delta, dist_m)
	if combat_state != "Combat" or not is_instance_valid(target):
		_end_play(false)
		cmd["anim"] = "Idle" if combat_state == "Calm" else "Alert"
		cmd["face"] = combat_state != "Calm"
		return cmd
	_refresh_facts(dist_m, target)
	if play.is_empty() or _should_end():
		_end_play(play.get("ok", true))
		var c := draw()
		if c != "":
			_start_card(c)
	if not play.is_empty():
		_tick_card(delta, cmd, dist_m, target)
	return cmd


## DI2 combat state (ECombatState) from combat stims (DA_CombatStims_Zombie_Common, parent of DA_CombatStims_<Type>):
## SeeHostileHumanoid scores 20, its envelope rises over AttackTime 1 s and falls over the current target's
## ReleaseTime 20 s; the Distance modifier scales it by 1 at <= 800 cm to 0.7 at 1500 cm; Combat starts when the
## score reaches CombatAggroComponent.ScoreThreshold (10) and ends when it falls below. UNVERIFIED: the envelope's
## exact shape (linear here) and the Threat / ViewAngle / GoalProximity modifiers (1 for a single visible target).
var stim := 0.0

func _update_combat_state(can_see: bool, dist_m: float) -> void:
	var dt := now - float(facts.get("_stim_t", now))
	facts["_stim_t"] = now
	var d := dist_m * 100.0
	var dist_mult := 1.0 if d <= 800.0 else lerpf(1.0, 0.7, clampf((d - 800.0) / 700.0, 0.0, 1.0))
	if can_see:
		stim = minf(stim + dt / 1.0, 1.0)
	else:
		stim = maxf(stim - dt / 20.0, 0.0)
	var score := 20.0 * stim * dist_mult
	if score >= _aggro("ScoreThreshold") and combat_state != "Combat":
		combat_state = "Combat"
		combat_t0 = now
	elif score < _aggro("ScoreThreshold") and combat_state == "Combat":
		combat_state = "Search"


# --- facts -----------------------------------------------------------------------------------------------------------

func _set_fact(n: String, v: Variant) -> void:
	facts[n] = v
	fact_times[n] = now


## Self facts for KnowledgeBase expressions: the body facts zombie_reactions builds (HealthFraction_*, Crawler, ...),
## the dealer's own facts, and the combat facts (DistanceFromTarget in cm).
func _refresh_facts(dist_m: float, target: Node3D) -> void:
	var f: Dictionary = z.reactions.victim_facts() if z.reactions != null else {}
	f.merge(facts, true)
	f["CombatState"] = combat_state
	f["CosmeticCombatState"] = combat_state   # UNVERIFIED: DI2's cosmetic state lags / differs from the combat state
	f["Strafe"] = str(play.get("kind", "")) == "strafe"   # UNVERIFIED fact source (DA_MovementSpeed "Strafe" entry)
	f["DistanceFromTarget"] = dist_m * 100.0
	_last_dist = dist_m
	f["DesiredEngagementRing"] = _desired_ring()
	var ring := _ring(dist_m * 100.0)
	if ring != str(facts.get("_ring", "None")):
		# Ring-entry facts the decks' AttackRules warm-ups start from (WarmUpStartedFactName First_EnteredInnerRing,
		# Last_EnteredOuterRing); set by DI2's native engagement-ring code (UNVERIFIED: set on entering by distance).
		facts["_ring"] = ring
		if ring == "Inner" and not fact_times.has("First_EnteredInnerRing"):
			_set_fact("First_EnteredInnerRing", now)
		if ring == "Outer":
			_set_fact("Last_EnteredOuterRing", now)
		_set_fact("Last_EnteredEngagementRing", now)
	f["EngagementRing"] = ring
	f["World.NumPlayers"] = 1
	f["AggressionLevel"] = facts.get("AggressionLevel", 0)
	_self_facts = f
	var t := {}
	if target.has_method("ai_facts"):
		t = target.ai_facts()
	else:
		t["Dead"] = bool(target.get("dead"))
		t["PlayerKnockdown"] = str(target.get("state")) in ["knockdown", "down"]
		t["Grapple"] = str(target.get("state")) == "grapple"
	_target_facts = t
	for k: String in t:
		_self_facts["Target." + k] = t[k]


func expr(e: Variant, on_target := false) -> bool:
	var s := str(e.get("Expression", "") if e is Dictionary else e)
	if s.strip_edges() == "":
		return true
	return DI2Expr.eval(s, _target_facts if on_target else _self_facts)


# --- engagement rings (section 7: provisional) ----------------------------------------------------------------------

## CombatAggroComponent ctor defaults (0x14106b430), overridden by BPC_CombatAggro_<Type> (zombie_ai.json aggro).
const AGGRO_DEFAULTS := {"ScoreThreshold": 10.0, "TargetPerceptionGracePeriod": 0.5, "Threat": 1.0,
	"EngagementPriority": 0.0, "InnerRingRadius": 120.0, "InnerRingOccupyRadius": 100.0, "InnerRingSquishAmount": 50.0,
	"InnerRingOccupyVariation": 50.0, "OuterRingRadius": 500.0, "OuterRingOccupyRadius": 400.0,
	"OuterRingSquishAmount": 100.0, "OuterRingOccupyVariation": 100.0, "OccupyTolerance": 20.0}


func _aggro(k: String, _dflt := 0.0) -> float:
	return float(ctl.get("aggro", {}).get(k, AGGRO_DEFAULTS.get(k, _dflt)))


func _ring(d_cm: float) -> String:
	if d_cm <= _aggro("InnerRingRadius"):
		return "Inner"
	return "Outer"


func _desired_ring() -> String:
	return str(facts.get("DesiredEngagementRing", "Inner"))


# --- dealer: decks and generators (section 7) ----------------------------------------------------------------------

## Draws the next card of the current context, applying on-draw side effects of the generators that produced it.
## The card in play is a DI2 grapple (DA_Card_Grapple_*): its hit starts the paired grapple on the target.
func is_grapple() -> bool:
	return str(play.get("name", "")).contains("Grapple")


## A hit reaction / fall interrupts the card in play (DI2: the action is cancelled; counted as a failure).
func interrupt() -> void:
	_end_play(false)


func draw() -> String:
	var path: Array = []
	_draw_rules = []
	var deck: String = str(ctl["contexts"].get(context, "") if ctl["contexts"].get(context) != null else "")
	var c := _deck(deck, path, 0)
	if c == "":
		return ""
	for g: Dictionary in path:
		_on_drew(g)
	log.append([snappedf(now, 0.01), c])
	return c


## The card the deck would deal now, without side effects (DI2's peek: SelfPeekedCard / PeakedCardToMaintainAction).
func peek() -> String:
	_peek_path = []
	return _deck(str(ctl["contexts"].get(context, "") if ctl["contexts"].get(context) != null else ""), _peek_path, 0)


func _deck(name: String, path: Array, depth: int) -> String:
	var d := asset(name)
	if d.is_empty() or depth > 8:
		return ""
	for g in d.get("Generators", []):
		var gen = g.get("Generator") if g is Dictionary else null
		if gen == null:
			continue
		var c := _gen(gen, path, depth)
		if c != "":
			path.append(d)
			return c
	return ""


func _gen(g: Variant, path: Array, depth: int) -> String:
	if not (g is Dictionary):
		return ""
	var t: String = g.get("$t", "")
	var res = g.get("Result", {}).get("Generator") if g.get("Result") is Dictionary else null
	var ok := true
	match t:
		"CardGenerator_Always":
			var c := str(g.get("Card", "")).trim_prefix("@")
			if c != "" and not _card_playable(c):
				return ""   # TEMPORARY (UNVERIFIED 94): the body lacks the card's attack montage
			if c != "":
				path.append(g)
			return c
		"CardGenerator_IncludeDeck":
			var inc = ctl["contexts"].get(str(g.get("DeckContextToInclude", "")))
			return _deck(str(inc) if inc != null else "", path, depth + 1)
		"CardGenerator_Selector":
			for o in g.get("Options", []):
				var c := _gen(o.get("Generator") if o is Dictionary else null, path, depth)
				if c != "":
					path.append(g)
					return c
			return ""
		"CardGenerator_Random":
			return _random(g, path, depth)
		"CardGenerator_KnowledgeBase":
			ok = expr(g.get("Expression", ""))
		"BP_CardGenerator_Latent_CombatTargetKB_C":
			ok = expr(g.get("Expression", ""), true)
		"BP_CardGenerator_Latent_HasCombatTarget_C":
			ok = combat_state == "Combat"
		"BP_CardGenerator_Latent_SetBoolFactOnDraw_C":
			ok = true
		"CardGenerator_ConsoleVariable":
			ok = _cvar(str(g.get("CVar", "")))
		"CardGenerator_CounterComparison":
			ok = _counter_cmp(g)
		"CardGenerator_FacingCombatTarget":
			ok = _facing(g)
		"CardGenerator_VerticalRangeToCombatTarget":
			ok = _vertical(g)
		"CardGenerator_AttackRules":
			ok = rules_allow(g.get("AttackRules", []), str(g.get("WarmUpStartedFactName", "")))
		"CardGenerator_CanReachCombatTarget":
			ok = not bool(g.get("bInverse", false))   # the arena has no unreachable targets: reachable always
		"CardGenerator_ScopedCounterFacts":
			ok = true
		"CardGenerator_EveryNthDraw":
			# Passes on every Nth draw through it, N in [DrawIntervalMin, DrawIntervalMax] (UNVERIFIED semantics;
			# the decks only use 1..1 = always).
			var key := str(g.hash())
			var st: Array = _nth.get(key, [0, rng.randi_range(int(g.get("DrawIntervalMin", 1)), int(g.get("DrawIntervalMax", 1)))])
			if not is_same(path, _peek_path):
				st[0] = int(st[0]) + 1
			ok = int(st[0]) + (0 if not is_same(path, _peek_path) else 1) >= int(st[1])
			if ok and not is_same(path, _peek_path):
				st = [0, rng.randi_range(int(g.get("DrawIntervalMin", 1)), int(g.get("DrawIntervalMax", 1)))]
			_nth[key] = st
		"BP_CardGenerator_Polling_IsMeleeObstructed_C":
			ok = false                                  # open arena: melee is never obstructed
		_:
			push_warning("ZombieAI: unhandled generator " + t)
			ok = false
	if not ok:
		return ""
	var c2 := _gen(res, path, depth)
	if c2 != "":
		path.append(g)
	return c2


## CardGenerator_Random: weighted by Options[].Frequency (section 7: fall-through when the pick yields nothing is
## provisional: the remaining options are tried by weight).
func _random(g: Dictionary, path: Array, depth: int) -> String:
	var opts: Array = []
	for o in g.get("Options", []):
		opts.append(o)
	while not opts.is_empty():
		var total := 0.0
		for o in opts:
			total += float(o.get("Frequency", 1))
		var r := rng.randf() * total
		var pick = opts[-1]
		for o in opts:
			r -= float(o.get("Frequency", 1))
			if r < 0.0:
				pick = o
				break
		var res = pick.get("Result", {}).get("Generator") if pick.get("Result") is Dictionary else null
		var c := _gen(res, path, depth)
		if c != "":
			path.append(g)
			return c
		opts.erase(pick)
	return ""


## Console variables the decks test, at DI2's shipping defaults (UNVERIFIED values, section 7).
func _cvar(n: String) -> bool:
	match n.to_lower():
		"ai.enableoffscreenbehaviours":
			return true
		"ai.combat.grappleenabled":
			return true
	return false


func _counter_cmp(g: Dictionary) -> bool:
	var l := int(counters.get(str(g.get("Left", {}).get("CounterName", "")), 0))
	var rv: Dictionary = g.get("Right", {}).get("RawValue", {})
	var r := _sample_int(rv)
	match str(g.get("Operator", "EComparisonOperator::Equal")).trim_prefix("EComparisonOperator::"):
		"Less":
			return l < r
		"LessEqual":
			return l <= r
		"Greater":
			return l > r
		"GreaterEqual":
			return l >= r
		"NotEqual":
			return l != r
	return l == r


## FacingCombatTarget: angle between the facing of one side and the direction to the other (section 7).
func _facing(g: Dictionary) -> bool:
	var tgt: Node3D = z.target
	var a: Node3D = z
	var b: Node3D = tgt
	if str(g.get("FacingType", "")).ends_with("CombatTargetToAgent"):
		a = tgt
		b = z
	var fwd := -a.global_transform.basis.z
	fwd.y = 0.0
	var to := b.global_position - a.global_position
	to.y = 0.0
	if fwd.length() < 1e-4 or to.length() < 1e-4:
		return not bool(g.get("bIsInverse", false))
	fwd = fwd.normalized().rotated(Vector3.UP, deg_to_rad(-float(g.get("RotationalOffset", 0.0))))
	var ang := rad_to_deg(fwd.angle_to(to.normalized()))
	# MaxFacingAngle is the full cone (half each side): the decks only make sense that way (the off-screen branch's
	# CombatTargetToAgent inverse 180 = "outside the target's front half"; as a half-angle it could never hold).
	# UNVERIFIED against the native CardGenerator_FacingCombatTarget.
	var inside := ang <= float(g.get("MaxFacingAngle", 90.0)) * 0.5
	return inside != bool(g.get("bIsInverse", false))


func _vertical(g: Dictionary) -> bool:
	var dz: float = (z.target.global_position.y - z.global_position.y) * 100.0
	return dz >= float(g.get("VerticalRangeMin", -100000.0)) and dz <= float(g.get("VerticalRangeMax", 100000.0))


## On-draw side effects of a generator on the drawing path.
func _on_drew(g: Dictionary) -> void:
	match str(g.get("$t", "")):
		"Deck":
			_counters(g.get("CounterModificationOnDraw", {}))
		"CardGenerator_CounterComparison":
			_counters(g.get("OnDrewCard", {}))
		"BP_CardGenerator_Latent_SetBoolFactOnDraw_C":
			_set_fact(str(g.get("FactKey", {}).get("NameStorage", "")), bool(g.get("bValue", false)))
		"CardGenerator_AttackRules":
			_draw_rules.append_array(g.get("AttackRules", []))


func _counters(m: Dictionary) -> void:
	for kv in m.get("CountersToModify", []):
		counters[kv["Key"]] = int(counters.get(kv["Key"], 0)) + _sample_int(kv.get("Value", {}))
	for kv in m.get("CountersToSet", []):
		counters[kv["Key"]] = _sample_int(kv.get("Value", {}))


# --- random-number structs (section 6) -----------------------------------------------------------------------------

func _sample_int(v: Dictionary) -> int:
	match str(v.get("Distribution", "")).get_slice("::", 1):
		"Uniform":
			return rng.randi_range(int(v.get("Min", 0)), int(v.get("Max", 0)))
	return int(v.get("AbsoluteValue", 0))


## FRandomNumberGenerator_Float sample (FUN_141aeae20). Layout (reflection): Distribution @0, ExpectedValue @4,
## StandardDeviation @8, Min @12, Max @16, Lambda @20, Offset @24; ctor FUN_141ae9700(v): AbsoluteValue, Expected v,
## SD 1, Min 0, Max 1, Lambda 1, Offset 0. AbsoluteValue -> ExpectedValue; Uniform -> Min + u (Max - Min); Normal ->
## ExpectedValue + SD * N(0, 1) (Marsaglia polar, no clamp); Cauchy -> Offset + Lambda tan((u - 0.5) pi).
## `dflt` = the owner's ctor ExpectedValue for a struct the asset leaves at its default.
func sample(v: Variant, dflt := 0.0) -> float:
	var d: Dictionary = v if v is Dictionary else {}
	match str(d.get("Distribution", "")).get_slice("::", 1):
		"Uniform":
			var mn := float(d.get("Min", 0.0))
			return mn + rng.randf() * (float(d.get("Max", 1.0)) - mn)
		"Normal":
			return float(d.get("ExpectedValue", dflt)) + float(d.get("StandardDeviation", 1.0)) * rng.randfn(0.0, 1.0)
		"Cauchy":
			return float(d.get("Offset", 0.0)) + float(d.get("Lambda", 1.0)) * tan((rng.randf() - 0.5) * PI)
	return float(d.get("ExpectedValue", dflt))


# --- attack rules (section 6) ---------------------------------------------------------------------------------------
# DI2 keeps AttackRules state as knowledge-base facts named AttackRules_<Name>_<scope>_Started / _InProgress
# (FUN_14103d600 / FUN_141040e50) in the attacker's, the combat target's and the global knowledge base
# (FUN_1410629b0). UAttackRules ctor (0x141b55f20): WarmUp = 0, Attacker / Target / GlobalPostEndCooldown = -1,
# Target / GlobalPostStartCooldown = 0.
#  - check (FUN_14104ac10 per rules of the generator's set): warm-up (FUN_141051530) and, per scope, no _Started fact
#    and no _InProgress fact (FUN_1410519b0);
#  - commit (FUN_141043990): attacker _InProgress = sample(AttackerPostEndCooldown) if >= 0; target / global: if
#    PostStartCooldown > 0, add _Started and remove it after that time; _InProgress = sample(PostEndCooldown) if >= 0;
#  - end (FUN_141049eb0): remove _Started now, remove _InProgress after its value (s).
# The port keeps the three scopes in static dictionaries: scope key -> {fact: expiry time (INF while in progress)}.
static var _kb := {}


func _scope_key(scope: String) -> String:
	match scope:
		"Attacker":
			return "a%d" % z.get_instance_id()
		"Target":
			return "t%d" % _tid()
	return "global"


func _kb_has(scope: String, fact: String) -> bool:
	return float(_kb.get(_scope_key(scope), {}).get(fact, -1.0)) > clock


func _kb_set(scope: String, fact: String, until: float) -> void:
	_kb.get_or_add(_scope_key(scope), {})[fact] = until


func _tid() -> int:
	return z.target.get_instance_id() if is_instance_valid(z.target) else 0


## Warm-up (FUN_141051530): passes without a WarmUpStartedFactName; else the start fact must exist, its value is the
## start time, a warm-up is sampled whenever that value changes (AttackRules_<Name>_WarmUpGenerated), and the check
## passes once now - start >= the warm-up.
func _warm_ok(a: Dictionary, warm_fact: String) -> bool:
	if warm_fact == "" or warm_fact == "None":
		return true
	if not fact_times.has(warm_fact):
		return false
	var n := str(a.get("Name", ""))
	var t0: float = fact_times[warm_fact]
	if not warmups.has(n) or float(warmups[n][0]) != t0:
		warmups[n] = [t0, sample(a.get("WarmUp"), 0.0)]
	return now - t0 >= float(warmups[n][1])


func rules_allow(rules: Array, warm_fact := "") -> bool:
	for r in rules:
		var a := asset(str(r))
		if a.is_empty():
			continue
		if not _warm_ok(a, warm_fact):
			return false
		var n := "AttackRules_" + str(a.get("Name", r))
		for sc in ["Attacker", "Target", "Global"]:
			if _kb_has(sc, n + "_" + sc + "_Started") or _kb_has(sc, n + "_" + sc + "_InProgress"):
				return false
	return true


## An attack under these rules commits (its CommitExpression holds; the port commits when the action starts).
func rules_started(rules: Array) -> void:
	for r in rules:
		var a := asset(str(r))
		if a.is_empty():
			continue
		var n := "AttackRules_" + str(a.get("Name", r))
		var cds := {"Attacker": sample(a.get("AttackerPostEndCooldown"), -1.0),
			"Target": sample(a.get("TargetPostEndCooldown"), -1.0), "Global": sample(a.get("GlobalPostEndCooldown"), -1.0)}
		var starts := {"Target": float(a.get("TargetPostStartCooldown", 0.0)), "Global": float(a.get("GlobalPostStartCooldown", 0.0))}
		for sc: String in cds:
			if starts.get(sc, 0.0) > 0.0:
				_kb_set(sc, n + "_" + sc + "_Started", clock + float(starts[sc]))
			if float(cds[sc]) >= 0.0:
				_kb_set(sc, n + "_" + sc + "_InProgress", INF)
				_cooldowns[n + "|" + sc] = cds[sc]


var _cooldowns := {}
var _nth := {}                    # CardGenerator_EveryNthDraw state: generator hash -> [draws, N]
var _peek_path: Array = []        # the path array peek() passes (no draw side effects)
var _draw_rules: Array = []       # AttackRules of the generators that dealt the last drawn card


## The attack under these rules ended: _Started goes now, _InProgress after its sampled cooldown.
func rules_ended(rules: Array) -> void:
	for r in rules:
		var a := asset(str(r))
		if a.is_empty():
			continue
		var n := "AttackRules_" + str(a.get("Name", r))
		for sc in ["Attacker", "Target", "Global"]:
			if _kb_has(sc, n + "_" + sc + "_Started"):
				_kb_set(sc, n + "_" + sc + "_Started", -1.0)
			if _cooldowns.has(n + "|" + sc):
				_kb_set(sc, n + "_" + sc + "_InProgress", clock + float(_cooldowns[n + "|" + sc]))
				_cooldowns.erase(n + "|" + sc)


# --- card player ----------------------------------------------------------------------------------------------------

## Card params by class (CDOs from extracted/json_bp; section 4b):
## BP_ActionParams_Wait_AI: MinimumDurationExpression 0.5, MaximumDurationExpression 99999, PeekedCardCheckInterval 0.3,
## CardCounterModificationOnBegin sets ActiveCombat = 0. BP_ActionParams_Strafe_AI: MinDuration 1.0, direction
## EStrafeDirection (default Left, RandomiseStrafeDirection picks at random); BP_Action_Strafe_AI peeks every
## CheckPeakedCardFrequency 0.5 s from MinDuration on and ends when the peek differs from PeakedCardToMaintainAction;
## its hard-coded duration is 20 s (EndAction(0, 20.0)).
func _start_card(name: String) -> void:
	var c := asset(name)
	var act := str(c.get("Action", "")).trim_prefix("@")
	var p: Dictionary = c.get("Parameters", {}) if c.get("Parameters") is Dictionary else {}
	var ptype := str(p.get("$t", ""))
	play = {"name": name, "card": c, "action": act, "t": 0.0, "ok": true, "p": p, "next_peek": 0.0}
	# The dealing generators' AttackRules are in progress while the card plays (UNVERIFIED: commit at card start vs
	# at the CommitExpression; section 7).
	play["gen_rules"] = _draw_rules.duplicate()
	rules_started(play["gen_rules"])
	for f in c.get("LifetimeFacts", []) + asset(act).get("LifetimeFacts", []):
		facts[str(f.get("NameStorage", f) if f is Dictionary else f)] = true
	var seq := str(p.get("AttackSequence", "")).trim_prefix("@")
	if seq == "" and str(p.get("AnimSetName", "")) != "":
		# BP_ActionParams_EnterCombat_AI / AnimSet params: one anim-set action (EnterCombat roar etc.), its
		# AdditionalResolutionFacts.CounterFacts held while it plays (e.g. MovingEnterCombat picks the moving variant).
		for f in p.get("AdditionalResolutionFacts", {}).get("CounterFacts", []):
			facts[str(f.get("NameStorage", ""))] = true
			_self_facts[str(f.get("NameStorage", ""))] = true
		play["kind"] = "sequence"
		play["units"] = [{"AnimSetName": str(p["AnimSetName"])}]
		play["unit"] = -1
		play["min"] = 0.0
		play["max"] = INF
		return
	if seq != "":
		play["kind"] = "sequence"
		play["units"] = asset(seq).get("Units", [])
		play["unit"] = -1
		play["min"] = 0.0
		play["max"] = INF
		return
	if ptype.begins_with("BP_ActionParams_Strafe_AI"):
		play["kind"] = "strafe"
		var dir := str(p.get("StrafeDirection", "EStrafeDirection::Left"))
		if bool(p.get("RandomiseStrafeDirection", false)):
			dir = "Left" if rng.randf() < 0.5 else "Right"
		play["side"] = 1.0 if dir.ends_with("Right") else -1.0
		play["min"] = float(p.get("MinDuration", 1.0))
		play["max"] = 20.0
		play["keep"] = str(p.get("PeakedCardToMaintainAction", "")).trim_prefix("@")
		play["interval"] = 0.5
		return
	play["kind"] = "stand" if act.contains("Stationary") else "move"
	play["min"] = float(DI2Expr.value(str(p.get("MinimumDurationExpression", {}).get("Expression", "0.5")), _self_facts))
	play["max"] = float(DI2Expr.value(str(p.get("MaximumDurationExpression", {}).get("Expression", "99999")), _self_facts))
	if str(p.get("MinimumDurationModifier", "")) == "@DA_AttributeType_AttackSpacingDuration":
		play["min"] *= _arch_attack("cooldown", 1.0)   # x AIAttributeValues AttackSpacingDuration (UNVERIFIED: x vs +)
	play["keep"] = str(p.get("SelfPeekedCard", "")).trim_prefix("@")
	play["interval"] = float(p.get("PeekedCardCheckInterval", 0.3))
	if ptype.begins_with("BP_ActionParams_Wait"):
		var begin: Array = p.get("CardCounterModificationOnBegin", [{"CountersToSet": [{"Key": "ActiveCombat", "Value": {"AbsoluteValue": 0}}]}])
		for m in begin:
			_counters(m)


## A wait / strafe card ends at its maximum duration, or after its minimum duration when a peek (every interval) deals
## a card other than the one it maintains (none: any card; UNVERIFIED for WaitAction, decoded for Strafe).
func _should_end() -> bool:
	if play.is_empty():
		return true
	if play.get("done", false):
		return float(play["t"]) >= float(play.get("min", 0.0))
	if play["kind"] in ["sequence", "scream"]:
		return false
	var t: float = play["t"]
	if t < float(play["min"]):
		return false
	if t >= float(play["max"]):
		return true
	if t < float(play["next_peek"]):
		return false
	play["next_peek"] = t + float(play["interval"])
	return peek() != str(play["keep"])


func _end_play(ok: bool) -> void:
	if play.is_empty():
		return
	if play.has("sm"):
		# The card ends under the state machine (hit reaction, combat ended): its Scream action is cancelled
		# (reason 2, UNVERIFIED) and its lifetime facts drop.
		_scream_effects_end(play["sm"], 2)
		for f in play["sm"]["facts"]:
			facts.erase(str(f))
	var c: Dictionary = play["card"]
	_counters(c.get("CounterModificationOnSuccess" if ok else "CounterModificationOnFailure", {}))
	for f in c.get("LifetimeFacts", []) + asset(play["action"]).get("LifetimeFacts", []):
		facts.erase(str(f.get("NameStorage", f) if f is Dictionary else f))
	for f in play["p"].get("AdditionalResolutionFacts", {}).get("CounterFacts", []):
		facts.erase(str(f.get("NameStorage", "")))
	var fe := str(play["p"].get("AttackRulesFactToSetOnEnd", {}).get("NameStorage", "")) if play["p"].get("AttackRulesFactToSetOnEnd") is Dictionary else ""
	if fe != "":
		_set_fact(fe, true)
	if play.has("rules"):
		rules_ended(play["rules"])
	rules_ended(play.get("gen_rules", []))
	var suicide := ok and play.has("unit_end") and str(asset(play["action"]).get("Implementation", "")).trim_prefix("@") == SUICIDE_ACTION
	play = {}
	if suicide and not z.dead:
		_suicide_success()   # the detonation montage ended uninterrupted (OnCompleted / OnBlendOut)


func _tick_card(delta: float, cmd: Dictionary, dist_m: float, target: Node3D) -> void:
	play["t"] = float(play["t"]) + delta
	cmd["face"] = true
	match str(play["kind"]):
		"move":
			# Approach moves to the engagement-ring point: it holds once inside the ring's occupy radius + tolerance
			# (BPC_CombatAggro InnerRingOccupyRadius / OccupyTolerance; UNVERIFIED stand-in for EQSQuery_Surround).
			if dist_m * 100.0 > _aggro("InnerRingOccupyRadius") + _aggro("OccupyTolerance"):
				cmd["speed"] = move_speed(dist_m)
				cmd["anim"] = "Crawl" if z.gore.is_crawling() else "Chase"
			else:
				cmd["anim"] = "CrawlIdle" if z.gore.is_crawling() else "Idle"
		"strafe":
			var to: Vector3 = target.global_position - z.global_position
			to.y = 0.0
			cmd["move_dir"] = to.normalized().cross(Vector3.UP) * float(play["side"])
			cmd["speed"] = move_speed(dist_m)
			cmd["anim"] = "Chase"
		"stand":
			cmd["anim"] = "CrawlIdle" if z.gore.is_crawling() else "Idle"
		"sequence":
			_tick_sequence(cmd, dist_m)
		"scream":
			_tick_scream(cmd, target)


## Attack sequence: units in order; a melee unit picks its wind-up (first whose Condition holds) and the attack whose
## reach fits the distance (section 7: provisional), plays its montage and deals damage in its AIDetectMeleeHits window.
func _tick_sequence(cmd: Dictionary, dist_m: float) -> void:
	if play.has("unit_end") and play["t"] < float(play["unit_end"]):
		cmd["anim"] = "Attack"
		_tick_streams(dist_m)
		var hit_t: float = play.get("hit_t", -1.0)
		if hit_t >= 0.0 and play["t"] >= hit_t and not play.get("hit_done", false):
			play["hit_done"] = true
			cmd["damage"] = float(play.get("damage", 0.0))
		return
	if play.has("rules"):
		rules_ended(play["rules"])
		play.erase("rules")
	play["unit"] = int(play["unit"]) + 1
	var units: Array = play["units"]
	if int(play["unit"]) >= units.size():
		play["done"] = true
		return
	var u: Dictionary = units[int(play["unit"])]
	# DI2's melee action closes in while it winds up (move target AIMeleeAction; DA_MovementSpeed "InWindUp" entry):
	# the attack montage starts once inside reach. Reach = the old port's long band 1.7 m (UNVERIFIED 88); the wind-up
	# is cancelled past CancelWindUpAfterSeconds (5) or beyond CancelWindUpAtDistance (1050 cm).
	if u.has("AttackDefinition") and dist_m > 1.7:
		if not play.has("windup_t0"):
			play["windup_t0"] = play["t"]
		var wt: float = float(play["t"]) - float(play["windup_t0"])
		facts["InWindUp"] = true
		play["unit"] = int(play["unit"]) - 1
		if wt > 5.0 or dist_m * 100.0 > 1050.0:
			facts.erase("InWindUp")
			play["done"] = true
			play["ok"] = false
			return
		cmd["speed"] = move_speed(dist_m)
		cmd["anim"] = "Crawl" if z.gore.is_crawling() else "Chase"
		return
	facts.erase("InWindUp")
	play.erase("windup_t0")
	var act_def := _unit_action(u)
	if str(action_def(act_def).get("impl", "")) == SM_SCREAM:
		_scream_begin(act_def)   # the archetype's own "EnterCombat" action: the scream state machine
		return
	var start := _start_unit(u, dist_m)
	if start.is_empty():
		if u.has("AnimSetName") and not u.has("AttackDefinition"):
			_skip_unit()
			return
		play["done"] = true
		play["ok"] = false
		play["min"] = 0.3   # nothing playable for this body: hold one PeekedCardCheckInterval (UNVERIFIED) before re-dealing
		return
	if start.get("anim_set", false):
		# A non-attack montage (idle break, scream): played here like zombie_reactions plays DI2 montages.
		if start["clip"] != "":
			z._play_once(str(start["clip"]), float(start["length"]))
		else:
			z.anim_ctl.play_montage(str(start["montage"]))
			z.lock_time = float(start["length"])
		_streams_begin(str(start["montage"]))   # its projectile-stream windows (ranged fire modes)
		for f in u.get("FactsToIncrement", []):
			var fn := str(f.get("NameStorage", "")) if f is Dictionary else str(f)
			_set_fact(fn, int(facts.get(fn, 0)) + 1)
	else:
		cmd["attack"] = play["name"]
		cmd["clip"] = start["clip"]
		attack_log.append([snappedf(now, 0.01), start["montage"], start["clip"]])
		cmd["attack_len"] = start["length"]
	cmd["anim"] = "Attack"
	play["unit_end"] = float(play["t"]) + float(start["length"])
	play["hit_t"] = float(play["t"]) + float(start["hit"]) if start["hit"] >= 0.0 else -1.0
	play["hit_done"] = false
	play["damage"] = start["damage"]
	play["rules"] = start["rules"]
	rules_started(start["rules"])
	if not start.get("anim_set", false):
		_set_fact("IsAttacking", true)   # #HasEverAttacked = hasfact("none", "IsAttacking")


## An anim-set unit this body has no montage for: skipped (the next unit, or the card ends after 0.3 s).
func _skip_unit() -> void:
	play["min"] = 0.3
	if int(play["unit"]) + 1 >= play["units"].size():
		play["done"] = true


func _start_unit(u: Dictionary, dist_m: float) -> Dictionary:
	if str(u.get("AnimSetName", "")) != "" and not u.has("AttackDefinition"):
		return _start_anim_set(str(u["AnimSetName"]))
	var def := asset(str(u.get("AttackDefinition", "")))
	if def.is_empty():
		return {}
	var wu := {}
	for w in def.get("WindUps", []):
		if expr(w.get("Condition", "")):
			wu = w
			break
	if wu.is_empty():
		return {}
	var choice := pick_attack(wu.get("Attacks", []), dist_m)
	if choice.is_empty():
		return {}   # this body lacks the montage DI2 picks: nothing playable (no stand-in clip)
	choice["wu"] = wu
	choice["rules"] = def.get("AttackRules", [])
	choice["damage"] = _damage(u)
	return choice


## The montage DI2's anim set `set_name` picks for class `arch_name` (zombie_ai.json anim_sets from its
## AnimSetCollections): a single montage, or the first group whose expression holds, an item by weight from `r`
## (UNVERIFIED for "Random" order: weighted pick). Only montages in montages_zombie.json; "" for none.
static func pick_set_montage(arch_name: String, set_name: String, f: Dictionary, r: RandomNumberGenerator) -> String:
	_load()
	var e: Dictionary = data.get("anim_sets", {}).get(arch_name, data.get("anim_sets", {}).get("Walker", {})).get(set_name, {})
	if e.has("montage"):
		return str(e["montage"])
	var sd: Dictionary = data.get("anim_sets", {}).get("_data", {}).get(str(e.get("set", "")), {})
	for g: Dictionary in sd.get("groups", []):
		if not DI2Expr.eval(str(g.get("expr", "")), f):
			continue
		var items: Array = g.get("items", []).filter(func(it): return ZombieAnim.zdata.get("montages", {}).has(str(it[1])))
		if items.is_empty():
			continue
		var total := 0.0
		for it in items:
			total += float(it[0])
		var x := r.randf() * total
		for it in items:
			x -= float(it[0])
			if x < 0.0:
				return str(it[1])
		return str(items[-1][1])
	return ""


## AttackSequenceUnit_AnimSetAction / BP_AttackSequenceUnit_AnimSetAction_IdleBreak: play the archetype's anim set
## (zombie_ai.json anim_sets, its AnimSetCollections): a single montage, or the first group whose expression holds,
## an item picked by weight (UNVERIFIED for "Random" order: weighted pick). {} when nothing playable.
func _start_anim_set(set_name: String) -> Dictionary:
	var am := pick_set_montage(arch, set_name, _self_facts, rng)
	var md: Dictionary = ZombieAnim.zdata.get("montages", {}).get(am, {})
	if md.is_empty():
		return {}
	var segs: Array = md.get("segments", {}).get(str(z.body), [])
	if segs.is_empty() or not segs.all(func(sg): return z.anim_ctl.a.has_clip(sg[0])):
		return {}
	return {"anim_set": true, "montage": am, "clip": clip_for(am), "length": float(md.get("length", 1.0)), "hit": -1.0,
		"damage": 0.0, "rules": []}


## What zombie.gd plays for attack montage `am`: its body clip (by_clip), else the montage name when every segment
## clip of this body resolves (attacks2 "x:<seq>" sets; ZombieAnim.play / montage_for accept a montage name), else "".
func attack_clip_for(am: String) -> String:
	var c := clip_for(am)
	if c != "":
		return c
	var segs: Array = ZombieAnim.zdata.get("montages", {}).get(am, {}).get("segments", {}).get(str(z.body), [])
	if segs.is_empty() or not segs.all(func(sg): return str(sg[0]) != "" and z.anim_ctl.a.has_clip(str(sg[0]))):
		return ""
	return am


## Body clip that plays DI2 montage `am` (montages_zombie.json by_clip, reversed), "" when the body can't play it.
func clip_for(am: String) -> String:
	var by: Dictionary = ZombieAnim.zdata.get("by_clip", {}).get(str(z.body), {})
	var best := ""
	for c: String in by:
		if by[c] == am and (best == "" or c.length() > best.length()):
			best = c   # the specific clip name (attack_swipe_rh_horiz_attack_med) over the generic alias (attack_swipe_r)
	return best


## The attack of a wind-up's Attacks[] (Short / Med / Long) to play at `dist_m`: exactly the montage DI2 picks
## (_attack_index, section 7), {} when this body can't play it. Returns {clip (a body clip, or the montage name when
## only its segments resolve, e.g. the attacks2 "x:<seq>" clips; ZombieAnim.play takes both), montage, length,
## hit (s after start, -1 none)}.
func pick_attack(attacks: Array, dist_m: float) -> Dictionary:
	if attacks.is_empty():
		return {}
	var i := clampi(_attack_index(attacks, dist_m), 0, attacks.size() - 1)
	var am := str(attacks[i].get("Montage", "")).trim_prefix("@")
	var c := attack_clip_for(am)
	if c == "":
		return {}
	var md: Dictionary = ZombieAnim.zdata.get("montages", {}).get(am, {})
	# ZombieAnim.play runs the montage's wind-up first (montages_zombie.json windup: [fixed montage, Duration, def]).
	var wu: Array = ZombieAnim.zdata.get("windup", {}).get(am, ["", 0.0, ""])
	var lead := float(wu[1]) if (str(wu[0]) != "" or (wu.size() > 2 and str(wu[2]) != "")) else 0.0
	var hit := -1.0
	for n: Array in md.get("notifies", []):
		if str(n[0]).contains("AIDetectMeleeHits"):
			hit = lead + float(n[1])
			break
	return {"clip": c, "montage": am, "length": lead + float(md.get("length", 1.0)), "hit": hit}


## Index into Attacks[] (0 Short, 1 Med, 2 Long) for the distance. UNVERIFIED stand-in until the native melee action's
## choice is decoded (section 7): the old port bands (< 1.2 m short, < 1.7 m med, else long).
func _attack_index(attacks: Array, dist_m: float) -> int:
	if attacks.size() <= 1:
		return 0
	return 0 if dist_m < 1.2 else (1 if dist_m < 1.7 or attacks.size() < 3 else 2)


## Damage of a melee unit: the archetype's BaseDamageAttribute (DA_AIAttributeValues_<Type>, via archetypes.json card
## damage at multiplier 1). UNVERIFIED: DI2's per-attack scaling (EffectivenessModifier, impact profiles).
func _damage(_u: Dictionary) -> float:
	return _arch_attack("damage", 0.0)


# --- archetype actions: the Screamer's scream (recon/ZOMBIE_AI.md 9) -------------------------------------------------

## BP_Action_ScreamStateMachine_Screamer_C: the class that DA_ActionDefinition_ScreamStateMachine_Screamer (Name
## "EnterCombat") implements. BP_Base_Screamer's BPC_AI_CharacterAction.ArchetypeSpecificActionDefinitions
## (DA_ActionDefinitions_AI_Screamer) maps the scream card's AnimSetAction unit (ActionName "EnterCombat") to it.
const SM_SCREAM := "BP_Action_ScreamStateMachine_Screamer_C"
## State machine states (GetNextState / BeginState byte values): 1 WindUp, 2 Scream, 3 Outro, 4 EndAction.
enum { SM_WINDUP = 1, SM_SCREAM_STATE = 2, SM_OUTRO = 3, SM_END = 4 }

var statuses := {}                # status effect name -> until (own AI time; INF while a source holds it)
var scream_log: Array = []        # [time, event] (tests)


## Archetype-specific action definition for an AnimSetAction unit's ActionName (zombie_ai.json actions), "" = generic.
func _unit_action(u: Dictionary) -> String:
	return str(data.get("actions", {}).get(arch, {}).get(str(u.get("ActionName", "")), ""))


static func action_def(dn: String) -> Dictionary:
	_load()
	return data.get("action_defs", {}).get(dn.trim_prefix("@"), {})


## A status effect on this zombie: DI2's status component exposes it to the KB as fact StatusEffect_<Name> (the decks
## read StatusEffect_Aggressive, e.g. DA_AnimSet_Roar_Thug, the Thug smash wind-ups). `dur` < 0: held until removed.
func status_add(n: String, dur: float) -> void:
	statuses[n] = INF if dur < 0.0 else now + dur
	facts["StatusEffect_" + n] = true


func _status_tick() -> void:
	for n: String in statuses.keys():
		if now >= float(statuses[n]):
			statuses.erase(n)
			facts.erase("StatusEffect_" + n)


func _sm_log(ev: String) -> void:
	scream_log.append([snappedf(now, 0.01), ev])


## OnBegin (BP_Action_ScreamStateMachine_Screamer ubergraph 30): SetState(Crawler || AmbushSkipWindUp ? Scream : WindUp).
## d = the state machine's class defaults, s = BP_Action_Scream_Screamer's (its ScreamActionDefinition's
## implementation); the action definition's LifetimeFacts (StopEngagement, StopCombatTimers, ScreamAttack) hold
## while it runs.
func _scream_begin(dn: String) -> void:
	var ad := action_def(dn)
	var d: Dictionary = ad.get("defaults", {})
	var sad := action_def(str(d.get("ScreamActionDefinition", "")))
	play["kind"] = "scream"
	play["min"] = 0.0
	play["sm"] = {"d": d, "s": sad.get("defaults", {}), "state": 0, "end": INF, "effects_t": INF, "on": false,
		"facts": ad.get("LifetimeFacts", []) + sad.get("LifetimeFacts", []), "inside": {}, "player_in": false}
	for f in play["sm"]["facts"]:
		facts[str(f)] = true
	_sm_log("begin " + dn)
	_scream_set(SM_SCREAM_STATE if expr("Crawler || AmbushSkipWindUp") else SM_WINDUP)


## SetState: EndState (the running sub-action is cancelled), CurrentState = next, BeginState.
func _scream_set(st: int) -> void:
	var sm: Dictionary = play["sm"]
	sm["state"] = st
	var t: float = play["t"]
	match st:
		SM_WINDUP:
			# BeginWindUpState(ScreamWindup): anim set AnimSetName ("Scream") with CounterFacts [ScreamWindup]
			# (DA_AnimSet_Scream_Screamer: "!Crawler && ScreamWindup" -> AM_ZMB_Screamer_Attack_Scream_Windup).
			var f := _self_facts.duplicate()
			f["ScreamWindup"] = true
			_scream_play(str(sm["d"].get("AnimSetName", "Scream")), f, -1.0)
		SM_SCREAM_STATE:
			# BeginScreamState: the Scream action (DA_ActionDefinition_Scream_Screamer -> BP_Action_Scream_Screamer)
			# with anim set "Scream" resolved with the ScreamAngle fact (GetCombatTargetsDirectionAngleResolutionFact).
			var f := _self_facts.duplicate()
			f["ScreamAngle"] = _scream_angle(sm["d"])
			_sm_log("ScreamAngle %.1f" % float(f["ScreamAngle"]))
			if _scream_play(str(sm["s"].get("AnimSetName", "Scream")), f, -1.0):
				sm["end"] = INF   # the Loop section loops; the Scream action's timers end it
				sm["effects_t"] = t + float(sm.get("effects_lead", 0.0))
		SM_OUTRO:
			# BeginOutroState: BP_ActionParams_AnimSet_AI, AnimSetName 'ScreamEnd', BlendOutDurationOverride 0.8,
			# ThresholdInterruptionParams {DamageRequiredAsHealthPortion 0.1} (UNVERIFIED: not tracked here).
			_scream_play("ScreamEnd", _self_facts, 0.8)
		SM_END:
			# BeginState default: EndAction(0) -> the card succeeds.
			_sm_log("end")
			play["done"] = true
			play["ok"] = true


## Plays the anim set's montage; the sub-action ends at the montage's blend-out start (MontageEndEvent byte 1 =
## EMontageEndEvent::MontageBlendingOut, as the scream card's unit names it; UNVERIFIED enum order). `blend_out` >= 0
## overrides the montage's BlendOut time. No montage for this body: the sub-action fails (reason 1).
func _scream_play(set_name: String, f: Dictionary, blend_out: float) -> bool:
	var sm: Dictionary = play["sm"]
	var am := pick_set_montage(arch, set_name, f, rng)
	var md: Dictionary = ZombieAnim.zdata.get("montages", {}).get(am, {})
	var m = z.anim_ctl.play_montage(am) if not md.is_empty() else null
	_sm_log("%s -> %s%s" % [set_name, am, "" if m != null else " (not playable)"])
	if m == null and not md.is_empty():
		# Diagnostics: which segment clip this body lacks, and the body's clips of that family.
		var segs: Array = md.get("segments", {}).get(str(z.body), [])
		_sm_log("  body %s segments %s; player clips %s" % [str(z.body),
			segs.map(func(sg): return "%s:%s" % [sg[0], z.anim_ctl.a.has_clip(str(sg[0]))]),
			Array(z.anim.get_animation_list()).filter(func(c): return str(c).contains(set_name.to_lower().left(5)))])
	if m == null:
		sm["end"] = float(play["t"])
		sm["fail"] = true
		return false
	var bo := blend_out if blend_out >= 0.0 else float(md.get("blend_out", [0.0])[0])
	sm["end"] = float(play["t"]) + maxf(float(md.get("length", 1.0)) - bo, 0.0)
	sm["montage"] = am
	# The Loop montage's AnimNotifyState_ScopedFacts {FactsArray: [ScreamEffectsBegin]} (AM_ZMB_Screamer_Attack_
	# Scream_Loop: 0.5984 s, and ~0.6 s in the angled loops) raises the fact the Scream action waits for.
	sm["effects_lead"] = INF
	for n: Array in md.get("notifies", []):
		if str(n[0]) == "ScopedFacts":
			sm["effects_lead"] = float(n[1])
			break
	return true


## GetCombatTargetsDirectionAngleResolutionFact: unless SkipScreamDirectionalAngleAdjustmentExpression
## ("AmbushSkipWindUp") holds or the search location is invalid, ScreamAngle = DetermineFacingActorOffset2D(Screamer,
## CombatTarget) degrees, negated when (ActorRight * SearchDirection).X + .Y < 0, i.e. the target is on the left
## (the anim set's L45..L180 bands are negative). UNVERIFIED: DetermineFacingActorOffset2D returns the unsigned
## angle (BPFL_GeneralFunctions not decoded); the search location is the target's position here.
func _scream_angle(d: Dictionary) -> float:
	var skip := str(d.get("SkipScreamDirectionalAngleAdjustmentExpression", {}).get("Expression", ""))
	if skip != "" and expr(skip):
		return 0.0
	var tgt: Node3D = z.target
	if not is_instance_valid(tgt):
		return 0.0
	var fwd := -z.global_basis.z
	fwd.y = 0.0
	var to := tgt.global_position - z.global_position
	to.y = 0.0
	if fwd.length() < 1e-4 or to.length() < 1e-4:
		return 0.0
	var deg := rad_to_deg(fwd.normalized().angle_to(to.normalized()))
	return -deg if z.global_basis.x.dot(to) < 0.0 else deg


func _tick_scream(cmd: Dictionary, target: Node3D) -> void:
	var sm: Dictionary = play["sm"]
	var t: float = play["t"]
	cmd["anim"] = "Attack"
	cmd["face"] = false   # the montage turns the Screamer (ScreamAngle bands), the action doesn't rotate it
	z.lock_time = maxf(z.lock_time, 0.1)
	var st := int(sm["state"])
	if st == SM_SCREAM_STATE:
		if not sm["on"] and t >= float(sm["effects_t"]):
			_scream_effects_begin(sm, t)
		if sm["on"]:
			_scream_sphere(sm, target)
			var s: Dictionary = sm["s"]
			# OnScreamDurationOver: MaxDuration (12 s) after the effects began -> EndAction(0).
			if t >= float(sm["max_t"]):
				_scream_end(0)
				return
			# OnMinDurationOver: after MinDuration (2 s), DetermineIfPrematureEnd every DetermineIfPrematureEndFrequency
			# (0.5 s): IsActorFacingActor2D(Screamer, CombatTarget, FacingTargetAngleToMaintainScream 180, bInverse
			# true) -> EndAction(2), i.e. the target left the front half (full-cone reading, UNVERIFIED 85 style).
			if t >= float(sm["min_t"]) and t >= float(sm["next_check"]):
				sm["next_check"] = t + float(s.get("DetermineIfPrematureEndFrequency", 0.5))
				if not _facing({"MaxFacingAngle": float(s.get("FacingTargetAngleToMaintainScream", 180.0))}):
					_scream_end(2)
					return
			# EstablishAdditionalCancelationSettings (DelayBeforeAdditionalCancellationSettings 1.5 s): an expression
			# listener on DamageOverTimeStatusEffectExpression (#DamageOverTimeStatusEffect) -> EndAction(2).
			var dot := str(s.get("DamageOverTimeStatusEffectExpression", {}).get("Expression", ""))
			if t >= float(sm["dot_t"]) and dot != "" and expr(dot):
				_scream_end(2)
				return
			# ThresholdInterruptionParams (DamageRequiredAsHealthPortion 0.12): OnDamageThresholdForHitReact-
			# VulnerabilityReached increments VulnerabilityFact (MadeVulnerableByDamageThresholdReached).
			if not sm.get("vulnerable", false) and float(sm["hp0"]) - z.gore.get_health() >= \
					float(s.get("DamageThresholdForVulnerability", 0.12)) * maxf(z.gore.get_max_health(), 1.0):
				sm["vulnerable"] = true
				var vf := str(s.get("VulnerabilityFact", {}).get("NameStorage", "MadeVulnerableByDamageThresholdReached"))
				_set_fact(vf, int(facts.get(vf, 0)) + 1)
				_sm_log("vulnerable")
		elif t >= float(sm["end"]):
			_scream_next(1 if sm.get("fail", false) else 0)   # the Loop montage could not play
		return
	if t >= float(sm["end"]):
		_scream_next(1 if sm.get("fail", false) else 0)


## OnActionEnded -> GetNextState(reason): WindUp: 0 -> Scream, else End; Scream: 0/1/2 -> Outro, 3 -> End;
## Outro -> End.
func _scream_next(reason: int) -> void:
	var sm: Dictionary = play["sm"]
	sm.erase("fail")
	match int(sm["state"]):
		SM_WINDUP:
			_scream_set(SM_SCREAM_STATE if reason == 0 else SM_END)
		SM_SCREAM_STATE:
			_scream_set(SM_OUTRO if reason <= 2 else SM_END)
		_:
			_scream_set(SM_END)


## The Scream action ends (EndAction(reason)): UnintialiseScreamEffects, then the state machine moves on.
func _scream_end(reason: int) -> void:
	_scream_effects_end(play["sm"], reason)
	_scream_next(reason)


## IntialiseScreamEffects (ScreamEffectsBegin raised): PlayCE_OnBegin, NumberOfScreamsStarted + 1, SpawnStim,
## SpawnExplosion, SummonZombieBackup, BehaviourModifiersToApplyDuringScream; the ubergraph then starts the
## MaxDuration / MinDuration timers and, after DelayBeforeAdditionalCancellationSettings, the DoT listener.
func _scream_effects_begin(sm: Dictionary, t: float) -> void:
	var s: Dictionary = sm["s"]
	sm["on"] = true
	sm["max_t"] = t + float(s.get("MaxDuration", 12.0))
	sm["min_t"] = t + float(s.get("MinDuration", 2.0))
	sm["next_check"] = sm["min_t"]
	sm["dot_t"] = t + float(s.get("DelayBeforeAdditionalCancellationSettings", 1.5))
	sm["hp0"] = z.gore.get_health()
	sm["t_on"] = now
	_set_fact("NumberOfScreamsStarted", int(facts.get("NumberOfScreamsStarted", 0)) + 1)
	_sm_log("effects begin")
	# PlayCE_OnBegin: Blood_CE and Continuous_CE (+Continuous_CE_Offset Z 22 cm) at CE_MouthAttachSocket head_mouth.
	for k in ["Blood_CE", "Continuous_CE"]:
		_scream_ce(str(s.get(k, "")), Vector3(0, 0.22, 0) if k == "Continuous_CE" else Vector3.ZERO)
	# SpawnExplosion: ExplosionArchetypeIdentifier 'Explosion_Scream' through the anim set (DA_DataSetCollection_
	# Explosions_Screamer -> DA_ExplosionArchetype_Scream_Screamer) at socket SpawnExplosionFromBone ("Head"), with
	# the mesh rotation (the archetype's AngleScaleCurve; DI2Explosion has no angle scale yet).
	var ex := str(data.get("explosion_sets", {}).get(arch, {}).get("Explosion_Scream", ""))
	if ex != "":
		DI2Explosion.spawn(z.get_parent(), ex, _bone_pos(str(s.get("SpawnExplosionFromBone", "Head")).to_lower()), z)
		_sm_log("explosion " + ex)
	# SpawnStim (DA_Stim_HearScream, YelpRadius 4000 cm at the target), SummonZombieBackup (ScriptedSequenceComponent)
	# and BP_BehaviourModifier_RememberTarget: not ported (UNVERIFIED 90).


## UnintialiseScreamEffects(reason): PlayCE_OnEnd (NaturalEnd_CE for reasons 0 / 1, Interrupted_CE for 2 / 3),
## UninitialiseScreamCollision (everyone leaves the sphere: EndSphereOverlap), EndStim, RemoveHealthTracking.
func _scream_effects_end(sm: Dictionary, reason: int) -> void:
	if not sm.get("on", false):
		return
	sm["on"] = false
	var s: Dictionary = sm["s"]
	_sm_log("effects end %d" % reason)
	_scream_ce(str(s.get("NaturalEnd_CE" if reason <= 1 else "Interrupted_CE", "")), Vector3.ZERO)
	for id in sm["inside"].keys():
		_sphere_leave(sm, id)
	sm["player_in"] = false
	if sm.get("vulnerable", false):
		var vf := str(s.get("VulnerabilityFact", {}).get("NameStorage", "MadeVulnerableByDamageThresholdReached"))
		_set_fact(vf, maxi(int(facts.get(vf, 0)) - 1, 0))


## The ScreamSphere (BP_Base_Screamer SphereComponent, SphereRadius 1300 cm) overlap while the effects run:
## OnOverlapScreamSphere adds per faction reaction (AddOverlapStatusEffect): friendly zombies get
## BP_StatusEffect_Aggressive (Duration -1), the hostile player BP_StatusEffect_Slowed_Screamer; EndSphereOverlap
## swaps a zombie's held Aggressive for a lingering one (AddLingeringStatusEffect).
func _scream_sphere(sm: Dictionary, target: Node3D) -> void:
	var r := float(data.get("spheres", {}).get(arch, {}).get("ScreamSphere", 0.0)) / 100.0
	for n in z.get_tree().get_nodes_in_group("zombies"):
		if n == z or n.get("ai") == null or n.dead:
			continue
		var id: int = n.get_instance_id()
		var inside: bool = n.global_position.distance_to(z.global_position) <= r
		if inside and not sm["inside"].has(id):
			sm["inside"][id] = [n, now]
			n.ai.status_add("Aggressive", -1.0)
			_sm_log("aggressive " + str(n.name))
		elif not inside and sm["inside"].has(id):
			_sphere_leave(sm, id)
	var pin := is_instance_valid(target) and target.global_position.distance_to(z.global_position) <= r
	if pin != bool(sm["player_in"]):
		sm["player_in"] = pin
		# BP_StatusEffect_Slowed_Screamer on the player (MovementSpeedModifier -0.9 x distance / direction / angle
		# intensity curves): needs a player hook (UNVERIFIED 90); logged only.
		_sm_log("player %s sphere" % ("in" if pin else "out of"))


## AddLingeringStatusEffect: Aggressive for MapRangeClamped(time in the scream, MinDuration, MaxDuration,
## LingeringStatusEffectMinDuration 4, LingeringStatusEffectMaxDuration 12) s (ScaleLingeringAggressiveByTimeInScream),
## else LingeringStatusEffectDefaultDuration 15 s.
func _sphere_leave(sm: Dictionary, id: int) -> void:
	var e: Array = sm["inside"][id]
	sm["inside"].erase(id)
	var n = e[0]
	if not is_instance_valid(n) or n.get("ai") == null:
		return
	var s: Dictionary = sm["s"]
	var dur := float(s.get("LingeringStatusEffectDefaultDuration", 15.0))
	if bool(s.get("ScaleLingeringAggressiveByTimeInScream", true)):
		dur = remap(clampf(now - float(e[1]), float(s.get("MinDuration", 2.0)), float(s.get("MaxDuration", 12.0))),
			float(s.get("MinDuration", 2.0)), float(s.get("MaxDuration", 12.0)),
			float(s.get("LingeringStatusEffectMinDuration", 4.0)), float(s.get("LingeringStatusEffectMaxDuration", 12.0)))
	n.ai.status_add("Aggressive", dur)
	_sm_log("aggressive lingers %.1f s on %s" % [dur, str(n.name)])


## A cosmetic effect at the mouth (CE_MouthAttachSocket head_mouth) through DI2Particles; logged when the particles
## data lacks it.
func _scream_ce(ce: String, offset: Vector3) -> void:
	ce = ce.trim_prefix("@")
	if ce == "":
		return
	if not DI2Particles.db().get("ce", {}).has(ce):
		_sm_log("CE missing " + ce)
		return
	DI2Particles.play_ce(z.get_parent(), ce, _bone_pos("head_mouth") + offset, -z.global_basis.z, -z.global_basis.z)


func _bone_pos(bone: String) -> Vector3:
	var b: int = z.skeleton.find_bone(bone)
	if b < 0:
		_sm_log("bone missing " + bone)
		b = z.skeleton.find_bone("head")
	return z.skeleton.global_transform * z.skeleton.get_bone_global_pose(b).origin


# --- the Suicider's arming and detonation (recon/ZOMBIE_AI.md 10) ----------------------------------------------------

## BP_Action_SuicideDetonation_Suicider_C: DA_ActionDefinition_AI_Suicider_SuicideDetonation's implementation
## (DA_Card_SuicideDetonation_Suicider, AnimSetActionParams AnimSetName "Suicide"; LifetimeFacts CommittedToSuicide).
const SUICIDE_ACTION := "BP_Action_SuicideDetonation_Suicider_C"

var arming := 0.0                 # BP_Base_Suicider ArmingIntensity timeline position (0..1; curves span 0..1)
var arming_rate := 0.0            # timeline play rate (1 / Duration; negative while reversing, 0 paused / stopped)
var _arming_state := ""           # combat state the last ExecuteStateResponse ran for
var _arming_in_sphere := false
var _arming_hp := -1.0


func _bal(k: String, dflt: float) -> float:
	return float(data.get("balancing", {}).get(arch, {}).get(k, dflt))


## BP_Base_Suicider: CombatStateChanged -> ExecuteStateResponse (unless CommittedToSuicide): Calm (ECombatState 0) ->
## SetArming(false, ArmingCooldown 10); Combat (2) -> SetArming(true, FastTrackArmingDuration 0.5) when the combat target
## overlaps ExplosionExecutionSphere (ExecutionSphereRadius 250 cm), else SetArming(true, ArmingDuration 4); no target
## -> BoostIntensity(CatiousIntensityBoost 0.3, 0.3) + PauseArming. The sphere's begin overlap with the combat target
## fast-tracks too. SetArming: play rate 1 / Duration; active -> Play (or AttemptRequestSuicideExecution when already at
## 1), inactive -> Reverse. Timeline finished -> AttemptRequestSuicideExecution: position 1 and the target in the sphere
## -> KB bool fact TriggerSuicideAnticipation (DA_Deck_Suicider deals DA_Card_SuicideDetonation_Suicider on
## "TriggerSuicideAnticipation && DistanceFromTarget < 800"). OnDamageReceived -> BoostIntensity(clamp(DamageTaken /
## MaxHealth x DamagePortionToIntensityBoost 1, 0, DamageIntensityBoostCap 0.2), 1).
## UNVERIFIED (row 93): ECombatState 1 / 3 do nothing; the timeline length is 1 s of curve time.
func _suicider_tick(delta: float, dist_m: float) -> void:
	if not data.get("balancing", {}).has(arch) or not data["balancing"][arch].has("ArmingDuration"):
		return
	var hp: float = z.gore.get_health()
	if _arming_hp >= 0.0 and hp < _arming_hp and not facts.get("CommittedToSuicide", false):
		var boost := clampf((_arming_hp - hp) / maxf(z.gore.get_max_health(), 1.0) * _bal("DamagePortionToIntensityBoost", 1.0),
			0.0, _bal("DamageIntensityBoostCap", 0.2))
		_arming_boost(boost, 1.0)
	_arming_hp = hp
	if facts.get("CommittedToSuicide", false):
		return
	var in_sphere := is_instance_valid(z.target) and dist_m * 100.0 <= _bal("ExecutionSphereRadius", 250.0)
	if combat_state != _arming_state:
		_arming_state = combat_state
		if combat_state == "Calm":
			_set_arming(false, _bal("ArmingCooldown", 10.0))
		elif combat_state == "Combat":
			if not is_instance_valid(z.target):
				_arming_boost(_bal("CatiousIntensityBoost", 0.3), _bal("CatiousIntensityBoost", 0.3))
				arming_rate = 0.0
			else:
				_set_arming(true, _bal("FastTrackArmingDuration", 0.5) if in_sphere else _bal("ArmingDuration", 4.0))
	if in_sphere and not _arming_in_sphere:
		_set_arming(true, _bal("FastTrackArmingDuration", 0.5))   # BndEvt ExplosionExecutionSphere begin overlap
	_arming_in_sphere = in_sphere
	if arming_rate != 0.0:
		var was := arming
		arming = clampf(arming + arming_rate * delta, 0.0, 1.0)
		if arming >= 1.0 and was < 1.0:
			arming_rate = 0.0
			_attempt_suicide()   # ArmingIntensity__FinishedFunc
		elif arming <= 0.0:
			arming_rate = 0.0
	facts["CurrentArmingIntensity"] = arming


func _set_arming(active: bool, dur: float) -> void:
	var rate := 1.0 / maxf(dur, 1e-3)
	if active:
		if arming >= 1.0:
			_attempt_suicide()
		else:
			arming_rate = rate
	else:
		arming_rate = -rate


## BoostIntensity: when position < limit, position = clamp(position + portion x length, 0, limit).
func _arming_boost(portion: float, limit: float) -> void:
	if arming < limit:
		arming = clampf(arming + portion, 0.0, limit)


func _attempt_suicide() -> void:
	if arming >= 1.0 and _arming_in_sphere_now():
		_set_fact("TriggerSuicideAnticipation", true)
		_sm_log("TriggerSuicideAnticipation")


func _arming_in_sphere_now() -> bool:
	var tgt: Node3D = z.target
	return is_instance_valid(tgt) and tgt.global_position.distance_to(z.global_position) * 100.0 <= _bal("ExecutionSphereRadius", 250.0)


## BP_Action_SuicideDetonation_Suicider: the "Suicide" montage's OnCompleted / OnBlendOut (once) -> OnSuccessfulSuicide:
## SuccessfulSuicide counter + 1, then a GeneralImpactEvent on itself (ImpactGameplayCategory 6) and EndAction(0); its
## OnInterrupted -> OnUnsuccessfulSuicide (EndAction(1)). The death runs the class perk
## DA_PerkDefinition_RequestExplosionOnDeath_Suicider: explosion set Explosion_Suicide (DA_DataSet_Suicide_Suicider),
## the first group whose expression holds (IsBeingElectrocuted / IsCorroded / IsOnFire / IsDrained, else Suicide_Suicider).
## UNVERIFIED (row 93): the impact kills (category 6 read as the suicide kill); the explosion's origin (mesh bounds).
func _suicide_success() -> void:
	_set_fact("SuccessfulSuicide", int(facts.get("SuccessfulSuicide", 0)) + 1)
	var ex := suicide_explosion()
	_sm_log("suicide " + ex)
	var at := DI2Explosion.victim_point(z)
	z._die("spine_03", Vector3.UP, 0.0)
	if ex != "":
		DI2Explosion.spawn(z.get_parent(), ex, at, z)


## The Suicider's death explosion archetype for its current facts (zombie_ai.json explosion_sets Explosion_Suicide).
func suicide_explosion() -> String:
	var groups = data.get("explosion_sets", {}).get(arch, {}).get("Explosion_Suicide", [])
	if groups is String:
		return groups
	for g: Array in groups:
		if expr(str(g[0])):
			return str(g[1])
	return ""


## TEMPORARY until the special bodies get their own attack clip sets (coordinator Q17; UNVERIFIED 94): a melee card
## whose first unit's attack montage this body cannot play is left out of the deal, instead of being dealt, failing
## and re-dealt every 0.3 s. The montage is the one pick_attack takes at the distance the attack would start at (the
## wind-up walks in to the 1.7 m reach, UNVERIFIED 87 / 88). DI2 deals the card (every body has the clips there).
func _card_playable(c: String) -> bool:
	var seq := str(asset(c).get("Parameters", {}).get("AttackSequence", "")).trim_prefix("@")
	var units: Array = asset(seq).get("Units", []) if seq != "" else []
	if units.is_empty() or not (units[0] is Dictionary) or not units[0].has("AttackDefinition"):
		return true
	var def := asset(str(units[0]["AttackDefinition"]))
	var ok := false
	for w in def.get("WindUps", []):
		if expr(w.get("Condition", "")):
			ok = not pick_attack(w.get("Attacks", []), minf(_last_dist, 1.69)).is_empty()
			break
	if not ok:
		if not deal_skips.has(c):
			print("ZombieAI %s: %s left out of the deal (no playable attack montage for body %s)" % [arch, c, str(z.body)])
		deal_skips[c] = int(deal_skips.get(c, 0)) + 1
	return ok


# --- ranged fire modes: the Slobber's spit / spew / vomit (recon/ZOMBIE_AI.md 11) ------------------------------------

var shots_log: Array = []         # [time, fire mode, projectile] shots fired (tests)


## The anim-set montage's BP_AnimNotifyState_ActivateProjectileStream windows (montages_zombie.json notifies, paired by
## Duration with zombie_ai.json streams for their FireModeIdentifier / offsets): [start, end, params, next shot, shots].
func _streams_begin(am: String) -> void:
	var defs: Array = data.get("streams", {}).get(am, [])
	if defs.is_empty():
		return
	var list: Array = []
	for n: Array in ZombieAnim.zdata.get("montages", {}).get(am, {}).get("notifies", []):
		if str(n[0]) != "BP_ActivateProjectileStream":
			continue
		for d: Array in defs:
			if absf(float(d[0]) - float(n[2])) < 1e-3:
				list.append([float(play["t"]) + float(n[1]), float(play["t"]) + float(n[1]) + float(n[2]), d[1], 0.0, 0])
				break
	play["streams"] = list


## While a window is active the fire mode shoots: StandardShotHandler DelayTimeBetweenShotsInBurst between shots, at most
## NumberOfSuccessiveShotsBeforeEndShoot (0 = unlimited) per window. UNVERIFIED (row 95): the first shot fires at the
## window start; UseDistanceVariants picks <FireModeIdentifier><i> for the first DistanceFromTargetVariants entry the
## distance is under (Spit0 <= 1400 cm, else Spit1).
func _tick_streams(dist_m: float) -> void:
	var t: float = play["t"]
	for s: Array in play.get("streams", []):
		if t < float(s[0]) or t >= float(s[1]):
			continue
		var prm: Dictionary = s[2]
		var id := str(prm.get("FireModeIdentifier", ""))
		if bool(prm.get("UseDistanceVariants", false)):
			var vs: Array = prm.get("DistanceFromTargetVariants", [])
			var i := vs.size() - 1
			for k in vs.size():
				if dist_m * 100.0 <= float(vs[k]):
					i = k
					break
			id += str(maxi(i, 0))
		var fm: Dictionary = data.get("fire_modes", {}).get(arch, {}).get(id, {})
		if fm.is_empty() or t < float(s[3]):
			continue
		if int(fm.get("shots", 0)) > 0 and int(s[4]) >= int(fm["shots"]):
			continue
		s[3] = t + maxf(float(fm.get("delay", 0.0)), 0.01)
		s[4] = int(s[4]) + 1
		var count := randi_range(int(fm.get("count", [1, 1])[0]), int(fm.get("count", [1, 1])[1]))
		for _i in count:
			_fire(id, fm, prm)


## One projectile from MuzzleOriginBoneOrSocketName (head_mouth) at the fire mode's speed (OverrideInitalProjectileSpeed,
## else the projectile's InitialSpeed). Aim (RaycastFromMuzzle): at the combat target, the yaw clamped to
## ManualOffsetRotationLimit of the Screamer's facing; ManualOffsetPitchOverride >= 0 sets the pitch (degrees up);
## a ParabolaToTargetTrajectoryAdjustmentHelper solves the low arc to the target at that speed. AIDeviation:
## DefaultDeviationRange 0 -> none. UNVERIFIED (row 95): the target point (target position + 1 m), the clamp / pitch
## semantics and the parabola settings (DA_ParabolaLaunchParams_Slobber not exported).
func _fire(id: String, fm: Dictionary, prm: Dictionary) -> void:
	var tgt: Node3D = z.target
	var muzzle := _bone_pos(str(fm.get("muzzle", prm.get("MeshSocketToSetManualPositionFrom", "head_mouth"))))
	var speed := float(fm.get("speed", 1000.0)) / 100.0
	var fwd := -z.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var aim := (tgt.global_position + Vector3(0, 1.0, 0)) if is_instance_valid(tgt) else muzzle + fwd * 5.0
	var to := aim - muzzle
	var flat := Vector3(to.x, 0.0, to.z)
	var yaw_lim := deg_to_rad(float(prm.get("ManualOffsetRotationLimit", 90.0)))
	var ang := fwd.signed_angle_to(flat.normalized(), Vector3.UP) if flat.length() > 1e-3 else 0.0
	var dir_flat := fwd.rotated(Vector3.UP, clampf(ang, -yaw_lim, yaw_lim))
	var pitch := atan2(to.y, flat.length())
	var g := absf(_gravity())
	if bool(fm.get("parabola", false)):
		var x := flat.length()
		var disc := speed ** 4 - g * (g * x * x + 2.0 * to.y * speed * speed)
		if disc >= 0.0 and x > 1e-3:
			pitch = atan((speed * speed - sqrt(disc)) / (g * x))
	if float(prm.get("ManualOffsetPitchOverride", -1.0)) >= 0.0:
		pitch = deg_to_rad(float(prm["ManualOffsetPitchOverride"]))
	var vel := (dir_flat * cos(pitch) + Vector3.UP * sin(pitch)) * speed
	var p := SpecialProjectile.new()
	p.ai = self
	p.cls = str(fm.get("projectile", "")).trim_suffix("_C")
	p.cfg = data.get("projectiles", {}).get(p.cls, {})
	p.vel = vel
	p.g = g
	z.get_parent().add_child(p)
	p.global_position = muzzle
	shots_log.append([snappedf(now, 0.01), id, p.cls])


## UProjectileMovementComponent gravity: the world's GravityZ (fluids.json gravity_z, cm/s^2) x ProjectileGravityScale
## (default 1), in m/s^2.
func _gravity() -> float:
	return float(DI2Fluids.db().get("gravity_z", -980.0)) / 100.0


## A BP_Projectile_* in flight: v' = v + g dt, swept with a ray each physics step (DetectMeshCollisions: characters'
## bodies; the world). A character hit runs ApplyPointImpactCollisionResponse (DamageQuantityToApply of
## DamageClassToApply, AccumulatingEffectsToApply, bFriendlyFireAllowed) and InvokeParentProjectileResponse (detonate);
## a world hit detonates. Detonation: InvokeParentProjectileLocationResponse -> ProjectileResponseSpawnProjectile (the
## acid BP_Fluid_Projectile_*_SlobberBile with FluidPayloadRadius, DI2Fluids) + destroy. UNVERIFIED (row 95): the
## fluid inherits no velocity; the player takes the damage through take_zombie_hit (no acid / Corroded on the player);
## lifetime: 10 s cap (DI2: until a hit).
class SpecialProjectile extends Node3D:
	var ai
	var cls := ""
	var cfg := {}
	var vel := Vector3.ZERO
	var g := 9.8
	var t := 0.0

	func _physics_process(delta: float) -> void:
		t += delta
		var v2 := vel + Vector3(0, -g, 0) * delta
		var to := global_position + (vel + v2) * 0.5 * delta
		vel = v2
		var q := PhysicsRayQueryParameters3D.create(global_position, to)
		if is_instance_valid(ai.z):
			q.exclude = [ai.z.get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			global_position = to
			if t > 10.0:
				queue_free()
			return
		var c: Object = hit["collider"]
		var at: Vector3 = hit["position"]
		var dmg := float(cfg.get("damage", 0.0))
		if c != null and c.has_method("take_zombie_hit"):
			if dmg > 0.0:
				c.take_zombie_hit(dmg, ai.z)
			ai._sm_log("projectile %s hit player %.0f" % [cls, dmg])
		elif c is Zombie and not c.dead:
			var kind := DI2Explosion._kind(str(cfg.get("damage_type", "")))
			c.take_hit("spine_03", at, vel.normalized(), vel.normalized(), dmg, kind, false, 1.0, 0.0, Vector3.ZERO, ai.z)
			if not (cfg.get("accumulating", []) as Array).is_empty():
				c.accumulate(cfg["accumulating"], ai.z.level, true, at)
			ai._sm_log("projectile %s hit %s" % [cls, c.name])
		var sp: Dictionary = cfg.get("spawn", {})
		var fl := DI2Fluids.of(self)
		if not sp.is_empty() and fl != null:
			fl.spawn_projectile(str(sp.get("cls", "")), at, Vector3.ZERO, float(sp.get("radius", 0.0)), [], ai.z, hit.get("normal", Vector3.UP))
		queue_free()
