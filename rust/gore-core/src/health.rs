//! Multi-part health: DI2's `MultiPartHealth` behaviour for one character.

use std::collections::HashMap;

use crate::anatomy::{PartRole, Skeleton};
use crate::archetype::Archetype;
use crate::damage::{DamageKind, Hit, Rng};
use crate::expr::Expr;
use crate::stability::{Reaction, Stability};
use crate::status::{Status, StatusEffects};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PartState {
    Intact,
    /// Bone broken by blunt force: arms dangle, legs fold.
    Broken,
    /// Severed at `cut_bone` (that bone and everything below it is gone).
    Dismembered { cut_bone: usize },
}

#[derive(Debug, Clone)]
pub struct PartRuntime {
    pub health: f32,
    pub max_health: f32,
    pub state: PartState,
    /// Resolved bone indices of the part (from the archetype's bone names).
    pub bones: Vec<usize>,
    pub cut_bones: Vec<usize>,
    pub role: PartRole,
}

/// Everything a hit caused, for the presentation layer (meshes, physics, FX, audio).
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Damaged { part: Option<usize>, body_damage: f32, part_damage: f32 },
    /// `bone`: the bone the depleting damage hit (a radial event's random part bone).
    Broken { part: usize, bone: usize },
    /// Spawn a severed piece from `cut_bone` downwards and hide it on the body.
    Dismembered { part: usize, cut_bone: usize, force: f32 },
    /// Head destroyed without a flying piece (blunt pulping).
    Crushed { part: usize },
    Staggered,
    /// Stability reaction tier for this hit (light flinch .. knockdown / launch).
    Reacted { reaction: Reaction },
    /// An elemental status just triggered (burning, electrified, caustic, bleeding).
    StatusStarted { status: Status },
    /// Locomotion changed to crawling (lost or broken leg).
    BecameCrawler,
    Killed { reason: DeathReason },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeathReason {
    HealthDepleted,
    LostVitalPart,
    SurvivalRuleFailed,
    StatusDamage,
}

#[derive(Debug, Clone)]
pub struct Body {
    pub archetype: Archetype,
    pub skeleton: Skeleton,
    pub health: f32,
    pub max_health: f32,
    pub stability: Stability,
    pub status: StatusEffects,
    pub parts: Vec<PartRuntime>,
    pub alive: bool,
    pub crawling: bool,
    pub facts: HashMap<String, f64>,
    survive: Expr,
    rng: Rng,
    /// `Dismember.ForceScalar` / `Dismember.HeavyAttackForceScalar` equivalents.
    pub force_scalar: f32,
    pub heavy_force_scalar: f32,
}

impl Body {
    pub fn new(archetype: Archetype, skeleton: Skeleton, seed: u64) -> Self {
        let survive = archetype.survive_expr().unwrap_or(Expr::Num(1.0));
        let parts = archetype
            .parts
            .iter()
            .map(|p| {
                let bones: Vec<usize> = p.bones.iter().filter_map(|n| skeleton.find(n)).collect();
                let cut_bones = if p.cut_bones.is_empty() {
                    bones.clone()
                } else {
                    p.cut_bones.iter().filter_map(|n| skeleton.find(n)).collect()
                };
                let max = p.max_health_fraction * archetype.limb_health;
                PartRuntime { health: max, max_health: max, state: PartState::Intact, bones, cut_bones, role: p.role() }
            })
            .collect();
        let mut body = Body {
            health: archetype.health,
            max_health: archetype.health,
            stability: Stability::new(500.0, seed),
            status: StatusEffects::default(),
            archetype,
            skeleton,
            parts,
            alive: true,
            crawling: false,
            facts: HashMap::new(),
            survive,
            rng: Rng::new(seed),
            force_scalar: 1.0,
            heavy_force_scalar: 1.6,
        };
        body.refresh_facts();
        body
    }

    /// Part that owns `bone`: the first ancestor (inclusive) listed in a part's bones.
    pub fn part_of_bone(&self, bone: usize) -> Option<usize> {
        for b in self.skeleton.ancestry(bone) {
            if let Some(i) = self.parts.iter().position(|p| p.bones.contains(&b)) {
                return Some(i);
            }
        }
        None
    }

