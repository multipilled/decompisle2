//! DI2's splatter render targets, baked on the CPU (recon/SHADERS_FLESH.md §3).
//!
//! DI2 rasterises each mesh section in UV0 space with `FSplatterVS_*` + `FSplatterPS_*Element` and writes two
//! render targets per section group: **DispSplatterRT** (R wound depth, G blood, B bruise, A coverage) and
//! **DiffuseSplatterRT** (R drips, G cauterisation, B fuel, A water). The materials then just sample them at UV0
//! (eyes and hair at UV1, into the head's targets). Decal / ApplyMin batches blend ADD, ApplyMax batches MAX
//! (§3.6), the targets saturate (UNORM), and an H + V pass grows covered texels one texel across UV seams (§3.7).
//!
//! The port does the same per stamp: a [`TexelMap`] holds each covered texel's bind-pose position, normal and
//! deform length (rasterised once per section), and [`SplatterRt::apply`] runs the §3.3 element over the texels
//! the stamp's box can reach.

use std::collections::HashMap;

use glam::Vec3;

use crate::splatter::{Stamp, APPLY_MAX, APPLY_MIN, ABSOLUTE_DEFORMATION, CLOTH_NEVER, CLOTH_ONLY};

/// Grid cell (metres) of the texel lookup.
const CELL: f32 = 0.04;

/// Every texel a section's UV0 layout covers, with what DI2's splatter VS interpolates there.
#[derive(Debug, Clone)]
pub struct TexelMap {
    pub res: usize,
    /// Texel index (y * res + x) per covered texel.
    pub texel: Vec<u32>,
    /// Bind-pose position, interpolated (un-normalised) normal and |deform| (cm) per covered texel.
    pub pos: Vec<Vec3>,
    pub nrm: Vec<Vec3>,
    pub dlen_cm: Vec<f32>,
    /// The section triangle each texel lies in (vertex indices) and its barycentrics there: DI2's default
    /// projection (FSplatterVS_World) reads the skinned position at the time of the hit, interpolated like this.
    pub tri: Vec<[u32; 3]>,
    pub bary: Vec<[f32; 3]>,
    /// Bind-pose bounds of the section.
    pub min: Vec3,
    pub max: Vec3,
    /// Texel indices sorted by cell, and each occupied cell's range in it.
    order: Vec<u32>,
    grid: HashMap<(i32, i32, i32), (u32, u32)>,
}

fn cell(p: Vec3) -> (i32, i32, i32) {
    ((p.x / CELL).floor() as i32, (p.y / CELL).floor() as i32, (p.z / CELL).floor() as i32)
}

