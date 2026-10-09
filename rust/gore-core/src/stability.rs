//! Stability: DI2's poise meter. Weapon force wears it down; each hit's reaction tier depends on how hard
//! it hit relative to the meter, and an emptied meter knocks the zombie down (or launches it).
//!
//! DI2 data: AI base stability 500 (`DA_AttributeType_AIBaseStability`), force -> stability damage 1:1
//! (`Curve_ForceToStabilityDamage_Float`), recharge curve (`Curve_StabilityRecharge_Float`) and a fall-over
//! chance curve (`Curve_StabiltyFallOverChance_Float`). Weapon/kick force attributes (bat 25, kick 30) are
//! pre-multiplier values; `FORCE_SCALE` is the estimate that turns them into stability damage.

use serde::{Deserialize, Serialize};

use crate::damage::Rng;

/// Estimated global force multiplier (weapon Force attribute -> stability damage).
pub const FORCE_SCALE: f32 = 10.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Reaction {
    /// Flinch layered over whatever the zombie is doing.
    Light,
    /// Full-body hit reaction.
    Medium,
    /// Staggers backwards a few steps.
    Stumble,
    /// Falls to the ground, then gets up.
    Knockdown,
    /// Thrown off its feet by a big hit.
    Launch,
}

#[derive(Debug, Clone)]
pub struct Stability {
    pub max: f32,
    pub value: f32,
    /// Seconds since the last hit; recharge starts after `cooldown`.
    pub since_hit: f32,
    pub cooldown: f32,
    /// Seconds for a full recharge.
    pub recharge_time: f32,
    rng: Rng,
}

impl Stability {
    pub fn new(max: f32, seed: u64) -> Self {
        Self { max, value: max, since_hit: 99.0, cooldown: 2.0, recharge_time: 3.0, rng: Rng::new(seed ^ 0x57AB) }
    }

    pub fn fraction(&self) -> f32 {
        (self.value / self.max).clamp(0.0, 1.0)
    }

    /// DI2's recharge curve (0,0) (0.5,0.4) (1,1): slow start, fast finish.
    fn recharge_curve(t: f32) -> f32 {
        if t < 0.5 {
            t / 0.5 * 0.4
        } else {
            0.4 + (t - 0.5) / 0.5 * 0.6
        }
    }

    /// DI2 fall-over chance by remaining stability percentage: (0 -> 1.0) (5 -> 0.15) (20 -> 0).
    fn fall_chance(pct: f32) -> f32 {
        if pct <= 0.0 {
            1.0
        } else if pct < 5.0 {
            1.0 - pct / 5.0 * 0.85
        } else if pct < 20.0 {
            0.15 * (1.0 - (pct - 5.0) / 15.0)
        } else {
            0.0
        }
    }

    /// Applies a hit of `force` (attribute units, before `FORCE_SCALE`). `launch` = heavy hits that can throw.
    pub fn hit(&mut self, force: f32, launch: bool) -> Reaction {
        let dmg = force.max(0.0) * FORCE_SCALE;
        self.since_hit = 0.0;
        self.value -= dmg;
        let pct = self.fraction() * 100.0;
        if self.value <= 0.0 || self.rng.chance(Self::fall_chance(pct)) && pct < 20.0 {
            self.value = 0.0;
            return if launch && dmg >= self.max * 0.6 { Reaction::Launch } else { Reaction::Knockdown };
        }
        let r = dmg / self.max;
        if r < 0.12 {
            Reaction::Light
        } else if r < 0.4 {
            Reaction::Medium
        } else {
            Reaction::Stumble
        }
    }

    /// Back on its feet after a knockdown: DI2 refills the meter.
    pub fn reset(&mut self) {
        self.value = self.max;
    }

    pub fn tick(&mut self, dt: f32) {
        self.since_hit += dt;
        if self.since_hit > self.cooldown && self.value < self.max {
            let t = ((self.since_hit - self.cooldown) / self.recharge_time).clamp(0.0, 1.0);
            let target = self.max * Self::recharge_curve(t);
            self.value = self.value.max(target).min(self.max);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_kicks_knock_a_walker_down() {
        let mut s = Stability::new(500.0, 1);
        // Dani's KickForce is 30.
        assert!(matches!(s.hit(30.0, false), Reaction::Stumble));
        assert_eq!(s.hit(30.0, false), Reaction::Knockdown);
    }

    #[test]
    fn light_hits_flinch_and_meter_recharges() {
        let mut s = Stability::new(500.0, 2);
        assert_eq!(s.hit(4.0, false), Reaction::Light);
        let low = s.value;
        for _ in 0..100 {
            s.tick(0.05);
        }
        assert!(s.value > low && s.value <= s.max);
    }

    #[test]
    fn big_heavy_hit_launches_from_low_stability() {
        let mut s = Stability::new(500.0, 3);
        s.hit(25.0, false);
        assert_eq!(s.hit(37.5, true), Reaction::Launch);
    }
}
