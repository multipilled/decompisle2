# DI2 viscera and spawnable parts

This covers the viscera and spawnable parts of the four zombie bodies the port ships: walker `SK_WalkerMaleCas01`, runner `SK_RunnerMaleCas01`, shambler `SK_ShamMaleCas01` and thug `SK_ThugA01`.

- **Data:** `game/data/viscera_parts.json`, written by `tools/with_cpu.sh <you> python tools/build_viscera_parts.py` (about 10 s; it scans every extracted JSON and runs di2x and pack_materials, so it goes through the shared CPU throttle).
- **Meshes:** `game/assets/di2/<body>/parts/` (eyes, jaw, and the shared skeleton and viscera meshes), each with its `pack_materials` manifest.
- **Sources:** DI2's own assets (di2x JSON plus the cooked meshes) and static RE of `DeadIsland-Win64-Shipping.exe`. The RE used headless Ghidra in a project of its own, `extracted/ghidra_viscera/DI2vis`, with the script class `VisceraDecompileAt`; the decompiled C is in `extracted/ghidra_viscera/*.c`. Nothing was run.
- **Blueprints:** the behaviour of `BP_Part_Jaw` and `BP_Part_Eye` comes from their Kismet bytecode, read with a scratch CUE4Parse dumper using `ReadScriptData`.

Addresses below assume image base `0x140000000`. Everything stated as fact is read from data or code. Items marked **UNVERIFIED** are not.

---

## 1. Summary per body

