//! `DI2ParticleSim`: the Cascade simulation of one DI2 particle system (UParticleSystemComponent) in Rust, driven
//! by the GDScript node `DI2Particles` (game/scripts/di2_particles.gd), which keeps the data lookup, the
//! renderers / materials and a GDScript fallback of the same simulation (`DI2Particles.use_rust`).
//!
//! Per frame the node calls `tick` (emitter ticks, module updates, spawning, collision traces against the Godot
//! world, particle events), grows its MultiMeshes to `counts()`, then `render` (camera-aligned sprite / mesh
//! particle transforms written straight into each emitter's MultiMesh buffer). Behaviour and DI2 sources:
//! recon/PARTICLES.md; the module semantics are documented on the GDScript counterparts.

mod dist;
mod sim;

use dist::{Param, Params, Xf, M3};
use godot::classes::file_access::ModeFlags;
use godot::classes::{FileAccess, PhysicsDirectSpaceState3D, RenderingServer};
use godot::prelude::*;
use serde_json::Value;
use std::rc::Rc;

thread_local! {
    static DB: std::cell::RefCell<Option<Rc<Value>>> = Default::default();
    /// Compiled emitters per (system, LOD), cloned for every spawn.
    static TEMPLATES: std::cell::RefCell<std::collections::HashMap<(String, usize), Rc<Vec<sim::Emitter>>>> = Default::default();
}

/// Drops the cached data and templates (plain Rust values; safe to call any time, they are rebuilt on demand).
/// For lib.rs's on_stage_deinit, so nothing of this module outlives the engine.
#[allow(dead_code)]
pub fn release() {
    DB.with(|d| d.borrow_mut().take());
    TEMPLATES.with(|t| t.borrow_mut().clear());
}

