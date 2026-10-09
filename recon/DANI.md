# Dani (DI2 FemBerserker) in first person: mesh, materials, shaders, hand blood

Static analysis of the user's own install, personal use only. The game is never run. Nothing extracted is shared.

**Files (this session):**
- `tools/build_dani_materials.py` → `game/data/dani_materials.json` and `game/assets/di2/dani/flesh/` (.gdignore'd: DDS, volume noise, skin side-car, TP shadow glb).
- `game/shaders/player.gdshader`: the transcription.
- `game/scripts/dani_visual.gd`: setup and runtime.
- `game/scripts/autotest_dani.gd`: `--danitest=<dir>`.
- `tools/re_dani/` with my own headless Ghidra project `extracted/ghidra_dani/DI2dani`.

**Hook-up:**
- `player.gd`: `arm_mats = DaniVisual.attach(self, rig)` replaces the `Util.apply_prop_materials` line.
- `main.gd`: registers `--danitest=`.

**Reproduce:**
1. `tools/with_cpu.sh dani <miniconda python> tools/build_dani_materials.py` (about 30 s).
2. `tools/with_cpu.sh dani tools/with_lock.sh dani tools/run_test.sh --danitest=game/test_out/dani`.

Every number below has its DI2 source next to it. Section 7 lists what is **not** verified.

---------------------------------------------------------------------------------------------------------------------

## 0. What was wrong before, and what changed

The old setup was `Util.apply_prop_materials` with `prop.gdshader` and `dani_fp.materials.json`, from `pack_materials.py` and CUE4Parse's PM_* guesses. These problems account for the "looks bad":

| Problem | Before | DI2 / now |
|---|---|---|
| Hand albedo | `DefaultDiffuse.png`, a grey placeholder, on FPHandR, FPHandL, the bracelet, the glove and the upper/lower body | `T_FemBerserkerFPHandR_D` and the other per-section `Diffuse Colour Map`s from the MI chain |
| Hand normal | `T_FemBerserkerFPHandRFury_N` (the **Zombie Veins** normal map, only used during Fury) on both hands | `T_FemBerserkerFPHand{R,L}_N` |
| Skin normal | `T_DefaultSkin_Detail_N` (the detail map) as the base normal | `T_FemBerserkerSkin_N` as base, plus the detail map at `Detail Tiling` × `ATA.b` strength |
| Mipmaps | All 30 textures imported lossless **without mipmaps**: heavy aliasing at FP distances | DI2's own cooked mip chains (DDS, byte-identical BCn blocks, no re-encode) |
| Shading | Generic PBR, no SSS, no cloth model | Five transcribed DI2 base-pass PS (section 4) + DI2's own light pass (dual-lobe oil skin, Burley diffuse, Charlie cloth with translucency back-scatter, 2·S' specular byte), subsurface profile |
| Skinning | 4 influences (CUE4Parse glTF writer) | The cooked 8 influences: 3,977 of 27,918 glb vertices carry up to 14.5% weight beyond the 4th |
| Shadows | The FP arms cast the player's shadow | As DI2: the FP mesh casts none; the hidden third-person body casts it |
| Hand blood | A smoothstep "blood_amount" overlay | DI2's PlayerHandsMaterialComponent: staged textures, flow animation, Beer-Lambert absorption, wet roughness |

Captures (in `game/test_out/dani/`):
- before/after: `03_before_prop_shader`, `04_before_prop_closeup` vs `01_idle_bat`, `02_hands_closeup`;
- left hand / glove: `02b_left_hand_closeup`;
- pistol grip: `06b_pistol_hands_closeup`;
- blood stages: `08_blood_*`;
- Fury veins: `10_fury_veins_closeup`;
- look down: `11_look_down`;
- shadow: `12_shadow_external`, `13_shadow_fp`.

The log `dani.log` checks every section against the JSON. The current result: 10/10 sections OK, 51/51 textures loaded, 8 influences on (top-4 agreement 27,786/27,918; the rest are weight ties).

---------------------------------------------------------------------------------------------------------------------

## 1. Meshes and component setup

### 1.1 The FP mesh: `SK_FemBerserkerFP`
- `DA_ModelVariantAsset_FemBerserkerFP.Model` = `SK_FemBerserkerFP`; `BP_Berserker_Female.MeshFirstPerson.SkeletalMesh` = the same.
- Skeleton `SKEL_MaleStandard`, physics asset `PA_MaleStandard`.
- 5 LODs. At FP distance only LOD0 matters: 28,365 vertices, 1 UV channel (`NumTexCoords 1`).
- Bounds: origin (12.8, −0.4, 75.6) cm, extent (29.0, 50.1, 75.7). It is a **full headless body**: hands, arms, torso, legs.

| Slot | MI | LOD0 verts | MaxBoneInfluences | CharacterMaterialMasks |
|---|---|---|---|---|
| 0 | MI_FemBerserkerSkin | 1589 | 6 | |
| 1 | MI_FemBerserkerLowerBody | 5670 | 8 | |
| 2 | MI_FemBerserkerUpperBody | 5554 | 5 | |
| 3 | MI_FemBerserkerBandFP | 1942 | 7 | SectionName "Bandage" |
| 4 | MI_FemBerserkerBandCardsFP | 350 | 7 | SectionName "Bandage" |
| 5 | MI_FemBerserkerFPHandR | 4258 | 7 | PlayerHandsData: BloodSettings `FemBerserkerBloodHandR`, injury `HandR` |
| 6 | MI_FemBerserkerFPBracelet | 1678 | 7 | (no blood) |
| 7 | MI_FemBerserkerSkinArmL | 1157 | 6 | `FemBerserkerBloodArms`, injury `ArmL` |
| 8 | MI_FemBerserkerFPGlove | 3703 | 7 | `FemBerserkerBloodAccessories` |
| 9 | MI_FemBerserkerFPHandL | 2464 | 6 | `FemBerserkerBloodHandL`, injury `HandL` |

- `DIEngineMaterialMasks`: `WriteSplatterMask`, `DeformationMask` and `DismemberMask` are all 0xFFFF…FC00, which clears bits 0–9. **No FLESH splatter is written to any FP section.** Blood on Dani's FP body comes only from the staged hand textures (section 5).
- `SortBiasMask` 699050 = 0xAAAAA, 2 bits per section.
- **dani_fp.glb** (`game/assets/di2/dani/`, merged with the animations) holds exactly these 10 sections. CUE4Parse's glTF writer dedups vertices (27,918 glb vs 28,365 cooked) and keeps only 4 influences.
- `dani_visual.gd` rebuilds the surfaces at load:
  - all 8 cooked influences, from the raw package's FSkinWeightVertexBuffer (4.27 layout, decoded in `build_dani_materials.py::skin8`);
  - matched to Godot's vertices **by position**, because Godot's importer reorders vertices;
  - joints mapped **by name**, because Godot's skin binds are not in glTF joint order.
- `CUSTOM0` = the UE bind position in cm. It feeds the materials' 3D noise; DI2's VS passes `ATTRIBUTE0 + Deform.xyz·Deform.w` (TEXCOORD2.xy / 3.x), and the player's deform depth is 0.
- `SK_FemBerserkerNoBandageFP` is the same mesh without the two Bandage sections (variant asset `DA_ModelVariantAsset_FemBerserkerNoBandageFP`). It is not used.

### 1.2 Third-person body in first person: yes, as a hidden shadow caster
Evidence from `BP_Base_Player`, with the meshes overridden in `BP_Berserker_Female`:

| Component | Mesh | Flags (BP_Base_Player) |
|---|---|---|
| `MeshFirstPerson` (FirstPersonMeshComponent) | SK_FemBerserkerFP | `bOnlyOwnerSee` true, **`CastShadow` false**, `bRenderNearest` true, `AnimClass` ABP_PlayerCharacter_1P, attached to the capsule at RelativeLocation (0, 0, −95) |
| `CharacterMesh0` (DSSkeletalMeshComponent) | SK_FemBerserker (21 sections incl. head, hair, eyes) | **`bOwnerNoSee` true, `bCastHiddenShadow` true**, same `AnimClass` ABP_PlayerCharacter_1P, attached to the capsule at (0, 0, −95), LightingChannels bChannel1 false |
| `FirstPersonPlayerCamera` | | AttachParent = MeshFirstPerson, RelativeRotation yaw 90, FieldOfView 37.849 (component default) |

So in first person:
- The owner sees only the FP mesh: hands, arms, torso, legs. The FP mesh casts no shadow.
- The full third-person body is invisible to the owner but casts the player's shadow, with the same 1P anim blueprint, i.e. the FP pose.

**Port:**
- `dani_visual.gd` sets the FP mesh `cast_shadow` OFF.
- It loads `SK_FemBerserker` (`flesh/dani_tp_shadow.glb`, copied from `extracted/mesh`) as `SHADOWS_ONLY`, with depth-only masked materials: ATA.r, and hair data .a for the hair at its MI clip 0.4. The translucent eye overlay casts nothing.
- Each frame it copies the FP skeleton's local bone poses by name (114 bones shared).
- The port pitches the FP rig with the camera, whereas DI2 attaches both meshes to the capsule. The shadow body therefore takes the rig transform **without the head pitch**.

