//! DI2 particle distributions, Godot's RNG and Godot-exact vector math for the Cascade port (DI2ParticleSim).
//!
//! Mirrors game/scripts/di2_particles.gd (the GDScript reference implementation) operation for operation:
//! scalars are f64 (GDScript `float`), vectors / bases are f32 (Godot `real_t`), so a run with the same seed
//! reproduces the GDScript simulation (recon/PARTICLES.md "Rust simulation").

use godot::builtin::{Basis, Vector3};
use serde_json::Value;
use std::collections::HashMap;

// --- Godot RandomPCG (core/math/random_pcg.h, 4.x) ---------------------------------------------------------------

pub const PCG_DEFAULT_INC_64: u64 = 1442695040888963407;

#[derive(Clone, Default)]
pub struct Rng {
    state: u64,
    inc: u64,
}

impl Rng {
    /// RandomNumberGenerator.seed = s (pcg32_srandom_r with the default increment).
    pub fn seeded(seed: u64) -> Self {
        let mut r = Rng { state: 0, inc: (PCG_DEFAULT_INC_64 << 1) | 1 };
        r.next_u32();
        r.state = r.state.wrapping_add(seed);
        r.next_u32();
        r
    }

    fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(6364136223846793005).wrapping_add(self.inc);
        let xorshifted = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xorshifted.rotate_right(rot)
    }

    /// RandomPCG::randf: the first rand() picks the binary exponent (its leading zeros), the second the significand
    /// (| 0x80000001: top and bottom bits set), scaled by 2^(-32 - clz).
    pub fn randf(&mut self) -> f64 {
        let proto = self.next_u32();
        if proto == 0 {
            return 0.0;
        }
        let m = (self.next_u32() | 0x8000_0001) as f32;
        let e = -32 - proto.leading_zeros() as i32;
        (m * 2f32.powi(e)) as f64
    }
}

/// A distribution's random source: FMath::SRand (Godot's PCG here, the GDScript simulation's RNG) or a seeded
/// module's FRandomStream (UParticleModule*_Seeded, RandomSeedInfo).
pub trait RandSrc {
    fn frac(&mut self) -> f64;
}

impl RandSrc for Rng {
    fn frac(&mut self) -> f64 {
        self.randf()
    }
}

/// UE FRandomStream: MutateSeed (seed * 196314165 + 907633515), GetFraction from the mantissa bits.
#[derive(Clone, Copy, Default)]
pub struct SeedStream(pub u32);

impl RandSrc for SeedStream {
    fn frac(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(196314165).wrapping_add(907633515);
        (f32::from_bits((self.0 >> 9) | 0x3f80_0000) - 1.0) as f64
    }
}

// --- Godot-exact f32 vector / basis helpers ----------------------------------------------------------------------

