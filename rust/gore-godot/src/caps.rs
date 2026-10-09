//! Cut caps: close the hole a severed part leaves, on the body and on the flying piece.
//!
//! The body hides fragments whose weight in the cut slot is above 0.5 and that lie past the slot's cut
//! plane (when the limb is cut mid-bone), so the edge of the hole is the zero line of
//! min(weight - 0.5, plane distance) across the skin and cloth triangles. Every triangle the line crosses
//! gives one rim segment; fanning each segment to the rim's centre closes the hole without having to
//! chain the rim into loops first. The fan is split into rings so the cap domes along the bone axis, and
//! every vertex carries interpolated skin weights (it deforms with the stump) and cut-slot weights (later
//! cuts hide or keep it exactly like the skin around it).

use godot::prelude::*;

use crate::{plane_side, SurfaceCpu, SLOTS};

/// A point on the cut: bind-pose position, skin weights (bind index, weight) and cut-slot weights.
#[derive(Clone)]
pub struct CapVert {
    pub pos: Vector3,
    pub bones: Vec<(i32, f32)>,
    pub slots: [f32; SLOTS],
}

/// Where the cap sits: rim centre, bone axis (towards the severed side), the bone's centre on the cap
/// plane, and the mean rim radius.
pub struct CapFrame {
    pub centre: Vector3,
    pub axis: Vector3,
    pub bone_centre: Vector3,
    pub radius: f32,
}

/// Vertex streams of a cap, ready for an ArrayMesh.
#[derive(Default)]
pub struct CapGeometry {
    pub verts: Vec<Vector3>,
    pub normals: Vec<Vector3>,
    pub tangents: Vec<f32>,
    pub uv: Vec<Vector2>,
    pub uv2: Vec<Vector2>,
    pub bones: Vec<i32>,
    pub weights: Vec<f32>,
    pub custom: [Vec<f32>; 4],
    pub indices: Vec<i32>,
}

/// Ring radii (fraction of the way from centre to rim) the fan is split at.
const RINGS: [f32; 3] = [0.4, 0.75, 1.0];

fn add_weight(bones: &mut Vec<(i32, f32)>, bone: i32, w: f32) {
    match bones.iter_mut().find(|(b, _)| *b == bone) {
        Some(e) => e.1 += w,
        None => bones.push((bone, w)),
    }
}

fn surface_vert(s: &SurfaceCpu, v: usize) -> CapVert {
    let mut bones = Vec::new();
    for j in 0..s.per {
        let (b, w) = (s.bones[v * s.per + j], s.weights[v * s.per + j]);
        if w > 0.0 && b >= 0 {
            add_weight(&mut bones, b, w);
        }
    }
    CapVert { pos: s.verts[v], bones, slots: s.slot_w[v] }
}

/// Weighted blend of cap vertices (weights should sum to 1).
fn blend(parts: &[(&CapVert, f32)]) -> CapVert {
    let mut out = CapVert { pos: Vector3::ZERO, bones: Vec::new(), slots: [0.0; SLOTS] };
    for (v, f) in parts {
        out.pos += v.pos * *f;
        for &(b, w) in &v.bones {
            add_weight(&mut out.bones, b, w * f);
        }
        for k in 0..SLOTS {
            out.slots[k] += v.slots[k] * f;
        }
    }
    out
}

/// One piece of the cut's edge. `cloth` marks edges of clothing, which sits outside the skin.
pub struct RimSeg {
    pub ends: [CapVert; 2],
    pub cloth: bool,
}

/// Rim segments of `slot`'s cut (with its cut plane, see `plane_side`) across these (surface, is cloth) layers.
pub fn rim(surfaces: &[(&SurfaceCpu, bool)], slot: usize, plane: Vector4) -> Vec<RimSeg> {
    let mut segs = Vec::new();
    for &(s, cloth) in surfaces {
        // Signed "past the cut" value, zero on the edge; the shader evaluates the same per fragment.
        let w = |v: usize| (s.slot_w[v][slot] - 0.5).min(plane_side(plane, s.verts[v]));
        for tri in s.indices.chunks_exact(3) {
            let ids = [tri[0] as usize, tri[1] as usize, tri[2] as usize];
            let inside = ids.map(|v| w(v) > 0.0);
            if inside[0] == inside[1] && inside[1] == inside[2] {
                continue;
            }
            let mut pts = Vec::with_capacity(2);
            for (a, b) in [(0, 1), (1, 2), (2, 0)] {
                if inside[a] != inside[b] {
                    let (va, vb) = (ids[a], ids[b]);
                    let t = (-w(va) / (w(vb) - w(va))).clamp(0.0, 1.0);
                    pts.push(blend(&[(&surface_vert(s, va), 1.0 - t), (&surface_vert(s, vb), t)]));
                }
            }
            if let (Some(b), Some(a)) = (pts.pop(), pts.pop()) {
                segs.push(RimSeg { ends: [a, b], cloth });
            }
        }
    }
    segs
}

fn line_distance(p: Vector3, origin: Vector3, axis: Vector3) -> f32 {
    let d = p - origin;
    (d - axis * d.dot(axis)).length()
}

