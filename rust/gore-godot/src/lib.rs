//! Godot 4 bindings for gore-core.
//!
//! `GoreBody` sits under a character whose skinned meshes hang off a `Skeleton3D`. On ready it:
//! - mirrors the skeleton into gore-core and loads the archetype (DI2 data or hand-written JSON);
//! - bakes per-vertex data into the meshes' custom channels (shared per source mesh):
//!   CUSTOM0 = bind-pose position, CUSTOM1..3 = skin weight inside each cut slot's bone subtree;
//! - swaps the surfaces to flesh shader materials using the asset's materials manifest.
//!
//! When a part is severed, `add_cut_caps()` closes the hole on the body and on the flying piece with a cap
//! built from the exact edge of the cut (see `build_cap`).
//!
//! Gameplay calls `hit()` with a world-space impact; the outcome list drives the scene side
//! (severed pieces, ragdolls, FX) and the wound field / severed mask go straight to the shaders.
//! The impact is first refined against the posed mesh itself (CPU-skinned like the GPU draws it), so the
//! damaged part and the wound are exactly where the hit landed on the moving body, not on a hitbox capsule.
//! Limbs are cut where they're hit: at the nearest of DI2's cut positions along the bone (its VisceraProxy
//! boxes, game/data/cut_points.json), as a plane in bind space per cut slot.

use std::collections::HashMap;
use std::rc::Rc;

mod caps;
mod particles;

use godot::classes::mesh::{ArrayFormat, ArrayType, PrimitiveType};
use godot::classes::{
    ArrayMesh, FileAccess, INode, Image, ImageTexture, Material, Mesh, MeshInstance3D, Node, Shader, ShaderMaterial, Skeleton3D, Skin, Texture2D, Texture2DArray, file_access::ModeFlags,
};
use godot::prelude::*;
use godot::tools::try_load;

use gore_core::glam::Vec3 as GVec3;
use gore_core::{Archetype, Body, Brain, DamageKind, Hit, Outcome, PartRole, PartState, Perception, Skeleton, Splatter, Stamp, Status, WoundChannel, WoundField, WoundScale};
use gore_core::splatter::frame;
use gore_core::splatter_rt::{SplatterRt, TexelMap};
use gore_core::dismember::{break_section, classify_section, f16_round, radial_vertex_depth, split_indices, DecalFrame, DismemberData, RadialElement, RegionKind};

mod gpu_bake;
use gpu_bake::GpuSection;
use gore_core::glam::Vec3 as SVec3;

struct GoreExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GoreExtension {
    fn on_stage_deinit(stage: InitStage) {
        // Baked meshes and the GPU bake are Godot objects: release them while the engine is still alive (a
        // thread-local destructor runs after it is gone, and releasing a Gd then panics).
        if stage == InitStage::Scene {
            BAKED.with(|c| c.borrow_mut().clear());
            gpu_bake::release();
        }
    }
}

const SLOTS: usize = 12;
const FLESH_SHADER: &str = "res://shaders/flesh.gdshader";
/// M_EyeOcclusion sections (layer "eye_overlay"): translucent screen-space overlay, its own shader.
const EYE_OCCLUSION_SHADER: &str = "res://shaders/eye_occlusion.gdshader";
/// M_EyeRefractive sections (layer "eye"): their own shader for UE's MSM_Eye lighting (a custom light()).
const EYE_SHADER: &str = "res://shaders/eye.gdshader";
/// Flesh shader layer id of cut caps.
const CAP_LAYER: i32 = 8;
/// Stamps a body keeps (pre-spawn sets + hits); the oldest hit stamps make room beyond this.
const STAMP_CAPACITY: usize = 160;

/// Metres per texture repeat on a cap face (DI2's breakage flesh texture).
const CAP_UV_SCALE: f32 = 0.16;
/// Cut-plane distance (m) to slot-weight units: both decide which side of a cut a point is on.
const PLANE_SCALE: f32 = 12.0;
/// How far in front of the hitbox impact the surface ray starts, and how far it looks.
const RAY_BACK: f32 = 0.3;
const RAY_LENGTH: f32 = 0.65;

thread_local! {
    /// Baked meshes keyed by (source mesh instance id, slot signature) so every zombie of a type shares them,
    /// with the CPU copy of their skinning and slot weights that cut caps are built from.
    static BAKED: std::cell::RefCell<HashMap<(i64, String), (Gd<ArrayMesh>, Rc<MeshCpu>)>> = Default::default();
}
thread_local! {
    /// Splatter texel maps by section geometry (vertex count, index count, first position), shared across bodies.
    static TEXMAPS: std::cell::RefCell<HashMap<(usize, usize, [u32; 3]), Rc<TexelMap>>> = Default::default();
    /// data/flesh_materials.json, parsed once per path.
    static FLESH_DATA: std::cell::RefCell<HashMap<String, Rc<serde_json::Value>>> = Default::default();
    /// Raw FLESH PNGs (gdignored folder: loaded with Image, not the importer), by path.
    /// Never dropped: the thread-local destructor runs after the engine is gone (releasing Gd then panics).
    static FLESH_TEX: std::mem::ManuallyDrop<std::cell::RefCell<HashMap<String, Gd<ImageTexture>>>> = Default::default();
}


/// CPU copy of one baked surface: bind-pose positions, skinning (bind indices, `per` per vertex) and cut-slot weights.
struct SurfaceCpu {
    verts: Vec<Vector3>,
    /// Bind-pose normals (DI2's deform CS angle wrap).
    normals: Vec<Vector3>,
    /// DI2 deform vector per vertex (bind pose, metres); empty when the stream isn't available.
    deform: Vec<Vector3>,
    bones: Vec<i32>,
    weights: Vec<f32>,
    per: usize,
    slot_w: Vec<[f32; SLOTS]>,
    indices: Vec<i32>,
    /// UV0, the space DI2's splatter render targets live in.
    uv: Vec<[f32; 2]>,
    /// UV0 texel -> bind-pose position / normal / deform length (built on the section's first splatter).
    texmap: std::cell::OnceCell<Rc<TexelMap>>,
}

type MeshCpu = Vec<SurfaceCpu>;

/// DI2 splatter render-target size per section (r.Splatter.TextureReduction / group sizes are [CPU], UNVERIFIED #45).
const SPLATTER_RT_RES: usize = 512;

/// One section's targets: baked on the GPU (storage textures sampled directly) or, without a RenderingDevice,
/// on the CPU and uploaded.
enum SectionTargets {
    Gpu(GpuSection),
    Cpu(SectionRt),
}

/// One section's DispSplatterRT / DiffuseSplatterRT (CPU bake) and their GPU copies.
struct SectionRt {
    rt: SplatterRt,
    disp: Gd<ImageTexture>,
    dif: Gd<ImageTexture>,
    /// Written since the last upload (uploads happen once per frame, in `flush_splatter`).
    dirty: bool,
}

/// RGBA8 texels as bytes (no copy).
fn rgba_bytes(px: &[[u8; 4]]) -> &[u8] {
    // SAFETY: [u8; 4] has size 4, alignment 1 and no padding.
    unsafe { std::slice::from_raw_parts(px.as_ptr() as *const u8, px.len() * 4) }
}

fn to_glam(v: Vector3) -> GVec3 {
    GVec3::new(v.x, v.y, v.z)
}

fn read_text(path: &str) -> Option<String> {
    FileAccess::open(path, ModeFlags::READ).map(|f| f.get_as_text().to_string())
}

struct Surface {
    mi: Gd<MeshInstance3D>,
    /// Per surface: material and flesh shader layer.
    materials: Vec<Gd<ShaderMaterial>>,
    layers: Vec<i32>,
    bone_to_bind: HashMap<i32, i32>,
    /// Skeleton bone of each skin bind (-1 if unresolved).
    bind_to_bone: Vec<i32>,
    skin: Option<Gd<Skin>>,
    cpu: Rc<MeshCpu>,
    /// The baked mesh is shared between bodies; the first vertex sink gives this body its own copy.
    own_mesh: bool,
    /// Per section: its splatter render targets (skin / cloth sections, allocated on first write).
    rts: Vec<Option<SectionTargets>>,
    /// Per section: the section whose targets it samples, and whether at UV1 (eyes, overlay, hair -> the head's).
    rt_source: Vec<Option<(usize, bool)>>,
    /// Per section: cached vertex buffer (stride, bytes) for the deform sink.
    vbuf: Vec<Option<(usize, Vec<u8>)>>,
    /// Per section: DI2 subsection names (index = the id packed in CUSTOM0.w) and which are hidden.
    sub_names: Vec<Vec<String>>,
    sub_hidden: Vec<u64>,
    /// The body's own glb mesh (not a shared part mesh): what DI2's dismember edits.
    is_body: bool,
    /// Per section: the triangles drawn now, once a DI2 cut has edited them (None = the baked ones).
    cur_indices: Vec<Option<Vec<i32>>>,
    /// Per section: bind-pose bounds (which sections a posed stamp can reach).
    bind_bounds: Vec<(GVec3, GVec3)>,
    /// The skin's bind poses (constant), cached so posed skinning doesn't fetch them every frame.
    bind_poses: Vec<Transform3D>,
}

/// Where a ray met the visible body: skeleton bone with the most weight there, bind-pose point, world
/// point, and the ray / weapon directions taken into bind pose through the skinning at that point.
struct SurfaceHit {
    bone: usize,
    rest: Vector3,
    world: Vector3,
    rest_into: Vector3,
    rest_dir: Vector3,
    /// Bind-pose normal of the triangle hit, facing the incoming ray.
    rest_normal: Vector3,
    /// World up carried into bind pose by the skinning at the impact.
    rest_up: Vector3,
}

/// Signed side of a slot's cut plane (normal towards the severed side, offset), in slot-weight units.
/// A zero plane means the cut sits at the joint, where the skin weights alone decide.
pub(crate) fn plane_side(plane: Vector4, p: Vector3) -> f32 {
    let n = Vector3::new(plane.x, plane.y, plane.z);
    if n.length_squared() < 0.25 {
        1.0
    } else {
        (n.dot(p) - plane.w) * PLANE_SCALE
    }
}

#[derive(GodotClass)]
#[class(base=Node)]
pub struct GoreBody {
    base: Base<Node>,
    /// Archetype name in `archetypes_path` (e.g. "Walker"), or empty for the built-in Walker.
    #[export]
    archetype: GString,
    #[export]
    archetypes_path: GString,
    /// Skeleton the meshes are skinned to.
    #[export]
    skeleton_path: NodePath,
    /// `<asset>.materials.json` written by tools/pack_materials.py; texture paths are relative to it.
    #[export]
    materials_manifest: GString,
    /// Folder with the splatter textures (gore gradient, wound noise, drips, ...).
    #[export]
    splatter_dir: GString,
    /// Gore gradient texture name inside `splatter_dir` (DI2 has Walker/Runner/Shambler ramps).
    #[export]
    gore_gradient: GString,
    #[export]
    seed: i64,
    /// Materials manifest holding the cut-cap flesh material (DI2's breakage texture set).
    #[export]
    cap_manifest: GString,
    #[export]
    cap_material: GString,
    /// DI2's cut positions along each limb bone (tools/convert_cut_points.py).
    #[export]
    cut_points_path: GString,
    /// DI2 per-vertex deform vectors (`<body>.deform.bin`: float32 xyz per vertex, glb primitive order, glTF
    /// space, recon/DEFORM_STREAM.md). Empty / missing = not decoded: the shader's normal-push stand-in is used.
    #[export]
    deform_path: GString,
    /// DI2 mesh subsections per glb vertex (tools/build_subsections.py): what viscera / skull / bone culling hides.
    #[export]
    subsections_path: GString,
    /// DI2 FLESH material data (tools/shaders/build_flesh_materials.py): per material section, the splatter
    /// parameters and textures resolved through its MI chain; textures in `flesh_dir` (raw PNGs, gdignored).
    #[export]
    flesh_materials_path: GString,
    #[export]
    flesh_dir: GString,
    /// Draw gore-core's procedural wound fields. DI2 draws every wound as a FLESH splatter stamp
    /// (add_stamp / add_stamp_rest); the fields stay the gameplay record either way.
    #[export]
    procedural_wounds: bool,

    body: Option<Body>,
    wounds: Option<WoundField>,
    brain: Option<Brain>,
    skeleton: Option<Gd<Skeleton3D>>,
    surfaces: Vec<Surface>,
    slots: Vec<usize>,
    cap_template: Option<Gd<ShaderMaterial>>,
    /// Bone -> (next limb bone, cut fractions along it).
    cut_points: HashMap<usize, (usize, Vec<f32>)>,
    /// Per cut slot: its cut plane (see `plane_side`) and where along the bone it sits (0 = joint).
    planes: [Vector4; SLOTS],
    cut_t: [f32; SLOTS],
    /// Materials of the body's own caps, kept in sync with the wound field like the body surfaces.
    cap_materials: Vec<Gd<ShaderMaterial>>,
    dirty: bool,
    /// DI2 FLESH splatter stamps (gore-core splatter.rs) and their GPU data texture.
    splatter: Splatter,
    stamp_tex: Option<Gd<Texture2DArray>>,
    /// RGBA8 of every stamp texture layer: the deform CS point-samples R, the render-target bake samples RGBA.
    stamp_px: Vec<(i32, i32, Vec<u8>)>,
    /// Per surface, per section: DI2's accumulated per-vertex wound depth (FSplatterDeformMeshCS) and its texture.
    vdepth: Vec<Vec<Vec<f32>>>,
    vdepth_tex: Vec<Vec<Option<Gd<ImageTexture>>>>,
    vdepth_dirty: Vec<Vec<bool>>,
    /// Per section: the vertex range [lo, hi) whose depth changed since the last sink (usize::MAX, 0 = none).
    vdepth_range: Vec<Vec<(usize, usize)>>,
    /// Events raised outside hit() (e.g. death by burning), drained by take_events().
    events: Vec<String>,
    /// Splatter bake cost: applications, total and worst milliseconds.
    bake_stats: (u32, f64, f64),
    /// Bake phase totals (ms): texel-map builds, element apply, dilation.
    bake_phases: [f64; 5],
    /// Total GoreBody.process time (ms): flushes, core ticks, uniform pushes.
    process_ms: f64,
    /// Time skinning sections for posed stamps (ms).
    process_ms_skin: f64,
    /// GPU bake jobs queued this frame: (surface, section, stamp, cloth, posed), run in order by `flush_splatter`.
    gpu_jobs: Vec<(usize, usize, Stamp, bool, bool, Option<[[f32; 4]; 3]>)>,
    /// DI2 dismember data of this body (game/assets/di2/<body>/<body>.dismember.json), loaded on the first cut.
    dismember: Option<Rc<DismemberData>>,
    /// Skin / cloth sections skinned at this frame's hits (DI2 FSplatterVS_World): per surface, per section
    /// (world positions, world normals, bounds), and the frame they belong to.
    posed: Vec<Vec<Option<(Vec<GVec3>, Vec<GVec3>, GVec3, GVec3)>>>,
    posed_frame: u64,
    /// Skeleton bones' world transforms for `posed_frame` (filled on the first posed stamp of a frame).
    bone_world: Vec<Transform3D>,
    /// Set by set_radial_part_budget, taken by the next hit_ex.
    radial_part_budget: Option<f32>,
    /// The next hit_ex's damage type (a weapon mod's converted element), consumed by it.
    next_damage_type: Option<DamageKind>,
    /// The last di2_cut's placed plane (glTF bind pose, metres; normal towards the limb).
    last_cut_plane: Option<(GVec3, GVec3)>,
    /// Per surface / section / vertex: skinned this frame (only what a posed stamp could reach is).
    posed_done: Vec<Vec<Vec<bool>>>,
    /// Sections whose skinned vertices the GPU needs before this frame's jobs run.
    posed_upload: Vec<(usize, usize)>,
}

#[godot_api]
impl INode for GoreBody {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            archetype: "Walker".into(),
            archetypes_path: "res://data/archetypes.json".into(),
            skeleton_path: NodePath::default(),
            materials_manifest: GString::new(),
            splatter_dir: "res://assets/di2/splatter".into(),
            gore_gradient: "T_GoreGradWalker.png".into(),
            seed: 1,
            cap_manifest: "res://assets/di2/gore/breakage.materials.json".into(),
            cap_material: "MI_Breakage".into(),
            cut_points_path: "res://data/cut_points.json".into(),
            procedural_wounds: true,
            flesh_materials_path: "res://data/flesh_materials.json".into(),
            flesh_dir: "res://assets/di2/flesh".into(),
            deform_path: GString::new(),
            subsections_path: GString::new(),
            body: None,
            wounds: None,
            splatter: Splatter::new(STAMP_CAPACITY),
            stamp_tex: None,
            stamp_px: Vec::new(),
            vdepth: Vec::new(),
            vdepth_tex: Vec::new(),
            vdepth_dirty: Vec::new(),
            vdepth_range: Vec::new(),
            brain: None,
            skeleton: None,
            surfaces: Vec::new(),
            slots: Vec::new(),
            cap_template: None,
            cut_points: HashMap::new(),
            planes: [Vector4::ZERO; SLOTS],
            cut_t: [0.0; SLOTS],
            cap_materials: Vec::new(),
            dirty: false,
            events: Vec::new(),
            bake_stats: (0, 0.0, 0.0),
            bake_phases: [0.0; 5],
            process_ms: 0.0,
            process_ms_skin: 0.0,
            gpu_jobs: Vec::new(),
            dismember: None,
            posed: Vec::new(),
            posed_frame: u64::MAX,
            bone_world: Vec::new(),
            radial_part_budget: None,
            next_damage_type: None,
            last_cut_plane: None,
            posed_done: Vec::new(),
            posed_upload: Vec::new(),
        }
    }

    fn ready(&mut self) {
        self.setup();
    }

    fn on_notification(&mut self, what: godot::classes::notify::NodeNotification) {
        if what == godot::classes::notify::NodeNotification::PREDELETE {
            if let Some(g) = gpu_bake::gpu() {
                for s in &self.surfaces {
                    for t in s.rts.iter().flatten() {
                        if let SectionTargets::Gpu(sec) = t {
                            g.borrow_mut().free(sec);
                        }
                    }
                }
            }
        }
    }

    fn process(&mut self, delta: f64) {
        let tp = std::time::Instant::now();
        self.process_inner(delta);
        self.process_ms += tp.elapsed().as_secs_f64() * 1000.0;
    }
}

impl GoreBody {
    fn process_inner(&mut self, delta: f64) {
        self.flush_splatter();
        let dt = delta as f32;
        if let Some(w) = self.wounds.as_mut() {
            if w.tick(dt) {
                self.dirty = true;
            }
        }
        if let Some(body) = self.body.as_mut() {
            let was_alive = body.alive;
            let outcomes = body.tick(dt);
            let burning = body.status.active(Status::Burning);
            let caustic = body.status.active(Status::Caustic);
            let shocked = body.status.active(Status::Electrified);
            if let Some(w) = self.wounds.as_mut() {
                if burning && w.intensify(WoundChannel::Burn, dt) { self.dirty = true; }
                if caustic && w.intensify(WoundChannel::Melt, dt) { self.dirty = true; }
                if shocked && w.intensify(WoundChannel::Scorch, dt * 0.5) { self.dirty = true; }
            }
            if was_alive && outcomes.iter().any(|o| matches!(o, Outcome::Killed { .. })) {
                self.events.push("killed_by_status".to_string());
                if let Some(b) = self.brain.as_mut() { b.on_death(); }
            }
        }
        if self.dirty {
            self.push_uniforms();
            self.dirty = false;
        }
    }
}