#[inline]
pub fn v3(x: f64, y: f64, z: f64) -> Vector3 {
    Vector3::new(x as f32, y as f32, z as f32)
}
#[inline]
pub fn vadd(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.x + b.x, a.y + b.y, a.z + b.z)
}
#[inline]
pub fn vsub(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.x - b.x, a.y - b.y, a.z - b.z)
}
/// Vector3 * float (the double is converted to real_t first, like Godot's Variant operator).
#[inline]
pub fn vmul(a: Vector3, s: f64) -> Vector3 {
    let s = s as f32;
    Vector3::new(a.x * s, a.y * s, a.z * s)
}
#[inline]
pub fn vmulv(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.x * b.x, a.y * b.y, a.z * b.z)
}
#[inline]
pub fn vneg(a: Vector3) -> Vector3 {
    Vector3::new(-a.x, -a.y, -a.z)
}
#[inline]
pub fn vdot(a: Vector3, b: Vector3) -> f32 {
    a.x * b.x + a.y * b.y + a.z * b.z
}
#[inline]
pub fn vcross(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
#[inline]
pub fn vlen_sq(a: Vector3) -> f32 {
    a.x * a.x + a.y * a.y + a.z * a.z
}
#[inline]
pub fn vlen(a: Vector3) -> f32 {
    vlen_sq(a).sqrt()
}
/// Vector3::normalized (zero stays zero).
#[inline]
pub fn vnorm(a: Vector3) -> Vector3 {
    let l2 = vlen_sq(a);
    if l2 == 0.0 {
        return Vector3::ZERO;
    }
    let l = l2.sqrt();
    Vector3::new(a.x / l, a.y / l, a.z / l)
}
#[inline]
pub fn vabs(a: Vector3) -> Vector3 {
    Vector3::new(a.x.abs(), a.y.abs(), a.z.abs())
}
#[inline]
pub fn comp(a: Vector3, k: usize) -> f32 {
    match k {
        0 => a.x,
        1 => a.y,
        _ => a.z,
    }
}
#[inline]
pub fn set_comp(a: &mut Vector3, k: usize, v: f32) {
    match k {
        0 => a.x = v,
        1 => a.y = v,
        _ => a.z = v,
    }
}

/// 3x3 matrix with Godot Basis semantics (rows; columns are the axes).
#[derive(Clone, Copy, Debug)]
pub struct M3 {
    pub r: [[f32; 3]; 3],
}

impl M3 {
    pub const IDENTITY: M3 = M3 { r: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]] };

    /// Basis(x, y, z) from column vectors.
    pub fn from_cols(x: Vector3, y: Vector3, z: Vector3) -> M3 {
        M3 { r: [[x.x, y.x, z.x], [x.y, y.y, z.y], [x.z, y.z, z.z]] }
    }
    pub fn col(&self, j: usize) -> Vector3 {
        Vector3::new(self.r[0][j], self.r[1][j], self.r[2][j])
    }
    pub fn from_godot(b: &Basis) -> M3 {
        M3 { r: [[b.rows[0].x, b.rows[0].y, b.rows[0].z], [b.rows[1].x, b.rows[1].y, b.rows[1].z], [b.rows[2].x, b.rows[2].y, b.rows[2].z]] }
    }
    /// Basis::xform
    #[inline]
    pub fn xform(&self, v: Vector3) -> Vector3 {
        Vector3::new(
            self.r[0][0] * v.x + self.r[0][1] * v.y + self.r[0][2] * v.z,
            self.r[1][0] * v.x + self.r[1][1] * v.y + self.r[1][2] * v.z,
            self.r[2][0] * v.x + self.r[2][1] * v.y + self.r[2][2] * v.z,
        )
    }
    /// Basis * Basis
    pub fn mul(&self, o: &M3) -> M3 {
        let mut r = [[0f32; 3]; 3];
        for i in 0..3 {
            for j in 0..3 {
                r[i][j] = self.r[i][0] * o.r[0][j] + self.r[i][1] * o.r[1][j] + self.r[i][2] * o.r[2][j];
            }
        }
        M3 { r }
    }
    fn cofac(&self, r1: usize, c1: usize, r2: usize, c2: usize) -> f32 {
        self.r[r1][c1] * self.r[r2][c2] - self.r[r1][c2] * self.r[r2][c1]
    }
    /// Basis::inverse
    pub fn inverse(&self) -> M3 {
        let co = [self.cofac(1, 1, 2, 2), self.cofac(1, 2, 2, 0), self.cofac(1, 0, 2, 1)];
        let det = self.r[0][0] * co[0] + self.r[0][1] * co[1] + self.r[0][2] * co[2];
        let s = 1.0f32 / det;
        M3 {
            r: [
                [co[0] * s, self.cofac(0, 2, 2, 1) * s, self.cofac(0, 1, 1, 2) * s],
                [co[1] * s, self.cofac(0, 0, 2, 2) * s, self.cofac(0, 2, 1, 0) * s],
                [co[2] * s, self.cofac(0, 1, 2, 0) * s, self.cofac(0, 0, 1, 1) * s],
            ],
        }
    }
    pub fn scaled_cols(&self, s: Vector3) -> M3 {
        // b * Basis.from_scale(s)
        self.mul(&M3 { r: [[s.x, 0.0, 0.0], [0.0, s.y, 0.0], [0.0, 0.0, s.z]] })
    }
    /// Basis::get_euler (EULER_ORDER_YXZ), radians.
    pub fn euler_yxz(&self) -> Vector3 {
        let r = &self.r;
        let m12 = r[1][2];
        const E: f32 = 0.00001;
        if m12 < 1.0 - E {
            if m12 > -(1.0 - E) {
                if r[1][0] == 0.0 && r[0][1] == 0.0 && r[0][2] == 0.0 && r[2][0] == 0.0 && r[0][0] == 1.0 {
                    Vector3::new((-m12).atan2(r[1][1]), 0.0, 0.0)
                } else {
                    Vector3::new((-m12).asin(), r[0][2].atan2(r[2][2]), r[1][0].atan2(r[1][1]))
                }
            } else {
                Vector3::new(std::f32::consts::PI * 0.5, r[0][1].atan2(r[0][0]), 0.0)
            }
        } else {
            Vector3::new(-std::f32::consts::PI * 0.5, -(r[0][1].atan2(r[0][0])), 0.0)
        }
    }
}