impl TexelMap {
    /// Rasterises the section's triangles in UV0 (texel centres, top-left origin like UE's UV space).
    pub fn build(res: usize, pos: &[Vec3], nrm: &[Vec3], dlen_cm: &[f32], uv: &[[f32; 2]], indices: &[u32]) -> TexelMap {
        let mut owner: Vec<u32> = vec![u32::MAX; res * res];
        let mut bary: Vec<[f32; 3]> = vec![[0.0; 3]; res * res];
        for (t, tri) in indices.chunks_exact(3).enumerate() {
            let [a, b, c] = [tri[0] as usize, tri[1] as usize, tri[2] as usize];
            if a >= uv.len() || b >= uv.len() || c >= uv.len() {
                continue;
            }
            let p = |i: usize| [uv[i][0] * res as f32, uv[i][1] * res as f32];
            let (pa, pb, pc) = (p(a), p(b), p(c));
            let area = (pb[0] - pa[0]) * (pc[1] - pa[1]) - (pc[0] - pa[0]) * (pb[1] - pa[1]);
            if area.abs() < 1e-12 {
                continue;
            }
            let x0 = pa[0].min(pb[0]).min(pc[0]).floor().max(0.0) as i64;
            let x1 = pa[0].max(pb[0]).max(pc[0]).ceil().min(res as f32) as i64;
            let y0 = pa[1].min(pb[1]).min(pc[1]).floor().max(0.0) as i64;
            let y1 = pa[1].max(pb[1]).max(pc[1]).ceil().min(res as f32) as i64;
            for y in y0..y1 {
                for x in x0..x1 {
                    let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                    let w0 = ((pb[0] - px) * (pc[1] - py) - (pc[0] - px) * (pb[1] - py)) / area;
                    let w1 = ((pc[0] - px) * (pa[1] - py) - (pa[0] - px) * (pc[1] - py)) / area;
                    let w2 = 1.0 - w0 - w1;
                    if w0 < -1e-5 || w1 < -1e-5 || w2 < -1e-5 {
                        continue;
                    }
                    let k = y as usize * res + x as usize;
                    owner[k] = t as u32;
                    bary[k] = [w0, w1, w2];
                }
            }
        }
        let mut m = TexelMap { res, texel: Vec::new(), pos: Vec::new(), nrm: Vec::new(), dlen_cm: Vec::new(), tri: Vec::new(), bary: Vec::new(), min: Vec3::splat(f32::MAX), max: Vec3::splat(f32::MIN), order: Vec::new(), grid: HashMap::new() };
        for (k, &t) in owner.iter().enumerate() {
            if t == u32::MAX {
                continue;
            }
            let tri = &indices[t as usize * 3..t as usize * 3 + 3];
            let w = bary[k];
            let at = |v: &[Vec3]| v[tri[0] as usize] * w[0] + v[tri[1] as usize] * w[1] + v[tri[2] as usize] * w[2];
            let p = at(pos);
            let n = if nrm.len() == pos.len() { at(nrm) } else { Vec3::ZERO };
            let d = if dlen_cm.len() == pos.len() { dlen_cm[tri[0] as usize] * w[0] + dlen_cm[tri[1] as usize] * w[1] + dlen_cm[tri[2] as usize] * w[2] } else { 0.0 };
            m.texel.push(k as u32);
            m.pos.push(p);
            m.nrm.push(n);
            m.dlen_cm.push(d);
            m.tri.push([tri[0], tri[1], tri[2]]);
            m.bary.push(w);
            m.min = m.min.min(p);
            m.max = m.max.max(p);
        }
        let mut keyed: Vec<((i32, i32, i32), u32)> = m.pos.iter().enumerate().map(|(i, p)| (cell(*p), i as u32)).collect();
        keyed.sort_unstable();
        let mut start = 0;
        while start < keyed.len() {
            let mut end = start;
            while end < keyed.len() && keyed[end].0 == keyed[start].0 {
                end += 1;
            }
            m.grid.insert(keyed[start].0, (start as u32, end as u32));
            start = end;
        }
        m.order = keyed.into_iter().map(|(_, i)| i).collect();
        m
    }

    /// Whether the box [lo, hi] reaches the section's bounds at all.
    pub fn overlaps(&self, lo: Vec3, hi: Vec3) -> bool {
        !(self.texel.is_empty() || hi.x < self.min.x || hi.y < self.min.y || hi.z < self.min.z || lo.x > self.max.x || lo.y > self.max.y || lo.z > self.max.z)
    }

    /// Covered texels (indices into this map) whose cell overlaps the box [lo, hi].
    pub fn near(&self, lo: Vec3, hi: Vec3) -> Vec<u32> {
        self.near_box(lo, hi, None)
    }

    /// `near`, skipping whole cells an oriented box (centre, unit axes, half extents) can't reach.
    pub fn near_box(&self, lo: Vec3, hi: Vec3, obb: Option<(Vec3, [Vec3; 3], [f32; 3])>) -> Vec<u32> {
        if !self.overlaps(lo, hi) {
            return Vec::new();
        }
        let (a, b) = (cell(lo.max(self.min)), cell(hi.min(self.max)));
        let half = Vec3::splat(CELL * 0.5);
        let mut out = Vec::new();
        for x in a.0..=b.0 {
            for y in a.1..=b.1 {
                for z in a.2..=b.2 {
                    let Some(&(s0, s1)) = self.grid.get(&(x, y, z)) else { continue };
                    if let Some((c, ax, he)) = obb {
                        // Separating axes: the box's own three (the cell's three are covered by lo/hi).
                        let cc = Vec3::new(x as f32 + 0.5, y as f32 + 0.5, z as f32 + 0.5) * CELL;
                        let d = cc - c;
                        if (0..3).any(|k| d.dot(ax[k]).abs() > he[k] + half.dot(ax[k].abs())) {
                            continue;
                        }
                    }
                    out.extend_from_slice(&self.order[s0 as usize..s1 as usize]);
                }
            }
        }
        out
    }
}

/// The two UNORM8 targets of one section (RGBA each, row-major, `res` x `res`).
#[derive(Debug, Clone)]
pub struct SplatterRt {
    pub res: usize,
    pub disp: Vec<[u8; 4]>,
    pub dif: Vec<[u8; 4]>,
    /// Texels the last `apply` wrote (the dilation only has to look around these).
    touched: Vec<u32>,
    /// Per texel: the generation it was last queued in (dedup without sorting).
    mark: Vec<u32>,
    generation: u32,
}