| | walker | runner | shambler | thug |
|---|---|---|---|---|
| named subsections | 125 in 19 sections | 137 in 18 | 135 in 16 | 115 in 15 |
| head viscera (skull, brain, `Sec_Jaw`) | section 10, 14 subsections, in body glb | section 2, 14, in body glb | section 2, 14, in body glb | section 4, 15 (two `Sec_Jaw`), in body glb |
| torso viscera (organs, ribs, spine) | sections 11/12/13 (33+7+6), in body glb | section 12 = `SK_ZombieViscera` (57), **parts/SK_ZombieViscera.glb** | section 10 = `SK_ZombieViscera` (57), **parts/** | section 12 (36), in body glb |
| limb bones / broken bones | 14 = `SK_Skeleton` (28) / 15 = `SK_SkeletonBreak` (24), **parts/** | 13 / 14, **parts/** | 11 / 12, **parts/** | section 11 (52: bones and `_Break` together), in body glb |
| `InitiallyHiddenMask` | section 15 (broken bones) | 14 | 12 | 11 (the whole skeleton section) |
| `SkeletonVisceraMask` | 14, 15 | 13, 14 | 11, 12 | 11 |
| VisceraAsset | `Viscera_ZombieStandard` (91 proxies, 24 gibs, 15 switchable variants) | same | same | `Viscera_Thug` (88 proxies, 24 gibs, no variants) |
| SpawnableParts | `DA_SpawnableParts_Walker` | `DA_SpawnableParts_Runner` | `DA_SpawnableParts_Shambler` | `DA_SpawnableParts_Walker` (the walker's eye and jaw meshes) |
| part meshes | `SK_WalkerEyeBallLeft/Right`, `SK_WalkerJaw` | `SK_Runner*` | `SK_Shambler*` | `SK_Walker*` |

Viscera subsection names that do not exist on a body are listed per body under `viscera_resolved`. In DI2 they simply cull nothing.
- **Walker:** the `*_Exposed` intestine and rib variants, the `Ribs*Front` set and `RibsMidR`. Its viscera mesh predates the shared `SK_ZombieViscera`, so the walker never shows the 15 switchable "exposed" variants.
- **Runner and shambler:** no unresolved names.
- **Thug:** no unresolved names; it has no variants to resolve.

---

## 2. Mesh subsections

### 2.1 How a cooked section stores subsections

Every DI2 cooked `FSkelMeshRenderSection` ends with a `TArray` of 18-byte items:
- `u32 NumTriangles`
- `u32 BaseIndex`
- `u32 BaseVertexIndex`
- `u16 NumVertices`
- `u16 flag`
- `u16 0`

(recon/DEFORM_STREAM.md §3 found these items. Their meaning is resolved here.)

The items are the mesh's **named subsections**, one-to-one with the SkeletalMesh's `CharacterMaterialMasks` asset user data:
- `MaterialSectionNames[i]` is the name of subsection `i`;
- `SectionID[i]` is its render section;
- `SoftBodyNames[i]` is its soft-body name.

Subsection `i` is the i-th item, counting through sections in order. The item counts per section match `SectionID` on all four bodies.

### 2.2 SharedRenderData

`USkeletalMesh.SharedRenderData` is a DI2 extension: `[{Mesh, Mapping: [{LOD, BaseSection, SharedSection}]}]`. A section listed there is cooked **disabled and empty**: its BaseIndex and BaseVertexIndex equal the next section's. DI2 renders it from `Mesh`'s `SharedSection`, so CUE4Parse's glb export of the body leaves it out.

The section's trailing two bytes (`di2_tail`) hold the 1-based index into `SharedRenderData`. The body's items for such a section equal the shared mesh's items once rebased (`items_match_shared_mesh: true` on every body).

| body | section → shared mesh |
|---|---|
| walker | 14 → `SK_Skeleton`, 15 → `SK_SkeletonBreak` |
| runner | 12 → `SK_ZombieViscera`, 13 → `SK_Skeleton`, 14 → `SK_SkeletonBreak` |
| shambler | 10 → `SK_ZombieViscera`, 11 → `SK_Skeleton`, 12 → `SK_SkeletonBreak` |
| thug | none (its skeleton and viscera sections are enabled) |

Each body gets its own copy of the shared glbs in `parts/`, with the glb material renamed to the material the body uses for that section. For example, the walker's `SK_Skeleton.glb` uses `MI_WalkerSkeleton`.

The shared meshes are skinned to `SKEL_ZombieStandard`: their joints are a subset of the body skeleton, so they bind by bone name.

### 2.3 Triangle ranges in the glbs we load

CUE4Parse writes each section's triangles in index order and drops degenerate triangles; SharpGLTF dedups vertices. The builder therefore matches every glb triangle to its cooked triangle by exact float32 positions, regardless of winding.
- Every glb triangle matched.
- Each subsection is one contiguous glb triangle range, given as `glb_tris: [first, count]`.
- The thug's section 12 drops 2 degenerate triangles: 15344 cooked, 15342 in the glb.

A geometric spot check passed: subsection centroids sit inside their DI2 VisceraProxy boxes (`Sec_Jaw` → Jaw proxy, `Heart` → Heart, thug `BrainLeftFront`, and others).

### 2.4 DIEngineMaterialMasks (u64 bit per render section)

Decoded per body under `bodies.<b>.masks`. Bits beyond the section count are kept in `bits_beyond_section_count`; `SplatterGroupMask` and `SortBiasMask` have such bits, and their meaning is **UNVERIFIED**.

| mask | meaning, from where it is used |
|---|---|
| `InitiallyHiddenMask` | sections hidden at spawn: the broken-bone section, or the thug's whole skeleton section |
| `SkeletonVisceraMask` | the skeleton sections (bones and broken bones) |
| `DismemberMask` | every section except the viscera, skeleton and IntA ones |
| `SoftBodyDeformationMask` | head and torso viscera sections |
| `BinaryDismemberMask` | eyes, eye overlay, hair: binary rather than graded dismember (dismember-re territory) |
| `ClothingMask`, `WriteSplatterMask`, `DeformationMask`, `TrimMask`, `TrimHQMask`, `RegeneratesMask` | as named |
| `MeatMaterialMask` | from `CharacterMaterialMasks`: the viscera, skeleton and IntA sections |

`SoftBodyMaskMap` (name → u64) is **per subsection**, with bit = `subsection_index & 63`; the x64 shift wraps, so indices of 64 and above alias. `soft_body_mask_map.<name>.subsections` gives the exact indices from `SoftBodyNames`.

### 2.5 Culling by name (native)

`CullSubsectionByName` (0x140ece1f0) and `UnhideSubsectionByName` (0x140ed2dc0) both lead into 0x140ecd5a0.

**Lookup.**
- Look the name up in the mesh's `MaterialSectionNames`. Every match is toggled, so the walker's two `Kidney1` subsections in sections 12 and 13 go together.
- FName comparison is **case-insensitive**, so `UpperarmR1` matches `UpperArmR1`.

**Visibility.**
- Matching sets a per-LOD visibility byte on each subsection (USkinnedMeshComponent 0x143646f60, all LODs) and dirties the render state.
- It returns true only when the visibility actually changed.
- A name that matches nothing is a silent no-op: DI2 data contains several, such as `Guts`, `Jaw` and `RibsLowerRFrontzz`.
- Culling only stops drawing. No geometry is removed and nothing is unhidden later unless something explicitly unhides it.

---

## 3. The viscera asset

`viscera_assets.<name>` is a direct, normalised copy of the VisceraAsset tree. Defaults below come from the native constructors and apply wherever the data omits a field.

**VisceraGroup** (ctor 0x140ed66a0):
- `name`
- `bone`: the BoneName
- `ownership`: Torso or Limb
- `cut_margin`: default **0.75**
- `can_rupture`: default false
- `shootable`: default false
- `switch_on_dismemberment`
- `children`

Groups in `Viscera_ZombieStandard`:
- Guts: Torso, 24 proxies, all can rupture, thresholds 6–16
- Head: bone neck_01, 17 proxies, 12 can rupture, thresholds 1–7
- Skeleton: 14 proxies, 6 can rupture at 30
- LeftArm, RightArm, LeftLeg, RightLeg: Limb, cut_margin 0.75, nothing ruptures

**VisceraProxy** (ctor 0x140ed6710):
- `proxy_id`: default −1
- `box`: the Location FTransform; Scale3D is the box **half extent in cm**. `box.gl.half_extents` is in metres.
- `subsections`: VisceraSubsections, subsection names
- `broken_subsections`
- `spawnable_part_slots`
- `cut_bias`: ECutBias Cull 0, Body, Limb, BodySentinel, LimbSentinel, BoxCentre 5. Default **Cull**.
- `can_rupture`: default false
- `ignore_max_blend`: default **true**
- `hold_final_state`: default false
- `rupture_effects`: a CE
- `rupture_threshold`: default **1.0**
- `rupture_bone_id` and `breakage_bone_id`: indices into SKEL_ZombieStandard's reference skeleton, resolved to `rupture_bone` and `breakage_bone`
- `switchable_thresholds` and `switchable_variants`
- `gib`
- `shadow_capsules`: body names in the mesh's ShadowPhysicsAsset `PA_ZombieCapsuleShadows`
- `events`: Cut / Break / Rupture events. All are empty in these two assets.
- `soft_body_movement_modifiers`

**VisceraSwitchableVariant** (ctor 0x140ed6ab0):
- `root_proxy_id`: default −1
- `subsections`: shown when the variant switches in
- `switch_threshold`: default **100**; this is the percentage of the rupture threshold
- `activation_effects`: a CE
- soft-body modifier and GPU-influence children

**VisceraSwitchableGroup:** `proxy_ids`, plus proxies that switch together (the "Intestine Group" and "SmallIntestine Group").

**VisceraGibbableSubSection**, under its proxy:
- `actor_class`: `BP_SkeletalMeshSubSectionAttachment_Gib_C`
- `physics_asset`: one box body on a body bone, PhysMaterial `PM_Flesh_Dismembered` (Friction 5, Restitution 0)
- `spawn_subsections`: shown on the gib
- `hide_subsections`: hidden on the body
- `socket`
- `location`
- `modules`: SpawnOnDetachModule (spawns itself) and GibAttachmentModule

**VisceraBreakageEffect**, on limb proxies:
- `effect`: `CE_BoneBreakout`, whose shards SM_BreakageA-E are already in game/assets/di2/gore
- `splatter_group`: the proxy's name
- `splatter_set`: `SplatterSet_BoneBreakout_ZombieStandard` or `_Thug`. Neither is in game/data/splatter.json yet (`splatter_set_in_splatter_json: false`).
- `location`

**VisceraStateBlacklistRuleset:** `invalid_states` (ints) and the `proxies` they bind. Their runtime use was not decoded (§5.3).

**Soft body:** `VisceraSoftBodyModifer` (ModifierName / AddAmount, e.g. BreakRibs, ExposeGuts) and `VisceraSoftBodyGPUInfluence`. DI2's proprietary SoftBody plugin consumes them; they are not ported.

---

## 4. How viscera are hidden and revealed

1. **Shader reveal (always on).**
   - The viscera, skull and bone sections are drawn inside the body all the time.
   - The skin and the IntA shell are cut away where the FLESH wound depth reaches about 0.95 (recon/SHADERS_FLESH.md §7), which uncovers whatever subsections are still visible underneath.
2. **Name culling, which CEs and parts do.**
   - `CosmeticEffect_Viscera` culls `RawVisceraToCull` (§6.1).
   - A spawned part hides its `OriginalPartToHide` (§5).
   - `HideProxy` culls a proxy's subsections when a variant switches.
3. **Rupture from FLESH splatter.** Every splatter stamp applied to the body accumulates damage on nearby rupturable proxies (§4.1).
4. **Switchable variants.** As a proxy's damage passes `SwitchThreshold` percent, its subsections are swapped for the variant's "exposed" subsections (§4.2).
5. **Gibs** (§4.3).
6. **Dismember and bone break.** Limb cut, `BrokenSubsections`, `_Break` bones and `InitiallyHidden` belong to the dismember mesh-edit path, which the dismember-re session owns. LimbCut (0x1412450a0) and BisectionCut (0x141236160) are UVisceraComponent UFUNCTIONs and were not decoded here.

### 4.1 Rupture from splatter

`UVisceraComponent::Splatter` (exec 0x141e37490 → 0x141256940) runs for every stamp. "Stamp" fields are the stamp's `FSplatterMeshInfo` (RE_FLESH.md layout); positions are in reference-pose component space.

**1. Gate.** The stamp counts only if all of these hold:
- `(SplatterType & 1)`: one of the *Decal types;
- `RuptureInteraction != NoRupture`;
- `MaximumRuptureCount > 0`;
- `RuptureDamageMultiplier >= 1e-4` or `RuptureDamageOffset >= 1e-4`.

**2. Sizes.** As compiled, the radius adds the **depth** offset (+0x80); `RuptureRadiusOffset` is not read.
- `radius = RuptureRadiusMultiplier · UVScale + RuptureDepthOffset`
- `depth = RuptureDepthMultiplier · DepthScale + RuptureDepthOffset`

**3. Candidates** (0x140ed1f80). For every group with `can_rupture`, take every descendant proxy with `can_rupture`.
- n, t and b are the stamp frame's X, Y and Z axes (projection direction and tangents). o is the stamp origin. c and R are the proxy box centre and rotation, and S its half extents.
- `d = n·c − n·o`
- `rn = Σi |n·(Si R ei)|`
- Keep the proxy if `d − rn < depth` **and** `|c − o − n d|² < (0.25 (Σi|b·Si R ei| + Σi|t·Si R ei|) + 0.5 radius)²`.

**4. Skips.**
- Proxies already gibbed or in their final state.
- Proxies whose damage is ≥ RuptureThreshold.
- For **MaxDecal** stamps (`SplatterType & 0x21 == 0x21`): proxies with `ignore_max_blend`, which is the default. Max-blended wounds, far from death, therefore don't rupture most viscera.

**5. Amount.**
- Falloff: `f = 1 − min(|o − c|² / UVScale², 1)`, applied when `RuptureFalloffFactor > 1e-4` and `UVScale > 1e-4`. Otherwise f = 1. Skip the proxy if f ≤ 1e-4.
- `amount = (UVScale · 0.01 · f · DisplacementScale · RuptureDamageMultiplier + RuptureDamageOffset) · f`

**6. ApplyProxyDamage** (UVisceraComponent virtual +0x408, 0x14124f570).
- `cap = RuptureThreshold · RuptureLimitFraction`. If damage ≥ cap, nothing happens.
- Otherwise `damage = min(damage + amount, cap)`.
- If `!hold_final_state` and `damage ≥ RuptureThreshold`, the proxy **ruptures**:
  - emit RuptureEvents;
  - apply SoftBodyMovementModifiers;
  - play `rupture_effects` at the hit;
  - call `DamageRepercussions.DetachOrDeletePart` for every `spawnable_part_slots` entry (SkullLeftFront → left eye, SkullRightFront → right eye, Jaw → jaw);
  - mark the proxy ruptured;
  - count it toward the stamp's `MaximumRuptureCount`.
- Otherwise, see §4.2.

**Proxy state** (map value): float damage @0, float cap @4, float falloff @8, bool gibbed @0xc, bool final @0xe, int variant index @0x10.

Rupture effects by themselves do not cull: the skull and brain rupture CEs stamp `DA_SplatterSet_Rupture*` and play particles. Only `CE_Ruptured_SkullLeft/RightFront` (and the thug versions) contain viscera or part effects, which delete the eye part.

### 4.2 Switchable variants

With `p = 100 · damage / (RuptureThreshold + 1e-4)`, a variant fires when `SwitchableThresholds[k]` falls in `(p_old, p_new]` and `SwitchableVariants[k]` is set. Here k is the proxy's current variant index. The variant applies to the proxy, or to every proxy of its VisceraSwitchableGroup. `SwitchVariant` is +0x400, 0x141258ad0.

When a variant fires:
1. `HideProxy` (+0x3f0, 0x141243e50) culls the proxy's `subsections`, its `broken_subsections` and the subsections of all its variants, and switches off its `shadow_capsules`.
2. Unhide the variant's subsections.
3. `ActivateVariant` (+0x3f8, 0x141232720) applies the soft-body modifiers and GPU influence.
4. k += 1.
5. Play `activation_effects`.

When `hold_final_state` is set and k has reached the variant count, the state is final.

Thresholds in data: RibsUpperL and RibsUpperR switch at 95 %; the other ribs, guts and intestines at 50 %.

### 4.3 Gibs

`SpawnRandomGibs` (0x141256850) and `SpawnRandomGibAttachments` (0x141256780) take `MaximumGibsToSpawn`.
- Candidates are every gib whose owning proxy is not gibbed.
- While more than the maximum remain, remove index `min(int((rand() & 0x7fff) · 3.051851e-05 · count), count − 1)`.
- Each chosen gib marks its proxy gibbed, spawns its ModularAttachment on the body mesh (virtual +0x260) and detaches.

The gib actor (`BP_SkeletalMeshSubSectionAttachment_Gib`):
- shows `spawn_subsections` of the body mesh and hides `hide_subsections` on the body;
- simulates on its PhysicsAsset;
- has ForcedDeSpawnDelay 3.5 s and despawn conditions `Debris`.

**Callers (traced):** each function has one native call site, its UFUNCTION exec thunk (SpawnRandomGibs from 0x141e373c0, SpawnRandomGibAttachments from 0x141e37340), so only Blueprints call them. A scan of the name tables of all 8,475 BP_ / AN_ / ABP_ / GA_ / GC_ / GE_ / CE_ packages in the install finds two:
- `Expansion02/.../Reformer/BP_AnimNotify_SpawnGibs_Reformer` (the Reformer's anim notify);
- `Expansion02/Gameplay/EnvHazards/FallenTurbine/BP_EnvHazard_FallenTurbine`.

No base-game zombie, weapon, explosion or cosmetic effect calls `SpawnRandomGibs`. Ordinary combat still gets gibs another way: `UVisceraComponent::LimbCut` spawns a straddling proxy's `GibbableSectionAttachment` on one side of a limb cut (recon/RE_DISMEMBER.md §12.3 "LimbCut"). The `bCanSpawnGibs` flag on `CosmeticEffect_FluidParticle` (e.g. CE_Explosion_Suicider_Blood) is the fluid system's own gibs, not this path.

### 4.4 VisceraShot

`UCosmeticEffect_VisceraShot` (Radius default 10, at 0x1412563e0) moves the hit point into the hit bone's reference pose. It then tests every shootable group's proxies with `ProxyPointTest` and queues the hits.

`ProxyPointTest` (0x1440a32e0), checked lane by lane in the disassembly:
- `l = InverseTransformPosition(box, p)`, which divides by Scale3D;
- `dx = |l.x|` **only**, because the y and z lanes are masked;
- `m = min(dx, |e.x|, |e.y|, |e.z|)` with `e = Scale3D · CutMargin`;
- hit if `(dx − m)² < Radius²`.

**No asset uses VisceraShot**: none of the 2545 extracted CE assets contains one.

---

## 5. Spawnable parts

### 5.1 Data

These are the `bodies.<b>.spawnable_parts[]` fields. The native layout is `FSpawnablePart`, 0x70 bytes.

| field | value in these assets |
|---|---|
| `slot` | LeftEye 0, RightEye 1, Jaw 2 |
| `original_part_to_hide` | `Sec_EyeL` / `Sec_EyeR` / `Sec_Jaw`, with `original_part_subsections` the indices on this body (the thug has two `Sec_Jaw`, 16 and 17) |
| `attach_socket` + `socket` | SKEL_ZombieStandard sockets: `eye_l_spawn` (bone eye_l, (0, 0.5, 0) cm, roll 180), `eye_r_spawn` (eye_r, (0, −0.5, 0), roll 180), `jaw_spawn` (head, (3.27, 2.97, 0), yaw 91.18, roll −90). UE and glTF forms are both given. |
| `attach_offset` | identity |
| `class_to_spawn` | null, so the attachment path is used |
| `attachment_spec` → `spec[]` | SkeletalMeshAttachmentSpec: `mesh` (SK_*EyeBall*/SK_*Jaw on SKEL_EyeBallLeft/Right/SKEL_Jaw, no PhysicsAsset), `actor_class` BP_Part_Eye_C/BP_Part_Jaw_C, socket, `location` (≈identity), `attachment_instance` SpawnablePartAttachment with `BoneNameForVelocity: head`, plus `glb` and its packed `materials` |
| `preset_splatter` | `DA_SplatterSet_LeftEyeReveal` / `RightEyeReveal` / `JawReveal`, all present in game/data/splatter.json |
| `detachable` | eyes **false**, jaw **true** |
| `spawned_fact` | eyes `EyeLoose`, jaw `JawDislocated` |
| `detached_fact` | None |

