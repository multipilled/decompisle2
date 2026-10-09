//! Zombie brain: perception, chase, attack cards, stagger and crawler fallback.
//!
//! Engine-agnostic: the host feeds distances and events each tick and reads back
//! a locomotion request, the animation state to play and attack damage events.

use crate::anatomy::PartRole;
use crate::archetype::AttackDef;
use crate::damage::Rng;
use crate::health::Body;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Idle,
    /// Noticed the target; turns towards it before chasing.
    Alert { t: f32 },
    Chase,
    Attack { card: usize, t: f32, hit_done: bool },
    Stagger { t: f32 },
    /// Falling over after losing a leg.
    FallToCrawl { t: f32 },
    Dead,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anim {
    Idle,
    Alert,
    Walk,
    Chase,
    Crawl,
    CrawlIdle,
    Attack,
    CrawlAttack,
    Stagger,
    Fall,
    Death,
}

#[derive(Debug, Clone, Default)]
pub struct Perception {
    pub distance: f32,
    pub can_see: bool,
    /// Angle (radians) between facing and the target direction.
    pub facing_error: f32,
}

#[derive(Debug, Clone)]
pub struct Command {
    /// Desired forward speed (m/s); the host steers towards the target / along its nav path.
    pub speed: f32,
    pub face_target: bool,
    pub anim: Anim,
    /// Name of the attack card when a new attack starts (for picking the animation).
    pub attack_started: Option<String>,
    /// Damage to apply to the target this tick (attack's damage frame).
    pub deal_damage: Option<f32>,
}

#[derive(Debug, Clone)]
pub struct Brain {
    pub state: State,
    cooldowns: Vec<f32>,
    rng: Rng,
    lost_sight_t: f32,
}

impl Brain {
    pub fn new(seed: u64) -> Self {
        Self { state: State::Idle, cooldowns: Vec::new(), rng: Rng::new(seed ^ 0xB4A1), lost_sight_t: 0.0 }
    }

    /// Notify a hit reaction (from `Outcome::Staggered`).
    pub fn on_stagger(&mut self) {
        if !matches!(self.state, State::Dead | State::FallToCrawl { .. }) {
            self.state = State::Stagger { t: 0.0 };
        }
    }

    pub fn on_became_crawler(&mut self) {
        if self.state != State::Dead {
            self.state = State::FallToCrawl { t: 0.0 };
        }
    }

    pub fn on_death(&mut self) {
        self.state = State::Dead;
    }

    fn card_usable(card: &AttackDef, body: &Body) -> bool {
        (body.crawling && card.crawling || !body.crawling && card.standing)
            && (!card.needs_left_arm || body.usable_arm(PartRole::ArmLeft))
            && (!card.needs_right_arm || body.usable_arm(PartRole::ArmRight))
    }

    fn pick_card(&mut self, body: &Body, distance: f32) -> Option<usize> {
        let cards = &body.archetype.attacks;
        let usable: Vec<usize> = (0..cards.len())
            .filter(|&i| self.cooldowns[i] <= 0.0 && distance <= cards[i].range && Self::card_usable(&cards[i], body))
            .collect();
        let total: f32 = usable.iter().map(|&i| cards[i].weight).sum();
        if total <= 0.0 {
            return None;
        }
        let mut r = self.rng.f32() * total;
        for &i in &usable {
            r -= cards[i].weight;
            if r <= 0.0 {
                return Some(i);
            }
        }
        usable.last().copied()
    }

