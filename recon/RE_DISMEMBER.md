# DI2 FLESH: mesh-edit splatter passes (dismember, bone break, soft influence, rupture, clears)

Static analysis only, of `DeadIsland-Win64-Shipping.exe` (Steam build 25629748) and the shipping global shader cache. The game is never run.

Tools (all mine, in `tools/re_dismember/`):
- `decomp.sh` + `DismemberDecompileAt.java`: Ghidra 12.1.4 headless, own project `extracted/ghidra_dismember/DI2dis`, no auto-analysis. Decompiled C lands in `extracted/ghidra_dismember/*.c`.
- `fn.py`, `callers.py`, `xref_addr.py`, `xref_strings.py`, `wstr.py`, `disasm.py`, `disp_scan.py`, `rtti.py`: lookups over the exe. They are built on `tools/re/di2exe.py` (imported, not edited) and capstone.
- `refl.py`, `boolofs.py`, `structparams.py`, `propscan.py`: UE4.27 reflection layouts. `boolofs.py` decodes native-bool offsets from their SetBit functions. `propscan.py` finds a reflected owner from field offsets.
- `storescan.py`: finds functions that store to a given set of field offsets.
- `params.py` (miniconda python): exact cbuffer/register bindings of the Splatter compute shaders, read from the frozen global shader map. `shdis.py`: fxc + 3Dmigoto decompiles into `extracted/ghidra_dismember/shaders/`. Both reuse `tools/shaders/` read-only.
- `blendstate.py`: decodes the static blend states the clear pass uses.
- `meshedit_data.py`, `masks_dump.py`: data surveys of the extracted JSON.
- **`dismember_ref.py`: a literal Python transcription of every algorithm below.** The port should mirror it. `--selftest` runs it on the Walker.

These are personal research notes. Addresses are for re-finding code locally. Companion docs:
- `recon/RE_FLESH.md`: SplatterDecal, Orient, Modify, batch packing.
- `recon/SHADERS_FLESH.md`: projection PS, RT channels, deform CS.
- `recon/DEFORM_STREAM.md`: per-vertex deform stream.

---------------------------------------------------------------------------------------------------------------------

## 0. Summary

