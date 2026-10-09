//! DI2's splatter render-target bake on the GPU (the way DI2 does it): one compute dispatch per stamp application
//! over a section's covered UV0 texels (game/shaders/compute/splatter_apply.glsl), then the H / V dilation
//! (splatter_dilate.glsl). The targets are storage textures the materials sample directly through Texture2DRD, so
//! nothing goes back through the CPU. gore-core's `splatter_rt` is the CPU twin and the fallback when there is no
//! RenderingDevice (Compatibility renderer, headless).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use godot::classes::rendering_device::{DataFormat, SamplerFilter, SamplerRepeatMode, TextureUsageBits, UniformType};
use godot::classes::{RdSamplerState, RdShaderFile, RdTextureFormat, RdTextureView, RdUniform, RenderingDevice, RenderingServer, Texture2Drd};
use godot::prelude::*;
use godot::tools::try_load;

use gore_core::splatter::Stamp;
use gore_core::splatter_rt::TexelMap;

const APPLY_SHADER: &str = "res://shaders/compute/splatter_apply.glsl";
const DILATE_SHADER: &str = "res://shaders/compute/splatter_dilate.glsl";
/// Longer than a severed piece lives (zombie.gd frees them after 60 s).
const GRAVE_SECONDS: f64 = 90.0;

/// Shared pipelines and the dilation scratch targets (one pair per resolution).
pub struct GpuBake {
    rd: Gd<RenderingDevice>,
    apply_shader: Rid,
    apply_pipe: Rid,
    dilate_shader: Rid,
    dilate_pipe: Rid,
    sampler: Rid,
    scratch: HashMap<usize, (Rid, Rid)>,
    /// Covered-texel buffers by section geometry key (shared by every body of the mesh): (buffer, texel count).
    texels: HashMap<(usize, usize, [u32; 3]), (Rid, u32)>,
    /// Targets of deleted bodies, freed once nothing can still sample them (severed pieces share the materials and
    /// live up to 60 s): (free after, rids).
    graveyard: Vec<(f64, Vec<Rid>)>,
}

thread_local! {
    static GPU: RefCell<Option<Rc<RefCell<GpuBake>>>> = const { RefCell::new(None) };
}

fn shader(rd: &mut Gd<RenderingDevice>, path: &str) -> Option<Rid> {
    let file = try_load::<RdShaderFile>(path).ok()?;
    let spirv = file.get_spirv()?;
    let err = spirv.get_stage_compile_error(godot::classes::rendering_device::ShaderStage::COMPUTE);
    if !err.is_empty() {
        godot_error!("GoreBody: {path}: {err}");
        return None;
    }
    let rid = rd.shader_create_from_spirv(&spirv);
    rid.is_valid().then_some(rid)
}

/// Drops the shared GPU bake (its Godot objects) while the engine is still alive (ExtensionLibrary::on_stage_deinit).
pub fn release() {
    GPU.with(|g| g.borrow_mut().take());
}

/// The shared GPU bake, if this renderer has a RenderingDevice and the shaders compile.
pub fn gpu() -> Option<Rc<RefCell<GpuBake>>> {
    GPU.with(|g| {
        if let Some(b) = g.borrow().as_ref() {
            return Some(b.clone());
        }
        let mut rd = RenderingServer::singleton().get_rendering_device()?;
        let apply_shader = shader(&mut rd, APPLY_SHADER)?;
        let dilate_shader = shader(&mut rd, DILATE_SHADER)?;
        let apply_pipe = rd.compute_pipeline_create(apply_shader);
        let dilate_pipe = rd.compute_pipeline_create(dilate_shader);
        let mut ss = RdSamplerState::new_gd();
        ss.set_mag_filter(SamplerFilter::LINEAR);
        ss.set_min_filter(SamplerFilter::LINEAR);
        ss.set_repeat_u(SamplerRepeatMode::CLAMP_TO_EDGE);
        ss.set_repeat_v(SamplerRepeatMode::CLAMP_TO_EDGE);
        let sampler = rd.sampler_create(&ss);
        let b = Rc::new(RefCell::new(GpuBake { rd, apply_shader, apply_pipe, dilate_shader, dilate_pipe, sampler, scratch: HashMap::new(), texels: HashMap::new(), graveyard: Vec::new() }));
        *g.borrow_mut() = Some(b.clone());
        Some(b)
    })
}