/// Texel rectangle [x0, x1) x [y0, y1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x0: usize,
    pub y0: usize,
    pub x1: usize,
    pub y1: usize,
}

fn q(v: f32) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0).round() as u8
}

fn f(v: u8) -> f32 {
    v as f32 / 255.0
}

/// A stamp texture's RGBA (0..1) at (u, v), bilinear with clamp (the PS's `t0/t1.Sample`).
pub type Sampler<'a> = &'a dyn Fn(i32, f32, f32) -> [f32; 4];

impl SplatterRt {
    pub fn new(res: usize) -> SplatterRt {
        SplatterRt { res, disp: vec![[0; 4]; res * res], dif: vec![[0; 4]; res * res], touched: Vec::new(), mark: vec![0; res * res], generation: 0 }
    }

    /// The stamp's box in bind pose (axis-aligned bounds; cloth sections use ClothingDepthScale).
    pub fn bounds(s: &Stamp, cloth: bool) -> (Vec3, Vec3) {
        let d = s.depth * if cloth { s.cloth_depth } else { 1.0 };
        let e = s.ay.abs() * s.half_size + s.az.abs() * s.half_size + s.ax.abs() * d;
        (s.origin - e, s.origin + e)
    }

    /// One planar element (§3.3) for every texel the box reaches, blended into the targets: ADD (saturating) for
    /// Decal and ApplyMin, MAX for ApplyMax. Returns the texel rectangle that changed.
    pub fn apply(&mut self, map: &TexelMap, s: &Stamp, cloth: bool, sample: Sampler) -> Option<Rect> {
        self.apply_posed(map, s, cloth, sample, None)
    }

