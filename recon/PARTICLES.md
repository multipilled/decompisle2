# DI2 hit particle effects — Godot port

## Hand-off (2026-10-08, particle visuals session)

**Done this session** (commits 7abf0e5 .. on main):
- particles.json rebuilt with `--fetch`: 790 CEs, 334 systems, now with PS_Extinguished_Fire and PS_Drips_Acid / Petrol /
  Water. Materials carry `vertex_factories` (the shader map's base-pass VFs, `shader_map_vfs` in the builder).
- **Burning petrol** (CE_Fluid_State_Flammable → PS_Burning_Liquid, CE_Extinguished_Fire): PSM_Fire_OpacityMask
  (`di2_particle_fire_mask`, PS 6901 / GPU 6894: fuel-blue base, BlackBody flames) and PSM_Whitewater_Foam
  (`di2_particle_foam`, VS 12355 / PS 12356) transcribed. The black squares were the generic fallback plus its
  `fire_light` emitter drawn as a sprite: emitters with `ERM_LightsOnly` (92 in the data) now draw only their lights.
- New transcriptions (table in §4.3): PSM_FireDebris, PSM_Translucent_Bubbles, PSM_Explosion_AlphaComposite (molotov,
  pipe bomb, muzzle MIs), PSM_Liquid_FluidSprite (blunt blood sheets), PSM_Houdini_VertexAnimated_Fluid_Translucent,
  PSM_Debris on GPU sprites (PS 11865, `di2_particle_debris_sprite`), PSM_Linear_AlphaComp_Lit's UseSelectChannel
  (PS 12268).
- Emitters whose material has no base pass for their vertex factory (PSMI_SmokeTrail on GPU sprites: 9 explosions;
  MI_AirlinerJetEngineDebrisA_01 on meshes) draw nothing (`di2_particle_hidden`); UE would use the engine default
  material (UNVERIFIED 63).
- Drip decals take game/data/fluids.json `compose` (colours by the MI's Fluid Type with FFluidComposePS's selector,
  level_colors for Fuel / FuelEdge, FluidDensity / FluidRoughness / specular / sharpen); UE specular → Godot sqrt(S/2).
- Captures (`game/test_out/particles`): new floor entries burning_petrol, extinguished_fire, acid_lingering,
  bullet_acid_world, molotov, pipe_bomb (4th element floor, 5th camera scale, 6th PS instance params; floor runs use
  2× times, 0.067–3 s). Fluid effects need the transmitter's params (Radius = VisualRadiusMultiplier × R, Opacity).

**Open items, in priority order.**
1. Weak captures: acid_lingering shows 4-5 bubbles that are near-invisible. PS 12574's opacity peaks at
   0.25 x fresnel (the (1 - f) f depth term, f = sat(D / 24 cm)), so this may be DI2's own subtle look. Compare with a
   reference before changing it. blunt_fire's FireDebris flakes are small (50 BlackDebris). bullet_acid_world's VAT
   splash renders (green, ~0.5 s).
2. Exposure: HDR emissives (FireDebris Color1 25000, BlackBody fire / foam, FuelColor (0, 20, 800)) assume
   PreExposure / View[152].y = 1 and read hot-white in the daylight arena. DI2's exposure value is the open item
   (UNVERIFIED 63 a): RE the View[152].y writer, then scale every emissive transcription the same way.
3. ERM_Point emitters (31) still draw as sprites. UE 4.27 may draw points only in the editor: verify in the exe
   before changing.
4. Remaining fallback masters: `python tools/particles/fallbacks.py` (M_WeaponStatic 32, CrownSmoke 27, LightningMesh 26,
   Debris_Translucent 20, M_Vertex_Animation 14, DustPoint 11, …). PSM_LightningMesh is read: PS 10148 (mesh) frame =
   floor-pick (dyn.w·Columns + dyn.z) over Columns × Rows, m = sat(lerp(lerp(t.r, t.g, sat(vertex r) + dyn.x), t.b,
   dyn.y) − Balance), colour = (particle rgba·m)^(Colour_Contrast + ContactAmount·(1 − sat(D/ContactDistance))) ×
   lerp(Multy, MultyFar, sat(dist/DistanceCompensation)²), emissive × lerp(B, D)·4.7e-5 / X, opacity sat((a·m)^OC·OS·dc);
   VS 10129 adds UE's simplex Vector Noise of (world/Scale + WorldSpeed·t) × WorldDisplacement × (1 − UV.x) and the
   Displacement Noise texture × DispalcementAmount × sat(2(1 − UV.x)). The simplex noise is the long part.
5. Exact GPU simulation in Rust; `Emitter::gpu_update` is still the drag + acceleration approximation. Traced so far:
   - The shader: Global 587 / 590, see §4 notes in the session's shared hand-over.
   - Fixed step: exe 0x14393bd50 (dynamic-data builder) uses r.GPUParticle.FixDeltaSeconds 1/30, FixTolerance 0.1 and
     MaxNumIterations 3. DI2's config doesn't override them.
   - Per frame: n = floor(Var/Fix), and the remainder is carried in OffsetSeconds. Emitters with bUseFixDT run n fixed
     iterations persistently and draw a non-persistent leftover step. Evidence: the dispatch 0x14392b3e0 reads
     Prev→Cur for the fixed pass and Cur→Prev for the leftover pass, the visualize pass reads Prev (0x14393ce90), and
     a per-frame swap happens at 0x143932c70.
   - Vector fields: VolumeToWorld = Rot(LocalVectorFieldRotation)·LVF.Transform·ComponentToWorld (0x14393bd50). The
     local field is passed with intensity scale 1 and tightness −1 (keep the instance's), up to 4 fields
     (0x14394a110). The bounds scale/offset follows UE 4.27 FVectorFieldInstance::UpdateTransforms (not decompiled).
   - The GPU spawn path (FGPUSpriteParticleEmitterInstance::Tick / BuildNewParticles) is not RE'd yet.
   - The InitialAttributes texture format (8-bit quantisation?) and the VF sampler address mode are UNVERIFIED.
   - CollisionGPU (PS 590) runs on 111 emitters; port it with physics rays.
6. Ribbons (P3; dropped for now) (TypeDataRibbon / TrailSource), the distortion/refraction pass, LocationBoneSocket, InheritPlayerVelocity.
7. Particle lights: the Light module and the pool work (fire_light lights the test capsule). Brightness against
   Godot's lighting is the same exposure question as item 2.

**Files owned (particles):** game/scripts/di2_particles.gd, di2_particle_materials.gd, autotest_particles.gd;
game/shaders/di2_particle_*; tools/build_particles.py, tools/particles/*; game/data/particles.json (git-ignored);
rust/gore-godot/src/particles/*; recon/PARTICLES.md.

**Test.** Rebuild data: `tools/with_cpu.sh <you> python -u tools/build_particles.py --no-assets < /dev/null` (~2 min;
`--fetch` exports missing dumps). Captures: `tools/with_cpu.sh <you> tools/with_lock.sh <you> tools/run_test.sh
--particletest=game/test_out/particles [--only=<label>]` (`--only` overwrites particles.log). Regression:
`TEST_OUT=game/test_out/particles_flesh tools/run_all_tests.sh flesh` — **never wrap run_all_tests.sh in
with_lock.sh**: it takes the lock per suite and deadlocks until the 40-minute stale reclaim.
Gotchas: `python $UNSET_VAR` waits on stdin forever; give one-off Python `< /dev/null`. Shader decompiles:
`matshaders.py <MI|root master> list`, then `<VF> <type> <label>`; inline maps need the root master's name.

Port of the Cascade particle systems that Dead Island 2's zombie-hit cosmetic effects (`CE_*`) play: blood spray,
mist and dust, VAT blood splashes, droplets, drips and their environment decals, viscera/bone bits, and the elemental
impacts (fire, shock, acid, bleed). Everything is driven by DI2's own cooked data; the simulation follows DI2's exe and
the materials are transcriptions of DI2's decompiled shaders. This page lists the format, where every value comes
from, and what is approximated or UNVERIFIED (§5).

DI2 is UE 4.27 and uses **Cascade only** for these effects (no Niagara system is reachable from the hit CEs).

## 1. Files

| File | What |
|---|---|
| `tools/build_particles.py` | Builds `game/data/particles.json` and the textures/meshes in `game/assets/di2/particles/` (`--fetch` dumps missing assets with di2x, `--no-assets` keeps the previous texture/mesh tables) |
| `game/data/particles.json` | The data (§3) |
| `game/assets/di2/particles/tex/*.dds|.vatpos|.vatnrm|.vol`, `mesh/*.pmesh` | Cooked texture mips and particle meshes (`.gdignore`d, loaded at runtime) |
| `game/scripts/di2_particles.gd` | `class_name DI2Particles`: the runtime node (one node = one ParticleSystemComponent): data lookup, renderers, lights, and the GDScript reference simulation |
| `rust/gore-godot/src/particles/` | `DI2ParticleSim` (GDExtension class): the same simulation in Rust, used when `DI2Particles.use_rust` (default) — §4.6 |
| `game/scripts/di2_particle_materials.gd` | `class_name DI2ParticleMaterials`: DI2 material instance → Godot ShaderMaterial |
| `game/shaders/di2_particle_*.gdshader`, `di2_particle_translucent.gdshaderinc`, `di2_particle_twosided.gdshaderinc` | Transcribed DI2 particle materials (§4.3) |
| `game/scripts/autotest_particles.gd` | `--particletest=<dir>` capture test (§6) |
| `tools/particles/` | RE aids: `matshaders.py` (list/decompile a material's shaders), `inline_map.py` (shader list of a root material whose shader map is inline in its package), `global_find.py` (global shaders by type), `uclass_vtable.py`, `module_funcs.py`, `props.py`, `decomp.sh` + `ParticlesDecompileAt.java` (Ghidra), `annotate_p.py` |
| `extracted/particles_build/` | Build intermediates: material dumps, `module_funcs.json`, mip dumps; `extracted/ghidra_particles/*.c` = decompiled exe functions |

## 2. API

```gdscript
DI2Particles.play_ce(parent: Node, ce_name: String, world_pos: Vector3, normal: Vector3, dir: Vector3,
                     factor := -1.0, ps_params := {}, base: Variant = null) -> void
DI2Particles.play_ps(parent: Node, ps: String, xf: Transform3D, attached := false, ps_params := {}) -> DI2Particles
DI2Particles.last_spawned   # Array of the DI2Particles nodes the last play_ce created (nested CEs included)
node.advance(delta) -> bool # one simulation step (the node does this itself in _process; true when finished)
```

- `play_ce` plays every ParticleSystem the CE lists, then its nested CEs (recursively). `normal` = outward surface
  normal at the hit, `dir` = direction the hit travels (attacker → victim), both in Godot world space.
- **Orientation** = DI2's point-impact spawn rotation, traced by the gore session (exe 0x1414810b0,
  recon/RE_FLESH.md "Hit-effect spawn transform", ported as `HitEffectSpawn.point_basis`): q = orient(normal); if
  factor > 0, q = normalize(Slerp_NotNormalized(q, orient(dir), factor)); if factor < 1, re-roll q about its X so
  Y = normalize(dir × X). So factor 0 faces out of the surface and factor 1 along the hit's travel. The CE link's own
  `rot` (FRotator) goes on top. `factor` = the hit tree's `DirectionInterpolationFactor` for this CE (the values
  `hit_effects.json` uses are in `ce[...].factors`; default: 1.0 if listed, else the first). `base` skips this and uses
  the caller's spawn rotation (e.g. `HitEffectSpawn.radial_basis` for explosions: victim root, facing away from the
  origin).
- **Attachment.** A link with `force_not_attached` (DI2 `bForceNotAttached`) spawns in world space (under the current
  scene); the others are children of `parent` and follow it (DI2 attaches to the hit component; pass the zombie, or a
  BoneAttachment3D at the hit bone). `attachment` names DI2's socket when set (only `WeaponZombieAttachment`, 17 links,
  zombie weapon throws). `ps_params` = instance parameters (`{name: value}`) for modules that read them.
- Systems free themselves when complete. Looping systems are cut at 30 s (`LOOPING_LIFETIME_CAP`): **UNVERIFIED**, DI2
  deactivates them natively (not decoded).

## 3. particles.json

Units and axes are DI2's (UE): cm, X forward, Y right, Z up; rotators are `[Pitch, Yaw, Roll]` degrees.

- `ce{CE: {...}}` — every CE reachable from DI2's hit data (`cosmetics.json`, `hit_effects.json`, `viscera_parts.json`)
  and the explosion archetypes' CosmeticEffects (`explosions.json`) that plays particles. Per CE:
  - `ps[]`: one entry per `ParticleSystemData` element: `ps`, `force_not_attached`, `rot` (RotationOffset or null),
    `attachment` (socket or null), `desaturation`, `custom_depth`, `stencil`, `affect_lifetime`, `destroy_persistent`,
    `force_visible`, `remap` (parameter remaps).
  - `fluid[]`: the CE's FluidParticle entries (type, speed, amount, spawn method). Data only (§5, not ported).
  - `nested[]`, `factors[]` (DirectionInterpolationFactor values seen in the hit tree), `params`, `budget`.
- `gradual` — `DA_ContextualGradualDamageEffectList_AI` candidates (MajorCut → PS_Blood_MajorCut, Decapitate →
  PS_Dismemberment_Head, Dismember → PS_Blood_Heavy_Dismemberment, BoneBreak has no PS), with requirements,
  duration, emission period and over-time fluid.
- `ps{PS: {...}}` — 119 systems: `lod_distances`, `lod_method`, `warmup`, `warmup_tick`, `delay*`, `fixed_bounds`,
  `emitters[]`. Per emitter: `name`, `class`, `render`, `legacy_spawn` (UE `bUseLegacySpawningBehavior`),
  `significance`, `detail_mask`, `disabled_lods_keep_alive`, `modules[]` (every module object of the emitter, with
  only the properties DI2 cooked, merged over the class defaults below) and `lods[]` (`level`, `enabled`, `required`,
  `spawn`, `type`, `events`, `modules` = indices into `modules[]`, `peak` = cooked PeakActiveParticles).
  - Module `m` = class without `UParticleModule`. Distributions: `{"op", "lock", "n", "s", "ss", "ts", "tb", "v"}` =
    UE's cooked `FRawDistribution` lookup table (op 1 none / 2 random / 3 extreme; lock 1 XY / 2 XZ / 3 YZ / 4 XYZ;
    entry count, stride, sub-entry stride, TimeScale, TimeBias, values). Uncooked distributions keep their curves
    (`FInterpCurve` points).
  - Class defaults that DI2 doesn't serialize come from UE 4.27; the Required defaults and VelocityCone's
    `Direction (0, 0, 1)` were checked in DI2's exe constructors.
- `materials{MI: {...}}` — `chain` (MI → parent → … → root), `root`, `base` (blend mode, shading model, lighting mode,
  two-sided, decal settings, …), `scalars`, `vectors`, `textures`, `switches` (MI overrides over the compiled shader
  map's uniform defaults), `shader_map` (resource hash, `inline:<root>` when the root's shader map is inline in its
  package), `referenced_textures` (every texture the compiled shader map samples).
- `textures{name: {...}}` — format, size, sRGB, address, filter, LOD group, compression, cooked mip count, `file`.
  DDS files hold the cooked mips byte for byte; `PF_A2B10G10R10` VAT positions → `.vatpos`, `PF_V8U8` VAT normals →
  `.vatnrm` (float16), volume textures → `.vol` (`"DI2T"`, RGBA/L8 tag, w, h, d, mip 0 slices).
- `meshes{name: {...}}` — `.pmesh` (`"DI2M"`, counts, flags; float32 UE-cm positions, normals, tangents with the
  binormal sign, UV0, UV1, colours; u32 indices in UE winding), `sections` (first, count, material), `bounds_cm`.
- `engine_modules{class: {spawn, update, exe}}` — whether DI2's exe overrides `UParticleModule::Spawn` / `Update` for
  the class, with the constructor, vtable and function addresses (§4.1).

## 4. Where the values come from

### 4.1 Simulation (DI2's exe)

The exe has no RTTI. Classes were found from their `L"U<Class>"` names → `GetPrivateStaticClass` → the
InternalConstructor → constructor → vtable (`tools/particles/uclass_vtable.py`). `UParticleModule` flags byte +0x28:
bit0 spawn, bit1 update, 0x80 enabled; `Spawn` = vtable +0x240, `Update` = +0x248, stub `0x140784e40`. A module runs
at spawn / update only where its class overrides the slot (`engine_modules`). FBaseParticle offsets as UE 4.27
(OldLocation 0x0 … BaseColor 0x70; flags JustSpawned 0x02000000, Freeze 0x04000000, IgnoreCollisions 0x08000000,
FreezeTranslation 0x10000000, FreezeRotation 0x20000000).

Checked against the decompiled exe (addresses DI2 PC build; decompiles in `extracted/ghidra_particles/`):

| What | DI2 function | Notes |
|---|---|---|
| Emitter tick order | `FParticleEmitterInstance::Tick` and helpers | time setup (EmitterTime − delay, restored after the tick, 0x143952490), kill, `ResetParticleParameters` 0x143946520 (does not clear JustSpawned), module updates, spawn (rate + bursts + SpawnPerUnit; legacy vs non-legacy rate accounting), integration 0x143957390 (OldLocation = Location; clears JustSpawned; skips frozen / just-spawned non-legacy) |
| Mesh emitter pre-tick | 0x1439525f0 | rotation payload when MeshRotation/MeshRotationRate is active |
| Mesh particle transform | `CalculateParticleTransform` 0x143965a10 via 0x14397e2f0 | Scale(size) · Rot(MakeFromEuler(r,r,r) + payload rotation) · Translate; local space then LocalToWorld |
| FRotationTranslationMatrix | 0x1409fe120 | `rotator_basis_ue` |
| Lifetime / Location / Sphere / Cylinder / Rotation / RotationRate / MeshRotation(+Rate) / SubUV / CameraOffset / Size / SizeMultiplyLife / SizeScale / SizeScaleBySpeed / Color / ColorOverLife / ColorScaleOverLife / Velocity / VelocityCone / VelocityInheritParent / Acceleration / AccelerationConstant / AccelerationDrag / ParameterDynamic / Collision | see `engine_modules` | e.g. VelocityCone SpawnEx 0x14398da10, Sphere 0x14398c610 + DetermineUnitDirection 0x14396ac70, SubUV DetermineImageIndex 0x143937d90, ParameterDynamic 0x14398d090 / 0x143991d50, AccelerationDrag (no spawn; coefficient sampled per frame at RelativeTime) 0x1439547f0, SizeScale / SizeScaleBySpeed overwrite Size |
| Distribution lookup | `FRawDistribution::GetValue*` | entry = max((t − TimeBias)·TimeScale, 0), i = min(trunc, n−1), j = min(i+1, n−1), lerp by frac; null RandomStream = `FMath::SRand` |

Particle events (`EventGenerator` → `EventReceiverSpawn`) are dispatched within the system (collision / death /
spawn); collision traces go against `Util.WORLD` (DI2: WorldStatic/WorldDynamic).

Also from the exe:
- **Orbit** (`UParticleModuleOrbit`, Spawn 0x14398b500 / Update 0x143991b10, ResetParticleParameters' orbit reset and
  UpdateOrbitData 0x143958ca0 with the Add / Scale / Link chain modes): every Orbit module in DI2's data (16) has
  `bEnabled = false`, so UpdateOrbitData only ever writes a zero offset — nothing to port.
- **Light** (`UParticleModuleLight`, Spawn 0x14394ef60 / Update 0x1439566b0): payload ColorScale =
  BrightnessOverLife(t) × ColorScaleOverLife(t) (updated every frame), RadiusScale(EmitterTime), LightExponent
  (0 when bUseInverseSquaredFalloff), bValid = FRandomStream fraction < SpawnFraction, bAffectsTranslucency,
  bHighQualityLights; gated by `r.ParticleLightQuality` (UE 4.27 default 2; DI2's config doesn't set it). The
  distributions and the SpawnFraction draw use the component's FRandomStream (seed × 196314165 + 907633515), ported
  as its own stream so the main RNG sequence is unchanged. Drawn per UE 4.27 `GatherSimpleLights` (not decompiled):
  colour = particle rgb × alpha × ColorScale, radius = RadiusScale × (Size.x + Size.y) / 2, as pooled OmniLight3Ds
  (`_update_lights`). Inverse-squared lights (UE 1 / (d_cm² + 1)) map to Godot energy colour / 10000 with
  attenuation 2; exponent lights to Godot's range window. Brightness against Godot's lighting is APPROXIMATED.
- **Seeded modules** (`UParticleModule*_Seeded`: Size 73 emitters, Lifetime 23, Rotation 16, Velocity 9; from the
  explosion / weapon systems): the base module evaluated with a per-emitter FRandomStream initialised from
  `RandomSeedInfo.RandomSeeds[0]` (DI2 only uses seed 0), reset on emitter looping (bResetSeedOnEmitterLooping,
  default true) — the same "random" sequence every time the effect plays. Exact in the Rust simulation; the GDScript
  fallback draws them from the system RNG (APPROXIMATED).

### 4.2 Rendering

- One `MultiMeshInstance3D` per emitter (top-level, fixed huge AABB, no shadows). Simulation is in UE space; Godot
  space = UE `(x, z, y) · 0.01`, bases conjugated by that swap.
- **Sprites** are camera-aligned on the CPU with UE's `ParticleSpriteVertexFactory` `GetTangents` (confirmed by the
  decompiled DI2 sprite VS 1249 / 2925): Square / Rectangle, `PSA_Velocity`, `PSA_FacingCameraPosition`,
  `EPAL_ROTATE_X/Y/Z` axis locks, rotation, pivot offset, UV flip by negative size. The instance basis carries
  right·size, down·size and (SubImageIndex, RelativeTime) for the shaders (`skip_vertex_transform`).
- **Mesh particles** use the exe's mesh transform above. Godot front faces are clockwise, so the UE index order is kept
  after the (x, z, y) mirror.
- **GPU sprite emitters** (`TypeDataGpu`) are simulated on the CPU with their spawn modules (EmitterInfo.SpawnModules)
  and the GPU curves (colour, size, sub-image) sampled per particle (§5).
- Sorting per `SortMode`; LOD by camera distance at activation.

### 4.3 Materials (decompiled DI2 shaders)

Each master material that the hit set uses was decompiled from DI2's shader archive (base pass, quality High, the
vertex factory the emitter uses; `tools/particles/matshaders.py`) and transcribed. Instance values come from
`materials` (MI overrides over the shader map's defaults).

| DI2 master | Godot shader | DI2 shaders (archive index) | Notes |
|---|---|---|---|
| PSM_Houdini_VertexAnimated_Fluid | `di2_particle_vat` | VS 1693 / PS 1647; Meat_02 PS 12057 / VS 12066 | Houdini VAT: positions/octahedral normals from `.vatpos`/`.vatnrm` at frame = ceil(Frames·clamp(dyn.z, 0, 1−1/Frames))/Frames; fresnel erosion by dyn.y; masked dither clip 0.3333; TwoSidedFoliage |
| PSM_Dither_Blood_Opaque | `di2_particle_dither` | sprite / GPU PS | mask .a, tiled scrolling normal map, base = sat(Diffuse Reflected Colour) |
| PSM_Dither_Blood_Opaque_MeshFlipbook | `di2_particle_dither_mesh` | PS 11680 | time from RelativeTime (instance custom .w) |
| PSM_Smoke_Transluscent_Lit | `di2_particle_smoke` | PS 11551 / VS 1249; Whispy_Smoke PS 6324 | flipbook from dyn.x with motion vectors, BC5 normals, depth / near fade, contrast, AlphaComposite; `Alpha_Channel` = opacity from the spritesheet's alpha instead of red (PS 6324); no specular (TLM_Volumetric*) |
| PSM_Liquid_Transluscent_Lit | `di2_particle_smoke` | PS 12586 (Acid_Smoke_02) | same flipbook / fades / contrasts as the smoke master, opacity from alpha, TLM_Surface (reflections with Roughness); its WS sphere-mask terms are not transcribed |
| PSM_Liquid_Bits_Simple | `di2_particle_bits` | PS 11162 / 11184, 13983 / 13978 (Brightspot), 12193 (Env_BloodDrop) | c = sat(tex·particle) (Brightspot: × strength; UsesAlphaMask off: a = tex.r·particle a); FlattenNormal |
| PSM_Liquid_Bits_Complex | `di2_particle_bits_complex` | PS 12109 (GPU) | rotating caustic shimmer UV, RNM normal blend, colour = Diffuse Reflected Colour, opacity = droplet .a · particle a, roughness |
| PSM_Linear_AlphaComp_Lit | `di2_particle_linear_alphacomp` | PS 12216, 11331, 6206, 11957 | lightning erode by RelativeTime, colour/opacity contrast, UE BlackBody, UV distort, depth fade; unlit AlphaComposite |
| PSM_BloodDripsEnviro | `di2_particle_drip_decal` | FMeshDecalsPS 1598 (+ global 1856–1858) | mesh decal, §4.5 |
| PSM_ElectricDistortion | `di2_particle_electric_distortion` | PS 2917 (_02, UsesContactOpacity), 12243 (_04) | mask rotated by 2π·dyn.x, noise UV distort, distance compensation (Multy → MultyFar), Power, Colour_Contrast on HDR particle colours, contact fade, exposure-compensated emissive (below) |
| PSM_Fire_AlphaComposite | `di2_particle_fire` | PS 6748 (Fire_02), 12292 (Flames_Whispy, UsesContactOpacity) | motion-vector flipbook, UE BlackBody of T = sat(depth / PreBlackbody_DepthFade)·contrasted red·dyn.y, Emissive_Add, depth fade, contact fade, exposure-compensated emissive. Fire_Burst_01 (PS 7564: Normals / Refraction) and GroundFlames (PS 10019: WorldHeight_Falloff) use it without their extra terms |
| PSM_Debris | `di2_particle_debris` | PS 11860 / VS 1502 (inline shader map) | the viscera chunks: atlas UV (U·u / UV_Tiles, V·v), BC5 normal + Normal_Flatness, base = sat(Diffuse·particle rgb), subsurface = sat(Subsurface_Mult·base), roughness = sat(Roughness_Mult·MRO.g), clip(a·Diffuse.a − 0.3333), TwoSidedFoliage |
| PSM_Fire_OpacityMask | `di2_particle_fire_mask` | PS 6901 (sprite), 6894 (GPU) | the burning-petrol flames (PS_Burning_Liquid, PS_Extinguished_Fire): fire flipbook + motion vectors, BlackBody(BlackBodyBias·dyn.y), lerp to FuelColor by UsesFuel·(1 − sat((1 − (particle z − pixel z))/FuelHeightFalloff)^0.8)·max(0, 0.8(1 − cc.r) + 0.1), × (1 − mean(cc))·Emissive_Add, × lerp(sat e, luma, Desaturation_Fraction), vector opacity c^Contrast_Opacity·a·Opacity_Boost, 30 cm depth fade; GPU: dyn = 0 |
| PSM_Whitewater_Foam | `di2_particle_foam` | VS 12355 / PS 12356 (mesh) | PSMI_Fire_Foam (the glowing sphere under the petrol flames): WPO along the unnormalised normal by PT_Linear_Noise, TV_Global3dNoise volume mask, depth-fade band (dyn.y, DepthFade_Brightness, SoftEdge), BlackBody(Temperature·…) emissive, Opacity_Boost 0 (additive) |
| PSM_FireDebris | `di2_particle_fire_debris` | PS 12656 (GPU), 12664 (sprite), inline map | burning flakes: clip d.x ≥ particle alpha, hot rim Color1 (25000, 100, 0) on alpha ≤ d.x < alpha + Edge, base sat(rgb·d.y), BC5 normal, roughness 0.95 |
| PSM_Translucent_Bubbles | `di2_particle_bubbles` | PS 12574 (mesh), inline map | acid bubbles: fresnel opacity ((1 − N·V)^ExponentIn lerped by BaseReflectFractionIn)^Mask_Contrast·a·(1 − f)f, f = sat(D/DepthFade_Distance); TLM_Surface → Godot BxDF |
| PSM_Explosion_AlphaComposite | `di2_particle_explosion` | PS 6868 (Explosion_07, muzzle MIs), 7350 (Fire_Burst_02), 6787 (Explosion_08: Near_Camera_Fade), 8464 (Fire off), GPU 6841 | smoke flipbook (smoke.rgb^Contrast_Smoke, alpha^Contrast_Opacity, 4-tap max depth fade, near fade) + fire BlackBody(dyn.y·fire.r^Contrast_Fire)·dyn.z·(1 − mean)·Emissive_Add + multiple-scattering sphere BlackBody(MS_Temperature·dyn.w·sat((1 − d/dyn.w)/(1 − MS_SphereHardness))^MS_Contrast), d from the particle centre + (0, 0, MS_ZOffset), 1-tap depth fade, exposure multiplier |
| PSM_Liquid_FluidSprite | `di2_particle_fluid_sprite` | PS 11482 | blood / acid liquid sheets: colour sat(rgb·lerp(LowColorMulty, 1, t.r)), opacity dyn.x·t.a·sat(floor(a + t.r)), current sub-image only; per-vertex volumetric lighting → per pixel |
| PSM_Houdini_VertexAnimated_Fluid_Translucent | `di2_particle_vat_translucent` | VS 4576 / PS 4579 | translucent VAT splashes: VS 1693's VAT decode, opacity sat(Diffuse Opacity Multiplier·a), roughness lerp(Max, Min, ColorMap.x), TLM_Surface → Godot BxDF |
| everything else | `di2_particle_generic` | — | APPROXIMATED fallback (§5) |

- **Lit translucency** (`di2_particle_translucent.gdshaderinc`, shared by smoke / bits / bits complex): every DI2
  translucent-lit particle master ends in the same tail: transmission = sat(pow(opacity, Opacity To Transmission
  Curve)·(Min − Max) + Max), absorbed colour = min(1, c^(10·sat(Absorption Density)·min(t,1)·opacity))·c, lit by
  DI2's translucency-volume term with a Cornette–Shanks phase (g = 2·min(t,1) − 1, k = −0.98g): directional
  `(sat(L·(−gN)) + (1−|g|)/π)(1 − sat g) + 0.25·CS(L·V)·sat g`. Godot applies it per light in `light()`; DI2's SH
  ambient part is replaced by Godot's ambient (APPROXIMATED).
- **TwoSidedFoliage** (VAT, dither, debris; `di2_particle_twosided.gdshaderinc`): UE 4.27 `TwoSidedBxDF` (Lambert +
  GGX/SmithJointApprox/Schlick + wrap transmission) in `light()`. UE 4.27 also lights these with the subsurface colour
  in the indirect diffuse (BasePassPixelShader `DiffuseColorForIndirect += SubsurfaceColor`, and the skylight's
  `SkyLightDiffuse` lookup along −N × SubsurfaceColor): the shaders write ALBEDO = base + subsurface so Godot's ambient
  sees it, and `light()` scales the direct diffuse back to the base colour. Without it the dark VAT blood showed only
  the sky reflection (near-black / blue). The −N sky lookup is folded into Godot's ambient (APPROXIMATED). DI2's deferred
  light pass itself is custom and not decoded (recon/DANI.md 7.1).
- Godot's `LIGHT_COLOR` carries a factor π (same convention as the Dani shaders).
- **Exposure-compensated emissive** (fire, electric distortion; also the `Strength` term of PSM_Linear_AlphaComp_Lit):
  DI2 scales emissive by `lerp(Bright, Dark Scene Multiplier, sat((X − Tb)/(Td − Tb))) / X` with X = View[152].y (an
  exposure value; Tb / Td = `MPC_Postprocess_Player` AdvExpCompThresholdBright 5e-5 / AdvExpCompThresholdDark 0.005),
  and the base pass multiplies by PreExposure. ElectricDistortion's multipliers carry an extra 4.7e-5 that its HDR
  particle colours (e.g. blue ×100 with Colour_Contrast 4.5) compensate. The port takes PreExposure / X = 1 and picks
  the multiplier with `DI2ParticleMaterials.scene_exposure` (0 = bright scene, the daylight arena): APPROXIMATED, Godot's
  lighting is not in DI2's physical units.
- **Specular**: DI2 packs a Fury flag into the GBuffer specular channel (stored 1.0 → decoded 0.496); the opaque /
  masked masters use Specular 0.5.
- **Masked dither.** DI2's masked particle materials clip against a screen-space dither (Good64x64 noise +
  ((x + 2y) % 5)·0.2) that DI2 resolves with TAA. The arena has no TAA, so the dither pattern is visible.
- **Fury mode** desaturation (`cb0[225]`, "Fury Highlight Desaturation", "Is Blood (For Fury Mode)") and the editor
  SelectionColor emissive are dropped (gameplay view mode / editor only).

### 4.4 Textures and meshes

Cooked mips are dumped with CUE4Parse (`extracted/particles_build/mipdump`, generated by the builder) for every
texture an MI sets plus every texture the compiled shader maps reference (`referenced_textures`: graph constants such
as `PT_Caustics_Noise_B_Tiling_N`, `T_RoundSplatter_A`, `TV_Global3dNoise`) and `Good64x64TilingNoiseHighFreq`.
Partial mip chains keep mip 0 (Godot's DDS loader needs a full chain). VAT position textures decode inside
[Bounding Min, Bounding Max] with DI2's texture unpack scale/bias = identity (no `PT_*_Pos` carries the PackedData
bit-28 range, so the preshader op 42 is a no-op); VAT normals are signed V8U8 octahedral.

### 4.6 Rust simulation (DI2ParticleSim)

`rust/gore-godot/src/particles/` runs the whole system tick (time setup, kill, reset, module updates, collision traces
against the Godot world via `PhysicsDirectSpaceState3D`, spawning, events, integration) and writes each emitter's
MultiMesh buffer (`RenderingServer.multimesh_set_buffer`, 20 floats per instance). `DI2Particles` keeps the data
lookup, renderers / materials, the light pool and the GDScript simulation (`use_rust = false` switches to it).
- It is a line-for-line port of the GDScript emitter (same function names in comments) with GDScript's numeric types
  (scalars f64, vectors / bases f32 with Godot's operator semantics), and it draws Godot's `RandomNumberGenerator`
  sequence exactly (PCG32; `randf` = two `rand()` calls, significand | 0x80000001, scaled by 2^(-32 - clz)). With the
  same seed both simulations produce identical state and draw checksums (`--perf`).
- Cost (`--perf`: 24 systems, ~3700 live particles, 120 fixed 60 Hz steps): GDScript 99.9 ms/frame before its
  optimisation, 59.9 ms after (compiled distributions, hoisted lookups, one buffer upload per emitter); Rust 3.2 ms.

### 4.5 Environment drips (PSM_BloodDripsEnviro)

The drips that blood droplets leave on the world (collision events → `EventReceiverSpawn` → a `ParticleCube` mesh
emitter, 26 emitters) are **deferred decals**: `MD_DeferredDecal`, `DecalBlendMode DBM_CustomFluid` (DI2's own blend
mode), drawn on the particle mesh as a mesh decal. Coverage = DI2's `FMeshDecalsPS` 1598, transcribed exactly: scene
position from depth, projected on the particle's scaled local axes, divided by Divide00 · DynamicParameter.y ·
particle alpha (so the splat shrinks as the alpha fades), three `T_RoundSplatter_A` projections (YZ / XZ blended by
|camera forward · UE Y|, and XY), distorted by `TV_Global3dNoise` at world / "3D Noise Scale".

DI2 writes that coverage into its fluid buffer, and two global passes (`/Engine/Private/DS/Internal/Fluids.usf`:
`FFluidDetailFilterPS` Global 1856 / 1857, `FFluidComposePS` Global 1858; recon/RE_FLUIDS.md) compose it into the
GBuffer: sel = sat((1 − typeRGB)/typeW) picks the fluid colour (blood's "Fluid Type" (0, 1, 1) → View[236]; the pairs
231/232 and 233/234 lerp by 1 − c²), colour = min(1, rgb^(FluidDensity·c²)), base-colour alpha = colour.w·c, and
GBufferB = (metallic 0, specular 0.35, roughness FluidRoughness) at alpha √c. FluidDensity = 10 and FluidRoughness =
0.08 are `AFluidParamsUpdateActor`'s constructor defaults (exe 0x1436ff060, traced by the gore session). The colours are
DI2 additions to FPostProcessSettings (BloodColor, …): the drip shader takes them from game/data/fluids.json
`compose` (the gore session's build_fluids.py; level_colors override Fuel / FuelEdge), picked by the MI's "color"
(its Fluid Type) with FFluidComposePS's selector. The port draws a lit
overlay with permutation 1's edge sharpening (k = sat((c − .5)·12 + .5)·c), colour min(1, C^(10·k²)), specular 0.35,
roughness 0.08 (one alpha for both). The splats are the size of the drip cube (ParticleCube ±1.31 cm × Size 3–5, about
8–13 cm) and shrink as the particle alpha fades (7–14 s lifetimes). The gameplay fluid / puddle system is the gore
session's `di2_fluids.gd` (recon/RE_FLUIDS.md).

## 5. Approximated, UNVERIFIED, not ported

1. **CE attachment** — the spawn rotation is traced (§2); the socket attach itself follows the CE data and the caller's
   parent (DI2 attaches to the impact's component at the hit bone).
2. **Looping systems** stop after 30 s. UNVERIFIED (native deactivation).
3. **GPU emitters**: DI2's `FParticleSimulationPS` (global shader) is not transcribed yet. Constant acceleration + drag
   (sample·DragCoefficientScale + Bias) + Euler integration per UE 4.27. UNVERIFIED. `CollisionGPU` (depth-buffer
   collision, 20 emitters in the shock/impact systems) is not ported: those particles pass through surfaces.
4. **Vector fields** (`VectorFieldLocal` 132 uses, `VectorFieldRotation(Rate)`, `VectorFieldGlobal`,
   `AccelerationVectorField`): not ported (GPU emitters lose their swirl).
5. **Not ported modules**: `LocationBoneSocket` (PS_BloodSpurt_BlueCrab_CS), ribbons (`TypeDataRibbon` +
   `TrailSource`, 12 emitters: paired kills, fire explosions), `EventReceiverAkEvent` (audio). Orbit is disabled
   everywhere in DI2's data; Light and the Seeded modules are ported (§4.1).
6. **Collision**: `UParticleModuleCollision::Update` follows UE 4.27 (DI2 0x14398edd0 not transcribed line by line).
   `LocationPrimitiveCylinder`, `LocationEmitter` follow UE 4.27 (UNVERIFIED in DI2's exe; few uses).
7. **LOD** chosen once at activation (no periodic re-check).
8. **Mesh particles**: TypeDataMesh camera facing, AxisLockOption and `PSA_TypeSpecific` mesh alignment are not
   ported (unused by the hit set).
9. **Materials without a transcription** use `di2_particle_generic` (first colour texture × particle colour, the
   master's blend mode, unshaded): APPROXIMATED. Remaining (emitter uses in particles.json, 2026-10-08):
   M_WeaponStatic 32 (arrow meshes, inline), PSM_CrownSmoke_Transluscent_Lit 27, PSM_LightningMesh 26,
   PSM_Debris_Translucent 20 (bullet-impact debris), M_Vertex_Animation 14, PSM_DustPoint 11, PSM_FlareSmokeTrail 10
   (ribbons, not ported), PSM_Vegetation 9, DefaultParticle 7, PSM_GlassDebris_ThinTranslucent 6, PSM_BrinkVeins 5,
   PSM_BrinkLightnings 4, PSM_Hive_Debris 4, PSM_Teeth 4, M_EyeRefractive 3, PSM_BloodTrail 2 (ribbon), M_VolFogParticle 2,
   PSM_Fireworks_AlphaComp_Lit 2, M_Opaque 2, PSM_Env_Worm / PSM_SwarmBoid / PSM_Fly_Sprite 1, and 10 Suicider mesh
   emitters whose material has no dump. List them with the script in §7. `tools/particles/inline_map.py` +
   `matshaders.py <root master>` decompile inline maps (pass the master's name: an MI's dump has no resources).
   The VAT Acid / HeadStomp MIs (same master) use the base VAT transcription; their switch-dependent differences
   (PS 4510, 7078) are not checked.
10. **Lighting**: DI2's translucency-volume SH ambient → Godot ambient; DI2's deferred light pass → stock UE BxDFs;
    no TAA (dither visible); DI2's reflection captures → Godot sky/probes (bits complex specular). APPROXIMATED.
11. **Refraction / distortion pass** (Refraction switches, ElectricDistortion): UE's separate distortion pass is not
    ported.
12. **Fluid system**: CE `FluidParticle` entries (`DA_FluidTypeInfo_Blood` → `BP_Fluid_Projectile_Blood`, puddles and
    flow) are DI2's gameplay fluid simulation, not particles: data only. The drip decals' fluid composite is
    approximated (§4.5).
13. **Fury mode** and selection colour terms dropped (§4.3).
14. **Exposure-compensated emissive** (fire, electric distortion): DI2's exposure value is replaced by
    `DI2ParticleMaterials.scene_exposure` (§4.3). APPROXIMATED.
15. **Contact fades** (fire `UsesContactOpacity`, ElectricDistortion_02) only show against a surface within a few cm
    behind the sprite (the zombie body in DI2): they are invisible in open air by DI2's own math.

## 6. Test

`tools/with_cpu.sh particles tools/with_lock.sh particles tools/run_test.sh --particletest=game/test_out/particles`
(add `--only=<label substring>` / `--debugvat` after it for iteration). `autotest_particles.gd` clears the arena,
puts a body stand-in (a capsule, visual only: DI2's particle collision traces statics) right behind a chest-height hit
so the contact / soft-particle depth fades have a surface, plays 12 CEs (normal +Z toward the camera side, hit
travelling −Z) with the hit tree's factor, steps them at a fixed 60 Hz and saves `<label>.png` (8 frames at 0.033 /
0.067 / 0.1 / 0.167 / 0.25 / 0.4 / 0.7 / 1.5 s, cropped around the hit), `<label>_full.png` (t = 0.167 s),
`<label>_end.png` (t = 1.5 s from a camera looking down at the floor where droplets land, for the drip decals) and
`particles.log` (live particles per emitter per frame, sim time; with `--only`, mesh-particle state). Effects: blunt_medium, blunt_crit, sharp_medium, sharp_crit, stab_medium, bullet_pistol,
headshot_pistol, headshot_shotgun, blunt_fire, blunt_shock, blunt_acid, bleed_lingering, and fist_kill_chunks
(CE_Zombie_Counter_Fist_Kill, for the viscera chunks).

## 7. RE notes

- Material shaders: `python tools/particles/matshaders.py <MI> list` then `<MI> <VertexFactory> <ShaderType> <label>`
  (decompiles with 3Dmigoto and annotates parameter names from the shader map; output in
  `extracted/shaders/annotated`). Already decompiled but not transcribed: Explosion_AlphaComposite 7350, Fire_Burst_01
  7564 / GroundFlames 10019 extra terms, Blood_Smoke_SurfaceVolume 11501, Whitewater 2751 / 11766, BlowMind 13532,
  SawDebris 16137 / 1502, VAT Acid 4510 / 4491, VAT Translucent 4579 / 4576, VAT HeadStomp 7078 / 7063.
  (BloodDripsEnviro's base pass 1614 / 1618 exists but is not what draws: the material is a deferred decal, §4.5.)
- Global shaders: `tools/particles/global_find.py <regex> [--decompile <label>]` (needs a Python with `zstandard`,
  e.g. Python312).
- Inline shader maps: `di2x raw "/<Material>\\.uasset$"` (with `DOTNET_ROOT=tools/dotnet10`), then
  `python tools/particles/inline_map.py <Material> [type regex]`; `matshaders.py` uses it automatically for roots
  without a `shader_resource_hash`.
- View uniform buffer offsets used above (UE 4.27 order): SVPositionToTranslatedWorld cb0[44..47], ViewToTranslatedWorld
  cb0[16..19], InvDeviceZToWorldZTransform cb0[65], WorldCameraOrigin cb0[67], PreViewTranslation cb0[70].
- The inline map is UMaterial's SerializeInlineShaderMaps stream (bCooked, bValid, FMaterialShaderMapId, DI2 frozen
  content); `inline_map.py` finds it by the CookedShaderMapIdHash and parses it with `tools/shaders/frozen.py`
  (CUE4Parse misreads DI2's frozen layout).