    /// Bone the part is severed at for a hit on `bone`: the nearest allowed cut bone at or above it,
    /// else the part's top-most cut bone.
    pub fn cut_bone_for(&self, part: usize, bone: usize) -> Option<usize> {
        let p = &self.parts[part];
        self.skeleton
            .ancestry(bone)
            .find(|b| p.cut_bones.contains(b))
            .or_else(|| p.cut_bones.iter().copied().min_by_key(|&b| self.skeleton.ancestry(b).count()))
    }

    /// True if `bone` has been cut off (it lies below some part's cut).
    /// Severs the part `bone` belongs to at its cut bone without a hit (DI2 pre-spawn / authored SplatterSet
    /// Dismember entries: the zombie spawns without the limb). Returns (part, cut bone), or None when the bone has
    /// no dismemberable part or it is already severed.
    pub fn dismember_bone(&mut self, bone: usize) -> Option<(usize, usize)> {
        let part = self.part_of_bone(bone)?;
        if matches!(self.parts[part].state, PartState::Dismembered { .. }) {
            return None;
        }
        let cut_bone = self.cut_bone_for(part, bone)?;
        self.parts[part].state = PartState::Dismembered { cut_bone };
        // Same follow-up as a hit's dismember: facts, and a lost leg makes the zombie crawl.
        self.refresh_facts();
        if self.parts[part].role.is_leg() {
            self.crawling = true;
        }
        Some((part, cut_bone))
    }

    pub fn is_bone_severed(&self, bone: usize) -> bool {
        self.parts.iter().any(|p| match p.state {
            PartState::Dismembered { cut_bone } => self.skeleton.is_in_subtree(bone, cut_bone),
            _ => false,
        })
    }

    /// Every bone a cut can happen at, in a stable order. Hosts give each one a mask slot
    /// (shader bit) so a severed subtree can be hidden on the body and shown on the flying piece.
    pub fn cut_slots(&self) -> Vec<usize> {
        let mut v: Vec<usize> = Vec::new();
        for p in &self.parts {
            for &b in &p.cut_bones {
                if !v.contains(&b) {
                    v.push(b);
                }
            }
        }
        v
    }

    /// Bit mask over [`Body::cut_slots`] of the cuts that have happened.
    pub fn severed_slot_mask(&self) -> u32 {
        let slots = self.cut_slots();
        self.parts
            .iter()
            .filter_map(|p| match p.state {
                PartState::Dismembered { cut_bone } => slots.iter().position(|&b| b == cut_bone),
                _ => None,
            })
            .fold(0u32, |m, i| m | (1 << i))
    }

    /// Bone indices currently severed, for shader masks.
    pub fn severed_bones(&self) -> Vec<usize> {
        (0..self.skeleton.len()).filter(|&b| self.is_bone_severed(b)).collect()
    }

    pub fn count(&self, pred: impl Fn(PartRole) -> bool, include_broken: bool) -> usize {
        self.parts
            .iter()
            .filter(|p| pred(p.role))
            .filter(|p| match p.state {
                PartState::Intact => true,
                PartState::Broken => include_broken,
                PartState::Dismembered { .. } => false,
            })
            .count()
    }

    fn refresh_facts(&mut self) {
        let has = |b: bool| if b { 1.0 } else { 0.0 };
        let arms = self.count(PartRole::is_arm, true);
        let legs = self.count(PartRole::is_leg, true);
        let total_arms = self.parts.iter().filter(|p| p.role.is_arm()).count();
        let total_legs = self.parts.iter().filter(|p| p.role.is_leg()).count();
        let head = self.count(|r| r == PartRole::Head, true);
        let f = &mut self.facts;
        f.insert("HasBothArms".into(), has(arms >= 2 || (total_arms < 2 && arms == total_arms)));
        f.insert("HasAnArm".into(), has(arms >= 1));
        f.insert("HasBothLegs".into(), has(legs >= 2 || (total_legs < 2 && legs == total_legs)));
        f.insert("HasALeg".into(), has(legs >= 1));
        f.insert("HasHead".into(), has(head >= 1 || !self.parts.iter().any(|p| p.role == PartRole::Head)));
        f.insert("ArmCount".into(), arms as f64);
        f.insert("LegCount".into(), legs as f64);
    }