/// Transform3D with Godot semantics.
#[derive(Clone, Copy, Debug)]
pub struct Xf {
    pub b: M3,
    pub o: Vector3,
}

impl Xf {
    pub const IDENTITY: Xf = Xf { b: M3::IDENTITY, o: Vector3::ZERO };
    #[inline]
    pub fn xform(&self, v: Vector3) -> Vector3 {
        vadd(self.b.xform(v), self.o)
    }
    pub fn mul(&self, o: &Xf) -> Xf {
        Xf { b: self.b.mul(&o.b), o: self.xform(o.o) }
    }
    pub fn affine_inverse(&self) -> Xf {
        let bi = self.b.inverse();
        Xf { b: bi, o: bi.xform(vneg(self.o)) }
    }
}

/// DI2Particles.rotator_basis_ue: UE FRotationTranslationMatrix(FRotator(Pitch, Yaw, Roll)) rows as basis columns.
pub fn rotator_basis_ue(pitch: f64, yaw: f64, roll: f64) -> M3 {
    let (sp, cp) = (pitch.to_radians().sin(), pitch.to_radians().cos());
    let (sy, cy) = (yaw.to_radians().sin(), yaw.to_radians().cos());
    let (sr, cr) = (roll.to_radians().sin(), roll.to_radians().cos());
    let x = v3(cp * cy, cp * sy, sp);
    let y = v3(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp);
    let z = v3(-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp);
    M3::from_cols(x, y, z)
}

#[inline]
pub fn u2g(p: Vector3) -> Vector3 {
    let s = 0.01f32;
    Vector3::new(p.x * s, p.z * s, p.y * s)
}
#[inline]
pub fn u2g_dir(v: Vector3) -> Vector3 {
    Vector3::new(v.x, v.z, v.y)
}
#[inline]
pub fn g2u(p: Vector3) -> Vector3 {
    let s = 100.0f32;
    Vector3::new(p.x * s, p.z * s, p.y * s)
}
/// S * B * S (swap y / z): columns u2g(B * X), u2g(B * Z), u2g(B * Y).
pub fn u2g_basis(b: &M3) -> M3 {
    M3::from_cols(
        u2g_dir(b.xform(Vector3::new(1.0, 0.0, 0.0))),
        u2g_dir(b.xform(Vector3::new(0.0, 0.0, 1.0))),
        u2g_dir(b.xform(Vector3::new(0.0, 1.0, 0.0))),
    )
}

/// UE FQuat::FindBetweenNormals as (x, y, z, w), normalized like Godot's Quaternion::normalized (f32).
pub fn find_between_normals_ue(a: Vector3, b: Vector3) -> [f32; 4] {
    let w = 1.0f64 + vdot(a, b) as f64;
    let q: [f32; 4] = if w >= 1e-6 {
        [a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x, w as f32]
    } else if a.x.abs() > a.y.abs() {
        [-a.z, 0.0, a.x, 0.0]
    } else {
        [0.0, -a.z, a.y, 0.0]
    };
    let l = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).sqrt();
    [q[0] / l, q[1] / l, q[2] / l, q[3] / l]
}

