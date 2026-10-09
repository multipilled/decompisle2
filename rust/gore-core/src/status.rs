//! Elemental status effects (DI2's weapon mods, curveballs, explosions) and DI2's accumulating-effect meters
//! (UAccumulatingEffectComponent / UAccumulatingEffectInstance, recon/RE_ACCUMULATING.md).
//! - Burning (fire): damage over time, keeps charring the wounds.
//! - Electrified (shock): stunned and twitching, plus damage.
//! - Caustic (acid): damage over time and Weakened (takes more damage); wounds keep melting.
//! - Bleeding: damage over time.
//!
//! The meter: one instance per effect type, a 0..1 value with a state (Accumulating 0, Active 1, Paused 2,
//! Idle 3) and a drain rate. Each applier calls `accumulate` (UpdateEffectValue 0x141473550 -> instance update
//! 0x1414746f0):
//!   Idle / Accumulating: value += v x GainMultiplier (bApplyMaxValue: 1), clamped to 0..1; at 1 the status
//!     begins (Active); otherwise, AccumulatingPauseDuration after the last gain the meter decays at
//!     AccumulatingDecayRatePerSecond x DecayMultiplier and the instance resets to Idle when it reaches 0.
//!   Active: the meter drains at 1 / (DefaultEffectDuration x DurationMultiplier); the status ends (reset) at 0.
//!     A hit with CanExtendEffectDuration pauses it (Paused) for PauseDuration; another such hit re-arms the
//!     pause; then it resumes Active.
//! The current value is stored - rate x elapsed since the last update (0x14145df40), and while Idle /
//! Accumulating the first AccumulatingPauseDuration of that elapsed time doesn't count.
//! Numbers: DI2's DA_AccumulatingEffectConfig_* (game/data/accumulating_effects.json); the defaults below are
//! Walker_Default's (DefaultAI). Damage: the zombie status BPs' InitialDamage at the start and DamagePerSecond
//! after (BP_StatusEffect_Burning_Zombie 30 + 15/s, BP_StatusEffect_Electrocute_Zombie 25 + 10/s (the DoT base),
//! BP_Base_StatusEffect_Corroded 15 + 7/s x Curve_DamageOverTimeStatusEffect_DamageCorroded (1 -> 0 linear over the
//! effect), DI2's Bleed applies BP_StatusEffect_Draining_Zombie 25 + 10/s). Corroded's ElementalDebuffToApply
//! 0.25 raises elemental damage taken.
//! - Weakened (tearing mods): BP_StatusEffect_Weakened (BP_Base_StatusEffect_ApplyDebuff) adds
//!   BP_StatusEffectParams_Weakened.DamageTakenModifier 0.3 to DA_ModifiableValueDef_PhysicalDamageReceivedModifier
//!   while it runs: physical damage (Blunt / Sharp / Projectile / Explosive / Bleed, BP_DamageType_* DamageCategory)
//!   x 1.3. No damage of its own.
//! - Disoriented (impact mods): BP_StatusEffect_Disoriented (BP_Base_StatusEffect_Stun) on an AI: the
//!   StopActions / StopEngagementOpportunity facts and the Disorientated / DisorientatedEnd anim sets
//!   (DA_ActionDefinition_Stun_Disorientated_AI), and at ReceiveBegin AddDeviationModifier: its accumulating
//!   duration multiplier (DA_ModifiableValue_AccumulatingEffect_Disoriented_DurationMultiplier, Multiplicative)
//!   x RandomFloatInRange(DeviationModifierMin 0.85, DeviationModifierMax 1.15), removed at ReceiveEnd
//!   (`set_duration_deviation`). No damage of its own.
//! ModifiableValues (exe 0x141aadf70 recompute, 0x141a9aff0 GetCurrentValue): base = DefaultValueOverride (else
//! 0 for Additive / Max, 1 for Min / Multiplicative), each source's value combined by the definition's
//! ResolutionType (def +0x40: Additive 0, Min 1, Max 2, Multiplicative 3), clamped to Min/MaxValueLimit.

