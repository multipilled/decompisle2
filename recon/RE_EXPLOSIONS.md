# DI2 explosions (static RE of the shipping exe; personal-use notes)

This covers how DI2's explosion action finds victims, how it scales damage, stability and impulse, and how
MultiPartHealth spreads radial damage over body parts. Addresses are in DeadIsland-Win64-Shipping.exe. The exe
was decompiled headless (`tools/re_explosion/decomp.sh`, outputs in `extracted/ghidra/explosion_*.c`).

**Port:**
- `tools/build_explosions.py` writes `game/data/explosions.json`;
- `game/scripts/di2_explosion.gd` runs the action;
- gore-core `Body::radial_part_events` does the part distribution (§5);
- `GoreBody.set_radial_part_budget` hands the budget to the next hit.

**Users:**
- the pipe bomb (`player_moves.gd` Curveball `_explode`);
- the legendary revolver's ImpactCannon rounds (`player_ranged.gd PROJECTILE_EXPLOSIONS`).

## 1. Classes and data

| Class | StaticClass | Ctor / vtable | Size |
|---|---|---|---|
| UExplosionActionArchetype | 0x141c01a90 | ctor 0x141c029d0 (defaults below), InternalConstructor 0x141c02730 | 0x2d0 |
| UExplosionActionParams | 0x141c01e80 | | 0xa0 |
| UExplosionAction | 0x141c02000 | InternalConstructor 0x141c02710, vtable 0x14519e778 | 0x1f0 |
| UExplosionBalancing_PlayerBasedRules | 0x141c05e30 | ctor 0x141c06460 (TimeRangeScale 1, ValueScale 1), vtable 0x14548f820 | 0x38 |
| UMultiPartHealthComponent | 0x141d4e610 | ctor 0x141d50360 | 0x590 |

There is no RTTI in this build. Class names are wide strings `TEXT("UName") + 1` passed to
GetPrivateStaticClassBody.

**Archetype native defaults** (ctor 0x141c029d0):

| Field | Offset | Default |
|---|---|---|
| OuterRadius | 0x3c | 100 |
| StaticOcclusion | 0xb8 | 1.0 |
| DynamicOcclusion | 0xbc | 0.9 |
| DynamicOcclusionTurbulence | 0xc0 | 0.5 |
| BlastSpeed | 0xe8 | 5000 |
| BlastImpulse | 0xec | 20000 |
| BodyPartDamageEffectivenessMultiplier | 0x1c8 | 1.0 |
| StabilityDamageForce | 0x1f0 | 150 |
| ImpactCategory | 0x200 | 6 |
| CollisionChannel | 0x2c8 | 3 |

ImpactData sits at 0x1cc. The ctor writes 0x10000 there, so bSpawnLimbsOnDismember (0x1ce) = 1 and the rest are 0.
BisectionChance (0x1d4) = 1.0.

**Archetype field offsets** (from reflection):

| Field | Offset |
|---|---|
| DistanceScaleCurve | 0x50 |
| DistanceScaleCurveClassOverrides | 0x58 |
| DistanceBalancingData | 0xa8 |
| AngleScaleCurve | 0xb0 |
| StaticOcclusionStabilityScaleCurve | 0xc8 |
| StaticOcclusionDamageScaleCurve | 0xd0 |
| StaticOcclusionImpactScaleCurve | 0xd8 |
| DynamicOcclusionImpactScaleCurve | 0xe0 |
| BodyPartDamageEffectivenessMultiplier | 0x1c8 |
| DamageDefinitions (stride 0xf0) | 0x1e0 |
| StabilityDistanceScaleCurve | 0x208 |
| StabilityDistanceBalancingData | 0x210 |
| StabilityDistanceScaleCurveClassOverrides | 0x218 |
| ImpactKB (stride 0x50) | 0x288 |

**DamageDefinition offsets:**

| Field | Offset |
|---|---|
| Damage | 0x0 |
| DamageTypeClass | 0x8 |
| bOnlyApplyToCharacters | 0x79 |
| DistanceScaleCurve | 0x90 |
| DistanceBalancingData | 0x98 |
| DistanceScaleCurveClassOverrides | 0xa0 |

**Params:**