### 1.3 Port-side differences (reported to the animations session, which owns player.gd)
- DI2 attaches the camera to the FP mesh and the FP mesh to the capsule. The port parents the rig to the camera, so the FP legs/torso pitch with the view (`11_look_down` shows no legs).
- `bRenderNearest` (DI2's foreground rendering of the FP mesh) is not ported.
- With the pistol equipped, the arms are outside the FP view in the port (also in the animation session's own `anim/after2` sheets). That is an animation/camera issue, not a material one; `06b` checks the pistol hands from a close-up camera.

### 1.4 Story-state hand materials (not used in normal play)
`PlayerHandsMaterialComponent` (BP_Base_Player) holds `HandsVisualsDataAsset`s. These are swapped by the game event `UGameEventStateResponse_SetPlayerHandsMaterial`, i.e. story progress. For BP_Berserker_Female, FirstPersonMesh:

| State | Material |
|---|---|
| Normal | (default mesh materials) |
| Bitten | MI_FemBerserkerSkinBitten (PS 12829, recorded but not transcribed) |
| Address | MI_FemBerserkerSkinAddress |
| Healed | MI_FemBerserkerSkinHealed |

Address and Healed use PS 12717. All are resolved in the JSON (role `hands_visual_variant`). Which section the swap targets is native code (most likely the `ArmL` injury section) **[unverified]**.

---------------------------------------------------------------------------------------------------------------------

## 2. Materials: chains, values, textures

Resolution reuses `tools/shaders/build_flesh_materials.py` read-only (`chains_for`, `resolve`, `base_pass_samples`), with its build folder redirected to `extracted/shaders/dani_build/`. Rules are as in SHADERS_FLESH.md §13.1: leaf-first instance override, else the master default from the effective shader map's uniform expression set. Every value below is from `game/data/dani_materials.json`, with its source instance. The full per-section tables are in Appendix A.

| Sections | Chain | Master / shading model | Shader map (owner) | Base-pass PS | player.gdshader variant |
|---|---|---|---|---|---|
| FPHandR, FPHandL | MI → MMI_PlayerHandsArms → M_Skin | M_Skin, MSM_SubsurfaceProfile (SSP_DefaultLightSkinFP) | BA2D540F… / 019B45CF… (own MIs) | **9326** (same code for both) | `skin_staged_veinmap` (0) |
| Skin, SkinArmL | MI → MMI_PlayerHandsArms → M_Skin | M_Skin, SSP_DefaultLightSkinFP | 683473D8… | **12717** | `skin_staged_cheapveins` (1) |
| BandFP, BandCardsFP | MI → M_Skin | M_Skin, SSP_DefaultLightSkin, two-sided (MI override) | D97B0148… | **5740** | `skin` (2) |
| UpperBody, LowerBody, FPBracelet | MI → M_Clothing | M_Clothing, MSM_Cloth, two-sided | 9AC19F80… | **4452** | `cloth` (3) |
| FPGlove | MI → M_Clothing | M_Clothing, MSM_Cloth, two-sided | 140AEADE… | **9445** | `cloth_staged` (4) |

Static switches:
- **hands**: Staged Splatter Mode, Enable Zombie Veins Effect, Use Vein Normal Map, UsesCutsceneBloodSplatter, Enable Splatter, Enable Detail Mapping.
- **Skin / ArmL**: the same plus Enable Cheap Zombie Veins Effect.
- **Glove**: Staged Splatter Mode, Enable Splatter (Characters Only!), Enable Detail Mapping.
- **Cloth**: Enable Detail Mapping.

Render settings, leaf-first `BasePropertyOverrides` (else the master):
- all are BLEND_Masked;
- clip 0.1 on the M_Skin sections and 0.3333 on M_Clothing;
- M_Skin hands/arms are one-sided; the bands and all cloth are two-sided.

Key values. Full lists are in Appendix A; MPC = `MPC_CharacterGameWideParams` asset defaults.
- **Hands** (MI_FemBerserkerFPHandR/L):
  - Detail Tiling 16, Detail Normal Strength 0.5, Detail Roughness Strength 0, Specular Occlusion Power 1, Roughness Adjustment 0 (all MI).
  - Veins: Normal Strength 2 (MI), Mask Erode 3 (MI), Blood Density 10 (MI); Veins Blood Colour (0.8, 0.4267, 0.4) (M_Skin default).
  - Zombie Veins Normal Map T_FemBerserkerFPHand{R}Fury_N, the 4096² BC5 (MI).
  - CutScene Blood Map T_FemBerserkerFPHand{R,L}Blood04_A (MI); Staged Blood Map T_BlackMaskAlpha_A (MMI).
  - Base SSS 0.9, Vein SSS 1.0, Vein Roughness 0.45, Distortion/Pulse noise set, BlendWeight Normals Curve 2.5 (all MMI_PlayerHandsArms).
- **Skin / ArmL**: Detail Tiling 22, Detail Normal Strength 0.8, Specular Occlusion Power 4, Veins Blood Colour (0.75, 0.4547, 0.4336) (all MI); Detail Roughness Strength 3 (MMI).
- **Band**: Detail Tiling 20 (M_Skin default), Translucency Adjustment 0.07 (MI).
- **Cloth**:
  - Detail Tiling −10.594563 (MI, negative = mirrored detail UVs);
  - Sheen: UpperBody 0.2457 / 0.9848 / 2.2857 (Averaging / Desaturation / Multiplier); Glove 0.38 / 0.1 (default) / 1.4;
  - Cloth Translucency 0.25 and Force Cloth 0 (M_Clothing defaults).
- **MPC**:
  - StagedSplatterBloodDensity 6, NormalsBlendThreshold 4, DynamicNormalsJitter 0.0035, DynamicNormalsStrength 2, EdgeContrast 10, DriedBloodCavityPower 0.6;
  - CutSceneHandBloodSplatter 0;
  - FurySkin RedIsolation 2 / RedDesat 0 / NonRedDesat 1; FuryClothNonRedDesat 1; ChrFuryTint (1, 1, 1);
  - `MPC_GameWideParams.ZombieVeinsCinematic` 0.
- **Subsurface profiles**:
  - `SSP_DefaultLightSkinFP`: Burley, ScatterRadius **0.3 cm**, MeanFreePathDistance 0.25, WorldUnitScale 0.2, SubsurfaceColor (0.915, 0.7517, 0.6039), FalloffColor (1, 0.433, 0.37).
  - `SSP_DefaultLightSkin` (band): ScatterRadius 1.5, same colours.
  - From the exe's default profile struct (DEFERRED_LIGHTING §7.3): the FP profile is **Burley** (MFP colour (1, 0.089, 0.072)); the band profile is **separable** (bEnableBurley defaults to false).

**Textures** (`game/assets/di2/dani/flesh/`, 63 files):
- Written as **DDS holding the cooked BCn blocks and every cooked mip** (Godot `Image.load_dds_from_buffer`, nothing re-encoded). `TV_Global3dNoise` is written as a raw RGBA8 128³ volume (mip 0).
- Formats as cooked: `_D`/`_MRO`/`_ATA`/staged blood = DXT1, normal maps = BC5, `T_BlackMaskAlpha_A` = DXT5, hair data = BC7.
- **sRGB** only on the `_D` maps (texture asset `SRGB`), sampled with `source_color`. Everything else (TC_Masks, TC_Normalmap, staged blood, noise) is linear.
- Addressing is wrap everywhere. Filter: anisotropic trilinear (see 7, sampler state).

---------------------------------------------------------------------------------------------------------------------

## 3. Decompiled shaders used

Files:
- `extracted/shaders/dis/DeadIsland_<idx>_Dani*.{hlsl,asm}`;
- annotated (Material/MPC slot names): `extracted/shaders/annotated/DeadIsland_<idx>_Dani*.hlsl` + `.slots.txt`;
- `extracted/shaders/dani_build/shaders.json` lists PS and VS per map.

All are High quality, `TGPUSkinVertexFactoryDefault`, `TBasePassPSFNoLightMapPolicy`.

| PS | VS | Sections |
|---|---|---|
| 9326 (669 instr) | 9311 | FPHandR, FPHandL |
| 12717 (650) | 2162 | Skin, SkinArmL |
| 5740 (507) | 1993 | BandFP, BandCardsFP |
| 4452 (556) | 4469 | UpperBody, LowerBody, FPBracelet |
| 9445 (572) | 9401 | FPGlove |

VS interpolators:
- TEXCOORD0 = UV0 (ATTRIBUTE5).
- TEXCOORD1 = ATTRIBUTE6, i.e. UV1. The mesh has one UV channel, so the GPU-skin VF binds UV0 again **[engine]**.
- TEXCOORD2.xy / 3.x = bind position + Deform.
- TEXCOORD3.y (skin) = `sat(Color.g + (Deform.w ≥ 0.001))`.
- Cloth: TEXCOORD2.y = `sat(Freeze Amount)·frostiness`, which is 0.
- TEXCOORD9 = world position; TEXCOORD10/11 = tangent X / Z (w = determinant sign).
- Skinning: 4 bones + 2 DI2 "soft" influences (ATTRIBUTE11/12; SoftBodyNames are all None on this mesh). The 5–8-influence sections use the GPU-skin "Extra" VF, whose PS is the same code.

---------------------------------------------------------------------------------------------------------------------

## 4. player.gdshader: what was transcribed and how

### 4.1 Per variant (register-level sources are in comments in the shader)
- **Inputs**: `ata = ATA(UV0)`. `.r` = opacity (× vis), `.g` = vein mask (skin) or cloth mask (cloth), `.b` = detail mask.
- **Veins** (variants 0/1, PS 9326/12717 lines 121–216): see the formulas below. **Off** while ZombieVeinBlendWeight = 0 (the default).
  - `pulseMove = 1 − ata.g·LargerVeinsMoveLess`
  - two TV_Global3dNoise taps at `Pb·scale + frac(speed·GameTime)`:
    - `dn = (dot(n1, V7) − 0.5)·2`;
    - `pn = sat((dot(n2, V14) − min)/(max − min))`;
  - `dist = lerp(MinUV·(1−Freeze), MaxUV·(1−Freeze), pn)·VC.r·dn`
  - `uvV = UV(1|0) + pulseMove·dist`; `h = ATA(uvV).g`
  - `I = lerp(VeinIntMin, VeinIntMax, dn·DistAffects + pn)`
  - `w = dist·pulseMove·I·ZombieVeinBlendWeight·h^SkinDistortFalloff`
  - normal UV = `UV + w·BaseNormalsDistort`; skin UV = `UV + w·SkinDistort`
  - `vmask = sat(I·h^VeinMaskErode)`; `vblend = sat(sat(ZombieVeinsCinematic) + ZombieVeinBlendWeight)`
- **Normal**: `rnm(unpack(Normal(uvA)), lerp((0,0,1), unpack(DetailN(Tiling·uvB)), DetailStrength·ata.b))`. This is UE's BlendAngleCorrectedNormals exactly as compiled.
  - Variant 1 first flattens the base normal by `ata.g^ZombieVeinBaseNormalFlattenPower` (0.1). This is always on, not gated by veins.
- **Vein normal**:
  - Variant 0 samples `Zombie Veins Normal Map` at uvV in a **screen-derivative cotangent frame** (PS 9326 lines 178–210), with the cross products in mirrored order (see 4.2), then `(n − z)·VeinsNormalStrength·Aggressive + z`.
  - Variant 1 uses the base Normal Map at uvV instead.
  - Blend by `vblend·vmask`.
- **Staged blood** (variants 0/1/4; PS 9326 lines 219–315):
  - `c0 = 0.5 − 0.5/EdgeContrast`; `ph = Phase·2c0 − c0`; `step(g) = sat((g + ph − 0.5)·EdgeContrast + 0.5)`.
  - The G channel is the **flow arrival time**: the phase sweeps the visible area. R = blood height, B = dried blood.
  - Height normal from 4 taps at ±Jitter: `(s(hC−hA), s(hD−hB), 2)`, with CutScene Blood Map selected when `CutSceneHandBloodSplatter` > 1e−5.
  - `cav = max(0, 1 − |n.z|/|n|)`; normal blend `sat(4·(R + cav)·m)`.
  - Absorption `min(1, exp2(−(0.3219, 3.3219, 4.3219)·6·a))` = `(0.8, 0.1, 0.05)^(6a)`, where `a = (R + cav)·m + B^0.6·cav + B`.
- **Skin colour / PBR** (PS 9326 lines 494–575; 12717; 5740):
  - MRO at uvB. `spec = 0.5·O^SpecOcclusionPower`. `metallic = M·absorb.r^MetalBlendPow` (staged).
  - `D` desaturated by Desaturation, × Colour Tint, Fury desaturation (× `View[225].y`, 0 outside Fury).
  - Veins colour `min(1, VeinsBloodColour^(Density·vblend^2.5·vmask))`. Base = `sat(min(max(C·absorb, 0.018·spec), 0.875 + 0.125·metallic))`.
  - Roughness `sat(adj + R + DetailRoughStrength·ata.b·(XRX.g − 0.5))`, then → Vein Roughness by V, then `× (1 − sat(m + B))` (wet blood).
  - SSS opacity:
    - veins variants: `lerp(Base SSS, Vein SSS, V)` (0.9);
    - band: `MRO.b·sat(TranslucencyAdj + ata.g)`.
  - Alpha `ata.r·sat(VC.g)`, clip at the MI value.
- **Cloth** (PS 4452 / 9445):
  - `cloth = sat(ForceCloth + ata.g)`; `tint = lerp(1, ClothColourTint, cloth)`.
  - Base `sat(min(max(D·tint·absorb, 0.009), 0.875 + 0.125·m'))` with `m' = lerp(M, ClothTranslucency, cloth)` (× absorb^pow on the glove).
  - Roughness `sat(R + DetailRoughStrength·ata.b·(DRO.g − 0.5) + adj)` (× wet on the glove).
  - Fuzz (sheen) colour from the diffuse's **last mip** (`SampleLevel 16` = average colour):
    - `lerp(C, avg·tint, SheenAveraging)`, desaturated by SheenDesat, `sat(·SheenMultiplier)`, × absorb;
    - a Fury desat applies on 4452 only.
  - Alpha `ata.r`.

### 4.2 Conventions checked against data
- **Tangent frame.** On the cooked LOD0 tangents, Godot's `BINORMAL` (= cross(N, T)·w from the glb) is exactly **−(mirrored UE bitangent)**: cos = −1.000 on every hand vertex. So `B_ue = −BINORMAL`, and the shader builds the world normal itself (`NORMAL = n.x·T + n.y·B_ue + n.z·N`).
- **Mirror.** The glTF space is the (x, z, y) mirror of UE's. `cross(Ma, Mb) = −M·cross(a, b)`, so the vein cotangent frame uses the opposite cross order to UE's.
- **Back faces.** Godot flips only NORMAL on back faces (verified in 4.7's embedded scene shader); the shader undoes that.
  - M_Skin two-sided (band) **does not read SV_IsFrontFace at all**: back faces keep the front normal.
  - M_Clothing flips **world XY** on back faces: `TwoSidedSign = Primitive.det · View.CullingSign · (front ? 1 : −1)`, then `N = sign ≥ 0 ? N : (−1, −1, 1)·N`.
  - UE world XY is the horizontal plane, which is Godot world XZ.

### 4.3 GBuffer encoding seen in the PS (DI2 changes to UE 4.27)
- `GBufferB.w` = 133/255 (SubsurfaceProfile, id 5) on skin, 136/255 (Cloth, id 8) on cloth. That is standard id | 0x80 mask.
*Corrected 2026-10-08 with DI2's decoded light pass, recon/DEFERRED_LIGHTING.md §2.* The earlier note that the light pass "reads a packed layout from structured buffers" described only the hair-strands permutation (Global 2174 p16241). Every other permutation reads the plain GBuffer. There are 768 permutation entries (475 distinct shaders), not 40.

- **Specular byte.** `GBufferB.y = sat(129/255 + min(0.5, Specular))` is a flag plus a **7-bit specular intensity**. The light pass decodes `S' = 0.5·sat((B.y − 129/255)·512/255)` (at most 0.49606) and multiplies **all specular by 2·S'**: the direct light, and also the reflection pass. It does **not** set F0.
  - Skin: S = 0.5·O^SpecularOcclusionPower.
  - Cloth: no Specular input, so 2·S' = 0.99213.
- **F0 is fixed:** `lerp(0.04, BaseColor, metal)`. For SubsurfaceProfile (and Eye) it is **0.028**, with metal forced to 0.
- **Skin `GBufferB.x`** is not metallic. It is the **"Oil Layer" lobe mix**: `sat('Debug Oil Layer' + MRO.x·absorb.r^StagedSplatterMetalBlendPow)`, PS 9326 line 562. The base clamp `0.875 + 0.125·oil` stays material-side.
- **Skin CustomData:** CustomData.a = SSS opacity, which gates the lobes and the SSS recombine by `sat(10·op)`.
- **Cloth:**
  - `GBufferB.x` holds `min(0.99, lerp(Metallic, ClothTranslucency, Cloth))`.
  - The light pass uses `metal = B.x·(1 − Cloth)`.
  - **ClothTranslucency is back-scatter transmission:** a fraction m of the base colour is moved out of the Lambert diffuse (section 4.5).
  - CustomData = (fuzz colour, **linear**, Cloth).
- **AO:** no material AO output (`GBufferC.a` = dither). MRO.b is used only for specular occlusion (and the band's SSS). The port leaves Godot AO at 1, since Godot multiplies direct light by AO.

### 4.4 Preshaders
DI2's opcode table, derived from the data:

| Opcode | Op |
|---|---|
| 35 | ComponentSwizzle |
| 36 | AppendVector |
| 41 | RVT uniform |
| 24 | Saturate (confirmed by its use on Freeze Amount / LandscapeBlend) |

That is UE 4.27's EPreshaderOpcode list shifted by two, which makes 20 = **Sqrt** and 22 = **Length**. The noise channel mixes are then `V7 = v / length(v / sqrt(v))` = `v / sqrt(Σv)`, with x/0 taken as 0 (`dani_visual.gd::_channel_mix`). **[Unverified]**: the two missing enum entries are inferred, and the result does not sum-normalise the mix, which looks unintended.

### 4.5 Lighting: DI2's own light pass (corrected 2026-10-08)
`light()` transcribes DI2's `FDeferredLightPS` BxDFs (recon/DEFERRED_LIGHTING.md §4.5, §4.8, §9; Global 2075 p1). Stock UE 4.27 is no longer used.

- **Skin** (MSM_SubsurfaceProfile, variants 0/1/2):
  - `METALLIC = 0`; oil = GBufferB.x; op = SSS opacity; `s = sat(10·op)`.
  - Lobe roughnesses: `rA = lerp(1, max(min(R², 1), 0.02), s)`, `rB = lerp(1, max(R, 0.02), s)`, `rV = lerp(rB, rA, oil)`.
  - `F = Fc + (1 − Fc)·0.028`.
  - Specular = `NoL·F·Vis_SJA(rV⁴)·(oil·D_GGX(rA⁴) + (1 − F·oil)²·D_GGX(rB⁴)) · 2S'`.
  - Diffuse = Burley: `FD90 = 0.5 + 2·VoH²·R`.
  - The profile's Roughness0/Roughness1/LobeMix are unused, as in DI2.
- **Cloth** (MSM_Cloth, variants 3/4):
  - `F0 = lerp(0.04, BC·(1 − m·C), metal)`.
  - Specular = `lerp(GGX, NoL·Charlie(αc = max(R, 0.08))·Vis_Cloth·F_Schlick(fuzz), C) · 0.99213`.
  - Diffuse ×`(1 − m·C)·(1 − C·NoL·Vis_Cloth·F_fuzz)`.
  - Plus transmission `sat(C·m·BC)·(1/2π + 2.522535·sat(−V·L)¹²)·(1 − sat(−N·L))³`. This is not NoL-clamped, so light() runs it when the light is behind. It is lit by the surface shadow, ATTENUATION in Godot.
  - On Dani m = ClothTranslucency = 0.25 where Cloth = 1.
- **Not ported:** DI2's `sat(1 + SSAO − Cloth)` on cloth specular and transmission. Godot's light() cannot read SSAO, so it is 1 unless occluded.

Godot 4.7 Forward+ multiplies the `light()` diffuse by albedo·(1 − metallic) afterwards, and LIGHT_COLOR carries π (checked in the embedded shader source). Ratios match DI2.

**Ambient / reflections (fragment `SPECULAR`, `ROUGHNESS`).** Godot's ambient F0 is `0.16·SPECULAR²`. The shader writes:
- skin: `SPECULAR = sqrt(0.028·2S'/0.16)`;
- cloth: `SPECULAR = sqrt(0.04·2S'·(1 − |NoV|·C)/0.16)`, with `ROUGHNESS = lerp(R, 0.1, sat((C − 0.9)·10))`. DI2's reflection pass uses the same damping and roughness. The true R goes to light() as a varying.

Folding 2·S' into F0 is exact on the F0·A term of the environment BRDF. On the B term Godot gives `min(1, 50·F0')` where DI2 gives `2S'` **[approximation]**.

DI2's second, oil reflection lobe (roughness R², reflection §6) is **not ported**. Godot's CLEARCOAT is no substitute: its roughness is capped at 0.1 and it uses the geometric normal.

**SSS.** DI2 uses two different kernels (DEFERRED_LIGHTING §7.3):
- `SSP_DefaultLightSkinFP` (hands, arms) is **Burley**: MeanFreePathDistance 0.25 × WorldUnitScale 0.2 = 0.05 cm, MFP colour (1, 0.089, 0.072).
- `SSP_DefaultLightSkin` (band) is **separable**, ScatterRadius 1.5 cm. bEnableBurley defaults to false (exe default struct).

Godot has only its screen-space skin kernel. `dani_visual.gd::_sss_radius_cm` picks the radius by profile type, and the shader maps it onto Godot's kernel, gated like DI2's recombine `sat(10·op)`:

    strength = sat(10·op) · (R · P00 / 2z) / subsurface_scattering_scale

**[approximations]:**
- the Burley radius reading of MFP × WorldUnitScale;
- the kernel shape;
- DI2's per-channel SubsurfaceColor blend and its `sat(PixelRadius − 4)` gate, whose scale is CPU-side.

At 0.05 cm on the FP hands that gate likely switches DI2's SSS off, and the port's strength is correspondingly tiny.

Before/after captures for this change (stock UE 4.27 vs DI2 light pass): `game/test_out/dani/compare_light/*_stock_vs_di2.png`. The flesh suite (`--fleshtest`) was re-run afterwards with an identical case list and no errors (`game/test_out/dani/fleshcheck/`).

### 4.6 Terms left out (exactly zero for the player in normal play)
- Landscape RVT blend: `LandscapeBlend` 0 makes the blend weight 0.
- Frost: `Freeze Amount` 0.
- Selection emissive: SelectionColor 0.
- Character fade dither: fully shown, PrimitiveFade 254 ⇒ alpha passes untouched.
- Debug view overrides (`View[135–138]`).
- The per-primitive Fury highlight (`View[225].y/z` × primitive byte), 0 outside Fury.

---------------------------------------------------------------------------------------------------------------------

## 5. Hand blood and hand effects (UPlayerHandsMaterialComponent, UCosmeticEffect_PlayerHandMaterial)

### 5.1 Data: `BP_Berserker_Female.PlayerHandsMaterialComponent.BloodSettings`
All four entries share:
- `TextureParameterName` "Staged Blood Map";
- `FlowAnimationTextureParameterName` "Splatter Animation Phase";
- `FlowAnimationDuration` **2.25** s;
- `RequiredOnScreenTimeBeforeAnimation` **1.0** s.

The `UStagedTextureMap`s (`DI2/Player/Characters/Berserker/DA_StagedBloodTextures_PlayerHands_Berserker_Female_*`), score → texture:

| Key (section) | 1.0 | 0.75 | 0.5 | 0.1 | 0.0 |
|---|---|---|---|---|---|
| FemBerserkerBloodHandR (FPHandR) | T_FemBerserkerFPHandRBlood04_A | …03_A | …02_A | …01_A | T_BlackMaskAlpha_A |
| FemBerserkerBloodHandL (FPHandL) | T_FemBerserkerFPHandLBlood04_A | …03_A | …02_A | …01_A | black |
| FemBerserkerBloodArms (SkinArmL) | T_FemBerserkerSkinBlood04_A | T_FemBerserkerSkinBlood03_A | black | black | black |
| FemBerserkerBloodAccessories (FPGlove) | T_FemBerserkerFPGloveBlood04_A | …03_A | …02_A | …01_A | black |

The section → key mapping comes from `SK_FemBerserkerFP.CharacterMaterialMasks.PlayerHandsData`; the bracelet has key None.

### 5.2 Native logic
Static RE: own headless Ghidra project `extracted/ghidra_dani/DI2dani` (no analysis, on demand); decompiles are in `extracted/ghidra_dani/hands*.c`. Reflection is from `tools/re/di2exe.py`.

- **State.** `UPlayerHandsMaterialComponent`:
  - `BloodSettings` TMap @+232; `PlayerMaterialParams` TMap<EMeshPerspective, …> @+312;
  - `CurrentHandBloodinessValue` float @**+0x1c0**, replicated, OnRep;
  - a flow-pending flag @+0x1c4.
- **Increase.** The melee weapon's on-hit (`FUN_14170c360`), when the weapon state byte = 3 (equipped) and the target is a character class (two gameplay tags exclude a hit):
  - `inc = MeleeArchetypeData.BloodinessIncrementPerHit` (weapon +0x650 = archetype +0x400), `× 3` if the impact's `DSDamageData + 9` bool is set (**bCriticalHit**; inferred from the reflected struct layout: bFriendlyFireAllowed @8, bCriticalHit @9, bHeavyAttack @10);
  - the weapon's own bloodiness (+0x1210) += inc if < 1;
  - `AddHandBloodiness(owner.PlayerHandsMaterialComponent, inc)` (`FUN_1418138b0`): `value = clamp(value + inc, 0, 1)`; if changed, the OnRep body + net dirty.
  - **Kicks / unarmed moves do not go through this.**
- **Default.** `BloodinessIncrementPerHit` = **0.1**, from the FMeleeArchetypeData constructor `FUN_1416e4e00` (`+0x400 = 0x3dcccccd`). Its neighbours are consistent with the reflected offsets: BaseAttacksPerSecond 1.0 @0x5B8, crit multipliers 2.0, DurabilityLossPerHit 1.0 @0x5E4. **No DI2 asset overrides it** (no extracted JSON contains the name).
- **OnRep / stage select** (`FUN_14181c3b0` → `FUN_141559700` / `FUN_141af6070` / `FUN_141554fc0`), per section MID: `tex = first SortedTexturesHighestToLowest entry with RequiredScore ≤ value`. If it differs from the MID's current "Staged Blood Map": set it, set "Splatter Animation Phase" = **0**, flag the flow animation.
- **Flow animation** (TickComponent `FUN_141829950` → `FUN_14182b780`, step `FUN_141559630`):
  - For a section whose phase is 0, wait until `WorldTime − T ≥ RequiredOnScreenTimeBeforeAnimation`. T is a timestamp looked up by a fixed FName key in a map on the object at component+0x220 **[which timestamp is unverified]**; the port uses "hands visible since".
  - Then `phase = clamp(phase + dt / max(FlowAnimationDuration, 1.19e−7), 0, 1)`. The flag stays while any phase < 1.
  - So a new stage fills in over **2.25 s**, along the texture's G arrival-time channel.
- **Decay:** none over time.
- **Clean** (value → 0, `FUN_1416eaa20` / `FUN_141823630`):
  - when a weapon that has been stowed longer than **`melee.StowedTimeForClean` = 5.0 s** (CVar registered at `FUN_1404fde50`) is equipped again (`FUN_141700550`);
  - also from three weapon routines that first write weapon+0xc20 (`FUN_1416eb140/eb190/ed340`, probably durability/repair) **[purpose unverified]**.
- **Port** (`dani_visual.gd`):
  - `on_melee_hit(critical)` adds 0.1 / 0.3;
  - `_flow` and `_stow_clean` poll `player.weapon` read-only.
  - The animations session was asked to call `DaniVisual.of(p).on_melee_hit(crit)` in `player_melee._strike`. Until then hand blood only rises through the API; the test calls it.

### 5.3 UCosmeticEffect_PlayerHandMaterial / CosmeticEffectData_PlayerHandMaterial
Searching all 2,546 extracted CosmeticEffect assets finds this effect type **only in `CE_Player_Autophage`** (DIShared/Effects/CosmeticFX/Player). Its `PlayerHandsParams.MaterialParametersAssetSet` holds one `MaterialFloatParameterMap`:
- `MaterialParameterName` **ZombieVeinBlendWeight**;
- `Expression` "OverallFuryProgress";
- `bUseCustomCurve`, cubic keys (0, 0), (0.5, 1), (1, 0) with zero tangents: a smooth rise to full veins at mid-Fury and a fall back to 0.

So the hand-material effect is the **Fury (Autophage) vein pulse**. Hits, wetness and burns do not touch the FP hand material through this path. DI2's FP sections are excluded from FLESH splatter (`WriteSplatterMask`, section 1.1). Hand blood is only the staged component above.

The port drives ZombieVeinBlendWeight with `curve(1 − player.fury)` while `moves.fury_active`, else 0. **[OverallFuryProgress = elapsed fraction of Fury, unverified; Spawn/end behaviour of the CE (`UCosmeticEffect_PlayerHandMaterial::Spawn` @0x141255980) not decompiled]**.

Also present but inactive in play:
- `CutSceneHandBloodSplatter` (MPC, cutscenes) selects the MI's CutScene Blood Map (Blood04);
- `ZombieVeinsCinematic` (MPC_GameWideParams).

---------------------------------------------------------------------------------------------------------------------

## 6. Verification (`--danitest`, `game/test_out/dani/dani.log`)

- **Materials:**
  - every FP surface carries player.gdshader with the variant of its decompiled PS;
  - every used texture is bound;
  - every mapped scalar equals the JSON value: 0 mismatches.
- **Textures:** 51 loaded, BCn formats kept (17 DXT1, 19 DXT5, 21 RGTC_RG, 22 BPTC), full mip chains. The only exception is `T_DefaultCharacterVarB_ATA`, which DI2 ships as a single 4×4 mip.
- **Skin:** 8 influences on; 27,786/27,918 vertices' top-4 equal the importer's 4 (the rest are equal-weight ties).
- **Hand blood:** the log shows each stage texture picked at 0.1 / 0.4 (hits ×0.1) / 0.7 (critical ×3) / 0.8, phase 0 right after the change and 1.00 after 1 + 2.25 s. Arms stay black below 0.75, as in DI2's data. Clean returns to T_BlackMaskAlpha_A.
- **Autophage curve:** 0.5 / 1.0 / 0.5 at progress 0.25 / 0.5 / 0.75.
- **Captures:** listed in section 0, plus `05_swing_bat_*` and `06_pistol` / `07_pistol_fire`. In the FP view the pistol is off-screen (section 1.3).

---------------------------------------------------------------------------------------------------------------------

## 7. Unverified / open

1. **DI2's deferred lighting** is decoded (recon/DEFERRED_LIGHTING.md) and ported for punctual lights (section 4.5). Still open:
   - the ambient oil reflection lobe;
   - the exact 2·S' on the environment BRDF's B term;
   - cloth `sat(1 + SSAO − Cloth)`;
   - DI2's light-setup extras (near un-shadow, `DLU[9]` cone shaping, contact shadows);
   - the rect-light (LTC) path;
   - which reflection permutation runs **[CPU]**.
2. **SSS.** Godot's screen-space skin kernel stands in for DI2's Burley (FP) and separable (band) profiles. The radius is mapped, the shape is not. The Burley radius reading (MFP × WorldUnitScale) and the recombine's pixel-radius gate are unverified.
3. **Sampler state of `View` resource 0/1** (the shared material sampler most taps use). Taken as aniso trilinear wrap/clamp; the flesh session's note says "bilinear" from UE's naming. Not verified in the exe.
4. **Preshader opcodes 20/22** (section 4.4): the channel-mix normalisation. It only matters with veins on.
5. **UV1 = UV0** for the vein ATA tap on the hands. This is UE's GPU-skin rule for meshes with fewer UV channels; not checked in DI2's exe.
6. **Hand blood:**
   - the on-screen timestamp (+0x220 map key);
   - the `×3` flag identity (bCriticalHit by layout);
   - the target-class and gameplay-tag filters of the on-hit;
   - the three clean routines' purpose;
   - which section the story-state HandsVisuals swap replaces.
7. **CE_Player_Autophage:** OverallFuryProgress semantics and the CE's spawn/stop handling of the parameter.
8. **Shadow body:**
   - the third-person mesh is kept at 4 influences;
   - copying the FP local poses ignores per-mesh retarget differences;
   - the hair opacity channel is taken as .a (`T_*HairData_AAAA`) at the MI clip 0.4.
9. **Port-side** (animations session): rig attached to the camera instead of the capsule, `bRenderNearest`, pistol arms off-screen, SmartBoneDriver correctives (`SK_FemBerserkerFP` has 96 blender + 90 cone-reader + 62 bone-driven + 48 twist items, not ported here).

---------------------------------------------------------------------------------------------------------------------

## Appendix A: resolved parameters per FP section (from game/data/dani_materials.json; "default (M_x)" = master default in the effective shader map)

#### MI_FemBerserkerSkin

Chain MI_FemBerserkerSkin > MMI_PlayerHandsArms > M_Skin; master M_Skin; PS 12717 -> `skin_staged_cheapveins`; BLEND_Masked, two-sided False, clip 0.1, MSM_SubsurfaceProfile; SSP SSP_DefaultLightSkinFP; static switches: Enable Cheap Zombie Veins Effect=True, UsesCutsceneBloodSplatter=True, Enable Detail Mapping=True, Enable Splatter=True, Enable Zombie Veins Effect=True, Staged Splatter Mode=True, Use Vein Normal Map (Else Generate From Mask Height)=True, UsesZombie ModeOnCinematics=True

| Parameter | Value | Source |
|---|---|---|
| Packed ATA Map (see tooltip!) | T_FemBerserkerSkin_ATA | MI_FemBerserkerSkin |
| Normal Map | T_FemBerserkerSkin_N | MI_FemBerserkerSkin |
| Detail Normal Map | T_DefaultSkin_Detail_N | MI_FemBerserkerSkin |
| Staged Blood Map | T_BlackMaskAlpha_A | MMI_PlayerHandsArms |
| CutScene Blood Map | T_FemBerserkerSkinBlood04_A | MI_FemBerserkerSkin |
| Packed MRO Map (see tooltip!) | T_FemBerserkerSkin_MRO | MI_FemBerserkerSkin |
| Diffuse Colour Map | T_FemBerserkerSkin_D | MI_FemBerserkerSkin |
| Detail Roughness Map | T_DefaultSkin_Detail_XRX | MI_FemBerserkerSkin |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Skin) |
| Distortion Noise Speed | (-0.2, -0.2, 0, 0) | MMI_PlayerHandsArms |
| Distortion Noise Channel Mix | (2, 0, 0.1, 0.4) | MMI_PlayerHandsArms |
| Pulse Noise Speed | (-0.35, -0, 0, 0) | MMI_PlayerHandsArms |
| Pulse Noise Channel Mix | (1, 0, 0, 0) | MMI_PlayerHandsArms |
| Colour Tint | (1, 1, 1, 0) | default (M_Skin) |
| Veins Blood Colour | (0.75, 0.454687, 0.433594, 0) | MI_FemBerserkerSkin |
| Larger Veins Move Less | 0.4 | default (M_Skin) |
| Distortion Noise Scale | 0.09 | MMI_PlayerHandsArms |
| Min UV Distortion | 0.005 | MMI_PlayerHandsArms |
| Max UV Distortion | 0.01 | MMI_PlayerHandsArms |
| Pulse Noise Scale | 0.015 | MMI_PlayerHandsArms |
| Pulse Noise Range Min | 0 | MMI_PlayerHandsArms |
| Pulse Noise Range Max | 1 | MMI_PlayerHandsArms |
| Zombie Vein Skin Distort Falloff | 0.14 | default (M_Skin) |
| ZombieVeinBlendWeight | 0 | MMI_PlayerHandsArms |
| Vein Intensity Min | 0.3 | MMI_PlayerHandsArms |
| Vein Intensity Max | 1 | MMI_PlayerHandsArms |
| Distortion Noise Affects Vein Intensity | 0.3 | MMI_PlayerHandsArms |
| Zombie Vein Base Normals Distort | 0.6 | default (M_Skin) |
| Zombie Vein Base Normal Flatten Power | 0.1 | MMI_PlayerHandsArms |
| Zombie Vein Skin Distort | 1 | default (M_Skin) |
| Detail Tiling | 22 | MI_FemBerserkerSkin |
| Detail Normal Strength | 0.8 | MI_FemBerserkerSkin |
| Veins Normal Strength | 2 | MMI_PlayerHandsArms |
| Aggressive Veins Normal | 1 | default (M_Skin) |
| Vein Mask Erode | 3 | MI_FemBerserkerSkin |
| Splatter Animation Phase | 0.5 | default (M_Skin) |
| Specular Occlusion Power | 4 | MI_FemBerserkerSkin |
| StagedSplatterMetalBlendPow | 1 | default (M_Skin) |
| Desaturation | 0 | default (M_Skin) |
| Detail Roughness Strength | 3 | MMI_PlayerHandsArms |
| Roughness Adjustment | 0 | MI_FemBerserkerSkin |
| BlendWeight Normals Curve | 2.5 | MMI_PlayerHandsArms |
| Veins Blood Density | 10 | MI_FemBerserkerSkin |
| Aggressive Veins Density | 1 | default (M_Skin) |
| Vein Roughness | 0.45 | MMI_PlayerHandsArms |
| Base Subsurface Scattering | 0.9 | MMI_PlayerHandsArms |
| Vein Subsurface Scattering | 1 | MMI_PlayerHandsArms |

#### MI_FemBerserkerLowerBody

Chain MI_FemBerserkerLowerBody > M_Clothing; master M_Clothing; PS 4452 -> `cloth`; BLEND_Masked, two-sided True, clip 0.3333, MSM_Cloth; SSP -; static switches: Enable Detail Mapping=True

| Parameter | Value | Source |
|---|---|---|
| Normal Map | T_FemBerserkerLowerBody_N | MI_FemBerserkerLowerBody |
| Detail Normal Map | T_DefaultClothing_Detail_N | default (M_Clothing) |
| Packed ATA Map (see tooltip!) | T_FemBerserkerLowerBody_ATA | MI_FemBerserkerLowerBody |
| Packed MRO Map (see tooltip!) | T_FemBerserkerLowerBody_MRO | MI_FemBerserkerLowerBody |
| Diffuse Colour Map | T_FemBerserkerLowerBody_D | MI_FemBerserkerLowerBody |
| Detail DRO Map | T_DefaultClothing_Detail_XRX | default (M_Clothing) |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Clothing) |
| LargeNoiseRandomOffset | (0, 0, 0, 0) | default (M_Clothing) |
| Cloth Colour Tint | (1, 1, 1, 1) | default (M_Clothing) |
| Detail Tiling | -10.5946 | MI_FemBerserkerLowerBody |
| Detail Normal Strength | 1 | default (M_Clothing) |
| Cloth Translucency | 0.25 | default (M_Clothing) |
| Force Cloth | 0 | default (M_Clothing) |
| FuryDeathDesaturationOverride | 0 | default (M_Clothing) |
| Detail Roughness Strength | 1 | default (M_Clothing) |
| Roughness Adjustment | 0 | default (M_Clothing) |
| Sheen Colour Averaging Amount | 0.245714 | MI_FemBerserkerLowerBody |
| Sheen Colour Desaturation | 0.984762 | MI_FemBerserkerLowerBody |
| Sheen Colour Multiplier | 2.28572 | MI_FemBerserkerLowerBody |

#### MI_FemBerserkerUpperBody

Chain MI_FemBerserkerUpperBody > M_Clothing; master M_Clothing; PS 4452 -> `cloth`; BLEND_Masked, two-sided True, clip 0.3333, MSM_Cloth; SSP -; static switches: Enable Detail Mapping=True

| Parameter | Value | Source |
|---|---|---|
| Normal Map | T_FemBerserkerUpperBody_N | MI_FemBerserkerUpperBody |
| Detail Normal Map | T_DefaultClothing_Detail_N | default (M_Clothing) |
| Packed ATA Map (see tooltip!) | T_FemBerserkerUpperBody_ATA | MI_FemBerserkerUpperBody |
| Packed MRO Map (see tooltip!) | T_FemBerserkerUpperBody_MRO | MI_FemBerserkerUpperBody |
| Diffuse Colour Map | T_FemBerserkerUpperBody_D | MI_FemBerserkerUpperBody |
| Detail DRO Map | T_DefaultClothing_Detail_XRX | default (M_Clothing) |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Clothing) |
| LargeNoiseRandomOffset | (0, 0, 0, 0) | default (M_Clothing) |
| Cloth Colour Tint | (1, 1, 1, 1) | default (M_Clothing) |
| Detail Tiling | -10.5946 | MI_FemBerserkerUpperBody |
| Detail Normal Strength | 1 | default (M_Clothing) |
| Cloth Translucency | 0.25 | default (M_Clothing) |
| Force Cloth | 0 | default (M_Clothing) |
| FuryDeathDesaturationOverride | 0 | default (M_Clothing) |
| Detail Roughness Strength | 1 | default (M_Clothing) |
| Roughness Adjustment | 0 | default (M_Clothing) |
| Sheen Colour Averaging Amount | 0.245714 | MI_FemBerserkerUpperBody |
| Sheen Colour Desaturation | 0.984762 | MI_FemBerserkerUpperBody |
| Sheen Colour Multiplier | 2.28572 | MI_FemBerserkerUpperBody |