use serde::{Deserialize, Serialize};

use crate::damage::DamageKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Status {
    Burning = 0,
    Electrified = 1,
    Caustic = 2,
    Bleeding = 3,
    Weakened = 4,
    Disoriented = 5,
}

/// Number of accumulating effect types the port tracks.
pub const N: usize = 6;

/// BP_StatusEffectParams_Weakened.DamageTakenModifier (added to PhysicalDamageReceivedModifier).
pub const WEAKENED_DAMAGE_TAKEN: f32 = 0.3;
/// Corroded's ElementalDebuffToApply (added to ElementalDamageReceivedModifier).
pub const CORRODED_DAMAGE_TAKEN: f32 = 0.25;
/// DA_ModifiableValueDef_{Physical,Elemental}DamageReceivedModifier MaxValueLimit.
pub const DAMAGE_RECEIVED_MAX: f32 = 2.0;

impl Status {
    pub const ALL: [Status; N] =
        [Status::Burning, Status::Electrified, Status::Caustic, Status::Bleeding, Status::Weakened, Status::Disoriented];

    pub fn for_kind(kind: DamageKind) -> Option<Self> {
        match kind {
            DamageKind::Fire => Some(Status::Burning),
            DamageKind::Electric => Some(Status::Electrified),
            DamageKind::Acid => Some(Status::Caustic),
            DamageKind::Bleed => Some(Status::Bleeding),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Status::Burning => "burning",
            Status::Electrified => "electrified",
            Status::Caustic => "caustic",
            Status::Bleeding => "bleeding",
            Status::Weakened => "weakened",
            Status::Disoriented => "disoriented",
        }
    }

    /// From a status name or DI2's EAccumulatingEffectType name.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "burning" | "Burning" => Some(Status::Burning),
            "electrified" | "Electrocuted" => Some(Status::Electrified),
            "caustic" | "Corroded" => Some(Status::Caustic),
            "bleeding" | "Bleed" => Some(Status::Bleeding),
            "weakened" | "Weakened" => Some(Status::Weakened),
            "disoriented" | "Disoriented" => Some(Status::Disoriented),
            _ => None,
        }
    }

    /// (initial damage, damage per second): DI2's zombie status BPs (module docs).
    pub fn damage(self) -> (f32, f32) {
        match self {
            Status::Burning => (30.0, 15.0),
            Status::Electrified => (25.0, 10.0),
            Status::Caustic => (15.0, 7.0),
            Status::Bleeding => (25.0, 10.0),
            Status::Weakened | Status::Disoriented => (0.0, 0.0),
        }
    }

    /// DA_AccumulatingEffectConfig_Walker_Default's entry.
    pub fn walker_def(self) -> AccumDef {
        let duration = match self {
            Status::Electrified => 4.0,
            Status::Weakened => 7.0,
            _ => 5.0,
        };
        AccumDef { decay_rate: 0.05, duration, accumulating_pause: 2.5, pause: 1.0, ..AccumDef::default() }
    }
}

/// One effect type's FAccumulatingEffectSettings plus its modifiers' values.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AccumDef {
    /// AccumulatingDecayRatePerSecond.
    pub decay_rate: f32,
    /// DefaultEffectDuration (s).
    pub duration: f32,
    /// AccumulatingPauseDuration (s): no decay this long after a gain.
    pub accumulating_pause: f32,
    /// PauseDuration (s): an extending hit pauses an active effect this long.
    pub pause: f32,
    /// GainModifier / DecayModifier / EffectDurationModifier (DefaultValueOverride 1 in DI2's data).
    pub gain: f32,
    pub decay_mult: f32,
    pub duration_mult: f32,
}

impl Default for AccumDef {
    fn default() -> Self {
        AccumDef { decay_rate: 0.05, duration: 5.0, accumulating_pause: 2.5, pause: 1.0, gain: 1.0, decay_mult: 1.0, duration_mult: 1.0 }
    }
}

const ACCUMULATING: u8 = 0;
const ACTIVE: u8 = 1;
const PAUSED: u8 = 2;
const IDLE: u8 = 3;

