//! DI2 mesh-edit splatter passes (recon/RE_DISMEMBER.md): Dismember (2) / DismemberWithDecal (3), BoneBreak (8) /
//! BoneBreakWithDecal (9), the radial wound stamp of 3 / 9, and the clears ClearToValue (64) / ClearSplatter (80).
//! A function-by-function port of `tools/re_dismember/dismember_ref.py`; the tests check it against that script's
//! outputs (`tools/re_dismember/fixtures/dismember_fixtures.json`, written by `make_fixtures.py`).
//!
//! Two layers:
//! - [`ue`] and the placement functions (`bone_topology`, `safe_region_matrix`, `evaluate_candidate`,
//!   `decal_frame_from_rotator`, `place_dismember`) work in UE space as DI2 does: cm, `FMatrix` rows, row vectors
//!   (p' = p · M), f64 (CPU, once per hit).
//! - The per-vertex GPU passes (`classify_triangle`, `break_vertex`, `radial_*`) are f32 and take glam matrices
//!   `M` with `M * p` = DI2's `p · M`. They work in whatever space their matrices map from: [`CutPlacement`] hands
//!   out glTF-space ones, so bind-pose glb positions in metres go straight in, and distances stay in DI2's cm.
//!
//! [`DismemberData`] (`<body>.dismember.json`, from `tools/re_dismember/export_dismember_data.py`) is the glTF-space
//! entry point. Bone indices are glb skin joint indices (JOINTS_0 values); positions are glTF bind pose, metres;
//! UE -> glTF is p (x, z, y) * 0.01, quaternion (x, z, y, -w). DI2 indexes bones section-locally (BoneMap). With
//! global joint indices every test gives the same result, except that the BoneBreak pass is only dispatched on
//! sections whose BoneMap holds the break child (`DismemberData::break_applies`).

use glam::{Mat4, Quat, Vec3};
use serde::Deserialize;

use crate::splatter::{Stamp, ABSOLUTE_DEFORMATION, APPLY_MAX, APPLY_MIN, SUBTRACTIVE};

/// `ESplatterType` bits of the mesh edits (RE_DISMEMBER.md §1.1).
pub const DISMEMBER: u32 = 2;
pub const DISMEMBER_WITH_DECAL: u32 = 3;
pub const SOFT_INFLUENCE_UPDATE: u32 = 4;
pub const BONE_BREAK: u32 = 8;
pub const BONE_BREAK_WITH_DECAL: u32 = 9;
pub const CLEAR_TO_VALUE: u32 = 64;
pub const CLEAR_SPLATTER: u32 = 80;

/// `r.Splatter.SafeRegionMatrixOffset` (cm) and `r.Splatter.SafeRegionMatrixScale` defaults (§5.3).
pub const SAFE_REGION_MATRIX_OFFSET: f64 = 50.0;
pub const SAFE_REGION_MATRIX_SCALE: f64 = 1.333;

/// Branch roots of the bone topology (§4); every other root starts with mask 1.
pub const BRANCH_ROOTS: [(&str, u16); 5] = [("clavicle_l", 2), ("clavicle_r", 4), ("thigh_l", 8), ("thigh_r", 16), ("neck_01", 32)];

/// UE4.27 `FMatrix` helpers: rows, row vectors (p' = p · M), row 3 = translation, `mmul(a, b)` = apply a then b.
pub mod ue {
    pub type M = [[f64; 4]; 4];
    pub type V = [f64; 3];

    pub const IDENTITY: M = [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]];

    /// `FMatrix operator*`: (a*b)[i][j] = sum_k a[i][k] b[k][j].
    pub fn mmul(a: &M, b: &M) -> M {
        let mut o = [[0.0; 4]; 4];
        for i in 0..4 {
            for j in 0..4 {
                let mut s = 0.0;
                for k in 0..4 {
                    s += a[i][k] * b[k][j];
                }
                o[i][j] = s;
            }
        }
        o
    }

    /// FUN_140a0f420 (`FMatrix::Inverse`): identity when rows 0..2 are all ~0, else the full 4x4 inverse
    /// (Gauss-Jordan with partial pivoting, as dismember_ref.py; identity if singular).
    pub fn inverse(m: &M) -> M {
        if (0..3).all(|r| (0..3).all(|c| m[r][c].abs() <= 1e-8)) {
            return IDENTITY;
        }
        let mut a = [[0.0f64; 8]; 4];
        for i in 0..4 {
            a[i][..4].copy_from_slice(&m[i]);
            a[i][4 + i] = 1.0;
        }
        for c in 0..4 {
            let mut p = c;
            for r in c + 1..4 {
                if a[r][c].abs() > a[p][c].abs() {
                    p = r;
                }
            }
            a.swap(c, p);
            let piv = a[c][c];
            if piv.abs() < 1e-30 {
                return IDENTITY;
            }
            for v in a[c].iter_mut() {
                *v /= piv;
            }
            let rc = a[c];
            for (r, row) in a.iter_mut().enumerate() {
                if r != c {
                    let f = row[c];
                    for (vr, vc) in row.iter_mut().zip(rc.iter()) {
                        *vr -= f * vc;
                    }
                }
            }
        }
        let mut o = [[0.0; 4]; 4];
        for i in 0..4 {
            o[i].copy_from_slice(&a[i][4..]);
        }
        o
    }

    pub fn norm(v: V) -> f64 {
        (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt()
    }

    /// `FVector::GetSafeNormal` as inlined in DI2: unchanged if |v|² == 1, zero if |v|² < 1e-8, else v / |v|.
    pub fn safe_normal(v: V) -> V {
        let s = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        if s == 1.0 {
            return v;
        }
        if s < 1e-8 || !s.is_finite() {
            return [0.0; 3];
        }
        let k = 1.0 / s.sqrt();
        [v[0] * k, v[1] * k, v[2] * k]
    }

    /// FUN_140a0e080 `GetUnitAxis`: axis 1 = X (row 0), 2 = Y (row 1), 3 = Z (row 2).
    pub fn unit_axis(m: &M, axis: usize) -> V {
        let r = m[axis - 1];
        safe_normal([r[0], r[1], r[2]])
    }

    pub fn cross(a: V, b: V) -> V {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }

    pub fn dot(a: V, b: V) -> f64 {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }

    /// A direction (w = 0) through m.
    pub fn xform_vec(v: V, m: &M) -> V {
        let mut o = [0.0; 3];
        for (j, oj) in o.iter_mut().enumerate() {
            *oj = v[0] * m[0][j] + v[1] * m[1][j] + v[2] * m[2][j];
        }
        o
    }

    /// A point (w = 1) through m.
    pub fn xform_pos(p: V, m: &M) -> V {
        let mut o = [0.0; 3];
        for (j, oj) in o.iter_mut().enumerate() {
            *oj = p[0] * m[0][j] + p[1] * m[1][j] + p[2] * m[2][j] + m[3][j];
        }
        o
    }

    pub fn row3(m: &M, r: usize) -> V {
        [m[r][0], m[r][1], m[r][2]]
    }

    /// `FRotator::Quaternion` (UE4.27), degrees -> (x, y, z, w).
    pub fn quat_from_rotator(pitch: f64, yaw: f64, roll: f64) -> [f64; 4] {
        let r = std::f64::consts::PI / 180.0 / 2.0;
        let (sp, cp) = ((pitch * r).sin(), (pitch * r).cos());
        let (sy, cy) = ((yaw * r).sin(), (yaw * r).cos());
        let (sr, cr) = ((roll * r).sin(), (roll * r).cos());
        [cr * sp * sy - sr * cp * cy, -cr * sp * cy - sr * cp * sy, cr * cp * sy - sr * sp * cy, cr * cp * cy + sr * sp * sy]
    }

    /// `FTransform::ToMatrixWithScale` (rows scaled by Scale3D).
    pub fn transform_matrix(q: [f64; 4], t: V, s: V) -> M {
        let [x, y, z, w] = q;
        let (x2, y2, z2) = (x + x, y + y, z + z);
        let (xx, xy, xz) = (x * x2, x * y2, x * z2);
        let (yy, yz, zz) = (y * y2, y * z2, z * z2);
        let (wx, wy, wz) = (w * x2, w * y2, w * z2);
        [
            [(1.0 - (yy + zz)) * s[0], (xy + wz) * s[0], (xz - wy) * s[0], 0.0],
            [(xy - wz) * s[1], (1.0 - (xx + zz)) * s[1], (yz + wx) * s[1], 0.0],
            [(xz + wy) * s[2], (yz - wx) * s[2], (1.0 - (xx + yy)) * s[2], 0.0],
            [t[0], t[1], t[2], 1.0],
        ]
    }

    /// `FRotationTranslationMatrix` (rows = X, Y, Z axes).
    pub fn rotation_matrix(pitch: f64, yaw: f64, roll: f64, loc: V) -> M {
        transform_matrix(quat_from_rotator(pitch, yaw, roll), loc, [1.0; 3])
    }
}

use ue::{cross, dot, inverse, mmul, row3, safe_normal, transform_matrix, unit_axis, xform_pos, xform_vec};

// ---------------------------------------------------------------------------------------------------------------
// UE <-> glTF
// ---------------------------------------------------------------------------------------------------------------

/// glTF metres -> UE cm: (x, z, y) * 100.
pub fn ue_pos(p: [f64; 3]) -> ue::V {
    [p[0] * 100.0, p[2] * 100.0, p[1] * 100.0]
}

/// UE cm -> glTF metres: (x, z, y) * 0.01.
pub fn gl_pos(p: ue::V) -> [f64; 3] {
    [p[0] * 0.01, p[2] * 0.01, p[1] * 0.01]
}

/// Directions swap y / z (both ways).
pub fn swap_dir(v: [f64; 3]) -> [f64; 3] {
    [v[0], v[2], v[1]]
}

/// Quaternions: (x, y, z, w) <-> (x, z, y, -w) (self-inverse).
pub fn swap_quat(q: [f64; 4]) -> [f64; 4] {
    [q[0], q[2], q[1], -q[3]]
}

/// A glTF transform (16 floats column-major, column vectors, metres) -> UE rows (cm).
pub fn ue_rows_from_gl(c: &[f64; 16]) -> ue::M {
    const S: [usize; 3] = [0, 2, 1];
    let g = |row: usize, col: usize| c[col * 4 + row];
    let mut m = [[0.0; 4]; 4];
    for i in 0..3 {
        let col = [g(0, S[i]), g(1, S[i]), g(2, S[i])];
        m[i] = [col[0], col[2], col[1], 0.0];
    }
    m[3] = [g(0, 3) * 100.0, g(2, 3) * 100.0, g(1, 3) * 100.0, 1.0];
    m
}

