//! DI2 FLESH splatter stamps, as DI2's Splatter plugin packs them for its shaders (recon/RE_FLESH.md "Batch
//! packing", recon/SHADERS_FLESH.md §3–§4).
//!
//! Every wound DI2 paints is a decal: a box in decal space `|x| < 1, |y| < 1, |z| < 1` where x / y run
//! UVScale / 2 across the stamp's u / v axes and z runs DepthScale along its outward axis, symmetric about the
//! impact plane. Its displacement texture (RGB) feeds the wound render target (R wound depth, G blood, B bruise)
//! scaled by WoundScale; its diffuse ("decal") texture (RGBA) feeds the second target (R drips, G cauterisation,
//! B fuel, A water) scaled by FXScale. `FSplatterDeformMeshCS` also accumulates a per-vertex depth that sinks the
//! skin (`deform_vertex`). Positions and axes are in the mesh's bind pose, metres.

use glam::Vec3;

/// Texels (vec4) per stamp in the packed data texture.
pub const STAMP_TEXELS: usize = 8;

/// `flags` bits.
pub const APPLY_MIN: u32 = 1;
pub const APPLY_MAX: u32 = 2;
pub const ABSOLUTE_DEFORMATION: u32 = 4;
pub const SUBTRACTIVE: u32 = 8;
pub const CLOTH_ONLY: u32 = 16;
pub const CLOTH_NEVER: u32 = 32;

#[derive(Debug, Clone)]
pub struct Stamp {
    pub origin: Vec3,
    /// Projection axis (into the body); decal +Z is `-ax`.
    pub ax: Vec3,
    /// Image +u (decal X) and +v (decal Y) axes, unit length.
    pub ay: Vec3,
    pub az: Vec3,
    /// UVScale / 2 and DepthScale, metres.
    pub half_size: f32,
    pub depth: f32,
    /// ScaleVec.x = 1 / clamp(1 - DepthFadeStart, 1e-4, 1).
    pub fade_gain: f32,
    /// clamp(AngleWrap, 0, 1).
    pub angle_wrap: f32,
    pub displacement_tex: i32,
    pub diffuse_tex: i32,
    pub flags: u32,
    pub cloth_depth: f32,
    pub cloth_displacement: f32,
    /// WoundScale.xyz = (DisplacementScale, FluidSplatterAmount, BruisingAmount) x TextureInfluence.
    pub wound: [f32; 3],
    /// FXScale = (FluidDripsAmount, CauterisationAmount, 1, 1) x TextureInfluence.
    pub fx: [f32; 4],
    /// RangeParams = (InputMinimum, InputRange).
    pub range: [f32; 2],
    /// ScaleVec.y: DisplacementScale, the deform CS amplitude.
    pub displacement: f32,
    /// Stored set stamps (pre-spawn / initial wounds) are never evicted.
    pub persistent: bool,
    /// Assigned by `Splatter::add_id` (0 = not added yet).
    pub id: u64,
}

#[derive(Debug, Clone)]
pub struct Splatter {
    pub stamps: Vec<Stamp>,
    pub capacity: usize,
    next_id: u64,
}

impl Splatter {
    pub fn new(capacity: usize) -> Self {
        Self { stamps: Vec::new(), capacity, next_id: 1 }
    }

    /// Adds a stamp; when full, the oldest non-persistent stamp makes room.
    pub fn add(&mut self, s: Stamp) -> bool {
        self.add_id(s).is_some()
    }

    /// `add`, returning the stamp's id.
    pub fn add_id(&mut self, mut s: Stamp) -> Option<u64> {
        if self.stamps.len() >= self.capacity {
            match self.stamps.iter().position(|x| !x.persistent) {
                Some(i) => {
                    self.stamps.remove(i);
                }
                None => return None,
            }
        }
        let id = self.next_id;
        self.next_id += 1;
        s.id = id;
        self.stamps.push(s);
        Some(id)
    }

    pub fn get_mut(&mut self, id: u64) -> Option<&mut Stamp> {
        self.stamps.iter_mut().find(|s| s.id == id)
    }