#[godot_api]
impl GoreBody {
    /// (Re)builds the simulation and visuals. Called automatically on ready.
    #[func]
    fn setup(&mut self) {
        let Some(skel) = self.base().try_get_node_as::<Skeleton3D>(&self.skeleton_path) else {
            godot_error!("GoreBody: skeleton_path does not point at a Skeleton3D");
            return;
        };
        let n = skel.get_bone_count();
        let names = (0..n).map(|i| skel.get_bone_name(i).to_string()).collect();
        let parents = (0..n).map(|i| usize::try_from(skel.get_bone_parent(i)).ok()).collect();
        let core_skel = Skeleton::new(names, parents);

        let archetype = self.load_archetype();
        let body = Body::new(archetype, core_skel, self.seed as u64);
        self.slots = body.cut_slots().into_iter().take(SLOTS).collect();
        self.wounds = Some(WoundField::new(WoundField::MAX, WoundScale::default(), self.seed as u64));
        self.brain = Some(Brain::new(self.seed as u64));
        self.cut_points = self.load_cut_points(&body);
        self.planes = [Vector4::ZERO; SLOTS];
        self.cut_t = [0.0; SLOTS];
        self.body = Some(body);
        self.skeleton = Some(skel.clone());
        self.bake_meshes(&skel);
        self.dirty = true;
    }