| Type (value) | What DI2 does | Where |
|---|---|---|
| **Dismember (2)** | Rebuilds the section index buffers on the GPU. **No geometry is split.** Each triangle is classified as **body** (kept at the front of the section's index range), **limb** (packed at the end of the range) or **dropped** (it straddles the cut inside the safe region). The cut plane comes from region **sockets** on the mesh (`<bone>_safe_region[_N]`) and is fitted to an elliptic cylinder. Skin weights and a per-bone topology (depth, branch mask) decide which triangles belong to the limb. A `DismemberedLimbActor` is spawned separately. | §5, §6 |
| **DismemberWithDecal (3)** | Dismember, plus a wound stamp at the fitted cut. The stamp uses **bind pose and radial projection**: a cylindrical band of height UVScale around the safe-region axis, in both the RT pass and the vertex-depth pass. | §8 |
| **BoneBreak (8)** | Re-skins vertices beyond a break plane (`<bone>_break_region` sockets). The 4th influence becomes the bone's first non-twist/Volume child, with weight `sat(d/10 cm)`; ancestor influences fade out. The break bone's physics constraint frames are moved to the break point. No RT stamp. | §7 |
| **BoneBreakWithDecal (9)** | BoneBreak plus the radial wound stamp. No data asset uses it. | §7, §8 |
| **SoftInfluenceUpdate (4)** | **Rejected by `SplatterDecal`**, with a warning. Only `USplatterMeshComponent::UpdateSoftInfluences(TArray<FSplatterSoftPrimitive>)` issues it. It adds capsule falloffs to a 10-bit per-soft-body-vertex influence, at most 4 primitives per call. | §10 |
| **ClearToValue (64)** | Writes `DisplacementClearValue` into **all four channels of both splatter RTs** (replace blend) and into **every vertex's deform depth**. It applies to the whole section and ignores the decal box. | §9 |
| **ClearSplatter / ClearAll (80)** | Same pass with a MIN blend and output 0: clears both RTs to 0, and vertex depth to `DisplacementClearValue` (default 0). | §9 |
| **Rupture\*** | Consumed only by `UVisceraComponent::Splatter`, via a delegate on the splatter component, and only for decal-bit hits. An OBB-vs-slab test against the viscera proxies feeds damage into the proxies. Each proxy ruptures at `RuptureThreshold`, capped by `RuptureLimitFraction`. At most `MaximumRuptureCount` proxies rupture per hit. | §11 |

**Who issues them.**
- No CosmeticEffect hit-effect preset uses any mesh-edit type. The 270 splatter CEs use only Decal (349 infos) and MaxDecal (32).
- Live gameplay uses four `UGradualDamageEffect` assets, chosen by `DA_ContextualGradualDamageEffectList_AI` (`{Hit}.Dismember` / `{Hit}.BoneBreak` / `#Beheaded`).
- Authored `USplatterSet`s add more: corpses, crawler variants, cutscenes, perks and the Expansion 2 reformer clears. See §2.

---------------------------------------------------------------------------------------------------------------------

## 1. Types, gates and the pending decal

### 1.1 ESplatterType (read from the exe's UEnum table)

| Name | Value | Bits |
|---|---|---|
| None | 0 | |
| Decal | 1 | 0x01 (RT + deform stamp) |
| Dismember | 2 | 0x02 |
| DismemberWithDecal | 3 | 0x03 |
| SoftInfluenceUpdate | 4 | 0x04 |
| BoneBreak | 8 | 0x08 |
| BoneBreakWithDecal | 9 | 0x09 |
| ApplyMin | 16 | 0x10 |
| MinDecal | 17 | 0x11 |
| ApplyMax | 32 | 0x20 |
| MaxDecal | 33 | 0x21 |
| ClearToValue | 64 | 0x40 |
| ClearSplatter | 80 | 0x50 |
| ClearAll | 80 | alias of ClearSplatter |
| RequiresSplatter | 81 | 0x51 = mask "needs the RT/deform path" |
| RequiresMeshEdit | 138 | 0x8A = mask "needs a mesh edit" (0x80 + BoneBreak + Dismember) |

### 1.2 `USplatterMeshComponent::SplatterDecal` (0x140a161a0), mesh-edit branches

`t` is the type byte (info+0x64), BoneIndex is info+0x5c, comp is the USplatterMeshComponent.

```
if (t & 4) { warn("Dont use SplatterDecal API to update the Soft Bodies, SoftInfluenceUpdate flag ignored"); t &= ~4; }
if (!comp.TargetComponent || t == 0) return;
decal = PendingDecal(info); frame = [R.Y; -R.Z; -R.X; location]           // RE_FLESH "DecalMatrix"
if (!comp.bAllowDismember(+0x621) || !comp.HasMaterialMasks(+0x623) || BoneIndex == -1)
    t &= ~(Dismember|BoneBreak)                                           // & 0xF5
ruptureOnly = false
if (info.RuptureInteraction == RuptureOnly(2) && (t & 1)) { t &= ~1; ruptureOnly = true; }
if (t != 0):
  if (t & 1 && comp.pending >= 256) { warn("too many decals pending"); return; }
  if (bUVSpaceSplatter) frame = identity
  if ((t & (Dismember|BoneBreak)) == 0):  append decal to comp.Pending (+0x5F8); copy to param_6 (if any)
  else if (mesh && 0 <= BoneIndex < mesh.RefSkeleton.Num()):
      d2 = PendingDecal(); if (PlaceDismember(comp, decal, d2) /*0x140a05050, §5*/):
          d2.+0x78  = BoneTopology(mesh, BoneIndex)        // 0x143ad3870: u16 depth, u16 branch, i32 break bone (§4)
          if (t & BoneBreak): d2.+0x2D0 = break bone; d2.+0x200 = GetBoneMatrix(comp, break bone)
                              d2.+0x240 = mesh.CachedComposedRefPoseMatrices[break bone]
          if (t & Dismember): comp.DismemberCounter(+0x61C)++
          d2.+0x2D4 = comp.DismemberCounter
          append d2 (only d2; the original decal is not queued); copy to param_6
          return value = the corrected cut frame (FUN_140a0fbc0 on d2.+0x1C0)
// rupture listener: also for mesh-edit decals that carry the Decal bit
if (comp.SplatterDelegate bound (+0x520/+0x528) && ((t & 1) || ruptureOnly) && 0 <= BoneIndex < NumBones)
    delegate(Rotation frame [R.X; R.Y; R.Z; location] moved into ref space through BoneIndex, info)   // §11
```

**Gates for Dismember and BoneBreak, all required:**
1. `USplatterMeshParameters.bAllowDismember` (byte +0x49), copied to comp+0x621 by 0x140a09b30, which `CreateSplatterMeshResources` (exec 0x140a1dfe0) calls.
2. The mesh carries a `UDIEngineMaterialMasks` asset user data. comp+0x623 means "MaterialMasks found" (0x140a09ca0).
3. A valid BoneIndex.
4. At least one region socket on that bone (§5). Without one, **nothing at all is queued, not even the decal stamp.**

`DA_SplatterParameters_AI_NoDismember` sets `bAllowDismember = false`. Other `USplatterMeshParameters` bool offsets:

| Field | Byte |
|---|---|
| bFatTextures | +0x48 |
| bAllowDeformation | +0x4A |
| bSharesResources | +0x4B |

### 1.3 Pending-decal fields used by the mesh edits (0x2E0 bytes; FLESH fields in RE_FLESH.md)

| Offset | Field |
|---|---|
| +0x10 | SoftUpdatePrims (TArray<FSplatterSoftPrimitive>) |
| +0x50 | DisplacementClearValue |
| +0x5C | BoneIndex |
| +0x60 | MaterialID |
| +0x64 | type |
| +0x65 | ClothingInteraction |
| +0x6C | pass flags (§1.4) |
| +0x70 | bReferencePose. Set to 1 by PlaceDismember, by UpdateSoftInfluences and by ApplySplatterSet. |
| +0x71 | **radial** flag. Set only by PlaceDismember: `+0x70 = 0x0101`. |
| +0x72 / +0x73 | bAbsoluteDeformation / bSubtractive |
| +0x75 | bInvertSplatter. Copied only; never read by the Splatter plugin (but see §12.3). |
| +0x76 | bUVSpaceSplatter |
| +0x78 | bone topology of BoneIndex: u16 depth, u16 branch mask, i32 break-child bone (§4) |
| +0x80 | decal frame (rows). For dismember: **the fitted cut frame** [X = N×Z; Y = N; Z = normalize(BoneRefY × N); O], ref space. Processing scales rows 0/1 by UVScale/2 and inverts it into the stamp DecalMatrix. |
| +0xC0 | the same cut frame, unscaled. Processing inverts it into **`c_DecalMatrix` of the mesh-edit CS**, so decal-space y = signed distance in cm along N. |
| +0x100 | "BoneMatrix": ref bone matrix with row0 = ±normalize(BoneRef.Y) and row1 = ±BoneRef.X (flipped when BoneRef.X·N < 0). It is bound as `c_BoneMatrix`, but **every shipping shader compiles it out**. |
| +0x140 | bone matrix used for the space change: GetBoneMatrix, or the ref matrix when bReferencePose |
| +0x180 | ref bone matrix (`CachedComposedRefPoseMatrices[BoneIndex]`, USkeletalMesh+0x380) |
| +0x1C0 | `inverse(+0x140) · +0x180`: world → ref-pose space through the hit bone |
| +0x200 / +0x240 | BoneBreak: GetBoneMatrix(break child) / its ref matrix |
| +0x280 | **SafeRegionMatrix** (§5.3). The mesh-edit CS bounds test and the frame of the radial stamp. |
| +0x2D0 | BoneBreak: break-child bone index, or −1 |
| +0x2D4 | comp dismember counter |
| +0x2D8 | `BoneBranchMask` of the chosen region socket (u16), ORed into TargetBoneData.z |

### 1.4 Game-thread processing (0x140a1af60) → render thread

For every pending decal:

1. **BoneBreak only** (`(t & 10) == 8`) with a break child: `ManipulateConstraint` (0x140a10420, §7.3).
2. **`t & 1`:** scale +0x80 rows 0 and 1 by `UVScale/2`, then invert. bUVSpace instead uses `diag(1/UVScale)`.
3. **`t & 10`:** invert +0xC0.
4. Flags: `comp+0x625 |= (t & 0x51) != 0 || t == 4` ("needs splatter"); `comp+0x624 |= (t & 0x8A) != 0` ("needs mesh edit").
5. Pass flags at +0x6C:

| Bit | Value | Condition | Meaning |
|---|---|---|---|
| 0 | 1 | `t & 1` | stamp |
| 1 | 2 | `(t & 0x50) != 0` | **clear** (ClearToValue, ClearSplatter, and also ApplyMin/MinDecal, literally) |
| 2 | 4 | bReferencePose | Local VS / REFERENCE_POSE |
| 3 | 8 | bReferencePose && +0x71 | **radial** |
| 4 | 16 | `t & 4` | soft body |
| 5 | 32 | bUVSpace | UV_SPACE |

**Render-thread dispatcher (0x140a13370), per mesh object:**
- clear / RT path (0x140a136f0);
- deform path (0x1409f2510 sync, 0x1409f2030 async);
- mesh-edit path. Per LOD: BoneBreak in 0x1409f5210 (sync) / 0x1409f4920 (async). Then dismember consolidation in 0x1409f38a0.

The async variants are used when `r.Splatter.AsyncDeformation` is on and async compute is available.

---------------------------------------------------------------------------------------------------------------------

## 2. Who issues the mesh-edit types (data)

### 2.1 Live gameplay: `UGradualDamageEffect` via `UDamageRepercussions`

**`UGradualDamageEffect` layout:**

| Offset | Field |
|---|---|
| +0x30 | InitialEffect |
| +0x1A0 | OverTimeEffect |
| +0x310 | ParticleSystem |
| +0x318 | Duration |
| +0x31C | EmmissionPeriod |
| +0x320 | CustomDepthStencilWriteMask |
| +0x324 | CustomDepthStencilValue |
| +0x32C | DesaturationResponse |

**`FGradualDamageEffectInfo` (0x170):**

| Offset | Field |
|---|---|
| +0 | SplatterInfo (FSplatterMeshInfo) |
| +0xA8 | SplatterModifiers |
| +0x158 | FluidType |
| +0x160 | FluidAmount |
| +0x164 | FluidStrength |
| +0x168 | EmissionVelocity |

`DA_ContextualGradualDamageEffectList_AI` (PriorityOrderedCandidates, first match wins):

| # | Requirement | Effect | InitialEffect.SplatterInfo (non-default fields) |
|---|---|---|---|
| 0 | `{Hit}.Dismember && {Hit}.BoneName in {spine_01..04, clavicle_l/r}` | **MajorCut_AI** | DismemberWithDecal, T_DismemberSharp01_Wound, diffuse T_BlackMaskAlpha_A, UVScale 50, DepthScale 17, DepthFadeStart 0.5, bAbsoluteDeformation false |
| 1 | `#Beheaded` | **Decapitate_AI** | DismemberWithDecal, T_DismemberSharp01_Wound, UVScale 22, bAbsoluteDeformation false |
| 2 | `{Hit}.BoneBreak` | **BoneBreak_AI** | BoneBreak (8, no decal bit), T_BluntSweep02_Wound_A, UVScale 50, DisplacementScale 1.2, AngleWrap 0.5 |
| 3 | `{Hit}.Dismember` | **Dismember_AI** | DismemberWithDecal, T_DismemberSharp01_Wound, UVScale 45, bAbsoluteDeformation false |
| 4 | none | EffectData null | falls through to a global default effect (0x141c612d0 settings +0x118; not identified) |

The BoneBreak effect's textures are therefore never stamped.

**OverTimeEffect.SplatterInfo:**
- Dismember_AI: T_PointHit_A, UVScale 50, DisplacementScale 0, Bruising 0, Drips 0, Cauterisation 0, DepthScale 15.
- BoneBreak_AI: SplatterType None, so no over-time decal.
- Decapitate and MajorCut: default info.

**Timing:**

| Effect | Duration (s) | EmmissionPeriod (s) |
|---|---|---|
| Dismember | 7 | none |
| Decapitate | 2.5 | 0.25 |
| MajorCut | 1.25 | 0.25 |
| BoneBreak | 7 | 3 |

**Code path:**
1. `UDamageRepercussions::OnOwnerGameplayStateUpdated` (exec 0x141ba91e0 → 0x1412a6690).
   - The event data is a **`UBodyPartState`**:

     | Offset | Field |
     |---|---|
     | +0x78 | Health |
     | +0x7C | GameplayState (3 = dismember, 2 = break) |
     | +0x80 | LastDamageType |
     | +0x88 | LastDamage |
     | +0x8C | LastHitBoneIndex |
     | +0x90 | LastHitLocation |
     | **+0x9C** | **LastHitRotation** |
     | +0xA8 | LastHitDirection |
     | +0xB4 | LastDamageData {bHeavyAttack +0, bCanCauseBreak +1, bCanCauseDismember +2, bSpawnLimbsOnDismember +3, Force +4} |
     | +0xC0 | LastInstigator |
     | +0xD0 | LastCauser |
     | +0xD8 | PartDefinitionArrayIndex |
     | +0xE8 | HealthComponent |

   - State type 3 (dismember): 0x141293a60 builds a major wound from LastHitBoneIndex, LastHitLocation, LastHitRotation and LastHitDirection.
     - The force scalar is `Dismember.HeavyAttackForceScalar` if bHeavyAttack, else `Dismember.ForceScalar`, × Force.
     - A limb is spawned only if bSpawnLimbsOnDismember.
   - State type 2 (break): walks up the parents until a bone has a `_break_region` socket, then queues a type-8 wound.
2. `0x14129a8e0` processes the wound:
   - It walks up the bone's parents until `<bone>_safe_region` (type 2) or `_break_region` (type 8) exists. The check is 0x140a10220 → 0x140a0bd10.
   - It picks the effect (0x1412a1120). Facts set: BoneName, SplatterType name, a location, `{Hit}.BoneBreak = t&8`, `{Hit}.Dismember = t&2`.
   - It warns "Passed splatter info that doesn't do the required action" if `(SplatterType & type) != type`.
   - Then `RequestGradualDamageEffect` (0x1412ae1f0):
     - `Modify(SplatterModifiers, SplatterInfo, …)`. Identity for these assets, which set no modifiers.
     - BoneIndex = GetBoneIndex(bone).
     - `SplatterDecal(comp, hitLocation, hitRotator, info)` with the processed decal copied back.
     - An over-time instance is created with a timer (callback 0x14129b260).
   - Type 2: spawn `DismemberedLimbClass` (0x1412b2ba0), broadcast events, record the cut bone.
   - Type 8: `UVisceraComponent` break (0x1412365c0) and `PhysicalizedReactionComponent` break (0x14126a210).
3. **Over-time tick (0x14129b260), each update `dt`:**
   - `elapsed += dt`.
   - Fluid emission when `elapsed >= n · EmmissionPeriod`.
   - If OverTimeEffect.SplatterInfo.SplatterType ≠ 0: `info = Modify(OverTime…)`, then `info.DisplacementScale *= dt / Duration`, then `SplatterDecal(comp, woundTransform)` (0x140a16100). The other amounts are not scaled.
   - The instance is removed when `elapsed >= Duration`.

### 2.2 Authored splatter sets (`USplatterSet.SplatterEntries` / `SplatterGroups`)

Survey of all extracted JSON (`tools/re_dismember/meshedit_data.py` → `extracted/ghidra_dismember/meshedit_data.txt`):

| Type | Count | Where |
|---|---|---|
| DismemberWithDecal | 51 | Walker crawler and arm sets (17), Screamer/Slobber/Thug (9), GrenadeVest perk (8), corpses, head-explosion perks (3), cutscenes, the three AI gradual effects |
| Dismember | 38 | prologue corpses, Dr Dorian corpses, crawler 03, counters (3), cutscenes |
| BoneBreak | 1 | `DA_GradualDamageEffect_BoneBreak_AI` |
| ClearToValue | 13 | Expansion 2 Cameron/reformer sets and cutscenes |
| ClearSplatter | 2 | Expansion 2 Cameron/reformer sets and cutscenes |
| None | 3 | |

Most of these sets also hold plain Decals with BoneIndex set (432 with BoneIndex 8). For plain decals, **BoneIndex only matters for rupture** (§11).

**`ApplySplatterSet` (0x140a03e80)**, per entry:
- Forces **bReferencePose = 1**. Entry Location/Orientation are in ref-pose component space.
- Remaps BoneIndex from **skeleton** to **mesh** bone index by name (0x143ad37b0).
- Calls SplatterDecal.
- If the entry has `bInvertSplatter`, calls 0x143645f90(skelComp, set.DismembermentSectionIndexOverride (+0x48)), which writes it into every LOD's subsection data +0x44 (§12.3).

**Walker data:**
- Splatter-set BoneIndex values are **skeleton** indices (SKEL_ZombieStandard), remapped to mesh indices at apply time. Arm sets dismember 8 (upperarm_l) and 33 (upperarm_r). Crawler sets use 199/204 (thigh_l/r). The GrenadeVest sets use 200, 33 and 10.
- The four port bodies' `InitialSplatterSetVariants` contain **no** mesh-edit sets. The crawler meshes (`SK_Walker_CrawlerMale0x`) do.

---------------------------------------------------------------------------------------------------------------------

## 3. Section masks (`UDIEngineMaterialMasks`, mesh AssetUserData)

**Layout.** Masks struct at object +0x28; the mesh object copies it to +0x2B8. One u64 per field. **Bit index = material slot index.** Consistency check against every offset the code reads: DeformationMask at +0x2D8 (deform), WriteSplatterMask +0x2C8 (clear), ClothingProxyMask +0x308 (clear), TrimMask/TrimHQMask +0x318/+0x320, BinaryDismemberMask +0x348.

**Struct offsets:**

| Field | Offset |
|---|---|
| HideMask | 0 |
| InitiallyHiddenMask | 8 |
| WriteSplatterMask | 0x10 |
| CapDismemberMask | 0x18 |
| DeformationMask | 0x20 |
| DismemberMask | 0x28 |
| InternalDeformationMask | 0x30 |
| SkeletonVisceraMask | 0x38 |
| SoftBodyDeformationMask | 0x40 |
| ClothingMask | 0x48 |
| ClothingProxyMask | 0x50 |
| ArmourMask | 0x58 |
| TrimMask | 0x60 |
| TrimHQMask | 0x68 |
| RegeneratesMask | 0x70 |
| SplatterGroupMask | 0x78 |
| SplatterClothingGroupMask | 0x80 |
| SortBiasMask | 0x88 (2 bits per slot) |
| BinaryDismemberMask | 0x90 |
| SoftBodyMaskMap | 0x98 |

**Use in the mesh edits:**

| Mask | Effect |
|---|---|
| DismemberMask | Sections that take Dismember. A section not in it is still processed by **BoneBreak** if it is in SkeletonVisceraMask and its render section has the flag tested in 0x1409f5210, so the bones get re-skinned. |
| BinaryDismemberMask | Sets `c_BinaryDismember` (§6). |
| TrimMask / TrimHQMask | `c_UseTrim` = Trim, or (TrimHQ && quality cvar). **Compiled out of every shipping shader**: no effect. |
| HideMask | Hidden at component init (0x14363e8b0). |
| InitiallyHiddenMask | Hidden at spawn and on `ResetDamageRepercussions` (0x14363e930 ← 0x1412afc20). |
| WriteSplatterMask / ClothingProxyMask | Clear pass (§9). |
| DeformationMask | Vertex-depth passes. |
| SoftBodyDeformationMask | Soft passes. |

The **`HideViscera`** UFUNCTION (exec 0x140ed92b0 → 0x140ece200) hides every material slot **not** in DismemberMask on a component, per LOD (`ShowMaterialSection(slot, slot, false, lod)`). On the Walker these are the skull, viscera and skeleton.

**Port bodies, from `tools/re_dismember/masks_dump.py`.** Full JSON: `extracted/ghidra_dismember/body_masks.json`.

| Body | DismemberMask excludes | Binary | SkeletonViscera | InitiallyHidden |
|---|---|---|---|---|
| Walker | 10 skull, 11–13 viscera, 14–15 skeleton | 6, 7 eyes, 8 eye overlay | 14, 15 | 15 |
| Runner | 2 skull, 12 viscera, 13–14 skeleton | eyes, overlay, hair shell + cards | 13, 14 | 14 |
| Shambler | 2 brain, 10 viscera, 11–12 skeleton | eyes, overlay, hair | 11, 12 | 12 |
| Thug | 4 head viscera, 11 skeleton, 12 viscera | eyes, overlay, three hair layers | 11 | 11 |

Two skeleton slots: the second (initially hidden) is the "broken bone" set. Its subsection names (`UpperArmL1_Break` …) are in the mesh's `CharacterMaterialMasks`.

**Open:** CUE4Parse lists no LOD section for Walker slots 14/15. The skeleton geometry's section mapping still needs checking against the cooked mesh.

---------------------------------------------------------------------------------------------------------------------

## 4. Bone topology (USkeletalMesh +0x390, built in PostLoad 0x143ada2d0 → 0x143adbb30 / 0x143ae13c0)

**Per-bone node (0x30 bytes):**

| Offset | Field |
|---|---|
| +0 | name |
| +8 | children |
| +0x18 | parent |
| +0x20 | bone index |
| +0x24 | u16 depth |
| +0x26 | u16 branch mask |
| +0x28 | byte flag |

```
root: depth 0, mask = table(root) or 1
visit(child, depth, mask, f):            // f inherited from the parent
  if mask < 2: mask = {clavicle_l:2, clavicle_r:4, thigh_l:8, thigh_r:16, neck_01:32}.get(name, mask)
  node.depth = depth; node.mask = mask
  if strstr(name,"twist") or strstr(name,"Volume"): node.flag = 1; f = 1
  if strstr(name,"head"): f = 1                       // no flag, but stops the depth increment below
  for c in children: visit(c, depth + (f ? 0 : 1), mask, f)
break_bone(b) = first child of b (bone order) with flag == 0, else -1         // 0x143ad3870
```

**Walker examples:**

| Bone | Depth | Branch | Break child |
|---|---|---|---|
| upperarm_l | 7 | 2 | lowerarm_l |
| lowerarm_l | 8 | 2 | hand_l |
| thigh_r | 2 | 16 | calf_r |
| calf_r | 3 | 16 | foot_r |
| neck_01 | 6 | 32 | neck_02 |
| spine_04 | 5 | 1 | clavicle_l |

Bones under `head` all have depth 8.

**Shader side.** The CS reads the topology through `BoneTopologySRV` (uint2 = (depth, branch)), indexed by the **section-local** bone index (the skin buffer's indices). It is per section, via mesh-object +0x190 vtbl +0x80.

---------------------------------------------------------------------------------------------------------------------

## 5. Cut placement: region sockets and the fitted plane (0x140a05050, 0x140a06270, 0x140a05c90)

### 5.1 Region sockets

`0x140a0bd10` builds the names below and looks each one up with 0x143ad1db0. It keeps **mesh** sockets only: the socket index must be below `(mesh sockets + skeleton sockets) − skeleton sockets`.

| Edit | Socket names |
|---|---|
| Dismember | `"%s_%s"(bone, "safe_region")`, then `"%s_%d"(that, 1, 2, …)` until one is missing |
| BoneBreak | the same with `"break_region"` |

A string `boneend_region` also exists. It is loaded at 0x140417490 but never used by placement (GetBoneEndAxis UFUNCTION).

`USkeletalMeshSocket` gains `BoneBranchMask` (int +0x60). The socket's RelativeScale gives the **region half-extents (cm)**: sx along socket X, sy, sz.

**Walker region sockets** (identical names on all four bodies, 28 each):

| Socket | Bone | Loc | Rot (P, Y, R) | Scale | BoneBranchMask |
|---|---|---|---|---|---|
| upperarm_l_safe_region | upperarm_l | (17, 0, 0) | (0, −180, 0) | (7, 8, 8) | 0 |
| upperarm_l_safe_region_1 | upperarm_l | (7.19, 0.04, −2.0) | (−37.4, 177.6, 2.0) | (4.66, 14.24, 16.09) | 0 |
| upperarm_l_safe_region_2 | upperarm_l | (1.81, 0.09, −0.09) | (−57.6, 176.3, 3.0) | (3.72, 16.58, 15.75) | 0 |
| upperarm_l_break_region | upperarm_l | (17, 0, 1) | (−10, −175, 180) | (6, 20, 20) | 0 |
| lowerarm_l_safe_region | lowerarm_l | (14, 0, 0) | (0, 170, 0) | (10, 7, 6) | 0 |
| lowerarm_l_break_region | lowerarm_l | (12, 1, 0) | (0, 175, 0) | (9, 20, 20) | 0 |
| (right arm) | | mirrored: X negated, yaw ≈ 0 | | same scales | 0 |
| head_safe_region | head | (6, 1, 0) | (0, −160, 180) | (6, 14, 10) | 0 |
| neck_01_safe_region | neck_01 | (4, 0, 0) | (0, 180, 180) | (0.5, 8, 8) | 0 |
| neck_02_safe_region | neck_02 | (1, 1, 0) | (0, −180, −180) | (1.5, 8, 8) | 0 |
| thigh_l_safe_region | thigh_l | (−34, −3, 1) | (5, 10, 0) | (11, 14, 11) | 0 |
| thigh_l_break_region | thigh_l | (−30, −3, 0) | (10, 10, 0) | (12, 30, 30) | 0 |
| calf_l_safe_region | calf_l | (−26, −1, 0) | (0, −5, 0) | (18, 9, 9) | 0 |
| calf_l_break_region | calf_l | (−26, −3, 0) | (0, −5, 0) | (12, 20, 20) | 0 |
| (right leg) | | mirrored | | | 0 |
| spine_02_safe_region | spine_02 | (−5, −3, 0) | (0, −170, 0) | (5, 18, 20) | **38** |
| spine_03_safe_region | spine_03 | (−4, 0, 0) | (0, −170, 0) | (7, 20, 20) | **38** |
| spine_04_safe_region | spine_04 | (−8, 0, 0) | (0, −175, 0) | (5, 18, 20) | **38** |
| spine_04_safe_region_1 | spine_04 | (0, −2, 0) | (44.2, −180, −180) | (5, 15, 28) | **34** |
| spine_04_safe_region_2 | spine_04 | (−4, −2, 0) | (−49.4, 175.9, 0) | (5, 15, 30) | **36** |

All values come from `SK_WalkerMaleCas01.json`. Branch 38 = 2 | 4 | 32 (both arms and the head), 34 = 2 | 32, 36 = 4 | 32. These masks are ORed into TargetBoneData.z, so a spine cut takes the arms and/or head with it.

### 5.2 Placement (literal; `dismember_ref.place_dismember` / `evaluate_candidate`)

**Inputs:**
- `F` = decal frame (world) = [R.Y; −R.Z; −R.X; L] from the SplatterDecal rotator.
- `Bcur` = GetBoneMatrix(BoneIndex), or `Bref` when bReferencePose.
- `Bref` = CachedComposedRefPoseMatrices[BoneIndex].

```
T     = inverse(Bcur) · Bref                 // +0x1C0
Fref  = F · T                                // decal frame in ref space
for each region socket S (candidate):        // 0x140a06270
  U  = SocketMatrix(rot, loc) · Bref         // unscaled;  Ws = same with scale (sx,sy,sz)
  n0 = normalize(dir(Fref.row1) · U⁻¹)       // initial plane normal = decal Y = -R.Z, in socket space
  o  = point(Fref.row3) · U⁻¹
  foci: sy <= sz ? F1,2 = (0,0,±sqrt(sz²-sy²)) : (0,±sqrt(sy²-sz²),0)    // end-cap ellipse y²/sy²+z²/sz²=1
  n = n0; if |n.x| < 0.001: n.x += 0.05, renormalise
  t = dot(o,n)/n.x;  if |t| > 0.95·sx: t = sign(t)·0.95·sx          // plane crosses socket X at (t,0,0)
  G,N,H = dX, n, dZ                                                    // defaults
  r = sqrt(n.y²+n.z²)
  if r > 1e-8:
     (ey,ez) = (n.z/r, -n.y/r);  w = normalize((r, ez·n.x, -ey·n.x))  // socket X projected into the plane
     E = (t > 0.5) ? (+sx,0,0) : (-sx,0,0);  s = (E.x - t)/w.x;  Q = (E.x, w.y·s, w.z·s)
     line Q + λ(0,ey,ez) vs ellipse: B = 2Qz·ez/sz² + 2Qy·ey/sy²,  A = ez²/sz²+ey²/sy²,  C = Qz²/sz²+Qy²/sy²-1
     if B² - 4AC > 0:                                    // plane exits through the end cap: tilt it to the rim
        V = safe_normal(Q - E);  V /= max(sqrt(V.z²/sz² + V.y²/sy²), 1e-4);   P = E + V   (rim point)
        D1 = safe_normal(F1 - V); D2 = safe_normal(F2 - V)
        m.y = -0.5(D1.y+D2.y);  m.z = 0.5(D1.z+D2.z)
        N = normalize((m.y·P.y - P.z·m.z,  -m.y·(P.x - t),  m.z·(P.x - t)))        // (P-T) × rim tangent
        G = normalize((m.z·N.z - m.y·N.y,  m.y·N.x,  -m.z·N.x));  H = normalize(N × G)
  if N.x >= 0: N = -N                                     // normal points to socket -X
  score = min(|N·n0|,1)⁴ · 2/3 + clamp(1 - |dot(o,n0) - t·n0.x|·0.2, 0, 1) · 1/3
  cand.frame = [G·U; N·U; H·U; (t,0,0)·U]                 // ref space
  cand.SafeRegion = SafeRegionMatrix(Ws, BoneBranchMask > 0)          // §5.3
best = max score (strictly greater; initial -1)
N    = best.frame.row1;  Z = normalize(Bref.row1 × N);  X = normalize(N × Z)
cut frame (+0x80 = +0xC0) = [X; N; Z; best.frame.row3];  +0x280 = best.SafeRegion;  +0x2D8 = best.BoneBranchMask
```

**The normal points toward socket −X.** The region sockets are rotated so that socket −X points away from the body: down the limb, or up the neck. So the **limb is on the +N side**: decal-space y > 0.

`dismember_ref.py --selftest` uses the Walker skeleton ref pose and a hit whose −R.Z runs along the bone:
- upperarm_l: t = 5 cm, score 1.0, N·boneX = +1.
- thigh_r at 12 cm (outside its region): t is clamped to 0.95·sx = 10.47.

### 5.3 SafeRegionMatrix (0x140a05c90)

```
a = |Ws.row0| (= sx, clamped ≥ 1e-5);  S = 1000/a
P = [[S,0,0,0],[0,k,0,0],[0,0,k,0],[1-S+off/a,0,0,1]]     // k=1, off=0 unless the socket BoneBranchMask > 0:
                                                          //   k = r.Splatter.SafeRegionMatrixScale = 1.333
                                                          //   off = r.Splatter.SafeRegionMatrixOffset = 50 (cm)
SafeRegionMatrix = inverse(P · Ws)
```

The test `|SR·p| < 1` is a **slab**:
- Along the socket axis it runs from the box's +X face (pushed `off` cm further for spine regions) for 2000 cm toward −X.
- Its cross-section is the box's ±sy, ±sz, scaled by k for spine regions.

The cvar help strings are "Safe region matrix offset (after plane constraint)" and "Safe region matrix scale for diagonal cuts". `r.Splatter.DebugDraw` draws placement/restraint/correction.

---------------------------------------------------------------------------------------------------------------------

## 6. Dismember on the GPU: `FSplatterGeometryIndicesCS_FourBone` (Global 939)

**Dispatch.** 0x1409f38a0 builds one request per (LOD, section) where `DismemberMask` has the section bit and the section is not shared. 0x1409f29f0 then runs, per LOD:
1. `FSplatterCopyIndicesCS` (Global 908): copies the index buffer to scratch, `u0[i] = t0[i]` for `i < c239.y`.
2. `GeometryIndicesCS` once per section request (0x1409f46b0).
3. `FSplatterConsolidateStaticIArgCS` (Global 941): fixes the draw/dispatch indirect args.

**Bindings** (`params.py`):

| Parameter | Binding |
|---|---|
| SRVStrides0/1 | c0 / c1 |
| SRVOffsets | c4 |
| c_SectionParameters | c6 (.w = indirect-args base) |
| c_IndirectArgsIndexParameter | c7.x = section index << 8 |
| c_DecalMatrix | c12–15 = inverse(+0xC0) |
| c_SafeRegionMatrix | c16–19 = +0x280 |
| c_BinaryDismember | c216.y |
| c_TargetBoneData | c218 (int4) |
| BoneTopologySRV | t4 |

`c_BoneMatrix` and `c_UseTrim` are bound by the CPU but **absent** from the shader.

**TargetBoneData** (0x1409f38a0 / 0x1409f5210):

| Field | Value |
|---|---|
| x | section-local index of BoneIndex (BoneMap search), or −1 |
| y | depth(BoneIndex) |
| z | branch(BoneIndex) \| region BoneBranchMask (+0x2D8) |
| w | section-local break child (BoneBreak), else 0 |

One thread per triangle (`< IndexCount/3`). Indices come from the copy, plus BaseVertex. Positions are **bind pose** (PositionBufferSRV). Skin = 4 influences (the first index and weight words of 4/8-influence buffers, 8-bit).

```
T1,T2,F = Binary ? (0,0,0) : (0.1, 0.24, 255)
per vertex k: d_k = dot(p_k, DM col y) + DM[3].y                   // cm along N; limb side d >= 0
  br_kj  = w_kj > T2 ? topo[b_kj].branch : F
  dep_kj = w_kj > T1 ? topo[b_kj].depth  : 0
  inBranch_k = Binary ? any_j(br_kj & Tz) : all_j(br_kj & Tz)
insideSR   = all_k |SR·p_k| < 1  &&  Tz != 0  &&  !Binary
candidate  = insideSR || all_k inBranch_k
anyPrimary = any_k (w_k0 > T1 && b_k0 == Tx)          // influence 0 only
anyTarget  = any_k,j (w_kj > T1 && b_kj == Tx)
touch      = ((!candidate && !anyPrimary) || Tx == -1) ? 0 : anyTarget
srOrTarget = insideSR || touch
deeper     = any_k,j (Ty < dep_kj)                     // unsigned
limbTri    = candidate && deeper && !srOrTarget
code = srOrTarget ? (Binary ? 0 : count_k(d_k < 0)) : (limbTri ? 0 : 3)
code 3 -> body: idx = StartIndex + atomicAdd(args[A+0], 3);              write (i0,i1,i2)
code 0 -> limb: o = atomicAdd(args[A+7], 3); idx = StartIndex + argsSRV[A+6] - (o + argsSRV[A+7]) - 3  // packed from the end
code 1/2 -> dropped (the triangle straddles the cut inside the region / at the target bone)
```

**Meaning:**
- Inside the safe region and on triangles touching the hit bone, the **plane** decides: all three vertices behind the plane = body, all three in front = limb, mixed = removed.
- Elsewhere the **skeleton** decides: a triangle whose significant (> 0.24) influences all lie in the cut branch and that has some influence deeper than the cut bone goes to the limb; everything else stays.
- **Binary sections** (eyes, hair cards, eye overlay) are never split. They go to the limb if they touch the target bone or are in the branch with deeper influences.
- The hole is not capped by new geometry. It is covered by the interior shells (IntA), the skeleton/viscera sections (not in DismemberMask) and the radial wound stamp.
- Repeated dismembers accumulate: limb triangles are packed downward from the end of the section range.

**`FSplatterGeometryCS_FourBone[_TwoUV]` (Global 903/893)** is a triangle-*splitting* variant: 1900 instructions, writes full vertex streams. It is compiled into the cache, but its FShaderType objects (0x146b71ba0 / 0x146b71d00) have **no code reference** except their registration. **It is never dispatched by the shipping exe.** The `FSplatterConsolidate*CS` types other than StaticIArg are 1-instruction stubs.

**StaticIArg (A = c7.x):**

```
u0[A]   = argsSRV[A]
u0[A+9] = ceil((argsSRV[A]/3)/48)                           // groups for later per-triangle passes
u0[A+7] = argsSRV[A+7] + u0[A+7]
u0[c6.x·16 + A] = argsSRV[A+7]
then writes the limb draw at that base: +2 = (u0[A+6] + u0[A+2]) - new limb count, +7 = 0, +9 = groups
```

The exact semantics of every slot are **open**: they only matter for a GPU port.

---------------------------------------------------------------------------------------------------------------------

## 7. Bone break

### 7.1 Placement

As §5, with `<bone>_break_region` sockets: half-extents (6–12, 20–30, 20–30), circular cross-sections. `TargetBoneData.w` = the section-local break child = the bone's first non-twist/Volume child (§4).

### 7.2 `FSplatterBreakCS` (Global 904; dispatched by 0x1409ec110 from 0x1409f5210/0x1409f4920 when `(t&10) == 8`)

**When it runs:**
- Per section in DismemberMask, or in SkeletonVisceraMask with the render-section flag.
- Only if the break child is found in the section's BoneMap.
- Dispatched indirectly over the section's triangles.
- An atomic per-pass stamp (`c217.w`, a global counter 0x14684557c) processes each vertex once.

**Bindings:** c_DecalMatrix c12–15, c_TargetBoneData c218, c_BinaryDismember c216.y, skin UAV u1 (2 words per vertex: indices, weights, 8-bit), positions t2, topology t3.

```
T1,T2,F = Binary ? (0,0,0) : (0.1, 0.24, 255)
d = dot(p, DM col y) + DM[3].y                       // bind pose, cm
affected = (Binary ? any_j : all_j)(((w_j > T2) ? topo[b_j].branch : F) & Tz)
if !(affected && d >= 0) return
dep_j = (w_j > T1) ? topo[b_j].depth : 0
reassign = (Tx != -1 && any_j(w_j > T1 && b_j == Tx)) || any_j(dep_j == Ty)
if !reassign return
g   = saturate(0.1·d)                                 // 10 cm ramp past the break plane
w'_j = w_j·(1 - g·[Ty >= dep_j])  for j = 0..2;   w'_3 = g      // influence 3's original weight is dropped
w'  *= (Σw)/(Σw')                                     // keep the original total
store bones (b0,b1,b2,Tw), weights floor(min(w',1)·255)
```

So vertices of the broken bone's segment beyond the break plane progressively follow the **child** bone (e.g. upperarm → lowerarm), and the limb bends at the break. Nothing is removed. BoneBreak (8) carries no stamp. BoneBreakWithDecal (9) would add the radial stamp of §8.

### 7.3 Physics: `USplatterMeshComponent::ManipulateConstraint` (0x140a10420)

On the game thread, for a pending BoneBreak with a break child:
- Finds the physics constraint between the break child and its parent.
- Rebuilds both constraint frames so the joint pivot sits at the cut-frame origin (+0xF0), using +0x140/+0x180/+0x1C0/+0x200.
- On failure it logs "Splatter Mesh Component (%s) failed to manipulate constraints".

The re-skinned segment then swings about the break point under ragdoll or physical animation. Exact frame math: **open** (FUN_1439c4230, FUN_140a0fbc0 usage).

Game side: `UVisceraComponent` break (0x1412365c0) feeds the break plane (cut-frame Y axis and distance) to the viscera groups. `UPhysicalizedReactionComponent` (0x14126a210) also reacts. Both are **open**.

---------------------------------------------------------------------------------------------------------------------

## 8. The wound stamp of DismemberWithDecal / BoneBreakWithDecal: **radial, reference pose**

PlaceDismember sets +0x70 = +0x71 = 1, so pass flags = stamp | REFERENCE_POSE | **RADIAL** (§1.4). This answers SHADERS_FLESH.md §3.5 ("which effects use radial"): **only the mesh-edit decals.** It also answers SHADERS_FLESH §4.2 p82 (bind-pose radial deform).

**RT pass:**
- `FSplatterPS_*_Radial` with the Local VS (bind-pose positions), selected in 0x140a11e80 by decal +0x71.
- **DecalMatrix** = inverse of the cut frame with rows 0/1 × UVScale/2. Axial `y = 2·dist/UVScale` along N, a band of total height UVScale centred on the cut.
- **SafeRegionMatrix[i]** = +0x280. With `s = SR·p` (region-local), `qy = s.y`, `qz = s.z` and `r = sqrt(qy² + qz²)`, r = 1 at the region box's side.

```
w  = (|y| < 1)·(1 - sat(4(r - 1)))        // full inside the region cross-section, fades to 0 at 1.25×
uv = sat((qz/r, y)·0.5 + 0.5)             // u = sine of the angle round the region axis, v = across the cut
```

No depth fade or AngleWrap. Scales and RangeParams pack as for any decal (RE_FLESH.md). Both shaders compute `qz·rsqrt(r²)`, so on the region axis (r = 0) u = saturate(NaN) = 0 at full weight. Where w = 0 the PS writes 0 (no change, no coverage); the CS still runs its blend with v·w = 0.

**Deform CS p82 (Global 926), per vertex** (`dismember_ref.radial_vertex_depth`):

```
v  = ((Disp.R at texel (uint)(uv·size), mip 0) − Range.x) / Range.y · S.y;   vw = v·w
m  = S.z < 0 ? (DeformParams.y < 0 ? 1 − vw : vw) : DeformParams.y·vw
depth' = S.w < 0 ? sat(max(m·1.1111112, depth)) : S.z < 0 ? sat(min(m·1.1111112, depth)) : sat(depth + m·1.1111112)
stored as f16 (Deform.z kept)
```

**Deform pass:** the RADIAL REFERENCE_POSE permutation (DEFORM_BEHAVIOUR 2) with the same frames. The data sets `bAbsoluteDeformation = false`, so DeformParams.x = 0 and there is no 3/|D| factor.

**Data values:**

| Effect | Texture | UVScale | DepthScale |
|---|---|---|---|
| Dismember_AI | T_DismemberSharp01_Wound | 45 | 10 |
| Decapitate | T_DismemberSharp01_Wound | 22 | 10 |
| MajorCut | T_DismemberSharp01_Wound | 50 | 17 |

All use DisplacementScale 1 and diffuse T_BlackMaskAlpha_A. DepthScale is unused by the radial PS, which has no depth fade.

---------------------------------------------------------------------------------------------------------------------

## 9. Clears: ClearToValue (64), ClearSplatter / ClearAll (80)

**RT side (0x140a12a40, via 0x140a136f0).** For each section with WriteSplatterMask set, whose RTs exist, and with `t & 0x51`: `FSplatterClearPS` (Global 1877, `o = saturate(1 − c_ClearMask)`) draws over the **whole UV rect** (0, 0, 1, 1) of each RT. The decal box is ignored.

| Section | Type | c_ClearMask | Blend (decoded by `blendstate.py`) | Result |
|---|---|---|---|---|
| not in ClothingProxyMask | ClearToValue | `1 − DisplacementClearValue` (×4) | default: Add(One, Zero), RGBA (0x140a09480) | **both RTs, all 4 channels = DisplacementClearValue** |
| not in ClothingProxyMask | ClearSplatter / ClearAll | (1, 1, 1, 1) | **Min(One, One)**, RGBA (0x140a08e80) | both RTs = 0 |
| in ClothingProxyMask | either | (1, 1, 1, 1) | Min(One, One), **write mask R\|A** (0x140a08b80) | Disp RT only: wound depth and coverage = 0, blood/bruise kept |

**Vertex side.** The deform batch "clear" flag is `t & 0x50`. It selects `FSplatterDeformMeshCS` DEFORM_BEHAVIOUR 3 (p83/p…, Global 885). For **every** vertex of the section's triangles (once each, atomic stamp):

```
deform.w = f16(c_ClearValueArray[0].x)       // = DisplacementClearValue of the batch's first decal; deform.z kept
```

**Literal side-effect:** ApplyMin (16) and MinDecal (17) also set the clear flag. No asset uses them.

**Uses:** only Expansion 2 (Cameron reformer gore piles and cutscenes). They clear before re-applying their states. Their entries are otherwise default: DisplacementClearValue 0, so clear to 0.

---------------------------------------------------------------------------------------------------------------------

## 10. SoftInfluenceUpdate (4)

**API:** `USplatterMeshComponent::UpdateSoftInfluences(TArray<FSplatterSoftPrimitive>)` (exec 0x140a1e8c0 → 0x140a1b9e0). It queues a pending decal with type 4, bReferencePose 1 and the primitives, bypassing SplatterDecal.

**`FSplatterSoftPrimitive` (0x28):**

| Offset | Field |
|---|---|
| 0 | Position |
| 12 | Radius |
| 16 | HalfHeight |
| 20 | Axis |
| 32 | FadeRadius |
| 36 | AddInfluenceAmount |

**Caller:** the viscera component when a switchable variant activates (0x141232720). For each `UVisceraSoftBodyGPUInfluence` child with Radius > 0:
- Position = Location.Translation, Axis = Location.Rotation·(0, 0, 1).
- Radius, HalfHeight, FadeRadius and AddInfluenceAmount copied.
- Walker example: the ruptured guts variant, Radius 13, HalfHeight 11, Fade 3, Amount 1, at (5.26, 0, 103.74).

**GPU:** `FSplatterDeformMeshCS` with APPLY_TO_SOFT_BODY (perm `(p/10)%2`, e.g. p90, Global 896). Packed by 0x1409fa380 only when type == 4:

| Parameter | Value |
|---|---|
| IsSoftUpdate | 1 |
| SoftNumVolumes | min(N, 4) |
| SoftPosition[i] | Position |
| SoftAxis[i] | (Axis, HalfHeight) |
| SoftRadius[i] | Radius |
| SoftInfluence[i] | AddInfluenceAmount |
| SoftFade[i] | FadeRadius |

It runs over the soft-body vertices (args c6.w+5 count, +3 base). Soft data `u0`: 10:10:10 packed, z = influence `s = z/1023`.

```
for i < SoftNumVolumes:
  d = pos(bind) - P_i;  t = clamp(dot(d, A_i), -H_i, H_i);  dist = max(|d - t·A_i| - R_i, 0)
  if dist <= Fade_i:  s = saturate(Infl_i · max(1 - dist²/(Fade_i² + 1), 0) + s);  store z = ftou(s·1023)
```

**APPLY_TO_SOFT_BODY without IsSoftUpdate** (an ordinary stamp on soft sections):
- Skins the soft vertex and runs the world planar projection (no angle wrap).
- `v = DispTex.R` remap × ScaleVec.y × fade × inside × (3/|D| if DeformParams.x).
- Then `s = ApplyMax ? min(max(s, 3v), 1) : ApplyMin ? max(min(s, 3v), 0) : sat(s + 3v)`.

What the SoftBody plugin does with `s` is outside the Splatter plugin. **Open.**

---------------------------------------------------------------------------------------------------------------------

## 11. Rupture (`FSplatterMeshInfo.Rupture*`, `MaximumRuptureCount`, `RuptureInteraction`)

**Delivery.** SplatterDecal calls the splatter component's native delegate (+0x520). `UVisceraComponent` binds it to **`UVisceraComponent::Splatter` (0x141256940)** (the delegate's Execute is 0x141e37490). The matrix passed is the hit rotation frame **[R.X; R.Y; R.Z; L]** moved into ref space through BoneIndex. Here R.X is the Orient projection direction (into the surface with the default flip).

**Field offsets in FSplatterMeshInfo:**

| Field | Offset |
|---|---|
| RuptureDamageMultiplier | +0x68 |
| RuptureDamageOffset | +0x6C |
| RuptureRadiusMultiplier | +0x70 |
| RuptureRadiusOffset | +0x74 (**never read**) |
| RuptureFalloffFactor | +0x78 |
| RuptureDepthMultiplier | +0x7C |
| RuptureDepthOffset | +0x80 |
| RuptureLimitFraction | +0x84 |
| MaximumRuptureCount | +0x90 |
| RuptureInteraction | +0x95 (Default 0, NoRupture 1, RuptureOnly 2) |
| bIgnoreRulesets | +0x96 |

```
require viscera asset, (type & 1), RuptureInteraction != NoRupture, MaximumRuptureCount > 0,
        RuptureDamageMultiplier >= 1e-4 || RuptureDamageOffset >= 1e-4
radius = RuptureRadiusMultiplier·UVScale + RuptureDepthOffset         // literal: DepthOffset, not RadiusOffset
depth  = RuptureDepthMultiplier·DepthScale + RuptureDepthOffset
maxBlend = (type & 0x21) == 0x21
for each UVisceraGroup with bCanRupture (+0x64), for each UVisceraProxy with bCanRupture (+0xBC):   // 0x140ed1f80
   n,u,v = normalize(M.row0), normalize(M.row1), normalize(M.row2);  O = M.row3;  C = proxy.Location.T
   A_i = rotate(proxy.Location.Q, e_i)·Scale3D_i                    // OBB half axes
   s = dot(n,C) - dot(n,O);  rn = Σ|A_i·n|
   if s - rn < depth:  D = C - O - n·s;  ruv = (Σ|A_i·v| + Σ|A_i·u|)·0.25 + radius·0.5
                       if |D|² < ruv²: hit
hits -> ruleset filter (0x14122d3e0, bIgnoreRulesets) ->
for each hit proxy (skip if maxBlend && proxy.bIgnoreMaxBlend(+0xBD); skip if state final):
   if state.acc < proxy.RuptureThreshold:
      f = 1; if RuptureFalloffFactor > 1e-4 && UVScale > 1e-4: f = 1 - clamp(|O - C|²/UVScale², 0, 1); if f <= 1e-4: skip
      dmg = (UVScale·0.01·f·DisplacementScale·RuptureDamageMultiplier + RuptureDamageOffset)·f
      if ApplyRupture(proxy, dmg, RuptureLimitFraction): count++; if count >= MaximumRuptureCount: break
```

**`ApplyRupture`** (UVisceraComponent vtbl+0x408 = 0x14124f570; state from vtbl at +0xE8):

```
cap = RuptureThreshold·limitFraction;  if cap <= acc: return false
acc = min(acc + dmg, cap)
if !bHoldFinalState(+0xBE) && RuptureThreshold <= acc:
    run RuptureEvents (+0x130), soft-body modifiers (+0x140), spawn RuptureEffects CE (+0xC0) at the hit,
    SpawnablePartSlots (+0xA8) -> spawnable-parts component vtbl+0x3F0, mark ruptured; return true
else: switchable variants: idx = state[4]; thr = SwitchableThresholds[idx] (percent of RuptureThreshold)
      if old·100/Thr < thr <= acc·100/Thr: activate SwitchableVariants[idx] (vtbl+0x400; its CE at +0x70, its
      GPU soft influences §10); if bHoldFinalState and all variants used: state final; return false
```

**Data:**
- Walker proxies (Viscera_MaleStandard): RuptureThreshold 9–12, RuptureBoneId per organ, CE_RupturedVisceraBile. "Guts" switches at 50%.
- Splatter presets: `RuptureDamageMultiplier` on 260 CE infos, `RuptureRadiusMultiplier`/`RuptureInteraction` on 119.
- Defaults (RE_FLESH): DamageMultiplier 1, RadiusMultiplier 0.25, LimitFraction 1, MaximumRuptureCount 1.
- Modify's progressive curves can change DamageMultiplier, LimitFraction, DepthMultiplier, RadiusMultiplier and MaximumRuptureCount (RE_FLESH "Modify").

---------------------------------------------------------------------------------------------------------------------

## 12. After the cut: hidden sections, limb actor, spawnable parts

### 12.1 What the parent hides

The parent hides **no section** for a cut: the body draws only its kept triangles. The geometry under the hole is meant to show:
- the IntA interior shells, which are in DismemberMask and cut like skin;
- the skeleton and viscera slots, which are not in DismemberMask and stay whole.

### 12.2 Limb actor

`DismemberedLimbClass` (UDamageRepercussions +0xF0, BP `BP_DismemberedLimb_AI`) is spawned by 0x1412b2ba0 with:

| Limb field | Value |
|---|---|
| +0x2C0 | parent mesh component (weak) |
| +0x2C8 | parent physics asset |
| +0x2D0 | cut bone name |
| +0x2D8 | region BoneBranchMask |
| +0x308 | initial velocity = force scalar × direction |
| +0x320.. | spawn transform = cut frame relative to the ref bone |

In BeginPlay (0x14124cf80 → 0x141244130) the limb:
- copies the parent's per-LOD subsection visibility (comp +0x688, 0x88 per LOD);
- builds a limb **PhysicsAsset** for the cut bone's subtree (0x14403e380 with bone and branch mask);
- uses the same SkeletalMesh;
- uses `BPC_SplatterMesh_DismemberedLimb_AI`, whose `DA_SplatterParameters_DismemberedLimb_AI.bSharesResources = true`: it shares the parent's splatter resources (RTs, edited buffers).

**Open:** how the limb mesh object selects the **limb** index range (the end-packed triangles / second draw args) instead of the body range. The dismember counter +0x2D4 is carried in the request at +0x208, which may select it.

### 12.3 Subsections / spawnable parts

- `CharacterMaterialMasks` (per mesh): MaterialSectionNames, SectionID, SoftBodyNames, MeatMaterialMask.
- `UVisceraProxy`: VisceraSubsections, BrokenSubsections, SpawnablePartSlots, CutEvents/BreakEvents/RuptureEvents, CutBias, GibbableSectionAttachment.
- The gibbable attachment class (owner of bShareSplatterResourcesOnSpawn): SubSectionNames / ToSpawn, ParentSubSectionNamesToHide / ToShow.

These drive subsection visibility on cut, break and rupture inside `UVisceraComponent` (0x1412365c0 break, 0x140ecc870 per group, 0x14123e710 events) and `USpawnablePartAttachment::OnLimbCut`. Splatter sets' `DismembermentSectionIndexOverride` goes into LOD subsection data +0x44 (§2.2).

**LimbCut (traced; ported in zombie.gd `_viscera_limb_cut`).**

Callers:
- 0x14129a8e0 and 0x1412a7ce0 (the dismember owner) call 0x1412b62b0(cut frame, cut bone, bBisect, bIsLimb).
- That builds the plane from the cut frame's Y row, i.e. the cut normal N, and its origin: normal = +N when
  bIsLimb is 0, −N otherwise; W = n·O. The axis getter 0x140a0e080 is 1-based (EAxis X=1, Y=2, Z=3).
- It then calls `UVisceraComponent::LimbCut` (0x1412450a0), or BisectionCut 0x141236160 when bisecting.

Per VisceraGroup, the group test (0x140ece450):
- **Ownership 0 (Torso):** on the limb mesh every child proxy is culled (0x140eccc80). The body is untouched.
- **Ownership 1 (Limb):**
  - If the cut bone is neither the group bone nor below it (visitor +0x20 = 0x141236690: is groupBone an ancestor
    of cutBone), the limb mesh culls everything.
  - Otherwise 0x140eccd60 tests each proxy under the group (recursive) against the plane, with an oriented box:
    Location = the box, Scale3D = the half extents, × the group's CutMargin.
- The box/plane test is 0x1440a3070: +1 if wholly past the plane, 0 if straddling, −1 if short of it.

**Per CutBias** (proxy +0xB8), the threshold the side value must reach:

| CutBias | Value | Body mesh | Limb mesh |
|---|---|---|---|
| Cull | 0 | 0 | 0 |
| Body | 1 | 1 | 0 |
| Limb | 2 | 0 | 1 |
| BodySentinel | 3 | — | culled |
| LimbSentinel | 4 | culled | — |
| BoxCentre | 5 | 1 at scale 0 (centre only); ruptured: 0 at scale 2 | same |

**At or past the threshold:**
- A proxy wholly past the plane is culled (visitor +8 = 0x14123daf0):
  - its state is marked gibbed;
  - its subsections are hidden through the component vtable +0x3F0;
  - its events run.
- Straddling proxies are also culled. The first straddler on the mesh where (count & 1) == bIsLimb goes through
  visitor +0x10 (0x141243820) instead: the same, but if the proxy has a GibbableSectionAttachment, that
  attachment is spawned (vtable +0x260).

**After a group returns 1,** 0x141258ba0 runs its CutEvents: conditioned subsection show / hide and attachment
toggles. The ZombieStandard groups have none.

**DismemberMask:** sections outside it are not split by DI2. They stay whole on both meshes and are culled per proxy
here. GoreBody.di2_cut marks those sections `di2_cut`, so the recreation's subtree discard no longer applies.

**BisectionCut** (0x141236160, used instead of LimbCut when bisecting; ported in `_viscera_limb_cut(…, bisect = true)`).

Per group, 0x140ecc800 decides:
- **Ownership 0 (Torso):** the per-proxy CutBias plane test (0x140eccd60) runs on both meshes, so the guts and ribs
  are split by the plane.
- **Ownership 1 (Limb):** the group goes whole to one side. It is culled where (cutBone is an ancestor of
  groupBone) != bIsLimb, so groups below the cut go with the upper piece and the rest stay on the body.

On top of that, BisectionCut collects the cut bone's child branch bones by region branch mask (param 5) and culls
Limb groups at or under those bones on the matching side. For a spine cut this repeats the rule above, so the port
doesn't model it.

### 12.4 Bisection (traced; ported in zombie.gd `_bisection_bone`)

**Decision.** `CT_HitReact_Death_Zombie` starts with the module `CT_HitReact_Bisect_Zombie`. Corpses can also be
bisected, through `CT_HitReact_Dead_AI` (not Ragdoll, not launch, #HasALeg). The module returns "Should Bisect"
when all of these hold:
- `CanBisect`;
- `#CanBeBisected`;
- either BisectionChance ≥ 1 (then, if `ThrownAttack`, it also needs `CanBisectWhenThrown`), or BisectionChance ≥
  rnd(0, 1).

`#CanBeBisected` (DT_ExpressionAliases) =
`({Hit}.KillingBlow || {Victim}.Dead) && {Hit}.Torso_Bisectable && !{Hit}.ArmouredTorsoImpact && {Victim}.HealthFraction_Torso_Bisectable <= 0.65`.

**Facts.** The impact KB writer (0x1413cc2d0) copies them from the damage's ImpactData:
- `CanBisect` = bCanCauseBisection (+0x44);
- `BisectionChance` (+0x48).

**HeavyAttackChargeBisectionRequirement** is on AMeleeWeaponItemActor (+0xAB8). Its ctor (0x141d0aba0) default is 0
and no asset sets it.

**Response.** `UBisectionTriggerResponse::TriggerResponse` (0x14125b8c0, vtable 0x145393490 +0x238) finds the
DamageRepercussions, MultiPartHealth and viscera components. If the character was already bisected (+0x42A), it
logs and returns. Otherwise:
- **Point impacts** (`ProcessPointBisectionTrigger` 0x14124f2a0):
  - for the hit bone's parts that are in `BisectionConfig.BisectableParts`;
  - 0x1412a0610 picks, among that part's bones, the one whose kind-2 (safe) region socket is nearest the hit.
- **Radial impacts** (`ProcessRadialBisectionTrigger` 0x14124fb90): a random bone of each part in
  `RadialImpactBisectionConfig.BisectableParts`, via (rand() & 0x7fff) · 3.05e-5 · count.
- 0x1412b3ec0 then:
  - sets the bisected flag;
  - builds a frame from the impact direction;
  - calls the dismember entry 0x14129a8e0 with that bone and request flags 0x102 / 1 (bBisect).

**Data:**
- BPC_DamageRepercussions_AI: BisectableParts = [Torso_Bisectable] in both configs. The Mutator overrides both to [].
- DT_ZombiePartBoneDefinition: Torso_Bisectable = spine_04, spine_03, spine_02.
- Only some MultiPartHealth definitions include Torso_Bisectable: Thug, Screamer, Slobber, Whipper, Reformer and
  their variants. Walker, Runner, Shambler, Suicider, Mutator and Butcher do not, so those archetypes are never
  bisected.

---------------------------------------------------------------------------------------------------------------------

## 13. Porting (Rust GoreBody + Godot)

Mirror `tools/re_dismember/dismember_ref.py` function by function. All constants below are DI2's.

### 13.1 Load-time data per body

1. **Bone topology** (§4, `bone_topology`):
   - Branch roots clavicle_l 2, clavicle_r 4, thigh_l 8, thigh_r 16, neck_01 32, default 1.
   - Case-sensitive substrings `twist` / `Volume` flag a bone and freeze depth below it; `head` freezes depth below it.
   - break child = first unflagged child in bone order.
   - Store per **section-local** bone (via the section BoneMap) for the classification.
2. **Region sockets** (§5.1) from the mesh JSON: `<bone>_safe_region`, `_1`, `_2` …; `<bone>_break_region` …
   - loc, rot (FRotator → FQuat, UE formula), scale = half-extents, BoneBranchMask.
   - Bones without a region cannot be dismembered or broken. The hit walks up the parent chain to the first bone that has one.
3. **Masks** (§3) from `DIEngineMaterialMasks`, bit = material slot. Needed: DismemberMask, BinaryDismemberMask, SkeletonVisceraMask, InitiallyHiddenMask, WriteSplatterMask, ClothingProxyMask, DeformationMask, SoftBodyDeformationMask.
4. **Ref-pose bone matrices** = CachedComposedRefPoseMatrices: compose the mesh's ref pose; the self-test uses SKEL_ZombieStandard as a stand-in.

### 13.2 Dismember (2) / DismemberWithDecal (3)

1. **Hit → bone.** Take the hit bone and climb to the first bone with a `_safe_region` socket. The Walker has them on: upperarm_l/r, lowerarm_l/r, thigh_l/r, calf_l/r, head, neck_01, neck_02, spine_02/03/04.
2. **Decal frame** `F = [R.Y; −R.Z; −R.X; hitLocation]` from the hit rotator (**source of the rotator: open**, §14). Ref space: `Fref = F · inverse(Bcur) · Bref`.
3. **Placement** (§5.2): evaluate every region socket and keep the best score. Cut frame = [X; N; Z; O]; SafeRegionMatrix as §5.3 (spine sockets use offset 50 cm and scale 1.333).
4. **Classify every triangle** of every section in DismemberMask (§6, `classify_triangle`):
   - positions in bind pose;
   - d = `(p − O)·N`;
   - TargetBoneData = (section-local hit bone, depth, branch | region mask, 0);
   - Binary per BinaryDismemberMask.
   - Body keeps code-3 triangles. Code-0 triangles form the limb mesh. Code 1/2 are removed from both.
5. **Limb:** spawn a separate skinned instance that draws only the limb triangles. It shares the body's splatter textures (bSharesResources) and gets a physics body set for the cut bone's subtree, plus that branch mask. Initial velocity = (`Dismember.HeavyAttackForceScalar` if heavy else `Dismember.ForceScalar`; both default **3.5**) × force along the hit direction. It is forced for `Dismember.ForceVelFrameCount` = **2** frames.
6. **Type 3 only, radial stamp** (§8), in bind-pose space of the body (and the limb, via the shared textures):
   - `y = 2·((p − O)·N)/UVScale`; `s = SR·p`; `r = sqrt(s.y² + s.z²)`;
   - `w = (|y|<1)·(1 − sat(4(r−1)))`; `uv = sat((s.z/r, y)·0.5 + 0.5)`;
   - RT write as any decal (§3.3 of SHADERS_FLESH with fade = 1, wrap = 1);
   - vertex depth with the RADIAL permutation (no 3/|D| since bAbsoluteDeformation = false).
7. **Rupture** (§11) runs for type 3 (it has the decal bit) with the **hit** rotation frame.
8. **Over time** (§2.1): spawn the gradual effect's particle system and fluid; re-apply OverTimeEffect.SplatterInfo every update with `DisplacementScale × dt/Duration` until Duration.

### 13.3 BoneBreak (8) / BoneBreakWithDecal (9)

1. **Hit → bone**, climbing to the first bone with `_break_region` (Walker: upperarm, lowerarm, thigh, calf). Placement as §5 with the break sockets.
2. **Per vertex** in DismemberMask sections, and SkeletonViscera sections (§7.2, `break_vertex`):
   - d = (p − O)·N;
   - re-skin with 4th bone = break child, weight sat(d/10);
   - ancestor/same-depth influences × (1 − sat(d/10)); renormalise to the original sum; quantise to 8 bits.
   - This is permanent: it rewrites the skin weights.
3. **Physics:** move the break child's joint pivot to O (§7.3), so the re-skinned segment hinges there.
4. Type 8 has **no RT stamp and no rupture**. Type 9 adds §8's radial stamp.

### 13.4 Clears (64 / 80)

- **ClearToValue:** for sections in WriteSplatterMask and not ClothingProxyMask, set both splatter RTs (all channels) to DisplacementClearValue. For ClothingProxyMask sections, set Disp.R and Disp.A to 0. Set every vertex's deform depth to DisplacementClearValue (DeformationMask sections).
- **ClearSplatter / ClearAll:** the same, but both RTs go to 0.
- Both ignore position and box: the whole section.

### 13.5 SoftInfluenceUpdate (4)

Never from hits. On viscera switchable variants with `VisceraSoftBodyGPUInfluence` children: per soft-body vertex, `s = sat(Amount·max(1 − dist²/(Fade² + 1), 0) + s)`, quantised to 10 bits (§10). Capsules come from the viscera data. Max 4 per call.

### 13.6 Rupture (every hit with the decal bit)

§11 verbatim:
- slab/OBB proxy test with `depth = DepthMult·DepthScale + DepthOffset` and `radius = RadiusMult·UVScale + DepthOffset`;
- damage `(UVScale·0.01·f·DisplacementScale·DamageMult + DamageOffset)·f`, `f = 1 − clamp(|O−C|²/UVScale²)`;
- accumulate up to `Threshold·LimitFraction`;
- rupture at Threshold unless bHoldFinalState;
- at most MaximumRuptureCount ruptures per hit.

---------------------------------------------------------------------------------------------------------------------

## 14. Unresolved (explicit)

1. **Hit rotation for gameplay dismember/break.**
   - What we have: `UBodyPartState.LastHitRotation` (+0x9C), read by 0x1412a6690 / 0x141293a60. It sets the initial cut normal (−R.Z).
   - Open: the code that writes it from the impact.
     - Tried: a store scan for functions writing +0x8C/+0x90/+0x9C/+0xA8 in 0x140c00000–0x142000000 (`storescan.py`). It found only constructors and generic struct copies (0x141b26a20, 0x141b49ff0, 0x141baf7a0, 0x141bd9ad0).
     - Tried: a scan for `GameplayState := 2/3` stores. It found 0x141af3f80, a different class.
     - The writer probably uses 16-byte (movups) copies.
   - This matters because placement corrects the plane only within the region constraints, so the initial normal still shapes the cut.
2. **Limb rendering:** which index range or args the limb actor's shared mesh object draws (§12.2). Also the full StaticIArg slot semantics (§6).
3. **Subsection switching** on cut/break/rupture: VisceraProxy BrokenSubsections, CutBias, SpawnablePartSlots, the gibbable attachment (§12.3). Also what DismembermentSectionIndexOverride (+0x44) selects.
4. **`ManipulateConstraint` frame math** (§7.3) and the PhysicalizedReaction / viscera reactions to a break.
5. **Default global gradual effect** when no candidate matches (0x141c612d0 +0x118).
6. ~~Dismember cvar defaults~~ resolved: ForceScalar 3.5 and HeavyAttackForceScalar 3.5 (0x1404be830 / 0x1404be8a0, both read 0x144bcf0e4); ForceVelFrameCount 2 (global 0x14687ad94).
7. **Walker skeleton slots 14/15** have no LOD section in the CUE4Parse export (§3). The ref pose used by the self-test is the skeleton's, not the mesh's own.
8. **Soft-body consumption** of the influence channel (SoftBody plugin) (§10).
9. `GetBoneEndAxis` / `boneend_region`: present but not used by placement. Not traced further.
10. **ClothingInteraction filtering** of the stamp (0x140a11e80 tests decal +0x65 per section). RE_FLESH describes a texture swap instead; both may apply. Not re-verified here.

---------------------------------------------------------------------------------------------------------------------

## 15. Reproduce

```
tools/re_dismember/decomp.sh <name> <addr...>                  # own Ghidra project (import: see extracted/ghidra_dismember/import.log)
python tools/re_dismember/fn.py <addr>                         # print a decompiled function (splatter_all.c + mine)
miniconda python tools/re_dismember/params.py "Break|Geometry|StaticIArg|CopyIndices|DeformMesh"   # cb0 bindings
miniconda python tools/re_dismember/shdis.py 939 GeometryIndicesCS 904 BreakCS ...                 # decompile CS
python tools/re_dismember/blendstate.py 0x140a08e80 0x140a08b80 0x140a09480                        # clear blends
python tools/re_dismember/meshedit_data.py > extracted/ghidra_dismember/meshedit_data.txt          # data survey
python tools/re_dismember/masks_dump.py --json extracted/ghidra_dismember/body_masks.json          # masks + sockets
python tools/re_dismember/dismember_ref.py --selftest                                              # reference impl
python tools/re_dismember/export_dismember_data.py     # -> game/assets/di2/<body>/<body>.dismember.json (glTF space)
python tools/re_dismember/make_fixtures.py             # -> tools/re_dismember/fixtures/dismember_fixtures.json
cd rust && cargo test -p gore-core dismember           # the Rust port (gore-core/src/dismember.rs) vs the fixtures
```

**Port.** `rust/gore-core/src/dismember.rs` mirrors `dismember_ref.py` function by function: placement in UE space (f64), the per-vertex passes in f32 with glam matrices, and a glTF-space entry point (`DismemberData`). Its tests check every function against the reference's outputs on the four bodies' real data, in UE space and through the glTF conversion. `dismember_ref.py` also carries the radial PS / p82 vertex-depth element (`radial_texel`, `radial_vertex_depth`) and the clears (`clear_rt_texel`, `clear_vertex_depth`).

**Exporter checks** (printed by `export_dismember_data.py`):
- glb joints are a subset of SKEL_ZombieStandard in the same order, with the same parents.
- The glb bind pose of the 14 region bones equals the SKEL ref pose to 1.5e-5 (Walker, Runner, Shambler). The Thug's ref pose differs (up to 41 cm; its own proportions), and so do the face bones of every body.
- glb primitive *i* = LOD0 section *i* (material names asserted).
- The interior (IntA) sections and some viscera have fewer glb vertices than LOD0 sections. The glb drops unused vertices.
- Each section's `bones` (joints with weight > 0) stand in for its BoneMap, which the extracted JSON lacks.

Key decompiles:

| File | Contents |
|---|---|
| `dispatch.c` | 0x1409ec110 BreakCS dispatch, 0x1409f29f0 consolidation, … |
| `f05050.c` / `f06270.c` | placement |
| `f38a0.c` | dismember requests |
| `f1af60.c` | processing |
| `f12a40.c` | clear |
| `f9190.c` / `ffa380.c` | deform/soft packing |
| `f256940.c` | rupture |
| `fae1f0.c` / `f29b260.c` | gradual effects |
| `f24cf80.c` | limb |
| `shaders/Global_*` | GeometryIndicesCS 939, BreakCS 904, GeometryCS 903/893, Copy 908, StaticIArg 941, DeformMesh p80/p83/p90…p94 |