### 5.2 Behaviour

Native code in `UDamageRepercussionsComponent` keeps per-slot state: spawned, detached, deleted, and weak pointers to the part.

**SpawnPart(slot)** (0x1412a4950 → SpawnPartForMesh 0x1412a4790):
1. Skip if the slot is already spawned.
2. Hide `OriginalPartToHide` on the body. **Abort if that hid nothing**: the subsection was already hidden, for example by a CE cull or because the head is gone.
3. Spawn the AttachmentSpec on the body mesh at the socket.
4. Stamp `PresetSplatter` on the body.
5. Set spawned, and set `SpawnedFact` true in the zombie's knowledge base.

**DetachPart(slot)** (0x1412a4660): requires spawned, not detached, not deleted, and `detachable`. It reads the body's physics linear velocity and angular velocity (in deg/s) at `BoneNameForVelocity`, which is head, and calls the part's `OnDetach(ParentMesh, Velocity, AngularVelocity)`. It then sets detached.

**DeletePart(slot)** (0x1412a43a0): requires spawned and not detached or deleted. It destroys the part. The original subsection stays hidden.

**DetachOrDeletePart** (0x1412a44b0): detach if detachable, else delete. Viscera rupture uses it (§4.1).

**`BP_Part_Jaw`**, from bytecode:
- **BeginPlay:**
  - `bHangFromLeftSide = RandomBool()`.
  - If the KB expression `{DisableImpactsOnDeath}` holds at the actor, the jaw ignores collision channel 20.