    /// Applies an impact. `bone` is the hit bone name; `world_point` the impact, `world_dir` the weapon's travel
    /// (swing tangent / bullet path) and `world_into` the direction into the body (view ray), all in world space.
    /// `kind` is one of blunt/sharp/projectile/explosive/fire/acid/electric. Returns
    /// `{outcomes: [{type, part, bone, force}], alive, crawling, health}`.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn hit(&mut self, bone: GString, world_point: Vector3, world_dir: Vector3, world_into: Vector3, damage: f32, kind: GString, heavy: bool, limb_mult: f32) -> VarDictionary {
        self.hit_ex(bone, world_point, world_dir, world_into, damage, kind, heavy, limb_mult, 0.0)
    }

    /// The next hit_ex is radial (an explosion): DI2's MultiPartHealth spreads `budget` part damage over the
    /// parts (gore-core Body::radial_part_events) instead of damaging the hit part.
    #[func]
    fn set_radial_part_budget(&mut self, budget: f32) {
        self.radial_part_budget = Some(budget.max(0.0));
    }

    /// `hit` plus DI2's force (stability damage, weapon Force attribute units) and elemental build-up per damage.
    /// Adds `{type: "reaction", reaction: light|medium|stumble|knockdown|launch}` and `{type: "status", status}` outcomes.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn hit_ex(&mut self, bone: GString, world_point: Vector3, world_dir: Vector3, world_into: Vector3, damage: f32, kind: GString, heavy: bool, limb_mult: f32, force: f32) -> VarDictionary {
        let Some(body) = self.body.as_ref() else { return VarDictionary::new() };
        let Some(bone_idx) = body.skeleton.find(&bone.to_string()) else {
            godot_warn!("GoreBody.hit: unknown bone {bone}");
            return VarDictionary::new();
        };
        let kind = DamageKind::from_name(&kind.to_string()).unwrap_or(DamageKind::Blunt);
        // The hitbox only says the zombie was hit; the mesh under the impact says where.
        let ray = world_into.normalized_or_zero();
        let exact = if ray.length_squared() > 0.5 { self.surface_hit(world_point - ray * RAY_BACK, ray, RAY_LENGTH, world_dir) } else { None };
        let (bone_idx, p, d, into, world_hit, normal, up) = match exact.as_ref() {
            Some(e) => (e.bone, to_glam(e.rest), to_glam(e.rest_dir), to_glam(e.rest_into), e.world, to_glam(e.rest_normal), to_glam(e.rest_up)),
            None => {
                let (p, d) = self.world_to_rest(bone_idx, world_point, world_dir);
                let (_, into) = self.world_to_rest(bone_idx, world_point, world_into);
                let (_, up) = self.world_to_rest(bone_idx, world_point, Vector3::UP);
                (bone_idx, p, d, into, world_point, -into, up)
            }
        };
        let mut h = Hit::new(bone_idx, damage, kind, p, d);
        h.into = into;
        h.heavy = heavy;
        h.limb_multiplier = if limb_mult > 0.0 { limb_mult } else { 1.0 };
        h.force = force;
        h.radial_part_budget = self.radial_part_budget.take();
        h.damage_type = self.next_damage_type.take();

        let body = self.body.as_mut().unwrap();
        let outcomes = body.apply_hit(&h);
        if !outcomes.is_empty() {
            self.wounds.as_mut().unwrap().add_hit(&h);
        }

        let mut list = VarArray::new();
        for o in &outcomes {
            let body = self.body.as_ref().unwrap();
            let part_name = |i: usize| GString::from(body.archetype.parts[i].id.as_str()).to_variant();
            let bone_name = |b: usize| GString::from(body.skeleton.names[b].as_str()).to_variant();
            let entry = match o {
                Outcome::Damaged { part, body_damage, part_damage } => dict(&[("type", ("damaged").to_variant()), ("part", (part.map(part_name).unwrap_or_else(|| GString::new().to_variant())).to_variant()), ("body_damage", (*body_damage).to_variant()), ("part_damage", (*part_damage).to_variant())]),
                Outcome::Broken { part, bone } => dict(&[("type", ("broken").to_variant()), ("part", (part_name(*part)).to_variant()), ("bone", (bone_name(*bone)).to_variant())]),
                Outcome::Dismembered { part, cut_bone, force } => dict(&[("type", ("dismembered").to_variant()), ("part", (part_name(*part)).to_variant()), ("bone", (bone_name(*cut_bone)).to_variant()), ("force", (*force).to_variant())]),
                Outcome::Crushed { part } => {
                    let cut = match body.parts[*part].state {
                        PartState::Dismembered { cut_bone } => bone_name(cut_bone),
                        _ => GString::new().to_variant(),
                    };
                    dict(&[("type", ("crushed").to_variant()), ("part", (part_name(*part)).to_variant()), ("bone", (cut).to_variant())])
                }
                Outcome::Staggered => dict(&[("type", ("staggered").to_variant())]),
                Outcome::Reacted { reaction } => dict(&[("type", ("reaction").to_variant()), ("reaction", (format!("{reaction:?}").to_lowercase()).to_variant())]),
                Outcome::StatusStarted { status } => dict(&[("type", ("status").to_variant()), ("status", (status.name()).to_variant())]),
                Outcome::BecameCrawler => dict(&[("type", ("crawler").to_variant())]),
                Outcome::Killed { reason } => dict(&[("type", ("killed").to_variant()), ("reason", (format!("{reason:?}")).to_variant())]),
            };
            list.push(&entry.to_variant());
            match o {
                Outcome::Dismembered { cut_bone, part, .. } => {
                    self.set_cut_plane(*cut_bone, Vector3::new(p.x, p.y, p.z));
                    self.add_stump(*cut_bone, *part);
                }
                Outcome::Staggered => self.brain.as_mut().unwrap().on_stagger(),
                Outcome::BecameCrawler => self.brain.as_mut().unwrap().on_became_crawler(),
                Outcome::Killed { .. } => self.brain.as_mut().unwrap().on_death(),
                _ => {}
            }
        }
        self.dirty = true;
        let body = self.body.as_ref().unwrap();
        let bone_name = GString::from(body.skeleton.names[bone_idx].as_str());
        // The outward surface normal at the hit in the world (the rest normal through the hit bone as posed).
        let world_normal = self
            .rest_to_world(&bone_name.to_string())
            .map(|m| (m.basis * Vector3::new(normal.x, normal.y, normal.z)).normalized_or_zero())
            .unwrap_or(-world_into.normalized_or_zero());
        let body = self.body.as_ref().unwrap();
        dict(&[
            ("normal", world_normal.to_variant()),
            ("outcomes", (list.to_variant()).to_variant()),
            ("alive", (body.alive).to_variant()),
            ("crawling", (body.crawling).to_variant()),
            ("health", (body.health).to_variant()),
            ("bone", bone_name.to_variant()),
            ("point", world_hit.to_variant()),
            ("exact", exact.is_some().to_variant()),
            // Bind-pose impact frame for FLESH stamps (add_stamp_rest): point, surface normal, view ray, weapon
            // travel and world up, all in the space the stamps live in.
            ("rest_point", Vector3::new(p.x, p.y, p.z).to_variant()),
            ("rest_normal", Vector3::new(normal.x, normal.y, normal.z).to_variant()),
            ("rest_into", Vector3::new(into.x, into.y, into.z).to_variant()),
            ("rest_dir", Vector3::new(d.x, d.y, d.z).to_variant()),
            ("rest_up", Vector3::new(up.x, up.y, up.z).to_variant()),
        ])
    }

    /// Where along `cut_bone` its cut sits (0 = at the joint, else the fraction towards the next limb bone).
    #[func]
    fn cut_fraction(&self, cut_bone: GString) -> f32 {
        let Some(body) = self.body.as_ref() else { return 0.0 };
        body.skeleton
            .find(&cut_bone.to_string())
            .and_then(|b| self.slots.iter().position(|&s| s == b))
            .map_or(0.0, |slot| self.cut_t[slot])
    }

    /// Ray against the visible (skin, cloth) body as currently posed. Returns `{bone, point, rest}` or an
    /// empty dictionary. For tools and tests; `hit()` does this itself.
    #[func]
    fn raycast(&self, from: Vector3, dir: Vector3, length: f32) -> VarDictionary {
        let Some(body) = self.body.as_ref() else { return VarDictionary::new() };
        let Some(h) = self.surface_hit(from, dir.normalized_or_zero(), length, dir) else { return VarDictionary::new() };
        dict(&[("bone", GString::from(body.skeleton.names[h.bone].as_str()).to_variant()), ("point", h.world.to_variant()), ("rest", h.rest.to_variant())])
    }

    /// Runs the zombie brain. Returns `{speed, face, anim, attack, damage}`.
    #[func]
    fn think(&mut self, dt: f32, distance: f32, can_see: bool) -> VarDictionary {
        let (Some(body), Some(brain)) = (self.body.as_ref(), self.brain.as_mut()) else { return VarDictionary::new() };
        let cmd = brain.tick(dt, body, &Perception { distance, can_see, facing_error: 0.0 });
        dict(&[("speed", (cmd.speed).to_variant()), ("face", (cmd.face_target).to_variant()), ("anim", (format!("{:?}", cmd.anim)).to_variant()), ("attack", (cmd.attack_started.unwrap_or_default()).to_variant()), ("damage", (cmd.deal_damage.unwrap_or(0.0)).to_variant())])
    }

    /// External stagger (kicks, perfect blocks).
    #[func]
    fn stagger(&mut self) {
        if let Some(b) = self.brain.as_mut() {
            b.on_stagger();
        }
    }

    #[func]
    fn is_alive(&self) -> bool {
        self.body.as_ref().is_some_and(|b| b.alive)
    }

    #[func]
    fn is_crawling(&self) -> bool {
        self.body.as_ref().is_some_and(|b| b.crawling)
    }

    /// Test/tuning hook: override character health.
    #[func]
    fn set_health(&mut self, health: f32) {
        if let Some(b) = self.body.as_mut() {
            b.health = health;
        }
    }

    #[func]
    fn get_health(&self) -> f32 {
        self.body.as_ref().map_or(0.0, |b| b.health)
    }

    /// `{part_id: {health, max, state, role}}` for debug HUDs.
    #[func]
    fn part_states(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(b) = self.body.as_ref() {
            for (i, p) in b.parts.iter().enumerate() {
                let state = match p.state {
                    PartState::Intact => "intact",
                    PartState::Broken => "broken",
                    PartState::Dismembered { .. } => "severed",
                };
                d.set(&b.archetype.parts[i].id.to_variant(), &dict(&[("health", (p.health).to_variant()), ("max", (p.max_health).to_variant()), ("state", (state).to_variant()), ("role", (format!("{:?}", p.role)).to_variant())]).to_variant());
            }
        }
        d
    }

    /// Bones of broken (dangling) parts, for the animation post-process.
    #[func]
    fn broken_bones(&self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        if let Some(b) = self.body.as_ref() {
            for p in b.parts.iter().filter(|p| p.state == PartState::Broken) {
                for &bone in &p.bones {
                    out.push(&GString::from(b.skeleton.names[bone].as_str()));
                }
            }
        }
        out
    }

    /// Whether an arm can still swing (for picking attack animations).
    #[func]
    fn arm_usable(&self, left: bool) -> bool {
        self.body.as_ref().is_some_and(|b| b.usable_arm(if left { PartRole::ArmLeft } else { PartRole::ArmRight }))
    }

    /// Turns a duplicated visual (MeshInstance3Ds under `piece_root`) into the severed piece below `cut_bone`:
    /// own material copies that keep only that subtree, and the wounds as they were at the moment of the cut.
    #[func]
    fn configure_piece(&self, piece_root: Gd<Node>, cut_bone: GString) {
        let (Some(body), Some(wounds)) = (self.body.as_ref(), self.wounds.as_ref()) else { return };
        let Some(bone) = body.skeleton.find(&cut_bone.to_string()) else { return };
        let Some(slot) = self.slots.iter().position(|&b| b == bone) else { return };
        // Hide pieces that were severed earlier from inside this subtree (e.g. the hand before the forearm).
        let earlier = body.severed_slot_mask() & !(1 << slot);
        let packed = PackedVector4Array::from_iter(wounds.pack().into_iter().map(|v| Vector4::new(v.x, v.y, v.z, v.w)));
        for mut mi in collect_meshes(&piece_root) {
            let count = mi.get_surface_override_material_count();
            for s in 0..count {
                let Some(mat) = mi.get_surface_override_material(s) else { continue };
                let Ok(mat) = mat.try_cast::<ShaderMaterial>() else { continue };
                let mut dup = mat.duplicate_resource();
                dup.set_shader_parameter("is_piece", &true.to_variant());
                dup.set_shader_parameter("piece_slot", &(slot as i32).to_variant());
                dup.set_shader_parameter("severed_mask", &(earlier as i32).to_variant());
                dup.set_shader_parameter("wounds", &packed.to_variant());
                dup.set_shader_parameter("wound_count", &self.drawn_wounds().to_variant());
                dup.set_shader_parameter("cut_planes", &self.planes_packed().to_variant());
                mi.set_surface_override_material(s, &dup.upcast::<Material>());
            }
        }
    }

    /// Closes the cut at `cut_bone` with flesh/bone caps: one skinned to this body's skeleton and, when
    /// `piece_root` is given (the severed piece's copy of the visual), one on the piece facing the other way.
    /// The caps use the flesh shader, so wounds, blood and later cuts apply to them like to the skin.
    /// Call after `configure_piece`, so the piece doesn't also copy the body's new cap. Returns the caps made.
    #[func]
    fn add_cut_caps(&mut self, piece_root: Option<Gd<Node>>, cut_bone: GString) -> i32 {
        let (Some(body), Some(wounds), Some(template)) = (self.body.as_ref(), self.wounds.as_ref(), self.cap_template.as_ref()) else { return 0 };
        let Some(bone) = body.skeleton.find(&cut_bone.to_string()) else { return 0 };
        let Some(slot) = self.slots.iter().position(|&b| b == bone) else { return 0 };
        // The limb runs towards the child with the most bones below it (lowerarm, not a twist bone).
        let child = (0..body.skeleton.len())
            .filter(|&c| body.skeleton.parents[c] == Some(bone))
            .max_by_key(|&c| body.skeleton.subtree(c).len());
        let earlier = body.severed_slot_mask() & !(1 << slot);
        let packed = PackedVector4Array::from_iter(wounds.pack().into_iter().map(|v| Vector4::new(v.x, v.y, v.z, v.w)));
        let wound_count = self.drawn_wounds();
        let piece_skel = piece_root.as_ref().and_then(find_skeleton).map(|k| k.upcast::<Node>());

        let mut new_materials = Vec::new();
        for s in &self.surfaces {
            let (Some(skin), Some(&bind)) = (s.skin.as_ref(), s.bone_to_bind.get(&(bone as i32))) else { continue };
            let rest = skin.get_bind_pose(bind).affine_inverse();
            let axis = child
                .and_then(|c| s.bone_to_bind.get(&(c as i32)))
                .map(|&cb| skin.get_bind_pose(cb).affine_inverse().origin - rest.origin)
                .unwrap_or(rest.basis.col_a());
            let outer: Vec<(&SurfaceCpu, bool)> = s.cpu.iter().zip(&s.layers).filter(|(_, &l)| l <= 1).map(|(c, &l)| (c, l == 1)).collect();
            let mut segs = caps::rim(&outer, slot, self.planes[slot]);
            let Some(frame) = caps::frame(&mut segs, rest.origin, axis) else { continue };
            let Some(mut skel) = s.mi.get_parent() else { continue };

            let mut mat = template.duplicate_resource();
            mat.set_shader_parameter("cap_slot", &(slot as i32).to_variant());
            spawn_cap(&mut skel, &cap_mesh(&caps::build(&segs, &frame, 1.0, CAP_UV_SCALE)), skin, &s.mi, &mat, &cut_bone);
            new_materials.push(mat);

            if let Some(mut psk) = piece_skel.clone() {
                let mut pmat = template.duplicate_resource();
                pmat.set_shader_parameter("cap_slot", &(slot as i32).to_variant());
                pmat.set_shader_parameter("is_piece", &true.to_variant());
                pmat.set_shader_parameter("piece_slot", &(slot as i32).to_variant());
                pmat.set_shader_parameter("severed_mask", &(earlier as i32).to_variant());
                pmat.set_shader_parameter("wounds", &packed.to_variant());
                pmat.set_shader_parameter("wound_count", &wound_count.to_variant());
                pmat.set_shader_parameter("cut_planes", &self.planes_packed().to_variant());
                spawn_cap(&mut psk, &cap_mesh(&caps::build(&segs, &frame, -1.0, CAP_UV_SCALE)), skin, &s.mi, &pmat, &cut_bone);
            }
        }
        let made = new_materials.len() as i32;
        self.cap_materials.extend(new_materials);
        self.dirty = true;
        made
    }

    /// Number of active wounds (debug).
    #[func]
    fn wound_count(&self) -> i32 {
        self.wounds.as_ref().map_or(0, |w| w.wounds.len() as i32)
    }

    // --- Combat-fidelity pass: levels, stability, status, events -------------------------------------

    /// Enemy level: DI2 grows max health by `growth` (0.1) of base per level above 1.
    #[func]
    fn set_level(&mut self, level: i32, growth: f32) {
        if let Some(b) = self.body.as_mut() {
            b.set_level(level.max(1) as u32, growth);
        }
    }

    #[func]
    fn get_max_health(&self) -> f32 {
        self.body.as_ref().map_or(0.0, |b| b.max_health)
    }

    /// Stability meter, 0..1 (DI2's enemy stamina bar).
    #[func]
    fn get_stability(&self) -> f32 {
        self.body.as_ref().map_or(0.0, |b| b.stability.fraction())
    }

    /// Back on its feet after a knockdown.
    #[func]
    fn reset_stability(&mut self) {
        if let Some(b) = self.body.as_mut() {
            b.stability.reset();
        }
    }

    /// DI2 CharacterInitialState MaterialVariants: every section whose material is `source` takes the `replacement`
    /// material instance (its base maps, render settings and FLESH parameters from data/flesh_materials.json).
    /// Returns how many sections changed.
    #[func]
    fn substitute_material(&mut self, source: GString, replacement: GString) -> i32 {
        let (source, replacement) = (source.to_string(), replacement.to_string());
        let flesh = flesh_data(&self.flesh_materials_path.to_string());
        let Some(fm) = flesh.get("materials").and_then(|m| m.get(&replacement)) else { return 0 };
        let dir = self.flesh_dir.to_string();
        let mut changed = 0;
        for m in self.surfaces.iter_mut().flat_map(|s| s.materials.iter_mut()) {
            if m.get_name().to_string() != source {
                continue;
            }
            let tex = &fm["params"]["textures"];
            for (k, slot) in RESOLVED_BASE_MAPS {
                if let Some(t) = tex.get(k).and_then(|v| v["value"].as_str()).and_then(|n| flesh_texture(&dir, n)) {
                    m.set_shader_parameter(&format!("{slot}_tex"), &t.to_variant());
                    m.set_shader_parameter(&format!("has_{slot}"), &true.to_variant());
                }
            }
            let render = &fm["render"];
            if let Some(v) = render["TwoSided"]["value"].as_bool() {
                m.set_shader_parameter("two_sided", &v.to_variant());
            }
            if let Some(v) = render["BlendMode"]["value"].as_str() {
                m.set_shader_parameter("use_alpha_clip", &(v == "BLEND_Masked").to_variant());
            }
            if let Some(v) = render["OpacityMaskClipValue"]["value"].as_f64() {
                m.set_shader_parameter("alpha_clip", &(v as f32).to_variant());
            }
            apply_flesh_material(m, fm, &dir);
            m.set_meta("di2_material", &replacement.to_variant());
            changed += 1;
        }
        changed
    }

    /// Shares the DI2 stamp textures (game/assets/di2/splatter/stamps, one layer each) with every material.
    #[func]
    fn set_stamp_textures(&mut self, tex: Gd<Texture2DArray>) {
        self.stamp_px.clear();
        for i in 0..tex.get_layers() {
            if let Some(mut img) = tex.get_layer_data(i) {
                if img.is_compressed() {
                    img.decompress();
                }
                img.convert(godot::classes::image::Format::RGBA8);
                let (w, h) = (img.get_width(), img.get_height());
                self.stamp_px.push((w, h, img.get_data().as_slice().to_vec()));
            } else {
                self.stamp_px.push((0, 0, Vec::new()));
            }
        }
        self.stamp_tex = Some(tex);
    }

    /// Adds a DI2 splatter stamp at a world point on `bone`, projecting along `world_into` with its plane
    /// rolled `roll` radians about it (`world_up` orients the plane). `params` are the stamp values the game
    /// resolved from the preset (size, depth, fade_start, angle_wrap, displacement_tex, diffuse_tex, channel,
    /// displacement, fluid, bruise, cauterise, drips).
    #[func]
    fn add_stamp(&mut self, params: VarDictionary, bone: GString, world_point: Vector3, world_into: Vector3, world_up: Vector3, roll: f32) -> bool {
        let Some(body) = self.body.as_ref() else { return false };
        let Some(b) = body.skeleton.find(&bone.to_string()) else { return false };
        let (p, into) = self.world_to_rest(b, world_point, world_into);
        let (_, up) = self.world_to_rest(b, world_point, world_up);
        let (ax, ay, az) = frame(into, up, roll);
        self.push_stamp(&params, p, ax, ay, az, false)
    }

    /// Adds a stamp already in mesh rest (bind-pose) space: a stored SplatterSet entry, or a hit stamp framed
    /// from hit_ex's rest_* impact data. Persistent stamps (pre-spawn sets) are never evicted.
    #[func]
    fn add_stamp_rest(&mut self, params: VarDictionary, origin: Vector3, ax: Vector3, ay: Vector3, az: Vector3, persistent: bool) -> bool {
        self.push_stamp(&params, to_glam(origin), to_glam(ax).normalize_or_zero(), to_glam(ay).normalize_or_zero(), to_glam(az).normalize_or_zero(), persistent)
    }

    /// A hit stamp, DI2's default projection (bReferencePose false: FSplatterVS_World + the skinned deform CS): the
    /// rest-space frame (as framed from hit_ex's rest_* data) is carried back to the world through `bone`, the bone
    /// the hit was resolved on, and projected against the body as it is posed now.
    #[func]
    fn add_stamp_posed(&mut self, params: VarDictionary, bone: GString, origin: Vector3, ax: Vector3, ay: Vector3, az: Vector3) -> bool {
        let Some(m) = self.rest_to_world(&bone.to_string()) else {
            return self.push_stamp(&params, to_glam(origin), to_glam(ax).normalize_or_zero(), to_glam(ay).normalize_or_zero(), to_glam(az).normalize_or_zero(), false);
        };
        let o = m * origin;
        let (wx, wy, wz) = ((m.basis * ax).normalized_or_zero(), (m.basis * ay).normalized_or_zero(), (m.basis * az).normalized_or_zero());
        let k = params.get("strength").and_then(|v| v.try_to::<f64>().ok()).map_or(1.0, |v| v as f32);
        let mut stamp = self.stamp_from(&params, to_glam(o), to_glam(wx), to_glam(wy), to_glam(wz));
        if k != 1.0 {
            stamp = stamp.scaled(k);
        }
        // Which sections to skin: the stamp's box in bind pose (its rest frame), grown for cloth depth and for how
        // far the pose can carry the surface around the hit bone.
        let rest = self.stamp_from(&params, to_glam(origin), to_glam(ax).normalize_or_zero(), to_glam(ay).normalize_or_zero(), to_glam(az).normalize_or_zero());
        let (rlo, rhi) = SplatterRt::bounds(&rest, true);
        let (rlo2, rhi2) = SplatterRt::bounds(&rest, false);
        let tsk = std::time::Instant::now();
        self.ensure_posed(rlo.min(rlo2), rhi.max(rhi2), 0.25);
        self.process_ms_skin += tsk.elapsed().as_secs_f64() * 1000.0;
        let td = std::time::Instant::now();
        self.deform_pass_ex(&stamp, true);
        self.bake_phases[3] += td.elapsed().as_secs_f64() * 1000.0;
        let t0 = std::time::Instant::now();
        self.bake_stamp_ex(&stamp, true, None);
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        let st = &mut self.bake_stats;
        *st = (st.0 + 1, st.1 + ms, st.2.max(ms));
        self.splatter.add(stamp)
    }

    /// DI2 clears (recon/RE_DISMEMBER.md §9), whole sections, no box. `all` = ClearSplatter / ClearAll (80): both
    /// splatter targets to 0 and every vertex depth to `value`; otherwise ClearToValue (64): skin sections' targets
    /// (all channels) to `value`, clothing sections' Disp.R and Disp.A to 0, and every vertex depth to `value`.
    #[func]
    fn clear_splatter(&mut self, all: bool, value: f32) {
        let gpu = gpu_bake::gpu();
        self.flush_splatter_inner();
        for (si, s) in self.surfaces.iter_mut().enumerate() {
            for ci in 0..s.rts.len() {
                let cloth = s.layers.get(ci).copied() == Some(1);
                match s.rts[ci].as_mut() {
                    Some(SectionTargets::Gpu(sec)) => {
                        if let Some(g) = gpu.as_ref() {
                            let v = if all { 0.0 } else { value };
                            g.borrow_mut().clear(sec, if cloth && !all { None } else { Some(v) });
                        }
                    }
                    Some(SectionTargets::Cpu(srt)) => {
                        let q = |x: f32| (x.clamp(0.0, 1.0) * 255.0).round() as u8;
                        if cloth && !all {
                            for t in srt.rt.disp.iter_mut() {
                                t[0] = 0;
                                t[3] = 0;
                            }
                        } else {
                            let v = q(if all { 0.0 } else { value });
                            srt.rt.disp.iter_mut().for_each(|t| *t = [v; 4]);
                            srt.rt.dif.iter_mut().for_each(|t| *t = [v; 4]);
                        }
                        srt.dirty = true;
                    }
                    None => {}
                }
            }
            if let Some(depths) = self.vdepth.get_mut(si) {
                for (ci, d) in depths.iter_mut().enumerate() {
                    d.iter_mut().for_each(|x| *x = value.clamp(0.0, 1.0));
                    if let Some(f) = self.vdepth_dirty.get_mut(si).and_then(|v| v.get_mut(ci)) {
                        *f = true;
                    }
                }
            }
        }
    }

    /// DI2 dismember (recon/RE_DISMEMBER.md §13.2): places the cut at the hit bone's safe-region sockets, classifies
    /// every triangle of the body's DismemberMask sections (body / limb / dropped, FSplatterGeometryIndicesCS),
    /// rebuilds the body with its kept triangles and `piece_root`'s copy of the visual with the limb triangles (both
    /// share this body's splatter targets, like DI2's bSharesResources limb), and for DismemberWithDecal bakes the
    /// radial cut band (bind pose) into the targets and the vertex depth. `origin` / `ax..az` = the hit's stamp
    /// frame in bind pose (the cut's initial normal is its +v axis, decal Y); `params` = the gradual effect's
    /// InitialEffect stamp params. Returns false when the body has no DI2 data or no region on the bone's chain.
    #[func]
    fn di2_cut(&mut self, piece_root: Option<Gd<Node>>, cut_bone: GString, origin: Vector3, ax: Vector3, ay: Vector3, az: Vector3, uv_scale: f32, params: VarDictionary, with_decal: bool) -> bool {
        let Some(data) = self.dismember_data() else { return false };
        let Some(b) = data.bone(&cut_bone.to_string()) else { return false };
        let Some(region) = data.region_bone(b, RegionKind::Safe) else { return false };
        let frame = DecalFrame { x: to_glam(ay).normalize_or_zero(), y: to_glam(az).normalize_or_zero(), z: -to_glam(ax).normalize_or_zero(), origin: to_glam(origin) };
        let Some(cut) = data.place(region, RegionKind::Safe, &frame, None) else { return false };
        self.last_cut_plane = Some((cut.origin, cut.normal));
        let target = data.target(&cut);
        let (dm, sr) = (cut.decal_matrix, cut.safe_region);
        // Classify the body's DismemberMask sections.
        let mut body_idx: HashMap<(usize, usize), Vec<i32>> = HashMap::new();
        let mut limb_idx: HashMap<(usize, usize), Vec<i32>> = HashMap::new();
        for (si, s) in self.surfaces.iter().enumerate() {
            if !s.is_body {
                continue;
            }
            let joints = self.bind_joints(s, &data);
            for (ci, c) in s.cpu.iter().enumerate() {
                if ci >= data.sections.len() || !data.dismember_applies(ci) || c.per == 0 || c.verts.is_empty() {
                    continue;
                }
                let pos: Vec<GVec3> = c.verts.iter().map(|v| to_glam(*v)).collect();
                let (mut bones, mut weights) = (Vec::with_capacity(pos.len()), Vec::with_capacity(pos.len()));
                for v in 0..pos.len() {
                    // DI2's FourBone classification: the four largest influences, as glb joint indices.
                    let mut inf: Vec<(i32, f32)> = (0..c.per).map(|j| (c.bones[v * c.per + j], c.weights[v * c.per + j])).collect();
                    inf.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                    let (mut bb, mut ww) = ([0u16; 4], [0f32; 4]);
                    for (k, (bi, w)) in inf.into_iter().take(4).enumerate() {
                        if w > 0.0 && bi >= 0 {
                            bb[k] = joints.get(bi as usize).copied().unwrap_or(0);
                            ww[k] = w;
                        }
                    }
                    bones.push(bb);
                    weights.push(ww);
                }
                let cur: Vec<u32> = match s.cur_indices.get(ci).and_then(|x| x.as_ref()) {
                    Some(v) => v.iter().map(|&i| i as u32).collect(),
                    None => c.indices.iter().map(|&i| i as u32).collect(),
                };
                let classes = classify_section(&pos, &bones, &weights, &cur, &dm, &sr, &target, &data.topo, data.sections[ci].binary_dismember);
                let (bi, li) = split_indices(&cur, &classes);
                body_idx.insert((si, ci), bi.into_iter().map(|x| x as i32).collect());
                limb_idx.insert((si, ci), li.into_iter().map(|x| x as i32).collect());
            }
        }
        if body_idx.is_empty() {
            return false;
        }
        // The piece first (from the body's mesh as it is before this cut), then the body.
        let piece_meshes: Vec<Gd<MeshInstance3D>> = piece_root.as_ref().map(collect_meshes).unwrap_or_default();
        for si in 0..self.surfaces.len() {
            if !self.surfaces[si].is_body {
                continue;
            }
            let name = self.surfaces[si].mi.get_name();
            let Some(src) = self.surfaces[si].mi.get_mesh() else { continue };
            let limb: HashMap<usize, Vec<i32>> = limb_idx.iter().filter(|((s2, _), _)| *s2 == si).map(|((_, ci), v)| (*ci, v.clone())).collect();
            let body: HashMap<usize, Vec<i32>> = body_idx.iter().filter(|((s2, _), _)| *s2 == si).map(|((_, ci), v)| (*ci, v.clone())).collect();
            for mut pm in piece_meshes.iter().filter(|m| m.get_name() == name).cloned() {
                if let Some(m) = rebuild_mesh(&src, &limb) {
                    pm.set_mesh(&m.upcast::<Mesh>());
                }
                for ci in limb.keys() {
                    if let Some(Ok(mut mat)) = pm.get_surface_override_material(*ci as i32).map(|m| m.try_cast::<ShaderMaterial>()) {
                        mat.set_shader_parameter("di2_cut", &true.to_variant());
                    }
                }
            }
            if let Some(m) = rebuild_mesh(&src, &body) {
                let s = &mut self.surfaces[si];
                s.mi.set_mesh(&m.upcast::<Mesh>());
                s.own_mesh = true;
                s.vbuf.clear();
                if s.cur_indices.len() < s.cpu.len() {
                    s.cur_indices.resize(s.cpu.len(), None);
                }
                for (ci, v) in &body {
                    s.cur_indices[*ci] = Some(v.clone());
                    if let Some(mat) = s.materials.get_mut(*ci) {
                        mat.set_shader_parameter("di2_cut", &true.to_variant());
                    }
                }
            }
            // Sections outside the DismemberMask (skeleton, viscera, eyes) are not split by DI2: they stay whole
            // on the body and the limb, and UVisceraComponent::LimbCut culls their proxies' subsections per CutBias
            // (zombie.gd _viscera_limb_cut). Only sections made of subsections are handed over that way.
            let whole: Vec<usize> = (0..self.surfaces[si].sub_names.len())
                .filter(|&ci| !self.surfaces[si].sub_names[ci].is_empty() && (ci >= data.sections.len() || !data.dismember_applies(ci)))
                .collect();
            for &ci in &whole {
                if let Some(mat) = self.surfaces[si].materials.get_mut(ci) {
                    mat.set_shader_parameter("di2_cut", &true.to_variant());
                }
                for pm in piece_meshes.iter().filter(|m| m.get_name() == name) {
                    if let Some(Ok(mut mat)) = pm.get_surface_override_material(ci as i32).map(|m| m.try_cast::<ShaderMaterial>()) {
                        mat.set_shader_parameter("di2_cut", &true.to_variant());
                    }
                }
            }
            // The new vertex buffer holds baked positions: sink every section again.
            if let Some(d) = self.vdepth_dirty.get_mut(si) {
                d.iter_mut().for_each(|x| *x = true);
            }
        }
        // DismemberWithDecal: the radial band (bind pose) into the targets and the vertex depth.
        if with_decal {
            let rdm = cut.radial_decal_matrix(uv_scale);
            let row = |m: &gore_core::glam::Mat4, r: usize| [m.x_axis[r], m.y_axis[r], m.z_axis[r], m.w_axis[r]];
            let rows = [row(&rdm, 1), row(&sr, 1), row(&sr, 2)];
            let mut stamp = self.stamp_from(&params, cut.origin, -cut.normal, cut.x_axis, cut.z_axis);
            // Reach for the section bounds test: the band is UVScale tall and spans the safe region.
            stamp.half_size = (uv_scale * 0.01).max(0.3);
            stamp.depth = stamp.half_size;
            self.radial_deform(&stamp, &rdm, &sr);
            self.bake_stamp_ex(&stamp, false, Some(rows));
        }
        true
    }

    /// DI2 BoneBreak (recon/RE_DISMEMBER.md §13.3, FSplatterBreakCS): places the break at the bone's break-region
    /// sockets and re-skins the body's vertices past the break plane: the 4th influence becomes the break child with
    /// weight sat(d / 10 cm), the ancestors fade by the rest, renormalised and 8-bit quantised. Permanent: the body's
    /// skin data is rebuilt. Returns {ok, point (bind pose, metres), normal, child (bone name)} for the physics
    /// pivot (ManipulateConstraint moves the child's joint to the break point).
    #[func]
    fn di2_break(&mut self, bone: GString, origin: Vector3, ax: Vector3, ay: Vector3, az: Vector3) -> VarDictionary {
        let fail = || dict(&[("ok", false.to_variant())]);
        let Some(data) = self.dismember_data() else { return fail() };
        let Some(b) = data.bone(&bone.to_string()) else { return fail() };
        let Some(region) = data.region_bone(b, RegionKind::Break) else { return fail() };
        let frame = DecalFrame { x: to_glam(ay).normalize_or_zero(), y: to_glam(az).normalize_or_zero(), z: -to_glam(ax).normalize_or_zero(), origin: to_glam(origin) };
        let Some(cut) = data.place(region, RegionKind::Break, &frame, None) else { return fail() };
        let target = data.target(&cut);
        let dm = cut.decal_matrix;
        let mut changed_any = false;
        for si in 0..self.surfaces.len() {
            if !self.surfaces[si].is_body {
                continue;
            }
            let joints = self.bind_joints(&self.surfaces[si], &data);
            let bind_of: HashMap<u16, i32> = joints.iter().enumerate().map(|(i, j)| (*j, i as i32)).collect();
            let mut new_skin: HashMap<usize, (Vec<i32>, Vec<f32>)> = HashMap::new();
            {
                let s = &self.surfaces[si];
                for (ci, c) in s.cpu.iter().enumerate() {
                    if ci >= data.sections.len() || !data.break_applies(ci, &target) || c.per == 0 || c.verts.is_empty() {
                        continue;
                    }
                    let pos: Vec<GVec3> = c.verts.iter().map(|v| to_glam(*v)).collect();
                    let (mut bones, mut weights) = (Vec::with_capacity(pos.len()), Vec::with_capacity(pos.len()));
                    for v in 0..pos.len() {
                        let mut inf: Vec<(i32, f32)> = (0..c.per).map(|j| (c.bones[v * c.per + j], c.weights[v * c.per + j])).collect();
                        inf.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                        let (mut bb, mut ww) = ([0u16; 4], [0f32; 4]);
                        for (k, (bi, w)) in inf.into_iter().take(4).enumerate() {
                            if w > 0.0 && bi >= 0 {
                                bb[k] = joints.get(bi as usize).copied().unwrap_or(0);
                                ww[k] = w;
                            }
                        }
                        bones.push(bb);
                        weights.push(ww);
                    }
                    let out = break_section(&pos, &bones, &weights, &dm, &target, &data.topo, data.sections[ci].binary_dismember);
                    if out.iter().all(|o| o.is_none()) {
                        continue;
                    }
                    // Back to this mesh's skin binds, in its bone-array width (extra slots zeroed).
                    let (mut nb, mut nw) = (c.bones.clone(), c.weights.clone());
                    for (v, o) in out.iter().enumerate() {
                        let Some((jb, jw)) = o else { continue };
                        for j in 0..c.per {
                            let (bi, w) = if j < 4 { (bind_of.get(&jb[j]).copied().unwrap_or(0), jw[j]) } else { (0, 0.0) };
                            nb[v * c.per + j] = bi;
                            nw[v * c.per + j] = w;
                        }
                    }
                    new_skin.insert(ci, (nb, nw));
                }
            }
            if new_skin.is_empty() {
                continue;
            }
            let Some(src) = self.surfaces[si].mi.get_mesh() else { continue };
            let cur: HashMap<usize, Vec<i32>> = self.surfaces[si].cur_indices.iter().enumerate().filter_map(|(ci, x)| x.clone().map(|v| (ci, v))).collect();
            if let Some(m) = rebuild_mesh_with(&src, |sidx, arrays| {
                if let Some(idx) = cur.get(&sidx) {
                    let idx = if idx.is_empty() { vec![0, 0, 0] } else { idx.clone() };
                    arrays.set(ArrayType::INDEX.ord() as usize, &PackedInt32Array::from(idx.as_slice()).to_variant());
                }
                if let Some((nb, nw)) = new_skin.get(&sidx) {
                    arrays.set(ArrayType::BONES.ord() as usize, &PackedInt32Array::from(nb.as_slice()).to_variant());
                    arrays.set(ArrayType::WEIGHTS.ord() as usize, &PackedFloat32Array::from(nw.as_slice()).to_variant());
                }
            }) {
                let s = &mut self.surfaces[si];
                s.mi.set_mesh(&m.upcast::<Mesh>());
                s.own_mesh = true;
                s.vbuf.clear();
                changed_any = true;
            }
            if let Some(d) = self.vdepth_dirty.get_mut(si) {
                d.iter_mut().for_each(|x| *x = true);
            }
        }
        let child = data.names.get(target.break_bone.max(0) as usize).cloned().unwrap_or_default();
        dict(&[
            ("ok", changed_any.to_variant()),
            ("point", Vector3::new(cut.origin.x, cut.origin.y, cut.origin.z).to_variant()),
            ("normal", Vector3::new(cut.normal.x, cut.normal.y, cut.normal.z).to_variant()),
            ("child", GString::from(child.as_str()).to_variant()),
        ])
    }

    /// A stored SplatterSet Dismember / DismemberWithDecal entry (DI2 pre-spawn missing limbs, crawler sets): the
    /// part is severed in the simulation (no limb actor: it was never there) and the mesh is cut with DI2's
    /// placement from the entry's own frame (bind pose). Returns the cut bone's name ("" when nothing was cut).
    #[func]
    /// `bone_index` = the entry's FSplatterMeshInfo.BoneIndex (the mesh's reference-skeleton index = glb joint).
    fn prespawn_dismember(&mut self, bone_index: i64, origin: Vector3, ax: Vector3, ay: Vector3, az: Vector3, uv_scale: f32, params: VarDictionary, with_decal: bool) -> GString {
        let Some(data) = self.dismember_data() else { return GString::new() };
        let Some(name) = usize::try_from(bone_index).ok().and_then(|i| data.names.get(i)).cloned() else { return GString::new() };
        let Some(body) = self.body.as_mut() else { return GString::new() };
        let Some(b) = body.skeleton.find(&name) else { return GString::new() };
        let Some((_, cut_bone)) = body.dismember_bone(b) else { return GString::new() };
        let cut_name = body.skeleton.names[cut_bone].clone();
        self.dirty = true;
        // DI2 climbs from the entry's own bone to the first bone with a safe region.
        self.di2_cut(None, GString::from(name.as_str()), origin, ax, ay, az, uv_scale, params, with_decal);
        GString::from(cut_name.as_str())
    }

    /// DI2's deform CS p82 (radial, bind pose) for the cut band over every skin / cloth vertex.
    fn radial_deform(&mut self, stamp: &Stamp, rdm: &gore_core::glam::Mat4, sr: &gore_core::glam::Mat4) {
        let rs = &self.stamp_px;
        let tex = stamp.displacement_tex;
        let point = |u: f32, v: f32| -> f32 {
            match rs.get(tex as usize) {
                Some((w, h, px)) if *w > 0 && tex >= 0 => {
                    let x = ((u * *w as f32) as i32).clamp(0, *w - 1);
                    let y = ((v * *h as f32) as i32).clamp(0, *h - 1);
                    px[((y * *w + x) * 4) as usize] as f32 / 255.0
                }
                _ => 0.0,
            }
        };
        if self.vdepth.len() != self.surfaces.len() {
            self.vdepth = self.surfaces.iter().map(|s| s.cpu.iter().map(|c| vec![0.0; c.verts.len()]).collect()).collect();
            self.vdepth_tex = self.surfaces.iter().map(|s| vec![None; s.cpu.len()]).collect();
            self.vdepth_dirty = self.surfaces.iter().map(|s| vec![false; s.cpu.len()]).collect();
            self.vdepth_range = self.surfaces.iter().map(|s| vec![(usize::MAX, 0); s.cpu.len()]).collect();
        }
        for (si, s) in self.surfaces.iter().enumerate() {
            for (ci, (c, &layer)) in s.cpu.iter().zip(&s.layers).enumerate() {
                if layer > 1 || c.verts.is_empty() {
                    continue;
                }
                let e = RadialElement::from_stamp(stamp, layer == 1);
                let depth = &mut self.vdepth[si][ci];
                let mut changed = false;
                for (vi, p) in c.verts.iter().enumerate() {
                    let d = f16_round(radial_vertex_depth(to_glam(*p), rdm, sr, &e, depth[vi], &point));
                    if d != depth[vi] {
                        depth[vi] = d;
                        changed = true;
                        let r = &mut self.vdepth_range[si][ci];
                        *r = (r.0.min(vi), r.1.max(vi + 1));
                    }
                }
                if changed {
                    self.vdepth_dirty[si][ci] = true;
                }
            }
        }
    }

    fn dismember_data(&mut self) -> Option<Rc<DismemberData>> {
        if self.dismember.is_none() {
            let path = self.deform_path.to_string().trim_end_matches(".deform.bin").to_string() + ".dismember.json";
            let text = read_text(&path)?;
            match DismemberData::from_json(&text) {
                Ok(d) => self.dismember = Some(Rc::new(d)),
                Err(e) => {
                    godot_warn!("GoreBody: {path}: {e}");
                    return None;
                }
            }
        }
        self.dismember.clone()
    }

    /// The glb joint index of every skin bind of a surface (by bone name).
    fn bind_joints(&self, s: &Surface, data: &DismemberData) -> Vec<u16> {
        let Some(skin) = s.skin.as_ref() else { return Vec::new() };
        let skel = self.skeleton.as_ref();
        (0..skin.get_bind_count())
            .map(|i| {
                let mut name = skin.get_bind_name(i).to_string();
                if name.is_empty() {
                    let bone = s.bind_to_bone.get(i as usize).copied().unwrap_or(-1);
                    if let (Some(sk), true) = (skel, bone >= 0) {
                        name = sk.get_bone_name(bone).to_string();
                    }
                }
                data.bone(&name).map(|j| j as u16).unwrap_or(0)
            })
            .collect()
    }

    /// A world point on `bone`, carried into bind-pose (stamp) space.
    #[func]
    fn world_point_to_rest(&self, bone: GString, world_point: Vector3) -> Vector3 {
        let Some(body) = self.body.as_ref() else { return world_point };
        let Some(b) = body.skeleton.find(&bone.to_string()) else { return world_point };
        let (p, _) = self.world_to_rest(b, world_point, Vector3::UP);
        Vector3::new(p.x, p.y, p.z)
    }

    /// A world direction at `world_point` on `bone`, carried into bind-pose (stamp) space.
    #[func]
    fn world_dir_to_rest(&self, bone: GString, world_point: Vector3, world_dir: Vector3) -> Vector3 {
        let Some(body) = self.body.as_ref() else { return world_dir };
        let Some(b) = body.skeleton.find(&bone.to_string()) else { return world_dir };
        let (_, d) = self.world_to_rest(b, world_point, world_dir);
        Vector3::new(d.x, d.y, d.z)
    }

    /// DI2 subsection culling (CosmeticEffect_Viscera, spawnable parts): hides every subsection called `name`
    /// (case-insensitive). Returns whether anything was visible before.
    #[func]
    fn cull_subsection(&mut self, name: GString) -> bool {
        self.set_subsection(&name.to_string(), true)
    }

    /// Shows every subsection called `name` again (viscera variants). Returns whether anything changed.
    #[func]
    fn show_subsection(&mut self, name: GString) -> bool {
        self.set_subsection(&name.to_string(), false)
    }

    /// The last DI2 cut's plane: {ok, origin, normal} in bind pose (glTF metres), normal towards the limb side
    /// (dismember CutPlacement), for UVisceraComponent::LimbCut's per-proxy CutBias tests.
    #[func]
    fn last_cut_plane(&self) -> VarDictionary {
        match self.last_cut_plane {
            Some((o, n)) => dict(&[("ok", true.to_variant()), ("origin", Vector3::new(o.x, o.y, o.z).to_variant()),
                ("normal", Vector3::new(n.x, n.y, n.z).to_variant())]),
            None => dict(&[("ok", false.to_variant())]),
        }
    }

    /// Hides subsection `name` on a severed piece (`piece_root`, the copy configure_piece gave its own
    /// materials): the same per-section bits as cull_subsection, set on the piece's materials. Returns whether
    /// anything changed.
    #[func]
    fn cull_piece_subsection(&self, piece_root: Gd<Node>, name: GString) -> bool {
        let name = name.to_string();
        let mut changed = false;
        for mut pm in collect_meshes(&piece_root) {
            let pname = pm.get_name();
            let Some(s) = self.surfaces.iter().find(|s| s.mi.get_name() == pname) else { continue };
            for ci in 0..s.sub_names.len() {
                let bits = s.sub_names[ci].iter().enumerate().filter(|(k, n)| *k < 64 && n.eq_ignore_ascii_case(&name)).fold(0u64, |m, (k, _)| m | (1u64 << k));
                if bits == 0 {
                    continue;
                }
                let Some(mat) = pm.get_surface_override_material(ci as i32) else { continue };
                let Ok(mut mat) = mat.try_cast::<ShaderMaterial>() else { continue };
                let lo = mat.get_shader_parameter("sub_hidden_lo").try_to::<i64>().unwrap_or(0) as u32 as u64;
                let hi = mat.get_shader_parameter("sub_hidden_hi").try_to::<i64>().unwrap_or(0) as u32 as u64;
                let mask = lo | (hi << 32);
                let new = mask | bits;
                if new != mask {
                    mat.set_shader_parameter("sub_hidden_lo", &((new & 0xffff_ffff) as u32 as i32).to_variant());
                    mat.set_shader_parameter("sub_hidden_hi", &((new >> 32) as u32 as i32).to_variant());
                    changed = true;
                }
            }
            let _ = &mut pm;
        }
        changed
    }

    /// A DI2 viscera gib (BP_SkeletalMeshSubSectionAttachment_Gib, VISCERA_PARTS.md §4.3): `piece_root`, a copy of
    /// the visual, gets its own materials showing only the subsections `names` (the gib's SubSectionNamesToSpawn):
    /// sections holding none of them are hidden, the others hide every other subsection.
    #[func]
    fn configure_gib(&self, piece_root: Gd<Node>, names: PackedStringArray) {
        let want: Vec<String> = names.as_slice().iter().map(|n| n.to_string()).collect();
        for mut pm in collect_meshes(&piece_root) {
            let pname = pm.get_name();
            let surf = self.surfaces.iter().find(|s| s.mi.get_name() == pname);
            for ci in 0..pm.get_surface_override_material_count() {
                let Some(mat) = pm.get_surface_override_material(ci) else { continue };
                let Ok(mat) = mat.try_cast::<ShaderMaterial>() else { continue };
                let mut dup = mat.duplicate_resource();
                let keep = surf
                    .and_then(|s| s.sub_names.get(ci as usize))
                    .map(|sn| sn.iter().enumerate().filter(|(k, n)| *k < 64 && want.iter().any(|w| w.eq_ignore_ascii_case(n))).fold(0u64, |m, (k, _)| m | (1u64 << k)))
                    .unwrap_or(0);
                if keep == 0 {
                    dup.set_shader_parameter("section_hidden", &true.to_variant());
                } else {
                    let mask = !keep;
                    dup.set_shader_parameter("sub_hidden_lo", &((mask & 0xffff_ffff) as u32 as i32).to_variant());
                    dup.set_shader_parameter("sub_hidden_hi", &((mask >> 32) as u32 as i32).to_variant());
                    dup.set_shader_parameter("severed_mask", &0.to_variant());
                    dup.set_shader_parameter("di2_cut", &true.to_variant());
                }
                pm.set_surface_override_material(ci, &dup.upcast::<Material>());
            }
        }
    }

    /// The `<bone>_safe_region[_N]` sockets of `bone` (DI2 dismember region kind 2), bone-local (glTF metres): the
    /// bisection trigger picks the bisectable bone whose region socket is nearest the hit (exe 0x1412a0610).
    #[func]
    fn safe_region_points(&mut self, bone: GString) -> PackedVector3Array {
        let mut out = PackedVector3Array::new();
        let Some(data) = self.dismember_data() else { return out };
        let Some(b) = data.bone(&bone.to_string()) else { return out };
        for s in data.region_sockets(b, RegionKind::Safe) {
            out.push(Vector3::new(s.loc.x, s.loc.y, s.loc.z));
        }
        out
    }

    /// Every subsection name on the body (debug / tests).
    #[func]
    fn subsection_names(&self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for s in &self.surfaces {
            for names in &s.sub_names {
                for n in names {
                    out.push(n.as_str());
                }
            }
        }
        out
    }

    /// Splatter bake cost so far: {applications, total_ms, max_ms, sections} (sections = render-target pairs in use).
    #[func]
    fn splatter_stats(&self) -> VarDictionary {
        let sections = self.surfaces.iter().map(|s| s.rts.iter().filter(|r| r.is_some()).count()).sum::<usize>() as i64;
        let gpu = self.surfaces.iter().any(|s| s.rts.iter().flatten().any(|t| matches!(t, SectionTargets::Gpu(_))));
        let (n, total, max) = self.bake_stats;
        let ph = self.bake_phases;
        dict(&[("applications", (n as i64).to_variant()), ("total_ms", total.to_variant()), ("max_ms", max.to_variant()), ("sections", sections.to_variant()),
               ("map_ms", ph[0].to_variant()), ("apply_ms", ph[1].to_variant()), ("dilate_ms", ph[2].to_variant()), ("deform_ms", ph[3].to_variant()), ("flush_ms", ph[4].to_variant()), ("process_ms", self.process_ms.to_variant()), ("skin_ms", self.process_ms_skin.to_variant()), ("gpu", gpu.to_variant())])
    }

    #[func]
    fn stamp_count(&self) -> i64 {
        self.splatter.stamps.len() as i64
    }

    /// Applies stability damage without a wound (shoves, perfect blocks, explosions' push).
    /// Returns the reaction tier name.
    #[func]
    fn stability_hit(&mut self, force: f32, launch: bool) -> GString {
        self.body.as_mut().map_or(GString::new(), |b| GString::from(format!("{:?}", b.stability.hit(force, launch)).to_lowercase().as_str()))
    }

    /// `{burning: s, electrified: s, caustic: s, bleeding: s}` seconds remaining (0 = inactive).
    #[func]
    fn status_states(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(b) = self.body.as_ref() {
            for st in Status::ALL {
                d.set(&st.name().to_variant(), &b.status.remaining(st).to_variant());
            }
        }
        d
    }

    /// DI2's accumulating-effect update for one effect (`status`: burning / electrified / caustic / bleeding or
    /// DI2's Burning / Electrocuted / Corroded / Bleed; `value` already level-scaled). Returns `{started, state,
    /// meter, killed}`.
    #[func]
    fn accumulate(&mut self, status: GString, value: f32, apply_max: bool, can_extend: bool) -> VarDictionary {
        let Some(s) = Status::parse(&status.to_string()) else { return VarDictionary::new() };
        let Some(body) = self.body.as_mut() else { return VarDictionary::new() };
        let out = body.accumulate(s, value, apply_max, can_extend);
        let started = out.iter().any(|o| matches!(o, Outcome::StatusStarted { .. }));
        let killed = out.iter().any(|o| matches!(o, Outcome::Killed { .. }));
        if killed {
            if let Some(b) = self.brain.as_mut() { b.on_death(); }
        }
        let body = self.body.as_ref().unwrap();
        dict(&[("started", started.to_variant()), ("killed", killed.to_variant()),
            ("state", body.status.state_name(s).to_variant()), ("meter", body.status.current(s).to_variant())])
    }

    /// The next hit_ex's DI2 damage type when a weapon mod converts its Physical damage (fire / acid / electric /
    /// bleed); the hit's `kind` still drives the gore.
    #[func]
    fn set_next_damage_type(&mut self, kind: GString) {
        self.next_damage_type = DamageKind::from_name(&kind.to_string());
    }

    /// One effect type's DA_AccumulatingEffectConfig entry (game/data/accumulating_effects.json `configs`):
    /// decay_rate, duration, accumulating_pause, pause, gain_multiplier, decay_multiplier, duration_multiplier.
    #[func]
    fn set_accumulating_def(&mut self, status: GString, def: VarDictionary) {
        let Some(s) = Status::parse(&status.to_string()) else { return };
        let Some(body) = self.body.as_mut() else { return };
        let f = |k: &str, d: f32| def.get(k).and_then(|v| v.try_to::<f32>().ok()).unwrap_or(d);
        let cur = body.status.defs[s as usize];
        body.status.defs[s as usize] = gore_core::status::AccumDef {
            decay_rate: f("decay_rate", cur.decay_rate),
            duration: f("duration", cur.duration),
            accumulating_pause: f("accumulating_pause", cur.accumulating_pause),
            pause: f("pause", cur.pause),
            gain: f("gain_multiplier", cur.gain),
            decay_mult: f("decay_multiplier", cur.decay_mult),
            duration_mult: f("duration_multiplier", cur.duration_mult),
        };
    }

    /// `{meter, state}` of one accumulating effect.
    #[func]
    fn accumulating_state(&self, status: GString) -> VarDictionary {
        let (Some(s), Some(b)) = (Status::parse(&status.to_string()), self.body.as_ref()) else { return VarDictionary::new() };
        dict(&[("meter", b.status.current(s).to_variant()), ("state", b.status.state_name(s).to_variant())])
    }

    #[func]
    fn is_stunned(&self) -> bool {
        self.body.as_ref().is_some_and(|b| b.status.stunned())
    }

    /// Whether a status runs (status / DI2 type name, e.g. "disoriented", "Weakened").
    #[func]
    fn is_status_active(&self, status: GString) -> bool {
        let (Some(s), Some(b)) = (Status::parse(&status.to_string()), self.body.as_ref()) else { return false };
        b.status.active(s)
    }

    /// Disoriented's AddDeviationModifier: a factor on the running status's DurationMultiplier (cleared at its end).
    #[func]
    fn set_status_duration_deviation(&mut self, status: GString, factor: f32) {
        let (Some(s), Some(b)) = (Status::parse(&status.to_string()), self.body.as_mut()) else { return };
        b.status.set_duration_deviation(s, factor);
    }

    /// Events raised outside hit(): currently "killed_by_status". Clears the queue.
    #[func]
    fn take_events(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for e in self.events.drain(..) {
            out.push(&GString::from(e.as_str()));
        }
        out
    }
}