/// game/data/particles.json, parsed once.
fn db() -> Option<Rc<Value>> {
    DB.with(|c| {
        if c.borrow().is_none() {
            let txt = FileAccess::open("res://data/particles.json", ModeFlags::READ).map(|f| f.get_as_text().to_string())?;
            let v: Value = serde_json::from_str(&txt).ok()?;
            *c.borrow_mut() = Some(Rc::new(v));
        }
        c.borrow().clone()
    })
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
pub struct DI2ParticleSim {
    sys: Option<sim::System>,
}

#[godot_api]
impl DI2ParticleSim {
    /// Builds the system's emitters from particles.json for LOD `lod`, with the RNG seeded like
    /// RandomNumberGenerator.seed = `seed`. `params` = instance parameters {name: float | Vector3}. Returns the
    /// number of (non-null) emitters, in the order DI2Particles creates them, or -1 when the system is unknown.
    #[func]
    fn setup(&mut self, ps: GString, lod: i64, seed: i64, params: VarDictionary, world_mask: i64) -> i64 {
        let Some(db) = db() else { return -1 };
        let name = ps.to_string();
        let lod = lod.max(0) as usize;
        let key = (name.clone(), lod);
        let cached = TEMPLATES.with(|t| t.borrow().get(&key).cloned());
        let template = match cached {
            Some(t) => t,
            None => {
                let Some(psv) = db.get("ps").and_then(|p| p.get(name.as_str())) else { return -1 };
                let engine = db.get("engine_modules").unwrap_or(&Value::Null);
                let t = Rc::new(sim::build_emitters(psv, lod, engine));
                TEMPLATES.with(|c| c.borrow_mut().insert(key, t.clone()));
                t
            }
        };
        let mut pm = Params::new();
        for (k, v) in params.iter_shared() {
            let key = k.to_string();
            if let Ok(f) = v.try_to::<f64>() {
                pm.insert(key, Param::F(f));
            } else if let Ok(i) = v.try_to::<i64>() {
                pm.insert(key, Param::F(i as f64));
            } else if let Ok(x) = v.try_to::<Vector3>() {
                pm.insert(key, Param::V(x));
            }
        }
        let s = sim::System::new((*template).clone(), seed as u64, pm, world_mask as u32);
        let n = s.emitters.len() as i64;
        self.sys = Some(s);
        n
    }

    /// The node's final emitter kinds (0 sprite, 1 mesh, 2 GPU sprite, 3 none: a mesh emitter whose mesh isn't
    /// exported draws nothing), each emitter's MultiMesh RID id (0 = no renderer), whether its material reads
    /// RelativeTime from custom data .w, and the component transform (UE space). Then Init (EmitterDelay /
    /// EmitterDuration ranges draw from the RNG here, as FParticleEmitterInstance::Init does).
    #[func]
    fn configure(&mut self, kinds: PackedInt32Array, rids: PackedInt64Array, time_in_w: PackedByteArray, comp_basis: Basis, comp_loc: Vector3) {
        let Some(s) = self.sys.as_mut() else { return };
        for (i, e) in s.emitters.iter_mut().enumerate() {
            if let Some(k) = kinds.get(i) {
                e.kind = match k {
                    0 => sim::Kind::Sprite,
                    1 => sim::Kind::Mesh,
                    2 => sim::Kind::Gpu,
                    _ => sim::Kind::None,
                };
            }
            e.rid = match rids.get(i) {
                Some(id) if id != 0 => Some(Rid::new(id as u64)),
                _ => None,
            };
            e.time_in_w = time_in_w.get(i).map(|b| b != 0).unwrap_or(false);
        }
        s.ctx.comp_basis = M3::from_godot(&comp_basis);
        s.ctx.comp_loc = comp_loc;
        s.init();
    }

    /// One component tick: the emitters (Tick), then the particle events. `space` = the world's direct space
    /// state for UParticleModuleCollision traces (null: no collisions). Returns true once every emitter completed.
    #[func]
    fn tick(&mut self, dt: f64, comp_basis: Basis, comp_loc: Vector3, part_sys_velocity: Vector3, camera_ue: Vector3, space: Option<Gd<PhysicsDirectSpaceState3D>>) -> bool {
        let Some(s) = self.sys.as_mut() else { return true };
        s.ctx.comp_basis = M3::from_godot(&comp_basis);
        s.ctx.comp_loc = comp_loc;
        s.ctx.part_sys_velocity = part_sys_velocity;
        s.ctx.camera_ue = camera_ue;
        s.ctx.space = space;
        s.tick(dt);
        s.ctx.space = None;
        s.completed()
    }

    /// Live particles per emitter.
    #[func]
    fn counts(&self) -> PackedInt32Array {
        let mut out = PackedInt32Array::new();
        if let Some(s) = self.sys.as_ref() {
            for e in &s.emitters {
                out.push(e.n as i32);
            }
        }
        out
    }

    /// Writes every rendered emitter's instances (capacity `caps[i]`, the MultiMesh instance_count) into its
    /// MultiMesh buffer for the camera's global transform.
    #[func]
    fn render(&mut self, cam: Transform3D, caps: PackedInt32Array) {
        let Some(s) = self.sys.as_mut() else { return };
        let camx = Xf { b: M3::from_godot(&cam.basis), o: cam.origin };
        let cb = s.ctx.comp_basis;
        let mut rs = RenderingServer::singleton();
        for (i, e) in s.emitters.iter_mut().enumerate() {
            let Some(rid) = e.rid else { continue };
            let cap = caps.get(i).unwrap_or(0).max(0) as usize;
            if cap == 0 || e.n == 0 {
                continue;
            }
            e.fill_buffer(&camx, cap, &cb);
            if let Some(b) = e.buf.as_ref() {
                rs.multimesh_set_buffer(rid, b);
            }
        }
    }

    /// The particle lights (UParticleModuleLight) to draw this frame: 9 floats per light, see Emitter::gather_lights.
    #[func]
    fn lights(&self) -> PackedFloat32Array {
        let mut v: Vec<f32> = vec![];
        if let Some(s) = self.sys.as_ref() {
            for e in &s.emitters {
                e.gather_lights(&mut v);
            }
        }
        PackedFloat32Array::from(v.as_slice())
    }

    /// True when any emitter has a Light module (the node keeps a light pool only then).
    #[func]
    fn has_lights(&self) -> bool {
        self.sys.as_ref().map(|s| s.emitters.iter().any(|e| e.has_light)).unwrap_or(false)
    }

    #[func]
    fn completed(&self) -> bool {
        self.sys.as_ref().map(|s| s.completed()).unwrap_or(true)
    }

    /// DI2Particles.checksum's formula over every live particle (A/B against the GDScript simulation).
    #[func]
    fn checksum(&self) -> f64 {
        self.sys.as_ref().map(|s| s.emitters.iter().map(|e| e.checksum()).sum()).unwrap_or(0.0)
    }

    /// Parses game/data/particles.json now (DI2Particles.db() calls it, so the first hit doesn't pay for it).
    #[func]
    fn preload() -> bool {
        db().is_some()
    }

    /// One particle's state (tests / debug).
    #[func]
    fn particle(&self, emitter: i64, i: i64) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(s) = self.sys.as_ref() else { return d };
        let Some(e) = s.emitters.get(emitter.max(0) as usize) else { return d };
        let i = i.max(0) as usize;
        if i >= e.n {
            return d;
        }
        d.set(&"loc".to_variant(), &e.loc[i].to_variant());
        d.set(&"vel".to_variant(), &e.vel[i].to_variant());
        d.set(&"size".to_variant(), &e.size[i].to_variant());
        d.set(&"col".to_variant(), &e.col[i].to_variant());
        d.set(&"rel".to_variant(), &(e.rel[i] as f64).to_variant());
        d.set(&"rot".to_variant(), &(e.rot[i] as f64).to_variant());
        d.set(&"dyn".to_variant(), &e.dyn_[i].to_variant());
        d
    }

    /// The first `n` RandomNumberGenerator.randf() values for `seed` (checks the PCG port against Godot's).
    #[func]
    fn rng_test(seed: i64, n: i64) -> PackedFloat64Array {
        let mut r = dist::Rng::seeded(seed as u64);
        let mut out = PackedFloat64Array::new();
        for _ in 0..n.max(0) {
            out.push(r.randf());
        }
        out
    }
}