/// Cap frame for a rim around the bone line (`bone_origin`, `axis`). Drops stray segments far off the
/// limb (a weight blend elsewhere on the mesh can graze 0.5 too). None if nothing usable is left.
pub fn frame(segs: &mut Vec<RimSeg>, bone_origin: Vector3, axis: Vector3) -> Option<CapFrame> {
    let axis = axis.normalized();
    let mid = |s: &RimSeg| (s.ends[0].pos + s.ends[1].pos) * 0.5;
    let mut d: Vec<f32> = segs.iter().map(|s| line_distance(mid(s), bone_origin, axis)).collect();
    if d.is_empty() {
        return None;
    }
    d.sort_by(f32::total_cmp);
    let limit = d[d.len() / 2] * 2.5 + 0.02;
    segs.retain(|s| line_distance(mid(s), bone_origin, axis) <= limit);
    let mut centre = Vector3::ZERO;
    let mut total = 0.0;
    for s in segs.iter() {
        let len = (s.ends[1].pos - s.ends[0].pos).length().max(1e-6);
        centre += mid(s) * len;
        total += len;
    }
    if total <= 0.0 {
        return None;
    }
    centre /= total;
    let radius = segs.iter().map(|s| (mid(s) - centre).length()).sum::<f32>() / segs.len() as f32;
    let bone_centre = bone_origin + axis * axis.dot(centre - bone_origin);
    Some(CapFrame { centre, axis, bone_centre, radius })
}

fn hash(p: Vector3, k: f32) -> f32 {
    let x = (p.x * 127.1 + p.y * 311.7 + p.z * 74.7 + k * 19.19).sin() * 43_758.547;
    x - x.floor()
}

fn perpendicular(n: Vector3) -> Vector3 {
    let helper = if n.x.abs() < 0.9 { Vector3::RIGHT } else { Vector3::UP };
    n.cross(helper).normalized()
}

/// Domed fan over the rim. `outward` = +1 faces the severed side (the body's cap), -1 faces the body
/// (the piece's cap). UV = cap-plane coordinates around the bone centre in texture repeats, UV2 =
/// (bone radius in the same units, 0 at the centre .. 1 at the rim).
///
/// Skin and clothing each get a fan from the same centre. Where clothing covers the skin both fans
/// overlap, so the skin's fan sits a few millimetres deeper and the outer (clothing) fan is the one seen.
pub fn build(segs: &[RimSeg], f: &CapFrame, outward: f32, uv_scale: f32) -> CapGeometry {
    let n = f.axis * outward;
    let u = perpendicular(f.axis);
    let v = f.axis.cross(u);
    let bulge = f.radius * 0.16;
    let bone_r = (f.radius * 0.28).clamp(0.008, 0.018);
    let mut g = CapGeometry::default();

    let has_cloth = segs.iter().any(|s| s.cloth);
    let rim_count = (segs.len() * 2) as f32;
    let all: Vec<(&CapVert, f32)> = segs.iter().flat_map(|s| s.ends.iter()).map(|c| (c, 1.0 / rim_count)).collect();
    let mut centre = blend(&all);
    centre.pos = f.centre;

    let push = |g: &mut CapGeometry, c: &CapVert, t: f32, recess: f32| -> i32 {
        let radial = c.pos - f.centre;
        let dir = if radial.length() > 1e-6 { radial.normalized() } else { Vector3::ZERO };
        let jitter = 0.85 + 0.3 * hash(c.pos, t);
        let pos = c.pos + n * (bulge * (1.0 - t * t) * jitter - recess * (1.0 - t * t * t * t));
        g.verts.push(pos);
        g.normals.push((n + dir * (2.0 * bulge * t / f.radius.max(1e-3))).normalized());
        g.tangents.extend_from_slice(&[u.x, u.y, u.z, outward]);
        let rel = pos - f.bone_centre;
        g.uv.push(Vector2::new(rel.dot(u), rel.dot(v)) / uv_scale);
        g.uv2.push(Vector2::new(bone_r / uv_scale, t));
        let mut bones = c.bones.clone();
        bones.sort_by(|a, b| b.1.total_cmp(&a.1));
        bones.truncate(4);
        let sum: f32 = bones.iter().map(|b| b.1).sum::<f32>().max(1e-6);
        for j in 0..4 {
            let (b, w) = bones.get(j).copied().unwrap_or((0, 0.0));
            g.bones.push(b);
            g.weights.push(w / sum);
        }
        g.custom[0].extend_from_slice(&[pos.x, pos.y, pos.z, 0.0]);
        for (k, chan) in g.custom[1..].iter_mut().enumerate() {
            chan.extend_from_slice(&c.slots[k * 4..k * 4 + 4]);
        }
        (g.verts.len() - 1) as i32
    };

    let c_idx = push(&mut g, &centre, 0.0, 0.0);
    let c_inner = push(&mut g, &centre, 0.0, 0.005);
    for s in segs {
        let recess = if has_cloth && !s.cloth { 0.005 } else { 0.0 };
        // Ring vertices for both rim ends, centre -> rim.
        let rings: Vec<[i32; 2]> = RINGS
            .iter()
            .map(|&t| {
                let mut ends = [0; 2];
                for (e, rim) in s.ends.iter().enumerate() {
                    let mut c = blend(&[(&centre, 1.0 - t), (rim, t)]);
                    c.pos = f.centre + (rim.pos - f.centre) * t;
                    ends[e] = push(&mut g, &c, t, recess);
                }
                ends
            })
            .collect();
        let tri = |g: &mut CapGeometry, a: i32, b: i32, c: i32| {
            let (pa, pb, pc) = (g.verts[a as usize], g.verts[b as usize], g.verts[c as usize]);
            // Godot front faces are clockwise seen from the front: the right-hand normal points away.
            if (pb - pa).cross(pc - pa).dot(n) > 0.0 {
                g.indices.extend_from_slice(&[a, c, b]);
            } else {
                g.indices.extend_from_slice(&[a, b, c]);
            }
        };
        tri(&mut g, if recess > 0.0 { c_inner } else { c_idx }, rings[0][0], rings[0][1]);
        for k in 1..rings.len() {
            let (i, o) = (rings[k - 1], rings[k]);
            tri(&mut g, i[0], o[0], o[1]);
            tri(&mut g, i[0], o[1], i[1]);
        }
    }
    g
}