/// glam matrix with `M * (p, 1)` = DI2's `p · rows` (UE rows become glam columns).
pub fn mat4_from_rows(m: &ue::M) -> Mat4 {
    Mat4::from_cols_array_2d(&m.map(|r| r.map(|v| v as f32)))
}

/// `p_gl (m) -> p_ue (cm)` as a row matrix.
const GL_TO_UE: ue::M = [[100.0, 0.0, 0.0, 0.0], [0.0, 0.0, 100.0, 0.0], [0.0, 100.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]];

/// A UE-space matrix applied to glTF metres: glam `C · M` (positions are converted to UE cm first).
pub fn gl_space(m: &ue::M) -> Mat4 {
    mat4_from_rows(&mmul(&GL_TO_UE, m))
}

fn v3(v: [f64; 3]) -> Vec3 {
    Vec3::new(v[0] as f32, v[1] as f32, v[2] as f32)
}

fn d3(v: Vec3) -> [f64; 3] {
    [v.x as f64, v.y as f64, v.z as f64]
}

// ---------------------------------------------------------------------------------------------------------------
// 1. Bone topology (USkeletalMesh PostLoad 0x143ada2d0 -> 0x143adbb30 / 0x143ae13c0; read by 0x143ad3870)
// ---------------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoneTopo {
    /// Depth from the root; frozen below `twist` / `Volume` / `head` bones.
    pub depth: u16,
    /// Branch mask: clavicle_l 2, clavicle_r 4, thigh_l 8, thigh_r 16, neck_01 32, else 1 (inherited).
    pub branch: u16,
    /// `twist` / `Volume` bone.
    pub flag: bool,
    /// First child (bone order) without the flag, or -1: the BoneBreak re-skin target.
    pub break_bone: i32,
}

fn branch_root(name: &str) -> Option<u16> {
    BRANCH_ROOTS.iter().find(|(n, _)| *n == name).map(|&(_, m)| m)
}

/// Per bone (depth, branch, flag, break bone): the recursion of §4. Root depth 0, mask = table or 1; a child gets
/// depth + 1 unless an ancestor (or the parent itself) is a `twist` / `Volume` / `head` bone (`head` stops the
/// increment but does not set the flag; substrings are case-sensitive); the mask is inherited unless the
/// inherited mask is < 2 and the bone is a branch root.
pub fn bone_topology<S: AsRef<str>>(names: &[S], parents: &[i32]) -> Vec<BoneTopo> {
    let n = names.len();
    let mut children = vec![Vec::new(); n];
    for (i, &p) in parents.iter().enumerate() {
        if p >= 0 {
            children[p as usize].push(i);
        }
    }
    let (mut depth, mut mask, mut flag) = (vec![0u16; n], vec![1u16; n], vec![false; n]);
    let has = |i: usize, s: &str| names[i].as_ref().contains(s);
    for r in (0..n).filter(|&i| parents[i] < 0) {
        let m = branch_root(names[r].as_ref()).unwrap_or(1);
        mask[r] = m;
        depth[r] = 0;
        let mut f = false;
        if has(r, "twist") || has(r, "Volume") {
            flag[r] = true;
            f = true;
        }
        if has(r, "head") {
            f = true;
        }
        let mut stack: Vec<(usize, u16, u16, bool)> = children[r].iter().map(|&c| (c, if f { 0 } else { 1 }, m, f)).collect();
        while let Some((i, d, mut m, mut f)) = stack.pop() {
            if m < 2 {
                m = branch_root(names[i].as_ref()).unwrap_or(m);
            }
            mask[i] = m;
            depth[i] = d;
            if has(i, "twist") || has(i, "Volume") {
                flag[i] = true;
                f = true;
            }
            if has(i, "head") {
                f = true;
            }
            for &c in &children[i] {
                stack.push((c, d + if f { 0 } else { 1 }, m, f));
            }
        }
    }
    (0..n)
        .map(|i| BoneTopo {
            depth: depth[i],
            branch: mask[i],
            flag: flag[i],
            break_bone: children[i].iter().find(|&&c| !flag[c]).map_or(-1, |&c| c as i32),
        })
        .collect()
}

// ---------------------------------------------------------------------------------------------------------------
// 2. Safe-region placement (0x140a05050, candidate 0x140a06270, safe region matrix 0x140a05c90), UE space
// ---------------------------------------------------------------------------------------------------------------

/// A region socket in UE space: quaternion, location (cm) and half-extents (cm) relative to its bone.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UeSocket {
    pub quat: [f64; 4],
    pub loc: ue::V,
    pub scale: ue::V,
    pub branch_mask: u16,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Candidate {
    /// Rows [G, N, H, O] in ref space.
    pub frame: ue::M,
    pub safe_region: ue::M,
    pub branch_mask: u16,
    pub score: f64,
    /// Where the plane crosses the socket X axis (cm).
    pub t: f64,
    /// The plane left through an end cap and was tilted to its rim.
    pub corrected: bool,
}

/// 0x140a05c90: SafeRegionMatrix = inverse(P · M), M = the socket matrix WITH scale in ref space.
pub fn safe_region_matrix(scaled_socket_ref: &ue::M, use_cvars: bool) -> ue::M {
    let m = scaled_socket_ref;
    let a = (m[0][0] * m[0][0] + m[0][1] * m[0][1] + m[0][2] * m[0][2]).sqrt().max(1e-5);
    let s = (1.0 / a) * 1000.0;
    let mut p = [[s, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [1.0 - s, 0.0, 0.0, 1.0]];
    if use_cvars {
        p[3][0] = SAFE_REGION_MATRIX_OFFSET * (1.0 / a) + (1.0 - s);
        p[1][1] *= SAFE_REGION_MATRIX_SCALE;
        p[2][2] *= SAFE_REGION_MATRIX_SCALE;
    }
    inverse(&mmul(&p, m))
}

/// 0x140a06270. frame_ref = decal frame in ref space (rows X, Y, Z, origin); ref_bone = composed ref-pose matrix
/// of the socket's bone.
pub fn evaluate_candidate(frame_ref: &ue::M, ref_bone: &ue::M, socket: &UeSocket) -> Candidate {
    let q = socket.quat;
    let [sx, sy, sz] = socket.scale;
    let w_scaled = mmul(&transform_matrix(q, socket.loc, socket.scale), ref_bone);
    let u = mmul(&transform_matrix(q, socket.loc, [1.0; 3]), ref_bone);
    let uinv = inverse(&u);
    let dx = safe_normal(xform_vec(unit_axis(frame_ref, 1), &uinv));
    let n0 = safe_normal(xform_vec(unit_axis(frame_ref, 2), &uinv)); // decal Y in socket space = initial normal
    let dz = safe_normal(xform_vec(unit_axis(frame_ref, 3), &uinv));
    let o = xform_pos(row3(frame_ref, 3), &uinv);
    let (b2, c2) = (sy * sy, sz * sz);
    let (f1, f2) = if sy <= sz {
        let f = (c2 - b2).sqrt();
        ([0.0, 0.0, f], [0.0, 0.0, -f])
    } else {
        let g = (b2 - c2).sqrt();
        ([0.0, g, 0.0], [0.0, -g, 0.0])
    };
    let mut n = n0;
    if n[0].abs() < 0.001 {
        // nudge a plane parallel to the socket X axis
        n[0] += 0.05;
        let l2 = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
        if l2 > 1e-8 {
            let k = 1.0 / l2.sqrt();
            n = [n[0] * k, n[1] * k, n[2] * k];
        }
    }
    let mut t = dot(o, n) / n[0]; // the plane meets the socket X axis at (t, 0, 0)
    if t.abs() > sx * 0.95 {
        t = if t != 0.0 { 1f64.copysign(t) * sx * 0.95 } else { 0.0 };
    }
    let (mut nn, mut g_axis, mut h_axis) = (n, dx, dz);
    let r = (n[2] * n[2] + n[1] * n[1]).sqrt();
    let mut corrected = false;
    if r > 1e-8 {
        let (ey, ez) = (n[2] / r, -n[1] / r);
        let mut w = [ey * n[2] - ez * n[1], ez * n[0], -(ey * n[0])]; // socket X projected into the plane
        let l2 = w[0] * w[0] + w[1] * w[1] + w[2] * w[2];
        if l2 > 1e-8 {
            let k = 1.0 / l2.sqrt();
            w = [w[0] * k, w[1] * k, w[2] * k];
        }
        let e = if t > 0.5 { [sx, 0.0, 0.0] } else { [-sx, 0.0, 0.0] };
        let s = (e[0] - t) / w[0];
        let (qz, qy) = (w[2] * s, w[1] * s);
        let (ib2, ic2) = (1.0 / b2, 1.0 / c2);
        let bq = (qz + qz) * ez * ic2 + (qy + qy) * ey * ib2;
        let disc = bq * bq - ((qz * qz * ic2 + qy * qy * ib2) - 1.0) * (ez * ez * ic2 + ey * ey * ib2) * 4.0;
        if disc > 0.0 {
            // the plane leaves through the end-cap ellipse: tilt it
            corrected = true;
            let mut v = safe_normal([(t + w[0] * s) - e[0], qy - e[1], qz - e[2]]);
            let kk = (v[2] * v[2] * ic2 + v[1] * v[1] * ib2).sqrt().max(0.0001);
            v = [v[0] / kk, v[1] / kk, v[2] / kk];
            let prim = [v[0] + e[0], v[1] + e[1], v[2] + e[2]]; // point on the end-cap ellipse rim
            let d1 = safe_normal([f1[0] - v[0], f1[1] - v[1], f1[2] - v[2]]);
            let d2 = safe_normal([f2[0] - v[0], f2[1] - v[1], f2[2] - v[2]]);
            let my = (d2[1] + d1[1]) * -0.5;
            let mz = (d2[2] + d1[2]) * 0.5;
            nn = safe_normal([my * prim[1] - prim[2] * mz, -(my * (prim[0] - t)), mz * (prim[0] - t)]);
            g_axis = safe_normal([mz * nn[2] - my * nn[1], my * nn[0], (d2[2] + d1[2]) * -0.5 * nn[0]]);
            h_axis = safe_normal([
                g_axis[2] * nn[1] - g_axis[1] * nn[2],
                g_axis[0] * nn[2] - g_axis[2] * nn[0],
                g_axis[1] * nn[0] - g_axis[0] * nn[1],
            ]);
        }
    }
    let sgn = if nn[0] >= 0.0 { -1.0 } else { 1.0 }; // the final normal points to socket -X
    nn = [nn[0] * sgn, nn[1] * sgn, nn[2] * sgn];
    let pen = (1.0 - (dot(o, n0) - t * n0[0]).abs() * 0.2).max(0.0).min(1.0);
    let align = dot(nn, n0).abs().min(1.0);
    let score = align * align * align * align * 0.6666667 + pen * 0.33333334;
    let gx = xform_vec(g_axis, &u);
    let nx = xform_vec(nn, &u);
    let hx = xform_vec(h_axis, &u);
    let frame = [
        [gx[0], gx[1], gx[2], 0.0],
        [nx[0], nx[1], nx[2], 0.0],
        [hx[0], hx[1], hx[2], 0.0],
        [u[3][0] + t * u[0][0], u[3][1] + t * u[0][1], u[3][2] + t * u[0][2], 1.0],
    ];
    Candidate { frame, safe_region: safe_region_matrix(&w_scaled, socket.branch_mask > 0), branch_mask: socket.branch_mask, score, t, corrected }
}

/// SplatterDecal 0x140a161a0: frame rows = (R.Y, -R.Z, -R.X, location) from the hit rotator (degrees).
pub fn decal_frame_from_rotator(loc: ue::V, pitch: f64, yaw: f64, roll: f64) -> ue::M {
    let r = ue::rotation_matrix(pitch, yaw, roll, [0.0; 3]);
    let (x, z) = (unit_axis(&r, 1), safe_normal(row3(&r, 2)));
    let yy = cross([-z[0], -z[1], -z[2]], [-x[0], -x[1], -x[2]]);
    [[yy[0], yy[1], yy[2], 0.0], [-z[0], -z[1], -z[2], 0.0], [-x[0], -x[1], -x[2], 0.0], [loc[0], loc[1], loc[2], 1.0]]
}

/// The second pending decal of a mesh edit (0x140a05050), UE space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UePlacement {
    /// +0x80 / +0xC0: cut frame in ref space, rigid; rows [X, N, Z, O], N = cut normal (limb side).
    pub frame: ue::M,
    /// c_DecalMatrix of GeometryIndicesCS / BreakCS = inverse(frame): decal y = signed distance (cm).
    pub decal_matrix: ue::M,
    /// +0x100 (c_BoneMatrix: compiled out of the shipping shaders).
    pub bone_matrix: ue::M,
    /// +0x140, +0x180, +0x1C0.
    pub bone_now: ue::M,
    pub ref_bone: ue::M,
    pub world_to_ref: ue::M,
    /// +0x280.
    pub safe_region: ue::M,
    /// +0x2D8.
    pub region_branch_mask: u16,
    pub score: f64,
    pub t: f64,
    pub corrected: bool,
}

