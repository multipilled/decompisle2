//! The Cascade emitter simulation of DI2Particles (game/scripts/di2_particles.gd, class Emitter) in Rust.
//!
//! One `System` = one UParticleSystemComponent instance: its emitters (DI2's cooked modules from
//! game/data/particles.json), the component state the GDScript node passes in each tick, the RNG and the particle
//! events. Every function mirrors its GDScript counterpart (same names in comments); the DI2 sources of the
//! semantics (exe addresses) are documented there and in recon/PARTICLES.md.

use super::dist::*;
use godot::builtin::{Color, PackedFloat32Array, Rid, Vector2, Vector3, VarDictionary};
use godot::meta::ToGodot;
use godot::classes::{PhysicsDirectSpaceState3D, PhysicsRayQueryParameters3D};
use godot::obj::{Gd, NewGd};
use serde_json::Value;
use std::rc::Rc;

pub const MAX_PARTICLES_PER_EMITTER: usize = 4000;
pub const F_JUST_SPAWNED: i32 = 0x0200_0000;
pub const F_FREEZE: i32 = 0x0400_0000;
pub const F_IGNORE_COLLISIONS: i32 = 0x0800_0000;
pub const F_FREEZE_TRANSLATION: i32 = 0x1000_0000;
pub const F_FREEZE_ROTATION: i32 = 0x2000_0000;
const TAU: f64 = std::f64::consts::TAU;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Kind {
    #[default]
    Sprite = 0,
    Mesh = 1,
    Gpu = 2,
    None = 3,
}

#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Align {
    #[default]
    Square,
    Rectangle,
    Velocity,
    FacingCameraPos,
    Other,
}

// --- modules -----------------------------------------------------------------------------------------------------

#[derive(Clone)]
struct DynParam {
    method: u8, // 0 UserSet, 1 VelX, 2 VelY, 3 VelZ, 4 VelMag, 5 AutoSet
    use_et: bool,
    eval: bool,
    value: Dist,
}

#[derive(Clone)]
enum Mod {
    Lifetime { life: Dist },
    Size { start: Dist },
    SizeMultiplyLife { mult: Dist, mx: bool, my: bool, mz: bool },
    SizeScale { scale: Dist },
    SizeScaleBySpeed { ss: [f64; 2], ms: [f64; 2] },
    Color { col: Dist, alpha: Dist },
    ColorOverLife { col: Dist, alpha: Dist },
    ColorScaleOverLife { col: Dist, alpha: Dist, by_et: bool },
    VelocityCone { angle: Dist, vel: Dist, dir: Vector3, world: bool },
    Velocity { start: Dist, radial: Dist, world: bool },
    VelocityInheritParent { scale: Dist },
    VelocityOverLifetime { vol: Dist, absolute: bool, world: bool },
    AccelerationConstant { a: Vector3, always_world: bool },
    Acceleration { a: Dist, always_world: bool },
    AccelerationDrag { c: Dist },
    Location { start: Dist, world_offset: bool },
    Sphere { start: Dist, radius: Dist, pos: [bool; 3], neg: [bool; 3], surface: bool, velocity: bool, vscale: Dist },
    Cylinder { start: Dist, radius: Dist, height: Dist, surface: bool, axis: u8 },
    Rotation { r: Dist },
    RotationRate { r: Dist },
    MeshRotation { r: Dist, inherit: bool },
    MeshRotationRate { r: Dist },
    SubUv { idx: Dist },
    ParameterDynamic { flags: i64, params: Vec<DynParam> },
    CameraOffset { off: Dist, method: u8, spawn_only: bool },
    Collision { damp: Dist, damp_rot: Dist, max_coll: Dist, delay: Dist, max_dist: f64, dirscalar: f64, completion: u8 },
    LocationEmitter { name: String, inherit_vel: bool, vel_scale: f64, inherit_rot: bool, rot_scale: f64 },
    Light { color_scale: Dist, brightness: Dist, radius: Dist, exponent: Dist, inverse_sq: bool, spawn_fraction: f64, flags: u8 },
    Other,
}

#[derive(Clone)]
struct SpawnPerUnit {
    unit: f64,
    spu: Dist,
    ignore: [bool; 3],
    max_frame_dist: f64,
    tolerance: f64,
    ignore_rate_when_moving: bool,
    process_rate: bool,
    process_burst: bool,
}

#[derive(Clone)]
struct Receiver {
    gen_type: String,
    name: String,
    use_psys_loc: bool,
    inherit_vel: bool,
    vel_scale: Dist,
    count: Dist,
}

#[derive(Clone)]
struct Burst {
    count: i64,
    count_low: i64,
    time: f64,
}

#[derive(Clone, Default)]
struct GpuData {
    drag: Dist,
    acc: Vector3,
    drag_scale: f64,
    drag_bias: f64,
    col: Vec<f64>,
    col_sc: [f32; 4],
    col_bs: [f32; 4],
    misc: Vec<f64>,
    misc_sc: [f32; 4],
    misc_bs: [f32; 4],
    inv0: f64,
    inv1: f64,
    sbs: [f64; 4],
}

impl Default for Dist {
    fn default() -> Self {
        Dist::Null
    }
}

/// The emitter's Required-module settings it reads at run time.
#[derive(Clone, Default)]
struct Req {
    delay: f64,
    delay_low: f64,
    delay_range: bool,
    duration: f64,
    duration_low: f64,
    duration_range: bool,
    loops: i64,
    delay_first_loop_only: bool,
    legacy_time: bool,
    recalc_each_loop: bool,
    rotation: [f64; 3],
    origin: [f64; 3],
    uv_flip: u8,
    interp: u8, // 0 none, 1 linear, 2 linear blend, 3 random, 4 random blend
    sub_total: i64,
    random_image_time: f64,
    random_image_changes: i64,
}

pub struct Event {
    kind: &'static str,
    name: String,
    loc: Vector3,
    vel: Vector3,
}

/// Component state for one tick (UParticleSystemComponent), set by the GDScript node.
pub struct Ctx {
    pub rng: Rng,
    pub params: Rc<Params>,
    pub comp_basis: M3,
    pub comp_loc: Vector3,
    pub part_sys_velocity: Vector3,
    pub camera_ue: Vector3,
    pub just_registered: bool,
    pub events: Vec<Event>,
    pub space: Option<Gd<PhysicsDirectSpaceState3D>>,
    pub query: Option<Gd<PhysicsRayQueryParameters3D>>,
    pub world_mask: u32,
    /// UParticleSystemComponent::RandomStream (FRandomStream): UParticleModuleLight's SpawnFraction draw.
    pub stream: u32,
    /// The Light module's distribution draws (DI2 passes the module / component stream, not FMath::SRand): a PCG
    /// of its own, so the main sequence stays the GDScript simulation's.
    pub light_rng: Rng,
    /// r.ParticleLightQuality (UE 4.27 default 2: simple + high-quality lights; DI2's config doesn't set it).
    pub light_quality: i32,
}

impl Ctx {
    /// FRandomStream::GetFraction (MutateSeed: seed * 196314165 + 907633515).
    fn stream_fraction(&mut self) -> f32 {
        self.stream = self.stream.wrapping_mul(196314165).wrapping_add(907633515);
        f32::from_bits((self.stream >> 9) | 0x3f80_0000) - 1.0
    }

    fn inverse_rotate(&self, v: Vector3) -> Vector3 {
        self.comp_basis.inverse().xform(v)
    }
}

#[derive(Default, Clone)]
pub struct Emitter {
    pub name: String,
    pub kind: Kind,
    pub enabled: bool,
    local_space: bool,
    legacy_spawn: bool,
    mesh_rotation_active: bool,
    lock_mode: u8,
    align: Align,
    sort_mode: u8,
    pivot: Vector2,
    req: Req,
    rate: Dist,
    rate_scale: Dist,
    bursts: Vec<Burst>,
    burst_scale: Option<Dist>,
    mods: Rc<Vec<Mod>>,
    /// Seeded modules (UParticleModule*_Seeded): per module index, (initial seed, stream state, reset on looping).
    seeds: Vec<Option<(u32, u32, bool)>>,
    spawn_list: Vec<usize>,
    update_list: Vec<usize>,
    spawning: Vec<SpawnPerUnit>,
    receivers: Vec<Receiver>,
    event_gen: Vec<(String, String)>,
    has_event_gen: bool,
    gpu: Option<GpuData>,
    // time
    emitter_time: f64,
    seconds: f64,
    loop_count: i64,
    duration: f64,
    current_delay: f64,
    spawn_fraction: f64,
    burst_fired: Vec<bool>,
    location: Vector3,
    old_location: Vector3,
    e2s: Xf,
    s2w: Xf,
    spu_travel: f64,
    counter: i64,
    // particles (SoA)
    pub n: usize,
    pub loc: Vec<Vector3>,
    old_loc: Vec<Vector3>,
    base_vel: Vec<Vector3>,
    pub vel: Vec<Vector3>,
    base_size: Vec<Vector3>,
    pub size: Vec<Vector3>,
    pub rel: Vec<f32>,
    oomlt: Vec<f32>,
    pub rot: Vec<f32>,
    rot_rate: Vec<f32>,
    base_rot_rate: Vec<f32>,
    pub col: Vec<Color>,
    base_col: Vec<Color>,
    flags: Vec<i32>,
    pub dyn_: Vec<Color>,
    subuv: Vec<f32>,
    subuv_rt: Vec<f32>,
    minit: Vec<Vector3>,
    mrot: Vec<Vector3>,
    mcont: Vec<Vector3>,
    mrot_rate: Vec<Vector3>,
    mrot_rate_base: Vec<Vector3>,
    camoff: Vec<Vector2>,
    accel: Vec<Vector3>,
    coll_left: Vec<i32>,
    coll_damp: Vec<Vector3>,
    coll_damp_rot: Vec<Vector3>,
    coll_delay: Vec<f32>,
    gpu_drag: Vec<f32>,
    gpu_init: Vec<Color>,
    // FLightParticlePayload: ColorScale, RadiusScale, LightExponent, bValid
    light_cs: Vec<Vector3>,
    light_radius: Vec<f32>,
    light_exp: Vec<f32>,
    light_valid: Vec<u8>,
    pub light_flags: u8,
    pub has_light: bool,
    // render
    pub rid: Option<Rid>,
    pub time_in_w: bool,
    /// Created on the first fill: the cached templates (particles::TEMPLATES, a thread-local) must hold no Godot
    /// value, because the thread-local destructor runs after the engine is gone.
    pub buf: Option<PackedFloat32Array>,
}

impl Default for Xf {
    fn default() -> Self {
        Xf::IDENTITY
    }
}

fn sub_s(v: &Value, k: &str) -> String {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string()
}

