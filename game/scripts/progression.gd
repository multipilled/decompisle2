class_name Progression
extends RefCounted
## DI2 XP and levels: DA_PlayerProgressionLevels (XP totals per level, up to 30) and each zombie's
## XPRewardAttribute (Walker 20, Runner 25, Shambler 15), scaled by the zombie's level relative to Dani's.

var xp_total: Array = []
var enemy_xp: Dictionary = {}
var xp := 0
var level := 1
var last_gain := 0
var gain_t := 0.0
var level_up_t := 0.0


func _init(combat: Dictionary) -> void:
	xp_total = combat["progression"]["xp_total"]
	enemy_xp = combat["progression"]["enemy_xp"]


func max_level() -> int:
	return xp_total.size() - 1


func level_floor(lv: int) -> int:
	return int(xp_total[clampi(lv, 0, max_level())])


func next_floor() -> int:
	return level_floor(level + 1) if level < max_level() else level_floor(level)


func fraction() -> float:
	if level >= max_level():
		return 1.0
	return clampf(float(xp - level_floor(level)) / maxf(1.0, float(next_floor() - level_floor(level))), 0.0, 1.0)


## XP for killing `z` (DI2 gives less for under-levelled enemies, more for over-levelled).
func reward_for(z: Zombie) -> int:
	var base := float(enemy_xp.get(z.body.capitalize(), 20.0))
	var diff := clampi(z.level - level, -5, 5)
	return maxi(1, roundi(base * (1.0 + 0.15 * diff) * (1.0 + 0.1 * (z.level - 1))))


## Adds XP; returns the number of levels gained.
func add(amount: int) -> int:
	xp += amount
	last_gain = amount
	gain_t = 2.0
	var gained := 0
	while level < max_level() and xp >= next_floor():
		level += 1
		gained += 1
		level_up_t = 3.0
	return gained


func tick(delta: float) -> void:
	gain_t = maxf(0.0, gain_t - delta)
	level_up_t = maxf(0.0, level_up_t - delta)