    /// Row-major RGBA float data, `STAMP_TEXELS` texels per stamp, `capacity` stamps wide.
    pub fn pack(&self) -> Vec<f32> {
        let mut v = vec![0.0f32; self.capacity * STAMP_TEXELS * 4];
        for (i, s) in self.stamps.iter().enumerate().take(self.capacity) {
            let o = i * STAMP_TEXELS * 4;
            let rows: [[f32; 4]; STAMP_TEXELS] = [
                [s.origin.x, s.origin.y, s.origin.z, s.half_size],
                [s.ax.x, s.ax.y, s.ax.z, s.depth],
                [s.ay.x, s.ay.y, s.ay.z, s.fade_gain],
                [s.az.x, s.az.y, s.az.z, s.angle_wrap],
                [s.displacement_tex as f32, s.diffuse_tex as f32, s.flags as f32, s.cloth_depth],
                [s.wound[0], s.wound[1], s.wound[2], s.cloth_displacement],
                s.fx,
                [s.range[0], s.range[1], s.displacement, 0.0],
            ];
            for (r, row) in rows.iter().enumerate() {
                v[o + r * 4..o + r * 4 + 4].copy_from_slice(row);
            }
        }
        v
    }
}

impl Stamp {
    /// DI2 animated splatter (`UCosmeticEffect_SplatterMesh::Apply` with animFraction < 1): DisplacementScale,
    /// FluidSplatterAmount, BruisingAmount, FluidDripsAmount and CauterisationAmount scaled by `k`
    /// (TextureInfluence-only terms are not).
    pub fn scaled(&self, k: f32) -> Stamp {
        let mut s = self.clone();
        for w in s.wound.iter_mut() {
            *w *= k;
        }
        s.fx[0] *= k;
        s.fx[1] *= k;
        s.displacement *= k;
        s
    }

    /// Decal coordinates of a bind-pose point: (x, y) in [-1, 1] across the stamp, z' = depth / DepthScale.
    pub fn decal(&self, p: Vec3, cloth: bool) -> Vec3 {
        let d = p - self.origin;
        let zs = 1.0 / (self.depth * if cloth { self.cloth_depth } else { 1.0 }).max(1e-5);
        Vec3::new(d.dot(self.ay) / self.half_size.max(1e-6), d.dot(self.az) / self.half_size.max(1e-6), d.dot(-self.ax) * zs)
    }

    /// The wound-depth angle wrap `wR` (PS / CS): `f = N . decal+Z`, ramp by AngleWrap.
    pub fn wrap_r(&self, n: Vec3) -> f32 {
        let f = n.dot(-self.ax) * 0.5 + 0.5;
        let k = 2.0 * self.angle_wrap - 1.0;
        let den = 1.0 - (-k).max(0.0);
        if den > 0.0 { ((f + k) / den).clamp(0.0, 1.0) } else { 0.0 }
    }

    /// DI2 `FSplatterDeformMeshCS` (Global 936) for one vertex: the vertex's new accumulated depth (0..1).
    /// `p` / `n`: bind-pose position and normal; `cloth`: the vertex's section is clothing; `deform_len_cm`:
    /// length of the vertex's DI2 deform vector (0 = none); `sample_r(tex, u, v)`: the displacement texture's R,
    /// point-sampled at mip 0.
    pub fn deform_vertex(&self, p: Vec3, n: Vec3, cloth: bool, deform_len_cm: f32, depth: f32, sample_r: &dyn Fn(i32, f32, f32) -> f32) -> f32 {
        let l = self.decal(p, cloth);
        if !(l.x.abs() < 1.0 && l.y.abs() < 1.0 && l.z.abs() < 1.0) {
            return depth;
        }
        let filtered = (self.flags & CLOTH_ONLY != 0 && !cloth) || (self.flags & CLOTH_NEVER != 0 && cloth);
        let t = if self.displacement_tex >= 0 && !filtered { sample_r(self.displacement_tex, l.x * 0.5 + 0.5, l.y * 0.5 + 0.5) } else { 0.0 };
        let fade = (self.fade_gain * (1.0 - l.z.abs().min(1.0))).clamp(0.0, 1.0);
        let sy = self.displacement * if cloth { self.cloth_displacement } else { 1.0 };
        let mut v = ((t - self.range[0]) / self.range[1]) * sy * fade * self.wrap_r(n);
        if self.flags & ABSOLUTE_DEFORMATION != 0 && deform_len_cm != 0.0 {
            v *= 3.0 / deform_len_cm.max(1.0);
        }
        let subtractive = self.flags & SUBTRACTIVE != 0;
        let min_mode = self.flags & APPLY_MIN != 0;
        v = if min_mode { if subtractive { 1.0 - v } else { v } } else if subtractive { -v } else { v };
        let s = v / 0.9;
        if self.flags & APPLY_MAX != 0 {
            s.max(depth).clamp(0.0, 1.0)
        } else if min_mode {
            s.min(depth).clamp(0.0, 1.0)
        } else {
            (depth + s).clamp(0.0, 1.0)
        }
    }
}