- **OnSpawn:**
  - `HideSkeletonPart(Parent, 'Sec_Jaw')`.
  - SoftBody data `SoftBody_Jaw_Left` or `_Right` according to the side.
  - With a = +10 (left) or −10 (right): `AddLocalTransform(T = (0, 0, −|sin(a)·5|) cm ≈ (0, 0, −0.868), R = Roll a)`.
- **OnDetach:**
  - Hide `Sec_Jaw` and detach, keeping the world transform.
  - Physics asset `PA_JawFalling`: one box on `jaw_02`, 8.70 × 7.26 × 11.96 cm.
  - Collision QueryAndPhysics; simulate physics.
  - Add the angular velocity, then the linear velocity.
  - Destroy the SoftBody; mass override **30 kg**.
  - `ScheduleActorDespawn(self, 'Limb', 'Jaw cleanup')`.

**`BP_Part_Eye`:**
- **BeginPlay:** (re)create the soft simulations (`SoftBody_Eye`).
- **OnSpawn:** `SoftBody.SetEnableAll(true)`. The eye dangles from its socket on DI2's soft body.
- Eyes are never detachable, so DetachOrDeletePart deletes them.

`USpawnablePartAttachment` also has `MaxAngularVelocity` (default 270) and `bAttachToDismemberedLimbs` (default true). **UNVERIFIED:** no reader of MaxAngularVelocity was found on the decompiled paths.