    pub fn tick(&mut self, dt: f32, body: &Body, p: &Perception) -> Command {
        let loco = &body.archetype.locomotion;
        let cards = &body.archetype.attacks;
        self.cooldowns.resize(cards.len(), 0.0);
        for c in &mut self.cooldowns {
            *c -= dt;
        }
        let move_anim = if body.crawling { Anim::Crawl } else { Anim::Chase };
        let idle_anim = if body.crawling { Anim::CrawlIdle } else { Anim::Idle };
        let mut cmd = Command { speed: 0.0, face_target: false, anim: idle_anim, attack_started: None, deal_damage: None };
        if !body.alive {
            self.state = State::Dead;
        }

        if p.can_see {
            self.lost_sight_t = 0.0;
        } else {
            self.lost_sight_t += dt;
        }
        let aware = p.can_see && p.distance <= body.archetype.sight_range;

        self.state = match self.state {
            State::Dead => {
                cmd.anim = Anim::Death;
                State::Dead
            }
            State::Idle => {
                if aware {
                    State::Alert { t: 0.0 }
                } else {
                    State::Idle
                }
            }
            State::Alert { t } => {
                cmd.anim = if body.crawling { Anim::CrawlIdle } else { Anim::Alert };
                cmd.face_target = true;
                if t + dt >= 0.8 {
                    State::Chase
                } else {
                    State::Alert { t: t + dt }
                }
            }
            State::Chase => {
                if !p.can_see {
                    // Lost the target: hold position, give up after a moment.
                    if self.lost_sight_t > 2.0 {
                        State::Idle
                    } else {
                        State::Chase
                    }
                } else if let Some(card) = self.pick_card(body, p.distance) {
                    self.cooldowns[card] = cards[card].cooldown;
                    cmd.attack_started = Some(cards[card].name.clone());
                    State::Attack { card, t: 0.0, hit_done: false }
                } else {
                    cmd.face_target = true;
                    let close = cards.iter().filter(|c| Self::card_usable(c, body)).map(|c| c.range).fold(0.9f32, f32::max);
                    if p.distance > close * 0.8 {
                        cmd.speed = if body.crawling {
                            loco.crawl_speed
                        } else if p.distance > 4.0 {
                            loco.chase_speed
                        } else {
                            loco.walk_speed
                        };
                        cmd.anim = move_anim;
                    }
                    State::Chase
                }
            }
            State::Attack { card, t, hit_done } => {
                let c = &cards[card];
                cmd.anim = if body.crawling { Anim::CrawlAttack } else { Anim::Attack };
                cmd.face_target = t < c.hit_time;
                let t2 = t + dt;
                let mut done = hit_done;
                if !hit_done && t2 >= c.hit_time {
                    done = true;
                    if p.distance <= c.range * 1.15 && Self::card_usable(c, body) {
                        cmd.deal_damage = Some(c.damage);
                    }
                }
                if t2 >= c.duration {
                    State::Chase
                } else {
                    State::Attack { card, t: t2, hit_done: done }
                }
            }
            State::Stagger { t } => {
                cmd.anim = Anim::Stagger;
                if t + dt >= 0.7 {
                    if aware { State::Chase } else { State::Idle }
                } else {
                    State::Stagger { t: t + dt }
                }
            }
            State::FallToCrawl { t } => {
                cmd.anim = Anim::Fall;
                if t + dt >= 1.2 {
                    if aware { State::Chase } else { State::Idle }
                } else {
                    State::FallToCrawl { t: t + dt }
                }
            }
        };
        cmd
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archetype::Archetype;
    use crate::damage::{DamageKind, Hit};
    use glam::Vec3;

    fn body() -> Body {
        Body::new(Archetype::walker(), crate::health::tests_support::skeleton(), 3)
    }

    fn run(brain: &mut Brain, b: &Body, dist: f32, secs: f32) -> Vec<Command> {
        let p = Perception { distance: dist, can_see: true, facing_error: 0.0 };
        (0..(secs / 0.05) as usize).map(|_| brain.tick(0.05, b, &p)).collect()
    }

    #[test]
    fn notices_chases_and_attacks() {
        let b = body();
        let mut brain = Brain::new(1);
        let far = run(&mut brain, &b, 10.0, 2.0);
        assert!(far.iter().any(|c| c.speed > 0.0 && c.anim == Anim::Chase));
        let near = run(&mut brain, &b, 1.0, 3.0);
        assert!(near.iter().any(|c| c.attack_started.is_some()));
        assert!(near.iter().any(|c| c.deal_damage.is_some()));
    }

    #[test]
    fn no_target_means_no_chasing() {
        let b = body();
        let mut brain = Brain::new(4);
        brain.on_stagger();
        let blind = Perception { distance: 99.0, can_see: false, facing_error: 0.0 };
        let cmds: Vec<_> = (0..100).map(|_| brain.tick(0.05, &b, &blind)).collect();
        assert!(cmds.iter().all(|c| c.speed == 0.0));
        assert_eq!(brain.state, State::Idle);
    }

    #[test]
    fn armless_crawler_can_only_bite() {
        let mut b = body();
        b.health = 1e6;
        for bone in ["upperarm_l", "upperarm_r"] {
            let h = Hit::new(b.skeleton.find(bone).unwrap(), 80.0, DamageKind::Sharp, Vec3::ZERO, Vec3::X);
            b.apply_hit(&h);
        }
        let mut brain = Brain::new(2);
        let cmds = run(&mut brain, &b, 1.0, 8.0);
        let names: Vec<_> = cmds.iter().filter_map(|c| c.attack_started.clone()).collect();
        assert!(!names.is_empty() && names.iter().all(|n| n == "Bite"), "{names:?}");
    }
}
