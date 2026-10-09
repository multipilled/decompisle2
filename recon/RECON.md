# Dead Island 2 static recon

Personal testing project. These notes come from reading the files on disk only. The game was never launched or patched.

## Install
- `C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2`, Steam build 25629748, 71.6 GB
- Customized UE4 (`DI_MS_Game` source tree). IoStore TOC version 3 (UE 4.27-era layout)
- `DeadIsland-Win64-Shipping.exe`, 119.7 MB, no PDB
- No anti-cheat. Epic Online Services is present for co-op, so keep the game offline when testing
- An ASI loader is already installed: `version.dll` + `FSR2DLSS_Loader.asi`

## Paks
- 46 `.utoc` containers. 38 of them are AES-encrypted, all with the zero key GUID (one primary key)
- To unpack them we need the AES key, plus FModel/CUE4Parse. Unversioned properties may also need a `.usmap`
- Details per container: `utoc_headers.csv`

## Gore system ("FLESH"): reflection names in the exe
Full list: `exe_strings.txt`

| Area | Identifiers |
|---|---|
| Per-limb health | `MultiPartHealth.*`, `LimbDamage`, `bAllowLimbDamageBonusesOnPartsWhichKillOwner` |
| Major wounds | `UMajorWoundData`, `FMajorWoundParams(Array/Item)`, `UConditionalMajorWoundList`, `ConditionalMajorWoundCandidate`; telemetry `major_wound_dismemberment`, `major_wound_bisection` |
| Dismemberment | `EDismembermentType`, `BinaryDismemberMask`, `BinaryDismemberParameter`, `c_BinaryDismember`, `FDismemberBaseCS` (compute shader), `ADismemberedLimbActor`, `BonesToRemoveFromLimbs`, `bSpawnCutLimb`, `OnLimbCut` |
| Viscera / gibs | `VisceraComponent`, `UVisceraGibbableSubSection`, `EVisceraEventType`, `UGibAttachmentModule`, `CharacterGibs`, `AGoreActor` |
| Surface wounds | `WoundScale`, `AlternateWoundTextures`, `FWriteToSliceVS/GS` |
| Tuning cvars | `Dismember.ForceScalar`, `Dismember.HeavyAttackForceScalar`, `Dismember.ForceVelFrameCount`, `Dismember.LimbPoolingEnabled`, `Dismember.DebugDrawMajorWounds` |
| Other | `UBodyPartImpalingComponent`, `LimbManagementComponent`, `GamePhysics.Ragdoll.State.EnableLimbSync` |
| Zombie AI | `Source/DeadIsland/AI/Crawler`, `UAICrawlerAction`, `UAICrawlerStateAction` (crawler locomotion when legs are lost) |

### Inferred pipeline (to confirm against the data assets)
1. Each hit goes into per-body-part health (MultiPartHealth).
2. When a part crosses its threshold and the weapon allows it, a major wound (dismember or bisect) is picked from a conditional list (MajorWoundData).
3. The cut is applied: a binary mask hides the severed region on the skinned mesh via a compute shader. A `DismemberedLimbActor` with its own cap mesh spawns, and gets launched with force from the `Dismember.*` scalars.
4. Viscera and gib sub-sections spawn. Smaller wounds use wound textures scaled by `WoundScale`.
5. If the legs are lost, the zombie switches to crawler AI.

## Data findings from the unpacked paks (2026-10-07)
- AES key found statically in the exe (`find_aes_key.py`) and stored in `aes_key.txt`. Properties are tagged, so no `.usmap` is needed.
- Extractor: `tools/di2x` (CUE4Parse with `EGame.GAME_DeadIsland2`). Output goes to `extracted/`, which is local only.
- **"Splatter" is the internal name for FLESH.** It has an engine plugin (`Engine/Plugins/Splatter`), `SplatterSet` data assets (CutBones, SplatterEntries, SplatterGroups) and `DA_SplatterParameters_*`.
- **Layered anatomy.** One merged skeletal mesh per variant (e.g. `SK_WalkerMaleCas01`, 17 sections) covers outer skin and clothing, an inner muscle layer (`*IntA`), the skull, and organs (`MI_WalkerViscera*`). 219 bones, UE mannequin-style names.
- **Viscera tree.** `VisceraProxy` (RuptureBoneId, BreakageBoneId, CutBias, bCanRupture), `VisceraGroup` (BoneName, CutMargin, bIsShootable, SwitchOnDismemberment), `VisceraSwitchableVariant` (SwitchThreshold), `VisceraGibbableSubSection`, `VisceraBreakageEffect`.
- **Body parts** (`DT_ZombiePartBoneDefinition`): Head = head, neck_02, neck_01. Arm = upperarm, lowerarm, hand. Leg = thigh, calf, foot, ball. Torso_Bisectable = spine_04, spine_03, spine_02.
- **MultiPartHealth per archetype** (`BPC_MultiPartHealth_*`): MaxHealth, plus a MaxHealthFraction per part and dismember/break chances. The survival rule is an expression; for Walker it's `floatbranch(!#HasBothLegs, #HasBothArms, true)`. Base: MaxHealth 120, head 0.8, limbs 0.3333.
- **Splatter shading** (material function names): wound height masks are colored through a 2D gore gradient (`T_GoreGradWalker/Runner/Shambler`) and get normals built from the height (`MF_CreateNormalsFromHeightMap`). Also: bruising, blood drips, cauterization (fire), freeze, fabric tears, and fake lighting under the splatter.
- **Damage types** (`/Game/DI2/Core/DamageTypes`): Acid, Bleed, Blunt, Collision, Electric, Explosive, Fallen, Fire, Normal, Projectile, Sharp.
- CUE4Parse glTF export only works with morph targets off. UV1–7 come out as zeros (DI2's custom vertex streams aren't decoded).

## Archetype bodies and animation sets (2026-10-07)
- **One skeleton.** Walker, Runner, Shambler and Thug meshes all use `SKEL_ZombieStandard` (421 bones; the meshes carry 219–227 of them). Runner and Shambler share the Walker's proportions. The Thug is about 1.24× bigger (pelvis 1.27 m vs 1.03 m).
- **Retargeting.** `SKEL_ZombieStandard`'s BoneTree sets a translation mode per bone: root = Animation, spine/limbs/pelvis = AnimationScaled, fingers/twists = Skeleton, many helper bones = AnimationRelative. Thug clips set `RetargetSource = SK_ThugA` (a pose stored in the skeleton's `AnimRetargetSources`). The Base hit/KO and crawler clips use the skeleton's ref pose, so on the Thug they have to be retargeted (`tools/merge_anims.py` does this).
- **Anim sets** (`AnimSetData/Zombie/Collections`): Runner and Thug have their own `*_Locomotion` sets. The Shambler has none: it uses Walker locomotion plus `Personality/Shambler_*` walk clips (LeftLeg, SpineBent*, SpineTwist, Vertigo). Runner crawlers use Walker crawler walk clips with Runner idles and attacks. Hit reactions are the shared `A_ZMB_Base_*` clips.
- **Attack timing.** Each attack `AM_*` montage has an `AIDetectMeleeHits*` notify state, which is the damage window. DI2 plays a wind-up first (a `_FixedWindUp` montage, or the first part of the same clip; the Runner swipes skip 0.5 s of their clip).
- **Gore gradients.** The Thug's material uses `T_GoreGradWalker` (its `Wound Gradient Map` parameter).
- **Hair** (`MSM_Hair`) has no colour map. It has Root/Tip colours and a `Packed Hair Data Map`, where alpha holds the strand coverage. Some of these maps need Detex to decode (now initialized in di2x).