fn normalize_axis(a: f64) -> f64 {
    let mut a = a % 360.0;
    if a < 0.0 {
        a += 360.0;
    }
    if a > 180.0 {
        a -= 360.0;
    }
    a
}

/// DI2Particles.quat_euler_ue: (Roll, Pitch, Yaw) degrees.
pub fn quat_euler_ue(q: [f32; 4]) -> Vector3 {
    let (x, y, z, w) = (q[0] as f64, q[1] as f64, q[2] as f64, q[3] as f64);
    let st = z * x - w * y;
    let yy = 2.0 * (w * z + x * y);
    let yx = 1.0 - 2.0 * (y * y + z * z);
    let (pitch, yaw, roll);
    if st < -0.4999995 {
        pitch = -90.0;
        yaw = yy.atan2(yx).to_degrees();
        roll = normalize_axis(-yaw - (2.0 * x.atan2(w)).to_degrees());
    } else if st > 0.4999995 {
        pitch = 90.0;
        yaw = yy.atan2(yx).to_degrees();
        roll = normalize_axis(yaw - (2.0 * x.atan2(w)).to_degrees());
    } else {
        pitch = (2.0 * st).asin().to_degrees();
        yaw = yy.atan2(yx).to_degrees();
        roll = (-2.0 * (w * x + y * z)).atan2(1.0 - 2.0 * (x * x + y * y)).to_degrees();
    }
    v3(roll, pitch, yaw)
}

// --- JSON helpers ------------------------------------------------------------------------------------------------

pub fn jf(v: &Value, k: &str, d: f64) -> f64 {
    v.get(k).and_then(|x| x.as_f64()).unwrap_or(d)
}
pub fn jb(v: &Value, k: &str, d: bool) -> bool {
    v.get(k).and_then(|x| x.as_bool()).unwrap_or(d)
}
pub fn js<'a>(v: &'a Value, k: &str, d: &'a str) -> &'a str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or(d)
}
pub fn ji(v: &Value, k: &str, d: i64) -> i64 {
    v.get(k).and_then(|x| x.as_f64()).map(|x| x as i64).unwrap_or(d)
}
/// DI2Particles._v3 of a JSON [x, y, z] (doubles -> Vector3).
pub fn jv3(v: Option<&Value>, d: [f64; 3]) -> Vector3 {
    match v.and_then(|a| a.as_array()) {
        Some(a) if a.len() >= 3 => v3(a[0].as_f64().unwrap_or(0.0), a[1].as_f64().unwrap_or(0.0), a[2].as_f64().unwrap_or(0.0)),
        _ => v3(d[0], d[1], d[2]),
    }
}

// --- instance parameters -----------------------------------------------------------------------------------------

#[derive(Clone, Copy)]
pub enum Param {
    F(f64),
    V(Vector3),
}
pub type Params = HashMap<String, Param>;

// --- distributions -----------------------------------------------------------------------------------------------

#[derive(Clone)]
pub enum CurveOut {
    F(f64),
    V([f64; 3]),
}

#[derive(Clone)]
pub struct CurvePt {
    t: f64,
    out: CurveOut,
    arrive: CurveOut,
    leave: CurveOut,
    mode: u8, // 0 linear, 1 constant, 2 curve (Hermite)
}

#[derive(Clone)]
pub enum Dist {
    Null,
    Lut { op: i32, n: i32, s: i32, ts: f64, tb: f64, lock: i32, vals: Vec<f64> },
    Fc(f64),
    Fu(f64, f64),
    Curve { pts: Vec<CurvePt>, lock: String },
    Fp { name: String, c: f64, in0: f64, in1: f64, out0: f64, out1: f64, mode: String },
    Vc(Vector3),
    Vu(Vector3, Vector3, String),
    Vp { name: String, c: [f64; 3], inp: [[f64; 3]; 2], out: [[f64; 3]; 2], mode: [String; 3] },
}

fn curve_out(v: &Value) -> CurveOut {
    if let Some(a) = v.as_array() {
        CurveOut::V([a.first().and_then(|x| x.as_f64()).unwrap_or(0.0), a.get(1).and_then(|x| x.as_f64()).unwrap_or(0.0), a.get(2).and_then(|x| x.as_f64()).unwrap_or(0.0)])
    } else {
        CurveOut::F(v.as_f64().unwrap_or(0.0))
    }
}