impl GoreBody {
    fn load_archetype(&self) -> Archetype {
        let name = self.archetype.to_string();
        if let Some(src) = read_text(&self.archetypes_path.to_string()) {
            match serde_json::from_str::<Vec<Archetype>>(&src) {
                Ok(all) => {
                    if let Some(a) = all.into_iter().find(|a| a.name.eq_ignore_ascii_case(&name)) {
                        return a;
                    }
                    godot_warn!("GoreBody: archetype {name} not in {}, using built-in Walker", self.archetypes_path);
                }
                Err(e) => {
                    godot_error!("GoreBody: {}: {e}", self.archetypes_path);
                }
            }
        }
        Archetype::walker()
    }

    /// The transform carrying bind-pose points rigidly attached to `bone` (or its first skinned ancestor) to the
    /// world as posed now: the inverse of `world_to_rest`.
    fn rest_to_world(&self, bone: &str) -> Option<Transform3D> {
        let (skel, body) = (self.skeleton.as_ref()?, self.body.as_ref()?);
        let b = body.skeleton.find(bone)?;
        for a in body.skeleton.ancestry(b) {
            for s in &self.surfaces {
                let (Some(skin), Some(&bind)) = (s.skin.as_ref(), s.bone_to_bind.get(&(a as i32))) else { continue };
                return Some(s.mi.get_global_transform() * skel.get_bone_global_pose(a as i32) * skin.get_bind_pose(bind));
            }
        }
        None
    }