#### MI_FemBerserkerBandFP

Chain MI_FemBerserkerBandFP > M_Skin; master M_Skin; PS 5740 -> `skin`; BLEND_Masked, two-sided True, clip 0.1, MSM_SubsurfaceProfile; SSP SSP_DefaultLightSkin; static switches: none

| Parameter | Value | Source |
|---|---|---|
| Normal Map | T_FemBerserkerBandFP_N | MI_FemBerserkerBandFP |
| Detail Normal Map | T_DefaultSkin_Detail_N | default (M_Skin) |
| Packed ATA Map (see tooltip!) | T_FemBerserkerBandFP_ATA | MI_FemBerserkerBandFP |
| Packed MRO Map (see tooltip!) | T_FemBerserkerBandFP_MRO | MI_FemBerserkerBandFP |
| Diffuse Colour Map | T_FemBerserkerBandFP_D | MI_FemBerserkerBandFP |
| Detail Roughness Map | T_DefaultSkin_Detail_XRX | default (M_Skin) |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Skin) |
| LargeNoiseRandomOffset | (0, 0, 0, 0) | default (M_Skin) |
| Colour Tint | (1, 1, 1, 0) | default (M_Skin) |
| Detail Tiling | 20 | default (M_Skin) |
| Detail Normal Strength | 1 | default (M_Skin) |
| Specular Occlusion Power | 1 | default (M_Skin) |
| Desaturation | 0 | default (M_Skin) |
| Detail Roughness Strength | 1 | default (M_Skin) |
| Roughness Adjustment | 0 | default (M_Skin) |
| Translucency Adjustment | 0.07 | MI_FemBerserkerBandFP |

