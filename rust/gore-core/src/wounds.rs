//! Wound field: a bounded set of capsule-shaped wounds in bind-pose space.
//!
//! The presentation layer uploads [`WoundField::pack`] to the body's shaders. Each fragment
//! evaluates its rest-pose distance to every capsule and gets a wound depth (0..1) per channel:
//! cut flesh, blunt crush, burn, acid melt and electric scorch. Deep enough flesh wounds let the
//! outer skin layer discard and reveal the muscle, bone and viscera meshes underneath, which is
//! how DI2's layered ("FLESH") bodies read.

use glam::{Vec3, Vec4};
use serde::{Deserialize, Serialize};

use crate::damage::{DamageKind, Hit, Rng};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum WoundChannel {
    Cut = 0,
    Crush = 1,
    Burn = 2,
    Melt = 3,
    Scorch = 4,
}

impl WoundChannel {
    pub fn for_kind(kind: DamageKind) -> Self {
        match kind {
            DamageKind::Sharp | DamageKind::Bleed => WoundChannel::Cut,
            DamageKind::Blunt => WoundChannel::Crush,
            DamageKind::Projectile => WoundChannel::Cut,
            DamageKind::Explosive => WoundChannel::Crush,
            DamageKind::Fire => WoundChannel::Burn,
            DamageKind::Acid => WoundChannel::Melt,
            DamageKind::Electric => WoundChannel::Scorch,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Wound {
    pub a: Vec3,
    pub b: Vec3,
    pub radius: f32,
    /// 0..1: 0.3 skin torn, 0.6 muscle exposed, 0.85+ bone/viscera exposed.
    pub depth: f32,
    pub channel: WoundChannel,
    pub seed: f32,
    pub age: f32,
    /// Acid keeps eating until this depth.
    pub grow_to: f32,
    /// Projection axis (into the body). Zero = spherical wound.
    pub into: Vec3,
    /// How far behind the impact point the wound reaches (bullets pass through limbs).
    pub reach: f32,
}

/// Hit points sit on hitbox capsules a few centimetres outside the skin, so wounds are projected:
/// distance is measured across the impact axis, within [-FRONT, reach] along it.
pub const FRONT: f32 = 0.04;

impl Wound {
    pub fn distance(&self, p: Vec3) -> f32 {
        let ab = self.b - self.a;
        let t = if ab.length_squared() > 1e-12 { ((p - self.a).dot(ab) / ab.length_squared()).clamp(0.0, 1.0) } else { 0.0 };
        let v = p - (self.a + ab * t);
        if self.into.length_squared() < 1e-8 {
            return v.length();
        }
        let along = v.dot(self.into);
        if along < -FRONT || along > self.reach {
            return f32::INFINITY;
        }
        (v - self.into * along).length()
    }

    /// Depth contribution at `p` (smooth falloff to 0 at `radius`).
    pub fn field(&self, p: Vec3) -> f32 {
        let x = (1.0 - self.distance(p) / self.radius).clamp(0.0, 1.0);
        self.depth * x * x * (3.0 - 2.0 * x)
    }
}

/// Size scale for wounds. DI2 works in centimetres; Godot glTF imports in metres.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct WoundScale {
    pub unit: f32,
}

impl Default for WoundScale {
    fn default() -> Self {
        Self { unit: 0.01 }
    }
}

#[derive(Debug, Clone)]
pub struct WoundField {
    pub wounds: Vec<Wound>,
    pub capacity: usize,
    pub scale: WoundScale,
    rng: Rng,
}

impl WoundField {
    pub const MAX: usize = 48;

    pub fn new(capacity: usize, scale: WoundScale, seed: u64) -> Self {
        Self { wounds: Vec::new(), capacity: capacity.min(Self::MAX), scale, rng: Rng::new(seed ^ 0x5157) }
    }

    /// Adds (or deepens) a wound for a hit. Returns the index of the affected wound.
    pub fn add_hit(&mut self, hit: &Hit) -> usize {
        let u = self.scale.unit;
        let ch = WoundChannel::for_kind(hit.kind);
        let strength = (hit.damage / 40.0).clamp(0.15, 1.5);
        let dir = if hit.direction.length_squared() > 1e-8 { hit.direction.normalize() } else { Vec3::Y };
        let (half_len, radius, depth, grow_to) = match ch {
            // Long narrow gash along the swing; sharp weapons open flesh quickly.
            WoundChannel::Cut => (self.rng.range(7.0, 12.0) * u * strength.sqrt(), self.rng.range(3.2, 4.8) * u, 0.55 + 0.35 * strength, 0.0),
            // Round crush that bruises first and only splits at high damage.
            WoundChannel::Crush => (0.0, self.rng.range(5.0, 8.0) * u * strength.sqrt(), 0.25 + 0.3 * strength, 0.0),
            WoundChannel::Burn => (0.0, self.rng.range(9.0, 14.0) * u, 0.35, 0.0),
            WoundChannel::Melt => (0.0, self.rng.range(7.0, 10.0) * u, 0.2, 0.95),
            WoundChannel::Scorch => (self.rng.range(2.0, 5.0) * u, self.rng.range(6.0, 9.0) * u, 0.25, 0.0),
        };
        let a = hit.point - dir * half_len;
        let b = hit.point + dir * half_len;
        let into = hit.into.normalize_or_zero();
        let reach = match hit.kind {
            DamageKind::Projectile => 0.6,
            DamageKind::Explosive => 0.3,
            _ => 0.16,
        };

        // Repeated hits in the same place dig deeper instead of adding new wounds.
        if let Some(i) = self
            .wounds
            .iter()
            .position(|w| w.channel == ch && w.distance(hit.point) < w.radius * 0.6)
        {
            let w = &mut self.wounds[i];
            w.depth = (w.depth + depth * 0.6).min(1.0);
            w.radius = w.radius.max(radius) * 1.08;
            w.grow_to = w.grow_to.max(grow_to);
            w.age = 0.0;
            return i;
        }
        let wound = Wound { a, b, radius, depth: depth.min(1.0), channel: ch, seed: self.rng.f32(), age: 0.0, grow_to, into, reach };
        if self.wounds.len() < self.capacity {
            self.wounds.push(wound);
            self.wounds.len() - 1
        } else {
            // Replace the least significant (shallow, old) wound.
            let i = self
                .wounds
                .iter()
                .enumerate()
                .min_by(|(_, x), (_, y)| (x.depth - x.age * 0.01).total_cmp(&(y.depth - y.age * 0.01)))
                .map(|(i, _)| i)
                .unwrap();
            self.wounds[i] = wound;
            i
        }
    }

    /// Adds a ring wound around a cut so the stump shows open flesh and bone.
    pub fn add_stump(&mut self, center: Vec3, axis: Vec3, radius: f32) {
        let axis = axis.normalize_or_zero();
        let w = Wound {
            a: center - axis * radius * 0.25,
            b: center + axis * radius * 0.25,
            radius: radius * 1.25,
            depth: 1.0,
            channel: WoundChannel::Cut,
            seed: self.rng.f32(),
            age: 0.0,
            grow_to: 0.0,
            into: Vec3::ZERO,
            reach: 0.0,
        };
        if self.wounds.len() < self.capacity {
            self.wounds.push(w);
        } else if let Some(slot) = self.wounds.iter_mut().min_by(|x, y| x.depth.total_cmp(&y.depth)) {
            *slot = w;
        }
    }

    /// Advances acid melt and wound age. Returns true if shader data changed.
    pub fn tick(&mut self, dt: f32) -> bool {
        let mut changed = false;
        for w in &mut self.wounds {
            w.age += dt;
            if w.grow_to > w.depth {
                w.depth = (w.depth + dt * 0.18).min(w.grow_to);
                w.radius += dt * 0.6 * self.scale.unit;
                changed = true;
            }
        }
        changed
    }

    /// Burning and caustic statuses keep eating at their wounds while active.
    pub fn intensify(&mut self, channel: WoundChannel, dt: f32) -> bool {
        let mut changed = false;
        for w in self.wounds.iter_mut().filter(|w| w.channel == channel) {
            w.depth = (w.depth + dt * 0.08).min(0.95);
            w.radius += dt * 0.012 * self.scale.unit / 0.01;
            changed = true;
        }
        changed
    }

    /// Max depth at `p` per channel (CPU reference for the shader, used in tests and gameplay queries).
    pub fn sample(&self, p: Vec3) -> [f32; 5] {
        let mut out = [0.0f32; 5];
        for w in &self.wounds {
            let c = w.channel as usize;
            out[c] = out[c].max(w.field(p));
        }
        out
    }

    /// Shader layout, 4 x vec4 per wound:
    ///   [a.xyz, radius], [b.xyz, depth], [channel, seed, age, reach], [into.xyz, 0]
    pub fn pack(&self) -> Vec<Vec4> {
        let mut v = Vec::with_capacity(self.wounds.len() * 4);
        for w in &self.wounds {
            v.push(w.a.extend(w.radius));
            v.push(w.b.extend(w.depth));
            v.push(Vec4::new(w.channel as u8 as f32, w.seed, w.age, w.reach));
            v.push(w.into.extend(0.0));
        }
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit(kind: DamageKind, p: Vec3, dmg: f32) -> Hit {
        Hit::new(0, dmg, kind, p, Vec3::X)
    }

    #[test]
    fn repeated_hits_deepen_one_wound() {
        let mut f = WoundField::new(16, WoundScale::default(), 1);
        let p = Vec3::new(0.0, 1.0, 0.0);
        f.add_hit(&hit(DamageKind::Sharp, p, 40.0));
        let d0 = f.sample(p)[0];
        f.add_hit(&hit(DamageKind::Sharp, p + Vec3::X * 0.005, 40.0));
        assert_eq!(f.wounds.len(), 1);
        assert!(f.sample(p)[0] > d0);
        assert!(f.sample(p + Vec3::Y * 0.5)[0] == 0.0, "falls off away from the wound");
    }

    #[test]
    fn acid_grows_over_time_and_capacity_holds() {
        let mut f = WoundField::new(4, WoundScale::default(), 2);
        f.add_hit(&hit(DamageKind::Acid, Vec3::ZERO, 20.0));
        let d0 = f.wounds[0].depth;
        assert!(f.tick(1.0));
        assert!(f.wounds[0].depth > d0);
        for i in 0..10 {
            f.add_hit(&hit(DamageKind::Blunt, Vec3::new(i as f32, 0.0, 0.0), 30.0));
        }
        assert_eq!(f.wounds.len(), 4);
        assert_eq!(f.pack().len(), 16);
    }

    #[test]
    fn wounds_project_along_the_impact() {
        let mut f = WoundField::new(8, WoundScale::default(), 3);
        // Impact 5 cm outside a surface at z = 0, travelling -z into the body.
        let mut h = hit(DamageKind::Blunt, Vec3::new(0.0, 0.0, 0.05), 30.0);
        h.into = Vec3::NEG_Z;
        f.add_hit(&h);
        assert!(f.sample(Vec3::ZERO)[1] > 0.1, "skin under the impact is wounded");
        assert_eq!(f.sample(Vec3::new(0.0, 0.0, -0.5))[1], 0.0, "but not deep inside a blunt hit");
        assert_eq!(f.sample(Vec3::new(0.0, 0.0, 0.2))[1], 0.0, "nor in front of it");
    }
}