/// 0x140a05050. bone_now = GetBoneMatrix of the hit bone (world), ref_bone = its composed ref-pose matrix;
/// sockets = '<bone>_safe_region', '_1', '_2' … (Dismember) or '<bone>_break_region' … (BoneBreak).
/// None when there is no region socket (no edit).
pub fn place_dismember(decal_frame_world: &ue::M, bone_now: &ue::M, ref_bone: &ue::M, sockets: &[UeSocket], reference_pose: bool) -> Option<UePlacement> {
    let cur = if reference_pose { ref_bone } else { bone_now };
    let t_w2r = mmul(&inverse(cur), ref_bone); // +0x1c0: world -> ref-pose space via the hit bone
    let frame_ref = mmul(decal_frame_world, &t_w2r);
    let mut best: Option<Candidate> = None;
    let mut best_score = -1.0;
    for s in sockets {
        let c = evaluate_candidate(&frame_ref, ref_bone, s);
        if best_score < c.score {
            best_score = c.score;
            best = Some(c);
        }
    }
    let best = best?;
    let n = safe_normal(row3(&best.frame, 1));
    let by = row3(ref_bone, 1); // unnormalised ref bone Y
    let z = safe_normal(cross(by, row3(&best.frame, 1)));
    let x = safe_normal(cross(row3(&best.frame, 1), z));
    let nrm = row3(&best.frame, 1);
    let o = row3(&best.frame, 3);
    let frame = [[x[0], x[1], x[2], 0.0], [nrm[0], nrm[1], nrm[2], 0.0], [z[0], z[1], z[2], 0.0], [o[0], o[1], o[2], 1.0]];
    let (mut bx, mut byn) = (unit_axis(ref_bone, 1), safe_normal(by));
    if dot(bx, n) < 0.0 {
        bx = bx.map(|v| -v);
        byn = byn.map(|v| -v);
    }
    let bone_matrix = [[byn[0], byn[1], byn[2], 0.0], [bx[0], bx[1], bx[2], 0.0], ref_bone[2], ref_bone[3]];
    Some(UePlacement {
        frame,
        decal_matrix: inverse(&frame),
        bone_matrix,
        bone_now: *cur,
        ref_bone: *ref_bone,
        world_to_ref: t_w2r,
        safe_region: best.safe_region,
        region_branch_mask: best.branch_mask,
        score: best.score,
        t: best.t,
        corrected: best.corrected,
    })
}

// ---------------------------------------------------------------------------------------------------------------
// 3. GPU: FSplatterGeometryIndicesCS_FourBone (Global 939) and FSplatterBreakCS (Global 904), f32
// ---------------------------------------------------------------------------------------------------------------

/// `c_TargetBoneData` (int4), with global bone indices.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TargetBone {
    /// x: the hit (region) bone, or -1.
    pub bone: i32,
    /// y: its depth.
    pub depth: u16,
    /// z: its branch | the chosen region socket's BoneBranchMask.
    pub branch: u16,
    /// w: the break child (BoneBreak), else 0.
    pub break_bone: i32,
}

/// One skinned vertex: bind-pose position and its first 4 influences (DI2 reads the first 4, 8-bit weights).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SkinVert {
    pub pos: Vec3,
    pub bones: [u16; 4],
    pub weights: [f32; 4],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriClass {
    /// Code 3: kept by the body (front of the section's index range).
    Body,
    /// Code 0: drawn by the limb (packed at the end of the range).
    Limb,
    /// Codes 1 / 2: straddles the cut inside the safe region or at the target bone; removed from both.
    Drop,
}

/// `dot(p, DM col y) + DM[3].y`: signed distance from the cut plane (DI2 cm), + on the limb side.
pub fn plane_d(p: Vec3, decal_matrix: &Mat4) -> f32 {
    (*decal_matrix * p.extend(1.0)).y
}

/// `|SR · p| < 1` on all three axes.
pub fn in_safe_region(p: Vec3, safe_region: &Mat4) -> bool {
    let q = *safe_region * p.extend(1.0);
    q.x.abs() < 1.0 && q.y.abs() < 1.0 && q.z.abs() < 1.0
}

/// GeometryIndicesCS per triangle: 3 = body, 0 = limb, 1 / 2 = dropped. `topo` is indexed by the vertices' bone
/// indices; `binary` = the section is in BinaryDismemberMask.
pub fn classify_code(verts: &[SkinVert; 3], decal_matrix: &Mat4, safe_region: &Mat4, target: &TargetBone, topo: &[BoneTopo], binary: bool) -> u32 {
    let (t1, t2, fill): (f32, f32, u16) = if binary { (0.0, 0.0, 0) } else { (0.1, 0.24, 255) };
    let (tx, ty, tz) = (target.bone, target.depth, target.branch);
    let inside_sr = verts.iter().all(|v| in_safe_region(v.pos, safe_region)) && tz != 0 && !binary;
    let mut in_branch = true;
    let (mut any_primary_target, mut any_target, mut deeper) = (false, false, false);
    for v in verts {
        let hit = |j: usize| ((if v.weights[j] > t2 { topo[v.bones[j] as usize].branch } else { fill }) & tz) != 0;
        in_branch = in_branch && if binary { (0..4).any(hit) } else { (0..4).all(hit) };
        let tgt = |j: usize| v.weights[j] > t1 && v.bones[j] as i32 == tx;
        any_primary_target |= tgt(0);
        any_target |= (0..4).any(tgt);
        deeper |= (0..4).any(|j| ty < if v.weights[j] > t1 { topo[v.bones[j] as usize].depth } else { 0 }); // unsigned
    }
    let candidate = inside_sr || in_branch;
    let touch = if (!candidate && !any_primary_target) || tx == -1 { false } else { any_target };
    let sr_or_target = inside_sr || touch;
    let limb_tri = candidate && deeper && !sr_or_target;
    if sr_or_target {
        if binary {
            0
        } else {
            verts.iter().filter(|v| plane_d(v.pos, decal_matrix) < 0.0).count() as u32
        }
    } else if limb_tri {
        0
    } else {
        3
    }
}

/// `classify_code` as body / limb / drop.
pub fn classify_triangle(verts: &[SkinVert; 3], decal_matrix: &Mat4, safe_region: &Mat4, target: &TargetBone, topo: &[BoneTopo], binary: bool) -> TriClass {
    match classify_code(verts, decal_matrix, safe_region, target, topo, binary) {
        3 => TriClass::Body,
        0 => TriClass::Limb,
        _ => TriClass::Drop,
    }
}

/// `classify_triangle` for every triangle of one section (positions / skin per vertex, any consistent order;
/// `indices` index into them). One class per triangle, in index order.
#[allow(clippy::too_many_arguments)]
pub fn classify_section(pos: &[Vec3], bones: &[[u16; 4]], weights: &[[f32; 4]], indices: &[u32], decal_matrix: &Mat4, safe_region: &Mat4, target: &TargetBone, topo: &[BoneTopo], binary: bool) -> Vec<TriClass> {
    let vert = |i: u32| SkinVert { pos: pos[i as usize], bones: bones[i as usize], weights: weights[i as usize] };
    indices
        .chunks_exact(3)
        .map(|t| classify_triangle(&[vert(t[0]), vert(t[1]), vert(t[2])], decal_matrix, safe_region, target, topo, binary))
        .collect()
}

/// Splits a section's index list by `classify_section`'s result: (body triangles, limb triangles), each in the
/// original order. Dropped triangles are in neither.
pub fn split_indices(indices: &[u32], classes: &[TriClass]) -> (Vec<u32>, Vec<u32>) {
    let (mut body, mut limb) = (Vec::new(), Vec::new());
    for (t, c) in indices.chunks_exact(3).zip(classes) {
        match c {
            TriClass::Body => body.extend_from_slice(t),
            TriClass::Limb => limb.extend_from_slice(t),
            TriClass::Drop => {}
        }
    }
    (body, limb)
}