#### MI_FemBerserkerBandCardsFP

Chain MI_FemBerserkerBandCardsFP > M_Skin; master M_Skin; PS 5740 -> `skin`; BLEND_Masked, two-sided True, clip 0.1, MSM_SubsurfaceProfile; SSP SSP_DefaultLightSkin; static switches: none

| Parameter | Value | Source |
|---|---|---|
| Normal Map | T_JacobOutfitCardsFP_N | MI_FemBerserkerBandCardsFP |
| Detail Normal Map | T_DefaultSkin_Detail_N | default (M_Skin) |
| Packed ATA Map (see tooltip!) | T_JacobOutfitCardsFP_ATA | MI_FemBerserkerBandCardsFP |
| Packed MRO Map (see tooltip!) | T_JacobOutfitCardsFP_MRO | MI_FemBerserkerBandCardsFP |
| Diffuse Colour Map | T_JacobOutfitCardsFP_D | MI_FemBerserkerBandCardsFP |
| Detail Roughness Map | T_DefaultSkin_Detail_XRX | default (M_Skin) |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Skin) |
| LargeNoiseRandomOffset | (0, 0, 0, 0) | default (M_Skin) |
| Colour Tint | (1, 1, 1, 0) | default (M_Skin) |
| Detail Tiling | 20 | default (M_Skin) |
| Detail Normal Strength | 1 | default (M_Skin) |
| Specular Occlusion Power | 1 | default (M_Skin) |
| Desaturation | 0 | default (M_Skin) |
| Detail Roughness Strength | 1 | default (M_Skin) |
| Roughness Adjustment | 0 | default (M_Skin) |
| Translucency Adjustment | 0.15 | MI_FemBerserkerBandCardsFP |