fn uniform(kind: UniformType, binding: i32, ids: &[Rid]) -> Gd<RdUniform> {
    let mut u = RdUniform::new_gd();
    u.set_uniform_type(kind);
    u.set_binding(binding);
    for id in ids {
        u.add_id(*id);
    }
    u
}

/// One section's targets on the GPU.
pub struct GpuSection {
    pub disp: Rid,
    pub dif: Rid,
    pub disp_tex: Gd<Texture2Drd>,
    pub dif_tex: Gd<Texture2Drd>,
    /// This body's skinned vertices of the section (vec4 position, vec4 normal), refreshed when a posed stamp lands.
    posed: Rid,
    verts: u32,
    count: u32,
    res: usize,
    apply_set: Rid,
    dilate_h: Rid,
    dilate_v: Rid,
}

impl GpuBake {
    fn target(&mut self, res: usize) -> Rid {
        let mut f = RdTextureFormat::new_gd();
        f.set_format(DataFormat::R8G8B8A8_UNORM);
        f.set_width(res as u32);
        f.set_height(res as u32);
        let bits = TextureUsageBits::SAMPLING_BIT.ord() | TextureUsageBits::STORAGE_BIT.ord() | TextureUsageBits::CAN_UPDATE_BIT.ord() | TextureUsageBits::CAN_COPY_FROM_BIT.ord();
        f.set_usage_bits(TextureUsageBits::from_ord(bits));
        let zero = PackedByteArray::from(vec![0u8; res * res * 4].as_slice());
        let data: Array<PackedByteArray> = Array::from(&[zero]);
        self.rd.texture_create_ex(&f, &RdTextureView::new_gd()).data(&data).done()
    }

    /// Allocates a section's targets (zeroed) and binds them to its covered-texel list (`key`: section geometry).
    pub fn section(&mut self, key: (usize, usize, [u32; 3]), map: &TexelMap, stamps: Rid, verts: usize) -> Option<GpuSection> {
        let res = map.res;
        let (texels, count) = match self.texels.get(&key) {
            Some(t) => *t,
            None => {
                let mut bytes: Vec<u8> = Vec::with_capacity(map.texel.len() * 64);
                for i in 0..map.texel.len() {
                    let (p, n) = (map.pos[i], map.nrm[i]);
                    for v in [p.x, p.y, p.z, map.dlen_cm[i], n.x, n.y, n.z, map.texel[i] as f32] {
                        bytes.extend_from_slice(&v.to_le_bytes());
                    }
                    for v in [map.tri[i][0], map.tri[i][1], map.tri[i][2], 0] {
                        bytes.extend_from_slice(&v.to_le_bytes());
                    }
                    for v in [map.bary[i][0], map.bary[i][1], map.bary[i][2], 0.0] {
                        bytes.extend_from_slice(&v.to_le_bytes());
                    }
                }
                if bytes.is_empty() {
                    return None;
                }
                let pb = PackedByteArray::from(bytes.as_slice());
                let buf = self.rd.storage_buffer_create_ex(bytes.len() as u32).data(&pb).done();
                self.texels.insert(key, (buf, map.texel.len() as u32));
                (buf, map.texel.len() as u32)
            }
        };
        let disp = self.target(res);
        let dif = self.target(res);
        let posed = self.rd.storage_buffer_create((verts.max(1) * 32) as u32);
        if !self.scratch.contains_key(&res) {
            let s = (self.target(res), self.target(res));
            self.scratch.insert(res, s);
        }
        let (s0, s1) = self.scratch[&res];
        let apply_set = self.rd.uniform_set_create(
            &Array::from(&[
                uniform(UniformType::STORAGE_BUFFER, 0, &[texels]),
                uniform(UniformType::IMAGE, 1, &[disp]),
                uniform(UniformType::IMAGE, 2, &[dif]),
                uniform(UniformType::SAMPLER_WITH_TEXTURE, 3, &[self.sampler, stamps]),
                uniform(UniformType::STORAGE_BUFFER, 4, &[posed]),
            ]),
            self.apply_shader,
            0,
        );
        let images = |a: Rid, b: Rid, c: Rid, d: Rid| {
            Array::from(&[uniform(UniformType::IMAGE, 0, &[a]), uniform(UniformType::IMAGE, 1, &[b]), uniform(UniformType::IMAGE, 2, &[c]), uniform(UniformType::IMAGE, 3, &[d])])
        };
        let dilate_h = self.rd.uniform_set_create(&images(disp, dif, s0, s1), self.dilate_shader, 0);
        let dilate_v = self.rd.uniform_set_create(&images(s0, s1, disp, dif), self.dilate_shader, 0);
        let mut disp_tex = Texture2Drd::new_gd();
        disp_tex.set_texture_rd_rid(disp);
        let mut dif_tex = Texture2Drd::new_gd();
        dif_tex.set_texture_rd_rid(dif);
        Some(GpuSection { disp, dif, disp_tex, dif_tex, posed, verts: verts as u32, count, res, apply_set, dilate_h, dilate_v })
    }