    pub fn has_arm(&self, role: PartRole) -> bool {
        self.parts.iter().any(|p| p.role == role && !matches!(p.state, PartState::Dismembered { .. }))
    }

    /// Arms that can still attack (not severed, not broken).
    pub fn usable_arm(&self, role: PartRole) -> bool {
        self.parts.iter().any(|p| p.role == role && p.state == PartState::Intact)
    }

    pub fn apply_hit(&mut self, hit: &Hit) -> Vec<Outcome> {
        let mut out = Vec::new();
        if self.is_bone_severed(hit.bone) {
            return out;
        }
        if !self.alive {
            return self.apply_corpse_hit(hit);
        }
        let part = self.part_of_bone(hit.bone);

        // A radial hit damages no part directly: DI2's MultiPartHealth spreads its budget over the parts below.
        let mut part_damage = if hit.radial_part_budget.is_some() { 0.0 } else { hit.damage * hit.limb_multiplier };
        let head = part.is_some_and(|i| self.parts[i].role == PartRole::Head);
        let weak = self.status.damage_taken_multiplier(hit.damage_type.unwrap_or(hit.kind));
        part_damage *= weak;
        let body_damage = hit.damage * weak * if head { self.archetype.head_damage_multiplier } else { 1.0 };
        self.health -= body_damage;
        out.push(Outcome::Damaged { part, body_damage, part_damage });

        if hit.heavy || hit.damage >= self.archetype.stagger_threshold {
            out.push(Outcome::Staggered);
        }
        if hit.force > 0.0 {
            let reaction = self.stability.hit(hit.force, hit.heavy);
            out.push(Outcome::Reacted { reaction });
        }

        if let (Some(i), None) = (part, hit.radial_part_budget) {
            if let Some(reason) = self.damage_part(i, hit.bone, part_damage, hit.kind, hit.heavy, &mut out) {
                return self.kill(out, reason);
            }
        }
        if let Some(budget) = hit.radial_part_budget {
            for (i, bone, damage) in self.radial_part_events(budget) {
                out.push(Outcome::Damaged { part: Some(i), body_damage: 0.0, part_damage: damage });
                if let Some(reason) = self.damage_part(i, bone, damage, hit.kind, hit.heavy, &mut out) {
                    return self.kill(out, reason);
                }
            }
        }

        if self.health <= 0.0 {
            return self.kill(out, DeathReason::HealthDepleted);
        }
        out
    }

    /// A hit on a corpse. DI2 keeps processing impacts on dead characters (CT_HitReact trees branch on
    /// {Victim}.Dead and SuppressCorpseHitReacts; DI2's loot config has bDisableBodyPartDestructionDropsOnceOwnerDead):
    /// MultiPartHealth part damage still depletes parts, so corpses dismember, crush and break. No body health,
    /// stagger, stability, status or second death.
    fn apply_corpse_hit(&mut self, hit: &Hit) -> Vec<Outcome> {
        let mut out = Vec::new();
        let part = self.part_of_bone(hit.bone);
        let part_damage = if hit.radial_part_budget.is_some() { 0.0 } else { hit.damage * hit.limb_multiplier };
        out.push(Outcome::Damaged { part, body_damage: 0.0, part_damage });
        if let (Some(i), None) = (part, hit.radial_part_budget) {
            let _ = self.damage_part(i, hit.bone, part_damage, hit.kind, hit.heavy, &mut out);
        }
        if let Some(budget) = hit.radial_part_budget {
            for (i, bone, damage) in self.radial_part_events(budget) {
                out.push(Outcome::Damaged { part: Some(i), body_damage: 0.0, part_damage: damage });
                let _ = self.damage_part(i, bone, damage, hit.kind, hit.heavy, &mut out);
            }
        }
        out.retain(|o| !matches!(o, Outcome::BecameCrawler));
        out
    }