    /// `apply` against posed vertices (`posed` = skinned positions and normals in the stamp's space, per section
    /// vertex): DI2's World projection. The texel lookup grid is bind-pose, so every covered texel is visited.
    pub fn apply_posed(&mut self, map: &TexelMap, s: &Stamp, cloth: bool, sample: Sampler, posed: Option<(&[Vec3], &[Vec3])>) -> Option<Rect> {
        let (lo, hi) = Self::bounds(s, cloth);
        let filtered = (s.flags & CLOTH_ONLY != 0 && !cloth) || (s.flags & CLOTH_NEVER != 0 && cloth);
        let zs = 1.0 / (s.depth * if cloth { s.cloth_depth } else { 1.0 }).max(1e-5);
        let hs = s.half_size.max(1e-6);
        let rng = if s.range[1].abs() > 1e-6 { s.range[1] } else { 1.0 };
        let a = s.angle_wrap;
        let (kr, kg) = (2.0 * a - 1.0, 4.0 * a - 1.0);
        let (den_r, den_g) = (1.0 - (-kr).max(0.0), 1.0 - (-kg).max(0.0));
        let ws = [s.wound[0] * if cloth { s.cloth_displacement } else { 1.0 }, s.wound[1], s.wound[2]];
        let (min_mode, max_mode) = (s.flags & APPLY_MIN != 0, s.flags & APPLY_MAX != 0);
        let mut rect: Option<Rect> = None;
        self.touched.clear();
        let d_half = s.depth * if cloth { s.cloth_depth } else { 1.0 };
        let obb = (s.origin, [s.ay, s.az, s.ax], [s.half_size, s.half_size, d_half]);
        let candidates: Vec<u32> = if posed.is_some() { (0..map.texel.len() as u32).collect() } else { map.near_box(lo, hi, Some(obb)) };
        for i in candidates {
            let i = i as usize;
            let (p, nrm) = match posed {
                Some((pp, nn)) => {
                    let (t, w) = (map.tri[i], map.bary[i]);
                    let at = |v: &[Vec3]| v[t[0] as usize] * w[0] + v[t[1] as usize] * w[1] + v[t[2] as usize] * w[2];
                    (at(pp), at(nn))
                }
                None => (map.pos[i], map.nrm[i]),
            };
            let d = p - s.origin;
            let lx = d.dot(s.ay) / hs;
            let ly = d.dot(s.az) / hs;
            let zp = d.dot(-s.ax) * zs;
            if !(lx.abs() < 1.0 && ly.abs() < 1.0 && zp.abs() < 1.0) {
                continue;
            }
            let (u, v) = ((lx * 0.5 + 0.5).clamp(0.0, 1.0), (ly * 0.5 + 0.5).clamp(0.0, 1.0));
            let fade = (s.fade_gain - zp.abs().min(1.0) * s.fade_gain).clamp(0.0, 1.0);
            let fw = nrm.dot(-s.ax) * 0.5 + 0.5;
            let w_r = if den_r > 0.0 { ((fw + kr) / den_r).clamp(0.0, 1.0) } else { 0.0 };
            let w_g = if den_g > 0.0 { ((fw + kg) / den_g).clamp(0.0, 1.0) } else { 0.0 };
            let mut dc = [0.0f32; 4];
            if s.diffuse_tex >= 0 {
                let t = sample(s.diffuse_tex, u, v);
                for c in 0..4 {
                    dc[c] = s.fx[c] * (t[c] - s.range[0]) / rng * fade * w_g;
                }
            }
            let mut wd = [0.0f32; 3];
            if s.displacement_tex >= 0 && !filtered {
                let t = sample(s.displacement_tex, u, v);
                let wrap = [w_r, w_g, w_g];
                for c in 0..3 {
                    wd[c] = ws[c] * (t[c] - s.range[0]) / rng * fade * wrap[c];
                }
                if s.flags & ABSOLUTE_DEFORMATION != 0 {
                    wd[0] *= 3.0 / map.dlen_cm[i].max(1.0);
                }
            }
            let k = map.texel[i] as usize;
            self.touched.push(k as u32);
            let (dst_w, dst_d) = (&mut self.disp[k], &mut self.dif[k]);
            if max_mode {
                for c in 0..3 {
                    dst_w[c] = q(f(dst_w[c]).max(wd[c].max(0.0)));
                }
                dst_w[3] = 255;
                for c in 0..4 {
                    dst_d[c] = q(f(dst_d[c]).max(dc[c].max(0.0)));
                }
            } else if min_mode {
                // Negative part only, alpha min(0, 1) = 0: subtracts, adds no coverage.
                for c in 0..3 {
                    dst_w[c] = q(f(dst_w[c]) + wd[c].min(0.0));
                }
                for c in 0..4 {
                    dst_d[c] = q(f(dst_d[c]) + dc[c].min(0.0));
                }
            } else {
                for c in 0..3 {
                    dst_w[c] = q(f(dst_w[c]) + wd[c]);
                }
                dst_w[3] = 255;
                for c in 0..4 {
                    dst_d[c] = q(f(dst_d[c]) + dc[c]);
                }
            }
            let (x, y) = (k % self.res, k / self.res);
            rect = Some(match rect {
                None => Rect { x0: x, y0: y, x1: x + 1, y1: y + 1 },
                Some(r) => Rect { x0: r.x0.min(x), y0: r.y0.min(y), x1: r.x1.max(x + 1), y1: r.y1.max(y + 1) },
            });
        }
        rect
    }

    /// One H then one V dilation pass (§3.7): covered texels (Disp.a = 1) stay, empty ones take the neighbour with
    /// the highest coverage (left/up first, then right/down). DI2 runs it over the whole target; only texels next
    /// to what the last `apply` wrote can change, so only those are visited. `_r` is kept for the call sites.
    pub fn dilate(&mut self, _r: Rect) {
        let res = self.res;
        // H pass: touched texels (ApplyMin ones add no coverage) and their left / right neighbours.
        self.generation = self.generation.wrapping_add(1).max(1);
        let g = self.generation;
        let mut h_set: Vec<u32> = Vec::with_capacity(self.touched.len() * 3);
        for i in 0..self.touched.len() {
            let k = self.touched[i] as usize;
            let (x, y) = (k % res, k / res);
            for (nx, ok) in [(x, true), (x.wrapping_sub(1), x > 0), (x + 1, x + 1 < res)] {
                let j = y * res + nx;
                if ok && self.mark[j] != g {
                    self.mark[j] = g;
                    h_set.push(j as u32);
                }
            }
        }
        let h_out = self.pass(&h_set, true);
        for &(k, w, d) in &h_out {
            self.disp[k as usize] = w;
            self.dif[k as usize] = d;
        }
        // V pass: up / down neighbours of everything the H pass looked at.
        self.generation = self.generation.wrapping_add(1).max(1);
        let g = self.generation;
        let mut v_set: Vec<u32> = Vec::with_capacity(h_set.len() * 3);
        for &k in &h_set {
            let k = k as usize;
            let (x, y) = (k % res, k / res);
            for (ny, ok) in [(y, true), (y.wrapping_sub(1), y > 0), (y + 1, y + 1 < res)] {
                let j = ny * res + x;
                if ok && self.mark[j] != g {
                    self.mark[j] = g;
                    v_set.push(j as u32);
                }
            }
        }
        let v_out = self.pass(&v_set, false);
        for &(k, w, d) in &v_out {
            self.disp[k as usize] = w;
            self.dif[k as usize] = d;
        }
    }