    /// Uploads a section's skinned vertices (position, normal; stamp space) for posed stamps.
    pub fn upload_posed(&mut self, sec: &GpuSection, pos: &[gore_core::glam::Vec3], nrm: &[gore_core::glam::Vec3]) {
        let n = (sec.verts as usize).min(pos.len()).min(nrm.len());
        if n == 0 {
            return;
        }
        let mut bytes: Vec<u8> = Vec::with_capacity(n * 32);
        for i in 0..n {
            for v in [pos[i].x, pos[i].y, pos[i].z, 1.0, nrm[i].x, nrm[i].y, nrm[i].z, 0.0] {
                bytes.extend_from_slice(&v.to_le_bytes());
            }
        }
        self.rd.buffer_update(sec.posed, 0, bytes.len() as u32, &PackedByteArray::from(bytes.as_slice()));
    }

    /// Runs the queued applications (section, stamp, cloth, posed, radial rows) in order, each followed by the
    /// H / V dilation. `radial` = (radial decal matrix row y, SafeRegionMatrix rows y, z) for the cut band.
    pub fn run(&mut self, jobs: &[(&GpuSection, Stamp, bool, bool, Option<[[f32; 4]; 3]>)]) {
        if jobs.is_empty() {
            return;
        }
        let rd = &mut self.rd;
        let list = rd.compute_list_begin();
        for (sec, s, cloth, posed, radial) in jobs {
            let pc = push_constants(s, *cloth, sec.count, *posed, radial.as_ref());
            rd.compute_list_bind_compute_pipeline(list, self.apply_pipe);
            rd.compute_list_bind_uniform_set(list, sec.apply_set, 0);
            rd.compute_list_set_push_constant(list, &pc, pc.len() as u32);
            rd.compute_list_dispatch(list, sec.count.div_ceil(64), 1, 1);
            rd.compute_list_add_barrier(list);
            let groups = (sec.res as u32).div_ceil(8);
            for (set, dir) in [(sec.dilate_h, [1i32, 0, 1, 0]), (sec.dilate_v, [0, 1, 0, 0])] {
                let bytes: Vec<u8> = dir.iter().flat_map(|v| v.to_le_bytes()).collect();
                let pcd = PackedByteArray::from(bytes.as_slice());
                rd.compute_list_bind_compute_pipeline(list, self.dilate_pipe);
                rd.compute_list_bind_uniform_set(list, set, 0);
                rd.compute_list_set_push_constant(list, &pcd, pcd.len() as u32);
                rd.compute_list_dispatch(list, groups, groups, 1);
                rd.compute_list_add_barrier(list);
            }
        }
        rd.compute_list_end();
    }

