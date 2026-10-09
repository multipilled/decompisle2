//! Data-driven zombie archetypes (Walker, Runner, Shambler, ...).
//!
//! The JSON schema is our own; `tools/convert_archetypes.py` fills it from DI2's
//! `BPC_MultiPartHealth_*` and `DT_ZombiePartBoneDefinition` dumps, or it can be hand-written.

use serde::{Deserialize, Serialize};

use crate::anatomy::PartRole;
use crate::expr::{Expr, ParseError};

fn one() -> f32 {
    1.0
}
fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PartDef {
    /// DI2 row name, e.g. `head`, `arm_left`, `Torso_Bisectable`.
    pub id: String,
    /// Bones that belong to the part, as in `DT_ZombiePartBoneDefinition` (descendants are included implicitly).
    pub bones: Vec<String>,
    /// Bones a cut may happen at. Empty = any bone in `bones`.
    #[serde(default)]
    pub cut_bones: Vec<String>,
    #[serde(default = "one")]
    pub max_health_fraction: f32,
    #[serde(default = "yes")]
    pub can_dismember: bool,
    #[serde(default = "one")]
    pub dismember_chance: f32,
    #[serde(default = "yes")]
    pub can_break: bool,
    #[serde(default = "one")]
    pub break_chance: f32,
    #[serde(default)]
    pub force_kill: bool,
    #[serde(default = "one")]
    pub radial_scalar: f32,
    #[serde(default = "one")]
    pub radial_chance: f32,
    #[serde(default)]
    pub can_regenerate: bool,
    #[serde(default)]
    pub role: Option<PartRole>,
}

impl PartDef {
    pub fn role(&self) -> PartRole {
        self.role.unwrap_or_else(|| PartRole::from_id(&self.id))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Locomotion {
    pub walk_speed: f32,
    pub chase_speed: f32,
    pub crawl_speed: f32,
    pub turn_rate_deg: f32,
}

impl Default for Locomotion {
    fn default() -> Self {
        Self { walk_speed: 0.9, chase_speed: 1.5, crawl_speed: 0.45, turn_rate_deg: 180.0 }
    }
}

/// One attack "card", in the spirit of DI2's AI decks (`DA_Card_LeftHandSwipe_Walker_Crawler`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttackDef {
    pub name: String,
    pub range: f32,
    pub damage: f32,
    /// Seconds from start to the damage frame.
    pub hit_time: f32,
    pub duration: f32,
    pub cooldown: f32,
    #[serde(default)]
    pub needs_left_arm: bool,
    #[serde(default)]
    pub needs_right_arm: bool,
    /// Usable while standing / while crawling.
    #[serde(default = "yes")]
    pub standing: bool,
    #[serde(default)]
    pub crawling: bool,
    #[serde(default = "one")]
    pub weight: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Archetype {
    pub name: String,
    /// Character health.
    pub health: f32,
    /// MultiPartHealth MaxHealth: each part has `max_health_fraction * limb_health`.
    pub limb_health: f32,
    #[serde(default = "head_mult")]
    pub head_damage_multiplier: f32,
    /// DI2 `BodyPartExpressionRequiredToLive`. Empty = always alive while health > 0.
    #[serde(default)]
    pub survive: String,
    pub parts: Vec<PartDef>,
    #[serde(default)]
    pub locomotion: Locomotion,
    #[serde(default)]
    pub attacks: Vec<AttackDef>,
    #[serde(default = "sight")]
    pub sight_range: f32,
    /// Stagger is triggered by single hits at or above this damage.
    #[serde(default = "stagger")]
    pub stagger_threshold: f32,
    /// MultiPartHealth `RadialDamageDistributionMethod` (ERadialDamageBodyPartDistributionMethod): 0 None,
    /// 1 ApplyTotalToEachPart, 2 DistributeDividedAcrossParts, 3 DistributeToRandomParts, 4
    /// DistributeLowestHealthFirst. Native default 4 (UMultiPartHealthComponent ctor 0x141d50360); no DI2 asset sets it.
    #[serde(default = "radial_distribution")]
    pub radial_distribution: u8,
}

fn head_mult() -> f32 {
    2.0
}
fn sight() -> f32 {
    18.0
}
fn stagger() -> f32 {
    25.0
}
fn radial_distribution() -> u8 {
    4
}

impl Archetype {
    pub fn from_json(src: &str) -> serde_json::Result<Self> {
        serde_json::from_str(src)
    }

    pub fn survive_expr(&self) -> Result<Expr, ParseError> {
        Expr::parse(&self.survive)
    }

    /// The DI2 Walker as shipped (BPC_MultiPartHealth_Walker + DT_ZombiePartBoneDefinition),
    /// with attack timings estimated from observation.
    pub fn walker() -> Self {
        let part = |id: &str, bones: &[&str], cut: &[&str], frac: f32, kill: bool| PartDef {
            id: id.into(),
            bones: bones.iter().map(|s| s.to_string()).collect(),
            cut_bones: cut.iter().map(|s| s.to_string()).collect(),
            max_health_fraction: frac,
            can_dismember: true,
            dismember_chance: 1.0,
            can_break: true,
            break_chance: 1.0,
            force_kill: kill,
            radial_scalar: 1.0,
            radial_chance: 1.0,
            can_regenerate: false,
            role: None,
        };
        let attack = |name: &str, l: bool, r: bool, standing: bool, crawling: bool| AttackDef {
            name: name.into(),
            range: if crawling && !standing { 1.2 } else { 1.7 },
            damage: 12.0,
            hit_time: 0.55,
            duration: 1.3,
            cooldown: 1.2,
            needs_left_arm: l,
            needs_right_arm: r,
            standing,
            crawling,
            weight: 1.0,
        };
        Archetype {
            name: "Walker".into(),
            health: 120.0,
            limb_health: 120.0,
            head_damage_multiplier: 2.0,
            survive: "floatbranch(!#HasBothLegs, #HasBothArms, true)".into(),
            parts: vec![
                part("head", &["head", "neck_02", "neck_01"], &["neck_02"], 1.0, true),
                part("arm_left", &["upperarm_l", "lowerarm_l", "hand_l"], &[], 0.3, false),
                part("arm_right", &["upperarm_r", "lowerarm_r", "hand_r"], &[], 0.3, false),
                part("leg_left", &["thigh_l", "calf_l", "foot_l", "ball_l"], &["thigh_l", "calf_l"], 0.35, false),
                part("leg_right", &["thigh_r", "calf_r", "foot_r", "ball_r"], &["thigh_r", "calf_r"], 0.35, false),
            ],
            radial_distribution: radial_distribution(),
            locomotion: Locomotion::default(),
            attacks: vec![
                attack("LeftHandSwipe", true, false, true, true),
                attack("RightHandSwipe", false, true, true, true),
                AttackDef { name: "Grapple".into(), damage: 18.0, hit_time: 0.8, duration: 2.0, cooldown: 3.0, weight: 0.5, ..attack("Grapple", true, true, true, true) },
                AttackDef { name: "Bite".into(), range: 1.1, damage: 8.0, weight: 0.3, ..attack("Bite", false, false, true, true) },
            ],
            sight_range: 18.0,
            stagger_threshold: 25.0,
        }
    }
}