#### MI_FemBerserkerFPHandR

Chain MI_FemBerserkerFPHandR > MMI_PlayerHandsArms > M_Skin; master M_Skin; PS 9326 -> `skin_staged_veinmap`; BLEND_Masked, two-sided False, clip 0.1, MSM_SubsurfaceProfile; SSP SSP_DefaultLightSkinFP; static switches: UsesCutsceneBloodSplatter=True, Enable Detail Mapping=True, Enable Splatter=True, Enable Zombie Veins Effect=True, Staged Splatter Mode=True, Use Vein Normal Map (Else Generate From Mask Height)=True, 01 - Use Test Skin Colour=False, Debug splatter morph thickness=False, Debug splatter texture=False, UsesZombie ModeOnCinematics=True

| Parameter | Value | Source |
|---|---|---|
| Packed ATA Map (see tooltip!) | T_FemBerserkerFPHandR_ATA | MI_FemBerserkerFPHandR |
| Normal Map | T_FemBerserkerFPHandR_N | MI_FemBerserkerFPHandR |
| Detail Normal Map | T_DefaultSkin_Detail_N | MI_FemBerserkerFPHandR |
| Zombie Veins Normal Map | T_FemBerserkerFPHandRFury_N | MI_FemBerserkerFPHandR |
| Staged Blood Map | T_BlackMaskAlpha_A | MMI_PlayerHandsArms |
| CutScene Blood Map | T_FemBerserkerFPHandRBlood04_A | MI_FemBerserkerFPHandR |
| Packed MRO Map (see tooltip!) | T_FemBerserkerFPHandR_MRO | MI_FemBerserkerFPHandR |
| Diffuse Colour Map | T_FemBerserkerFPHandR_D | MI_FemBerserkerFPHandR |
| Detail Roughness Map | T_DefaultSkin_Detail_XRX | MI_FemBerserkerFPHandR |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Skin) |
| Distortion Noise Speed | (-0.2, -0.2, 0, 0) | MMI_PlayerHandsArms |
| Distortion Noise Channel Mix | (2, 0, 0.1, 0.4) | MMI_PlayerHandsArms |
| Pulse Noise Speed | (-0.35, -0, 0, 0) | MMI_PlayerHandsArms |
| Pulse Noise Channel Mix | (1, 0, 0, 0) | MMI_PlayerHandsArms |
| Colour Tint | (1, 1, 1, 0) | default (M_Skin) |
| Veins Blood Colour | (0.8, 0.426666, 0.4, 0) | default (M_Skin) |
| Larger Veins Move Less | 0.4 | default (M_Skin) |
| Distortion Noise Scale | 0.09 | MMI_PlayerHandsArms |
| Min UV Distortion | 0.005 | MMI_PlayerHandsArms |
| Max UV Distortion | 0.01 | MMI_PlayerHandsArms |
| Pulse Noise Scale | 0.015 | MMI_PlayerHandsArms |
| Pulse Noise Range Min | 0 | MMI_PlayerHandsArms |
| Pulse Noise Range Max | 1 | MMI_PlayerHandsArms |
| Zombie Vein Skin Distort Falloff | 0.14 | default (M_Skin) |
| ZombieVeinBlendWeight | 0 | MMI_PlayerHandsArms |
| Vein Intensity Min | 0.3 | MMI_PlayerHandsArms |
| Vein Intensity Max | 1 | MMI_PlayerHandsArms |
| Distortion Noise Affects Vein Intensity | 0.3 | MMI_PlayerHandsArms |
| Zombie Vein Base Normals Distort | 0.6 | default (M_Skin) |
| Zombie Vein Skin Distort | 1 | default (M_Skin) |
| Detail Tiling | 16 | MI_FemBerserkerFPHandR |
| Detail Normal Strength | 0.5 | MI_FemBerserkerFPHandR |
| Veins Normal Strength | 2 | MI_FemBerserkerFPHandR |
| Aggressive Veins Normal | 1 | default (M_Skin) |
| Vein Mask Erode | 3 | MI_FemBerserkerFPHandR |
| Splatter Animation Phase | 0.5 | default (M_Skin) |
| Specular Occlusion Power | 1 | MI_FemBerserkerFPHandR |
| StagedSplatterMetalBlendPow | 1 | default (M_Skin) |
| Desaturation | 0 | default (M_Skin) |
| Detail Roughness Strength | 0 | MI_FemBerserkerFPHandR |
| Roughness Adjustment | 0 | MI_FemBerserkerFPHandR |
| BlendWeight Normals Curve | 2.5 | MMI_PlayerHandsArms |
| Veins Blood Density | 10 | MI_FemBerserkerFPHandR |
| Aggressive Veins Density | 1 | default (M_Skin) |
| Vein Roughness | 0.45 | MMI_PlayerHandsArms |
| Base Subsurface Scattering | 0.9 | MMI_PlayerHandsArms |
| Vein Subsurface Scattering | 1 | MMI_PlayerHandsArms |