### 5.3 What triggers parts

1. **Hit reacts.** `CT_HitReact_Organs_Head_Zombie` has 15 `SpawnablePartResponse` nodes; `game/data/hit_reacts.json` (hit-reacts session) exports them. This is how normal head hits pop eyes and dislocate jaws.
   - Native defaults (ctor 0x141df1220): **bSpawn false, bDetach false, bDelete false, NumSlotsToActivate 1**. The data only writes the non-defaults.
   - Apply (0x1412b4800) picks `NumSlotsToActivate` random slots from `Slots`, with the same rand() formula as the gibs, and runs delete or spawn+detach as below.
2. **CosmeticEffect_SpawnablePart** (§6.2), from counter CEs and the rupture CEs.
3. **Viscera rupture** of SkullLeftFront (eye L, threshold 3.0), SkullRightFront (eye R, 1.5) or Jaw (jaw; rupturable on the thug only).

The facts `EyeLoose` and `JawDislocated` feed back into those trees (`{Victim}.JawDislocated`, `{Victim}.EyeLoose`).

---

## 6. Cosmetic effects

`cosmetic_effects` lists every extracted CE that contains one of these three effect types (121 CEs), with:
- `path`;
- `effects`: the viscera, part or shot effects with resolved defaults;
- `other_effects`: the remaining sub-effect types and assets;
- `used_by_hit_effects`: tree nodes and causer-collection keys in game/data/hit_effects.json;
- `used_by_viscera`: proxy RuptureEffects;
- `used_by_assets`: other referencing assets;
- `viscera_resolved`: cull names → subsection indices per body.