    /// Clears a section's targets: `Some(v)` sets every channel of both to v; `None` (clothing under ClearToValue)
    /// zeroes Disp.R and Disp.A only. Runs through the RD queue, so it orders with the queued bake jobs.
    pub fn clear(&mut self, sec: &GpuSection, value: Option<f32>) {
        match value {
            Some(v) => {
                let c = Color::from_rgba(v, v, v, v);
                self.rd.texture_clear(sec.disp, c, 0, 1, 0, 1);
                self.rd.texture_clear(sec.dif, c, 0, 1, 0, 1);
            }
            None => {
                // Disp.G / B must survive: read back (a sync stall; ClearToValue is rare), zero R and A, write.
                let data = self.rd.texture_get_data(sec.disp, 0);
                let mut bytes = data.as_slice().to_vec();
                for px in bytes.chunks_exact_mut(4) {
                    px[0] = 0;
                    px[3] = 0;
                }
                self.rd.texture_update(sec.disp, 0, &PackedByteArray::from(bytes.as_slice()));
            }
        }
    }

    /// Queues a deleted body's section for freeing after `GRAVE_SECONDS` (its pieces may still sample it).
    pub fn free(&mut self, sec: &GpuSection) {
        let now = godot::classes::Time::singleton().get_ticks_msec() as f64 / 1000.0;
        self.graveyard.push((now + GRAVE_SECONDS, vec![sec.apply_set, sec.dilate_h, sec.dilate_v, sec.disp, sec.dif, sec.posed]));
    }

    /// Frees the queued targets whose grace period is over.
    pub fn collect(&mut self) {
        let now = godot::classes::Time::singleton().get_ticks_msec() as f64 / 1000.0;
        let (due, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut self.graveyard).into_iter().partition(|(t, _)| *t <= now);
        self.graveyard = keep;
        for (_, rids) in due {
            for rid in rids {
                if rid.is_valid() {
                    self.rd.free_rid(rid);
                }
            }
        }
    }
}

/// splatter_apply.glsl's push constants (8 x vec4).
fn push_constants(s: &Stamp, cloth: bool, count: u32, posed: bool, radial: Option<&[[f32; 4]; 3]>) -> PackedByteArray {
    let depth = s.depth * if cloth { s.cloth_depth } else { 1.0 };
    let w0 = s.wound[0] * if cloth { s.cloth_displacement } else { 1.0 };
    let (r0, r1, r2) = match radial {
        Some(r) => (r[0], r[1], r[2]),
        None => ([s.origin.x, s.origin.y, s.origin.z, s.half_size], [s.ax.x, s.ax.y, s.ax.z, depth], [s.ay.x, s.ay.y, s.ay.z, s.fade_gain]),
    };
    let v: [f32; 32] = [
        r0[0], r0[1], r0[2], r0[3],
        r1[0], r1[1], r1[2], r1[3],
        r2[0], r2[1], r2[2], r2[3],
        s.az.x, s.az.y, s.az.z, s.angle_wrap,
        s.displacement_tex as f32, s.diffuse_tex as f32, s.flags as f32, count as f32,
        w0, s.wound[1], s.wound[2], if cloth { 1.0 } else { 0.0 },
        s.fx[0], s.fx[1], s.fx[2], s.fx[3],
        s.range[0], s.range[1], if posed { 1.0 } else { 0.0 }, if radial.is_some() { 1.0 } else { 0.0 },
    ];
    let bytes: Vec<u8> = v.iter().flat_map(|f| f.to_le_bytes()).collect();
    PackedByteArray::from(bytes.as_slice())
}

/// The stamp texture array as an RD texture (for the compute sampler).
pub fn rd_texture(tex: &Gd<godot::classes::Texture2DArray>) -> Rid {
    RenderingServer::singleton().texture_get_rd_texture(tex.get_rid())
}