    /// Part-health damage on part `i` at `bone`, and what a depleted part does (dismember / crush / break), then
    /// the facts, survival rule and crawling. Returns the death reason when it kills the owner.
    fn damage_part(&mut self, i: usize, bone: usize, part_damage: f32, kind: DamageKind, heavy: bool, out: &mut Vec<Outcome>) -> Option<DeathReason> {
        let d = self.archetype.parts[i].clone();
        let head = self.parts[i].role == PartRole::Head;
        let rt = &mut self.parts[i];
        let was = rt.state;
        if matches!(was, PartState::Intact | PartState::Broken) {
            rt.health -= part_damage;
        }
        let depleted = rt.health <= 0.0;
        let fatal_head_blow = head && self.alive && self.health <= 0.0 && kind == DamageKind::Blunt;
        if depleted || fatal_head_blow {
            if head && kind.bursts_head() && d.can_dismember && !matches!(was, PartState::Dismembered { .. }) {
                if let Some(cut_bone) = self.cut_bone_for(i, bone) {
                    self.parts[i].state = PartState::Dismembered { cut_bone };
                    self.parts[i].health = 0.0;
                    out.push(Outcome::Crushed { part: i });
                }
            } else if kind.cuts() && d.can_dismember && !matches!(was, PartState::Dismembered { .. }) && self.rng.chance(d.dismember_chance) {
                if let Some(cut_bone) = self.cut_bone_for(i, bone) {
                    self.parts[i].state = PartState::Dismembered { cut_bone };
                    self.parts[i].health = 0.0;
                    let force = if heavy { self.heavy_force_scalar } else { self.force_scalar };
                    out.push(Outcome::Dismembered { part: i, cut_bone, force });
                }
            } else if kind.breaks() && head && d.can_dismember && (fatal_head_blow || was == PartState::Broken) {
                // A second blunt depletion (or the killing blow) pulps the head.
                if let Some(cut_bone) = self.cut_bone_for(i, bone) {
                    self.parts[i].state = PartState::Dismembered { cut_bone };
                    out.push(Outcome::Crushed { part: i });
                }
            } else if kind.breaks() && d.can_break && was == PartState::Intact && self.rng.chance(d.break_chance) {
                self.parts[i].state = PartState::Broken;
                self.parts[i].health = self.parts[i].max_health * 0.5;
                out.push(Outcome::Broken { part: i, bone });
            }
        }

        let destroyed = matches!(self.parts[i].state, PartState::Dismembered { .. }) && !matches!(was, PartState::Dismembered { .. });
        self.refresh_facts();
        if destroyed && d.force_kill {
            return Some(DeathReason::LostVitalPart);
        }
        if destroyed && !self.survive.eval_bool(&self.facts) {
            return Some(DeathReason::SurvivalRuleFailed);
        }
        let should_crawl = self.parts.iter().any(|p| p.role.is_leg() && p.state != PartState::Intact);
        if should_crawl && !self.crawling {
            self.crawling = true;
            out.push(Outcome::BecameCrawler);
        }
        None
    }

    /// DI2 MultiPartHealth radial body-part damage (exe 0x1412c0940, recon/RE_EXPLOSIONS.md): the parts that take a
    /// share of a radial hit's `budget`, as (part, bone, part damage). Candidates: RadialDamageScalar > 0, a
    /// rand() <= AffectedByRadialDamageChance roll, and not already destroyed (critical parts included:
    /// RadialDamageBodyPartDistributionOnCriticalPartsEnabled = 1). Per RadialDamageDistributionMethod:
    /// 1 each part takes scalar x budget; 2 the budget is split equally; 3 / 4 the candidates are shuffled (4 then
    /// sorted lowest part health first) and each takes min(scalar x budget left, its health) until the budget is
    /// spent (no MaxPartsAffectedCount limit, the cvar's default -1). Each event's bone is a random bone of the part.
    fn radial_part_events(&mut self, budget: f32) -> Vec<(usize, usize, f32)> {
        let mode = self.archetype.radial_distribution;
        if mode == 0 || budget <= 0.0 {
            return Vec::new();
        }
        let mut cands: Vec<usize> = Vec::new();
        for i in 0..self.parts.len() {
            let d = &self.archetype.parts[i];
            if d.radial_scalar <= 0.0 {
                continue;
            }
            let chance = d.radial_chance;
            let roll = self.rng.chance(chance);
            if roll && !matches!(self.parts[i].state, PartState::Dismembered { .. }) {
                cands.push(i);
            }
        }
        if (mode == 3 || mode == 4) && cands.len() > 1 {
            // DI2's in-place shuffle: slot k swaps with k + int(rand01 x remaining).
            let n = cands.len();
            for k in 0..n {
                let left = n - k;
                let j = k + ((self.rng.f32() * left as f32) as usize).min(left - 1);
                cands.swap(k, j);
            }
            if mode == 4 {
                cands.sort_by(|&a, &b| self.parts[a].health.partial_cmp(&self.parts[b].health).unwrap_or(std::cmp::Ordering::Equal));
            }
        }
        let count = cands.len();
        let mut left = budget;
        let mut events = Vec::new();
        for i in cands {
            if left <= 0.0 {
                break;
            }
            let scalar = self.archetype.parts[i].radial_scalar;
            let mut damage = scalar * budget;
            match mode {
                2 => damage /= count as f32,
                3 | 4 => {
                    damage = (scalar * left).min(self.parts[i].health);
                    left -= damage / scalar;
                }
                _ => {}
            }
            let n = self.parts[i].bones.len();
            if n == 0 {
                continue;
            }
            let bone = self.parts[i].bones[((self.rng.f32() * n as f32) as usize).min(n - 1)];
            if damage > 0.0 {
                events.push((i, bone, damage));
            }
        }
        events
    }