    /// Skins, once per frame (world space), the skin / cloth sections a posed stamp can reach: those whose bind-pose
    /// bounds meet the stamp's bind-pose box [`lo`, `hi`] grown by `margin` (posing moves surface points only so far
    /// from their bind spot relative to the hit bone; sections far from the hit aren't skinned at all).
    fn ensure_posed(&mut self, lo: GVec3, hi: GVec3, margin: f32) {
        let frame = godot::classes::Engine::singleton().get_process_frames();
        if self.posed_frame != frame || self.posed.len() != self.surfaces.len() {
            // Jobs still queued from an earlier frame were posed with that frame's skinning: run them first.
            if !self.posed_upload.is_empty() {
                self.flush_splatter_inner();
            }
            self.posed_frame = frame;
            self.bone_world.clear();
            self.posed = self.surfaces.iter().map(|s| vec![None; s.cpu.len()]).collect();
            self.posed_done = self.surfaces.iter().map(|s| s.cpu.iter().map(|_| Vec::new()).collect()).collect();
        }
        let Some(skel) = self.skeleton.as_ref() else { return };
        if self.bone_world.is_empty() {
            let sx = skel.get_global_transform();
            self.bone_world = (0..skel.get_bone_count()).map(|b| sx * skel.get_bone_global_pose(b)).collect();
        }
        let (lo, hi) = (lo - GVec3::splat(margin), hi + GVec3::splat(margin));
        let inside = |p: Vector3| p.x >= lo.x && p.y >= lo.y && p.z >= lo.z && p.x <= hi.x && p.y <= hi.y && p.z <= hi.z;
        // Vertices a stamp can't reach this frame sit far away (outside every stamp box).
        const FAR: f32 = 1.0e6;
        for (si, s) in self.surfaces.iter().enumerate() {
            let mut pose: Option<Vec<Transform3D>> = None;
            for (ci, (c, &layer)) in s.cpu.iter().zip(&s.layers).enumerate() {
                if layer > 1 || c.per == 0 || c.verts.is_empty() {
                    continue;
                }
                let (blo, bhi) = s.bind_bounds.get(ci).copied().unwrap_or((GVec3::splat(f32::MIN), GVec3::splat(f32::MAX)));
                if bhi.x < lo.x || bhi.y < lo.y || bhi.z < lo.z || blo.x > hi.x || blo.y > hi.y || blo.z > hi.z {
                    continue;
                }
                let bone_world = &self.bone_world;
                let pose = pose.get_or_insert_with(|| {
                    let mi_xf = s.mi.get_global_transform();
                    s.bind_poses
                        .iter()
                        .enumerate()
                        .map(|(b, bind)| {
                            let bone = s.bind_to_bone.get(b).copied().unwrap_or(-1);
                            let bone_pose = if bone >= 0 && (bone as usize) < bone_world.len() { bone_world[bone as usize] } else { mi_xf };
                            bone_pose * *bind
                        })
                        .collect()
                });
                if pose.is_empty() {
                    continue;
                }
                let n = c.verts.len();
                let entry = self.posed[si][ci].get_or_insert_with(|| (vec![GVec3::splat(FAR); n], vec![GVec3::ZERO; n], GVec3::splat(f32::MAX), GVec3::splat(f32::MIN)));
                let done = &mut self.posed_done[si][ci];
                if done.len() != n {
                    *done = vec![false; n];
                }
                for v in 0..n {
                    if done[v] || !inside(c.verts[v]) {
                        continue;
                    }
                    let (mut p, mut nn) = (Vector3::ZERO, Vector3::ZERO);
                    for j in 0..c.per {
                        let (b, w) = (c.bones[v * c.per + j], c.weights[v * c.per + j]);
                        if w > 0.0 && b >= 0 && (b as usize) < pose.len() {
                            let m = pose[b as usize];
                            p += (m * c.verts[v]) * w;
                            nn += (m.basis * c.normals[v]) * w;
                        }
                    }
                    let gp = to_glam(p);
                    entry.0[v] = gp;
                    entry.1[v] = to_glam(nn).normalize_or_zero();
                    entry.2 = entry.2.min(gp);
                    entry.3 = entry.3.max(gp);
                    done[v] = true;
                }
            }
        }
    }

    /// Hit point/direction (world) into the bind-pose space the wounds live in.
    fn world_to_rest(&self, bone: usize, p: Vector3, d: Vector3) -> (GVec3, GVec3) {
        let (Some(skel), Some(body)) = (self.skeleton.as_ref(), self.body.as_ref()) else { return (to_glam(p), to_glam(d)) };
        for b in body.skeleton.ancestry(bone) {
            for s in &self.surfaces {
                let (Some(skin), Some(&bind)) = (s.skin.as_ref(), s.bone_to_bind.get(&(b as i32))) else { continue };
                let xf = s.mi.get_global_transform() * skel.get_bone_global_pose(b as i32) * skin.get_bind_pose(bind);
                let inv = xf.affine_inverse();
                let rp = inv * p;
                let rd = (inv.basis * d).normalized_or_zero();
                return (to_glam(rp), to_glam(rd));
            }
        }
        (to_glam(p), to_glam(d))
    }

    fn planes_packed(&self) -> PackedVector4Array {
        PackedVector4Array::from(self.planes.as_slice())
    }