/// BreakCS per vertex (once per vertex per pass): the new (bones, weights), or None (unchanged). Influence 3
/// becomes the break child with weight sat(d / 10 cm); influences no deeper than the broken bone fade by the same
/// ramp; the total is kept and the weights are quantised to 8 bits. None also when there is no break child (the
/// CPU does not dispatch the pass then).
pub fn break_vertex(v: &SkinVert, decal_matrix: &Mat4, target: &TargetBone, topo: &[BoneTopo], binary: bool) -> Option<([u16; 4], [f32; 4])> {
    if target.break_bone < 0 {
        return None;
    }
    let (t_hit, t_br, fill): (f32, f32, u16) = if binary { (0.0, 0.0, 0) } else { (0.1, 0.24, 255) };
    let (tx, ty, tz, tw) = (target.bone, target.depth, target.branch, target.break_bone);
    let (b, w) = (v.bones, v.weights);
    let d = plane_d(v.pos, decal_matrix);
    let hit = |j: usize| ((if w[j] > t_br { topo[b[j] as usize].branch } else { fill }) & tz) != 0;
    let affected = if binary { (0..4).any(hit) } else { (0..4).all(hit) };
    if !(affected && d >= 0.0) {
        return None;
    }
    let sig = |j: usize| w[j] > t_hit;
    let on_target = (0..4).any(|j| sig(j) && b[j] as i32 == tx) && tx != -1;
    let dep: [u16; 4] = std::array::from_fn(|j| if sig(j) { topo[b[j] as usize].depth } else { 0 });
    let same_depth = dep.iter().any(|&dv| dv == ty);
    if !(on_target || same_depth) {
        return None;
    }
    let ramp = (d * 0.1).clamp(0.0, 1.0); // 10 cm ramp beyond the break plane
    let total = w[0] + w[1] + w[2] + w[3];
    let red: [f32; 3] = std::array::from_fn(|k| ramp * if ty >= dep[k] { 1.0 } else { 0.0 });
    let mut nw = [w[0] * (1.0 - red[0]), w[1] * (1.0 - red[1]), w[2] * (1.0 - red[2]), ramp];
    let s = nw[0] + nw[1] + nw[2] + nw[3];
    if s != 0.0 {
        nw = nw.map(|x| x * (total / s));
    }
    let nw = nw.map(|x| (x.min(1.0) * 255.0).floor() / 255.0); // ftou(min(w, 1) * 255)
    Some(([b[0], b[1], b[2], tw as u16], nw))
}

/// `break_vertex` for every vertex of one section, in the given order.
pub fn break_section(pos: &[Vec3], bones: &[[u16; 4]], weights: &[[f32; 4]], decal_matrix: &Mat4, target: &TargetBone, topo: &[BoneTopo], binary: bool) -> Vec<Option<([u16; 4], [f32; 4])>> {
    (0..pos.len())
        .map(|i| break_vertex(&SkinVert { pos: pos[i], bones: bones[i], weights: weights[i] }, decal_matrix, target, topo, binary))
        .collect()
}

// ---------------------------------------------------------------------------------------------------------------
// 3a. Radial wound stamp of DismemberWithDecal / BoneBreakWithDecal (§8): FSplatterPS_OneElement_Radial
//     (DeadIsland 1943) and FSplatterDeformMeshCS p82 (Global 926, RADIAL + REFERENCE_POSE)
// ---------------------------------------------------------------------------------------------------------------

/// DecalMatrix of the radial stamp: inverse(cut frame with rows 0, 1 scaled by UVScale / 2).
pub fn radial_decal_matrix(cut_frame: &ue::M, uv_scale: f64) -> ue::M {
    let mut m = *cut_frame;
    for r in 0..2 {
        for c in 0..3 {
            m[r][c] *= uv_scale * 0.5;
        }
    }
    inverse(&m)
}

/// The part both radial shaders share: (w, (u, v)). y = axial coordinate (±1 at ±UVScale/2 cm from the cut),
/// (s.y, s.z) = safe-region cross-section, r = |(s.y, s.z)|: w = (|y| < 1)·(1 - sat(4(r - 1))),
/// uv = sat((s.z / r, y)·0.5 + 0.5). At r == 0 the shaders get 0·inf = NaN and saturate(NaN) = 0, so u = 0.
pub fn radial_coords(p: Vec3, radial_dm: &Mat4, safe_region: &Mat4) -> (f32, [f32; 2]) {
    let y = plane_d(p, radial_dm);
    let s = *safe_region * p.extend(1.0);
    let r = (s.y * s.y + s.z * s.z).sqrt();
    let w = (if y.abs() < 1.0 { 1.0 } else { 0.0 }) * (1.0 - (4.0 * (r - 1.0)).clamp(0.0, 1.0));
    let u = if r > 0.0 { ((s.z / r) * 0.5 + 0.5).clamp(0.0, 1.0) } else { 0.0 };
    (w, [u, (y * 0.5 + 0.5).clamp(0.0, 1.0)])
}

/// One splatter element's constants as the radial shaders read them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RadialElement {
    /// ScaleVec: y = DisplacementScale (the CS amplitude); z < 0 = ApplyMin, w < 0 = ApplyMax (only the signs of
    /// z / w are read by the radial shaders).
    pub scale_vec: [f32; 4],
    /// WoundScale: xyz scale the displacement texture's RGB; w > 0 multiplies wound R by 3 / DEFORM0.
    pub wound_scale: [f32; 4],
    /// FXScale: scales the diffuse texture's RGBA.
    pub fx_scale: [f32; 4],
    /// RangeParams (InputMinimum, InputRange).
    pub range: [f32; 2],
    /// DeformParams: y = signed multiplier (min mode: y < 0 selects 1 - v). x is not read by p82.
    pub deform_params: [f32; 2],
}

impl RadialElement {
    /// The constants for a `splatter::Stamp`, with the same mapping `Stamp::deform_vertex` / `SplatterRt::apply`
    /// use: APPLY_MIN / APPLY_MAX -> ScaleVec.z / w < 0, ABSOLUTE_DEFORMATION -> WoundScale.w = 1,
    /// SUBTRACTIVE -> DeformParams.y = -1, cloth sections scale wound R and the CS amplitude by cloth_displacement.
    /// The CLOTH_ONLY / CLOTH_NEVER filters stay with the caller.
    pub fn from_stamp(s: &Stamp, cloth: bool) -> RadialElement {
        let cd = if cloth { s.cloth_displacement } else { 1.0 };
        let sign = |b: u32| if s.flags & b != 0 { -1.0 } else { 1.0 };
        let abs = if s.flags & ABSOLUTE_DEFORMATION != 0 { 1.0 } else { 0.0 };
        RadialElement {
            scale_vec: [s.fade_gain, s.displacement * cd, sign(APPLY_MIN), sign(APPLY_MAX)],
            wound_scale: [s.wound[0] * cd, s.wound[1], s.wound[2], abs],
            fx_scale: s.fx,
            range: s.range,
            deform_params: [abs, sign(SUBTRACTIVE)],
        }
    }
}

/// FSplatterPS_OneElement_Radial (DeadIsland 1943) for one texel whose bind-pose position is `p`: (SV_Target0 =
/// diffuse RT, SV_Target1 = displacement RT incl. coverage alpha), or None where w == 0 (the PS writes 0 to both:
/// no change, no coverage). `deform_len_cm` = |Deform.xyz| of the texel's vertex (the VS passes
/// DEFORM0 = max(1, len)); `sample_dif` / `sample_disp`(u, v) = the stamp textures' RGBA (bilinear). The result
/// is blended into the targets as any element (ADD, or MAX for ApplyMax).
pub fn radial_texel(p: Vec3, radial_dm: &Mat4, safe_region: &Mat4, e: &RadialElement, deform_len_cm: f32, sample_dif: &dyn Fn(f32, f32) -> [f32; 4], sample_disp: &dyn Fn(f32, f32) -> [f32; 4]) -> Option<([f32; 4], [f32; 4])> {
    let (w, [u, v]) = radial_coords(p, radial_dm, safe_region);
    if w == 0.0 {
        return None;
    }
    let (t0, t1) = (sample_dif(u, v), sample_disp(u, v));
    let rg = e.range;
    let d: [f32; 4] = std::array::from_fn(|c| e.fx_scale[c] * ((t0[c] - rg[0]) / rg[1]) * w);
    let mut wd = [0.0f32, 0.0, 0.0, 1.0];
    for c in 0..3 {
        wd[c] = e.wound_scale[c] * ((t1[c] - rg[0]) / rg[1]) * w;
    }
    if e.wound_scale[3] > 0.0 {
        wd[0] *= 3.0 / deform_len_cm.max(1.0);
    }
    let (mut o0, mut o1) = (d, wd);
    if e.scale_vec[2] < 0.0 {
        o0 = d.map(|x| x.min(0.0));
        o1 = wd.map(|x| x.min(0.0));
    }
    if e.scale_vec[3] < 0.0 {
        o0 = d.map(|x| x.max(0.0));
        o1 = wd.map(|x| x.max(0.0));
    }
    Some((o0, o1))
}

/// FSplatterDeformMeshCS p82 (Global 926) for one vertex: the new Deform.w (DI2 stores it as f16, see
/// `f16_round`). `disp_r_point(u, v)` = the displacement texture's R loaded at texel (uint)(uv · size), mip 0
/// (D3D returns 0 outside). No deform normalisation (DeformParams.x is not read).
pub fn radial_vertex_depth(p: Vec3, radial_dm: &Mat4, safe_region: &Mat4, e: &RadialElement, depth: f32, disp_r_point: &dyn Fn(f32, f32) -> f32) -> f32 {
    let (w, [u, v]) = radial_coords(p, radial_dm, safe_region);
    let val = ((disp_r_point(u, v) - e.range[0]) / e.range[1]) * e.scale_vec[1];
    let vw = val * w;
    let mn = if e.deform_params[1] < 0.0 { 1.0 - vw } else { vw };
    let val = if e.scale_vec[2] < 0.0 { mn } else { e.deform_params[1] * vw };
    let s = val * 1.111_111_2;
    if e.scale_vec[3] < 0.0 {
        s.max(depth).clamp(0.0, 1.0)
    } else if e.scale_vec[2] < 0.0 {
        s.min(depth).clamp(0.0, 1.0)
    } else {
        (val * 1.111_111_2 + depth).clamp(0.0, 1.0)
    }
}

// ---------------------------------------------------------------------------------------------------------------
// 3b. Clears (RT: 0x140a12a40 + FSplatterClearPS Global 1877; vertex: FSplatterDeformMeshCS p83 Global 885)
// ---------------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClearKind {
    /// ClearToValue (64): both RTs and the vertex depth = DisplacementClearValue.
    ToValue,
    /// ClearSplatter / ClearAll (80): both RTs MIN-blended to 0.
    ToZero,
}

/// The clear flag is `t & 0x50`; bit 0x10 selects the MIN-to-0 clear. Literal: ApplyMin (16) / MinDecal (17) land
/// here too (no asset uses them).
pub fn clear_kind(splatter_type: u32) -> Option<ClearKind> {
    if splatter_type & 0x50 == 0 {
        None
    } else if splatter_type & 0x10 != 0 {
        Some(ClearKind::ToZero)
    } else {
        Some(ClearKind::ToValue)
    }
}