    /// Scales health for an enemy level (DI2: +10% of base per level above 1).
    pub fn set_level(&mut self, level: u32, growth_per_level: f32) {
        let mult = 1.0 + growth_per_level * level.saturating_sub(1) as f32;
        let frac = if self.max_health > 0.0 { self.health / self.max_health } else { 1.0 };
        self.max_health = self.archetype.health * mult;
        self.health = self.max_health * frac;
    }

    /// DI2's UAccumulatingEffectComponent::UpdateEffectValue for one effect type (`value` level-scaled by the
    /// caller): fills the meter and begins the status at 1 (recon/RE_ACCUMULATING.md). The status BP's ReceiveBegin
    /// applies its InitialDamage.
    pub fn accumulate(&mut self, status: Status, value: f32, apply_max: bool, can_extend: bool) -> Vec<Outcome> {
        let mut out = Vec::new();
        if !self.alive {
            return out;
        }
        if let Some(s) = self.status.accumulate(status, value, apply_max, can_extend) {
            self.health -= s.damage().0;
            out.push(Outcome::StatusStarted { status: s });
            if self.health <= 0.0 {
                return self.kill(out, DeathReason::StatusDamage);
            }
        }
        out
    }

    /// Advances stability recharge and status effects. Returns outcomes (status deaths, ended statuses are silent).
    pub fn tick(&mut self, dt: f32) -> Vec<Outcome> {
        self.stability.tick(dt);
        let (dot, _ended) = self.status.tick(dt);
        if dot > 0.0 && self.alive {
            self.health -= dot;
            if self.health <= 0.0 {
                return self.kill(Vec::new(), DeathReason::StatusDamage);
            }
        }
        Vec::new()
    }

    fn kill(&mut self, mut out: Vec<Outcome>, reason: DeathReason) -> Vec<Outcome> {
        self.alive = false;
        self.health = self.health.min(0.0);
        out.retain(|o| !matches!(o, Outcome::Staggered | Outcome::Reacted { .. }));
        out.push(Outcome::Killed { reason });
        out
    }
}


#[cfg(test)]
pub(crate) mod tests_support {
    use crate::anatomy::Skeleton;