/// UAccumulatingEffectInstance: +0x29 state, +0x2c stored value, +0x30 last update time, +0x34 rate, timers
/// +0xb0 (reset) and +0xb8 (pause end).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AccumInstance {
    pub state: u8,
    pub stored: f32,
    pub last: f64,
    pub rate: f32,
    /// The reset timer: fire time, or the time left while paused.
    reset_at: Option<f64>,
    reset_paused_left: Option<f64>,
    pause_end_at: Option<f64>,
}

impl Default for AccumInstance {
    fn default() -> Self {
        AccumInstance { state: IDLE, stored: 0.0, last: 0.0, rate: 0.0, reset_at: None, reset_paused_left: None, pause_end_at: None }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusEffects {
    pub now: f64,
    pub inst: [AccumInstance; N],
    pub defs: [AccumDef; N],
    /// Runtime factor on DurationMultiplier (Disoriented's deviation modifier), 1 otherwise.
    pub duration_dev: [f32; N],
}

impl Default for StatusEffects {
    fn default() -> Self {
        StatusEffects {
            now: 0.0,
            inst: [AccumInstance { rate: 0.05, ..AccumInstance::default() }; N],
            defs: Status::ALL.map(Status::walker_def),
            duration_dev: [1.0; N],
        }
    }
}

impl StatusEffects {
    /// The instance's DurationMultiplier (+0x3C): the config's, times a runtime modifier.
    fn dur_mult(&self, i: usize) -> f32 {
        self.defs[i].duration_mult * self.duration_dev[i]
    }

    fn rate_for(&self, i: usize, state: u8) -> f32 {
        let d = &self.defs[i];
        match state {
            ACTIVE => 1.0 / (d.duration * self.dur_mult(i)).max(1e-4),
            PAUSED => 0.0,
            _ => d.decay_rate * d.decay_mult,
        }
    }

    /// The meter now (0x14145df40).
    pub fn current(&self, s: Status) -> f32 {
        self.current_i(s as usize)
    }

    fn current_i(&self, i: usize) -> f32 {
        let a = &self.inst[i];
        let mut elapsed = (self.now - a.last) as f32;
        if a.state == IDLE || a.state == ACCUMULATING {
            elapsed = (elapsed - self.defs[i].accumulating_pause).max(0.0);
        }
        (a.stored - elapsed * a.rate).max(0.0)
    }

    /// 0x1414729a0: re-base the meter and change the drain rate; a running reset timer is re-armed for the new
    /// rate (0x141473310: current x DefaultEffectDuration x DurationMultiplier), keeping it paused if it was.
    fn set_rate(&mut self, i: usize, rate: f32) {
        if rate == self.inst[i].rate {
            return;
        }
        self.inst[i].stored = self.current_i(i);
        self.inst[i].last = self.now;
        self.inst[i].rate = rate;
        if self.inst[i].reset_at.is_some() || self.inst[i].reset_paused_left.is_some() {
            let left = (self.current_i(i) * self.dur_mult(i) * self.defs[i].duration) as f64;
            if self.inst[i].reset_paused_left.is_some() {
                self.inst[i].reset_paused_left = Some(left);
            } else {
                self.inst[i].reset_at = Some(self.now + left);
            }
        }
    }

    /// 0x141450ec0: value += v x GainMultiplier (bApplyMaxValue: 1), clamped to 0..1.
    fn add_value(&mut self, i: usize, v: f32, apply_max: bool) {
        let v = if apply_max { 1.0 } else if v > 0.0 { v * self.defs[i].gain } else { v };
        self.inst[i].stored = (self.current_i(i) + v).clamp(0.0, 1.0);
        self.inst[i].last = self.now;
    }

    /// The Accumulating reset timer: the meter reaches 0 after the accumulating pause.
    fn arm_decay_reset(&mut self, i: usize) {
        let rate = self.rate_for(i, ACCUMULATING).max(1e-6);
        self.inst[i].reset_at = Some(self.now + (self.current_i(i) / rate + self.defs[i].accumulating_pause) as f64);
        self.inst[i].reset_paused_left = None;
    }

    /// 0x141472a50. Returns the status when this change began it.
    fn set_state(&mut self, i: usize, state: u8) -> Option<Status> {
        if self.inst[i].state == state {
            return None;
        }
        let was_active = matches!(self.inst[i].state, ACTIVE | PAUSED);
        self.inst[i].state = state;
        match state {
            ACCUMULATING => {
                self.set_rate(i, self.rate_for(i, ACCUMULATING));
                self.arm_decay_reset(i);
                None
            }
            ACTIVE => {
                self.set_rate(i, self.rate_for(i, ACTIVE));
                if let Some(left) = self.inst[i].reset_paused_left.take() {
                    self.inst[i].reset_at = Some(self.now + left); // UnPauseTimer
                } else if self.inst[i].reset_at.is_none() {
                    self.inst[i].reset_at = Some(self.now + (self.defs[i].duration * self.dur_mult(i)) as f64);
                }
                if was_active { None } else { Some(Status::ALL[i]) }
            }
            PAUSED => {
                self.set_rate(i, 0.0);
                if let Some(at) = self.inst[i].reset_at.take() {
                    self.inst[i].reset_paused_left = Some((at - self.now).max(0.0)); // PauseTimer
                }
                self.inst[i].pause_end_at = Some(self.now + self.defs[i].pause as f64);
                None
            }
            _ => {
                self.set_rate(i, self.rate_for(i, IDLE));
                None
            }
        }
    }

    /// 0x14146c340: timers cleared, value 0, Idle. Returns whether an active status ended.
    fn reset(&mut self, i: usize) -> bool {
        let was_active = matches!(self.inst[i].state, ACTIVE | PAUSED);
        self.inst[i].reset_at = None;
        self.inst[i].reset_paused_left = None;
        self.inst[i].pause_end_at = None;
        self.inst[i].stored = 0.0;
        self.inst[i].last = self.now;
        self.set_state(i, IDLE);
        if was_active {
            self.duration_dev[i] = 1.0; // the status's ReceiveEnd removes its modifiers (Disoriented's deviation)
        }
        was_active
    }

    /// UAccumulatingEffectComponent::UpdateEffectValue for one effect (`v` already level-scaled). Returns the
    /// status if this application began it.
    pub fn accumulate(&mut self, s: Status, v: f32, apply_max: bool, can_extend: bool) -> Option<Status> {
        let i = s as usize;
        match self.inst[i].state {
            ACCUMULATING => {
                self.add_value(i, v, apply_max);
                if self.inst[i].stored >= 1.0 {
                    return self.set_state(i, ACTIVE);
                }
                self.arm_decay_reset(i);
                None
            }
            ACTIVE => {
                if can_extend {
                    self.set_state(i, PAUSED);
                }
                None
            }
            PAUSED => {
                if can_extend {
                    self.inst[i].pause_end_at = Some(self.now + self.defs[i].pause as f64);
                }
                None
            }
            _ => {
                self.add_value(i, v, apply_max);
                if self.inst[i].stored >= 1.0 {
                    self.set_state(i, ACTIVE)
                } else {
                    if self.inst[i].stored > 0.0 {
                        self.set_state(i, ACCUMULATING);
                    }
                    None
                }
            }
        }
    }

    pub fn active(&self, s: Status) -> bool {
        matches!(self.inst[s as usize].state, ACTIVE | PAUSED)
    }

    /// Seconds the active status has left (the meter's drain time), 0 when inactive.
    pub fn remaining(&self, s: Status) -> f32 {
        if !self.active(s) {
            return 0.0;
        }
        self.current(s) * self.defs[s as usize].duration * self.dur_mult(s as usize)
    }

    /// A runtime factor on the effect's DurationMultiplier while it runs (Disoriented's AddDeviationModifier,
    /// RandomFloatInRange(0.85, 1.15)): an active meter re-bases its drain rate and re-arms its reset timer
    /// (SetRate 0x1414729a0). Cleared when the status ends.
    pub fn set_duration_deviation(&mut self, s: Status, m: f32) {
        let i = s as usize;
        self.duration_dev[i] = m.max(1e-4);
        let st = self.inst[i].state;
        let r = self.rate_for(i, st);
        self.set_rate(i, r);
    }

    /// "accumulating" / "active" / "paused" / "idle".
    pub fn state_name(&self, s: Status) -> &'static str {
        match self.inst[s as usize].state {
            ACCUMULATING => "accumulating",
            ACTIVE => "active",
            PAUSED => "paused",
            _ => "idle",
        }
    }

    /// Stunned while electrified.
    pub fn stunned(&self) -> bool {
        self.active(Status::Electrified)
    }

    /// The damage type's category DamageReceivedModifier (Additive, DefaultValueOverride 1, MaxValueLimit 2):
    /// Corroded adds 0.25 to Elemental (Fire / Acid / Electric), Weakened 0.3 to Physical (Blunt / Sharp /
    /// Projectile / Explosive / Bleed: BP_DamageType_Bleed is DA_DamageCategory_Physical).
    pub fn damage_taken_multiplier(&self, kind: DamageKind) -> f32 {
        let elemental = matches!(kind, DamageKind::Fire | DamageKind::Acid | DamageKind::Electric);
        let add = if elemental {
            if self.active(Status::Caustic) { CORRODED_DAMAGE_TAKEN } else { 0.0 }
        } else if self.active(Status::Weakened) {
            WEAKENED_DAMAGE_TAKEN
        } else {
            0.0
        };
        (1.0 + add).min(DAMAGE_RECEIVED_MAX)
    }

    /// Advances time and the meters' timers; returns the damage over time for this step (health points) and the
    /// statuses that ended. Corroded's damage follows its decay curve over the effect: x the meter left.
    pub fn tick(&mut self, dt: f32) -> (f32, Vec<Status>) {
        let mut dot = 0.0;
        let mut ended = Vec::new();
        let end = self.now + dt as f64;
        for s in Status::ALL {
            let i = s as usize;
            // Fire the timers due in this step in time order (pause end, then reset).
            loop {
                let pause = self.inst[i].pause_end_at.filter(|t| *t <= end);
                let reset = self.inst[i].reset_at.filter(|t| *t <= end);
                let first = match (pause, reset) {
                    (Some(p), Some(r)) => Some(if p <= r { (p, true) } else { (r, false) }),
                    (Some(p), None) => Some((p, true)),
                    (None, Some(r)) => Some((r, false)),
                    _ => None,
                };
                let Some((t, is_pause)) = first else { break };
                let saved = self.now;
                self.now = t.max(saved);
                if self.active(s) {
                    dot += self.dot_until(s, t, saved);
                }
                if is_pause {
                    self.inst[i].pause_end_at = None;
                    self.set_state(i, ACTIVE);
                } else if self.reset(i) {
                    ended.push(s);
                }
            }
            if self.active(s) {
                dot += self.dot_until(s, end, self.now);
            }
        }
        self.now = end;
        (dot, ended)
    }

    fn dot_until(&self, s: Status, until: f64, from: f64) -> f32 {
        let dt = (until - from).max(0.0) as f32;
        let decay = if s == Status::Caustic { self.current(s).clamp(0.0, 1.0) } else { 1.0 };
        s.damage().1 * decay * dt
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(st: &mut StatusEffects, secs: f32) -> Vec<Status> {
        let mut ended = vec![];
        let steps = (secs / 0.05).round() as i32;
        for _ in 0..steps {
            ended.extend(st.tick(0.05).1);
        }
        ended
    }

    #[test]
    fn meter_fills_then_the_effect_runs_its_duration() {
        let mut st = StatusEffects::default();
        assert_eq!(st.accumulate(Status::Burning, 0.3, false, false), None);
        assert_eq!(st.state_name(Status::Burning), "accumulating");
        assert_eq!(st.accumulate(Status::Burning, 0.3, false, false), None);
        assert_eq!(st.accumulate(Status::Burning, 0.3, false, false), None);
        assert!((st.current(Status::Burning) - 0.9).abs() < 1e-5);
        assert_eq!(st.accumulate(Status::Burning, 0.3, false, false), Some(Status::Burning));
        assert!(st.active(Status::Burning));
        let (dot, _) = st.tick(1.0);
        assert!((dot - 15.0).abs() < 1e-3, "15 / s while burning: {dot}");
        // Walker Burning: 5 s.
        let ended = run(&mut st, 3.9);
        assert!(ended.is_empty() && st.active(Status::Burning));
        assert_eq!(run(&mut st, 0.2), vec![Status::Burning]);
        assert_eq!(st.state_name(Status::Burning), "idle");
    }

    #[test]
    fn meter_waits_then_decays_to_idle() {
        let mut st = StatusEffects::default();
        st.accumulate(Status::Caustic, 0.5, false, false);
        run(&mut st, 2.5);
        assert!((st.current(Status::Caustic) - 0.5).abs() < 1e-3, "no decay for AccumulatingPauseDuration");
        run(&mut st, 4.0);
        assert!((st.current(Status::Caustic) - 0.3).abs() < 1e-3, "0.05 / s after the pause");
        run(&mut st, 6.5);
        assert_eq!(st.state_name(Status::Caustic), "idle");
    }

    #[test]
    fn extending_hits_pause_an_active_effect() {
        let mut st = StatusEffects::default();
        st.accumulate(Status::Burning, 1.0, false, true);
        run(&mut st, 2.0);
        st.accumulate(Status::Burning, 1.0, false, true);
        assert_eq!(st.state_name(Status::Burning), "paused");
        let left = st.remaining(Status::Burning);
        run(&mut st, 0.5);
        assert!((st.remaining(Status::Burning) - left).abs() < 1e-3, "frozen while paused");
        // Ends 5 s + the 1 s pause after it began.
        assert!(run(&mut st, 3.4).is_empty());
        assert_eq!(run(&mut st, 0.2), vec![Status::Burning]);
    }

    #[test]
    fn shock_stuns_acid_weakens() {
        let mut st = StatusEffects::default();
        st.accumulate(Status::Electrified, 1.0, true, false);
        assert!(st.stunned());
        st.accumulate(Status::Caustic, 1.0, false, false);
        assert!(st.damage_taken_multiplier(DamageKind::Fire) > 1.0);
        assert_eq!(st.damage_taken_multiplier(DamageKind::Blunt), 1.0);
        assert_eq!(st.damage_taken_multiplier(DamageKind::Bleed), 1.0); // Bleed is Physical in DI2
    }

    #[test]
    fn weakened_raises_physical_damage_taken() {
        let mut st = StatusEffects::default();
        assert_eq!(st.accumulate(Status::Weakened, 1.0, false, false), Some(Status::Weakened));
        assert!((st.damage_taken_multiplier(DamageKind::Sharp) - 1.3).abs() < 1e-6);
        assert!((st.damage_taken_multiplier(DamageKind::Bleed) - 1.3).abs() < 1e-6);
        assert_eq!(st.damage_taken_multiplier(DamageKind::Fire), 1.0);
        // Walker_Default Weakened DefaultEffectDuration 7 s.
        assert!(run(&mut st, 6.9).is_empty());
        assert_eq!(run(&mut st, 0.2), vec![Status::Weakened]);
        assert_eq!(st.damage_taken_multiplier(DamageKind::Sharp), 1.0);
    }

    #[test]
    fn disoriented_deviation_scales_its_duration() {
        let mut st = StatusEffects::default();
        st.accumulate(Status::Disoriented, 1.0, false, false);
        st.set_duration_deviation(Status::Disoriented, 1.15);
        assert!((st.remaining(Status::Disoriented) - 5.75).abs() < 1e-4);
        assert!(run(&mut st, 5.7).is_empty());
        assert_eq!(run(&mut st, 0.1), vec![Status::Disoriented]);
        assert_eq!(st.duration_dev[Status::Disoriented as usize], 1.0);
    }
}
