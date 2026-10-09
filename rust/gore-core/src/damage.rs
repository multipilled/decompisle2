//! Damage kinds and hit descriptions (mirrors DI2's `BP_DamageType_*` set).

use glam::Vec3;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DamageKind {
    Blunt,
    Sharp,
    Projectile,
    Explosive,
    Fire,
    Acid,
    Electric,
    Bleed,
}

impl DamageKind {
    /// Kinds that sever limbs when a part runs out of health (DI2 guns shoot limbs off too).
    pub fn cuts(self) -> bool {
        matches!(self, DamageKind::Sharp | DamageKind::Explosive | DamageKind::Projectile)
    }

    /// Kinds that break bones (dangling arms, folded legs) when a part runs out of health. DI2's
    /// `BP_DamageType_*` CDOs: Sharp sets bCanBreak = false, elemental types and Bleed set both flags false,
    /// Blunt only clears bCanDismember; Projectile and Explosive keep the engine defaults (both true).
    pub fn breaks(self) -> bool {
        matches!(self, DamageKind::Blunt | DamageKind::Projectile | DamageKind::Explosive)
    }

    /// Kinds that burst a depleted head instead of cutting it off.
    pub fn bursts_head(self) -> bool {
        matches!(self, DamageKind::Projectile | DamageKind::Explosive)
    }

    pub fn is_elemental(self) -> bool {
        matches!(self, DamageKind::Fire | DamageKind::Acid | DamageKind::Electric | DamageKind::Bleed)
    }

    pub fn from_name(s: &str) -> Option<Self> {
        Some(match s.to_ascii_lowercase().as_str() {
            "blunt" => DamageKind::Blunt,
            "sharp" | "slash" => DamageKind::Sharp,
            "projectile" | "bullet" => DamageKind::Projectile,
            "explosive" | "explosion" => DamageKind::Explosive,
            "fire" | "burn" => DamageKind::Fire,
            "acid" | "caustic" => DamageKind::Acid,
            "electric" | "shock" => DamageKind::Electric,
            "bleed" => DamageKind::Bleed,
            _ => return None,
        })
    }
}

/// One impact against a body, in the skeleton's bind (rest) pose space.
#[derive(Debug, Clone)]
pub struct Hit {
    pub bone: usize,
    pub damage: f32,
    pub kind: DamageKind,
    /// Impact point in bind-pose space.
    pub point: Vec3,
    /// Weapon travel direction in bind-pose space (swing tangent for melee, bullet path for guns).
    pub direction: Vec3,
    /// Direction from the attacker into the body (view ray). Wounds are projected along it.
    pub into: Vec3,
    /// Weapon's LimbDamageMultiplier attribute.
    pub limb_multiplier: f32,
    /// Radial (explosion) hit: the body-part damage budget DI2's MultiPartHealth spreads over the parts
    /// (damage x the impact's RadialToBodyPartDamageMultiplier x RadialDamageQuantityToBodyPartDamageConversionFactor),
    /// in place of part damage on the hit part ([`crate::health::Body::apply_hit`]).
    pub radial_part_budget: Option<f32>,
    /// Heavy (charged) attack: more force on severed limbs and a guaranteed stagger.
    pub heavy: bool,
    /// Weapon/kick force attribute (DI2 units, before stability scaling). 0 = no stability damage.
    pub force: f32,
    /// The damage's DI2 damage type when it differs from the impact `kind` that drives the gore: a weapon mod's
    /// ConvertDamageTypeAndQuantityCommand turns the Physical category into its element (recon/RE_ACCUMULATING.md),
    /// which damage-taken modifiers (Corroded's elemental +25%) read. None = `kind`.
    pub damage_type: Option<DamageKind>,
}

impl Hit {
    pub fn new(bone: usize, damage: f32, kind: DamageKind, point: Vec3, direction: Vec3) -> Self {
        Self { bone, damage, kind, point, direction, into: direction, limb_multiplier: 1.0, radial_part_budget: None, heavy: false, force: 0.0, damage_type: None }
    }
}

/// Deterministic xorshift64* so simulations replay identically in tests and across engines.
#[derive(Debug, Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.max(1))
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform in [0, 1).
    pub fn f32(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }

    pub fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.f32()
    }

    pub fn chance(&mut self, p: f32) -> bool {
        p >= 1.0 || self.f32() < p
    }
}
