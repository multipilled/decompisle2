class_name AccumulatingEffects
## DI2's accumulating effects (status build-up) data and the appliers' side (recon/RE_ACCUMULATING.md,
## game/data/accumulating_effects.json from tools/build_accumulating.py). The meters themselves run in gore-core
## (status.rs, GoreBody.accumulate).
##   What a weapon mod adds on a hit: its level's OnHitAccumulatingEffects, plus each ImpactRequestModifier's
##   AddAccumulatingEffects whose ImpactKBRequirements hold (melee: {Hit}.HeavyAttack +0.25, ranged: {Hit}.Head).
##   Level scaling (0x1413c7d00 -> 0x14117f490, ELevelScalingMethod::Curve): value x
##   Curve_AccumulatingEffectsLevelScaling(victim level - source level); weapons use their own level
##   (EAccumulatingEffectScalingPolicy::ScaledBasedOnWeaponLevel), explosions when bUseScalingOnAccumulatingEffects.

const DATA_PATH := "res://data/accumulating_effects.json"
## The recreation's mod names -> DI2's (BP_WeaponMod_<Name>_Level_N).
const MOD_NAMES := {"fire": "fire", "acid": "acid", "electric": "shock", "shock": "shock", "bleed": "bleed",
	"impact": "impact", "tearing": "tearing"}
## A damage kind's effect type (an elemental hit's status).
const TYPE_FOR_KIND := {"fire": "Burning", "acid": "Corroded", "electric": "Electrocuted", "bleed": "Bleed"}
## DI2 classes whose AccumulatingEffectComponent uses EAccumulatingEffectRecipient::Specials (BP_Base_Thug /
## Butcher / Mutator / Screamer / Slobber / Reformer / Whipper); every other AI is DefaultAI (BP_Base_AI).
const SPECIALS := ["Thug", "Butcher", "Mutator", "Screamer", "Slobber", "Reformer", "Whipper"]

static var _db: Dictionary = {}


static func db() -> Dictionary:
	if _db.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f == null:
			push_error("AccumulatingEffects: %s missing (run tools/build_accumulating.py)" % DATA_PATH)
			return _db
		_db = JSON.parse_string(f.get_as_text())
	return _db


## The effect settings for a zombie archetype: {Burning: {decay_rate, duration, ...}, ...}.
static func config_for(archetype: String) -> Dictionary:
	var d := db()
	var recipient := "Specials" if archetype in SPECIALS else "DefaultAI"
	return d.get("configs", {}).get(d.get("recipients", {}).get(recipient, ""), {})


## Curve_AccumulatingEffectsLevelScaling at (victim level - source level); UE's FRichCurve holds the end keys'
## values outside the keys.
static func level_scale(victim_level: int, source_level: int) -> float:
	var keys: Array = db().get("level_curve", [])
	if keys.is_empty():
		return 1.0
	var x := float(victim_level - source_level)
	if x <= float(keys[0][0]):
		return float(keys[0][1])
	for i in range(1, keys.size()):
		if x <= float(keys[i][0]):
			var a: Array = keys[i - 1]
			var b: Array = keys[i]
			return lerpf(float(a[1]), float(b[1]), (x - float(a[0])) / maxf(float(b[0]) - float(a[0]), 1e-6))
	return float(keys[-1][1])


## What a mod adds on one hit: [{type, value, apply_max, can_extend}], requirement-gated modifiers summed into
## the type's on-hit entry (or appended when the mod has none of that type). `facts`: {"Hit.HeavyAttack": ..,
## "Hit.Head": ..}.
static func mod_effects(mod: String, level: int, ranged: bool, facts: Dictionary) -> Array:
	var mods: Dictionary = db().get("mods_ranged" if ranged else "mods_melee", {})
	var rec: Dictionary = mods.get(MOD_NAMES.get(mod, mod), {}).get(str(clampi(level, 1, 3)), {})
	var out: Array = []
	for e: Dictionary in rec.get("on_hit", []):
		out.append(e.duplicate())
	for m: Dictionary in rec.get("modifiers", []):
		var req = m.get("requires")
		if req != null and str(req) != "" and not DI2Expr.eval(str(req), facts):
			continue
		for a: Dictionary in m.get("add_accumulating", []):
			var hit := out.filter(func(e: Dictionary) -> bool: return e["type"] == a["type"])
			if hit.is_empty():
				out.append({"type": a["type"], "value": float(a["value"]), "apply_max": false, "can_extend": false})
			else:
				hit[0]["value"] = float(hit[0]["value"]) + float(a["value"])
	return out


## The mod's heavy / headshot cosmetic effects (ImpactRequestModifierDataDriven.OnImpactModifiedCosmeticEffect)
## whose requirements hold.
static func mod_cosmetic_effects(mod: String, level: int, ranged: bool, facts: Dictionary) -> Array:
	var mods: Dictionary = db().get("mods_ranged" if ranged else "mods_melee", {})
	var rec: Dictionary = mods.get(MOD_NAMES.get(mod, mod), {}).get(str(clampi(level, 1, 3)), {})
	var out: Array = []
	for m: Dictionary in rec.get("modifiers", []):
		var req = m.get("requires")
		if m.get("cosmetic_effect") != null and (req == null or DI2Expr.eval(str(req), facts)):
			out.append(str(m["cosmetic_effect"]))
	return out