    fn load_cut_points(&self, body: &Body) -> HashMap<usize, (usize, Vec<f32>)> {
        let mut out = HashMap::new();
        let Some(v) = read_text(&self.cut_points_path.to_string()).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()) else {
            godot_warn!("GoreBody: no cut points at {}, limbs are cut at joints", self.cut_points_path);
            return out;
        };
        for (bone, e) in v.as_object().into_iter().flatten() {
            let child = e.get("child").and_then(|c| c.as_str()).and_then(|c| body.skeleton.find(c));
            let (Some(b), Some(c)) = (body.skeleton.find(bone), child) else { continue };
            let ts: Vec<f32> = e
                .get("cuts")
                .and_then(|c| c.as_array())
                .into_iter()
                .flatten()
                .filter_map(|c| c.get("t")?.as_f64())
                .map(|t| t as f32)
                .collect();
            out.insert(b, (c, ts));
        }
        out
    }

    /// Bind-pose positions of two bones (from a skin that binds both, else the skeleton rest).
    fn rest_segment(&self, a: usize, b: usize) -> Option<(Vector3, Vector3)> {
        for s in &self.surfaces {
            let Some(skin) = s.skin.as_ref() else { continue };
            if let (Some(&ba), Some(&bb)) = (s.bone_to_bind.get(&(a as i32)), s.bone_to_bind.get(&(b as i32))) {
                return Some((skin.get_bind_pose(ba).affine_inverse().origin, skin.get_bind_pose(bb).affine_inverse().origin));
            }
        }
        let skel = self.skeleton.as_ref()?;
        Some((skel.get_bone_global_rest(a as i32).origin, skel.get_bone_global_rest(b as i32).origin))
    }

    /// DI2 cuts a limb at the centre of the proxy box nearest the hit: of the bone's cut positions, the one
    /// closest to where the hit projects onto it. Positions at the joint keep the skin-weight cut.
    fn set_cut_plane(&mut self, cut_bone: usize, hit_rest: Vector3) {
        let Some(slot) = self.slots.iter().position(|&b| b == cut_bone) else { return };
        self.planes[slot] = Vector4::ZERO;
        self.cut_t[slot] = 0.0;
        let Some((child, ts)) = self.cut_points.get(&cut_bone).cloned() else { return };
        let Some((o, c)) = self.rest_segment(cut_bone, child) else { return };
        let axis = c - o;
        if axis.length_squared() < 1e-8 {
            return;
        }
        let t_hit = (hit_rest - o).dot(axis) / axis.length_squared();
        let Some(t) = ts.into_iter().min_by(|a, b| (a - t_hit).abs().total_cmp(&(b - t_hit).abs())) else { return };
        if t < 0.1 {
            return;
        }
        let n = axis.normalized();
        self.planes[slot] = Vector4::new(n.x, n.y, n.z, n.dot(o + axis * t));
        self.cut_t[slot] = t;
    }

    /// Nearest crossing of a world ray with the visible (skin, cloth) triangles of the body as currently
    /// posed. Vertices are skinned on the CPU exactly as the GPU skins them; severed regions are skipped.
    fn surface_hit(&self, origin: Vector3, dir: Vector3, max_t: f32, weapon_dir: Vector3) -> Option<SurfaceHit> {
        let (Some(skel), Some(body)) = (self.skeleton.as_ref(), self.body.as_ref()) else { return None };
        let mask = body.severed_slot_mask();
        let severed: Vec<usize> = (0..self.slots.len()).filter(|&k| mask & (1 << k) != 0).collect();
        let hidden = |c: &SurfaceCpu, v: usize| severed.iter().any(|&k| (c.slot_w[v][k] - 0.5).min(plane_side(self.planes[k], c.verts[v])) > 0.0);
        let skel_xf = skel.get_global_transform();
        // (distance, surface, layer surface, triangle, barycentrics)
        let mut best: Option<(f32, usize, usize, [usize; 3], [f32; 3])> = None;
        let mut poses: Vec<Vec<Transform3D>> = Vec::new();
        for (si, s) in self.surfaces.iter().enumerate() {
            let pose: Vec<Transform3D> = match s.skin.as_ref() {
                Some(skin) => (0..skin.get_bind_count())
                    .map(|b| {
                        let bone = s.bind_to_bone.get(b as usize).copied().unwrap_or(-1);
                        let bone_pose = if bone >= 0 { skel_xf * skel.get_bone_global_pose(bone) } else { s.mi.get_global_transform() };
                        bone_pose * skin.get_bind_pose(b)
                    })
                    .collect(),
                None => Vec::new(),
            };
            for (ci, (c, &layer)) in s.cpu.iter().zip(&s.layers).enumerate() {
                if layer > 1 || pose.is_empty() || c.per == 0 {
                    continue;
                }
                let posed: Vec<Vector3> = (0..c.verts.len())
                    .map(|v| {
                        let mut out = Vector3::ZERO;
                        for j in 0..c.per {
                            let (b, w) = (c.bones[v * c.per + j], c.weights[v * c.per + j]);
                            if w > 0.0 && b >= 0 && (b as usize) < pose.len() {
                                out += (pose[b as usize] * c.verts[v]) * w;
                            }
                        }
                        out
                    })
                    .collect();
                for tri in c.indices.chunks_exact(3) {
                    let ids = [tri[0] as usize, tri[1] as usize, tri[2] as usize];
                    let Some((t, u, v)) = ray_triangle(origin, dir, posed[ids[0]], posed[ids[1]], posed[ids[2]]) else { continue };
                    if t > max_t || best.as_ref().is_some_and(|b| t >= b.0) || ids.iter().all(|&i| hidden(c, i)) {
                        continue;
                    }
                    best = Some((t, si, ci, ids, [1.0 - u - v, u, v]));
                }
            }
            poses.push(pose);
        }
        let (t, si, ci, ids, bary) = best?;
        let s = &self.surfaces[si];
        let c = &s.cpu[ci];
        let pose = &poses[si];
        let mut rest = Vector3::ZERO;
        let mut weights: HashMap<i32, f32> = HashMap::new();
        for (k, &v) in ids.iter().enumerate() {
            rest += c.verts[v] * bary[k];
            for j in 0..c.per {
                let (b, w) = (c.bones[v * c.per + j], c.weights[v * c.per + j]);
                if w > 0.0 && b >= 0 {
                    *weights.entry(b).or_default() += w * bary[k];
                }
            }
        }
        // The skinning at the impact (blended like the GPU does) carries directions into bind pose.
        let (mut ca, mut cb, mut cc) = (Vector3::ZERO, Vector3::ZERO, Vector3::ZERO);
        for (&b, &w) in &weights {
            if let Some(m) = pose.get(b as usize) {
                ca += m.basis.col_a() * w;
                cb += m.basis.col_b() * w;
                cc += m.basis.col_c() * w;
            }
        }
        let inv = Basis::from_cols(ca, cb, cc).inverse();
        let rest_into = (inv * dir).normalized_or_zero();
        let mut rest_normal = (c.verts[ids[1]] - c.verts[ids[0]]).cross(c.verts[ids[2]] - c.verts[ids[0]]).normalized_or_zero();
        if rest_normal.dot(rest_into) > 0.0 {
            rest_normal = -rest_normal;
        }
        let bone = weights
            .iter()
            .filter_map(|(&b, &w)| s.bind_to_bone.get(b as usize).filter(|&&bone| bone >= 0).map(|&bone| (bone as usize, w)))
            .max_by(|a, b| a.1.total_cmp(&b.1))?
            .0;
        Some(SurfaceHit {
            bone,
            rest,
            world: origin + dir * t,
            rest_into,
            rest_dir: (inv * weapon_dir).normalized_or_zero(),
            rest_normal,
            rest_up: (inv * Vector3::UP).normalized_or_zero(),
        })
    }

    /// Deep ring wound at the cut so the stump reads as open flesh.
    fn add_stump(&mut self, cut_bone: usize, part: usize) {
        let Some(body) = self.body.as_ref() else { return };
        let role = body.parts[part].role;
        let child = (0..body.skeleton.len()).find(|&c| body.skeleton.parents[c] == Some(cut_bone));
        let mut centre = None;
        for s in &self.surfaces {
            let Some(skin) = s.skin.as_ref() else { continue };
            let Some(&bind) = s.bone_to_bind.get(&(cut_bone as i32)) else { continue };
            let bone_rest = skin.get_bind_pose(bind).affine_inverse();
            let axis = child
                .and_then(|c| s.bone_to_bind.get(&(c as i32)).map(|&cb| skin.get_bind_pose(cb).affine_inverse().origin - bone_rest.origin))
                .unwrap_or(bone_rest.basis.col_a());
            centre = Some((bone_rest.origin, axis));
            break;
        }
        let Some((mut c, axis)) = centre else { return };
        if let Some(slot) = self.slots.iter().position(|&b| b == cut_bone) {
            let pl = self.planes[slot];
            let n = Vector3::new(pl.x, pl.y, pl.z);
            if n.length_squared() > 0.25 {
                c -= n * (n.dot(c) - pl.w);
            }
        }
        let radius = match role {
            PartRole::Head => 0.07,
            r if r.is_leg() => 0.085,
            _ => 0.055,
        };
        self.wounds.as_mut().unwrap().add_stump(to_glam(c), to_glam(axis), radius);
    }

    fn bake_meshes(&mut self, skel: &Gd<Skeleton3D>) {
        self.surfaces.clear();
        let body = self.body.as_ref().unwrap();
        // Per skeleton bone: bit k set when the bone lies in cut slot k's subtree.
        let bone_bits: Vec<u32> = (0..body.skeleton.len())
            .map(|b| self.slots.iter().enumerate().filter(|(_, &s)| body.skeleton.is_in_subtree(b, s)).fold(0u32, |m, (k, _)| m | (1 << k)))
            .collect();
        let signature: String = self.slots.iter().map(|s| body.skeleton.names[*s].as_str()).collect::<Vec<_>>().join(",");
        let manifest = self.load_manifest();
        let shader = try_load::<Shader>(FLESH_SHADER).ok();
        if shader.is_none() {
            godot_error!("GoreBody: cannot load {FLESH_SHADER}");
        }
        let splatter = self.load_splatter();
        let dir = manifest_dir(&self.materials_manifest.to_string());
        let flesh = flesh_data(&self.flesh_materials_path.to_string());

        for mut mi in collect_meshes(&skel.clone().upcast::<Node>()) {
            let Some(mesh) = mi.get_mesh() else { continue };
            let Ok(src) = mesh.clone().try_cast::<ArrayMesh>() else { continue };
            let skin = mi.get_skin();
            let mut bone_to_bind = HashMap::new();
            let mut bind_to_bone = Vec::new();
            let mut bind_bits = Vec::new();
            if let Some(skin) = skin.as_ref() {
                for i in 0..skin.get_bind_count() {
                    let mut bone = skin.get_bind_bone(i);
                    if bone < 0 {
                        bone = skel.find_bone(&skin.get_bind_name(i).to_string());
                    }
                    bone_to_bind.entry(bone).or_insert(i);
                    bind_to_bone.push(bone);
                    bind_bits.push(usize::try_from(bone).ok().map_or(0, |b| bone_bits[b]));
                }
            }

            let key = (src.instance_id().to_i64(), signature.clone());
            // Shared part meshes (SK_Skeleton, SK_ZombieViscera ...) are tagged by zombie.gd with their glb; the body
            // mesh is the deform stream's glb.
            let body_glb = self.deform_path.to_string().trim_end_matches(".deform.bin").to_string() + ".glb";
            let glb = if mi.has_meta("di2_glb") { mi.get_meta("di2_glb").try_to::<GString>().map(|g| g.to_string()).unwrap_or(body_glb.clone()) } else { body_glb.clone() };
            let is_body = glb == body_glb;
            let empty = String::new();
            let deform_src = if is_body { self.deform_path.to_string() } else { empty };
            let deform_for = load_deform(&deform_src, &src);
            let initial_depth = if is_body { load_initial_depth(&deform_src, &src) } else { vec![0.0; src.get_surface_count() as usize] };
            let mut hidden = if is_body { load_initially_hidden(&deform_src, &src) } else { vec![false; src.get_surface_count() as usize] };
            let subs = load_subsections(&self.subsections_path.to_string(), &glb, &src);
            for (s, e) in subs.iter().enumerate() {
                if let Some(e) = e {
                    if e.initially_hidden && s < hidden.len() {
                        hidden[s] = true;
                    }
                }
            }
            let sub_ids: Vec<Vec<u16>> = subs.iter().map(|e| e.as_ref().map(|e| e.vertex_sub.clone()).unwrap_or_default()).collect();
            let sub_names: Vec<Vec<String>> = subs.iter().map(|e| e.as_ref().map(|e| e.names.clone()).unwrap_or_default()).collect();
            let sub_hidden: Vec<u64> = vec![0; sub_names.len()];
            let part_manifest;
            let (manifest, dir) = if is_body {
                (&manifest, dir.clone())
            } else {
                let path = glb.trim_end_matches(".glb").to_string() + ".materials.json";
                part_manifest = read_text(&path).and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok()).and_then(|v| v.as_object().cloned()).unwrap_or_default();
                (&part_manifest, manifest_dir(&path))
            };
            let (baked, cpu) = BAKED.with(|c| c.borrow().get(&key).cloned()).unwrap_or_else(|| {
                let (m, cpu) = bake(&src, &bind_bits, &deform_for, &initial_depth, &sub_ids);
                let entry = (m, Rc::new(cpu));
                BAKED.with(|c| c.borrow_mut().insert(key, entry.clone()));
                entry
            });
            mi.set_mesh(&baked.clone().upcast::<Mesh>());

            let mut materials = Vec::new();
            let mut layers = Vec::new();
            for s in 0..baked.get_surface_count() {
                let name = baked.surface_get_material(s).map(|m| m.get_name().to_string()).unwrap_or_default();
                let entry = manifest.get(&name).cloned().unwrap_or(serde_json::Value::Null);
                let mut mat = ShaderMaterial::new_gd();
                if entry.get("layer").and_then(|v| v.as_str()) == Some("eye_overlay") {
                    if let Ok(sh) = try_load::<Shader>(EYE_OCCLUSION_SHADER) {
                        mat.set_shader(&sh);
                    }
                } else if let (Some("eye"), Ok(sh)) = (entry.get("layer").and_then(|v| v.as_str()), try_load::<Shader>(EYE_SHADER)) {
                    mat.set_shader(&sh);
                } else if let Some(sh) = shader.as_ref() {
                    mat.set_shader(sh);
                }
                let layer = configure_material(&mut mat, &entry, &splatter, &dir);
                if layer == 0 {
                    set_inner_maps(&mut mat, &name, manifest, &dir);
                }
                if let Some(fm) = flesh.get("materials").and_then(|m| m.get(&name)) {
                    apply_flesh_material(&mut mat, fm, &self.flesh_dir.to_string());
                }
                // DI2 InitiallyHiddenMask (per material slot): sections drawn only once revealed (dismember).
                mat.set_shader_parameter("section_hidden", &hidden.get(s as usize).copied().unwrap_or(false).to_variant());
                layers.push(layer);
                mat.set_name(&name);
                mi.set_surface_override_material(s, &mat.clone().upcast::<Material>());
                materials.push(mat);
            }
            let names: Vec<String> = materials.iter().map(|m| m.get_name().to_string()).collect();
            let rt_source = splatter_sources(&names, &layers);
            let bind_bounds: Vec<(GVec3, GVec3)> = cpu.iter().map(|c| c.verts.iter().fold((GVec3::splat(f32::MAX), GVec3::splat(f32::MIN)), |(lo, hi), v| (lo.min(to_glam(*v)), hi.max(to_glam(*v))))).collect();
            let rts = (0..materials.len()).map(|_| None).collect();
            let bind_poses: Vec<Transform3D> = skin.as_ref().map(|k| (0..k.get_bind_count()).map(|b| k.get_bind_pose(b)).collect()).unwrap_or_default();
            self.surfaces.push(Surface { mi, materials, layers, bone_to_bind, bind_to_bone, skin, cpu, own_mesh: false, rts, rt_source, vbuf: Vec::new(), sub_names, sub_hidden, is_body, cur_indices: Vec::new(), bind_bounds, bind_poses });
        }

        // Cut caps share one template: the flesh shader in cap mode with DI2's breakage flesh textures.
        let cap_entries = read_text(&self.cap_manifest.to_string())
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .unwrap_or(serde_json::Value::Null);
        let entry = cap_entries.get(self.cap_material.to_string()).cloned().unwrap_or(serde_json::Value::Null);
        if entry.is_null() {
            godot_warn!("GoreBody: no {} in {}, caps use flat flesh", self.cap_material, self.cap_manifest);
        }
        let mut cap = ShaderMaterial::new_gd();
        if let Some(sh) = shader.as_ref() {
            cap.set_shader(sh);
        }
        configure_material(&mut cap, &entry, &splatter, &manifest_dir(&self.cap_manifest.to_string()));
        cap.set_shader_parameter("layer", &CAP_LAYER.to_variant());
        cap.set_name("cut_cap");
        self.cap_template = Some(cap);
    }

    fn load_manifest(&self) -> serde_json::Map<String, serde_json::Value> {
        read_text(&self.materials_manifest.to_string())
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default()
    }

    fn load_splatter(&self) -> Vec<(&'static str, Gd<Texture2D>)> {
        let dir = self.splatter_dir.to_string();
        let mut v = Vec::new();
        for (param, file) in [
            ("gore_gradient", self.gore_gradient.to_string()),
            ("wound_noise", "T_SkinSplatterWoundNoise_H.png".to_string()),
            ("blood_detail", "T_SkinBloodSplatterDetail_A.png".to_string()),
            ("drips_tex", "T_SkinBloodDrips_A.png".to_string()),
            ("bruise_tex", "T_Bruise_D.png".to_string()),
            ("char_tex", "T_CauterizedFlesh_A.png".to_string()),
            ("wound_noise_n", "T_SkinSplatterWoundNoise_N.png".to_string()),
            ("caut_n", "T_CauterizedFlesh_N.png".to_string()),
            ("fabric_tear", "T_FabricTearDetail_A.png".to_string()),
        ] {
            if let Ok(t) = try_load::<Texture2D>(&format!("{dir}/{file}")) {
                v.push((param, t));
            }
        }
        v
    }

    fn drawn_wounds(&self) -> i32 {
        match self.wounds.as_ref() {
            Some(w) if self.procedural_wounds => w.wounds.len() as i32,
            _ => 0,
        }
    }

    fn push_stamp(&mut self, params: &VarDictionary, origin: GVec3, ax: GVec3, ay: GVec3, az: GVec3, persistent: bool) -> bool {
        // DI2 Apply with animFraction < 1 (animated splatter ticks): strengths x "strength".
        let k = params.get("strength").and_then(|v| v.try_to::<f64>().ok()).map_or(1.0, |v| v as f32);
        let mut stamp = self.stamp_from(params, origin, ax, ay, az);
        if k != 1.0 {
            stamp = stamp.scaled(k);
        }
        stamp.persistent = persistent;
        let td = std::time::Instant::now();
        self.deform_pass(&stamp);
        self.bake_phases[3] += td.elapsed().as_secs_f64() * 1000.0;
        self.bake_stamp(&stamp);
        self.splatter.add(stamp)
    }

    /// DI2's FSplatterPS for one stamp into every skin / cloth section's UV0 render targets it reaches, then the
    /// H/V dilation and an upload of the sections that changed.
    fn bake_stamp(&mut self, stamp: &Stamp) {
        let t0 = std::time::Instant::now();
        self.bake_stamp_inner(stamp);
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        let st = &mut self.bake_stats;
        *st = (st.0 + 1, st.1 + ms, st.2.max(ms));
    }

    fn bake_stamp_inner(&mut self, stamp: &Stamp) {
        self.bake_stamp_ex(stamp, false, None);
    }

    /// `radial` = the cut band's (radial decal matrix row y, SafeRegionMatrix rows y, z): GPU only (bind pose).
    fn bake_stamp_ex(&mut self, stamp: &Stamp, posed: bool, radial: Option<[[f32; 4]; 3]>) {
        let px = &self.stamp_px;
        let phases = &mut self.bake_phases;
        let sample = |tex: i32, u: f32, v: f32| -> [f32; 4] { bilinear(px, tex, u, v) };
        let gpu = gpu_bake::gpu().filter(|_| self.stamp_tex.is_some());
        let stamps_rd = self.stamp_tex.as_ref().map(gpu_bake::rd_texture);
        for (si, s) in self.surfaces.iter_mut().enumerate() {
            for ci in 0..s.cpu.len() {
                let layer = s.layers.get(ci).copied().unwrap_or(7);
                if layer > 1 || s.cpu[ci].uv.is_empty() {
                    continue;
                }
                let cloth = layer == 1;
                let c = &s.cpu[ci];
                let tm = std::time::Instant::now();
                // Same geometry in every body of this mesh: share the map (and, on the GPU, its texel buffer).
                let v0 = c.verts.first().copied().unwrap_or(Vector3::ZERO);
                let key = (c.verts.len(), c.indices.len(), [v0.x.to_bits(), v0.y.to_bits(), v0.z.to_bits()]);
                let map = c.texmap.get_or_init(|| {
                    TEXMAPS.with(|t| {
                        t.borrow_mut().entry(key).or_insert_with(|| {
                            let pos: Vec<GVec3> = c.verts.iter().map(|v| to_glam(*v)).collect();
                            let nrm: Vec<GVec3> = c.normals.iter().map(|v| to_glam(*v)).collect();
                            let dlen: Vec<f32> = if c.deform.len() == c.verts.len() { c.deform.iter().map(|d| d.length() * 100.0).collect() } else { Vec::new() };
                            let idx: Vec<u32> = c.indices.iter().map(|&i| i as u32).collect();
                            Rc::new(TexelMap::build(SPLATTER_RT_RES, &pos, &nrm, &dlen, &c.uv, &idx))
                        }).clone()
                    })
                }).clone();
                phases[0] += tm.elapsed().as_secs_f64() * 1000.0;
                let (lo, hi) = SplatterRt::bounds(stamp, cloth);
                let posed_sec = if posed { self.posed.get(si).and_then(|p| p.get(ci)).and_then(|p| p.as_ref()) } else { None };
                match posed_sec {
                    Some((_, _, plo, phi)) => {
                        if hi.x < plo.x || hi.y < plo.y || hi.z < plo.z || lo.x > phi.x || lo.y > phi.y || lo.z > phi.z {
                            continue;
                        }
                    }
                    None if posed => continue,
                    None => {
                        if !map.overlaps(lo, hi) {
                            continue;
                        }
                    }
                }
                if s.rts[ci].is_none() {
                    let made = match (gpu.as_ref(), stamps_rd) {
                        (Some(g), Some(st)) => g.borrow_mut().section(key, &map, st, c.verts.len()).map(SectionTargets::Gpu),
                        _ => None,
                    };
                    let made = made.or_else(|| {
                        let blank = Image::create_empty(SPLATTER_RT_RES as i32, SPLATTER_RT_RES as i32, false, godot::classes::image::Format::RGBA8)?;
                        let d = ImageTexture::create_from_image(&blank)?;
                        let f = ImageTexture::create_from_image(&blank)?;
                        Some(SectionTargets::Cpu(SectionRt { rt: SplatterRt::new(SPLATTER_RT_RES), disp: d, dif: f, dirty: true }))
                    });
                    let Some(made) = made else { continue };
                    let (d, f): (Variant, Variant) = match &made {
                        SectionTargets::Gpu(g) => (g.disp_tex.to_variant(), g.dif_tex.to_variant()),
                        SectionTargets::Cpu(c) => (c.disp.to_variant(), c.dif.to_variant()),
                    };
                    for (mi, src) in s.rt_source.iter().enumerate() {
                        if let Some((from, uv1)) = src {
                            if *from == ci {
                                let m = &mut s.materials[mi];
                                m.set_shader_parameter("splat_disp", &d);
                                m.set_shader_parameter("splat_dif", &f);
                                m.set_shader_parameter("has_splat_rt", &true.to_variant());
                                m.set_shader_parameter("splat_uv2", &uv1.to_variant());
                            }
                        }
                    }
                    s.rts[ci] = Some(made);
                }
                match s.rts[ci].as_mut().unwrap() {
                    SectionTargets::Gpu(_) => {
                        if posed && !self.posed_upload.contains(&(si, ci)) {
                            self.posed_upload.push((si, ci));
                        }
                        self.gpu_jobs.push((si, ci, stamp.clone(), cloth, posed, radial));
                    }
                    SectionTargets::Cpu(_) if radial.is_some() => {}   // the radial band is GPU-only (UNVERIFIED #50)
                    SectionTargets::Cpu(srt) => {
                        let ta = std::time::Instant::now();
                        let pv = posed_sec.map(|(p, n, _, _)| (p.as_slice(), n.as_slice()));
                        let applied = srt.rt.apply_posed(&map, stamp, cloth, &sample, pv);
                        phases[1] += ta.elapsed().as_secs_f64() * 1000.0;
                        let Some(rect) = applied else { continue };
                        let td = std::time::Instant::now();
                        srt.rt.dilate(rect);
                        phases[2] += td.elapsed().as_secs_f64() * 1000.0;
                        srt.dirty = true;
                    }
                }
            }
        }
    }

    fn set_subsection(&mut self, name: &str, hide: bool) -> bool {
        let mut changed = false;
        for s in self.surfaces.iter_mut() {
            for ci in 0..s.sub_names.len() {
                let mut mask = s.sub_hidden[ci];
                for (k, n) in s.sub_names[ci].iter().enumerate() {
                    if k < 64 && n.eq_ignore_ascii_case(name) {
                        mask = if hide { mask | (1u64 << k) } else { mask & !(1u64 << k) };
                    }
                }
                if mask != s.sub_hidden[ci] {
                    s.sub_hidden[ci] = mask;
                    changed = true;
                    if let Some(m) = s.materials.get_mut(ci) {
                        m.set_shader_parameter("sub_hidden_lo", &((mask & 0xffff_ffff) as u32 as i32).to_variant());
                        m.set_shader_parameter("sub_hidden_hi", &((mask >> 32) as u32 as i32).to_variant());
                    }
                }
            }
        }
        changed
    }

    /// A stamp from GDScript params, not yet applied anywhere.
    fn stamp_from(&self, params: &VarDictionary, origin: GVec3, ax: GVec3, ay: GVec3, az: GVec3) -> Stamp {
        let f = |k: &str, d: f32| {
            params
                .get(k)
                .and_then(|v| v.try_to::<f64>().ok().or_else(|| v.try_to::<i64>().ok().map(|i| i as f64)))
                .map(|v| v as f32)
                .unwrap_or(d)
        };
        Stamp {
            origin, ax, ay, az,
            half_size: f("half_size", 0.05), depth: f("depth", 0.1), fade_gain: f("fade_gain", 1.0 / 0.65),
            angle_wrap: f("angle_wrap", 1.0),
            displacement_tex: f("displacement_tex", -1.0) as i32, diffuse_tex: f("diffuse_tex", -1.0) as i32,
            flags: f("flags", 4.0) as u32, cloth_depth: f("cloth_depth", 1.0), cloth_displacement: f("cloth_displacement", 1.0),
            wound: [f("wound_r", 1.0), f("wound_g", 1.0), f("wound_b", 1.0)],
            fx: [f("fx_r", 1.0), f("fx_g", 1.0), f("fx_b", 1.0), f("fx_a", 1.0)],
            range: [f("range_min", 0.0), f("range_size", 1.0)],
            displacement: f("displacement", 1.0), persistent: false, id: 0,
        }
    }

    /// DI2's FSplatterDeformMeshCS for one stamp over every skin / cloth vertex (bind pose), then uploads the
    /// per-vertex depth textures the flesh shader sinks the surface and opens wounds with.
    fn deform_pass(&mut self, stamp: &Stamp) {
        self.deform_pass_ex(stamp, false);
    }

    /// DI2's deform CS; `posed` = against this frame's skinned vertices (the World permutation, p80).
    fn deform_pass_ex(&mut self, stamp: &Stamp, posed: bool) {
        // A zero-amplitude stamp leaves every depth as it is (add 0 / max with 0); ApplyMin would still pull to 0.
        if stamp.displacement == 0.0 && stamp.flags & gore_core::splatter::APPLY_MIN == 0 {
            return;
        }
        let rs = &self.stamp_px;
        let sample = |tex: i32, u: f32, v: f32| -> f32 {
            match rs.get(tex as usize) {
                Some((w, h, px)) if *w > 0 => {
                    let x = ((u * *w as f32) as i32).clamp(0, *w - 1);
                    let y = ((v * *h as f32) as i32).clamp(0, *h - 1);
                    px[((y * *w + x) * 4) as usize] as f32 / 255.0
                }
                _ => 0.0,
            }
        };
        if self.vdepth.len() != self.surfaces.len() {
            self.vdepth = self.surfaces.iter().map(|s| s.cpu.iter().map(|c| vec![0.0; c.verts.len()]).collect()).collect();
            self.vdepth_tex = self.surfaces.iter().map(|s| vec![None; s.cpu.len()]).collect();
            self.vdepth_dirty = self.surfaces.iter().map(|s| vec![false; s.cpu.len()]).collect();
            self.vdepth_range = self.surfaces.iter().map(|s| vec![(usize::MAX, 0); s.cpu.len()]).collect();
        }
        for (si, s) in self.surfaces.iter_mut().enumerate() {
            for (ci, (c, &layer)) in s.cpu.iter().zip(&s.layers).enumerate() {
                if layer > 1 || c.verts.is_empty() {
                    continue;
                }
                let cloth = layer == 1;
                let depth = &mut self.vdepth[si][ci];
                let mut changed = false;
                let posed_sec = if posed { self.posed.get(si).and_then(|p| p.get(ci)).and_then(|p| p.as_ref()) } else { None };
                if posed && posed_sec.is_none() {
                    continue;
                }
                for (vi, p) in c.verts.iter().enumerate() {
                    let n = c.normals.get(vi).copied().unwrap_or(Vector3::ZERO);
                    let (pp, nn) = match posed_sec {
                        Some((pos, nrm, _, _)) => (pos[vi], nrm[vi]),
                        None => (SVec3::new(p.x, p.y, p.z), SVec3::new(n.x, n.y, n.z)),
                    };
                    let len_cm = c.deform.get(vi).map_or(0.0, |d| d.length() * 100.0);
                    // DI2 stores the depth as a half float (Deform.w): steps below its precision don't land.
                    let d = f16_round(stamp.deform_vertex(pp, nn, cloth, len_cm, depth[vi], &sample));
                    if d != depth[vi] {
                        depth[vi] = d;
                        changed = true;
                        let r = &mut self.vdepth_range[si][ci];
                        *r = (r.0.min(vi), r.1.max(vi + 1));
                    }
                }
                if changed {
                    self.vdepth_dirty[si][ci] = true;
                }
            }
        }
    }

    /// Once per frame: uploads the splatter targets and per-vertex depths written since the last frame and sinks
    /// the vertices that moved (every stamp application in a frame shares one upload).
    fn flush_splatter(&mut self) {
        let tf = std::time::Instant::now();
        self.flush_splatter_inner();
        self.bake_phases[4] += tf.elapsed().as_secs_f64() * 1000.0;
    }

    fn flush_splatter_inner(&mut self) {
        if let Some(g) = gpu_bake::gpu() {
            g.borrow_mut().collect();
        }
        if !self.gpu_jobs.is_empty() {
            if let Some(g) = gpu_bake::gpu() {
                for (si, ci) in std::mem::take(&mut self.posed_upload) {
                    if let (Some(Some(SectionTargets::Gpu(sec))), Some(Some((pos, nrm, _, _)))) =
                        (self.surfaces.get(si).and_then(|s| s.rts.get(ci)), self.posed.get(si).and_then(|p| p.get(ci)))
                    {
                        g.borrow_mut().upload_posed(sec, pos, nrm);
                    }
                }
                let jobs: Vec<(&GpuSection, Stamp, bool, bool, Option<[[f32; 4]; 3]>)> = self.gpu_jobs.iter().filter_map(|(si, ci, st, cloth, posed, radial)| match self.surfaces.get(*si).and_then(|s| s.rts.get(*ci)) {
                    Some(Some(SectionTargets::Gpu(sec))) => Some((sec, st.clone(), *cloth, *posed, *radial)),
                    _ => None,
                }).collect();
                g.borrow_mut().run(&jobs);
            }
            self.gpu_jobs.clear();
        }
        for s in self.surfaces.iter_mut() {
            for srt in s.rts.iter_mut().flatten().filter_map(|t| match t { SectionTargets::Cpu(c) => Some(c), _ => None }) {
                if !srt.dirty {
                    continue;
                }
                srt.dirty = false;
                for (rt, tex) in [(&srt.rt.disp, &mut srt.disp), (&srt.rt.dif, &mut srt.dif)] {
                    if let Some(img) = Image::create_from_data(SPLATTER_RT_RES as i32, SPLATTER_RT_RES as i32, false, godot::classes::image::Format::RGBA8, &PackedByteArray::from(rgba_bytes(rt))) {
                        tex.update(&img);
                    }
                }
            }
        }
        for si in 0..self.vdepth_dirty.len() {
            for ci in 0..self.vdepth_dirty[si].len() {
                if !self.vdepth_dirty[si][ci] {
                    continue;
                }
                self.vdepth_dirty[si][ci] = false;
                let s = &mut self.surfaces[si];
                let c = &s.cpu[ci];
                let depth = &self.vdepth[si][ci];
                if !c.deform.is_empty() {
                    if s.vbuf.len() != s.cpu.len() {
                        s.vbuf = (0..s.cpu.len()).map(|_| None).collect();
                    }
                    let range = self.vdepth_range.get(si).and_then(|r| r.get(ci)).copied().unwrap_or((usize::MAX, 0));
                    sink_vertices(&mut s.mi, &mut s.own_mesh, ci, c, depth, &mut s.vbuf[ci], range);
                }
                if let Some(r) = self.vdepth_range.get_mut(si).and_then(|r| r.get_mut(ci)) {
                    *r = (usize::MAX, 0);
                }
                const W: usize = 2048;
                let n = depth.len();
                let h = n.div_ceil(W);
                let mut buf = vec![0f32; W * h];
                buf[..n].copy_from_slice(depth);
                let bytes: Vec<u8> = buf.iter().flat_map(|v| v.to_le_bytes()).collect();
                let Some(img) = Image::create_from_data(W as i32, h as i32, false, godot::classes::image::Format::RF, &PackedByteArray::from(bytes.as_slice())) else { continue };
                let slot = &mut self.vdepth_tex[si][ci];
                match slot.as_mut() {
                    Some(t) => t.update(&img),
                    None => *slot = ImageTexture::create_from_image(&img),
                }
                if let (Some(t), Some(m)) = (slot.as_ref(), s.materials.get_mut(ci)) {
                    m.set_shader_parameter("vdepth_tex", &t.to_variant());
                    m.set_shader_parameter("vdepth_w", &(W as i32).to_variant());
                    m.set_shader_parameter("has_vdepth", &true.to_variant());
                }
            }
        }
    }

    fn push_uniforms(&mut self) {
        let (Some(wounds), Some(body)) = (self.wounds.as_ref(), self.body.as_ref()) else { return };
        let packed = PackedVector4Array::from_iter(wounds.pack().into_iter().map(|v| Vector4::new(v.x, v.y, v.z, v.w)));
        let count = if self.procedural_wounds { wounds.wounds.len() as i32 } else { 0 };
        let mask = body.severed_slot_mask() as i32;
        let planes = PackedVector4Array::from(self.planes.as_slice());
        for m in self.surfaces.iter_mut().flat_map(|s| s.materials.iter_mut()).chain(self.cap_materials.iter_mut()) {
            m.set_shader_parameter("cut_planes", &planes.to_variant());
            m.set_shader_parameter("wounds", &packed.to_variant());
            m.set_shader_parameter("wound_count", &count.to_variant());
            m.set_shader_parameter("severed_mask", &mask.to_variant());
        }
    }
}