/// One texel of both splatter RTs (current RGBA, 0..1) after the clear pass, for a section in WriteSplatterMask.
/// FSplatterClearPS draws `saturate(1 - c_ClearMask)` over the whole UV rect:
/// - not ClothingProxy, ClearToValue: mask = 1 - DisplacementClearValue, replace blend -> both RTs = the value;
/// - not ClothingProxy, ClearSplatter: mask = 1, MIN blend -> both RTs = 0;
/// - ClothingProxy (either): mask = 1, MIN blend with write mask R|A on the displacement RT only.
pub fn clear_rt_texel(splatter_type: u32, clothing_proxy: bool, clear_value: f32, disp: [f32; 4], dif: [f32; 4]) -> ([f32; 4], [f32; 4]) {
    let Some(kind) = clear_kind(splatter_type) else {
        return (disp, dif);
    };
    if clothing_proxy {
        let o = (1.0f32 - 1.0).clamp(0.0, 1.0);
        return ([disp[0].min(o), disp[1], disp[2], disp[3].min(o)], dif);
    }
    match kind {
        ClearKind::ToZero => {
            let o = (1.0f32 - 1.0).clamp(0.0, 1.0);
            (disp.map(|c| c.min(o)), dif.map(|c| c.min(o)))
        }
        ClearKind::ToValue => {
            let o = (1.0 - (1.0 - clear_value)).clamp(0.0, 1.0);
            ([o; 4], [o; 4])
        }
    }
}

/// p83: Deform.w = f16(c_ClearValueArray[0].x) for every vertex of the section (DeformationMask); Deform.z kept.
pub fn clear_vertex_depth(clear_value: f32) -> f32 {
    f16_round(clear_value)
}

/// `f32tof16` (round to nearest even) and back: what DI2's half-float deform buffer stores.
pub fn f16_round(x: f32) -> f32 {
    f16_to_f32(f32_to_f16(x))
}

fn f32_to_f16(x: f32) -> u16 {
    let b = x.to_bits();
    let sign = ((b >> 16) & 0x8000) as u16;
    let exp = ((b >> 23) & 0xff) as i32;
    let man = b & 0x007f_ffff;
    if exp == 0xff {
        return sign | 0x7c00 | if man != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1f {
        return sign | 0x7c00;
    }
    if e <= 0 {
        // half subnormal (or zero): mantissa with the implicit bit, in units of 2^-24
        let shift = (14 - e) as u32;
        if shift >= 25 {
            return sign;
        }
        let m = man | 0x0080_0000;
        let mut h = m >> shift;
        let rem = m & ((1 << shift) - 1);
        let half = 1 << (shift - 1);
        if rem > half || (rem == half && h & 1 != 0) {
            h += 1;
        }
        return sign | h as u16;
    }
    let mut h = sign as u32 | ((e as u32) << 10) | (man >> 13);
    let rem = man & 0x1fff;
    if rem > 0x1000 || (rem == 0x1000 && h & 1 != 0) {
        h += 1; // a carry into the exponent is the correct rounding (up to inf)
    }
    h as u16
}

fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h & 0x8000) as u32) << 16;
    let exp = ((h >> 10) & 0x1f) as u32;
    let man = (h & 0x3ff) as u32;
    if exp == 0 {
        let v = man as f32 * (1.0 / 16_777_216.0);
        return if sign != 0 { -v } else { v };
    }
    if exp == 0x1f {
        return f32::from_bits(sign | 0x7f80_0000 | (man << 13));
    }
    f32::from_bits(sign | ((exp + 112) << 23) | (man << 13))
}

// ---------------------------------------------------------------------------------------------------------------
// 4. Body data (glTF space) and the placement entry point
// ---------------------------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegionKind {
    /// `<bone>_safe_region[_N]`: Dismember (2 / 3).
    Safe,
    /// `<bone>_break_region[_N]`: BoneBreak (8 / 9).
    Break,
}

impl RegionKind {
    /// The region kind a splatter type places with (Dismember wins if both bits are set), or None.
    pub fn for_type(splatter_type: u32) -> Option<RegionKind> {
        if splatter_type & DISMEMBER != 0 {
            Some(RegionKind::Safe)
        } else if splatter_type & BONE_BREAK != 0 {
            Some(RegionKind::Break)
        } else {
            None
        }
    }
}

/// A region socket in glTF space (relative to its bone's bind frame; the y / z swap makes its glTF local Y the UE
/// local Z, so `scale` = (sx, sz, sy) half-extents in metres).
#[derive(Debug, Clone, PartialEq)]
pub struct RegionSocket {
    pub name: String,
    pub bone: usize,
    pub kind: RegionKind,
    /// 0 for `<bone>_<kind>_region`, N for `…_region_N`.
    pub index: u32,
    pub loc: Vec3,
    pub quat: Quat,
    pub scale: Vec3,
    pub branch_mask: u16,
    /// The same socket in UE space (from the JSON's glTF values, f64).
    pub ue: UeSocket,
}

/// One glb primitive = one LOD0 render section, with its material slot's mask bits (UDIEngineMaterialMasks, §3).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Section {
    pub primitive: usize,
    pub material_slot: usize,
    pub material: String,
    pub vertices: usize,
    /// Joints with weight > 0 in this primitive: stands in for the section's BoneMap (not in the extracted JSON).
    pub bones: Vec<u16>,
    pub dismember: bool,
    pub binary_dismember: bool,
    pub skeleton_viscera: bool,
    pub hide: bool,
    pub initially_hidden: bool,
    pub write_splatter: bool,
    pub clothing_proxy: bool,
    pub deformation: bool,
    pub soft_body_deformation: bool,
    pub clothing: bool,
}

/// A placed cut in glTF bind pose, plus the UE-space original.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CutPlacement {
    pub bone: usize,
    pub kind: RegionKind,
    /// Cut-frame origin (metres) and axes; `normal` points to the limb side (decal y > 0).
    pub origin: Vec3,
    pub normal: Vec3,
    pub x_axis: Vec3,
    pub z_axis: Vec3,
    /// glTF metres -> DI2 decal space: `.y` = signed distance from the cut plane in cm (`plane_d`).
    pub decal_matrix: Mat4,
    /// glTF metres -> safe-region space (inside: all |c| < 1, `in_safe_region`).
    pub safe_region: Mat4,
    pub region_branch_mask: u16,
    pub score: f32,
    /// Where the plane crosses the region socket's X axis, cm.
    pub t_cm: f32,
    pub corrected: bool,
    pub ue: UePlacement,
}

impl CutPlacement {
    /// The radial stamp's DecalMatrix in glTF space (`radial_coords`); UVScale in cm (Dismember_AI 45,
    /// Decapitate 22, MajorCut 50).
    pub fn radial_decal_matrix(&self, uv_scale_cm: f32) -> Mat4 {
        gl_space(&radial_decal_matrix(&self.ue.frame, uv_scale_cm as f64))
    }
}

/// DI2's SplatterDecal frame: rows [decal X, decal Y, decal Z, origin] = [R.Y, -R.Z, -R.X, hit location] for the
/// hit rotator R. Decal Y is the initial cut normal (§5.2); only it and the origin steer the placement.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DecalFrame {
    pub x: Vec3,
    pub y: Vec3,
    pub z: Vec3,
    pub origin: Vec3,
}

impl DecalFrame {
    /// From a `splatter::Stamp` (decal X = ay, decal Y = az, decal Z = -ax).
    pub fn from_stamp(s: &Stamp) -> DecalFrame {
        DecalFrame { x: s.ay, y: s.az, z: -s.ax, origin: s.origin }
    }

    fn rows(&self) -> [[f64; 3]; 4] {
        [d3(self.x), d3(self.y), d3(self.z), d3(self.origin)]
    }
}

#[derive(Deserialize)]
struct RawBones {
    names: Vec<String>,
    parents: Vec<i32>,
}

#[derive(Deserialize)]
struct RawSocket {
    name: String,
    bone: usize,
    kind: String,
    index: u32,
    loc: [f64; 3],
    quat: [f64; 4],
    scale: [f64; 3],
    branch_mask: u16,
}

#[derive(Deserialize)]
struct RawData {
    body: String,
    bones: RawBones,
    ref_pose: Vec<[f64; 16]>,
    sockets: Vec<RawSocket>,
    sections: Vec<Section>,
}

/// Per-body load-time data (`<body>.dismember.json`).
#[derive(Debug, Clone)]
pub struct DismemberData {
    pub body: String,
    /// glb skin joints: names, parents (-1 = root), and the topology computed from them.
    pub names: Vec<String>,
    pub parents: Vec<i32>,
    pub topo: Vec<BoneTopo>,
    /// Joint bind (ref-pose, component-space) transforms: glTF, column-major, column vectors.
    pub ref_pose: Vec<[f64; 16]>,
    pub sockets: Vec<RegionSocket>,
    pub sections: Vec<Section>,
}

impl DismemberData {
    pub fn from_json(text: &str) -> Result<DismemberData, String> {
        let raw: RawData = serde_json::from_str(text).map_err(|e| e.to_string())?;
        let n = raw.bones.names.len();
        if raw.bones.parents.len() != n || raw.ref_pose.len() != n {
            return Err(format!("bone arrays disagree: {} names, {} parents, {} ref poses", n, raw.bones.parents.len(), raw.ref_pose.len()));
        }
        let mut sockets = Vec::with_capacity(raw.sockets.len());
        for s in raw.sockets {
            let kind = match s.kind.as_str() {
                "safe" => RegionKind::Safe,
                "break" => RegionKind::Break,
                k => return Err(format!("socket {}: unknown kind {k}", s.name)),
            };
            if s.bone >= n {
                return Err(format!("socket {}: bone {} out of range", s.name, s.bone));
            }
            let ue = UeSocket { quat: swap_quat(s.quat), loc: ue_pos(s.loc), scale: [s.scale[0] * 100.0, s.scale[2] * 100.0, s.scale[1] * 100.0], branch_mask: s.branch_mask };
            sockets.push(RegionSocket {
                name: s.name,
                bone: s.bone,
                kind,
                index: s.index,
                loc: v3(s.loc),
                quat: Quat::from_xyzw(s.quat[0] as f32, s.quat[1] as f32, s.quat[2] as f32, s.quat[3] as f32),
                scale: v3(s.scale),
                branch_mask: s.branch_mask,
                ue,
            });
        }
        let topo = bone_topology(&raw.bones.names, &raw.bones.parents);
        Ok(DismemberData { body: raw.body, names: raw.bones.names, parents: raw.bones.parents, topo, ref_pose: raw.ref_pose, sockets, sections: raw.sections })
    }