#### MI_FemBerserkerFPBracelet

Chain MI_FemBerserkerFPBracelet > M_Clothing; master M_Clothing; PS 4452 -> `cloth`; BLEND_Masked, two-sided True, clip 0.3333, MSM_Cloth; SSP -; static switches: Enable Detail Mapping=True

| Parameter | Value | Source |
|---|---|---|
| Normal Map | T_FemBerserkerFPBracelet_N | MI_FemBerserkerFPBracelet |
| Detail Normal Map | T_DefaultClothing_Detail_N | default (M_Clothing) |
| Packed ATA Map (see tooltip!) | T_DefaultCharacterVarB_ATA | MI_FemBerserkerFPBracelet |
| Packed MRO Map (see tooltip!) | T_FemBerserkerFPBracelet_MRO | MI_FemBerserkerFPBracelet |
| Diffuse Colour Map | T_FemBerserkerFPBracelet_D | MI_FemBerserkerFPBracelet |
| Detail DRO Map | T_DefaultClothing_Detail_XRX | default (M_Clothing) |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Clothing) |
| LargeNoiseRandomOffset | (0, 0, 0, 0) | default (M_Clothing) |
| Cloth Colour Tint | (1, 1, 1, 1) | default (M_Clothing) |
| Detail Tiling | -10.5946 | MI_FemBerserkerFPBracelet |
| Detail Normal Strength | 1 | default (M_Clothing) |
| Cloth Translucency | 0.25 | default (M_Clothing) |
| Force Cloth | 0 | default (M_Clothing) |
| FuryDeathDesaturationOverride | 0 | default (M_Clothing) |
| Detail Roughness Strength | 1 | default (M_Clothing) |
| Roughness Adjustment | 0 | default (M_Clothing) |
| Sheen Colour Averaging Amount | 0.38 | MI_FemBerserkerFPBracelet |
| Sheen Colour Desaturation | 0.1 | default (M_Clothing) |
| Sheen Colour Multiplier | 1.4 | MI_FemBerserkerFPBracelet |