    /// Minimal UE-mannequin-like hierarchy covering the bones the Walker uses.
    pub fn skeleton() -> Skeleton {
        let spec: &[(&str, Option<&str>)] = &[
            ("root", None),
            ("pelvis", Some("root")),
            ("spine_01", Some("pelvis")),
            ("spine_02", Some("spine_01")),
            ("spine_03", Some("spine_02")),
            ("spine_04", Some("spine_03")),
            ("neck_01", Some("spine_04")),
            ("neck_02", Some("neck_01")),
            ("head", Some("neck_02")),
            ("clavicle_l", Some("spine_04")),
            ("upperarm_l", Some("clavicle_l")),
            ("lowerarm_l", Some("upperarm_l")),
            ("hand_l", Some("lowerarm_l")),
            ("index_01_l", Some("hand_l")),
            ("clavicle_r", Some("spine_04")),
            ("upperarm_r", Some("clavicle_r")),
            ("lowerarm_r", Some("upperarm_r")),
            ("hand_r", Some("lowerarm_r")),
            ("thigh_l", Some("pelvis")),
            ("calf_l", Some("thigh_l")),
            ("foot_l", Some("calf_l")),
            ("ball_l", Some("foot_l")),
            ("thigh_r", Some("pelvis")),
            ("calf_r", Some("thigh_r")),
            ("foot_r", Some("calf_r")),
            ("ball_r", Some("foot_r")),
        ];
        let names: Vec<String> = spec.iter().map(|(n, _)| n.to_string()).collect();
        let parents = spec.iter().map(|(_, p)| p.map(|p| names.iter().position(|n| n == p).unwrap())).collect();
        Skeleton::new(names, parents)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::Vec3;

    fn walker() -> Body {
        Body::new(Archetype::walker(), tests_support::skeleton(), 7)
    }

    fn hit(b: &Body, bone: &str, dmg: f32, kind: DamageKind) -> Hit {
        Hit::new(b.skeleton.find(bone).unwrap(), dmg, kind, Vec3::ZERO, Vec3::X)
    }

    #[test]
    fn radial_hit_spends_its_budget_lowest_health_first() {
        let mut b = walker();
        // Walker parts: head 120, arms 36, legs 42 (all RadialDamageScalar / chance 1). A 100 budget under
        // DistributeLowestHealthFirst depletes both arms (72) and puts the remaining 28 on a leg.
        let mut h = hit(&b, "spine_03", 10.0, DamageKind::Explosive);
        h.radial_part_budget = Some(100.0);
        let out = b.apply_hit(&h);
        let damaged: Vec<(usize, f32)> = out.iter().filter_map(|o| match o {
            Outcome::Damaged { part: Some(i), body_damage, part_damage } if *body_damage == 0.0 => Some((*i, *part_damage)),
            _ => None,
        }).collect();
        let total: f32 = damaged.iter().map(|d| d.1).sum();
        assert!((total - 100.0).abs() < 1e-3, "{damaged:?}");
        let roles: Vec<PartRole> = damaged.iter().map(|d| b.parts[d.0].role).collect();
        assert!(roles[0].is_arm() && roles[1].is_arm() && roles[2].is_leg(), "{roles:?}");
        assert!((damaged[2].1 - 28.0).abs() < 1e-3);
        // Explosive cuts: both arms come off.
        assert_eq!(out.iter().filter(|o| matches!(o, Outcome::Dismembered { .. })).count(), 2);
        assert!((b.health - 110.0).abs() < 1e-3);
    }

    #[test]
    fn corpses_keep_losing_parts() {
        let mut b = walker();
        b.apply_hit(&hit(&b, "spine_03", 10_000.0, DamageKind::Blunt));
        assert!(!b.alive);
        let health = b.health;
        // A dead Walker's arm (36 part health) still dismembers; no stagger, reaction or second death.
        let mut h = hit(&b, "lowerarm_l", 40.0, DamageKind::Sharp);
        h.force = 50.0;
        let out = b.apply_hit(&h);
        assert!(out.iter().any(|o| matches!(o, Outcome::Dismembered { .. })), "{out:?}");
        assert!(!out.iter().any(|o| matches!(o, Outcome::Killed { .. } | Outcome::Staggered | Outcome::Reacted { .. })));
        assert_eq!(b.health, health);
        // One blunt hit on the corpse's head only damages it (no "killing blow" pulp).
        let out = b.apply_hit(&hit(&b, "head", 10.0, DamageKind::Blunt));
        assert!(!out.iter().any(|o| matches!(o, Outcome::Crushed { .. })), "{out:?}");
    }

    #[test]
    fn sharp_forearm_hit_cuts_at_forearm() {
        let mut b = walker();
        // arm_left has 0.3 * 120 = 36 limb health.
        let h = hit(&b, "index_01_l", 40.0, DamageKind::Sharp);
        let out = b.apply_hit(&h);
        let lower = b.skeleton.find("lowerarm_l").unwrap();
        // Finger hit walks up to hand_l, the nearest cut bone.
        let hand = b.skeleton.find("hand_l").unwrap();
        assert!(out.iter().any(|o| matches!(o, Outcome::Dismembered { cut_bone, .. } if *cut_bone == hand)));
        assert!(b.is_bone_severed(b.skeleton.find("index_01_l").unwrap()));
        assert!(!b.is_bone_severed(lower));
        assert!(b.alive);
    }

    #[test]
    fn walker_dies_when_legless_and_armless() {
        let mut b = walker();
        // Big health pool so only the survival rule can kill.
        b.health = 10_000.0;
        // floatbranch(!#HasBothLegs, #HasBothArms, true): with both legs, arms don't matter...
        for bone in ["upperarm_l", "upperarm_r"] {
            let out = b.apply_hit(&hit(&b, bone, 60.0, DamageKind::Sharp));
            assert!(!out.iter().any(|o| matches!(o, Outcome::Killed { .. })), "{bone} should not kill");
        }
        // ...but a Walker missing a leg needs both arms.
        let out = b.apply_hit(&hit(&b, "thigh_l", 60.0, DamageKind::Sharp));
        assert!(out.contains(&Outcome::Killed { reason: DeathReason::SurvivalRuleFailed }), "{out:?}");

        let mut c = walker();
        c.health = 10_000.0;
        let out = c.apply_hit(&hit(&c, "thigh_r", 60.0, DamageKind::Sharp));
        assert!(out.contains(&Outcome::BecameCrawler) && c.alive, "a one-legged walker crawls on");
        let out = c.apply_hit(&hit(&c, "lowerarm_l", 60.0, DamageKind::Sharp));
        assert!(out.contains(&Outcome::Killed { reason: DeathReason::SurvivalRuleFailed }), "{out:?}");
    }

    #[test]
    fn blunt_breaks_then_crushes_head() {
        let mut b = walker();
        b.health = 10_000.0;
        let h = hit(&b, "head", 130.0, DamageKind::Blunt);
        assert!(b.apply_hit(&h).iter().any(|o| matches!(o, Outcome::Broken { .. })));
        let out = b.apply_hit(&h);
        assert!(out.iter().any(|o| matches!(o, Outcome::Crushed { .. })), "{out:?}");
        assert!(out.contains(&Outcome::Killed { reason: DeathReason::LostVitalPart }));
    }

    #[test]
    fn blunt_leg_break_makes_crawler_without_severing() {
        let mut b = walker();
        b.health = 10_000.0;
        let h = hit(&b, "calf_r", 50.0, DamageKind::Blunt);
        let out = b.apply_hit(&h);
        assert!(out.contains(&Outcome::BecameCrawler));
        assert!(b.severed_bones().is_empty());
        assert_eq!(b.facts["HasBothLegs"], 1.0, "broken legs still count as legs");
    }

    #[test]
    fn guns_shoot_limbs_off_and_burst_heads() {
        let mut b = walker();
        b.health = 10_000.0;
        let out = b.apply_hit(&hit(&b, "lowerarm_r", 40.0, DamageKind::Projectile));
        let lower = b.skeleton.find("lowerarm_r").unwrap();
        assert!(out.iter().any(|o| matches!(o, Outcome::Dismembered { cut_bone, .. } if *cut_bone == lower)), "{out:?}");
        assert_eq!(b.severed_slot_mask().count_ones(), 1);
        let out = b.apply_hit(&hit(&b, "head", 130.0, DamageKind::Projectile));
        assert!(out.iter().any(|o| matches!(o, Outcome::Crushed { .. })), "{out:?}");
        assert!(!b.alive);
        assert!(b.cut_slots().len() >= 11);
    }

    #[test]
    fn severed_bones_ignore_further_hits() {
        let mut b = walker();
        b.health = 10_000.0;
        let h = hit(&b, "calf_l", 60.0, DamageKind::Sharp);
        b.apply_hit(&h);
        assert!(b.apply_hit(&hit(&b, "foot_l", 60.0, DamageKind::Sharp)).is_empty());
    }
}