    pub fn bone(&self, name: &str) -> Option<usize> {
        self.names.iter().position(|n| n == name)
    }

    /// The joint's bind transform (glTF, metres).
    pub fn ref_pose(&self, bone: usize) -> Mat4 {
        Mat4::from_cols_array(&self.ref_pose[bone].map(|v| v as f32))
    }

    /// `<bone>_<kind>_region`, then `_1`, `_2` … until one is missing (0x140a0bd10); empty without the first.
    pub fn region_sockets(&self, bone: usize, kind: RegionKind) -> Vec<&RegionSocket> {
        let mut out = Vec::new();
        for i in 0.. {
            match self.sockets.iter().find(|s| s.bone == bone && s.kind == kind && s.index == i) {
                Some(s) => out.push(s),
                None => break,
            }
        }
        out
    }

    /// The bone a hit on `hit_bone` edits: it and then its parents, the first with a region socket of `kind`
    /// (0x14129a8e0, check 0x140a10220 -> 0x140a0bd10). None: the hit cannot dismember / break.
    pub fn region_bone(&self, hit_bone: usize, kind: RegionKind) -> Option<usize> {
        let mut b = hit_bone as i32;
        while b >= 0 {
            if !self.region_sockets(b as usize, kind).is_empty() {
                return Some(b as usize);
            }
            b = self.parents[b as usize];
        }
        None
    }

    /// Places a cut on `bone` (already the region bone, see `region_bone`). `frame` in glTF bind pose with
    /// `bone_now` None (DI2's bReferencePose), or in any posed space with `bone_now` = the bone's global transform
    /// in that space (glTF convention; DI2: GetBoneMatrix). None without a region socket.
    pub fn place(&self, bone: usize, kind: RegionKind, frame: &DecalFrame, bone_now: Option<&Mat4>) -> Option<CutPlacement> {
        let now = bone_now.map(|m| m.to_cols_array().map(|v| v as f64));
        self.place_rows(bone, kind, &frame.rows(), now.as_ref())
    }

    /// `place` with f64 inputs: frame rows [x, y, z, origin] (glTF) and `bone_now` as 16 column-major floats.
    pub fn place_rows(&self, bone: usize, kind: RegionKind, frame: &[[f64; 3]; 4], bone_now: Option<&[f64; 16]>) -> Option<CutPlacement> {
        let sockets: Vec<UeSocket> = self.region_sockets(bone, kind).iter().map(|s| s.ue).collect();
        let f = |r: [f64; 3]| -> [f64; 4] {
            let d = swap_dir(r);
            [d[0], d[1], d[2], 0.0]
        };
        let o = ue_pos(frame[3]);
        let frame_ue = [f(frame[0]), f(frame[1]), f(frame[2]), [o[0], o[1], o[2], 1.0]];
        let ref_bone = ue_rows_from_gl(&self.ref_pose[bone]);
        let now = bone_now.map(ue_rows_from_gl);
        let p = place_dismember(&frame_ue, now.as_ref().unwrap_or(&ref_bone), &ref_bone, &sockets, now.is_none())?;
        Some(CutPlacement {
            bone,
            kind,
            origin: v3(gl_pos(row3(&p.frame, 3))),
            normal: v3(swap_dir(row3(&p.frame, 1))),
            x_axis: v3(swap_dir(row3(&p.frame, 0))),
            z_axis: v3(swap_dir(row3(&p.frame, 2))),
            decal_matrix: gl_space(&p.decal_matrix),
            safe_region: gl_space(&p.safe_region),
            region_branch_mask: p.region_branch_mask,
            score: p.score as f32,
            t_cm: p.t as f32,
            corrected: p.corrected,
            ue: p,
        })
    }

    /// `c_TargetBoneData` of a placed cut: (bone, depth, branch | region mask, break child for BoneBreak else 0).
    pub fn target(&self, cut: &CutPlacement) -> TargetBone {
        let t = self.topo[cut.bone];
        TargetBone {
            bone: cut.bone as i32,
            depth: t.depth,
            branch: t.branch | cut.region_branch_mask,
            break_bone: if cut.kind == RegionKind::Break { t.break_bone } else { 0 },
        }
    }

    /// GeometryIndicesCS runs on the section (DismemberMask).
    pub fn dismember_applies(&self, section: usize) -> bool {
        self.sections[section].dismember
    }

    /// BreakCS runs on the section: in DismemberMask, or in SkeletonVisceraMask (DI2 also tests a render-section
    /// flag there, unidentified), and the break child is in its bones.
    pub fn break_applies(&self, section: usize, target: &TargetBone) -> bool {
        let s = &self.sections[section];
        target.break_bone >= 0 && (s.dismember || s.skeleton_viscera) && s.bones.contains(&(target.break_bone as u16))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const FIXTURES: &str = include_str!("../../../tools/re_dismember/fixtures/dismember_fixtures.json");
    const BODIES: [(&str, &str); 4] = [
        ("walker", include_str!("../../../game/assets/di2/walker/walker.dismember.json")),
        ("runner", include_str!("../../../game/assets/di2/runner/runner.dismember.json")),
        ("shambler", include_str!("../../../game/assets/di2/shambler/shambler.dismember.json")),
        ("thug", include_str!("../../../game/assets/di2/thug/thug.dismember.json")),
    ];

    fn fx() -> Value {
        serde_json::from_str(FIXTURES).unwrap()
    }

    fn body(name: &str) -> DismemberData {
        DismemberData::from_json(BODIES.iter().find(|b| b.0 == name).unwrap().1).unwrap()
    }

    fn f(v: &Value) -> f64 {
        v.as_f64().unwrap_or_else(|| panic!("not a number: {v}"))
    }

    fn arr<const N: usize>(v: &Value) -> [f64; N] {
        let a = v.as_array().unwrap();
        assert_eq!(a.len(), N);
        std::array::from_fn(|i| f(&a[i]))
    }

    fn rows(v: &Value) -> ue::M {
        let a: [f64; 16] = arr(v);
        std::array::from_fn(|i| std::array::from_fn(|j| a[i * 4 + j]))
    }

    fn vec3(v: &Value) -> Vec3 {
        v3(arr(v))
    }

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol * (1.0 + a.abs().max(b.abs()))
    }

    fn assert_m(a: &ue::M, b: &ue::M, tol: f64, what: &str) {
        for i in 0..4 {
            for j in 0..4 {
                assert!(close(a[i][j], b[i][j], tol), "{what}: [{i}][{j}] {} vs {}", a[i][j], b[i][j]);
            }
        }
    }

    fn assert_mat4(a: &Mat4, b: &[f64; 16], tol: f64, what: &str) {
        let a = a.to_cols_array();
        for i in 0..16 {
            assert!(close(a[i] as f64, b[i], tol), "{what}: [{i}] {} vs {}", a[i], b[i]);
        }
    }

    fn assert_v(a: Vec3, b: [f64; 3], tol: f64, what: &str) {
        for i in 0..3 {
            assert!(close(a[i] as f64, b[i], tol), "{what}: {a} vs {b:?}");
        }
    }

    #[test]
    fn math_matches_reference() {
        let fx = fx();
        let m = &fx["math"];
        for c in m["quat_from_rotator"].as_array().unwrap() {
            let r: [f64; 3] = arr(&c["rot"]);
            let q = ue::quat_from_rotator(r[0], r[1], r[2]);
            let e: [f64; 4] = arr(&c["quat"]);
            assert!((0..4).all(|i| close(q[i], e[i], 1e-12)), "{q:?} vs {e:?}");
        }
        for c in m["transform_matrix"].as_array().unwrap() {
            assert_m(&transform_matrix(arr(&c["quat"]), arr(&c["t"]), arr(&c["s"])), &rows(&c["m"]), 1e-12, "transform_matrix");
        }
        for c in m["inverse"].as_array().unwrap() {
            assert_m(&inverse(&rows(&c["m"])), &rows(&c["inv"]), 1e-9, "inverse");
        }
        for c in m["safe_normal"].as_array().unwrap() {
            let n = safe_normal(arr(&c["v"]));
            let e: [f64; 3] = arr(&c["n"]);
            assert!((0..3).all(|i| close(n[i], e[i], 1e-12)), "{n:?} vs {e:?}");
        }
        for c in m["f16"].as_array().unwrap() {
            assert_eq!(f16_round(f(&c["x"]) as f32), f(&c["f16"]) as f32, "f16({})", c["x"]);
        }
    }