`viscera_referenced_effects` lists the remaining rupture, activation and breakage CEs (36) with their sub-effect types.

### 6.1 `UCosmeticEffect_Viscera`

| | |
|---|---|
| class | 0x58 bytes, vtable 0x1453f1c58 |
| fields | `RawVisceraToCull` @0x38 and `RawVisceraToUnHide` @0x48 (TArray<FName>) |
| behaviour | one shot: CullSubsectionByName for each cull name, UnhideSubsectionByName for each unhide name, on the target's skeletal mesh (0x141256350 / 0x141259540) |
| data | 81 instances. Only `RawVisceraToCull` is ever set. |

### 6.2 `UCosmeticEffect_SpawnablePart`

| | |
|---|---|
| class | 0x50 bytes |
| fields | `SpawnablePartSlots` @0x38, `bSpawn` @0x48, `bDetach` @0x49, `bDelete` @0x4a |
| defaults | **bSpawn true, bDetach true, bDelete false** |
| behaviour | per slot: if bDelete → DeletePart; else bSpawn → SpawnPart, then bDetach → DetachPart (0x141255ad0) |
| data | 77 instances |

### 6.3 `UCosmeticEffect_VisceraShot`

Radius @0x38, default 10. See §4.4. It is unused by data.

### 6.4 Who uses them