    /// One dilation pass over `set`, reading the current targets (results applied after the pass, like a separate
    /// render target).
    fn pass(&self, set: &[u32], horizontal: bool) -> Vec<(u32, [u8; 4], [u8; 4])> {
        let res = self.res;
        let mut out = Vec::new();
        for &k in set {
            let k = k as usize;
            let (x, y) = (k % res, k / res);
            let (mut c0, mut c1) = (self.disp[k], self.dif[k]);
            if c0[3] == 255 {
                continue;
            }
            let n = if horizontal { [(x.wrapping_sub(1), y), (x + 1, y)] } else { [(x, y.wrapping_sub(1)), (x, y + 1)] };
            for (nx, ny) in n {
                if nx >= res || ny >= res {
                    continue;
                }
                let j = ny * res + nx;
                if c0[3] < self.disp[j][3] {
                    // * sign(a): a > 0 here
                    c0 = self.disp[j];
                    c1 = self.dif[j];
                }
            }
            c0[3] = if horizontal { if c0[3] > 0 { 128 } else { 0 } } else { 0 };
            out.push((k as u32, c0, c1));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quad_map(res: usize) -> TexelMap {
        // A 1 m square in the XY plane (normal +Z), UV0 covering the whole atlas.
        let pos = [Vec3::new(-0.5, -0.5, 0.0), Vec3::new(0.5, -0.5, 0.0), Vec3::new(0.5, 0.5, 0.0), Vec3::new(-0.5, 0.5, 0.0)];
        let nrm = [Vec3::Z; 4];
        let uv = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
        TexelMap::build(res, &pos, &nrm, &[0.0; 4], &uv, &[0, 1, 2, 0, 2, 3])
    }

    fn stamp(flags: u32) -> Stamp {
        Stamp {
            origin: Vec3::ZERO, ax: -Vec3::Z, ay: Vec3::X, az: Vec3::Y, half_size: 0.1, depth: 0.1, fade_gain: 1.0, angle_wrap: 1.0,
            displacement_tex: 0, diffuse_tex: 0, flags, cloth_depth: 1.0, cloth_displacement: 1.0, wound: [0.5, 0.5, 0.5],
            fx: [0.5, 0.5, 0.5, 0.5], range: [0.0, 1.0], displacement: 1.0, persistent: false, id: 0,
        }
    }

    #[test]
    fn texel_map_covers_the_quad() {
        let m = quad_map(64);
        assert_eq!(m.texel.len(), 64 * 64);
        assert!(m.near(Vec3::splat(-0.05), Vec3::splat(0.05)).len() > 16);
        assert!(m.near(Vec3::splat(2.0), Vec3::splat(3.0)).is_empty());
    }

    #[test]
    fn add_saturates_and_max_holds() {
        let m = quad_map(64);
        let one = |_: i32, _: f32, _: f32| [1.0f32; 4];
        let mut rt = SplatterRt::new(64);
        let r = rt.apply(&m, &stamp(0), false, &one).expect("covers texels");
        let c = 32 * 64 + 32;
        assert_eq!(rt.disp[c][0], 128, "0.5 written at the impact");
        rt.apply(&m, &stamp(0), false, &one);
        rt.apply(&m, &stamp(0), false, &one);
        assert_eq!(rt.disp[c][0], 255, "ADD saturates");
        let mut rt2 = SplatterRt::new(64);
        rt2.apply(&m, &stamp(APPLY_MAX), false, &one);
        rt2.apply(&m, &stamp(APPLY_MAX), false, &one);
        assert_eq!(rt2.disp[c][0], 128, "MAX holds the larger value");
        assert!(r.x0 < 32 && r.x1 > 32);
        // Dilation grows coverage one texel past the box edge.
        let edge = r.x1;
        rt.dilate(r);
        assert!(rt.disp[32 * 64 + edge][0] > 0 && rt.disp[32 * 64 + edge][3] < 255);
    }
}