impl Emitter {
    /// DI2Particles.Emitter._init + _gpu_lists (module lists of the LOD) + init_instance's constants.
    pub fn new(ed: &Value, lod: usize, engine: &Value) -> Emitter {
        let mut e = Emitter { name: js(ed, "name", "None").to_string(), ..Default::default() };
        let mut mods: Vec<Mod> = vec![];
        let mut seeds: Vec<Option<(u32, u32, bool)>> = vec![];
        static EMPTY: Vec<Value> = Vec::new();
        let mods_v: &Vec<Value> = ed.get("modules").and_then(|m| m.as_array()).unwrap_or(&EMPTY);
        e.legacy_spawn = jb(ed, "legacy_spawn", false);
        let lods: &Vec<Value> = ed.get("lods").and_then(|l| l.as_array()).unwrap_or(&EMPTY);
        let li = lod.min(lods.len().saturating_sub(1));
        let lod_d: &Value = lods.get(li).unwrap_or(&Value::Null);
        e.enabled = jb(lod_d, "enabled", true);
        let pick = |k: &str| -> &Value { lod_d.get(k).and_then(|x| x.as_u64()).and_then(|i| mods_v.get(i as usize)).unwrap_or(&Value::Null) };
        let req = pick("required");
        let spawn = pick("spawn");
        let type_mod = pick("type");
        let event_gen = pick("events");
        e.local_space = jb(&req, "bUseLocalSpace", false);
        e.kind = match js(&type_mod, "m", "") {
            "TypeDataMesh" => Kind::Mesh,
            "TypeDataGpu" => Kind::Gpu,
            "TypeDataRibbon" | "TypeDataBeam2" | "TypeDataAnimTrail" => Kind::None,
            _ => Kind::Sprite,
        };
        if js(ed, "render", "ERM_Normal") == "ERM_None" {
            e.kind = Kind::None;
        }
        // Required
        let er = jv3_f64(req.get("EmitterRotation"));
        let eo = jv3_f64(req.get("EmitterOrigin"));
        e.req = Req {
            delay: jf(&req, "EmitterDelay", 0.0),
            delay_low: jf(&req, "EmitterDelayLow", 0.0),
            delay_range: jb(&req, "bEmitterDelayUseRange", false),
            duration: jf(&req, "EmitterDuration", 1.0),
            duration_low: jf(&req, "EmitterDurationLow", 0.0),
            duration_range: jb(&req, "bEmitterDurationUseRange", false),
            loops: ji(&req, "EmitterLoops", 0),
            delay_first_loop_only: jb(&req, "bDelayFirstLoopOnly", false),
            legacy_time: jb(&req, "bUseLegacyEmitterTime", true),
            recalc_each_loop: jb(&req, "bDurationRecalcEachLoop", false),
            rotation: er,
            origin: eo,
            uv_flip: match js(&req, "UVFlippingMode", "EParticleUVFlipMode::None") {
                "EParticleUVFlipMode::FlipUV" => 1,
                "EParticleUVFlipMode::FlipUOnly" => 2,
                "EParticleUVFlipMode::FlipVOnly" => 3,
                "EParticleUVFlipMode::RandomFlipUV" => 4,
                "EParticleUVFlipMode::RandomFlipUOnly" => 5,
                "EParticleUVFlipMode::RandomFlipVOnly" => 6,
                "EParticleUVFlipMode::RandomFlipUVIndependent" => 7,
                _ => 0,
            },
            interp: match js(&req, "InterpolationMethod", "PSUVIM_None") {
                "PSUVIM_Linear" => 1,
                "PSUVIM_Linear_Blend" => 2,
                "PSUVIM_Random" => 3,
                "PSUVIM_Random_Blend" => 4,
                _ => 0,
            },
            sub_total: ji(&req, "SubImages_Horizontal", 1) * ji(&req, "SubImages_Vertical", 1),
            random_image_time: jf(&req, "RandomImageTime", 1.0),
            random_image_changes: ji(&req, "RandomImageChanges", 0),
        };
        e.align = match js(&req, "ScreenAlignment", "PSA_Square") {
            "PSA_Square" => Align::Square,
            "PSA_Rectangle" => Align::Rectangle,
            "PSA_Velocity" => Align::Velocity,
            "PSA_FacingCameraPosition" => Align::FacingCameraPos,
            _ => Align::Other,
        };
        e.sort_mode = match js(&req, "SortMode", "PSORTMODE_None") {
            "PSORTMODE_Age_NewestFirst" => 1,
            "PSORTMODE_Age_OldestFirst" => 2,
            "PSORTMODE_DistanceToView" | "PSORTMODE_ViewProjDepth" => 3,
            _ => 0,
        };
        e.pivot = Vector2::new(-0.5, -0.5);
        // Spawn module
        e.rate = Dist::from_json(spawn.get("Rate"));
        e.rate_scale = Dist::from_json(spawn.get("RateScale"));
        e.bursts = spawn
            .get("BurstList")
            .and_then(|b| b.as_array())
            .map(|a| a.iter().map(|b| Burst { count: ji(b, "Count", 0), count_low: ji(b, "CountLow", -1), time: jf(b, "Time", 0.0) }).collect())
            .unwrap_or_default();
        e.burst_scale = spawn.get("BurstScale").map(|d| Dist::from_json(Some(d)));
        // Event generator
        if !event_gen.is_null() && event_gen.as_object().map(|o| !o.is_empty()).unwrap_or(false) {
            e.has_event_gen = true;
            if let Some(evs) = event_gen.get("Events").and_then(|x| x.as_array()) {
                for ev in evs {
                    e.event_gen.push((js(ev, "Type", "EPET_Spawn").to_string(), js(ev, "CustomName", "None").to_string()));
                }
            }
        }
        // Module lists
        let lod_mods: Vec<usize> = lod_d.get("modules").and_then(|m| m.as_array()).map(|a| a.iter().filter_map(|x| x.as_u64().map(|i| i as usize)).collect()).unwrap_or_default();
        let eng = |cls: &str, k: &str| engine.get(cls).and_then(|c| c.get(k)).and_then(|x| x.as_bool()).unwrap_or(false);
        let mut lock_axis = "EPAL_NONE".to_string();
        if e.kind == Kind::Gpu {
            // _gpu_lists
            for &mi in &lod_mods {
                let m = &mods_v[mi];
                if !jb(m, "bEnabled", true) {
                    continue;
                }
                match js(m, "m", "") {
                    "SpawnPerUnit" => e.spawning.push(spawn_per_unit(m)),
                    "EventReceiverSpawn" => e.receivers.push(receiver(m)),
                    _ => {}
                }
            }
            let info = type_mod.get("EmitterInfo").cloned().unwrap_or(Value::Null);
            let names: Vec<String> = info.get("SpawnModules").and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect()).unwrap_or_default();
            let mut used: Vec<usize> = vec![];
            for nm in names {
                let base = match nm.rfind('_') {
                    Some(p) => nm[..p].to_string(),
                    None => nm.clone(),
                };
                let cls = base.strip_prefix("ParticleModule").unwrap_or(&base).to_string();
                for &mi in &lod_mods {
                    let m = &mods_v[mi];
                    let mt = js(m, "m", "");
                    let base_t = mt.strip_suffix("_Seeded").unwrap_or(mt);
                    if mt == cls && jb(m, "bEnabled", true) && !used.contains(&mi) && (eng(&cls, "spawn") || eng(base_t, "spawn")) {
                        used.push(mi);
                        mods.push(build_mod(m));
                        seeds.push(seed_info(m));
                        e.spawn_list.push(mods.len() - 1);
                        break;
                    }
                }
            }
            let rd = type_mod.get("ResourceData").cloned().unwrap_or(Value::Null);
            let samples = |k: &str| -> Vec<f64> {
                rd.get(k).and_then(|x| x.as_array()).map(|a| a.iter().flat_map(|s| [jf(s, "R", 0.0), jf(s, "G", 0.0), jf(s, "B", 0.0), jf(s, "A", 0.0)]).collect()).unwrap_or_default()
            };
            let v4 = |k: &str, d: [f32; 4]| -> [f32; 4] {
                match rd.get(k) {
                    Some(x) if x.is_object() => [jf(x, "X", 0.0) as f32, jf(x, "Y", 0.0) as f32, jf(x, "Z", 0.0) as f32, jf(x, "W", 0.0) as f32],
                    _ => d,
                }
            };
            let inv = info.get("InvMaxSize").and_then(|x| x.as_array()).cloned().unwrap_or_default();
            let sbs = rd.get("SizeBySpeed").cloned().unwrap_or(serde_json::json!({"X": 0, "Y": 0, "Z": 1, "W": 1}));
            e.gpu = Some(GpuData {
                drag: Dist::from_json(info.get("DragCoefficient")),
                acc: jv3(rd.get("ConstantAcceleration"), [0.0; 3]),
                drag_scale: jf(&rd, "DragCoefficientScale", 0.0),
                drag_bias: jf(&rd, "DragCoefficientBias", 0.0),
                col: samples("QuantizedColorSamples"),
                col_sc: v4("ColorScale", [1.0; 4]),
                col_bs: v4("ColorBias", [0.0; 4]),
                misc: samples("QuantizedMiscSamples"),
                misc_sc: v4("MiscScale", [1.0; 4]),
                misc_bs: v4("MiscBias", [0.0; 4]),
                inv0: inv.first().and_then(|x| x.as_f64()).unwrap_or(1.0),
                inv1: inv.get(1).and_then(|x| x.as_f64()).unwrap_or(1.0),
                sbs: [jf(&sbs, "X", 0.0), jf(&sbs, "Y", 0.0), jf(&sbs, "Z", 1.0), jf(&sbs, "W", 1.0)],
            });
        } else {
            for &mi in &lod_mods {
                let m = &mods_v[mi];
                if !jb(m, "bEnabled", true) {
                    continue;
                }
                let t = js(m, "m", "");
                let base_t = t.strip_suffix("_Seeded").unwrap_or(t);
                let (sp, up) = (eng(t, "spawn") || eng(base_t, "spawn"), eng(t, "update") || eng(base_t, "update"));
                if sp || up {
                    mods.push(build_mod(m));
                    seeds.push(seed_info(m));
                    let k = mods.len() - 1;
                    if sp {
                        e.spawn_list.push(k);
                    }
                    if up {
                        e.update_list.push(k);
                    }
                }
                match t {
                    "SpawnPerUnit" => e.spawning.push(spawn_per_unit(m)),
                    "EventReceiverSpawn" => e.receivers.push(receiver(m)),
                    "MeshRotation" | "MeshRotationRate" => e.mesh_rotation_active = true,
                    "OrientationAxisLock" => lock_axis = js(m, "LockAxisFlags", "EPAL_NONE").to_string(),
                    "PivotOffset" => {
                        let po = m.get("PivotOffset").and_then(|x| x.as_array()).cloned().unwrap_or_default();
                        let px = po.first().and_then(|x| x.as_f64()).unwrap_or(0.0);
                        let py = po.get(1).and_then(|x| x.as_f64()).unwrap_or(0.0);
                        e.pivot = Vector2::new((px as f32) - 0.5, (py as f32) - 0.5);
                    }
                    _ => {}
                }
            }
        }
        e.has_light = mods.iter().any(|m| matches!(m, Mod::Light { .. }));
        e.light_flags = mods.iter().find_map(|m| if let Mod::Light { flags, .. } = m { Some(*flags) } else { None }).unwrap_or(0);
        e.mods = Rc::new(mods);
        e.seeds = seeds;
        e.lock_mode = match lock_axis.as_str() {
            "EPAL_ROTATE_X" => 1,
            "EPAL_ROTATE_Y" => 2,
            "EPAL_ROTATE_Z" => 3,
            _ => 0,
        };
        e
    }

    /// init_instance (without the renderer, which the GDScript node owns)
    pub fn init_instance(&mut self, ctx: &mut Ctx) {
        self.location = ctx.comp_loc;
        self.old_location = self.location;
        self.update_transforms(ctx);
        self.burst_fired = vec![false; self.bursts.len()];
        self.setup_duration(ctx);
    }

    fn setup_duration(&mut self, ctx: &mut Ctx) {
        let r = &self.req;
        self.current_delay = r.delay;
        if r.delay_range {
            self.current_delay = r.delay_low + (r.delay - r.delay_low) * ctx.rng.randf();
        }
        let mut d = r.duration;
        if r.duration_range {
            d = r.duration_low + (d - r.duration_low) * ctx.rng.randf();
        }
        self.duration = d + self.current_delay;
        let loops = r.loops;
        if self.loop_count == 1 && r.delay_first_loop_only && (loops == 0 || loops > 1) {
            self.duration -= self.current_delay;
        }
    }

    fn update_transforms(&mut self, ctx: &Ctx) {
        let er = self.req.rotation;
        let eo = self.req.origin;
        let e2c = Xf { b: rotator_basis_ue(er[0], er[1], er[2]), o: v3(eo[0], eo[1], eo[2]) };
        let c2w = Xf { b: ctx.comp_basis, o: ctx.comp_loc };
        if self.local_space {
            self.e2s = e2c;
            self.s2w = c2w;
        } else {
            self.e2s = c2w.mul(&e2c);
            self.s2w = Xf::IDENTITY;
        }
    }

    pub fn has_completed(&self) -> bool {
        if !self.enabled {
            return true;
        }
        let loops = self.req.loops;
        if loops == 0 || self.seconds < self.duration * loops as f64 {
            return false;
        }
        self.n == 0
    }

    // --- tick -------------------------------------------------------------------------------------------------

    pub fn tick(&mut self, dt: f64, ctx: &mut Ctx, others: &[Emitter]) {
        let first = self.seconds <= 0.0;
        if ctx.just_registered {
            self.location = ctx.comp_loc;
            self.old_location = self.location;
        } else {
            self.old_location = self.location;
            self.location = ctx.comp_loc;
        }
        self.update_transforms(ctx);
        self.seconds += dt;
        let mut looped = false;
        if !self.req.legacy_time {
            self.emitter_time += dt;
            looped = self.duration > 0.0 && self.emitter_time >= self.duration;
        } else {
            self.emitter_time = self.seconds;
            if self.duration > 1e-4 {
                self.emitter_time = self.seconds % self.duration;
                looped = (self.seconds - self.duration * self.loop_count as f64) >= self.duration;
            }
        }
        let mut delay = self.current_delay;
        if looped {
            self.loop_count += 1;
            // EmitterLoopingNotify: seeded modules with bResetSeedOnEmitterLooping restart their stream
            for s in self.seeds.iter_mut().flatten() {
                if s.2 {
                    s.1 = s.0;
                }
            }
            for b in self.burst_fired.iter_mut() {
                *b = false;
            }
            if !self.req.legacy_time {
                self.emitter_time -= self.duration;
            }
            if self.req.recalc_each_loop || (self.req.delay_first_loop_only && self.loop_count == 1) {
                self.setup_duration(ctx);
            }
        }
        if self.req.delay_first_loop_only && self.loop_count > 0 {
            delay = 0.0;
        }
        self.emitter_time -= delay;
        if !self.enabled {
            self.emitter_time += delay;
            return;
        }
        if self.kind == Kind::Mesh && self.mesh_rotation_active {
            self.mesh_pre_tick();
        }
        self.kill_particles(ctx);
        self.reset_particle_parameters(dt);
        if self.kind == Kind::Gpu {
            self.gpu_update(dt);
        } else {
            for k in 0..self.update_list.len() {
                let mi = self.update_list[k];
                self.update_module(mi, dt, ctx);
            }
        }
        let loops = self.req.loops;
        if self.emitter_time >= 0.0 && (loops == 0 || self.loop_count < loops || self.seconds < self.duration * loops as f64 || first) {
            self.spawn_fraction = self.spawn(dt, ctx, others);
        }
        if self.n > 0 {
            self.integrate(dt);
        }
        if self.kind == Kind::Mesh && self.mesh_rotation_active {
            for i in 0..self.n {
                self.mcont[i] = vadd(self.mcont[i], vmul(self.mrot_rate[i], dt));
            }
        }
        self.emitter_time += delay;
    }

    fn mesh_pre_tick(&mut self) {
        let by_vel = self.align == Align::Velocity;
        let away = false; // PSA_AwayFromCenter: not used by the hit set (Align::Other)
        for i in 0..self.n {
            self.mrot_rate[i] = self.mrot_rate_base[i];
            if by_vel || away {
                let mut d = if by_vel { self.vel[i] } else { self.loc[i] };
                d = if vlen_sq(d) > 1e-8 { vnorm(d) } else { d };
                let e = quat_euler_ue(find_between_normals_ue(Vector3::new(1.0, 0.0, 0.0), d));
                self.mrot[i] = vadd(vadd(self.minit[i], e), self.mcont[i]);
            } else if (self.flags[i] & F_FREEZE_ROTATION) == 0 {
                self.mrot[i] = vadd(self.minit[i], self.mcont[i]);
            }
        }
    }

    fn add_particle(&mut self) -> usize {
        let i = self.n;
        if self.loc.len() <= i {
            self.loc.push(Vector3::ZERO);
            self.old_loc.push(Vector3::ZERO);
            self.base_vel.push(Vector3::ZERO);
            self.vel.push(Vector3::ZERO);
            self.base_size.push(Vector3::ZERO);
            self.size.push(Vector3::ZERO);
            self.rel.push(0.0);
            self.oomlt.push(0.0);
            self.rot.push(0.0);
            self.rot_rate.push(0.0);
            self.base_rot_rate.push(0.0);
            self.col.push(Color::from_rgba(0.0, 0.0, 0.0, 0.0));
            self.base_col.push(Color::from_rgba(0.0, 0.0, 0.0, 0.0));
            self.flags.push(0);
            self.dyn_.push(Color::from_rgba(1.0, 1.0, 1.0, 1.0));
            self.subuv.push(0.0);
            self.subuv_rt.push(0.0);
            self.mrot.push(Vector3::ZERO);
            self.mrot_rate.push(Vector3::ZERO);
            self.mrot_rate_base.push(Vector3::ZERO);
            self.minit.push(Vector3::ZERO);
            self.mcont.push(Vector3::ZERO);
            self.camoff.push(Vector2::ZERO);
            self.accel.push(Vector3::ZERO);
            self.coll_left.push(0);
            self.coll_damp.push(Vector3::ONE);
            self.coll_damp_rot.push(Vector3::ONE);
            self.coll_delay.push(0.0);
            self.gpu_drag.push(0.0);
            self.gpu_init.push(Color::from_rgba(0.0, 0.0, 0.0, 0.0));
            self.light_cs.push(Vector3::ZERO);
            self.light_radius.push(0.0);
            self.light_exp.push(0.0);
            self.light_valid.push(0);
        }
        self.n += 1;
        i
    }

    fn swap(&mut self, a: usize, b: usize) {
        self.loc.swap(a, b);
        self.old_loc.swap(a, b);
        self.base_vel.swap(a, b);
        self.vel.swap(a, b);
        self.base_size.swap(a, b);
        self.size.swap(a, b);
        self.rel.swap(a, b);
        self.oomlt.swap(a, b);
        self.rot.swap(a, b);
        self.rot_rate.swap(a, b);
        self.base_rot_rate.swap(a, b);
        self.col.swap(a, b);
        self.base_col.swap(a, b);
        self.flags.swap(a, b);
        self.dyn_.swap(a, b);
        self.subuv.swap(a, b);
        self.subuv_rt.swap(a, b);
        self.minit.swap(a, b);
        self.mrot.swap(a, b);
        self.mcont.swap(a, b);
        self.mrot_rate.swap(a, b);
        self.mrot_rate_base.swap(a, b);
        self.camoff.swap(a, b);
        self.accel.swap(a, b);
        self.coll_left.swap(a, b);
        self.coll_damp.swap(a, b);
        self.coll_damp_rot.swap(a, b);
        self.coll_delay.swap(a, b);
        self.gpu_drag.swap(a, b);
        self.gpu_init.swap(a, b);
        self.light_cs.swap(a, b);
        self.light_radius.swap(a, b);
        self.light_exp.swap(a, b);
        self.light_valid.swap(a, b);
    }

    fn kill(&mut self, i: usize) {
        self.n -= 1;
        if i != self.n {
            self.swap(i, self.n);
        }
    }

    fn kill_particles(&mut self, ctx: &mut Ctx) {
        let mut i = self.n as i64 - 1;
        while i >= 0 {
            let iu = i as usize;
            if self.rel[iu] > 1.0 {
                self.report(iu, "EPET_Death", ctx);
                self.kill(iu);
            }
            i -= 1;
        }
    }

    fn reset_particle_parameters(&mut self, dt: f64) {
        for i in 0..self.n {
            self.vel[i] = self.base_vel[i];
            self.size[i] = vabs(self.base_size[i]);
            self.rot_rate[i] = self.base_rot_rate[i];
            self.col[i] = self.base_col[i];
            let js = (self.flags[i] & F_JUST_SPAWNED) != 0;
            if !(js && !self.legacy_spawn) {
                self.rel[i] = (self.rel[i] as f64 + self.oomlt[i] as f64 * dt) as f32;
            }
            self.camoff[i].y = self.camoff[i].x;
        }
    }

    fn integrate(&mut self, dt: f64) {
        for i in 0..self.n {
            self.old_loc[i] = self.loc[i];
            let js = (self.flags[i] & F_JUST_SPAWNED) != 0;
            self.flags[i] &= !F_JUST_SPAWNED;
            if (self.flags[i] & F_FREEZE) != 0 || (js && !self.legacy_spawn) {
                continue;
            }
            if (self.flags[i] & F_FREEZE_TRANSLATION) == 0 {
                self.loc[i] = vadd(self.loc[i], vmul(self.vel[i], dt));
            }
            if (self.flags[i] & F_FREEZE_ROTATION) == 0 {
                self.rot[i] = ((self.rot[i] as f64 + self.rot_rate[i] as f64 * dt) % TAU) as f32;
            }
        }
    }

    // --- spawn ------------------------------------------------------------------------------------------------

    fn spawn(&mut self, dt: f64, ctx: &mut Ctx, others: &[Emitter]) -> f64 {
        let mut spawn_rate = 0.0f64;
        let mut burst: i64 = 0;
        let old_left = self.spawn_fraction;
        let mut process_rate = true;
        let mut process_burst = true;
        for k in 0..self.spawning.len() {
            let (_number, rate, pr) = self.spawn_per_unit(k, dt, ctx);
            spawn_rate += rate.max(0.0);
            if !pr {
                process_rate = false;
            }
            if !self.spawning[k].process_burst {
                process_burst = false;
            }
        }
        if process_rate {
            let rs = self.rate_scale.f(self.emitter_time, &mut ctx.rng, &ctx.params);
            let rate = self.rate.f(self.emitter_time, &mut ctx.rng, &ctx.params);
            spawn_rate += rate * clamp_g(rs, 0.0, rs);
        }
        if process_burst {
            burst += self.burst_count(ctx);
        }
        spawn_rate = spawn_rate.max(0.0);
        if spawn_rate > 0.0 || burst > 0 {
            let mut new_left = old_left + dt * spawn_rate;
            let number = new_left.floor() as i64;
            let inc = if spawn_rate > 0.0 { 1.0 / spawn_rate } else { 0.0 };
            let start = dt + old_left * inc - inc;
            new_left -= number as f64;
            let init = self.e2s.o;
            self.spawn_particles(number, start, inc, init, Vector3::ZERO, ctx, others);
            self.spawn_particles(burst, 0.0, 0.0, init, Vector3::ZERO, ctx, others);
            return new_left;
        }
        self.spawn_fraction
    }

    fn burst_count(&mut self, ctx: &mut Ctx) -> i64 {
        let mut total: i64 = 0;
        for k in 0..self.bursts.len() {
            if self.burst_fired[k] {
                continue;
            }
            let b = self.bursts[k].clone();
            if self.emitter_time >= b.time {
                let mut c = b.count;
                if b.count_low > -1 {
                    c = b.count_low + (ctx.rng.randf() * (c - b.count_low) as f64).round() as i64;
                }
                total += c;
                self.burst_fired[k] = true;
            }
        }
        if total > 0 {
            if let Some(bs) = &self.burst_scale {
                total = (total as f64 * bs.f(self.emitter_time, &mut ctx.rng, &ctx.params)).ceil() as i64;
            }
        }
        total
    }

    fn spawn_per_unit(&mut self, k: usize, dt: f64, ctx: &mut Ctx) -> (i64, f64, bool) {
        let m = self.spawning[k].clone();
        let ppu = m.spu.f(self.emitter_time, &mut ctx.rng, &ctx.params) / m.unit;
        let mut number: i64 = 0;
        let mut rate = 0.0;
        let mut moved = false;
        if ppu >= 0.0 {
            let mut tv = vsub(self.location, self.old_location);
            if m.ignore[0] {
                tv.x = 0.0;
            }
            if m.ignore[1] {
                tv.y = 0.0;
            }
            if m.ignore[2] {
                tv.z = 0.0;
            }
            let mut dist = vlen(tv) as f64;
            if (m.max_frame_dist > 0.0 && dist > m.max_frame_dist) || dist > 1048576.0 {
                dist = 0.0;
                self.spu_travel = 0.0;
            }
            if dist > 0.0 {
                if dist > m.tolerance * m.unit {
                    moved = true;
                }
                let nl = (dist + self.spu_travel) * ppu;
                number = nl.floor() as i64;
                rate = number as f64 / dt;
                self.spu_travel = ((dist + self.spu_travel) - number as f64 * m.unit).max(0.0);
            }
        }
        if m.ignore_rate_when_moving {
            return (number, rate, !moved);
        }
        (number, rate, m.process_rate)
    }

    #[allow(clippy::too_many_arguments)]
    fn spawn_particles(&mut self, count: i64, start: f64, inc: f64, init_loc: Vector3, init_vel: Vector3, ctx: &mut Ctx, others: &[Emitter]) {
        let count = count.min(MAX_PARTICLES_PER_EMITTER as i64 - self.n as i64);
        let mut st = start;
        let mut interp = 1.0f64;
        let interp_inc = if count > 0 && inc > 0.0 { 1.0 / count as f64 } else { 0.0 };
        for _ in 0..count.max(0) {
            let i = self.add_particle();
            if self.legacy_spawn {
                st -= inc;
                interp -= interp_inc;
            }
            self.pre_spawn(i, init_loc, init_vel);
            if self.kind == Kind::Gpu {
                self.gpu_spawn(i, st, ctx, others);
            } else {
                for k in 0..self.spawn_list.len() {
                    let mi = self.spawn_list[k];
                    self.spawn_module(mi, i, st, ctx, others);
                }
            }
            self.post_spawn(i, interp, st);
            if self.rel[i] > 1.0 {
                self.kill(i);
                continue;
            }
            self.report(i, "EPET_Spawn", ctx);
            if !self.legacy_spawn {
                st -= inc;
                interp -= interp_inc;
            }
        }
    }

    fn pre_spawn(&mut self, i: usize, init_loc: Vector3, init_vel: Vector3) {
        self.loc[i] = init_loc;
        self.old_loc[i] = init_loc;
        self.base_vel[i] = init_vel;
        self.vel[i] = init_vel;
        self.base_size[i] = Vector3::ZERO;
        self.size[i] = Vector3::ZERO;
        self.rel[i] = 0.0;
        self.oomlt[i] = 0.0;
        self.rot[i] = 0.0;
        self.rot_rate[i] = 0.0;
        self.base_rot_rate[i] = 0.0;
        self.col[i] = Color::from_rgba(0.0, 0.0, 0.0, 0.0);
        self.base_col[i] = Color::from_rgba(0.0, 0.0, 0.0, 0.0);
        self.flags[i] = 0;
        self.dyn_[i] = Color::from_rgba(1.0, 1.0, 1.0, 1.0);
        self.subuv[i] = 0.0;
        self.subuv_rt[i] = 0.0;
        self.mrot[i] = Vector3::ZERO;
        self.mrot_rate[i] = Vector3::ZERO;
        self.mrot_rate_base[i] = Vector3::ZERO;
        self.minit[i] = Vector3::ZERO;
        self.mcont[i] = Vector3::ZERO;
        self.camoff[i] = Vector2::ZERO;
        self.accel[i] = Vector3::ZERO;
        self.coll_left[i] = 0;
        self.coll_damp[i] = Vector3::ONE;
        self.coll_damp_rot[i] = Vector3::ONE;
        self.coll_delay[i] = 0.0;
        self.gpu_drag[i] = 0.0;
        self.gpu_init[i] = Color::from_rgba(0.0, 0.0, 0.0, 0.0);
        self.light_cs[i] = Vector3::ZERO;
        self.light_radius[i] = 0.0;
        self.light_exp[i] = 0.0;
        self.light_valid[i] = 0;
    }

    fn post_spawn(&mut self, i: usize, interp: f64, st: f64) {
        if !self.local_space && vlen_sq(vsub(self.location, self.old_location)) > 1.0 {
            self.loc[i] = vadd(self.loc[i], vmul(vsub(self.old_location, self.location), interp));
        }
        self.old_loc[i] = self.loc[i];
        self.loc[i] = vadd(self.loc[i], vmul(self.vel[i], st));
        self.flags[i] |= ((self.counter & 0x00FF_FFFF) as i32) | F_JUST_SPAWNED;
        self.counter += 1;
    }

    fn accel_vec(&self, always_world: bool, a: Vector3, ctx: &Ctx) -> Vector3 {
        if self.local_space {
            if always_world {
                return ctx.inverse_rotate(a);
            }
            return self.e2s.b.xform(a);
        }
        a
    }

    fn spawn_module(&mut self, mi: usize, i: usize, st: f64, ctx: &mut Ctx, others: &[Emitter]) {
        let et = self.emitter_time;
        let mods = self.mods.clone();
        let m = &mods[mi];
        let pm_rc = ctx.params.clone();
        let pm: &Params = &pm_rc;
        let seeded = self.seeds.get(mi).copied().flatten();
        let mut ss = SeedStream(seeded.map(|s| s.1).unwrap_or(0));
        let r = &mut ctx.rng;
        match m {
            Mod::Lifetime { life } => {
                let rr: &mut dyn RandSrc = if seeded.is_some() { &mut ss } else { r };
                let life = life.f(et, rr, pm);
                if self.oomlt[i] > 0.0 {
                    self.oomlt[i] = (1.0 / (1.0 / self.oomlt[i] as f64 + life)) as f32;
                } else {
                    self.oomlt[i] = if life > 0.0 { (1.0 / life) as f32 } else { 0.0 };
                }
                if self.rel[i] <= 1.0 {
                    self.rel[i] = (self.oomlt[i] as f64 * st) as f32;
                }
            }
            Mod::Size { start } => {
                let rr: &mut dyn RandSrc = if seeded.is_some() { &mut ss } else { r };
                let s = start.v(et, rr, pm);
                self.size[i] = vadd(self.size[i], s);
                let mut f = s;
                match self.req.uv_flip {
                    1 => f = vneg(s),
                    2 => f.x = -s.x,
                    3 => f.y = -s.y,
                    4 => {
                        if rr.frac() > 0.5 {
                            f = vneg(s)
                        }
                    }
                    5 => {
                        if rr.frac() > 0.5 {
                            f.x = -s.x
                        }
                    }
                    6 => {
                        if rr.frac() > 0.5 {
                            f.y = -s.y
                        }
                    }
                    7 => {
                        if rr.frac() > 0.5 {
                            f.x = -s.x
                        }
                        if rr.frac() > 0.5 {
                            f.y = -s.y
                        }
                    }
                    _ => {}
                }
                self.base_size[i] = vadd(self.base_size[i], f);
            }
            Mod::SizeMultiplyLife { mult, mx, my, mz } => {
                let s = mult.v(self.rel[i] as f64, r, pm);
                let mut z = self.size[i];
                if *mx {
                    z.x *= s.x;
                }
                if *my {
                    z.y *= s.y;
                }
                if *mz {
                    z.z *= s.z;
                }
                self.size[i] = z;
            }
            Mod::SizeScale { scale } => {
                self.size[i] = vmulv(vabs(self.base_size[i]), scale.v(self.rel[i] as f64, r, pm));
            }
            Mod::Color { col, alpha } => {
                let c = col.v(et, r, pm);
                let a = alpha.f(et, r, pm);
                self.col[i] = Color::from_rgba(c.x, c.y, c.z, a as f32);
                self.base_col[i] = self.col[i];
            }
            Mod::ColorOverLife { col, alpha } => {
                let t = self.rel[i] as f64;
                let c = col.v(t, r, pm);
                let a = alpha.f(t, r, pm);
                self.col[i] = Color::from_rgba(c.x, c.y, c.z, a as f32);
                self.base_col[i] = self.col[i];
            }
            Mod::ColorScaleOverLife { col, alpha, by_et } => {
                let t = if *by_et { et } else { self.rel[i] as f64 };
                let c = col.v(t, r, pm);
                let a = alpha.f(t, r, pm);
                let k = self.col[i];
                self.col[i] = Color::from_rgba(k.r * c.x, k.g * c.y, k.b * c.z, (k.a as f64 * a) as f32);
            }
            Mod::VelocityCone { angle, vel, dir, world } => {
                let ang = angle.f(et, r, pm);
                let spd = vel.f(et, r, pm);
                let pitch = ((ang * 182.03784) as i64) as f64;
                let yaw = ((r.randf() * 65533.625) as i64) as f64;
                let dsd = rotator_basis_ue(pitch, yaw, 0.0).col(2);
                let mut fwd = *dir;
                fwd = if vlen_sq(fwd) >= 1e-8 { vnorm(fwd) } else { Vector3::new(0.0, 0.0, 1.0) };
                let mut up = Vector3::new(0.0, 0.0, 1.0);
                let mut right = Vector3::new(1.0, 0.0, 0.0);
                if fwd != up && vneg(fwd) != up {
                    right = vcross(up, fwd);
                    up = vcross(fwd, right);
                } else {
                    up = vcross(fwd, right);
                    right = vcross(up, fwd);
                }
                right = vnorm(right);
                up = vnorm(up);
                let mut sdir = vadd(vadd(vmul(right, dsd.x as f64), vmul(up, dsd.y as f64)), vmul(fwd, dsd.z as f64));
                if !self.local_space && !*world {
                    sdir = ctx.comp_basis.xform(sdir);
                } else if self.local_space && *world {
                    sdir = ctx.inverse_rotate(sdir);
                }
                let v = vmul(sdir, spd);
                self.vel[i] = vadd(self.vel[i], v);
                self.base_vel[i] = vadd(self.base_vel[i], v);
            }
            Mod::Velocity { start, radial, world } => {
                let rr: &mut dyn RandSrc = if seeded.is_some() { &mut ss } else { r };
                let mut v = start.v(et, rr, pm);
                let rad = radial.f(et, rr, pm);
                let mut from_origin = vsub(self.loc[i], self.e2s.o);
                from_origin = if vlen_sq(from_origin) > 1e-8 { vnorm(from_origin) } else { Vector3::ZERO };
                if self.local_space {
                    v = if *world { ctx.inverse_rotate(v) } else { self.e2s.b.xform(v) };
                } else if !*world {
                    v = self.e2s.b.xform(v);
                }
                v = vadd(v, vmul(from_origin, rad));
                self.vel[i] = vadd(self.vel[i], v);
                self.base_vel[i] = vadd(self.base_vel[i], v);
            }
            Mod::VelocityInheritParent { scale } => {
                let mut pv = ctx.part_sys_velocity;
                if self.local_space {
                    pv = ctx.comp_basis.inverse().xform(pv);
                }
                let sc = scale.v(et, r, pm);
                let dvv = vmulv(pv, sc);
                self.vel[i] = vadd(self.vel[i], dvv);
                self.base_vel[i] = vadd(self.base_vel[i], dvv);
            }
            Mod::AccelerationConstant { a, always_world } => {
                let a = self.accel_vec(*always_world, *a, ctx);
                self.vel[i] = vadd(self.vel[i], vmul(a, st));
                self.base_vel[i] = vadd(self.base_vel[i], vmul(a, st));
            }
            Mod::Acceleration { a, always_world } => {
                let av = a.v(et, r, pm);
                let a = self.accel_vec(*always_world, av, ctx);
                self.accel[i] = a;
                self.vel[i] = vadd(self.vel[i], vmul(a, st));
                self.base_vel[i] = vadd(self.base_vel[i], vmul(a, st));
            }
            Mod::Location { start, world_offset } => {
                let o = start.v(et, r, pm);
                if *world_offset {
                    let d = if self.local_space { ctx.inverse_rotate(o) } else { o };
                    self.loc[i] = vadd(self.loc[i], d);
                } else {
                    self.loc[i] = vadd(self.loc[i], self.e2s.b.xform(o));
                }
            }
            Mod::Sphere { start, radius, pos, neg, surface, velocity, vscale } => {
                let start = start.v(et, r, pm);
                let ax = |k: usize, rv: f64| -> f64 {
                    if pos[k] && neg[k] {
                        rv * 2.0 - 1.0
                    } else if pos[k] {
                        rv
                    } else if neg[k] {
                        -rv
                    } else {
                        0.0
                    }
                };
                let r0 = r.randf();
                let r1 = r.randf();
                let r2 = r.randf();
                let mut u = v3(ax(0, r0), ax(1, r1), ax(2, r2));
                let nd = if vlen_sq(u) > 1e-8 { vnorm(u) } else { u };
                if *surface && vlen_sq(u) > 1e-8 {
                    u = vnorm(u);
                }
                let rad = radius.f(et, r, pm);
                let mx = vmul(vabs(nd), rad);
                let o = vmul(u, rad);
                let mut res = Vector3::ZERO;
                for k in 0..3 {
                    if pos[k] || neg[k] {
                        let m = comp(mx, k) as f64;
                        set_comp(&mut res, k, clamp_g(comp(o, k) as f64, -m, m) as f32);
                    }
                }
                res = vadd(res, start);
                self.loc[i] = vadd(self.loc[i], self.e2s.b.xform(res));
                if *velocity {
                    let v = self.e2s.b.xform(vmul(vsub(res, start), vscale.f(et, &mut ctx.rng, pm)));
                    self.vel[i] = vadd(self.vel[i], v);
                    self.base_vel[i] = vadd(self.base_vel[i], v);
                }
            }
            Mod::Cylinder { start, radius, height, surface, axis } => {
                let start = start.v(et, r, pm);
                let rad = radius.f(et, r, pm);
                let h = height.f(et, r, pm);
                let a = r.randf() * TAU;
                let d = if !*surface { r.randf() } else { 1.0 };
                let z = (r.randf() - 0.5) * h;
                let mut o = v3(a.cos() * rad * d, a.sin() * rad * d, z);
                match axis {
                    1 => o = Vector3::new(o.z, o.x, o.y),
                    2 => o = Vector3::new(o.x, o.z, o.y),
                    _ => {}
                }
                self.loc[i] = vadd(self.loc[i], self.e2s.b.xform(vadd(o, start)));
            }
            Mod::Rotation { r: d } => {
                let rr: &mut dyn RandSrc = if seeded.is_some() { &mut ss } else { r };
                self.rot[i] = (self.rot[i] as f64 + d.f(et, rr, pm) * TAU) as f32;
            }
            Mod::RotationRate { r: d } => {
                let rr = d.f(et, r, pm) * TAU;
                self.rot_rate[i] = (self.rot_rate[i] as f64 + rr) as f32;
                self.base_rot_rate[i] = (self.base_rot_rate[i] as f64 + rr) as f32;
            }
            Mod::MeshRotation { r: d, inherit } => {
                let mut mr = d.v(et, r, pm);
                if *inherit {
                    let e = ctx.comp_basis.euler_yxz();
                    mr = vadd(mr, Vector3::new(e.x.to_degrees() / 360.0, e.y.to_degrees() / 360.0, e.z.to_degrees() / 360.0));
                }
                self.minit[i] = vmul(mr, 360.0);
                self.mrot[i] = vadd(self.mrot[i], self.minit[i]);
            }
            Mod::MeshRotationRate { r: d } => {
                let rr = vmul(d.v(et, r, pm), 360.0);
                self.mrot_rate[i] = vadd(self.mrot_rate[i], rr);
                self.mrot_rate_base[i] = vadd(self.mrot_rate_base[i], rr);
            }
            Mod::SubUv { idx } => {
                self.subuv[i] = self.subuv_index(idx, i, ctx) as f32;
            }
            Mod::ParameterDynamic { flags, params } => {
                self.dynamic_params(*flags, params, i, true, ctx);
            }
            Mod::CameraOffset { off, method, .. } => {
                let v = off.f(self.rel[i] as f64, r, pm);
                match method {
                    0 => self.camoff[i] = Vector2::new(v as f32, v as f32),
                    1 => self.camoff[i].y = (self.camoff[i].y as f64 + v) as f32,
                    _ => self.camoff[i].y = (self.camoff[i].y as f64 * v) as f32,
                }
            }
            Mod::Collision { damp, damp_rot, max_coll, delay, .. } => {
                self.coll_damp[i] = damp.v(et, r, pm);
                self.coll_damp_rot[i] = damp_rot.v(et, r, pm);
                self.coll_left[i] = max_coll.f(et, r, pm).round() as i32;
                self.coll_delay[i] = delay.f(et, r, pm) as f32;
            }
            Mod::Light { color_scale, brightness, radius, exponent, inverse_sq, spawn_fraction, .. } => {
                // UParticleModuleLight::Spawn (DI2 0x14394ef60), when r.ParticleLightQuality > 0
                if ctx.light_quality > 0 {
                    let t = self.rel[i] as f64;
                    let lr = &mut ctx.light_rng;
                    let b = brightness.f(t, lr, pm);
                    let c = color_scale.v(t, lr, pm);
                    self.light_cs[i] = vmul(c, b);
                    self.light_radius[i] = radius.f(et, lr, pm) as f32;
                    self.light_exp[i] = if *inverse_sq { 0.0 } else { exponent.f(et, lr, pm) as f32 };
                    let f = ctx.stream_fraction();
                    self.light_valid[i] = (f < *spawn_fraction as f32) as u8;
                }
            }
            Mod::LocationEmitter { name, inherit_vel, vel_scale, inherit_rot, rot_scale } => {
                for e in others.iter() {
                    if &e.name == name && e.n > 0 {
                        let k = (self.counter as usize) % e.n;
                        let w = e.s2w.xform(e.loc[k]);
                        self.loc[i] = if self.local_space { self.s2w.affine_inverse().xform(w) } else { w };
                        if *inherit_vel {
                            let sv = vmul(e.vel[k], *vel_scale);
                            self.vel[i] = vadd(self.vel[i], sv);
                            self.base_vel[i] = vadd(self.base_vel[i], sv);
                        }
                        if *inherit_rot {
                            self.rot[i] = (self.rot[i] as f64 + e.rot[k] as f64 * rot_scale) as f32;
                        }
                        return;
                    }
                }
            }
            _ => {}
        }
        if seeded.is_some() {
            if let Some(Some(sd)) = self.seeds.get_mut(mi) {
                sd.1 = ss.0;
            }
        }
    }

    /// _subuv_index (DetermineImageIndex)
    fn subuv_index(&mut self, idx: &Dist, i: usize, ctx: &mut Ctx) -> f64 {
        let total = self.req.sub_total;
        match self.req.interp {
            1 | 2 => {
                let v = idx.f(self.rel[i] as f64, &mut ctx.rng, &ctx.params);
                if self.req.interp == 1 {
                    v.floor()
                } else {
                    v
                }
            }
            3 | 4 => {
                let rit = self.req.random_image_time;
                let mut v = self.subuv[i] as f64;
                if rit == 0.0 || (self.rel[i] as f64 - self.subuv_rt[i] as f64) > rit || self.subuv_rt[i] == 0.0 {
                    v = ctx.rng.randf() * total as f64;
                    self.subuv_rt[i] = self.rel[i];
                }
                if self.req.interp == 3 {
                    v.floor()
                } else {
                    v
                }
            }
            _ => 0.0,
        }
    }

    /// _dynamic_params_c
    fn dynamic_params(&mut self, flags: i64, ps: &[DynParam], i: usize, at_spawn: bool, ctx: &mut Ctx) {
        let mut cur = [self.dyn_[i].r, self.dyn_[i].g, self.dyn_[i].b, self.dyn_[i].a];
        for (k, p) in ps.iter().enumerate() {
            if !at_spawn && ((flags >> k) & 1) == 0 {
                continue;
            }
            if p.method == 5 {
                continue;
            }
            let t = if p.use_et { self.emitter_time } else { self.rel[i] as f64 };
            let velf: f64 = match p.method {
                1 => self.vel[i].x as f64,
                2 => self.vel[i].y as f64,
                3 => self.vel[i].z as f64,
                4 => vlen(self.vel[i]) as f64,
                _ => 1.0,
            };
            let mut val = 1.0;
            if p.eval {
                val = p.value.f(t, &mut ctx.rng, &ctx.params);
            }
            cur[k] = (val * velf) as f32;
        }
        self.dyn_[i] = Color::from_rgba(cur[0], cur[1], cur[2], cur[3]);
    }

    // --- update -----------------------------------------------------------------------------------------------

    fn update_module(&mut self, mi: usize, dt: f64, ctx: &mut Ctx) {
        let mods = self.mods.clone();
        let m = &mods[mi];
        let pm_rc = ctx.params.clone();
        let pm: &Params = &pm_rc;
        let n = self.n;
        match m {
            Mod::SizeMultiplyLife { mult, mx, my, mz } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let s = mult.v(self.rel[i] as f64, &mut ctx.rng, pm);
                        let mut z = self.size[i];
                        if *mx {
                            z.x *= s.x;
                        }
                        if *my {
                            z.y *= s.y;
                        }
                        if *mz {
                            z.z *= s.z;
                        }
                        self.size[i] = z;
                    }
                }
            }
            Mod::SizeScale { scale } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        self.size[i] = vmulv(vabs(self.base_size[i]), scale.v(self.rel[i] as f64, &mut ctx.rng, pm));
                    }
                }
            }
            Mod::SizeScaleBySpeed { ss, ms } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let sp = vlen(self.vel[i]) as f64;
                        let fx = (ss[0] * sp).max(1.0).min(ms[0]);
                        let fy = (ss[1] * sp).max(1.0).min(ms[1]);
                        let b = vabs(self.base_size[i]);
                        self.size[i] = Vector3::new((b.x as f64 * fx) as f32, (b.y as f64 * fy) as f32, b.z);
                    }
                }
            }
            Mod::ColorOverLife { col, alpha } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let t = self.rel[i] as f64;
                        let c = col.v(t, &mut ctx.rng, pm);
                        let a = alpha.f(t, &mut ctx.rng, pm);
                        self.col[i] = Color::from_rgba(c.x, c.y, c.z, a as f32);
                    }
                }
            }
            Mod::ColorScaleOverLife { col, alpha, by_et } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let t = if *by_et { self.emitter_time } else { self.rel[i] as f64 };
                        let c = col.v(t, &mut ctx.rng, pm);
                        let a = alpha.f(t, &mut ctx.rng, pm);
                        let k = self.col[i];
                        self.col[i] = Color::from_rgba(k.r * c.x, k.g * c.y, k.b * c.z, (k.a as f64 * a) as f32);
                    }
                }
            }
            Mod::AccelerationDrag { c } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let cc = c.f(self.rel[i] as f64, &mut ctx.rng, pm);
                        let d = vmul(self.vel[i], -cc * dt);
                        self.vel[i] = vadd(self.vel[i], d);
                        self.base_vel[i] = vadd(self.base_vel[i], d);
                    }
                }
            }
            Mod::AccelerationConstant { a, always_world } => {
                let a = self.accel_vec(*always_world, *a, ctx);
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        self.vel[i] = vadd(self.vel[i], vmul(a, dt));
                        self.base_vel[i] = vadd(self.base_vel[i], vmul(a, dt));
                    }
                }
            }
            Mod::Acceleration { .. } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        self.vel[i] = vadd(self.vel[i], vmul(self.accel[i], dt));
                        self.base_vel[i] = vadd(self.base_vel[i], vmul(self.accel[i], dt));
                    }
                }
            }
            Mod::SubUv { idx } => {
                let interp = self.req.interp;
                if interp == 0 {
                    return;
                }
                if (interp == 3 || interp == 4) && self.req.random_image_changes == 0 {
                    return;
                }
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 && self.rel[i] <= 1.0 {
                        self.subuv[i] = self.subuv_index(idx, i, ctx) as f32;
                    }
                }
            }
            Mod::ParameterDynamic { flags, params } => {
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        self.dynamic_params(*flags, params, i, false, ctx);
                    }
                }
            }
            Mod::CameraOffset { off, method, spawn_only } => {
                if *spawn_only {
                    return;
                }
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let mut v = off.f(self.rel[i] as f64, &mut ctx.rng, pm);
                        match method {
                            1 => v += self.camoff[i].y as f64,
                            2 => v *= self.camoff[i].y as f64,
                            _ => {}
                        }
                        self.camoff[i].y = v as f32;
                    }
                }
            }
            Mod::VelocityOverLifetime { vol, absolute, world } => {
                for i in 0..n {
                    let mut v = vol.v(self.rel[i] as f64, &mut ctx.rng, pm);
                    if *absolute {
                        if !self.local_space && !*world {
                            v = ctx.comp_basis.xform(v);
                        }
                        self.vel[i] = v;
                    } else {
                        self.vel[i] = vmulv(self.vel[i], v);
                    }
                }
            }
            Mod::Collision { max_dist, dirscalar, completion, .. } => {
                self.collision(*max_dist, *dirscalar, *completion, dt, ctx);
            }
            Mod::Light { color_scale, brightness, .. } => {
                // UParticleModuleLight::Update (DI2 0x1439566b0): ColorScale = Brightness(t) * ColorScaleOverLife(t)
                for i in 0..n {
                    if (self.flags[i] & F_FREEZE) == 0 {
                        let t = self.rel[i] as f64;
                        let b = brightness.f(t, &mut ctx.light_rng, pm);
                        let c = color_scale.v(t, &mut ctx.light_rng, pm);
                        self.light_cs[i] = vmul(c, b);
                    }
                }
            }
            _ => {}
        }
    }

    /// _collision (UParticleModuleCollision::Update, UE 4.27)
    fn collision(&mut self, maxd: f64, dirscalar: f64, opt: u8, dt: f64, ctx: &mut Ctx) {
        if maxd < 1048576.0 && vlen(vsub(ctx.comp_loc, ctx.camera_ue)) as f64 > maxd {
            return;
        }
        let Some(mut space) = ctx.space.clone() else { return };
        if ctx.query.is_none() {
            let mut q = PhysicsRayQueryParameters3D::new_gd();
            q.set_collision_mask(ctx.world_mask);
            ctx.query = Some(q);
        }
        let mut q = ctx.query.clone().unwrap();
        let mut kill: Vec<usize> = vec![];
        for i in 0..self.n {
            if (self.flags[i] & (F_IGNORE_COLLISIONS | F_FREEZE)) != 0 {
                continue;
            }
            if self.coll_delay[i] > self.rel[i] {
                continue;
            }
            let mut l = vadd(self.loc[i], vmul(self.vel[i], dt));
            let mut ol = self.old_loc[i];
            if self.local_space {
                l = self.s2w.xform(l);
                ol = self.s2w.xform(ol);
            }
            let dirv = vsub(l, ol);
            let dir = if vlen_sq(dirv) > 1e-8 { vnorm(dirv) } else { Vector3::ZERO };
            let sz = self.size[i];
            let ds = dirscalar as f32;
            let end = vadd(l, Vector3::new(dir.x * sz.x / ds, dir.y * sz.y / ds, dir.z * sz.z / ds));
            if is_equal_approx_v(ol, end) {
                continue;
            }
            q.set_from(u2g(ol));
            q.set_to(u2g(end));
            let hit: VarDictionary = space.intersect_ray(&q);
            if hit.is_empty() {
                continue;
            }
            let hp = g2u(hit.get(&"position".to_variant()).and_then(|v| v.try_to::<Vector3>().ok()).unwrap_or(Vector3::ZERO));
            let hn = u2g_dir(hit.get(&"normal".to_variant()).and_then(|v| v.try_to::<Vector3>().ok()).unwrap_or(Vector3::ZERO));
            let tlen = vlen(vsub(end, ol)) as f64;
            let htime = if tlen > 0.0 { vlen(vsub(hp, ol)) as f64 / tlen } else { 0.0 };
            self.coll_left[i] -= 1;
            let world_vel = if !self.local_space { self.vel[i] } else { self.s2w.b.xform(self.vel[i]) };
            self.report_collision(hp, world_vel, ctx);
            if self.coll_left[i] > 0 {
                let mut bv = if !self.local_space { self.base_vel[i] } else { self.s2w.b.xform(self.base_vel[i]) };
                bv = vmulv(vsub(bv, vmul(hn, 2.0 * vdot(bv, hn) as f64)), self.coll_damp[i]);
                self.base_vel[i] = if !self.local_space { bv } else { self.s2w.b.inverse().xform(bv) };
                self.base_rot_rate[i] *= self.coll_damp_rot[i].x;
                let nv = vmulv(vmul(vsub(dir, vmul(hn, 2.0 * vdot(dir, hn) as f64)), vlen(dirv) as f64), self.coll_damp[i]);
                self.vel[i] = Vector3::ZERO;
                let add = vmul(nv, 1.0 - htime);
                let d = if !self.local_space { add } else { self.s2w.b.inverse().xform(add) };
                self.loc[i] = vadd(self.loc[i], d);
            } else {
                match opt {
                    0 => kill.push(i),
                    1 => self.flags[i] |= F_FREEZE,
                    2 => self.flags[i] |= F_IGNORE_COLLISIONS,
                    3 => self.flags[i] |= F_FREEZE_TRANSLATION,
                    4 => self.flags[i] |= F_FREEZE_ROTATION,
                    5 => self.flags[i] |= F_FREEZE_ROTATION | F_FREEZE_TRANSLATION,
                    _ => {}
                }
            }
        }
        kill.sort();
        kill.reverse();
        for i in kill {
            self.kill(i);
        }
    }

    // --- events -----------------------------------------------------------------------------------------------

    fn report(&self, i: usize, typ: &'static str, ctx: &mut Ctx) {
        if !self.has_event_gen {
            return;
        }
        for (t, name) in &self.event_gen {
            if t != typ {
                continue;
            }
            let w = if self.local_space { self.s2w.xform(self.loc[i]) } else { self.loc[i] };
            let v = if self.local_space { self.s2w.b.xform(self.vel[i]) } else { self.vel[i] };
            ctx.events.push(Event { kind: typ, name: name.clone(), loc: w, vel: v });
        }
    }

    fn report_collision(&self, hit_loc: Vector3, v: Vector3, ctx: &mut Ctx) {
        if !self.has_event_gen {
            return;
        }
        for (t, name) in &self.event_gen {
            if t == "EPET_Collision" {
                ctx.events.push(Event { kind: "EPET_Collision", name: name.clone(), loc: hit_loc, vel: v });
            }
        }
    }

    /// receive_event (UParticleModuleEventReceiverSpawn::ProcessParticleEvent)
    fn receive_event(&mut self, ev: &Event, ctx: &mut Ctx, others: &[Emitter]) {
        if !self.enabled {
            return;
        }
        for k in 0..self.receivers.len() {
            let m = self.receivers[k].clone();
            if m.gen_type != ev.kind || m.name != ev.name {
                continue;
            }
            let mut at = if m.use_psys_loc { ctx.comp_loc } else { ev.loc };
            let mut v = Vector3::ZERO;
            if m.inherit_vel {
                let s = m.vel_scale.v(self.emitter_time, &mut ctx.rng, &ctx.params);
                v = vmulv(ev.vel, s);
            }
            if self.local_space {
                at = self.s2w.affine_inverse().xform(at);
                v = self.s2w.b.inverse().xform(v);
            }
            let count = m.count.f(self.emitter_time, &mut ctx.rng, &ctx.params).round() as i64;
            self.spawn_particles(count, 0.0, 0.0, at, v, ctx, others);
        }
    }

    // --- GPU sprite emitters ----------------------------------------------------------------------------------

    fn gpu_spawn(&mut self, i: usize, st: f64, ctx: &mut Ctx, others: &[Emitter]) {
        for k in 0..self.spawn_list.len() {
            let mi = self.spawn_list[k];
            self.spawn_module(mi, i, st, ctx, others);
        }
        let drag = self.gpu.as_ref().map(|g| g.drag.f(self.emitter_time, &mut ctx.rng, &ctx.params)).unwrap_or(0.0);
        self.gpu_drag[i] = drag as f32;
        let bs = self.base_size[i];
        self.gpu_init[i] = Color::from_rgba(bs.x, bs.y, self.rot[i], self.rot_rate[i]);
    }

    fn gpu_update(&mut self, dt: f64) {
        let Some(g) = self.gpu.as_ref() else { return };
        let (acc, ds, db) = (g.acc, g.drag_scale, g.drag_bias);
        for i in 0..self.n {
            let drag = self.gpu_drag[i] as f64 * ds + db;
            self.base_vel[i] = vadd(self.base_vel[i], vmul(acc, dt));
            self.base_vel[i] = vsub(self.base_vel[i], vmul(vmul(self.base_vel[i], drag), dt));
            self.vel[i] = self.base_vel[i];
        }
    }

    fn gpu_curve(s: &[f64], sc: [f32; 4], bs: [f32; 4], t: f64) -> [f32; 4] {
        let cnt = (s.len() / 4) as i64;
        if cnt == 0 {
            return [0.0; 4];
        }
        let x = t.clamp(0.0, 1.0) * (cnt - 1) as f64;
        let a = x.floor() as i64;
        let bi = (a + 1).min(cnt - 1);
        let f = x - a as f64;
        let (o0, o1) = ((a * 4) as usize, (bi * 4) as usize);
        let mut v = [0f32; 4];
        for k in 0..4 {
            v[k] = (lerp(s[o0 + k], s[o1 + k], f) as f32) / 255.0;
            v[k] = v[k] * sc[k] + bs[k];
        }
        v
    }

    // --- render -----------------------------------------------------------------------------------------------

    /// render(): the MultiMesh instance data (TRANSFORM_3D rows + colour + custom data, 20 floats per instance)
    /// into self.buf (capacity instances), for the camera's transform in Godot space.
    pub fn fill_buffer(&mut self, cam: &Xf, capacity: usize, comp_basis: &M3) {
        let stride = 20usize;
        let mut pbuf = self.buf.take().unwrap_or_default();
        if pbuf.len() != capacity * stride {
            pbuf.resize(capacity * stride);
        }
        self.fill(&mut pbuf, cam, capacity, comp_basis);
        self.buf = Some(pbuf);
    }

    fn fill(&self, pbuf: &mut PackedFloat32Array, cam: &Xf, capacity: usize, comp_basis: &M3) {
        let stride = 20usize;
        let n = self.n.min(capacity);
        if n == 0 {
            return;
        }
        let cam_pos_ue = g2u(cam.o);
        let cam_right = u2g_dir(cam.b.col(0));
        let cam_up = vneg(u2g_dir(cam.b.col(1)));
        let order: Vec<usize> = self.sort_order(cam_pos_ue);
        let is_mesh = self.kind == Kind::Mesh;
        let is_gpu = self.kind == Kind::Gpu;
        let buf = pbuf.as_mut_slice();
        let me: &Emitter = self;
        for k in 0..n {
            let i = if me.sort_mode != 0 { order[k] } else { k };
            let wl = if me.local_space { me.s2w.xform(me.loc[i]) } else { me.loc[i] };
            let mut co = Vector3::ZERO;
            if me.camoff[i].y != 0.0 {
                co = camera_offset(me.camoff[i].y as f64, vsub(cam_pos_ue, wl));
            }
            let mut custom = me.dyn_[i];
            if me.time_in_w {
                custom.a = me.rel[i];
            }
            let mut gm = [0f32; 4];
            let mut c = me.col[i];
            if is_gpu {
                let g = me.gpu.as_ref().unwrap();
                let cc = Emitter::gpu_curve(&g.col, g.col_sc, g.col_bs, me.rel[i] as f64);
                c = Color::from_rgba(cc[0], cc[1], cc[2], cc[3]);
                gm = Emitter::gpu_curve(&g.misc, g.misc_sc, g.misc_bs, me.rel[i] as f64);
            }
            let xf = if is_mesh { me.mesh_transform(i, vadd(wl, co)) } else { me.sprite_transform(i, vadd(wl, co), cam_pos_ue, cam_right, cam_up, gm, comp_basis) };
            let o = k * stride;
            let b = &xf.b.r;
            buf[o] = b[0][0];
            buf[o + 1] = b[0][1];
            buf[o + 2] = b[0][2];
            buf[o + 3] = xf.o.x;
            buf[o + 4] = b[1][0];
            buf[o + 5] = b[1][1];
            buf[o + 6] = b[1][2];
            buf[o + 7] = xf.o.y;
            buf[o + 8] = b[2][0];
            buf[o + 9] = b[2][1];
            buf[o + 10] = b[2][2];
            buf[o + 11] = xf.o.z;
            buf[o + 12] = c.r;
            buf[o + 13] = c.g;
            buf[o + 14] = c.b;
            buf[o + 15] = c.a;
            buf[o + 16] = custom.r;
            buf[o + 17] = custom.g;
            buf[o + 18] = custom.b;
            buf[o + 19] = custom.a;
        }
    }

    fn sort_order(&self, cam_ue: Vector3) -> Vec<usize> {
        if self.sort_mode == 0 {
            return vec![];
        }
        let mut order: Vec<usize> = (0..self.n).collect();
        match self.sort_mode {
            1 => order.sort_by(|&a, &b| self.rel[a].partial_cmp(&self.rel[b]).unwrap_or(std::cmp::Ordering::Equal)),
            2 => order.sort_by(|&a, &b| self.rel[b].partial_cmp(&self.rel[a]).unwrap_or(std::cmp::Ordering::Equal)),
            _ => {
                let w = |i: usize| {
                    let p = if self.local_space { self.s2w.xform(self.loc[i]) } else { self.loc[i] };
                    vlen_sq(vsub(cam_ue, p))
                };
                order.sort_by(|&a, &b| w(b).partial_cmp(&w(a)).unwrap_or(std::cmp::Ordering::Equal));
            }
        }
        order
    }

    #[allow(clippy::too_many_arguments)]
    fn sprite_transform(&self, i: usize, wl: Vector3, cam_ue: Vector3, cam_right: Vector3, cam_up: Vector3, gm: [f32; 4], comp_basis: &M3) -> Xf {
        let mut cam_dir = vsub(cam_ue, wl);
        cam_dir = if vlen_sq(cam_dir) > 1e-8 { vnorm(cam_dir) } else { Vector3::new(1.0, 0.0, 0.0) };
        let mut right = cam_right;
        let mut up = cam_up;
        let mut rbias = 0.0f64;
        if self.align == Align::Velocity {
            let mut md = vsub(self.loc[i], self.old_loc[i]);
            if self.local_space {
                md = self.s2w.b.xform(md);
            }
            if vlen_sq(md) < 1e-12 {
                md = if self.local_space { self.s2w.b.xform(self.vel[i]) } else { self.vel[i] };
            }
            md = if vlen_sq(md) > 1e-12 { vnorm(md) } else { Vector3::new(0.0, 0.0, 1.0) };
            let rr = vcross(cam_dir, md);
            right = if vlen_sq(rr) > 1e-12 { vnorm(rr) } else { right };
            up = vneg(md);
        } else if self.lock_mode != 0 {
            right = comp_basis.col((self.lock_mode - 1) as usize);
            let u2 = vcross(right, cam_dir);
            up = vneg(if vlen_sq(u2) > 1e-12 { vnorm(u2) } else { u2 });
            if self.lock_mode == 3 {
                rbias = std::f64::consts::PI * 0.5;
            }
        } else if self.align == Align::FacingCameraPos {
            let r2 = vcross(cam_dir, Vector3::new(0.0, 0.0, 1.0));
            right = if vlen_sq(r2) > 1e-12 { vnorm(r2) } else { right };
            up = vcross(cam_dir, right);
        }
        let ang = self.rot[i] as f64 + rbias;
        let (sr, cr) = (ang.sin(), ang.cos());
        let rv = vadd(vmul(up, sr), vmul(right, cr));
        let uv = vsub(vmul(up, cr), vmul(right, sr));
        let mut sz = Vector2::new(self.size[i].x, self.size[i].y);
        if self.kind == Kind::Gpu {
            sz = self.gpu_size(i, gm);
        }
        let bs = self.base_size[i];
        let sx = (sz.x as f64).abs() * if bs.x < 0.0 { -1.0 } else { 1.0 };
        let mut sy = (sz.y as f64).abs() * if bs.y < 0.0 { -1.0 } else { 1.0 };
        if self.align == Align::Square || self.align == Align::FacingCameraPos {
            sy = (sz.x as f64).abs() * if bs.y < 0.0 { -1.0 } else { 1.0 };
        }
        let origin = vadd(vadd(wl, vmul(vmul(rv, sx), self.pivot.x as f64 + 0.5)), vmul(vmul(uv, sy), self.pivot.y as f64 + 0.5));
        let gx = vmul(vmul(u2g_dir(rv), sx), 0.01);
        let gy = vmul(vmul(u2g_dir(uv), sy), 0.01);
        let sub = if self.kind != Kind::Gpu { self.subuv[i] } else { gm[2] };
        let extra = Vector3::new(sub, self.rel[i], 0.0);
        Xf { b: M3::from_cols(gx, gy, extra), o: u2g(origin) }
    }

    fn gpu_size(&self, i: usize, m: [f32; 4]) -> Vector2 {
        let g = self.gpu.as_ref().unwrap();
        let sp = vlen(self.vel[i]) as f64;
        let fx = (g.sbs[0] * sp).max(1.0).min(g.sbs[2]);
        let fy = (g.sbs[1] * sp).max(1.0).min(g.sbs[3]);
        let init = Vector2::new((self.gpu_init[i].r.abs() as f64 * g.inv0) as f32, (self.gpu_init[i].g.abs() as f64 * g.inv1) as f32);
        Vector2::new(((init.x * m[0]) as f64 * fx) as f32, ((init.y * m[1]) as f64 * fy) as f32)
    }

    fn mesh_transform(&self, i: usize, wl: Vector3) -> Xf {
        let r = (self.rot[i] as f64).to_degrees();
        let m = self.mrot[i];
        let mut b = rotator_basis_ue(r + m.y as f64, r + m.z as f64, r + m.x as f64);
        if self.local_space {
            b = self.s2w.b.mul(&b);
        }
        b = b.scaled_cols(self.size[i]);
        Xf { b: u2g_basis(&b), o: u2g(wl) }
    }

    /// UE 4.27 GatherSimpleLights for this emitter: per valid light particle (Godot space) position xyz, colour
    /// rgb (particle rgb * alpha * ColorScale), radius (m; RadiusScale * (Size.x + Size.y) / 2), exponent (0 =
    /// inverse squared), flags (1 affects translucency, 2 high quality, 4 shadow casting).
    pub fn gather_lights(&self, out: &mut Vec<f32>) {
        if !self.has_light {
            return;
        }
        for i in 0..self.n {
            if self.light_valid[i] == 0 {
                continue;
            }
            let wl = if self.local_space { self.s2w.xform(self.loc[i]) } else { self.loc[i] };
            let g = u2g(wl);
            let c = self.col[i];
            let cs = self.light_cs[i];
            let radius = self.light_radius[i] * (self.size[i].x + self.size[i].y) / 2.0;
            out.extend_from_slice(&[g.x, g.y, g.z, c.r * c.a * cs.x, c.g * c.a * cs.y, c.b * c.a * cs.z, radius * 0.01, self.light_exp[i], self.light_flags as f32]);
        }
    }

    pub fn checksum(&self) -> f64 {
        let mut c = 0.0f64;
        for i in 0..self.n {
            c += self.loc[i].x as f64 * 0.001 + self.loc[i].y as f64 * 0.002 + self.loc[i].z as f64 * 0.003 + vlen(self.vel[i]) as f64 * 0.0001;
            c += self.size[i].x as f64 * 0.01 + self.col[i].r as f64 + self.col[i].a as f64 * 0.5 + self.rel[i] as f64 + self.rot[i] as f64 * 0.1 + self.dyn_[i].g as f64;
        }
        c
    }
}