fn arr3(v: Option<&Value>) -> [f64; 3] {
    match v.and_then(|a| a.as_array()) {
        Some(a) => [a.first().and_then(|x| x.as_f64()).unwrap_or(0.0), a.get(1).and_then(|x| x.as_f64()).unwrap_or(0.0), a.get(2).and_then(|x| x.as_f64()).unwrap_or(0.0)],
        None => {
            let f = v.and_then(|x| x.as_f64()).unwrap_or(0.0);
            [f, f, f]
        }
    }
}

/// DI2Particles._lock
pub fn lock_str(mut v: Vector3, lock: &str) -> Vector3 {
    match lock {
        "EDVLF_XY" => v.y = v.x,
        "EDVLF_XZ" => v.z = v.x,
        "EDVLF_YZ" => v.z = v.y,
        "EDVLF_XYZ" => {
            v.y = v.x;
            v.z = v.x;
        }
        _ => {}
    }
    v
}

/// DI2Particles._map1
fn map1(x: f64, in0: f64, in1: f64, out0: f64, out1: f64, mode: &str) -> f64 {
    if mode == "DPM_Direct" {
        return x;
    }
    let x = if mode == "DPM_Abs" { x.abs() } else { x };
    let g = if in1 <= in0 { 0.0 } else { (out1 - out0) / (in1 - in0) };
    out0 + (x.clamp(in0, in1) - in0) * g
}