In the hit-effect trees, viscera and part CEs appear **only through the counter damage-causer collections**:
- `DA_AnimSetCollection_Counter_{1H_Chopping, 1H_Slicing, 1H_Stabbing, 1H_Sweeping, 2H_Chopping, 2H_Stabbing, 2H_Sweeping, Fist}`;
- keys `Victim_Counter_Action`, `Victim_Counter_Kill` and `Victim_Counter_Push`;
- 56 CEs in all.

For example, `CE_Zombie_Counter_M_1H_Slicing_Action` culls `BrainLeftFront`, spawns and detaches the left eye, and detaches the jaw.

Other users:
- **Weapon perks:** `CE_WeaponPerk_HeadExplosionOnKill` (crossbow perk) and its Thug / Slobber / Mutator variants (per-archetype CosmeticEffects collections).
- **Rupture CEs** of other viscera assets.
- **Unknown referencers:** the paired-move CEs (`CE_Pair_*`, `CE_Zombie_Paired_Head_Punch*`), `CE_Zombie_HeadStomp` and the cutscene CEs have no referencing asset among the extracted JSON. Their users (paired level sequences or montage notifies) are **not traced**.

---

## 7. `viscera_parts.json` reference

All `ue` values are DI2 component space in cm. All `gl` values use the conversion the body glbs went through: position `(x, y, z) cm → (x, z, y)·0.01 m`, quaternion `(x, y, z, w) → (x, z, y, −w)`, scale `(x, z, y)`.

