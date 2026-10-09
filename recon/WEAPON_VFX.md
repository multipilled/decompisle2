# DI2 weapon and world-impact VFX (static RE of the shipping exe + cooked data; personal-use notes)

> **Hand-off (2026-10-08, weapon-vfx session; reports go to gore-lead a worker).**
> Done and tested (`game/test_out/weapon_vfx/`, 110 captures, no script errors): environment hit trees + material grid
> (pistol / shotgun on concrete / wood / metal, bat, machete pick DI2's CE_Collision_*), DI2 decals (default Godot
> `Decal`, world layer only, off characters; `WeaponVfx.decal_renderer = "pom"` = exact PS 861 parallax box), gun
> cosmetics wired (muzzle CE at the Muzzle socket, casings, montage-notify shells, tracer with Velocity / Lifetime,
> cosmetic impact delay). **Waiting:** particles.json must contain the `game/data/vfx_roots.json` CEs / PSs (particles
> session's next `build_particles.py --fetch`); then rerun the test (command in "Port" below) and check the muzzle /
> tracer / shell / impact-particle captures. Open items: recon/UNVERIFIED.md #55 (arena PM_Concrete stand-in, per-pellet
> decals, decal approximations, unported audio / camera shake / PhysicalizedWorld).

What a DI2 gun shows when it fires (muzzle flash, casings, tracer) and what a bullet or melee weapon leaves on a world
surface (environment hit-effect tree, material grid, impact particles and decals). Addresses are in
DeadIsland-Win64-Shipping.exe (never run). Decompiles come from this session's own headless Ghidra project
(`tools/weapon_vfx/decomp.sh`, outputs `extracted/ghidra_vfx/{grid1,shot1..4}.c`); short functions were read with
capstone (`tools/re/di2exe.py`).

**Port:**
- `tools/weapon_vfx/build_weapon_vfx.py` writes `game/data/weapon_vfx.json` and the particle roots
  `game/data/vfx_roots.json` (read by the particles session's `tools/build_particles.py`), and copies the decal
  textures to `game/assets/di2/weapon_vfx/decals/` (`.gdignore`d, loaded raw);
- `game/scripts/weapon_vfx.gd` (`WeaponVfx`) plays everything; particle systems run on `DI2Particles`, decals on
  `game/shaders/weapon_vfx_decal_pom.gdshader`;
- hooks (one call each): `player_ranged.gd` `_shoot_once` -> `WeaponVfx.on_shot`, `_hitscan` ->
  `WeaponVfx.on_projectile`; `player_melee.gd` `_sweep` (rebound) -> `WeaponVfx.melee_world_hit`.
  `Fx.muzzle_flash / tracer / sparks` are no longer called;
- test: `game/scenes/weapon_vfx_test.tscn` + `game/scripts/autotest_weapon_vfx.gd` (own scene, no main.gd hook):
  `RUN_TEST_ENGINE_ARGS="--fixed-fps 60 res://scenes/weapon_vfx_test.tscn" tools/with_cpu.sh me tools/with_lock.sh me
  tools/run_test.sh --weaponvfxtest=game/test_out/weapon_vfx` -> `game/test_out/weapon_vfx/*.png`,
  `weapon_vfx.log`.

## 1. Classes

| Class | StaticClass | InternalCtor / ctor | vtable | Size |
|---|---|---|---|---|
| UBaseProjectileSpawnModule (shot cosmetics) | — | ctor 0x1415e4f30 | 0x14521c760 | — |
| UHitscanProjectileSpawnModule | 0x141c697e0 | ctor 0x1415b5950 | 0x145219cd8 | 0x5e0 |
| UConditionalTreeNode_MaterialGridCosmeticEffect | 0x141b862a0 | 0x141b887f0 | 0x1453cb748 | 0x68 |
| UGameCollisionEffectsRegistry (data asset) | — | — | — | — |
| UGameCollisionHandler | 0x141c1b410 | 0x1414253a0 | 0x1451a3ac0 | 0x138 |
| UCosmeticEffect / _Decal / _ParticleSystem | 0x140cd2840 / 0x140cd1270 / 0x1440c11c0 | 0x140cd3440 / 0x140cd3cf0 / 0x1440c2060 | 0x144d30410 / 0x144d327e8 / 0x1460fafa8 | 0x38 / 0x90 / 0x70 |
| UHitEffectsComponent | 0x141c6a9d0 | 0x14358e630 | 0x144fc5650 | 0x100 |

## 2. Spawn module properties (reflection offsets) and native defaults

UBaseProjectileSpawnModule (ctor 0x1415e4f30):

| Field | Offset | Default |
|---|---|---|
| RayTraceChannel | 0xe0 | 20 |
| RayTraceDistance | 0xe4 | 10000 cm |
| bUseSweptSphereOverRay / SweptSphereRadius | 0xe8 / 0xec | false / 5 |
| MuzzleOriginBoneOrSocketName | 0xf0 | `Muzzle` |
| LocalUserMuzzleAlignmentToleranceDegrees | 0xfc | 7.5 |
| MuzzleFlashEffectType / EjectedAmmoCasingsEffectType | 0x100 / 0x108 | null |
| AmmoEjectBoneOrSocketName | 0x110 | `AmmoEject` |
| LocalPlayerShootCosmeticEffect | 0x198 (key 0x1a8) | ObjectSet key `LocalPlayerFeedback` |
| WeaponShootMuzzleCosmeticEffect | 0x1b0 (key 0x1c0) | ObjectSet key `MuzzleFlare` |
| WeaponAmmoEjectCosmeticEffect | 0x1c8 (key 0x1d8) | ObjectSet key `AmmoEject` |
| WeaponShootLifetimeCosmeticEffect | 0x1e0 (key 0x1f0) | ObjectSet key `ShootLifetime` |
| MuzzleFXParticleSystemComponent | 0x214 (weak) | — |

The cosmetic structs are {bool bUseDefinition +0, Definition +8, FName ObjectSetKey +0x10}: `0x1415fdc80` returns the
Definition when the bool is set, else looks the key up in the weapon's ObjectSetComponent (DA_EffectSetCollection_*:
first group whose expression holds, weighted random item). No DI2 gun sets a direct Definition.