/// GetCameraOffset (UE 4.27)
fn camera_offset(off: f64, to_cam: Vector3) -> Vector3 {
    let lsq = vlen_sq(to_cam) as f64;
    let d = if lsq > 0.0 { vnorm(to_cam) } else { Vector3::ZERO };
    if lsq > off * off {
        return vmul(d, off);
    }
    vmul(d, off * 1048576.0)
}

/// Godot's CLAMP macro (min wins over max when they cross).
#[inline]
pub fn clamp_g(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

fn is_equal_approx_f(a: f32, b: f32) -> bool {
    if a == b {
        return true;
    }
    let mut tol = 0.00001f32 * a.abs();
    if tol < 0.00001 {
        tol = 0.00001;
    }
    (a - b).abs() < tol
}

fn is_equal_approx_v(a: Vector3, b: Vector3) -> bool {
    is_equal_approx_f(a.x, b.x) && is_equal_approx_f(a.y, b.y) && is_equal_approx_f(a.z, b.z)
}

fn jv3_f64(v: Option<&Value>) -> [f64; 3] {
    match v.and_then(|a| a.as_array()) {
        Some(a) => [a.first().and_then(|x| x.as_f64()).unwrap_or(0.0), a.get(1).and_then(|x| x.as_f64()).unwrap_or(0.0), a.get(2).and_then(|x| x.as_f64()).unwrap_or(0.0)],
        None => [0.0; 3],
    }
}

fn spawn_per_unit(m: &Value) -> SpawnPerUnit {
    SpawnPerUnit {
        unit: jf(m, "UnitScalar", 50.0),
        spu: Dist::from_json(m.get("SpawnPerUnit")),
        ignore: [jb(m, "bIgnoreMovementAlongX", false), jb(m, "bIgnoreMovementAlongY", false), jb(m, "bIgnoreMovementAlongZ", false)],
        max_frame_dist: jf(m, "MaxFrameDistance", 0.0),
        tolerance: jf(m, "MovementTolerance", 0.1),
        ignore_rate_when_moving: jb(m, "bIgnoreSpawnRateWhenMoving", false),
        process_rate: jb(m, "bProcessSpawnRate", true),
        process_burst: jb(m, "bProcessBurstList", true),
    }
}

fn receiver(m: &Value) -> Receiver {
    Receiver {
        gen_type: sub_s(m, "EventGeneratorType"),
        name: js(m, "EventName", "None").to_string(),
        use_psys_loc: jb(m, "bUsePSysLocation", false),
        inherit_vel: jb(m, "bInheritVelocity", false),
        vel_scale: Dist::from_json(m.get("InheritVelocityScale")),
        count: Dist::from_json(m.get("SpawnCount")),
    }
}

fn d(m: &Value, k: &str) -> Dist {
    Dist::from_json(m.get(k))
}

/// RandomSeedInfo of a *_Seeded module: (seed, state, bResetSeedOnEmitterLooping). DI2's data only uses
/// RandomSeeds[0] (bGetSeedFromInstance never set; with one seed, bRandomlySelectSeedArray picks index 0).
fn seed_info(m: &Value) -> Option<(u32, u32, bool)> {
    if !js(m, "m", "").ends_with("_Seeded") {
        return None;
    }
    let info = m.get("RandomSeedInfo")?;
    let seed = info.get("RandomSeeds").and_then(|a| a.as_array()).and_then(|a| a.first()).and_then(|x| x.as_i64()).unwrap_or(0) as i32 as u32;
    Some((seed, seed, jb(info, "bResetSeedOnEmitterLooping", true)))
}

fn build_mod(m: &Value) -> Mod {
    let cls = js(m, "m", "");
    match cls.strip_suffix("_Seeded").unwrap_or(cls) {
        "Lifetime" => Mod::Lifetime { life: d(m, "Lifetime") },
        "Size" => Mod::Size { start: d(m, "StartSize") },
        "SizeMultiplyLife" => Mod::SizeMultiplyLife { mult: d(m, "LifeMultiplier"), mx: jb(m, "MultiplyX", true), my: jb(m, "MultiplyY", true), mz: jb(m, "MultiplyZ", true) },
        "SizeScale" => Mod::SizeScale { scale: d(m, "SizeScale") },
        "SizeScaleBySpeed" => {
            let a = |k: &str| -> [f64; 2] {
                let v = m.get(k).and_then(|x| x.as_array()).cloned().unwrap_or_default();
                [v.first().and_then(|x| x.as_f64()).unwrap_or(1.0), v.get(1).and_then(|x| x.as_f64()).unwrap_or(1.0)]
            };
            Mod::SizeScaleBySpeed { ss: a("SpeedScale"), ms: a("MaxScale") }
        }
        "Color" => Mod::Color { col: d(m, "StartColor"), alpha: d(m, "StartAlpha") },
        "ColorOverLife" => Mod::ColorOverLife { col: d(m, "ColorOverLife"), alpha: d(m, "AlphaOverLife") },
        "ColorScaleOverLife" => Mod::ColorScaleOverLife { col: d(m, "ColorScaleOverLife"), alpha: d(m, "AlphaScaleOverLife"), by_et: jb(m, "bEmitterTime", false) },
        "VelocityCone" => Mod::VelocityCone { angle: d(m, "Angle"), vel: d(m, "Velocity"), dir: jv3(m.get("Direction"), [0.0, 0.0, 1.0]), world: jb(m, "bInWorldSpace", false) },
        "Velocity" => Mod::Velocity { start: d(m, "StartVelocity"), radial: d(m, "StartVelocityRadial"), world: jb(m, "bInWorldSpace", false) },
        "VelocityInheritParent" => Mod::VelocityInheritParent { scale: d(m, "Scale") },
        "VelocityOverLifetime" => Mod::VelocityOverLifetime { vol: d(m, "VelOverLife"), absolute: jb(m, "Absolute", false), world: jb(m, "bInWorldSpace", false) },
        "AccelerationConstant" => Mod::AccelerationConstant { a: jv3(m.get("Acceleration"), [0.0; 3]), always_world: jb(m, "bAlwaysInWorldSpace", false) },
        "Acceleration" => Mod::Acceleration { a: d(m, "Acceleration"), always_world: jb(m, "bAlwaysInWorldSpace", false) },
        "AccelerationDrag" => Mod::AccelerationDrag { c: d(m, "DragCoefficientRaw") },
        "Location" => Mod::Location { start: d(m, "StartLocation"), world_offset: false },
        "LocationWorldOffset" => Mod::Location { start: d(m, "StartLocation"), world_offset: true },
        "LocationPrimitiveSphere" => Mod::Sphere {
            start: d(m, "StartLocation"),
            radius: d(m, "StartRadius"),
            pos: [jb(m, "Positive_X", true), jb(m, "Positive_Y", true), jb(m, "Positive_Z", true)],
            neg: [jb(m, "Negative_X", true), jb(m, "Negative_Y", true), jb(m, "Negative_Z", true)],
            surface: jb(m, "SurfaceOnly", false),
            velocity: jb(m, "Velocity", false),
            vscale: d(m, "VelocityScale"),
        },
        "LocationPrimitiveCylinder" => Mod::Cylinder {
            start: d(m, "StartLocation"),
            radius: d(m, "StartRadius"),
            height: d(m, "StartHeight"),
            surface: jb(m, "SurfaceOnly", false),
            axis: match js(m, "HeightAxis", "PMLPC_HEIGHTAXIS_Z") {
                "PMLPC_HEIGHTAXIS_X" => 1,
                "PMLPC_HEIGHTAXIS_Y" => 2,
                _ => 0,
            },
        },
        "Rotation" => Mod::Rotation { r: d(m, "StartRotation") },
        "RotationRate" => Mod::RotationRate { r: d(m, "StartRotationRate") },
        "MeshRotation" => Mod::MeshRotation { r: d(m, "StartRotation"), inherit: jb(m, "bInheritParent", false) },
        "MeshRotationRate" => Mod::MeshRotationRate { r: d(m, "StartRotationRate") },
        "SubUV" => Mod::SubUv { idx: d(m, "SubImageIndex") },
        "ParameterDynamic" => {
            let ps = m.get("DynamicParams").and_then(|x| x.as_array()).cloned().unwrap_or_default();
            let params = ps
                .iter()
                .take(4)
                .map(|p| {
                    let vm = js(p, "ValueMethod", "EDPV_UserSet");
                    DynParam {
                        method: match vm {
                            "EDPV_VelocityX" => 1,
                            "EDPV_VelocityY" => 2,
                            "EDPV_VelocityZ" => 3,
                            "EDPV_VelocityMag" => 4,
                            "EDPV_AutoSet" => 5,
                            _ => 0,
                        },
                        use_et: jb(p, "bUseEmitterTime", false),
                        eval: vm == "EDPV_UserSet" || jb(p, "bScaleVelocityByParamValue", false),
                        value: d(p, "ParamValue"),
                    }
                })
                .collect();
            Mod::ParameterDynamic { flags: ji(m, "UpdateFlags", 15), params }
        }
        "CameraOffset" => Mod::CameraOffset {
            off: d(m, "CameraOffset"),
            method: match js(m, "UpdateMethod", "EPCOUM_DirectSet") {
                "EPCOUM_DirectSet" => 0,
                "EPCOUM_Additive" => 1,
                _ => 2,
            },
            spawn_only: jb(m, "bSpawnTimeOnly", false),
        },
        "Collision" => Mod::Collision {
            damp: d(m, "DampingFactor"),
            damp_rot: d(m, "DampingFactorRotation"),
            max_coll: d(m, "MaxCollisions"),
            delay: d(m, "DelayAmount"),
            max_dist: jf(m, "MaxCollisionDistance", 1000.0),
            dirscalar: jf(m, "DirScalar", 3.5),
            completion: match js(m, "CollisionCompletionOption", "EPCC_Kill") {
                "EPCC_Kill" => 0,
                "EPCC_Freeze" => 1,
                "EPCC_HaltCollisions" => 2,
                "EPCC_FreezeTranslation" => 3,
                "EPCC_FreezeRotation" => 4,
                "EPCC_FreezeMovement" => 5,
                _ => 6,
            },
        },
        "Light" => Mod::Light {
            color_scale: d(m, "ColorScaleOverLife"),
            brightness: d(m, "BrightnessOverLife"),
            radius: d(m, "RadiusScale"),
            exponent: d(m, "LightExponent"),
            inverse_sq: jb(m, "bUseInverseSquaredFalloff", true),
            spawn_fraction: jf(m, "SpawnFraction", 1.0),
            flags: (jb(m, "bAffectsTranslucency", false) as u8) | ((jb(m, "bHighQualityLights", false) as u8) << 1) | ((jb(m, "bShadowCastingLights", false) as u8) << 2),
        },
        "LocationEmitter" => Mod::LocationEmitter {
            name: js(m, "EmitterName", "").to_string(),
            inherit_vel: jb(m, "InheritSourceVelocity", false),
            vel_scale: jf(m, "InheritSourceVelocityScale", 1.0),
            inherit_rot: jb(m, "bInheritSourceRotation", false),
            rot_scale: jf(m, "InheritSourceRotationScale", 1.0),
        },
        _ => Mod::Other,
    }
}

// --- system ------------------------------------------------------------------------------------------------------

pub struct System {
    pub emitters: Vec<Emitter>,
    pub ctx: Ctx,
}

/// A system's emitters built from the JSON for one LOD (module lists, compiled distributions), cloned per spawn.
pub fn build_emitters(ps: &Value, lod: usize, engine: &Value) -> Vec<Emitter> {
    let mut emitters = vec![];
    if let Some(es) = ps.get("emitters").and_then(|x| x.as_array()) {
        for ed in es {
            if ed.is_null() {
                continue;
            }
            emitters.push(Emitter::new(ed, lod, engine));
        }
    }
    emitters
}

impl System {
    pub fn new(emitters: Vec<Emitter>, seed: u64, params: Params, world_mask: u32) -> System {
        System {
            emitters,
            ctx: Ctx {
                rng: Rng::seeded(seed),
                params: Rc::new(params),
                comp_basis: M3::IDENTITY,
                comp_loc: Vector3::ZERO,
                part_sys_velocity: Vector3::ZERO,
                camera_ue: Vector3::ZERO,
                just_registered: true,
                events: vec![],
                space: None,
                query: None,
                world_mask,
                stream: (seed as u32) ^ 0x5bd1_e995,
                light_rng: Rng::seeded(seed ^ 0x9e37_79b9_7f4a_7c15),
                light_quality: 2,
            },
        }
    }

    pub fn init(&mut self) {
        for k in 0..self.emitters.len() {
            let mut e = std::mem::take(&mut self.emitters[k]);
            e.init_instance(&mut self.ctx);
            self.emitters[k] = e;
        }
    }

    /// DI2Particles.advance's emitter ticks + _dispatch_events.
    pub fn tick(&mut self, dt: f64) {
        for k in 0..self.emitters.len() {
            let mut e = std::mem::take(&mut self.emitters[k]);
            e.tick(dt, &mut self.ctx, &self.emitters);
            self.emitters[k] = e;
        }
        self.ctx.just_registered = false;
        if self.ctx.events.is_empty() {
            return;
        }
        let evs = std::mem::take(&mut self.ctx.events);
        for ev in &evs {
            for k in 0..self.emitters.len() {
                let mut e = std::mem::take(&mut self.emitters[k]);
                e.receive_event(ev, &mut self.ctx, &self.emitters);
                self.emitters[k] = e;
            }
        }
    }

    pub fn completed(&self) -> bool {
        self.emitters.iter().all(|e| e.has_completed())
    }
}