| key | content |
|---|---|
| `native` | class layouts, ctor defaults and recovered algorithms, with exe addresses (the authoritative statement of §4–§6) |
| `part_actors` | BP_Part_Jaw / BP_Part_Eye / gib actor behaviour (§5.2) |
| `bodies.<b>.mesh`, `.glb` | skeletal mesh name; body glb |
| `bodies.<b>.sections[]` | `index`, `material` (the body's material for the section), `disabled_in_cook`, `di2_tail`, `shared_mesh`, `items_match_shared_mesh`, `glb` and `primitive` (where its triangles are), `glb_triangles`, `cooked_triangles`, `subsections[]` |
| `subsections[]` | `index` (global subsection index, the bit/order DI2 uses), `name`, `soft_body`, `glb_tris [first, count]` (triangle range inside `primitive` of `glb`), `cooked_tris` and `cooked_verts` (ranges inside the cooked section), `item_flag` |
| `bodies.<b>.masks` | per DIEngineMaterialMasks entry: `raw` (u64 as string), `sections` |
| `bodies.<b>.soft_body_mask_map` | name → `raw`, `bits` (subsection index & 63), exact `subsections` |
| `bodies.<b>.viscera` / `viscera_resolved` | VisceraAsset name; per proxy key: `subsections` / `broken_subsections` → `{indices, unresolved}`; per variant and per gib likewise |
| `bodies.<b>.spawnable_parts[]` | §5.1 |
| `viscera_assets.<name>` | §3: `groups`, `proxies`, `switchable_variants`, `switchable_groups`, `gibs`, `breakage_effects`, `blacklists`, `soft_body_modifiers`, `soft_body_gpu_influences`. Each element's `key` is its object path inside the asset; `children` and `gib` refer to those keys. |
| `cosmetic_effects`, `viscera_referenced_effects` | §6 |
| `physics_assets.<PA>` | `bodies[]`: `bone`, `collision_trace`, `phys_material` and its props, `shapes[]` (box: `size_ue` full lengths, `half_extents_gl`; `center_*`, `rotator_ue`, `q_gl`; shapes are in the body bone's local space) |
| `soft_bodies` | SoftBody_Eye / Jaw_Left / Jaw_Right: profiles, simulation names, particle and constraint counts, SimulationParams (reference only) |
| `sockets` | the `*_spawn` sockets of SKEL_ZombieStandard |
| `skeleton_bones` | SKEL_ZombieStandard reference-skeleton names (`*_bone_id` index this) |

---

## 8. Porting notes (Godot / GoreBody)

These are notes for the main session; this extraction changes no game code.

### 8.1 Subsection visibility (the primitive everything needs)
- Keep a `hidden` bitset over the body's subsection indices (≤ 137).
- To hide a subsection, drop its triangle range `glb_tris` from its primitive's index buffer, or equivalently split those primitives into per-subsection surfaces at load and toggle them.
  - Only sections with more than one subsection need it: the head viscera, torso viscera and skeleton sections, plus the parts glbs.
  - A shader discard keyed on a per-vertex subsection id would also work. Triangle ranges are exact and DI2-equivalent.
- `cull(name)` hides every subsection with that name, case-insensitively, and reports whether anything changed. Part spawning needs that result.
- At spawn, hide every section in `InitiallyHiddenMask`. For the thug this is all 52 skeleton subsections.

### 8.2 Shared sections
- For each section with `shared_mesh`, load `glb` (`parts/SK_Skeleton.glb` etc.) as an extra skinned mesh on the body's Skeleton3D, bound by bone name.
- It then behaves like any body section: subsections, masks and culling.
- Without it, the runner and shambler have no torso organs at all, and no body has limb bones.

### 8.3 Spawnable parts
Keep a per-slot state of spawned, detached and deleted.

**Spawn:**
1. `cull(original_part_to_hide)`; abort if nothing changed.
2. Instance `spec[0].glb`.
3. Attach it with a BoneAttachment3D at `socket.bone` with the `socket.gl` local transform.
4. Apply the BP's attach-time behaviour (jaw: random side, roll ±10°, z −0.868 cm).
5. Stamp `preset_splatter` through flesh.gd's splatter-set path.
6. Set `spawned_fact` in the zombie's facts.

**Detach** (jaw only): reparent to the world and make a RigidBody3D.
- Shape: the `physics_assets.PA_JawFalling` box (bone `jaw_02`). Mass 30 kg.
- Linear and angular velocity: the body's head bone velocity at that moment (deg/s → rad/s).
- Despawn under the `Limb` rules.

**Delete:** free the part. The original subsection stays hidden.

**Eyes:** DI2 dangles them on its proprietary soft body (`soft_bodies.SoftBody_Eye`, 3 particles, 3 constraints, gravity 0.5). That plugin is not decoded, so any dangle in Godot is a **stand-in** to list in recon/UNVERIFIED.md.

**Triggers:** hit-react `SpawnablePartResponse` (hit_reacts.json, with the native defaults in §5.3), counter CEs, rupture.

### 8.4 CEs
When flesh.gd plays a CE from hit_effects.json (causer sets) or a rupture or activation CE, look it up in `cosmetic_effects`:
- for `CosmeticEffect_Viscera`, cull each name;
- for `CosmeticEffect_SpawnablePart`, per slot apply the delete / spawn / detach rule with the CE defaults (spawn and detach true).

### 8.5 Rupture
On every splatter stamp GoreBody applies (stamp frame and FSplatterMeshInfo in ref-pose space, which GoreBody already uses), run §4.1 against the body's VisceraAsset proxies.
- Keep per-proxy damage, cap, variant index, ruptured and gibbed state.
- On rupture: play `rupture_effects`, then `DetachOrDeletePart` for `spawnable_part_slots`.
- On variant thresholds: `HideProxy` and unhide the variant's subsections (§4.2).
- The splatter presets in game/data/splatter.json already carry the Rupture* fields per CE.

### 8.6 Gibs
For a gib:
- hide `hide_subsections` on the body;
- build a rigid mesh from the `spawn_subsections` triangle ranges, posed at the moment of spawn;
- simulate it on its PhysicsAsset box (body bone and local box in `physics_assets`; PM_Flesh_Dismembered: friction 5, restitution 0);
- despawn after 3.5 s or under the Debris rules.

The selection rule is §4.3. What calls it is unknown.

### 8.7 Breakage
The limb proxies' `breakage_effects` (CE_BoneBreakout at `location`, splatter group, `SplatterSet_BoneBreakout_*`) belong with the bone-break path (dismember-re). The `SplatterSet_BoneBreakout_*` sets are not in splatter.json yet.

---

## 9. Unknown / UNVERIFIED

1. What calls `SpawnRandomGibs` / `SpawnRandomGibAttachments`, and with what `MaximumGibsToSpawn`.
2. The middle of `UVisceraComponent::Splatter` (0x141256940, about 800 decompiled lines between proxy selection and ApplyProxyDamage). It is probably the `VisceraStateBlacklistRuleset` checks (`invalid_states` are int states) and was not decoded, so blacklists are carried as data only.
3. `USpawnablePartAttachment.MaxAngularVelocity` (270): stored but no reader found.
4. `HideSkeletonPart`, the BP function the jaw calls: assumed to be the same subsection cull, not decompiled.
5. Users of the paired, stomp and cutscene CEs (no referencing asset in the extracted JSON).
6. DI2 SoftBody plugin (eye and jaw dangle, viscera soft-body modifiers, GPU influence): data only.
7. `SplatterGroupMask` and `SortBiasMask` bits beyond the section count.
8. LimbCut / BisectionCut / dismember and bone-break subsection handling: the dismember-re session's scope.
9. `ProxyPointTest` uses only the local X axis as compiled (§4.4). That is faithful to the binary, but it only matters for VisceraShot, which no data uses.