#### MI_FemBerserkerSkinArmL

Chain MI_FemBerserkerSkinArmL > MMI_PlayerHandsArms > M_Skin; master M_Skin; PS 12717 -> `skin_staged_cheapveins`; BLEND_Masked, two-sided False, clip 0.1, MSM_SubsurfaceProfile; SSP SSP_DefaultLightSkinFP; static switches: Enable Cheap Zombie Veins Effect=True, UsesCutsceneBloodSplatter=True, Enable Detail Mapping=True, Enable Splatter=True, Enable Zombie Veins Effect=True, Staged Splatter Mode=True, Use Vein Normal Map (Else Generate From Mask Height)=True, UsesZombie ModeOnCinematics=True

| Parameter | Value | Source |
|---|---|---|
| Packed ATA Map (see tooltip!) | T_FemBerserkerSkin_ATA | MI_FemBerserkerSkinArmL |
| Normal Map | T_FemBerserkerSkin_N | MI_FemBerserkerSkinArmL |
| Detail Normal Map | T_DefaultSkin_Detail_N | MI_FemBerserkerSkinArmL |
| Staged Blood Map | T_BlackMaskAlpha_A | MMI_PlayerHandsArms |
| CutScene Blood Map | T_FemBerserkerSkinBlood04_A | MI_FemBerserkerSkinArmL |
| Packed MRO Map (see tooltip!) | T_FemBerserkerSkin_MRO | MI_FemBerserkerSkinArmL |
| Diffuse Colour Map | T_FemBerserkerSkin_D | MI_FemBerserkerSkinArmL |
| Detail Roughness Map | T_DefaultSkin_Detail_XRX | MI_FemBerserkerSkinArmL |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Skin) |
| Distortion Noise Speed | (-0.2, -0.2, 0, 0) | MMI_PlayerHandsArms |
| Distortion Noise Channel Mix | (2, 0, 0.1, 0.4) | MMI_PlayerHandsArms |
| Pulse Noise Speed | (-0.35, -0, 0, 0) | MMI_PlayerHandsArms |
| Pulse Noise Channel Mix | (1, 0, 0, 0) | MMI_PlayerHandsArms |
| Colour Tint | (1, 1, 1, 0) | default (M_Skin) |
| Veins Blood Colour | (0.75, 0.454687, 0.433594, 0) | MI_FemBerserkerSkinArmL |
| Larger Veins Move Less | 0.4 | default (M_Skin) |
| Distortion Noise Scale | 0.09 | MMI_PlayerHandsArms |
| Min UV Distortion | 0.005 | MMI_PlayerHandsArms |
| Max UV Distortion | 0.01 | MMI_PlayerHandsArms |
| Pulse Noise Scale | 0.015 | MMI_PlayerHandsArms |
| Pulse Noise Range Min | 0 | MMI_PlayerHandsArms |
| Pulse Noise Range Max | 1 | MMI_PlayerHandsArms |
| Zombie Vein Skin Distort Falloff | 0.14 | default (M_Skin) |
| ZombieVeinBlendWeight | 0 | MMI_PlayerHandsArms |
| Vein Intensity Min | 0.3 | MMI_PlayerHandsArms |
| Vein Intensity Max | 1 | MMI_PlayerHandsArms |
| Distortion Noise Affects Vein Intensity | 0.3 | MMI_PlayerHandsArms |
| Zombie Vein Base Normals Distort | 0.6 | default (M_Skin) |
| Zombie Vein Base Normal Flatten Power | 0.1 | MMI_PlayerHandsArms |
| Zombie Vein Skin Distort | 1 | default (M_Skin) |
| Detail Tiling | 22 | MI_FemBerserkerSkinArmL |
| Detail Normal Strength | 0.8 | MI_FemBerserkerSkinArmL |
| Veins Normal Strength | 2 | MMI_PlayerHandsArms |
| Aggressive Veins Normal | 1 | default (M_Skin) |
| Vein Mask Erode | 3 | MI_FemBerserkerSkinArmL |
| Splatter Animation Phase | 0.5 | default (M_Skin) |
| Specular Occlusion Power | 4 | MI_FemBerserkerSkinArmL |
| StagedSplatterMetalBlendPow | 1 | default (M_Skin) |
| Desaturation | 0 | default (M_Skin) |
| Detail Roughness Strength | 3 | MMI_PlayerHandsArms |
| Roughness Adjustment | 0 | MI_FemBerserkerSkinArmL |
| BlendWeight Normals Curve | 2.5 | MMI_PlayerHandsArms |
| Veins Blood Density | 10 | MI_FemBerserkerSkinArmL |
| Aggressive Veins Density | 1 | default (M_Skin) |
| Vein Roughness | 0.45 | MMI_PlayerHandsArms |
| Base Subsurface Scattering | 0.9 | MMI_PlayerHandsArms |
| Vein Subsurface Scattering | 1 | MMI_PlayerHandsArms |