    #[test]
    fn topology_matches_reference() {
        let fx = fx();
        let t = &fx["topology_skel"];
        let names: Vec<String> = t["names"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
        let parents: Vec<i32> = t["parents"].as_array().unwrap().iter().map(|v| v.as_i64().unwrap() as i32).collect();
        let topo = bone_topology(&names, &parents);
        for (i, b) in topo.iter().enumerate() {
            assert_eq!(b.depth as i64, t["depth"][i].as_i64().unwrap(), "{}", names[i]);
            assert_eq!(b.branch as i64, t["branch"][i].as_i64().unwrap(), "{}", names[i]);
            assert_eq!(b.flag, t["flag"][i].as_bool().unwrap(), "{}", names[i]);
            assert_eq!(b.break_bone as i64, t["break_bone"][i].as_i64().unwrap(), "{}", names[i]);
        }
        let i = names.iter().position(|n| n == "upperarm_l").unwrap();
        assert_eq!((topo[i].depth, topo[i].branch), (7, 2));
        assert_eq!(names[topo[i].break_bone as usize], "lowerarm_l");
        // every exported body: the stored topology (dismember_ref.bone_topology) equals the port's
        for (name, text) in BODIES {
            let raw: Value = serde_json::from_str(text).unwrap();
            let d = body(name);
            for (i, b) in d.topo.iter().enumerate() {
                let r = &raw["bones"];
                assert_eq!(
                    (b.depth as i64, b.branch as i64, b.flag, b.break_bone as i64),
                    (r["depth"][i].as_i64().unwrap(), r["branch"][i].as_i64().unwrap(), r["flag"][i].as_bool().unwrap(), r["break_bone"][i].as_i64().unwrap()),
                    "{name} {}",
                    d.names[i]
                );
            }
        }
    }

    #[test]
    fn candidates_match_reference() {
        let fx = fx();
        for c in fx["safe_region_matrix"].as_array().unwrap() {
            assert_m(&safe_region_matrix(&rows(&c["m"]), c["use_cvars"].as_bool().unwrap()), &rows(&c["out"]), 1e-9, "safe_region_matrix");
        }
        for c in fx["decal_frame_from_rotator"].as_array().unwrap() {
            let r: [f64; 3] = arr(&c["rot"]);
            assert_m(&decal_frame_from_rotator(arr(&c["loc"]), r[0], r[1], r[2]), &rows(&c["frame"]), 1e-12, "decal_frame_from_rotator");
        }
        let mut corrected = 0;
        for c in fx["evaluate_candidate"].as_array().unwrap() {
            let s = UeSocket { quat: arr(&c["quat"]), loc: arr(&c["loc"]), scale: arr(&c["scale"]), branch_mask: c["branch_mask"].as_u64().unwrap() as u16 };
            let got = evaluate_candidate(&rows(&c["frame_ref"]), &rows(&c["ref_bone"]), &s);
            let o = &c["out"];
            let what = c["socket"].as_str().unwrap();
            assert_m(&got.frame, &rows(&o["frame"]), 1e-9, what);
            assert_m(&got.safe_region, &rows(&o["safe_region"]), 1e-9, what);
            assert!(close(got.score, f(&o["score"]), 1e-9) && close(got.t, f(&o["t"]), 1e-9), "{what}");
            assert_eq!(got.corrected, o["corrected"].as_bool().unwrap(), "{what}");
            assert_eq!(got.branch_mask as u64, o["branch_mask"].as_u64().unwrap());
            corrected += got.corrected as usize;
        }
        assert!(corrected > 0);
    }

    #[test]
    fn placement_matches_reference_in_gltf_space() {
        let fx = fx();
        let datas: Vec<DismemberData> = BODIES.iter().map(|b| body(b.0)).collect();
        let mut n = 0;
        for c in fx["place"].as_array().unwrap() {
            let d = datas.iter().find(|d| d.body == c["body"].as_str().unwrap()).unwrap();
            let bone = c["bone"].as_u64().unwrap() as usize;
            let kind = if c["kind"] == "safe" { RegionKind::Safe } else { RegionKind::Break };
            let fr = c["frame_gl"].as_array().unwrap();
            let frame: [[f64; 3]; 4] = std::array::from_fn(|i| arr(&fr[i]));
            let now: Option<[f64; 16]> = if c["bone_now_gl"].is_null() { None } else { Some(arr(&c["bone_now_gl"])) };
            let what = format!("{} {} {} {}", c["body"], c["bone_name"], c["kind"], c["hit"]);
            let p = d.place_rows(bone, kind, &frame, now.as_ref()).unwrap_or_else(|| panic!("{what}: no placement"));
            let (eu, eg) = (&c["expected"]["ue"], &c["expected"]["gl"]);
            assert_m(&p.ue.frame, &rows(&eu["frame"]), 1e-9, &what);
            assert_m(&p.ue.decal_matrix, &rows(&eu["decal_matrix"]), 1e-9, &what);
            assert_m(&p.ue.bone_matrix, &rows(&eu["bone_matrix"]), 1e-9, &what);
            assert_m(&p.ue.world_to_ref, &rows(&eu["world_to_ref"]), 1e-9, &what);
            assert_m(&p.ue.safe_region, &rows(&eu["safe_region"]), 1e-9, &what);
            assert!(close(p.ue.score, f(&eu["score"]), 1e-9) && close(p.ue.t, f(&eu["t"]), 1e-9), "{what}");
            assert_eq!(p.ue.corrected, eu["corrected"].as_bool().unwrap(), "{what}");
            assert_eq!(p.region_branch_mask as u64, eu["region_branch_mask"].as_u64().unwrap(), "{what}");
            assert_v(p.origin, arr(&eg["origin"]), 1e-6, &what);
            assert_v(p.normal, arr(&eg["normal"]), 1e-6, &what);
            assert_v(p.x_axis, arr(&eg["x"]), 1e-6, &what);
            assert_v(p.z_axis, arr(&eg["z"]), 1e-6, &what);
            assert_mat4(&p.decal_matrix, &arr(&eg["decal_matrix"]), 1e-6, &what);
            assert_mat4(&p.safe_region, &arr(&eg["safe_region"]), 1e-6, &what);
            let t: [f64; 4] = arr(&c["target"]);
            let tb = d.target(&p);
            assert_eq!([tb.bone as f64, tb.depth as f64, tb.branch as f64, tb.break_bone as f64], t, "{what}");
            // the f32 entry point agrees with the f64 one
            let df = DecalFrame { x: v3(frame[0]), y: v3(frame[1]), z: v3(frame[2]), origin: v3(frame[3]) };
            let now32 = now.map(|m| Mat4::from_cols_array(&m.map(|v| v as f32)));
            let p32 = d.place(bone, kind, &df, now32.as_ref()).unwrap();
            assert!((p32.origin - p.origin).length() < 1e-4 && p32.normal.dot(p.normal) > 0.9999, "{what}");
            // the normal points to the limb side: decal y of origin + normal is +100 cm
            assert!((plane_d(p.origin + p.normal, &p.decal_matrix) - 100.0).abs() < 1e-2, "{what}");
            n += 1;
        }
        assert!(n >= 200, "{n}");
    }

    #[test]
    fn region_bones_and_sockets() {
        let d = body("walker");
        let b = |n: &str| d.bone(n).unwrap();
        assert_eq!(d.region_sockets(b("upperarm_l"), RegionKind::Safe).len(), 3);
        assert_eq!(d.region_sockets(b("spine_04"), RegionKind::Safe).iter().map(|s| s.branch_mask).collect::<Vec<_>>(), vec![38, 34, 36]);
        assert_eq!(d.region_bone(b("hand_l"), RegionKind::Safe), Some(b("lowerarm_l")));
        assert_eq!(d.region_bone(b("upperarm_twist_01_l"), RegionKind::Break), Some(b("upperarm_l")));
        assert_eq!(d.region_bone(b("pelvis"), RegionKind::Safe), None);
        assert_eq!(d.region_bone(b("head"), RegionKind::Break), None);
        assert_eq!(RegionKind::for_type(DISMEMBER_WITH_DECAL), Some(RegionKind::Safe));
        assert_eq!(RegionKind::for_type(BONE_BREAK_WITH_DECAL), Some(RegionKind::Break));
        assert_eq!(RegionKind::for_type(CLEAR_TO_VALUE), None);
        // the glTF socket round-trips to the UE one
        let s = d.region_sockets(b("upperarm_l"), RegionKind::Safe)[0];
        assert!((s.ue.loc[0] - 17.0).abs() < 1e-9 && s.ue.scale.iter().zip([7.0, 8.0, 8.0]).all(|(a, b)| (a - b).abs() < 1e-9));
        // the ref pose converts to the UE bone frame: upperarm_l X axis (UE) = glTF column 0 swapped
        let m = d.ref_pose(b("upperarm_l"));
        let r = ue_rows_from_gl(&d.ref_pose[b("upperarm_l")]);
        assert!((Vec3::new(r[0][0] as f32, r[0][2] as f32, r[0][1] as f32) - m.x_axis.truncate()).length() < 1e-6);
    }

    fn skin(v: &Value, i: usize) -> SkinVert {
        SkinVert {
            pos: vec3(&v["pos_gl"][i]),
            bones: std::array::from_fn(|j| v["bones"][i][j].as_u64().unwrap() as u16),
            weights: std::array::from_fn(|j| f(&v["weights"][i][j]) as f32),
        }
    }

    fn to_ue(p: Vec3) -> Vec3 {
        v3(ue_pos(d3(p)))
    }

    #[test]
    fn classification_matches_reference() {
        let fx = fx();
        for sc in fx["classify"].as_array().unwrap() {
            let d = body(sc["body"].as_str().unwrap());
            let t: [f64; 4] = arr(&sc["target"]);
            let target = TargetBone { bone: t[0] as i32, depth: t[1] as u16, branch: t[2] as u16, break_bone: t[3] as i32 };
            // UE space with the reference's matrices
            let (dm, sr) = (mat4_from_rows(&rows(&sc["decal_matrix"])), mat4_from_rows(&rows(&sc["safe_region"])));
            // glTF space through the port's own placement
            let bone = sc["bone"].as_u64().unwrap() as usize;
            let fr = sc["frame_gl"].as_array().unwrap();
            let p = d.place_rows(bone, RegionKind::Safe, &std::array::from_fn(|i| arr(&fr[i])), None).unwrap();
            assert_eq!(d.target(&p), target);
            let mut seen = [0usize; 4];
            for tri in sc["triangles"].as_array().unwrap() {
                let gl: [SkinVert; 3] = std::array::from_fn(|i| skin(tri, i));
                let uev = gl.map(|v| SkinVert { pos: to_ue(v.pos), ..v });
                let binary = tri["binary"].as_bool().unwrap();
                let code = tri["code"].as_u64().unwrap() as u32;
                assert_eq!(classify_code(&uev, &dm, &sr, &target, &d.topo, binary), code, "{} {} ue {tri}", sc["body"], sc["bone_name"]);
                assert_eq!(classify_code(&gl, &p.decal_matrix, &p.safe_region, &target, &d.topo, binary), code, "{} {} gl {tri}", sc["body"], sc["bone_name"]);
                seen[code as usize] += 1;
            }
            assert!(seen[0] > 0 && seen[3] > 0, "{} {seen:?}", sc["bone_name"]);
        }
    }

    #[test]
    fn section_helpers_split_and_break() {
        let d = body("walker");
        let ua = d.bone("upperarm_l").unwrap();
        let topo_ua = d.topo[ua];
        let fr = DecalFrame { x: Vec3::Z, y: Vec3::X, z: Vec3::Y, origin: v3(gl_pos(ue::row3(&ue_rows_from_gl(&d.ref_pose[ua]), 3))) };
        let p = d.place(ua, RegionKind::Safe, &fr, None).unwrap();
        let tg = d.target(&p);
        assert_eq!((tg.bone, tg.depth, tg.branch, tg.break_bone), (ua as i32, topo_ua.depth, topo_ua.branch, 0));
        // a skinned quad on the bone straddling the cut: limb side -> limb, body side -> body, straddling -> drop
        let o = p.origin;
        let (n, a) = (p.normal, p.x_axis * 0.01);
        let pos = [o - n * 0.05, o - n * 0.05 + a, o - n * 0.04, o + n * 0.05, o + n * 0.05 + a, o + n * 0.04];
        let bones = [[ua as u16, 0, 0, 0]; 6];
        let weights = [[1.0, 0.0, 0.0, 0.0]; 6];
        let idx = [0, 1, 2, 3, 4, 5, 0, 1, 3];
        let cls = classify_section(&pos, &bones, &weights, &idx, &p.decal_matrix, &p.safe_region, &tg, &d.topo, false);
        assert_eq!(cls, vec![TriClass::Body, TriClass::Limb, TriClass::Drop]);
        assert_eq!(split_indices(&idx, &cls), (vec![0, 1, 2], vec![3, 4, 5]));
        // BoneBreak on the same bone: limb-side vertices ramp onto the break child over 10 cm, body side unchanged
        let pb = d.place(ua, RegionKind::Break, &fr, None).unwrap();
        let tb = d.target(&pb);
        let la = d.bone("lowerarm_l").unwrap() as u16;
        assert_eq!(tb.break_bone, la as i32);
        let o = pb.origin;
        let pos = [o - pb.normal * 0.05, o + pb.normal * 0.05, o + pb.normal * 0.2];
        let r = break_section(&pos, &bones[..3], &weights[..3], &pb.decal_matrix, &tb, &d.topo, false);
        assert_eq!(r[0], None);
        assert_eq!(r[1], Some(([ua as u16, 0, 0, la], [127.0 / 255.0, 0.0, 0.0, 127.0 / 255.0])));
        assert_eq!(r[2], Some(([ua as u16, 0, 0, la], [0.0, 0.0, 0.0, 1.0])));
        // no break child: the pass is not dispatched
        assert_eq!(break_vertex(&SkinVert { pos: pos[1], bones: bones[0], weights: weights[0] }, &pb.decal_matrix, &TargetBone { break_bone: -1, ..tb }, &d.topo, false), None);
    }

    #[test]
    fn bone_break_matches_reference() {
        let fx = fx();
        let (mut n, mut steps) = (0, 0);
        for sc in fx["break"].as_array().unwrap() {
            let d = body(sc["body"].as_str().unwrap());
            let t: [f64; 4] = arr(&sc["target"]);
            let target = TargetBone { bone: t[0] as i32, depth: t[1] as u16, branch: t[2] as u16, break_bone: t[3] as i32 };
            let dm = mat4_from_rows(&rows(&sc["decal_matrix"]));
            let bone = sc["bone"].as_u64().unwrap() as usize;
            let fr = sc["frame_gl"].as_array().unwrap();
            let p = d.place_rows(bone, RegionKind::Break, &std::array::from_fn(|i| arr(&fr[i])), None).unwrap();
            assert_eq!(d.target(&p), target);
            assert!(d.sections.iter().enumerate().any(|(i, _)| d.break_applies(i, &target)));
            for v in sc["vertices"].as_array().unwrap() {
                let sv = SkinVert { pos: vec3(&v["pos_gl"]), bones: std::array::from_fn(|j| v["bones"][j].as_u64().unwrap() as u16), weights: std::array::from_fn(|j| f(&v["weights"][j]) as f32) };
                let binary = v["binary"].as_bool().unwrap();
                for (r, space) in [(break_vertex(&SkinVert { pos: to_ue(sv.pos), ..sv }, &dm, &target, &d.topo, binary), "ue"), (break_vertex(&sv, &p.decal_matrix, &target, &d.topo, binary), "gl")] {
                    match (&r, v["out"].is_null()) {
                        (None, true) => {}
                        (Some((b, w)), false) => {
                            let eb: Vec<u64> = v["out"]["bones"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap()).collect();
                            assert_eq!(b.map(|x| x as u64).to_vec(), eb, "{space} {v}");
                            for j in 0..4 {
                                let e = f(&v["out"]["weights"][j]);
                                let dw = (w[j] as f64 - e).abs();
                                // f32 (GPU-like) vs f64 rounding can move floor() by one 8-bit step
                                assert!(dw < 1.0 / 255.0 + 1e-6, "{space} {v}: {w:?}");
                                steps += (dw > 1e-6) as usize;
                            }
                        }
                        _ => panic!("{space} {v}: got {r:?}"),
                    }
                    n += 1;
                }
            }
        }
        assert!(n > 900, "{n}");
        assert!(steps * 50 < n, "too many 8-bit step differences: {steps} of {n}");
    }

    fn tex_dif(u: f32, v: f32) -> [f32; 4] {
        [u, v, u * v, 1.0 - u * v]
    }

    fn tex_disp(u: f32, v: f32) -> [f32; 4] {
        [0.25 + 0.5 * u * v, u * u, v * v, 1.0]
    }

    fn tex_disp_r(u: f32, v: f32) -> f32 {
        0.25 + 0.5 * u * v
    }

    fn element(e: &Value) -> RadialElement {
        let a4 = |k: &str| -> [f32; 4] { arr::<4>(&e[k]).map(|v| v as f32) };
        let a2 = |k: &str| -> [f32; 2] { arr::<2>(&e[k]).map(|v| v as f32) };
        RadialElement { scale_vec: a4("ScaleVec"), wound_scale: a4("WoundScale"), fx_scale: a4("FXScale"), range: a2("RangeParams"), deform_params: a2("DeformParams") }
    }

    #[test]
    fn radial_stamp_matches_reference() {
        let fx = fx();
        let r = &fx["radial"];
        let d = body(r["body"].as_str().unwrap());
        let bone = r["bone"].as_u64().unwrap() as usize;
        let fr = r["frame_gl"].as_array().unwrap();
        let p = d.place_rows(bone, RegionKind::Safe, &std::array::from_fn(|i| arr(&fr[i])), None).unwrap();
        let uv_scale = f(&r["uv_scale"]);
        assert_m(&radial_decal_matrix(&rows(&r["cut_frame"]), uv_scale), &rows(&r["radial_decal_matrix"]), 1e-9, "radial_decal_matrix");
        let rdm_gl = p.radial_decal_matrix(uv_scale as f32);
        assert_mat4(&rdm_gl, &arr(&r["radial_decal_matrix_gl"]), 1e-6, "radial_decal_matrix gl");
        let (rdm_ue, sr_ue) = (mat4_from_rows(&rows(&r["radial_decal_matrix"])), mat4_from_rows(&rows(&r["safe_region"])));
        let elements: Vec<(String, RadialElement)> = r["elements"].as_object().unwrap().iter().map(|(k, v)| (k.clone(), element(v))).collect();
        let mut inside = 0;
        for c in r["points"].as_array().unwrap() {
            let pg = vec3(&c["pos_gl"]);
            for (pos, rdm, sr, space) in [(to_ue(pg), &rdm_ue, &sr_ue, "ue"), (pg, &rdm_gl, &p.safe_region, "gl")] {
                let (w, uv) = radial_coords(pos, rdm, sr);
                assert!((w as f64 - f(&c["w"])).abs() < 2e-4, "{space} w {w} {c}");
                let euv: [f64; 2] = arr(&c["uv"]);
                assert!((uv[0] as f64 - euv[0]).abs() < 2e-4 && (uv[1] as f64 - euv[1]).abs() < 2e-4, "{space} uv {uv:?} {c}");
                let (dlen, depth) = (f(&c["deform_len"]) as f32, f(&c["depth"]) as f32);
                for (name, e) in &elements {
                    let got = radial_texel(pos, rdm, sr, e, dlen, &tex_dif, &tex_disp);
                    let exp = &c["texel"][name];
                    match (&got, exp.is_null()) {
                        (None, true) => {}
                        (Some((o0, o1)), false) => {
                            let (e0, e1): ([f64; 4], [f64; 4]) = (arr(&exp[0]), arr(&exp[1]));
                            for k in 0..4 {
                                assert!((o0[k] as f64 - e0[k]).abs() < 1e-3 && (o1[k] as f64 - e1[k]).abs() < 1e-3, "{space} {name} {got:?} {exp}");
                            }
                        }
                        _ => panic!("{space} {name}: {got:?} vs {exp}"),
                    }
                    let vd = radial_vertex_depth(pos, rdm, sr, e, depth, &tex_disp_r);
                    assert!((vd as f64 - f(&c["vertex_depth"][name])).abs() < 5e-4, "{space} {name} depth {vd} {c}");
                }
            }
            inside += (f(&c["w"]) > 0.0) as usize;
        }
        assert!(inside >= 100, "{inside}");
        // on the region axis (r == 0): u = saturate(NaN) = 0, full weight
        let (w, uv) = radial_coords(Vec3::ZERO, &Mat4::IDENTITY, &Mat4::IDENTITY);
        assert_eq!((w, uv), (1.0, [0.0, 0.5]));
    }

    #[test]
    fn radial_element_from_stamp() {
        let (ax, ay, az) = crate::splatter::frame(-Vec3::Z, Vec3::Y, 0.0);
        let s = Stamp { origin: Vec3::ZERO, ax, ay, az, half_size: 0.225, depth: 0.1, fade_gain: 1.0, angle_wrap: 1.0, displacement_tex: 0, diffuse_tex: 1, flags: APPLY_MIN | SUBTRACTIVE, cloth_depth: 1.0, cloth_displacement: 0.5, wound: [1.0, 0.8, 0.6], fx: [0.1, 0.2, 1.0, 1.0], range: [0.0, 1.0], displacement: 2.0, persistent: false, id: 0 };
        let e = RadialElement::from_stamp(&s, true);
        assert_eq!(e.scale_vec, [1.0, 1.0, -1.0, 1.0]);
        assert_eq!(e.wound_scale, [0.5, 0.8, 0.6, 0.0]);
        assert_eq!(e.deform_params, [0.0, -1.0]);
        let f = DecalFrame::from_stamp(&s);
        assert_eq!((f.x, f.y, f.z), (ay, az, -ax));
    }

    #[test]
    fn clears_match_reference() {
        let fx = fx();
        for c in fx["clears"].as_array().unwrap() {
            let t = c["t"].as_u64().unwrap() as u32;
            let kind = match c["kind"].as_str() {
                Some("value") => Some(ClearKind::ToValue),
                Some("zero") => Some(ClearKind::ToZero),
                _ => None,
            };
            assert_eq!(clear_kind(t), kind, "{c}");
            let cv = f(&c["clear_value"]) as f32;
            let (a, b) = clear_rt_texel(t, c["proxy"].as_bool().unwrap(), cv, arr::<4>(&c["disp"]).map(|v| v as f32), arr::<4>(&c["dif"]).map(|v| v as f32));
            let (ea, eb): ([f64; 4], [f64; 4]) = (arr(&c["out_disp"]), arr(&c["out_dif"]));
            for k in 0..4 {
                assert!((a[k] as f64 - ea[k]).abs() < 1e-6 && (b[k] as f64 - eb[k]).abs() < 1e-6, "{c}: {a:?} {b:?}");
            }
            assert_eq!(clear_vertex_depth(cv), f(&c["vertex_depth"]) as f32, "{c}");
        }
        assert_eq!(clear_kind(CLEAR_TO_VALUE), Some(ClearKind::ToValue));
        assert_eq!(clear_kind(CLEAR_SPLATTER), Some(ClearKind::ToZero));
        assert_eq!(clear_kind(DISMEMBER_WITH_DECAL), None);
    }
}