| Field | Offset | Source |
|---|---|---|
| ModifiedExplosionOuterRadius | 0x94 | OuterRadius × the radius attribute, if any |
| ForceMultiplier | 0x98 | archetype +0x268/+0x270 attribute |
| DamageMultiplier | 0x9c | DamageAttributeType: the thrower's DA_Attribute_Throwable_ExplosionDamage |

These are set in 0x14140c220 through 0x141403750 (attribute value, or 1).

## 2. Blast front and victims (tick 0x1414020f0, record 0x1413f20e0, per-frame 0x141414810)

**Blast front.** Each tick the front's radius is r = min(BlastSpeed · t, R), or R when BlastSpeed ≤ 0. A sphere
overlap of radius r at the origin collects components. Characters are kept once each (a set at +0x138).

**Pending hits.** Each victim gets a pending record with a priority:
- priority = (R'² − d²)/R'² + 1000·flag + 10000·flag;
- d is measured to the root component's Bounds.Origin (+0x168);
- R' = r + Bounds.SphereRadius (+0x180).

The records are sorted. Up to N per frame are run (UWorld settings +0x260/+0x268 .0x68: ExplosionRequests…
counts).

**The action ends** once the front reaches R (BlastSpeed ≤ 0 also counts as reached).

**Per-victim point** (0x141414810): for an ACharacter, its Mesh (+0x2C8) Bounds.Origin (+0x168). The exception is
when `FindComponentByClass(UPhysicalizedReactionComponent)` (vtable +0x610, class 0x141d85610) exists and its
state +0x924 == 4; then the point is that component's transform (0x141271d10 → +0x9C0, translation).
- **Port:** di2_explosion.gd `victim_point` = the centre of UPhysicsAsset::CalcAABB over PA_ZombieStandard's 20
  BoundsBodies (shapes in their posed bone frames, the root sphere included).
- The blast front's overlap catches the capsule (`_capsule_distance`).
- The ragdoll-state transform is UNVERIFIED #51. Traced 2026-10-09 (gore session, extracted/ghidra_gore/ragstate.c):
  - +0x924 is the state chosen by 0x141285320 from flags: 4 when +0x91D && !+0x91E; else 2 when +0x918; else 3 when
    (+0x91B && !+0x91C) or the timers +0x934 / +0x938 > 0; else 1 when +0x919; else 0.
  - Entering 4 saves a 16-byte value from the mesh (+0x618) keyed by FName "Ragdoll" (0x144000810) into +0xAE4, then
    creates a physics object at +0x9C0 (0x143fe1260(+0x9E8, +0x9C8, ..., +0x9C0)); leaving 4 restores the saved value
    (0x14401c870) and releases +0x9C0 (0x14127f670).
  - 0x141271d10 (the victim-point getter) returns 0x141270e60(+0x9C0) when the state is 4 (or when +0x630's +0xDC9 is
    set): a pose from 0x1412721a0(+0x9C0) composed with the relative transform stored at +0x9C0 +0xB0..+0xD0.
  - Open: what +0x91D / +0x91E mean (which reaction is state 4) and which body the +0x9C0 object follows. Until
    then the port keeps the bounds centre for every state (which is DI2's point for states 0-3).

## 3. Per victim (0x1413f0bf0 → occlusion 0x1413f44c0 → impact 0x1413f22e0 → damage 0x141413040)

**Distance and angle.** 0x1413f4050 gives the distance d to the victim point and an angle term.
- With an AngleScaleCurve, angle = curve(acos(cos) in degrees). The victim is skipped when this is below 1e-8.
- With no curve, angle = 1. No throwable sets one.

**Occlusion.**
- A multi-trace (CollisionChannel) runs from the origin to the victim.
- Each blocker that isn't the victim adds to an occlusion sum, chosen by its mobility:
  - static: occ_s = (1 − occ_s) · StaticOcclusion + occ_s;
  - otherwise: occ_d = (1 − occ_d) · DynamicOcclusion + occ_d.
- The victim is skipped if either sum is ≥ `Impacts.OccludedImpactSkipThreshold`. That is a float cvar,
  default 0.9 (init 0x1404d93e0).

**Normalised distance:** x = d / ModifiedExplosionOuterRadius.

**Distance scale** (curve pick 0x1414010f0, eval 0x1414319f0 or inline):
- **Curve pick:**
  - 0x1414010f0 walks the class-override map;
  - it keeps the most derived key class the victim IsChildOf;
  - it returns that key's curve, or the given default.
- **Evaluation:**
  - curve and no balancing: curve(x);
  - curve with balancing: curve(a·x)·b;
  - no curve: sat(1 − a·x)·b.
- **Balancing (PlayerBasedRules):** vf 0x238 gives (a, b):
  - for the player class (0x141bd58a0): (1/TimeRangeScale, ValueScale), e.g. DA_ExplosionBalancingData_Player
    = (1, 0.25);
  - for anything else, zombies included: (1, 1).

**Impact** (0x1413f22e0):
- Impulse:
  - impulse = DynOccImpactScale(occ_d) · StatOccImpactScale(occ_s) · angle · distScale_archetype(x) · BlastImpulse,
    capped at 30000;
  - each *Scale is its curve, or 1 − occ without one;
  - distScale_archetype uses the archetype's DistanceScaleCurve and its class overrides;
  - stored at impact +0x2a8 and +0x178.
- Stability force:
  - stability = StatOccStabilityScale(occ_s) · ForceMultiplier · angle · distScale_stab(x) · StabilityDamageForce;
  - distScale_stab uses StabilityDistanceScaleCurve and its overrides, else the damage curve;
  - its balancing is StabilityDistanceBalancingData, else DistanceBalancingData;
  - stored at impact +0x20c.
- Impact copies: the archetype's ImpactData (+0x218), the explosion origin (+0x290), the victim (+0x1b8) and the
  instigator (+0x1d0).
- Impact knowledge base (+0x38):
  - `RadialToBodyPartDamageMultiplier` (FName init 0x1404c0c80) = BodyPartDamageEffectivenessMultiplier when
    ImpactData +0x1cc, +0x1cd or +0x1d0 is set, else 0. Those are bCanCauseBreak, bCanCauseDismember and
    bCanCauseBisection, by declaration order;
  - the bomb-type facts (e.g. {Hit}.Nail_Bomb) come in via ImpactKB, merged by `FUN_140a47b90`.

**Damage per DamageDefinition** (0x141413040):
- A definition is skipped if bOnlyApplyToCharacters and the victim isn't a character.
- damage = StatOccDamageScale(occ_s) · DamageMultiplier · angle · distScale_def(x) · Damage.
- distScale_def picks the curve in this order:
  - the definition's class override, else the definition's DistanceScaleCurve;
  - else the archetype curve for the victim;
  - balancing: the definition's DistanceBalancingData, else the archetype's.

**Applying the impact.** The impact is applied by 0x1413e0020, then the victim tree runs (ImpactConfiguration
VictimEffectTree, e.g. CT_HitEffect_Explosion_Victim). The tree's `CT_ExplosionType` module branches on the
ImpactKB bomb facts.

## 4. Data (examples)

| Archetype | R (cm) | BlastSpeed | Damage | Facts |
|---|---|---|---|---|
| Pipe bomb | 400 | 3000 | 75 explosive, Force 100, DismembermentChanceOnKill 1 | Thrown, CanBreakButcherBlock |
| Nail bomb | 550 | 3000 | 40 bleed | Nail_Bomb |
| ImpactCannon | 300 | 3000 | 30 explosive | Breach |

- **Pipe bomb:** ImpactData all true.
- **Nail bomb:** bCanCauseDismember and bCanCut.
- **ImpactCannon:** StabilityDamageForce 10, BlastImpulse 5000.
- **Damage curves:** Walker, Runner and Shambler use Curve_Explosion_Falloff_Commons: 2.0 to x = 0.35, then cubic
  to 1.21 at 0.84, then 0 at 1. Other zombie classes fall back to the archetype curve,
  Curve_DistanceScaleCurve_Float: 1 to x = 0.5, then cubic to 0 at 1.
- **Class hierarchy:** every family's BP_Base_<Family>_C derives directly from BP_Base_Zombie_C.

## 5. MultiPartHealth radial body-part damage (0x1412c0940)

This function reads the `RadialToBodyPartDamageMultiplier` fact from the impact KB, with 0 if the fact is
missing. It does nothing unless `MultiPartHealth.RadialDamageBodyPartDistributionEnabled` is set. The cvar is
read with GetInt and defaults to 1.0.

**Budget** = damage × `MultiPartHealth.RadialDamageQuantityToBodyPartDamageConversionFactor` × the fact. The
conversion factor defaults to 1.0.

**Candidates** (parts at +0x4a0):
- RadialDamageScalar (part settings +0x14) > 0;
- if the part is bForceKillOwnerWhenDestroyed (+0x10), it needs `…OnCriticalPartsEnabled` (default 1), or the
  owner flag at +0x178 ≤ 0;
- rand() ≤ AffectedByRadialDamageChance (+0x18), where rand is (rand() & 0x7fff) · 3.051851e-05;
- the part is not dead (health != 0, or the destroyed flag at +0x7c is clear).

**RadialDamageDistributionMethod** (+0x281, ERadialDamageBodyPartDistributionMethod):

| Value | Name | Effect |
|---|---|---|
| 0 | None | No part damage |
| 1 | ApplyTotalToEachPart | Each part takes scalar · budget |
| 2 | DistributeDividedAcrossParts | scalar · budget / count |
| 3 | DistributeToRandomParts | Shuffle; each part takes min(scalar · left, part health); left −= that / scalar |
| 4 | DistributeLowestHealthFirst | As 3, then introsort by part health ascending (0x1412b9dc0) before spending |

- Mode 4 is the native default: the ctor writes 0x0403 at +0x280, so GlobalDamagePropagation = 3.
- No zombie asset overrides it (no BPC_MultiPartHealth_* sets the property).
- The shuffle swaps slot k with k + int(rand01 · remaining).
- The loop stops when the budget is ≤ 0.
- It also stops at `…MaxPartsAffectedCount` events (int, default −1, i.e. no limit).
- `…OnlyWhenDead` (default 0) sets only a flag on the events.

**Each event:**
- the part;
- a random bone from the part's bone list, with the bone's location and directions from the origin;
- the part damage.

The events are queued at +0x500 and applied through the part-damage path. In the port, they are
`Outcome::Damaged` followed by the usual depletion handling: dismember, crush or break.

**Cvars** (init functions):

| Cvar | Init | Default |
|---|---|---|
| RadialDamageBodyPartDistributionEnabled | 0x1404c2b60 | 1.0 |
| …MaxPartsAffectedCount | 0x1404c2bd0 | −1 |
| …OnCriticalPartsEnabled | 0x1404c2c40 | 1.0 |
| …OnlyWhenDead | 0x1404c2cb0 | 0 |
| …ConversionFactor | 0x1404c2d10 | 1.0 |

No ini file in the pak overrides any of them. The files checked were DefaultEngine, DefaultGame,
DefaultDeviceProfiles, DefaultScalability and Windows*.

## 6. Who calls it

- **Throwables:**
  - DA_ThrowingWeaponArchetype_* point to their DA_ExplosionArchetype_*;
  - the request path is RequestExplosion 0x141c08690: UExplosionActionParams, then the action manager
    (0x143feb440).
- **Ranged:**
  - BP_Projectile_ImpactCannon's `ProjectileResponseCreateExplosion` uses DA_ExplosionArchetype_ImpactCannon;
  - it is invoked from an InvokeParentProjectileLocationResponse, i.e. at the impact location;
  - the same round also has an ApplyAttributeDrivenPointImpactCollisionResponse: projectile damage under the
    weapon's ImpactConfiguration, which has no victim tree.
- **Player:** ServerTriggerExplosion and ServerApplyExplosionDamageToSelf are player RPCs, in the player
  character's native table at 0x14544ec30.

## 7. Gibs (VISCERA_PARTS.md §4.3)

`UVisceraComponent::SpawnRandomGibs` and `SpawnRandomGibAttachments` are each called only from their exec thunks.
A name-table scan of all 8,475 BP / AN / ABP / GA / GC / GE / CE packages finds only two callers:
- `BP_AnimNotify_SpawnGibs_Reformer`;
- `BP_EnvHazard_FallenTurbine`.

Both are Expansion 2. Explosions don't spawn viscera gibs.