/// Moller-Trumbore, both faces: (distance, u, v) where the ray crosses triangle abc.
fn ray_triangle(o: Vector3, d: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Option<(f32, f32, f32)> {
    let (e1, e2) = (b - a, c - a);
    let p = d.cross(e2);
    let det = e1.dot(p);
    if det.abs() < 1e-12 {
        return None;
    }
    let inv = 1.0 / det;
    let s = o - a;
    let u = s.dot(p) * inv;
    if !(0.0..=1.0).contains(&u) {
        return None;
    }
    let q = s.cross(e1);
    let v = d.dot(q) * inv;
    if v < 0.0 || u + v > 1.0 {
        return None;
    }
    let t = e2.dot(q) * inv;
    (t > 0.0).then_some((t, u, v))
}

fn manifest_dir(path: &str) -> String {
    path.rsplit_once('/').map(|(d, _)| d.to_string()).unwrap_or_default()
}

/// Sets a flesh shader material up from a materials-manifest entry (textures relative to `dir`). Returns its layer.
fn configure_material(mat: &mut Gd<ShaderMaterial>, entry: &serde_json::Value, splatter: &[(&str, Gd<Texture2D>)], dir: &str) -> i32 {
    let layer = match entry.get("layer").and_then(|v| v.as_str()).unwrap_or("skin") {
        "skin" => 0,
        "cloth" => 1,
        "muscle" => 2,
        "bone" => 3,
        "organs" => 4,
        "eye" => 5,
        "eye_overlay" => 9,
        "hair" => 6,
        _ => 7,
    };
    mat.set_shader_parameter("layer", &layer.to_variant());
    for (slot, param) in [("albedo", "albedo_tex"), ("normal", "normal_tex"), ("mro", "mro_tex"), ("ata", "ata_tex")] {
        if let Some(rel) = entry.get(slot).and_then(|v| v.as_str()) {
            if let Ok(tex) = try_load::<Texture2D>(&format!("{dir}/{rel}")) {
                mat.set_shader_parameter(param, &tex.to_variant());
                mat.set_shader_parameter(&format!("has_{slot}"), &true.to_variant());
            }
        }
    }
    // DI2 skin / interior sections are single-sided (the shader discards back faces of those).
    let two_sided = entry.get("two_sided").and_then(|v| v.as_bool()).unwrap_or(true);
    mat.set_shader_parameter("two_sided", &two_sided.to_variant());
    let masked = entry.get("masked").and_then(|v| v.as_bool()).unwrap_or(false);
    mat.set_shader_parameter("use_alpha_clip", &masked.to_variant());
    mat.set_shader_parameter("alpha_clip", &(entry.get("clip").and_then(|v| v.as_f64()).unwrap_or(0.333) as f32).to_variant());
    for (p, t) in splatter {
        mat.set_shader_parameter(*p, &t.to_variant());
    }
    layer
}

/// DI2 base-map parameters (resolved through the MI chain in data/flesh_materials.json) -> flesh shader slots.
const RESOLVED_BASE_MAPS: [(&str, &str); 4] = [("Diffuse Colour Map", "albedo"), ("Normal Map", "normal"),
    ("Packed MRO Map (see tooltip!)", "mro"), ("Packed ATA Map (see tooltip!)", "ata")];

/// data/flesh_materials.json, parsed once per path.
fn flesh_data(path: &str) -> Rc<serde_json::Value> {
    FLESH_DATA.with(|c| {
        c.borrow_mut()
            .entry(path.to_string())
            .or_insert_with(|| read_text(path).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()).map(Rc::new).unwrap_or_else(|| Rc::new(serde_json::Value::Null)))
            .clone()
    })
}

/// A raw FLESH texture (PNG, or half-float EXR for HDR sources such as the eye mid-plane) as a texture (cached;
/// mipmapped).
fn flesh_texture(dir: &str, name: &str) -> Option<Gd<ImageTexture>> {
    let path = ["png", "exr"].iter().map(|e| format!("{dir}/{name}.{e}")).find(|p| FileAccess::file_exists(p))?;
    if let Some(t) = FLESH_TEX.with(|c| c.borrow().get(&path).cloned()) {
        return Some(t);
    }
    let mut img = Image::load_from_file(&path)?;
    img.generate_mipmaps();
    let t = ImageTexture::create_from_image(&img)?;
    FLESH_TEX.with(|c| c.borrow_mut().insert(path, t.clone()));
    Some(t)
}

/// Sets a section's DI2 FLESH parameters and textures from its data/flesh_materials.json entry (values resolved
/// through the MI chain; null = the parameter doesn't apply to this master).
fn apply_flesh_material(mat: &mut Gd<ShaderMaterial>, fm: &serde_json::Value, dir: &str) {
    let p = &fm["params"];
    let scalar = |k: &str| p["scalars"].get(k).and_then(|v| v["value"].as_f64()).map(|v| v as f32);
    let vector = |k: &str| p["vectors"].get(k).and_then(|v| v["value"].as_array()).map(|a| a.iter().map(|x| x.as_f64().unwrap_or(0.0) as f32).collect::<Vec<_>>());
    let texture = |k: &str| p["textures"].get(k).and_then(|v| v["value"].as_str()).map(|s| s.to_string());
    for (k, u) in [
        ("03 - Epidermis Map Tiling", "epidermis_tiling"), ("02 - Blood Splatter Map Tiling", "blood_splatter_tiling"),
        ("02 - Blood Drip Map Tiling", "blood_drip_tiling"), ("07 - Cauterization Map Tiling", "caut_tiling"),
        ("01 - Bruise Map Tiling", "bruise_tiling"), ("05 - Bruise Desaturation", "bruise_desat"),
        ("Inner Desaturation", "inner_desat"), ("inner Roughness", "inner_rough"), ("Splatter Opacity Offset", "opacity_offset"),
        ("03 - Fabric Tear Map Tiling", "fabric_tear_tiling"), ("Rip Amount", "rip_amount"),
        // M_EyeRefractive
        ("Iris Scale", "iris_scale"), ("LimbusUVWidthColor", "limbus_w_color"), ("LimbusUVWidthShading", "limbus_w_shading"),
        ("FlattenNormal", "flatten_normal"), ("Lens IoR", "lens_ior"), ("Iris Depth", "iris_depth"), ("Pupil Size", "pupil_size"),
        ("Iris Brightness", "iris_brightness"), ("Aggressive Iris", "aggressive_iris"), ("Limbus Darkening", "limbus_darkening"),
        ("Limbus Darkening Falloff", "limbus_darkening_falloff"), ("Sclera Brightness", "sclera_brightness"), ("Veins", "veins"),
        ("ScleraRougness", "sclera_roughness"), ("IrisRoughness", "iris_roughness"),
        ("Iris Concavity Scale", "iris_concavity_scale"), ("Iris Concavity Power", "iris_concavity_power"),
        // M_EyeOcclusion
        ("Overall Blur Amount", "overall_blur"), ("Outer Corner Blur Amount", "oc_blur"), ("Outer Corner Blur Falloff", "oc_blur_f"),
        ("Bottom Blur Amount", "bot_blur"), ("Bottom Blur Falloff", "bot_blur_f"), ("Perimeter Blur Amount", "perim_blur"),
        ("Perimeter Blur Falloff", "perim_blur_f"), ("Tearduct Blur Amount", "tear_blur"), ("Tearduct Blur Centre", "tear_c"),
        ("Tearduct Blur Falloff", "tear_f"), ("Outer Corner Occlusion Amount", "oc_occ"), ("Outer Corner Occlusion Falloff", "oc_occ_f"),
        ("Inner Corner Occlusion Amount", "ic_occ"), ("Inner Corner Occlusion Falloff", "ic_occ_f"),
        ("Top Occlusion Amount", "top_occ"), ("Top Occlusion Falloff", "top_occ_f"), ("Bottom Occlusion Amount", "bot_occ"),
        ("Bottom Occlusion Falloff", "bot_occ_f"), ("Overall Occlusion Amount", "overall_occ"),
    ] {
        if let Some(v) = scalar(k) {
            mat.set_shader_parameter(u, &v.to_variant());
        }
    }
    for (k, u) in [("Blood Colour", "blood_colour"), ("06 - Bruise Colour Tint", "bruise_tint"), ("inner Colour Tint", "inner_tint"),
                   ("Occlusion Colour", "occ_colour")] {
        if let Some(v) = vector(k).filter(|v| v.len() >= 3) {
            mat.set_shader_parameter(u, &Vector3::new(v[0], v[1], v[2]).to_variant());
        }
    }
    if let Some(v) = vector("BloodMapUVOffset").filter(|v| v.len() >= 2) {
        mat.set_shader_parameter("blood_uv_offset", &Vector2::new(v[0], v[1]).to_variant());
    }
    for (k, u, flag) in [
        ("Inner Diffuse Colour Map", "inner_tex", Some("has_inner")), ("Inner Normal Map", "inner_normal_tex", None),
        ("Wound Gradient Map", "gore_gradient", None), ("Blood Drip Map", "drips_tex", None),
        ("const T_FabricSplatterDetail_A", "fabric_detail", Some("has_fabric_detail")),
        ("const T_SkinBloodSplatterDetail_ReduceNoise_N", "blood_n", Some("has_blood_n")),
        ("const TV_Global3dNoise", "noise3d", Some("has_noise3d")),
        ("IrisColor", "iris_tex", Some("has_iris")), ("NormalMap", "eye_wet_n", Some("has_eye_wet_n")),
        ("const T_Eye_N", "eye_dir_n", Some("has_eye_dir_n")),
        ("const T_EyeMidPlaneDisplacement_Example", "midplane", Some("has_midplane")),
        ("const T_Eye_O", "eye_o", Some("has_eye_o")),
    ] {
        if let Some(t) = texture(k).and_then(|n| flesh_texture(dir, &n)) {
            mat.set_shader_parameter(u, &t.to_variant());
            if let Some(f) = flag {
                mat.set_shader_parameter(f, &true.to_variant());
            }
        }
    }
    // DI2 light-pass inputs (flesh_materials.json "lighting"; tools/shaders/build_flesh_materials.py lighting_block):
    // uniforms by flesh.gdshader name (float / int / bool / [r, g, b]) and textures with their has_* flag.
    if let Some(l) = fm.get("lighting") {
        if let Some(u) = l.get("uniforms").and_then(|v| v.as_object()) {
            for (k, v) in u {
                let var = if let Some(b) = v.as_bool() {
                    b.to_variant()
                } else if v.is_i64() || v.is_u64() {
                    (v.as_i64().unwrap_or(0) as i32).to_variant()
                } else if let Some(f) = v.as_f64() {
                    (f as f32).to_variant()
                } else if let Some(a) = v.as_array().filter(|a| a.len() >= 3) {
                    let c = |i: usize| a[i].as_f64().unwrap_or(0.0) as f32;
                    Vector3::new(c(0), c(1), c(2)).to_variant()
                } else {
                    continue;
                };
                mat.set_shader_parameter(k.as_str(), &var);
            }
        }
        if let Some(t) = l.get("textures").and_then(|v| v.as_object()) {
            for (k, v) in t {
                if let Some(tex) = v.get("texture").and_then(|n| n.as_str()).and_then(|n| flesh_texture(dir, n)) {
                    mat.set_shader_parameter(k.as_str(), &tex.to_variant());
                    if let Some(f) = v.get("flag").and_then(|f| f.as_str()) {
                        mat.set_shader_parameter(f, &true.to_variant());
                    }
                }
            }
        }
    }
}

/// M_Skin's "Inner Diffuse Colour Map" / "Inner Normal Map" are the textures of the body part's interior shell
/// (MMI_WalkerMaleUpper -> T_RunnerMaleUpperIntA_D / _N, recon/SHADERS_FLESH.md §5.1): the muscle-layer
/// section of the same part (Upper / Lower / Head).
fn set_inner_maps(mat: &mut Gd<ShaderMaterial>, name: &str, manifest: &serde_json::Map<String, serde_json::Value>, dir: &str) {
    let Some(part) = ["Upper", "Lower", "Head", "Arm", "Leg", "Hand"].into_iter().find(|p| name.contains(p)) else { return };
    let Some(inner) = manifest.iter().find(|(k, v)| v.get("layer").and_then(|l| l.as_str()) == Some("muscle") && k.contains(part)).map(|(_, v)| v) else { return };
    for (slot, param) in [("albedo", "inner_tex"), ("normal", "inner_normal_tex")] {
        if let Some(rel) = inner.get(slot).and_then(|v| v.as_str()) {
            if let Ok(tex) = try_load::<Texture2D>(&format!("{dir}/{rel}")) {
                mat.set_shader_parameter(param, &tex.to_variant());
            }
        }
    }
    mat.set_shader_parameter("has_inner", &true.to_variant());
}

/// DI2's base-pass vertex shader sinks skin before skinning: `P = Position + Deform.xyz * depth`. Done here on the
/// body's own copy of the mesh: the surface's bind-pose positions are rewritten in its vertex buffer.
/// Rewrites a section's vertex positions to P + Deform * depth. `cache` keeps the section's vertex buffer and
/// stride after the first read, so later sinks only patch positions and upload (no RenderingServer readback).
/// Only the vertex range `range` [lo, hi) is rewritten and uploaded when the buffer is already cached (the whole
/// section on the first sink, after a mesh rebuild, or for an empty range).
fn sink_vertices(mi: &mut Gd<MeshInstance3D>, own: &mut bool, surface: usize, c: &SurfaceCpu, depth: &[f32], cache: &mut Option<(usize, Vec<u8>)>, range: (usize, usize)) {
    let Some(mesh) = mi.get_mesh() else { return };
    let mesh = if *own {
        mesh
    } else {
        let Ok(copy) = mesh.duplicate_resource().try_cast::<Mesh>() else { return };
        mi.set_mesh(&copy);
        // Materials are per-instance overrides, so they survive the swap.
        *own = true;
        copy
    };
    let mut rs = godot::classes::RenderingServer::singleton();
    let rid = mesh.get_rid();
    let n = c.verts.len();
    let mut full = range.0 >= range.1 || range.1 > n;
    if cache.is_none() {
        full = true;
        let sd = rs.mesh_get_surface(rid, surface as i32);
        let Some(fmt) = sd.get("format").and_then(|v| v.try_to::<i64>().ok()) else { return };
        let Some(data) = sd.get("vertex_data").and_then(|v| v.try_to::<PackedByteArray>().ok()) else { return };
        let stride = rs.mesh_surface_get_format_vertex_stride(godot::classes::rendering_server::ArrayFormat::from_ord(fmt as u64), n as i32) as usize;
        if stride < 12 || data.len() < stride * n {
            return;
        }
        *cache = Some((stride, data.as_slice().to_vec()));
    }
    let Some((stride, buf)) = cache.as_mut() else { return };
    let stride = *stride;
    let (lo, hi) = if full { (0, n) } else { range };
    for i in lo..hi {
        let p = c.verts[i] + c.deform[i] * depth[i];
        let o = i * stride;
        buf[o..o + 4].copy_from_slice(&p.x.to_le_bytes());
        buf[o + 4..o + 8].copy_from_slice(&p.y.to_le_bytes());
        buf[o + 8..o + 12].copy_from_slice(&p.z.to_le_bytes());
    }
    rs.mesh_surface_update_vertex_region(rid, surface as i32, (lo * stride) as i32, &PackedByteArray::from(&buf[lo * stride..hi * stride]));
}

/// DI2 deform vectors for a mesh's surfaces: `path` holds float32 xyz per vertex, surfaces back to back in order.
/// Returns empty vectors (not decoded) when the file is missing or its size doesn't match the mesh.
/// Cooked starting depth per surface from the deform stream's .json ("primitives"[i].initial_depth, glb order);
/// 0 where unknown or where the vertex count doesn't match.
fn load_initial_depth(bin_path: &str, mesh: &Gd<ArrayMesh>) -> Vec<f32> {
    let path = bin_path.trim_end_matches(".bin").to_string() + ".json";
    let n = mesh.get_surface_count() as usize;
    let Some(j) = read_text(&path).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()) else { return vec![0.0; n] };
    let prims = j["primitives"].as_array().cloned().unwrap_or_default();
    (0..n)
        .map(|s| {
            prims.get(s)
                .filter(|p| p["vertex_count"].as_i64() == Some(mesh.surface_get_array_len(s as i32) as i64))
                .and_then(|p| p["initial_depth"].as_f64())
                .unwrap_or(0.0) as f32
        })
        .collect()
}

struct SubsectionEntry {
    names: Vec<String>,
    /// Subsection per imported (Godot-order) vertex.
    vertex_sub: Vec<u16>,
    initially_hidden: bool,
}

/// The subsections of `glb`'s primitives (tools/build_subsections.py), remapped to the imported vertex order by
/// bit-exact position (Godot reorders vertices; positions survive import exactly).
fn load_subsections(path: &str, glb: &str, mesh: &Gd<ArrayMesh>) -> Vec<Option<SubsectionEntry>> {
    let n = mesh.get_surface_count() as usize;
    let none = || (0..n).map(|_| None).collect();
    if path.is_empty() {
        return none();
    }
    let Some(j) = read_text(path).and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok()) else { return none() };
    let Some(entries) = j.get(glb).and_then(|v| v.as_array()) else { return none() };
    let Some(pos) = glb_positions(glb) else { return none() };
    let mut out: Vec<Option<SubsectionEntry>> = none();
    for e in entries {
        let Some(prim) = e["primitive"].as_u64().map(|p| p as usize) else { continue };
        if prim >= n || prim >= pos.len() {
            continue;
        }
        let ids: Vec<u16> = e["vertex_sub"].as_array().map(|a| a.iter().map(|v| v.as_u64().unwrap_or(0) as u16).collect()).unwrap_or_default();
        if ids.len() != pos[prim].len() {
            continue;
        }
        let by_pos: HashMap<[u32; 3], u16> = pos[prim].iter().zip(&ids).map(|(p, id)| ([p[0].to_bits(), p[1].to_bits(), p[2].to_bits()], *id)).collect();
        let arrays = mesh.surface_get_arrays(prim as i32);
        let verts: PackedVector3Array = arrays.at(ArrayType::VERTEX.ord() as usize).try_to().unwrap_or_default();
        let vertex_sub = verts.as_slice().iter().map(|v| by_pos.get(&[v.x.to_bits(), v.y.to_bits(), v.z.to_bits()]).copied().unwrap_or(0)).collect();
        let names = e["names"].as_array().map(|a| a.iter().map(|v| v.as_str().unwrap_or("").to_string()).collect()).unwrap_or_default();
        out[prim] = Some(SubsectionEntry { names, vertex_sub, initially_hidden: e["initially_hidden"].as_bool().unwrap_or(false) });
    }
    out
}

