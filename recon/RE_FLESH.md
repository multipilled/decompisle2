# DI2 FLESH: native code (static RE of the shipping exe)

> **Hand-off (gore-gaps session, 2026-10-09).** Board milestone 4 (damage model) work, item by item:
> 1. **Prewarm** done: main.gd prewarms hit_effects.json CEs + body_proxies propagation CEs + CE_StatusEffect_Electrocute.
> 2. **Hitboxes** done: no BoneAttachment3Ds; zombie.gd caches the 17 hitbox bone poses at `skeleton_updated` (the
>    post-modifier pose; a later `get_bone_global_pose` returns the pre-modifier pose, 30 cm off at the arm) and pushes
>    them to the areas only in `Zombie.sync_hitboxes()`, called before every Util.HITBOX query (player*.gd, autotest.gd).
>    A probe matched a BoneAttachment3D exactly. perf_check (8 zombies, arena), legacy (`--legacy-hitboxes`) →
>    on-demand: idle physics 5.64 → 5.18 ms (4.96 in another run), process 12.36 → 11.39 ms. The combat suite's logs
>    are not deterministic run-to-run (~40 differing lines within one mode), so they can't prove bit-identical hits.
> 3. **Weakened / Disoriented** done (gore-core status.rs, RE_ACCUMULATING.md "Weakened and Disoriented"; flesh-suite
>    `debuff_check`: ×1.300 physical damage, Disoriented 5 s × U[0.85,1.15] with the AI owner's StopActions hook).
>    The ModifiableValue combine is decoded (exe 0x141aadf70). Bleed is Physical in DI2.
> 4. **Modifier CEs** blocked (RE_ACCUMULATING.md "Modifier CEs"): the only reader is 0x14140c4a0; it spawns the CE on
>    the actor in the weak pointer at +0x148. Which actor (victim vs owner) needs Ghidra auto-analysis of the virtual callers.
> 5. **Corpse impulse / kicks** partly traced (UNVERIFIED #53): FImpactSettings defaults (Construct 0x141cbec50)
>    WorldSpaceImpulseMagnitude 2000 / PhysicalizedReactionMagnitude 0, ranged overrides; the corpse path is
>    ApplyFlinchImpulse Execute 0x14125a670 (strength +0x50 × vector +0x54, curve at the strength); its input struct is
>    #H20 (hit-react owner). Kicks still skip corpses (player_moves.gd, unowned; DI2's native kick query not read).
> 6. **Ragdoll victim point** partly traced (RE_EXPLOSIONS.md §2, UNVERIFIED #51): state machine 0x141285320,
>    getter 0x141270e60; what state 4 means (+0x91D / +0x91E) is open, so the bounds centre stays.
> 7. **Fluids** (drips, overflow / flow, burst grid #25) not started.
> Tools: tools/re_gore/ (own headless Ghidra project extracted/ghidra_gore, `decomp.sh`; capstone scanners for native
> tables, field reads, vtable slots, struct ops ctors). A fresh session should take 4 + 5 + 6 together (all virtual-call
> tracing, best with a Ghidra auto-analysed copy), then 7.


Static analysis only, of `DeadIsland-Win64-Shipping.exe` (Steam build 25629748). The game is never run. Tools:
- `tools/re/di2exe.py`: PE, reflection tables, `.pdata`, call and RIP scans.
- `tools/re/DecompileAt.java`: Ghidra 12.1.4 headless, project `extracted/ghidra/DI2`, no auto-analysis.

Decompiled C is in `extracted/ghidra/decomp_*.c`. These are personal research notes; addresses are for re-finding code locally.

## Reflection layouts (UE 4.27 compiled params)

| struct / class | field offsets |
|---|---|
| FSplatterMeshInfo | DiffuseDecalTexture 0, DisplacementDecalTexture 8, InternalDisplacementDecalTexture 16, SoftUpdatePrims 24, UVScale 40, DisplacementScale 44, FluidSplatterAmount 48, BruisingAmount 52, FluidDripsAmount 56, CauterisationAmount 60, DepthScale 64, DepthFadeStart 68, AngleWrap 72, TextureInfluence 76, ClothingDisplacementScale 80, ClothingDepthScale 84, DisplacementClearValue 88, BoneIndex 92, MaterialID 96, SplatterType 100 (u8), Rupture* 104..140, MaximumRuptureCount 144, ClothingInteraction 148, RuptureInteraction 149, DecorationID 152, bools from 156 |
| FSplatterModifiers | DamageToScaleRange 0 (4 floats: out min, out max, in min, in max), HealthRemainingToScaleCurve 16, HitsToDeathToScaleCurve 24, HealthRemainingtToStrengthCurve 32, HitsToDeathToStrengthCurve 40, ...RuptureLimit 48/56, ...RuptureDepth 64/72, ...RuptureRadius 80/88, ...RuptureCount 96/104, MaxBlendThreshold 112, HitsToDeathMaxBlendThreshold 116, UVScaleVariation 120, AlignmentAngle 124, AlignmentVariation 128, DepthVariation 132, bApplyStrengthVariationToTextureInfluence 136, AlternateWoundTextures 144, AlternateSecondaryTextures 160 |
| UCosmeticEffect_SplatterMesh | SplatterMeshInfo 56, SplatterModifiers 224, bApplySplatterUsingFlippedRotation 0x190, bAlignToWorldUp 0x191, Duration 404, EffecsScaleCurve 408, bEffectsScaleCurveWithAbsoluteTime 0x1A0, ApplyDifferences 420, ApplyThreshold 424 |
| FHitEffectCosmeticEffect | Definition 0, DirectionInterpolationFactor 8 |

**ESplatterType values:**

| Name | Value | Name | Value |
|---|---|---|---|
| None | 0 | ApplyMin | 16 |
| Decal | 1 | MinDecal | 17 |
| Dismember | 2 | ApplyMax | 32 |
| DismemberWithDecal | 3 | MaxDecal | 33 |
| SoftInfluenceUpdate | 4 | ClearToValue | 64 |
| BoneBreak | 8 | ClearSplatter / ClearAll | 80 |
| BoneBreakWithDecal | 9 | RequiresSplatter | 81 |
|  |  | RequiresMeshEdit | 138 |

**Other enums:**
- **ESplatterClothingInteraction:** Default 0, ClothOnly 1, ClothNever 2.
- **ESplatterRuptureInteraction:** Default 0, NoRupture 1, RuptureOnly 2.

## Native defaults (constructors)

**FSplatterMeshInfo** (`0x140a1cdb0`):

| Field | Default |
|---|---|
| UVScale | **10** |
| DisplacementScale | 1 |
| FluidSplatterAmount | 1 |
| BruisingAmount | 1 |
| FluidDripsAmount | 1 |
| CauterisationAmount | 1 |
| DepthScale | 10 |
| DepthFadeStart | 0.35 |
| AngleWrap | 1 |
| TextureInfluence | 1 |
| ClothingDisplacementScale | 1 |
| ClothingDepthScale | 1 |
| DisplacementClearValue | 0 |
| BoneIndex | −1 |
| MaterialID | −1 |
| SplatterType | Decal (1) |
| RuptureDamageMultiplier | 1 |
| RuptureDamageOffset | 0 |
| RuptureRadiusMultiplier | 0.25 |
| RuptureRadiusOffset | 0 |
| RuptureFalloffFactor | 1 |
| RuptureDepthMultiplier | 1 |
| RuptureDepthOffset | 0 |
| RuptureLimitFraction | 1 |
| InputMinimum | 0 |
| InputRange | 1 |
| MaximumRuptureCount | 1 |
| ClothingInteraction | Default |
| RuptureInteraction | Default |

The bool at +157 is set to 1 (likely `bAbsoluteDeformation`).

**UCosmeticEffect_SplatterMesh** (`0x141b9fab0`):

| Field | Default |
|---|---|
| DamageToScaleRange | {1, 1, 0, 100} (out min = out max, so no effect) |
| MaxBlendThreshold | **1.0** |
| HitsToDeathMaxBlendThreshold | **0.0** |
| Variations, AlignmentAngle | 0 |
| **bApplySplatterUsingFlippedRotation** | **true** |
| bAlignToWorldUp | false |
| Duration | 0 |
| ApplyDifferences | 1.0 |
| ApplyThreshold | 0.004 |

## Hit facts (`0x14123f640`, copied with a bonus by `0x14124ebd0`)

- `DamageAsFractionOfMaxHealth` = damage / maxHealth, plus the `SplatterScaleBonus` fact when the copier adds it.
- `HealthRemainingAsFractionOfMaxHealth` = (health before the hit − damage) / maxHealth. This is health after the hit and is **not clamped**, so it goes negative on overkill.
- Also carried: `SourceObjectAlignment` (vector) and `SweepDirection` (vector).

## UCosmeticEffect_SplatterMesh::Spawn (`0x141255bf0`)

1. Reads the hit's KB facts.
2. `rot = Orient(Modifiers, spawnRotation.Forward, SourceObjectAlignment, SweepDirection, bFlipped, bAlignToWorldUp)`.
3. If `Duration <= 0`: `Apply(location, rot, damage% = DamageFraction × 100, HealthRemaining, animFraction = 1, boneIndex)`.
4. Otherwise it creates an animated splatter: Duration with EffecsScaleCurve, location in component space.

### Orient (`0x141238ae0`)

- **No sweep frame** when AlignmentVariation ≥ 180, or SourceObjectAlignment ≈ 0, or SweepDirection ≈ 0: `X = flipped ? -dir : dir`, and the rotation is X's rotator (roll 0).
- **Sweep frame** otherwise:
  1. `n = normalize(Sweep × Alignment)`.
  2. If `|n · dir|` ≥ a threshold, use `n = normalize(Sweep × dir)` instead.
  3. `Y = dir × n`, flipped if `Y · Sweep < 0`.
  4. `X = flipped ? -dir : dir`; rotation = MakeFromXY(X, Y).
- `Roll += rand[-1,1] × AlignmentVariation + AlignmentAngle` (degrees).
- **bAlignToWorldUp:** keep X; `Y = normalize(Up × X)`; `Z = normalize(X × Y)`, which is world up projected off X. This replaces the roll.

### Apply (`0x141258560`)

1. `info = Modify(Modifiers, SplatterMeshInfo, damage%, health)`.
2. If animFraction < 1, multiply DisplacementScale, FluidSplatter, Bruising, FluidDrips and Cauterisation by animFraction.
3. Pass the result to `USplatterMeshComponent::SplatterDecal` (`0x140a161a0`).

### Modify (`0x141245180`)

`h` = HealthRemaining and `d%` = damage% (damage fraction × 100).

1. **DamageToScaleRange:** if out min ≠ out max, `UVScale *= lerp(outMin, outMax, clamp((d% - inMin) / (inMax - inMin), 0, 1))`.
2. **Hits to death:** `htd = (100 / d%) × h`, i.e. HealthRemaining / DamageFraction.
3. **Blend mode:** if `h > MaxBlendThreshold && htd > HitsToDeathMaxBlendThreshold && SplatterType == Decal`, set `SplatterType = MaxDecal`. Far from death, wounds max-blend; near death, they accumulate.
4. **Progressive curves:** each pair is evaluated as `C_H(h) + C_HTD(htd)`; a missing curve contributes 0. A pair applies only if at least one of its curves exists.
   - Scale: `UVScale *= sum`.
   - Strength: `DisplacementScale *= sum`, `RuptureDamageMultiplier *= sum`, and `TextureInfluence *= sum` if `bApplyStrengthVariationToTextureInfluence`.
   - RuptureLimit: `RuptureLimitFraction = sum`.
   - RuptureDepth: `RuptureDepthMultiplier *= sum`.
   - RuptureRadius: `RuptureRadiusMultiplier *= sum`.
   - RuptureCount: `MaximumRuptureCount = round(sum)`.
5. **Variations:** `UVScale += rand[-1,1] × UVScaleVariation`; `DepthScale += rand[-1,1] × DepthVariation`.
6. **Alternate textures:** AlternateWoundTextures picks a random DisplacementDecalTexture; AlternateSecondaryTextures picks a random DiffuseDecalTexture.

Early out (copy unchanged): no range, no curves, MaxBlendThreshold ≥ 1, both variations 0, no alternates.

## Hit-effect spawn transform (dispatch `0x1415485f0`, spawn loop `0x141556dd0`)

Traced end to end; ported in `game/scripts/hit_effect_spawn.gd` (HitEffectSpawn).

- **Gather:** the tree's leaf nodes are `UConditionalTreeNode_CosmeticEffect` subclasses. Their last virtual
  (slot 0x238) appends `{Definition, DirectionInterpolationFactor}` (16 bytes) to the output:
  - Plain node `0x141493f00`: factor 0.
  - HitEffectCosmeticEffect `0x141494260`: factor at +0x48, constructor default 0 (`0x141b88750`).
  - Multi `0x141494340`: assigns its own array. `FHitEffectCosmeticEffect`'s struct-ops Construct
    (`0x140cd4a70`) zero-fills it, so a missing factor is 0.
  - DamageCauser `0x141493f60` and MaterialGrid `0x1414942c0`.
- **Dispatch** `0x1415485f0(component, impact)`:
  1. It takes each tree from the impact's overrides first (+0x48 / +0x50 / +0x58), else from the HitEffectsComponent (+0xE8 attacker, +0xF0 victim, +0xF8 environment).
  2. It runs the spawn loop for the attacker and the victim.
- **Spawn loop** `0x141556dd0(component, impact, tree, actor, attachComponent, facts)`:
  1. `effects = Evaluate(tree)` (`0x141490cc0`).
  2. `impact->+0x38(&location, &rotation, &bone)`.
  3. For each effect: `impact->+0x40(effect, &rotation)`, then `UCosmeticEffectsComponent` spawn (`0x140ccd260`), attached to the component at the bone. Without an attach component it spawns at a world location (`0x140ccdf20`).
- **Impact types** are reflected as the `{Point, Radial, General}ImpactEvent` RPCs. Each has a 9-slot vtable:

| type | vtable | +0x38 location / rotation | +0x40 per effect |
|---|---|---|---|
| Point (melee, ranged, kicks) | `0x1450daff8` | HitInfo.ImpactPoint (+0x260+0x1C), bone from HitInfo; rotation untouched | `0x1410a8c90` → `0x1414810b0(effect, HitInfo, HitFromDirection)` |
| Radial (explosions) | `0x14518e7f0` | root component location; `(location - Origin).Rotation()` | none (factor unused) |
| General | `0x14518e7a8` | root component location; rotation zero | none |

- **Point impact fields** (reflection): HitFromDirection +0x250, HitInfo (FHitResult) +0x260.
- **Radial impact fields:** Origin +0x250, Strength +0x25C, Radius +0x260, Falloff +0x264, ComponentHits +0x268, DamagedComponents +0x278.
- **Melee** (`0x1410ab130`): `HitFromDirection = normalize(HitInfo.TraceEnd - HitInfo.TraceStart)`, the sweep travel from attacker to victim. It lands at request +0x270 next to HitInfo +0x280 (`0x14109db40`).
- **MakePointImpactDamageParams** (BP) passes its HitFromDirection argument straight through. The native caller `0x1416a61e0` passes ZeroVector.
- **`0x1414810b0`**, with N = ImpactNormal (FHitResult +0x34), D = HitFromDirection and f = the effect's factor:
  - **No direction:** if D is null or |D|² ≤ 0, `rot = N.Rotation()` (roll 0).
  - Otherwise:
    1. `q = N.ToOrientationQuat()` (`0x141f2fa50`).
    2. If f > 0: `q = normalize(Slerp_NotNormalized(q, D.ToOrientationQuat(), f))` (`0x141f2f300`).
    3. If f < 1: let X = q's X axis and C = D × X. If |C|² > 1e-4, set `q = FindBetweenNormals(q's Y axis, normalize(C)) * q` (`0x141f27c40`). This re-rolls q about X so that Y = normalize(D × X).
    4. `rot = q.Rotator()`.
  - So factor 0 faces the outward normal, rolled to the travel direction. Factor 1 faces the travel direction (away from the attacker), roll 0.
- **Data, consistent with the above:**
  - Every bullet CE and most sharp CEs use factor 1, so they follow the shot / swing.
  - Blunt bursts use 0.9.
  - 262 of 270 splatter CEs use factor 0: Orient X flipped = -dir, and decal +Z = -Orient X points out of the surface.
  - The 8 explosion splatters at factor 1 are radial, where the factor is never read.
- The earlier reading ("factor 1 = toward the attacker") was wrong in sign. The particle port's `ce_rotation` still uses it, which is why hits spawn through HitEffectSpawn.

## Still open

- **USplatterMeshComponent::SplatterDecal and the Splatter shaders:** how info becomes the render-target write (projection box, UVs, channels, Max / Add blend). The `flesh-shaders` session covers the shaders.
- ~~Duration / EffecsScaleCurve animation path~~: traced, see "Animated splatter" below.

## Animated splatter (Spawn's `Duration > 0` branch, tick `0x141259120`)

**Spawn:** creates an instance object (class from `0x141b9e220`) that stores:

| Offset | Contents |
|---|---|
| +0x40 | the CE |
| +0x60 / +0x68 / +0x70 | weak refs to the target mesh, the splatter component and the attach parent |
| +0x78 | the bone |
| +0x80..+0x88 | the location relative to the bone |
| +0x90..+0x9C | the rotation relative to the bone (quaternion, from the Orient result) |
| +0xA0 | damage % |
| +0xA4 | HealthRemaining |
| +0xB0 | bone index |

Nothing is applied at spawn.

**Tick (`param_3` = dt):**
```
t += dt                                    (+0xA8)
f = t / Duration
s = EffecsScaleCurve ? Curve.Eval(bEffectsScaleCurveWithAbsoluteTime ? t : min(f, 1)) : min(f, 1)
a = ((s - prev) - s) * ApplyDifferences + s        // = s - prev * ApplyDifferences   (prev at +0xAC)
if ((a <= 0 || a < ApplyThreshold) && t < Duration) return          // prev is NOT updated
xf = bone transform * stored relative location / rotation
Apply(CE, mesh, splatterComponent, xf, damage%, HealthRemaining, animFraction = a, boneIndex)
prev = s
if (t >= Duration) destroy instance                 // the last tick applies even when a <= 0
```
- **Apply** re-runs Modify every time, so the random variations are re-rolled per application.
- With animFraction < 1, it scales DisplacementScale, FluidSplatter, Bruising, FluidDrips and Cauterisation by animFraction.

**Data:** 162 of the 381 SplatterMesh entries have a Duration.
- 130 are Decal with ApplyDifferences 1. The applied increments telescope to s at the last application, and the final tick lands exactly on s(Duration). For example, `Curve_SharpSplatter_Dripping` runs 1 → 0.3: full at once, then a -0.7 application at the end.
- 32 are MaxDecal with ApplyDifferences 0. Each application is the full s, max-blended: the running max of s.

## Batch packing (answers to SHADERS_FLESH.md §10)

Sources: `extracted/ghidra/splatter_all.c` (all 426 Splatter plugin functions, `0x1409e8000`–`0x140a1c000`).

### Pending decal (component list, 0x2E0 bytes each)

`SplatterDecal` (`0x140a161a0`) copies the FSplatterMeshInfo into a pending decal:

| Offset | Field |
|---|---|
| +0x20 | UVScale |
| +0x24 | DisplacementScale |
| +0x28 | FluidSplatterAmount |
| +0x2C | BruisingAmount |
| +0x30 | FluidDripsAmount |
| +0x34 | CauterisationAmount |
| +0x38 | DepthScale |
| +0x3C | DepthFadeStart |
| +0x40 | AngleWrap |
| +0x44 | TextureInfluence |
| +0x48 | ClothingDisplacementScale |
| +0x4C | ClothingDepthScale |
| +0x50 | DisplacementClearValue |
| +0x54 | InputMinimum |
| +0x58 | InputRange |
| +0x5C | BoneIndex |
| +0x64 | SplatterType |
| +0x65 | ClothingInteraction |
| +0x70 | bReferencePose |
| +0x72 | bAbsoluteDeformation |
| +0x73 | bSubtractive |
| +0x75 | bInvertSplatter |
| +0x76 | bUVSpaceSplatter |
| +0x80 | decal frame (4×4) |

FSplatterMeshInfo bool bytes, from the SetBit functions: `bReferencePose` 0x9C, `bAbsoluteDeformation` 0x9D, `bSubtractive` 0x9E, `bInvertSplatter` 0x9F, `bUVSpaceSplatter` 0xA0, `bIgnoreRulesets` 0x96.

### DecalMatrix

- **Frame.** The rotation matrix `R` comes from Orient's rotator. The decal→world rows are:
  - row0 = `R.Y`
  - row1 = `-R.Z`
  - row2 = `-R.X`
  - row3 = the impact location

  So decal **+u = Orient Y** (the sweep), **+v = −Orient Z**, and **decal +Z = −Orient X**, which points out of the surface when flipped.
- **Scale and inverse.** `0x140a1af60` (pending-decal processing) scales row0 and row1 by **UVScale × 0.5**, then inverts the matrix (`FUN_140a0f420`) into `DecalMatrix`.
  - The box is therefore UVScale wide, with a depth half-extent of 1/ScaleVec.z = **DepthScale cm**, symmetric about the impact plane.
  - With `bUVSpaceSplatter`, the matrix becomes diag(1/UVScale).

### Per element, per mesh section

Built by `FUN_1409fe910` (PS) and `FUN_1409f9190` (deform CS); `0x140a0db30` is the section-aware ScaleVec.

| Constant | Packing |
|---|---|
| ScaleVec | (1 / clamp(1 − DepthFadeStart, 1e-4, 1), DisplacementScale·[ClothingDisplacementScale on cloth sections], ±1 / max(DepthScale·[ClothingDepthScale on cloth], 0.001) (− when SplatterType & ApplyMin 16), clamp(AngleWrap, 0, 1)·(−1 when SplatterType & ApplyMax 32)) |
| WoundScale | (DisplacementScale′·TI, FluidSplatterAmount·TI, BruisingAmount·TI, bAbsoluteDeformation ? TI : 0), where TI = TextureInfluence; G, B and W are zeroed when the pass flag param_9 is set |
| FXScale | (FluidDripsAmount·TI, CauterisationAmount·TI, TI, TI) |
| RangeParams | (InputMinimum, InputRange) |
| DeformParams | (bAbsoluteDeformation ? 1 : 0, bSubtractive ? −1 : +1) |

### ClothingInteraction

Applied per mesh section: ClothOnly on a non-cloth section, or ClothNever on a cloth section, swaps that section's displacement texture for the engine default (blank). The diffuse (decal) texture still applies.

## Port notes (how the recreation runs the above)

- **Render targets.** Every stamp application is baked into per-section UV0 targets (RGBA8, 512², UNVERIFIED #45), exactly as §3.3 / §3.6 / §3.7 of SHADERS_FLESH.md: element math, ADD for Decal / ApplyMin and MAX for ApplyMax, saturation, coverage alpha, then one H + V dilation.
  - **GPU, the default.** `game/shaders/compute/splatter_apply.glsl` runs one invocation per covered texel, and `splatter_dilate.glsl` ping-pongs through a scratch pair. Both are dispatched once per frame by `rust/gore-godot/src/gpu_bake.rs`, and the materials sample the storage textures through Texture2DRD. Measured: about 0.04 ms of CPU per application, against 2 to 10 ms for the CPU bake.
  - **CPU fallback,** used when there is no RenderingDevice: `gore-core/src/splatter_rt.rs`, which has the same math and is unit-tested.
  - Each section's texel map (bind-pose position, normal and |deform| per UV0 texel) is rasterised once per mesh and shared across bodies; on the GPU it is a storage buffer.
  - Materials sample the targets (`flesh_splatter.gdshaderinc`): shells use their skin twin's targets, and eyes, the eye overlay and hair use the head's at UV1.
- **Projection space.** Hit stamps use DI2's default World projection (bReferencePose is false in all data). `GoreBody.add_stamp_posed` carries the rest-space frame to the world through the hit bone. The body's skin and cloth sections are skinned once per frame on the CPU, and both the GPU bake (posed vertex buffer, texel barycentrics) and the deform CS evaluate the stamp against those vertices. Stored SplatterSets stay in bind pose.
- **Deform stream.** The stream is in glb vertex order and Godot's importer reorders vertices, so GoreBody remaps it by bit-exact position, read from the glb's own POSITION accessors.
- **Animated splatter.** `flesh.gd` SplatterAnimator runs the tick above, re-running Modify for every application.