/// An orthonormal frame: x along `into`, y / z spanning the plane, rolled by `roll` radians.
pub fn frame(into: Vec3, up_hint: Vec3, roll: f32) -> (Vec3, Vec3, Vec3) {
    let ax = into.normalize_or_zero();
    let mut ay = up_hint.cross(ax);
    if ay.length_squared() < 1e-6 {
        ay = Vec3::X.cross(ax);
        if ay.length_squared() < 1e-6 {
            ay = Vec3::Z.cross(ax);
        }
    }
    let ay = ay.normalize();
    let az = ax.cross(ay);
    let (s, c) = roll.sin_cos();
    (ax, ay * c + az * s, az * c - ay * s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamp(p: bool) -> Stamp {
        let (ax, ay, az) = frame(-Vec3::Z, Vec3::Y, 0.0);
        Stamp { origin: Vec3::ZERO, ax, ay, az, half_size: 0.1, depth: 0.15, fade_gain: 2.0, angle_wrap: 1.0, displacement_tex: 3,
            diffuse_tex: -1, flags: ABSOLUTE_DEFORMATION, cloth_depth: 1.0, cloth_displacement: 1.0, wound: [1.2, 1.0, 2.0],
            fx: [0.0, 1.0, 1.0, 1.0], range: [0.0, 1.0], displacement: 1.2, persistent: p, id: 0 }
    }

    #[test]
    fn frame_is_orthonormal_and_rolls() {
        let (x, y, z) = frame(Vec3::new(0.3, -0.2, 1.0), Vec3::Y, 0.7);
        assert!((x.length() - 1.0).abs() < 1e-5 && (y.length() - 1.0).abs() < 1e-5 && (z.length() - 1.0).abs() < 1e-5);
        assert!(x.dot(y).abs() < 1e-5 && x.dot(z).abs() < 1e-5 && y.dot(z).abs() < 1e-5);
    }

    #[test]
    fn full_field_keeps_persistent_stamps() {
        let mut s = Splatter::new(3);
        s.add(stamp(true));
        s.add(stamp(false));
        s.add(stamp(false));
        assert!(s.add(stamp(false)));
        assert_eq!(s.stamps.len(), 3);
        assert!(s.stamps[0].persistent, "pre-spawn stamp survives eviction");
        assert_eq!(s.pack().len(), 3 * STAMP_TEXELS * 4);
    }

    #[test]
    fn deform_cs_accumulates_like_di2() {
        // A vertex on the impact plane, facing the decal (+Z = -ax = +Z world), R = 0.5 everywhere.
        let s = stamp(false);
        let r = |_: i32, _: f32, _: f32| 0.5;
        // v = 0.5 * 1.2 * fade(=1 at the plane) * wR(=1) * 3/max(1, 6 cm) = 0.3; s = v / 0.9.
        let d = s.deform_vertex(Vec3::ZERO, Vec3::Z, false, 6.0, 0.0, &r);
        assert!((d - 0.3 / 0.9).abs() < 1e-5, "{d}");
        // Add mode accumulates, saturating at 1.
        let d2 = s.deform_vertex(Vec3::ZERO, Vec3::Z, false, 6.0, d, &r);
        assert!((d2 - 0.6 / 0.9).abs() < 1e-5);
        // Outside the box (beyond half_size) leaves the depth alone.
        assert_eq!(s.deform_vertex(Vec3::new(0.2, 0.0, 0.0), Vec3::Z, false, 6.0, 0.25, &r), 0.25);
        // ApplyMax keeps the larger value.
        let mut m = stamp(false);
        m.flags |= APPLY_MAX;
        assert!((m.deform_vertex(Vec3::ZERO, Vec3::Z, false, 6.0, 0.9, &r) - 0.9).abs() < 1e-6);
    }
}