/// Per surface: whether the mesh's InitiallyHiddenMask holds its UE material slot (deform .json "masks_by_material_slot"
/// and "primitives"[i].ue_material_index, glb order).
fn load_initially_hidden(bin_path: &str, mesh: &Gd<ArrayMesh>) -> Vec<bool> {
    let path = bin_path.trim_end_matches(".bin").to_string() + ".json";
    let n = mesh.get_surface_count() as usize;
    let Some(j) = read_text(&path).and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok()) else { return vec![false; n] };
    let mask: Vec<i64> = j["masks_by_material_slot"]["InitiallyHiddenMask"].as_array().map(|a| a.iter().filter_map(|v| v.as_i64()).collect()).unwrap_or_default();
    let prims = j["primitives"].as_array().cloned().unwrap_or_default();
    (0..n)
        .map(|s| {
            prims.get(s)
                .filter(|p| p["vertex_count"].as_i64() == Some(mesh.surface_get_array_len(s as i32) as i64))
                .and_then(|p| p["ue_material_index"].as_i64())
                .is_some_and(|slot| mask.contains(&slot))
        })
        .collect()
}

fn load_deform(path: &str, mesh: &Gd<ArrayMesh>) -> Vec<Vec<Vector3>> {
    if path.is_empty() || !FileAccess::file_exists(path) {
        return Vec::new();
    }
    let Some(mut f) = FileAccess::open(path, ModeFlags::READ) else { return Vec::new() };
    let len = f.get_length() as i64;
    let bytes = f.get_buffer(len);
    let counts: Vec<usize> = (0..mesh.get_surface_count()).map(|s| mesh.surface_get_array_len(s) as usize).collect();
    let total: usize = counts.iter().sum();
    if bytes.len() != total * 12 {
        godot_warn!("GoreBody: {path} has {} bytes, mesh needs {} ({} vertices); deform stream ignored", bytes.len(), total * 12, total);
        return Vec::new();
    }
    let fl: Vec<f32> = bytes.as_slice().chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect();
    // The stream is in glb vertex order; Godot's importer reorders each surface's vertices (same set, same
    // count). Positions survive import bit-exactly and key the deform vector uniquely within a surface
    // (recon/DEFORM_STREAM.md), so remap through the glb's own POSITION accessors.
    let glb_path = path.trim_end_matches(".deform.bin").to_string() + ".glb";
    let Some(glb_pos) = glb_positions(&glb_path) else {
        godot_warn!("GoreBody: can't read positions from {glb_path}; deform stream ignored");
        return Vec::new();
    };
    if glb_pos.len() != counts.len() || glb_pos.iter().zip(&counts).any(|(p, n)| p.len() != *n) {
        godot_warn!("GoreBody: {glb_path} primitives don't match the imported surfaces; deform stream ignored");
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut o = 0;
    let mut missed = 0;
    for (s, n) in counts.iter().enumerate() {
        let mut by_pos: HashMap<[u32; 3], Vector3> = HashMap::with_capacity(*n);
        for (i, p) in glb_pos[s].iter().enumerate() {
            by_pos.insert([p[0].to_bits(), p[1].to_bits(), p[2].to_bits()], Vector3::new(fl[(o + i) * 3], fl[(o + i) * 3 + 1], fl[(o + i) * 3 + 2]));
        }
        let arrays = mesh.surface_get_arrays(s as i32);
        let verts: PackedVector3Array = arrays.at(ArrayType::VERTEX.ord() as usize).try_to().unwrap_or_default();
        out.push(
            verts.as_slice().iter().map(|v| {
                by_pos.get(&[v.x.to_bits(), v.y.to_bits(), v.z.to_bits()]).copied().unwrap_or_else(|| {
                    missed += 1;
                    Vector3::ZERO
                })
            }).collect(),
        );
        o += n;
    }
    if missed > 0 {
        godot_warn!("GoreBody: {missed} vertices of {path} had no matching glb position (deform 0)");
    }
    out
}

/// POSITION of every primitive of a .glb's first mesh, in file order (float32 xyz).
fn glb_positions(path: &str) -> Option<Vec<Vec<[f32; 3]>>> {
    let mut f = FileAccess::open(path, ModeFlags::READ)?;
    let len = f.get_length() as i64;
    let b = f.get_buffer(len);
    let b = b.as_slice();
    let u32_at = |o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as usize;
    if b.len() < 20 || &b[0..4] != b"glTF" {
        return None;
    }
    let jl = u32_at(12);
    let js: serde_json::Value = serde_json::from_slice(&b[20..20 + jl]).ok()?;
    let bin = 20 + jl + 8;
    let mut out = Vec::new();
    for p in js["meshes"][0]["primitives"].as_array()? {
        let a = &js["accessors"][p["attributes"]["POSITION"].as_u64()? as usize];
        let v = &js["bufferViews"][a["bufferView"].as_u64()? as usize];
        let start = bin + v["byteOffset"].as_u64().unwrap_or(0) as usize + a["byteOffset"].as_u64().unwrap_or(0) as usize;
        let stride = v["byteStride"].as_u64().unwrap_or(12) as usize;
        let n = a["count"].as_u64()? as usize;
        let f32_at = |o: usize| f32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
        out.push((0..n).map(|i| {
            let o = start + i * stride;
            [f32_at(o), f32_at(o + 4), f32_at(o + 8)]
        }).collect());
    }
    Some(out)
}

fn dict(pairs: &[(&str, Variant)]) -> VarDictionary {
    let mut d = VarDictionary::new();
    for (k, v) in pairs {
        d.set(&k.to_variant(), v);
    }
    d
}

fn find_skeleton(root: &Gd<Node>) -> Option<Gd<Skeleton3D>> {
    let mut stack = vec![root.clone()];
    while let Some(n) = stack.pop() {
        if let Ok(s) = n.clone().try_cast::<Skeleton3D>() {
            return Some(s);
        }
        stack.extend(n.get_children().iter_shared());
    }
    None
}

/// CUSTOM0..3 as RGBA float channels.
fn custom_flags() -> u64 {
    const RGBA_FLOAT: u64 = 7;
    (RGBA_FLOAT << ArrayFormat::CUSTOM0_SHIFT.ord())
        | (RGBA_FLOAT << ArrayFormat::CUSTOM1_SHIFT.ord())
        | (RGBA_FLOAT << ArrayFormat::CUSTOM2_SHIFT.ord())
        | (RGBA_FLOAT << ArrayFormat::CUSTOM3_SHIFT.ord())
}

fn cap_mesh(g: &caps::CapGeometry) -> Gd<ArrayMesh> {
    let mut arrays = VarArray::new();
    arrays.resize(ArrayType::MAX.ord() as usize, &Variant::nil());
    let mut put = |t: ArrayType, v: Variant| arrays.set(t.ord() as usize, &v);
    put(ArrayType::VERTEX, PackedVector3Array::from(g.verts.as_slice()).to_variant());
    put(ArrayType::NORMAL, PackedVector3Array::from(g.normals.as_slice()).to_variant());
    put(ArrayType::TANGENT, PackedFloat32Array::from(g.tangents.as_slice()).to_variant());
    put(ArrayType::TEX_UV, PackedVector2Array::from(g.uv.as_slice()).to_variant());
    put(ArrayType::TEX_UV2, PackedVector2Array::from(g.uv2.as_slice()).to_variant());
    put(ArrayType::BONES, PackedInt32Array::from(g.bones.as_slice()).to_variant());
    put(ArrayType::WEIGHTS, PackedFloat32Array::from(g.weights.as_slice()).to_variant());
    for (k, t) in [ArrayType::CUSTOM0, ArrayType::CUSTOM1, ArrayType::CUSTOM2, ArrayType::CUSTOM3].into_iter().enumerate() {
        put(t, PackedFloat32Array::from(g.custom[k].as_slice()).to_variant());
    }
    put(ArrayType::INDEX, PackedInt32Array::from(g.indices.as_slice()).to_variant());
    let mut m = ArrayMesh::new_gd();
    m.add_surface_from_arrays_ex(PrimitiveType::TRIANGLES, &arrays).flags(ArrayFormat::from_ord(custom_flags())).done();
    m
}

/// Adds a cap mesh under `skel`, skinned like the body mesh `like`.
fn spawn_cap(skel: &mut Gd<Node>, mesh: &Gd<ArrayMesh>, skin: &Gd<Skin>, like: &Gd<MeshInstance3D>, mat: &Gd<ShaderMaterial>, bone: &GString) {
    let mut mi = MeshInstance3D::new_alloc();
    mi.set_name(&format!("Cap_{bone}"));
    mi.set_mesh(&mesh.clone().upcast::<Mesh>());
    mi.set_skin(skin);
    mi.set_layer_mask(like.get_layer_mask());
    mi.set_surface_override_material(0, &mat.clone().upcast::<Material>());
    skel.add_child(&mi);
    mi.set_skeleton_path(&NodePath::from(".."));
}

fn collect_meshes(root: &Gd<Node>) -> Vec<Gd<MeshInstance3D>> {
    let mut out = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(n) = stack.pop() {
        if let Ok(mi) = n.clone().try_cast::<MeshInstance3D>() {
            out.push(mi);
        }
        for c in n.get_children().iter_shared() {
            stack.push(c);
        }
    }
    out
}

/// Copies `src` adding CUSTOM0 (bind-pose position) and CUSTOM1..3 (weight inside each cut slot subtree).
/// Also returns the CPU copy cut caps are built from.
fn bake(src: &Gd<ArrayMesh>, bind_bits: &[u32], deform_for: &[Vec<Vector3>], initial_depth: &[f32], sub_ids: &[Vec<u16>]) -> (Gd<ArrayMesh>, MeshCpu) {
    let custom_flags = custom_flags();
    let mut out = ArrayMesh::new_gd();
    let mut cpu = Vec::new();
    for s in 0..src.get_surface_count() {
        let mut arrays = src.surface_get_arrays(s);
        let verts: PackedVector3Array = arrays.at(ArrayType::VERTEX.ord() as usize).try_to().unwrap_or_default();
        let normals: PackedVector3Array = arrays.at(ArrayType::NORMAL.ord() as usize).try_to().unwrap_or_default();
        let n = verts.len();
        let bones: PackedInt32Array = arrays.at(ArrayType::BONES.ord() as usize).try_to().unwrap_or_default();
        let weights: PackedFloat32Array = arrays.at(ArrayType::WEIGHTS.ord() as usize).try_to().unwrap_or_default();
        let per = if n > 0 { bones.len() / n } else { 0 };
        let (bs, ws) = (bones.as_slice(), weights.as_slice());

        let mut c0 = Vec::with_capacity(n * 4);
        let mut slot_w = vec![[0f32; SLOTS]; n];
        for (i, v) in verts.as_slice().iter().enumerate() {
            c0.extend_from_slice(&[v.x, v.y, v.z, 0.0]);
            for j in 0..per {
                let (b, w) = (bs[i * per + j], ws[i * per + j]);
                if w <= 0.0 || b < 0 {
                    continue;
                }
                let bits = bind_bits.get(b as usize).copied().unwrap_or(0);
                for (k, sw) in slot_w[i].iter_mut().enumerate() {
                    if bits & (1 << k) != 0 {
                        *sw += w;
                    }
                }
            }
        }
        let chan = |off: usize| -> PackedFloat32Array { slot_w.iter().flat_map(|w| w[off..off + 4].iter().copied()).collect() };
        arrays.set(ArrayType::CUSTOM0.ord() as usize, &PackedFloat32Array::from(c0.as_slice()).to_variant());
        arrays.set(ArrayType::CUSTOM1.ord() as usize, &chan(0).to_variant());
        arrays.set(ArrayType::CUSTOM2.ord() as usize, &chan(4).to_variant());
        arrays.set(ArrayType::CUSTOM3.ord() as usize, &chan(8).to_variant());

        let deform = deform_for.get(s as usize).filter(|d| d.len() == n).cloned().unwrap_or_default();
        for (i, d) in deform.iter().enumerate() {
            c0[i * 4 + 3] = (d.length() * 100.0).min(255.0); // CUSTOM0.w: deform length in cm (DI2 normalises wounds by it)
        }
        // + DI2 subsection id x 256 (flesh.gdshader collapses hidden subsections).
        if let Some(ids) = sub_ids.get(s as usize).filter(|v| v.len() == n) {
            for (i, id) in ids.iter().enumerate() {
                c0[i * 4 + 3] += *id as f32 * 256.0;
            }
        }
        arrays.set(ArrayType::CUSTOM0.ord() as usize, &PackedFloat32Array::from(c0.as_slice()).to_variant());
        // DI2 draws a section at P + Deform * depth from its cooked starting depth: the IntA interior shells start at
        // 1.0, i.e. on the tip of their skin twin's deform vector (recon/DEFORM_STREAM.md). CUSTOM0 keeps P, the
        // twin's position, so the shell reads the same splatter values its skin does (DI2 shares UV-space targets).
        let init = initial_depth.get(s as usize).copied().unwrap_or(0.0);
        if init != 0.0 && !deform.is_empty() {
            let moved: PackedVector3Array = verts.as_slice().iter().zip(&deform).map(|(v, d)| *v + *d * init).collect();
            arrays.set(ArrayType::VERTEX.ord() as usize, &moved.to_variant());
        }
        let fmt = src.surface_get_format(s).ord();
        let keep = fmt & ArrayFormat::FLAG_USE_8_BONE_WEIGHTS.ord();
        out.add_surface_from_arrays_ex(PrimitiveType::TRIANGLES, &arrays)
            .flags(ArrayFormat::from_ord(keep | custom_flags))
            .done();
        let idx = out.get_surface_count() - 1;
        out.surface_set_name(idx, &src.surface_get_name(s));
        if let Some(m) = src.surface_get_material(s) {
            out.surface_set_material(idx, &m);
        }
        let indices: PackedInt32Array = arrays.at(ArrayType::INDEX.ord() as usize).try_to().unwrap_or_default();
        let indices = if indices.is_empty() { (0..n as i32).collect() } else { indices.as_slice().to_vec() };
        let normals = if normals.len() == n { normals.as_slice().to_vec() } else { vec![Vector3::ZERO; n] };
        let uv0: PackedVector2Array = arrays.at(ArrayType::TEX_UV.ord() as usize).try_to().unwrap_or_default();
        let uv = if uv0.len() == n { uv0.as_slice().iter().map(|t| [t.x, t.y]).collect() } else { Vec::new() };
        cpu.push(SurfaceCpu { verts: verts.as_slice().to_vec(), normals, deform, bones: bs.to_vec(), weights: ws.to_vec(), per, slot_w, indices, uv, texmap: Default::default() });
    }
    (out, cpu)
}

/// A stamp texture layer's RGBA (0..1) at (u, v): bilinear, clamp to edge (FSplatterPS `t0/t1.Sample`).
fn bilinear(px: &[(i32, i32, Vec<u8>)], tex: i32, u: f32, v: f32) -> [f32; 4] {
    let Some((w, h, p)) = px.get(tex as usize) else { return [0.0; 4] };
    if *w <= 0 || p.is_empty() {
        return [0.0; 4];
    }
    let (w, h) = (*w as usize, *h as usize);
    let fx = (u * w as f32 - 0.5).clamp(0.0, (w - 1) as f32);
    let fy = (v * h as f32 - 0.5).clamp(0.0, (h - 1) as f32);
    let (x0, y0) = (fx.floor() as usize, fy.floor() as usize);
    let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
    let (tx, ty) = (fx - x0 as f32, fy - y0 as f32);
    let at = |x: usize, y: usize, c: usize| p[(y * w + x) * 4 + c] as f32 / 255.0;
    let mut out = [0.0; 4];
    for (c, o) in out.iter_mut().enumerate() {
        let a = at(x0, y0, c) * (1.0 - tx) + at(x1, y0, c) * tx;
        let b = at(x0, y1, c) * (1.0 - tx) + at(x1, y1, c) * tx;
        *o = a * (1.0 - ty) + b * ty;
    }
    out
}

/// Which section's splatter targets each section samples: skin / cloth their own (UV0); an interior shell its skin
/// twin's (the shell is a copy of the skin's vertices, UVs included); eyes, the eye overlay and hair the head's at
/// UV1 (their UV1 lands in the head section's UV0, recon/SHADERS_FLESH.md §7.1).
fn splatter_sources(names: &[String], layers: &[i32]) -> Vec<Option<(usize, bool)>> {
    const PARTS: [&str; 7] = ["Upper", "Lower", "Head", "Body", "Arm", "Leg", "Hand"];
    let skin = |part: &str| (0..names.len()).find(|&i| layers[i] == 0 && names[i].contains(part));
    let head = skin("Head");
    (0..names.len())
        .map(|i| match layers[i] {
            0 | 1 => Some((i, false)),
            2 => PARTS.iter().find(|p| names[i].contains(*p)).and_then(|p| skin(p)).map(|t| (t, false)),
            5 | 6 | 9 => head.map(|h| (h, true)),
            _ => None,
        })
        .collect()
}

/// A copy of `src` (an ArrayMesh) with each surface's arrays passed through `edit` first (formats, names and
/// materials carry over).
fn rebuild_mesh_with(src: &Gd<Mesh>, edit: impl Fn(usize, &mut VarArray)) -> Option<Gd<ArrayMesh>> {
    let src = src.clone().try_cast::<ArrayMesh>().ok()?;
    let custom = custom_flags();
    let mut out = ArrayMesh::new_gd();
    for s in 0..src.get_surface_count() {
        let mut arrays = src.surface_get_arrays(s);
        edit(s as usize, &mut arrays);
        let fmt = src.surface_get_format(s).ord();
        let keep = fmt & ArrayFormat::FLAG_USE_8_BONE_WEIGHTS.ord();
        out.add_surface_from_arrays_ex(PrimitiveType::TRIANGLES, &arrays).flags(ArrayFormat::from_ord(keep | custom)).done();
        out.surface_set_name(s, &src.surface_get_name(s));
        if let Some(m) = src.surface_get_material(s) {
            out.surface_set_material(s, &m);
        }
    }
    Some(out)
}

/// A copy of `src` (an ArrayMesh) with some surfaces' index buffers replaced (an empty list keeps one degenerate
/// triangle: Godot rejects empty surfaces). Formats, names and materials carry over.
fn rebuild_mesh(src: &Gd<Mesh>, replace: &HashMap<usize, Vec<i32>>) -> Option<Gd<ArrayMesh>> {
    let src = src.clone().try_cast::<ArrayMesh>().ok()?;
    let custom = custom_flags();
    let mut out = ArrayMesh::new_gd();
    for s in 0..src.get_surface_count() {
        let mut arrays = src.surface_get_arrays(s);
        if let Some(idx) = replace.get(&(s as usize)) {
            let idx = if idx.is_empty() { vec![0, 0, 0] } else { idx.clone() };
            arrays.set(ArrayType::INDEX.ord() as usize, &PackedInt32Array::from(idx.as_slice()).to_variant());
        }
        let fmt = src.surface_get_format(s).ord();
        let keep = fmt & ArrayFormat::FLAG_USE_8_BONE_WEIGHTS.ord();
        out.add_surface_from_arrays_ex(PrimitiveType::TRIANGLES, &arrays).flags(ArrayFormat::from_ord(keep | custom)).done();
        out.surface_set_name(s, &src.surface_get_name(s));
        if let Some(m) = src.surface_get_material(s) {
            out.surface_set_material(s, &m);
        }
    }
    Some(out)
}

/// Re-export for hosts embedding gore-core math.
pub use gore_core::glam;