#### MI_FemBerserkerFPGlove

Chain MI_FemBerserkerFPGlove > M_Clothing; master M_Clothing; PS 9445 -> `cloth_staged`; BLEND_Masked, two-sided True, clip 0.3333, MSM_Cloth; SSP -; static switches: Enable Detail Mapping=True, Enable Splatter (Characters Only!)=True, Staged Splatter Mode=True

| Parameter | Value | Source |
|---|---|---|
| Normal Map | T_FemBerserkerFPGlove_N | MI_FemBerserkerFPGlove |
| Detail Normal Map | T_DefaultClothing_Detail_N | default (M_Clothing) |
| Packed ATA Map (see tooltip!) | T_FemBerserkerFPGlove_ATA | MI_FemBerserkerFPGlove |
| Staged Blood Map | T_BlackMaskAlpha_A | default (M_Clothing) |
| CutScene Blood Map | T_BlackMaskAlpha_A | default (M_Clothing) |
| Packed MRO Map (see tooltip!) | T_FemBerserkerFPGlove_MRO | MI_FemBerserkerFPGlove |
| Diffuse Colour Map | T_FemBerserkerFPGlove_D | MI_FemBerserkerFPGlove |
| Detail DRO Map | T_DefaultClothing_Detail_XRX | default (M_Clothing) |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Clothing) |
| Cloth Colour Tint | (1, 1, 1, 1) | default (M_Clothing) |
| Detail Tiling | -10.5946 | MI_FemBerserkerFPGlove |
| Detail Normal Strength | 1 | default (M_Clothing) |
| Splatter Animation Phase | 0.5 | default (M_Clothing) |
| Cloth Translucency | 0.25 | default (M_Clothing) |
| Force Cloth | 0 | default (M_Clothing) |
| StagedSplatterMetalBlendPow | 1 | default (M_Clothing) |
| Detail Roughness Strength | 1 | default (M_Clothing) |
| Roughness Adjustment | 0 | default (M_Clothing) |
| Sheen Colour Averaging Amount | 0.38 | MI_FemBerserkerFPGlove |
| Sheen Colour Desaturation | 0.1 | default (M_Clothing) |
| Sheen Colour Multiplier | 1.4 | MI_FemBerserkerFPGlove |

#### MI_FemBerserkerFPHandL

Chain MI_FemBerserkerFPHandL > MMI_PlayerHandsArms > M_Skin; master M_Skin; PS 9326 -> `skin_staged_veinmap`; BLEND_Masked, two-sided False, clip 0.1, MSM_SubsurfaceProfile; SSP SSP_DefaultLightSkinFP; static switches: UsesCutsceneBloodSplatter=True, Enable Detail Mapping=True, Enable Splatter=True, Enable Zombie Veins Effect=True, Staged Splatter Mode=True, Use Vein Normal Map (Else Generate From Mask Height)=True, Debug splatter morph thickness=False, Debug splatter texture=False, UsesZombie ModeOnCinematics=True

| Parameter | Value | Source |
|---|---|---|
| Packed ATA Map (see tooltip!) | T_FemBerserkerFPHandL_ATA | MI_FemBerserkerFPHandL |
| Normal Map | T_FemBerserkerFPHandL_N | MI_FemBerserkerFPHandL |
| Detail Normal Map | T_DefaultSkin_Detail_N | MI_FemBerserkerFPHandL |
| Zombie Veins Normal Map | T_FemBerserkerFPHandRFury_N | MI_FemBerserkerFPHandL |
| Staged Blood Map | T_BlackMaskAlpha_A | MMI_PlayerHandsArms |
| CutScene Blood Map | T_FemBerserkerFPHandRBlood04_A | MI_FemBerserkerFPHandL |
| Packed MRO Map (see tooltip!) | T_FemBerserkerFPHandL_MRO | MI_FemBerserkerFPHandL |
| Diffuse Colour Map | T_FemBerserkerFPHandL_D | MI_FemBerserkerFPHandL |
| Detail Roughness Map | T_DefaultSkin_Detail_XRX | MI_FemBerserkerFPHandL |
| const TV_Global3dNoise | TV_Global3dNoise | default (M_Skin) |
| Distortion Noise Speed | (-0.2, -0.2, 0, 0) | MMI_PlayerHandsArms |
| Distortion Noise Channel Mix | (2, 0, 0.1, 0.4) | MMI_PlayerHandsArms |
| Pulse Noise Speed | (-0.35, -0, 0, 0) | MMI_PlayerHandsArms |
| Pulse Noise Channel Mix | (1, 0, 0, 0) | MMI_PlayerHandsArms |
| Colour Tint | (1, 1, 1, 0) | default (M_Skin) |
| Veins Blood Colour | (0.8, 0.426666, 0.4, 0) | default (M_Skin) |
| Larger Veins Move Less | 0.4 | default (M_Skin) |
| Distortion Noise Scale | 0.09 | MMI_PlayerHandsArms |
| Min UV Distortion | 0.005 | MMI_PlayerHandsArms |
| Max UV Distortion | 0.01 | MMI_PlayerHandsArms |
| Pulse Noise Scale | 0.015 | MMI_PlayerHandsArms |
| Pulse Noise Range Min | 0 | MMI_PlayerHandsArms |
| Pulse Noise Range Max | 1 | MMI_PlayerHandsArms |
| Zombie Vein Skin Distort Falloff | 0.14 | default (M_Skin) |
| ZombieVeinBlendWeight | 0 | MMI_PlayerHandsArms |
| Vein Intensity Min | 0.3 | MMI_PlayerHandsArms |
| Vein Intensity Max | 1 | MMI_PlayerHandsArms |
| Distortion Noise Affects Vein Intensity | 0.3 | MMI_PlayerHandsArms |
| Zombie Vein Base Normals Distort | 0.6 | default (M_Skin) |
| Zombie Vein Skin Distort | 1 | default (M_Skin) |
| Detail Tiling | 20 | MI_FemBerserkerFPHandL |
| Detail Normal Strength | 1 | MI_FemBerserkerFPHandL |
| Veins Normal Strength | 2 | MI_FemBerserkerFPHandL |
| Aggressive Veins Normal | 1 | default (M_Skin) |
| Vein Mask Erode | 3 | MI_FemBerserkerFPHandL |
| Splatter Animation Phase | 0.5 | default (M_Skin) |
| Specular Occlusion Power | 1 | MI_FemBerserkerFPHandL |
| StagedSplatterMetalBlendPow | 1 | default (M_Skin) |
| Desaturation | 0 | default (M_Skin) |
| Detail Roughness Strength | 1 | MI_FemBerserkerFPHandL |
| Roughness Adjustment | 0 | MI_FemBerserkerFPHandL |
| BlendWeight Normals Curve | 2.5 | MMI_PlayerHandsArms |
| Veins Blood Density | 10 | MI_FemBerserkerFPHandL |
| Aggressive Veins Density | 1 | default (M_Skin) |
| Vein Roughness | 0.45 | MMI_PlayerHandsArms |
| Base Subsurface Scattering | 0.9 | MMI_PlayerHandsArms |
| Vein Subsurface Scattering | 1 | MMI_PlayerHandsArms |