impl Dist {
    pub fn from_json(v: Option<&Value>) -> Dist {
        let Some(v) = v else { return Dist::Null };
        if v.is_null() {
            return Dist::Null;
        }
        if v.get("op").is_some() && v.get("v").is_some() {
            let vals: Vec<f64> = v["v"].as_array().map(|a| a.iter().map(|x| x.as_f64().unwrap_or(0.0)).collect()).unwrap_or_default();
            return Dist::Lut {
                op: ji(v, "op", 1) as i32,
                n: ji(v, "n", 1) as i32,
                s: ji(v, "s", 1) as i32,
                ts: jf(v, "ts", 0.0),
                tb: jf(v, "tb", 0.0),
                lock: ji(v, "lock", 0) as i32,
                vals,
            };
        }
        let lock = js(v, "lock", "EDVLF_None").to_string();
        match js(v, "d", "") {
            "FC" => Dist::Fc(jf(v, "c", 0.0)),
            "FU" => Dist::Fu(jf(v, "min", 0.0), jf(v, "max", 0.0)),
            "FCC" | "VCC" => {
                let pts = v["pts"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .map(|p| CurvePt {
                                t: p[0].as_f64().unwrap_or(0.0),
                                out: curve_out(&p[1]),
                                arrive: curve_out(&p[2]),
                                leave: curve_out(&p[3]),
                                mode: match p[4].as_str().unwrap_or("CIM_Linear") {
                                    "CIM_Linear" => 0,
                                    "CIM_Constant" => 1,
                                    _ => 2,
                                },
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Dist::Curve { pts, lock }
            }
            "FP" => Dist::Fp {
                name: js(v, "name", "").to_string(),
                c: jf(v, "c", 0.0),
                in0: v["in"][0].as_f64().unwrap_or(0.0),
                in1: v["in"][1].as_f64().unwrap_or(0.0),
                out0: v["out"][0].as_f64().unwrap_or(0.0),
                out1: v["out"][1].as_f64().unwrap_or(0.0),
                mode: v["mode"].as_str().unwrap_or("DPM_Normal").to_string(),
            },
            "VC" => Dist::Vc(lock_str(jv3(v.get("c"), [0.0; 3]), &lock)),
            "VU" => Dist::Vu(jv3(v.get("min"), [0.0; 3]), jv3(v.get("max"), [0.0; 3]), lock),
            "VP" => {
                let mode: [String; 3] = match v["mode"].as_array() {
                    Some(a) => [0, 1, 2].map(|k| a.get(k).and_then(|x| x.as_str()).unwrap_or("DPM_Normal").to_string()),
                    None => ["DPM_Normal".to_string(), "DPM_Normal".to_string(), "DPM_Normal".to_string()],
                };
                Dist::Vp {
                    name: js(v, "name", "").to_string(),
                    c: arr3(v.get("c")),
                    inp: [arr3(v["in"].get(0)), arr3(v["in"].get(1))],
                    out: [arr3(v["out"].get(0)), arr3(v["out"].get(1))],
                    mode,
                }
            }
            _ => Dist::Null,
        }
    }

    /// DI2Particles.df
    pub fn f(&self, t: f64, rng: &mut dyn RandSrc, params: &Params) -> f64 {
        match self {
            Dist::Null => 0.0,
            Dist::Lut { op, n, s, ts, tb, vals, .. } => {
                let (n, s) = (*n as i64, *s as i64);
                let rel = ((t - tb) * ts).max(0.0);
                let i = (rel as i64).min(n - 1);
                let j = (i + 1).min(n - 1);
                let a = rel - rel.floor();
                let g = |k: i64| vals.get(k as usize).copied().unwrap_or(0.0);
                if *op == 1 {
                    return lerp(g(i * s), g(j * s), a);
                }
                let r = rng.frac();
                if *op == 2 {
                    let lo = lerp(g(i * s), g(j * s), a);
                    let hi = lerp(g(i * s + 1), g(j * s + 1), a);
                    return lerp(lo, hi, r);
                }
                let k = if r > 0.5 { 1 } else { 0 };
                lerp(g(i * s + k), g(j * s + k), a)
            }
            Dist::Fc(c) => *c,
            Dist::Fu(lo, hi) => lerp(*lo, *hi, rng.frac()),
            Dist::Curve { pts, .. } => match curve(pts, t) {
                CurveOut::F(x) => x,
                CurveOut::V(v) => v[0],
            },
            Dist::Fp { name, c, in0, in1, out0, out1, mode } => {
                let x = match params.get(name) {
                    Some(Param::F(x)) => *x,
                    Some(Param::V(v)) => v.x as f64,
                    None => *c,
                };
                map1(x, *in0, *in1, *out0, *out1, mode)
            }
            Dist::Vc(v) => v.x as f64,
            Dist::Vu(..) | Dist::Vp { .. } => self.v(t, rng, params).x as f64,
        }
    }

    /// DI2Particles.dv
    pub fn v(&self, t: f64, rng: &mut dyn RandSrc, params: &Params) -> Vector3 {
        match self {
            Dist::Null => Vector3::ZERO,
            Dist::Lut { op, n, s, ts, tb, lock, vals } => {
                let (n, s) = (*n as i64, *s as i64);
                let rel = ((t - tb) * ts).max(0.0);
                let i = (rel as i64).min(n - 1);
                let j = (i + 1).min(n - 1);
                let a = rel - rel.floor();
                let e1 = i * s;
                let e2 = j * s;
                let g = |k: i64| vals.get(k as usize).copied().unwrap_or(0.0);
                if *op == 1 {
                    return v3(lerp(g(e1), g(e2), a), lerp(g(e1 + 1), g(e2 + 1), a), lerp(g(e1 + 2), g(e2 + 2), a));
                }
                if *op == 2 {
                    let mut r = v3(rng.frac(), rng.frac(), rng.frac());
                    match lock {
                        1 => r.y = r.x,
                        2 => r.z = r.x,
                        3 => r.z = r.y,
                        4 => {
                            r.y = r.x;
                            r.z = r.x;
                        }
                        _ => {}
                    }
                    let lo = v3(lerp(g(e1), g(e2), a), lerp(g(e1 + 1), g(e2 + 1), a), lerp(g(e1 + 2), g(e2 + 2), a));
                    let hi = v3(lerp(g(e1 + 3), g(e2 + 3), a), lerp(g(e1 + 4), g(e2 + 4), a), lerp(g(e1 + 5), g(e2 + 5), a));
                    return v3(
                        lerp(lo.x as f64, hi.x as f64, r.x as f64),
                        lerp(lo.y as f64, hi.y as f64, r.y as f64),
                        lerp(lo.z as f64, hi.z as f64, r.z as f64),
                    );
                }
                let k = if rng.frac() > 0.5 { 3 } else { 0 };
                v3(lerp(g(e1 + k), g(e2 + k), a), lerp(g(e1 + k + 1), g(e2 + k + 1), a), lerp(g(e1 + k + 2), g(e2 + k + 2), a))
            }
            Dist::Vc(v) => *v,
            Dist::Vu(lo, hi, lock) => {
                let r = lock_str(v3(rng.frac(), rng.frac(), rng.frac()), lock);
                v3(
                    lerp(lo.x as f64, hi.x as f64, r.x as f64),
                    lerp(lo.y as f64, hi.y as f64, r.y as f64),
                    lerp(lo.z as f64, hi.z as f64, r.z as f64),
                )
            }
            Dist::Curve { pts, lock } => {
                let v = match curve(pts, t) {
                    CurveOut::V(v) => v3(v[0], v[1], v[2]),
                    CurveOut::F(x) => v3(x, x, x),
                };
                lock_str(v, lock)
            }
            Dist::Vp { name, c, inp, out, mode } => {
                let pv = params.get(name);
                let mut res = Vector3::ZERO;
                for k in 0..3 {
                    let x = match pv {
                        Some(Param::V(v)) => comp(*v, k) as f64,
                        Some(Param::F(f)) => *f,
                        None => c[k],
                    };
                    set_comp(&mut res, k, map1(x, inp[0][k], inp[1][k], out[0][k], out[1][k], &mode[k]) as f32);
                }
                res
            }
            Dist::Fc(_) | Dist::Fu(..) | Dist::Fp { .. } => {
                let x = self.f(t, rng, params);
                v3(x, x, x)
            }
        }
    }
}

#[inline]
pub fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// DI2Particles._curve (FInterpCurve::Eval: CIM_Linear lerp, CIM_Constant step, curve modes = Hermite).
fn curve(pts: &[CurvePt], t: f64) -> CurveOut {
    let n = pts.len();
    if n == 0 {
        return CurveOut::F(0.0);
    }
    if t <= pts[0].t || n == 1 {
        return pts[0].out.clone();
    }
    if t >= pts[n - 1].t {
        return pts[n - 1].out.clone();
    }
    let mut i = 0;
    while i < n - 1 && t >= pts[i + 1].t {
        i += 1;
    }
    let (p0, p1) = (&pts[i], &pts[i + 1]);
    let diff = p1.t - p0.t;
    if diff <= 0.0 || p0.mode == 1 {
        return p0.out.clone();
    }
    let a = (t - p0.t) / diff;
    if p0.mode == 0 {
        return match (&p0.out, &p1.out) {
            (CurveOut::V(x), CurveOut::V(y)) => CurveOut::V([lerp(x[0], y[0], a), lerp(x[1], y[1], a), lerp(x[2], y[2], a)]),
            (CurveOut::F(x), CurveOut::F(y)) => CurveOut::F(lerp(*x, *y, a)),
            _ => p0.out.clone(),
        };
    }
    let a2 = a * a;
    let a3 = a2 * a;
    let h00 = 2.0 * a3 - 3.0 * a2 + 1.0;
    let h10 = a3 - 2.0 * a2 + a;
    let h01 = -2.0 * a3 + 3.0 * a2;
    let h11 = a3 - a2;
    match (&p0.out, &p0.leave, &p1.out, &p1.arrive) {
        (CurveOut::V(o0), CurveOut::V(l0), CurveOut::V(o1), CurveOut::V(a1)) => {
            let mut r = [0.0; 3];
            for k in 0..3 {
                r[k] = h00 * o0[k] + h10 * l0[k] * diff + h01 * o1[k] + h11 * a1[k] * diff;
            }
            CurveOut::V(r)
        }
        (CurveOut::F(o0), CurveOut::F(l0), CurveOut::F(o1), CurveOut::F(a1)) => CurveOut::F(h00 * o0 + h10 * l0 * diff + h01 * o1 + h11 * a1 * diff),
        _ => p0.out.clone(),
    }
}