UHitscanProjectileSpawnModule (ctor 0x1415b5950):

| Field | Offset | Default |
|---|---|---|
| ProjectileTracerEffectType | 0x408 | null |
| ProjectileTracerCosmeticEffect | 0x410 (key 0x420) | ObjectSet key `Tracer` |
| bCosmeticImpactTimeDelayEnabled / bBulletPenetrationEnabled | 0x550 / 0x551 | true / true |
| FakeProjectileSpeedForCosmeticImpactDelay | 0x560 | 15000 cm/s |
| MaxTracerLifetime | 0x564 | 2 s |
| MaxFakeProjectileCosmeticImpactDelay | 0x568 | 0.25 s |

Cooked overrides (BP_Weapon_*'s HitscanProjectileSpawnModule, `weapon_vfx.json weapons.<id>.spawner`): pistol
EjectedAmmoCasingsEffectType PS_Shells_9mm, FakeProjectileSpeed 30000; shotgun MuzzleFlashEffectType
PS_Shotgun_Muzzleflash, ProjectileTracerEffectType PS_Ranged_Tracer_Single, FakeProjectileSpeed 30000; short / tactical
shotguns MuzzleOrigin `MuzzleShort` / `MuzzleTactical`; machine pistol AmmoEject `AmmoEjectSMG`, speed 40000.

## 3. Gun cosmetics

### 3.1 Per shot (`0x141606560`)
1. **Muzzle flash** (`0x1416059b0`): CE `MuzzleFlare` from the ObjectSet. If there is one: the muzzle socket's world
   transform (vfunc +0x2c0 with MuzzleOriginBoneOrSocketName) and the CE spawned attached to the gun mesh at that
   socket (`0x140ccc5e0`). Without one: MuzzleFlashEffectType via `SpawnEmitterAttached(PS, gun mesh, socket, 0, 0,
   (1,1,1), KeepRelativeOffset, bAutoDestroy)` (`0x143745800`), kept in MuzzleFXParticleSystemComponent; a later
   shot re-activates that component (vfunc +0x240) while it is alive. Pistol and shotgun both resolve a CE
   (`DA_EffectSet_Pistol_MuzzleFlare` / `_Shotguns_MuzzleFlare` NoMod group: CE_MuzzleFlare_Pistol ->
   PS_Pistol_Muzzleflash, CE_MuzzleFlare_Shotgun -> PS_Shotgun_Muzzleflash), so the shotgun's MuzzleFlashEffectType
   is never used.
2. **Casings**: CE `AmmoEject` (every collection's AmmoEject AnimSet has no Data: none), else
   EjectedAmmoCasingsEffectType via `SpawnEmitterAtLocation(world, PS, AmmoEject socket world transform, auto-destroy)`
   (`0x143745350`) — world space, not attached. Pistol: PS_Shells_9mm at `AmmoEject`.
3. `0x141606790`, then `0x141605800`: LocalPlayerShootCosmeticEffect (camera / rumble CEs), ShootCameraShake,
   ShootForceFeedback — not ported here (no camera-shake / rumble CEs in this project).
4. `0x141606030`: ShootLifetime CE attached at the muzzle (no DI2 gun collection has the key).

### 3.2 Per projectile (`0x1415dca10`, hitscan vtable slot 0x2e8)
For each trace result: `0x1415d5e30` (hit processing), `0x1415d7260` (impact), then the tracer `0x1415dea40(start,
end)`: start = the muzzle socket's world location (vfunc +0x2c0, MuzzleOriginBoneOrSocketName) for the first segment,
the trace start for a continued (penetrating) one; end = the hit location, or trace start + direction *
RayTraceDistance for a miss.
- Tracer (`0x1415dea40`): rotation = travel direction (`FVector::ToOrientationRotator`), scale 1. CE `Tracer` from the
  ObjectSet (pistol and shotgun NoMod groups: CE_Tracer_Handguns_NoMod -> PS_Ranged_Tracer_Single), else
  `SpawnEmitterAtLocation(ProjectileTracerEffectType)`. With bCosmeticImpactTimeDelayEnabled and speed > 0 the system
  gets the instance parameters **Velocity** = FakeProjectileSpeedForCosmeticImpactDelay and **Lifetime** =
  min(|end - start| / speed, MaxTracerLifetime) (`SetFloatParameter` / CE parameter `0x140cca750`).
  PS_Ranged_Tracer_Single maps them through DistributionFloatParticleParameter (Velocity in [0, 10000],
  Lifetime in [0, 10]), so a 30000 cm/s gun's tracer moves at 100 m/s for distance / 300 m/s seconds — DI2's data.
- Impact delay (`0x1415d7260`): delay = bCosmeticImpactTimeDelayEnabled ? |impact - trace start| / speed : 0, capped
  at MaxFakeProjectileCosmeticImpactDelay; delay > 0 stores a deferred impact request (DeferredImpactRequestsByID) and
  a world timer applies the impact later (`0x1415cb270` -> `0x1413dfd10`). The **whole impact** is deferred (damage
  and hit effects), not only the cosmetics; the port defers the world-impact effects only (§7).
- Every trace result builds its own impact request, so each shotgun pellet that hits the world runs the environment
  tree (8 x CE_Collision_Bullet_Shotgun_<surface>, each with an MI_DecalBulletSpray decal). The point-impact handler
  gates hit effects per impact (`0x1413d85f0`: impact +0x259, the impact's bShouldTriggerHitEffects); its writer for
  hitscan requests (`0x1415d7260`) was not fully traced, nor whether impact groups (bForceAllocateImpactGroupIDForEach-
  ShotEvent) thin the cosmetics: recon/UNVERIFIED.md.

### 3.3 Gun montage notifies
`BP_AnimNotify_SpawnParticleSystemOnWeapon` (`Received_Notify`, bytecode via tools/bpdump): only for the current
perspective's weapon child actor; `SpawnAttached` (CDO true) -> `SpawnEmitterAttached(ParticleSystemTemplate, the
montage mesh, InSocket, 0, 0, Scale (CDO 1), KeepRelativeOffset, auto-destroy)`. The pump guns' shoot montages carry
it: AM_ShotGun_Shoot_Weapon PS_Shells_Shotgun at `AmmoEject`, 0.5658 s (LinkValue 0.808 of the 0.7 s section);
`montage_notifies` in weapon_vfx.json lists all seven.

## 4. World impacts

### 4.1 Which tree (`0x1415485f0`)
The dispatch builds the impact context — a list of knowledge-base references with scopes, in order: `Hit` (the
impact's own KB), `Attacker` (instigator), `Victim` (only for a character, or an actor tagged `HasVictimContext`),
`DamageCauser` (`0x140a49850` / `0x1415323e0`). A victim that is not a character (class checks
`0x143c94db0` / `0x141be3de0`) takes the **environment tree**: the impact's override (+0x58, the weapon's
ImpactConfiguration.EnvironmentEffectTree) or the attacker's HitEffectsComponent +0xF8. The spawn loop
(`0x141556dd0`) spawns each gathered CE at HitInfo.ImpactPoint, attached to the hit component, rotation from
`0x1414810b0` with the effect's factor; effects the hit actor doesn't take over are stopped after **10 s**
(`0x140cbfde0(handle, 10.0)` -> world timer -> stop).

Trees: guns CT_HitEffect_Weapon_Ranged_Environment, melee CT_HitEffect_Weapon_Environment (`{Hit}.Harvester` ->
row `MeleeSharp`, else `Melee`; the machete's CustomImpactFacts set Harvester).

### 4.2 MaterialGridCosmeticEffect
Gather `0x1414942c0`: registry = OverrideEffectsRegistry (+0x60) or the game collision handler's
(`0x141431990`: world +0x60 IsA UGameCollisionHandler -> +0x40 -> +0x28 = BP_GameCollisionHandler's
GameCollisionRegistry.EffectsRegistry = CollisionEffectsRegistry_Game); output `{CE, DirectionInterpolationFactor 0}`.

Pick `0x1414893d0`, node fields (ctor 0x141b887f0 defaults): bPreferMaterialGridRowNameFromImpactKnowledgebase +0x48
(false), bFallbackIfKBFactFailed +0x49 (**true**), bFallbackIfKBFactEmpty +0x4a (**true**), MaterialGridRowFactName
+0x4c (`MaterialGridRow`), MaterialGridRow +0x58 (None), OverrideEffectsRegistry +0x60:
1. Columns from the impact KB ints `Hit.ClassObjectIndex`, `Hit.MaterialObjectIndex`, `Hit.SurfaceIndex` (written by
   `0x1413d8870` from the hit: the hit actor's class object, the physical material object, its SurfaceType byte +0x50;
   it also writes the surface name from PhysicsSettings.PhysicalSurfaces): class ->
   ClassToCollidersMap (nearest ancestor class, `0x141431af0`); physical material (exact class PhysicalMaterial) ->
   MaterialToCollidersMap (`0x141431a90`); surface = EPhysicalSurface (columns 0..63 are the surfaces in enum order).
2. If prefer: the string fact `MaterialGridRowFactName` looked up **unscoped** (`0x140a3a6d0` with scope 0 walks every
   KB of the context in order); found -> row = FName(string) -> lookup; non-null -> done.
3. Fallback: FactFailed -> lookup(MaterialGridRow); else a found non-empty string -> nothing; else FactEmpty ->
   lookup(MaterialGridRow).

Lookup `0x141432fb0`: ColliderTable[row * N + column] (N = Colliders.Num, table symmetric). A class column wins unless
it holds MakeCascadeDefinition (the registry's +0x30 sentinel); then material column, else surface column.

Data (`CollisionEffectsRegistry_Game`, 167 colliders): surfaces 0..63 (Default, Flesh, Metal, … Dirt = SurfaceType24,
names from DefaultEngine.ini PhysicalSurfaces), 10 special physical materials (_Movable, Glass_NoFX, …), 75 actor
classes (Actor = 74 holds MakeCascadeDefinition for the bullet / melee rows), 18 custom rows (Bullet, Bullet_Pistol,
…, Melee, MeleeSharp, …). The guns' EquippableData.FactsSetWhenHeld set `MaterialGridRow` = `Bullet_<type>` (pistol
Bullet_Pistol, shotgun Bullet_Shotgun) on the holder, so node 42's KB lookup finds it in the Attacker KB; the generic
`Bullet` row (the fallback) holds the sawblade effects. Example: Bullet_Pistol x Concrete =
CE_Collision_Bullet_Pistol_Concrete (PS_Bullet_Concrete, sound, decal MI_DecalBullet_Concrete, PhysicalizedWorld).
Node 43 (`MaterialGridRow_BulletAdditive` on CollisionEffectsRegistry_BulletAdditive, rows Bullet_FireMod / ShockMod /
AcidMod) has no MaterialGridRow, so without that fact it plays nothing.

Physical materials: `PM_*` SurfaceType (data); DefaultEngine.ini DefaultPhysMaterialName = PM_Default (surface Default)
for geometry without one.

### 4.3 Decal effect (UCosmeticEffect_Decal, vtable 0x144d327e8)
Fields: DecalMaterial 0x38, DecalSize 0x40, DecalExtraRotation 0x4c, DecalRandomRotation 0x58,
DecalSizePercentageOffsetRange 0x64, SortOrder 0x68, bApplyCustomFadeInSettings 0x6c, FadeInStartDelay 0x70,
FadeInDuration 0x74, FadeStartDelay 0x78, FadeDuration 0x7c, FadeDistance 0x80, DestroyFadeStartDelay 0x84,
DestroyFadeDuration 0x88. Defaults (ctor 0x140cd3cf0): size (8, 16, 16), rotations 0, range 10 %, sort 0, fade-in 5 s +
2 s, fade-out 10 s + 5 s, FadeDistance 400, destroy fade 0 + 5 s.
- Spawn attached (slot 0x258, `0x140ccb930`) / at location (slot 0x260, `0x140ccba60`): rotator = spawn rotator +
  (Extra + Random * FRand per axis, rand() order roll, yaw, pitch; `0x140cc1fa0`), FRotator addition; size =
  DecalSize * (rand & 0x7fff * range * 6.103702e-07 - range * 0.01 + 1); `SpawnDecalAttached(..., KeepWorldPosition,
  LifeSpan 0)` / `SpawnDecalAtLocation`.
- Component setup `0x140cc2aa0`: SetSortOrder; SetFadeIn if bApplyCustomFadeInSettings; SetFadeOut(FadeStartDelay,
  FadeDuration, false); SetFadeScreenSize(1 / FadeDistance); OnDecalFadeFinished destroys it.
- Stop (slot 0x280, `0x140cbf4e0`): SetFadeOut(DestroyFadeStartDelay, DestroyFadeDuration + 0.1).

## 5. Decal material (M_DecalPOM_DNR)
MD_DeferredDecal, DBM_DBuffer_ColorNormalRoughness, BLEND_Translucent. All 19 dumped bullet / melee MIs share shader
map BB361826D306832FC1181979F3661A1B429A2100; FDeferredDecalPS High = archive index 861 (decompiled
`extracted/shaders/dis/DeadIsland_000861_decalpom_ps.hlsl`, annotated `extracted/shaders/annotated/...`). Transcribed
in `weapon_vfx_decal_pom.gdshader` (header lists the math): parallax occlusion with POMMinSteps 4 / POMMaxSteps 25
(MPC_GameWideParams), BC5 normal, ARA = (opacity, roughness, tint mask), diffuse x lerp(1, tint, ARA.b), opacity edge
fade sat(4 - 4 |OS.x|) x DecalParams x ARA.r. Master defaults: Roughness Adjustment 0, Depth 0.03, Tint (1,1,1); the
bullet MIs set Depth 0.2.

Two renderers (`WeaponVfx.decal_renderer`):
- `"decal"` (default): a Godot `Decal` with `cull_mask` = the world layer, so decals never land on characters
  (Fx.CHARACTER_LAYER). Like DI2's DBuffer it blends colour / normal / roughness into the surface before lighting. The
  builder composes its textures from the MI's maps the way PS 861 does (`<MI>_albedo` = sat(lerp(1, tint, ARA.b) x
  Diffuse) with alpha sat(ARA.r); `<MI>_normal` = the BC5 normal with green flipped for Godot's decal decode;
  `<MI>_orm` = (1, sat(Roughness Adjustment + ARA.g), 0)). Lost: the parallax occlusion (height map) and the exact
  sat(4 - 4 |OS.x|) depth ramp (Godot's (1 - |y|)^0.05).
- `"pom"`: the full PS 861 transcription (`weapon_vfx_decal_pom.gdshader`) on a depth-reading box: parallax depth and
  edge ramp exact, lit after the surface (blend order differs), and it also paints on characters inside the box.
Basis: Godot decal local X = UE decal Z (U), local Z = UE Y (V), local Y = -UE X (out of the surface).

## 6. Not ported / differences
- CE AudioEvent and PhysicalizedWorld entries (no audio, no physicalised world props here).
- LocalPlayerShootCosmeticEffect, camera shake, force feedback (§3.1.3).
- Particle modules the weapon systems use that DI2Particles doesn't run yet are the particles session's list
  (Light — the muzzle flash light and the tracer light —, Orbit, VectorField*, InheritPlayerVelocity, GPU sim).
- Decal rendering: the default Godot Decal has no parallax occlusion and an approximated depth ramp; the "pom" box is
  exact but lit after the surface and not excluded from characters; the screen-size fade (SetFadeScreenSize) is not
  applied (recon/UNVERIFIED.md).

## 7. Notes for the other sessions
- DI2 defers the whole point impact of a hitscan shot (damage, hit reacts, FLESH) by min(distance / speed, 0.25 s)
  (`0x1415d7260`); the recreation's `_hitscan` applies zombie damage immediately (gameplay code, not changed here).
- `tools/build_hit_effects.py` doesn't read `DI2/Expansion01/Effects/ModularTrees` (CT_Env_SpawnProjectilesOnSurface,
  CT_WeaponModLvl, used by the ranged environment / victim trees for crossbow bolts and mod levels).
