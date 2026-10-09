# DI2 fluids (blood / petrol / water / acid): native code and data

These are static RE notes on `DeadIsland-Win64-Shipping.exe`, with data from the extracted assets. The decompiled C is in `extracted/ghidra/explosion_fluid*.c` and `explosion_drop*.c`.

The fluid system is DI2's gameplay fluid simulation. The particle port (recon/PARTICLES.md §5.12) keeps its data only. It makes:
- the blood that hits throw onto the world,
- the blood from dismembers (gradual damage `fluid`),
- the molotov's burning petrol,
- slobber bile and acid pools.

## 1. Data

**`DA_FluidTypeInfo_<Type>`** (BalancingData/EnvHazards/Fluids). Blood's values:
- ProjectileClass BP_Fluid_Projectile_Blood, DropletClass BP_Fluid_Droplet_Blood.
- MinRadius 20, MaxRadius 55, VisualRadiusMultiplier 1.75, VisualRadiusInterpolationSpeed 4.
- TimeIdleBeforeAutoEvaporate 10 s, EvaporationAreaPerSec 50.
- ImpactPointScaleMultiplier 1.5, MaxSurfaceNormalDeviationFromFlatForPoolingInDegrees 30, StartingDecalRadiusMultiplierIfActorIsImpact 0.3.
- Drip particles PS_Drips_Blood; SpawnableGibs SM_BloodGibs1..7 (GibProbability 0); AreaOfEffectRadiusScalar 0.572.
- DecalMaterial MI_BloodDecal, DecalSize (64, 256, 256), MinOpacity 1, FadeIn / FadeOut 1.5 s, SpawnPriority 0.5.
- Consumption: Curve_FluidConsumption, MinimumPuddleSizeForSkippingConsumption 128.

**`DefaultFluidManager.ini`** (`AFluidManager`):
- DecalVerticalHeight 10, MergeDistIncrease 1.2, MergeMaxRange 256, MaxDirtyInstancesProcessedPerFrame 10.
- MinFlowPropagationSpeedForFlow 0.1, FlowAreaPerSecond 10000, MaxFlowDirDeviation 10.
- RayHeightOffsetFromSurface 5, RayLength 32, DripSpawnSurfaceOffset 16.
- GroundAnchorSurfaceNormalVsFlowStepDirBlend 0.5, GroundAnchorRayLength 300.

**Emitters:**
- **153 hit CEs** carry `UCosmeticEffect_FluidParticle` entries: FluidType +0x38, ProjectileSpawnMethod +0x48, Speed +0x50, Amount +0x54. The particle port stores them in particles.json `ce[*].fluid`. For example, CE_Blunt_Crit_Normal has blood 300 cm/s, amount 35, single, plus blood 450, amount 15, as a ±30° burst.
- **Gradual damage effects** carry `fluid`: FluidType, FluidAmount, FluidStrength, EmissionVelocity. Examples: Dismember 50 / 4 / 100; BoneBreak 10 / – / 30.

## 2. A CE's fluid spawn (`UCosmeticEffect_FluidParticle` vtable 0x1453f0048, spawn 0x14143f470 → 0x14143ffa0)

- `velocity = Speed × SpawnRotation.Vector()`. The spawn rotation is the CE's (recon/RE_FLESH.md "Hit-effect spawn transform"), so hit blood leaves along the effect's X axis.
- **No spawn method:** one request `0x14142e080(world, FluidType, location, attachActor, &velocity, Amount, …)`.
- **With a spawn method:** the method's virtual +0x240 fills a list of transforms (0x30 each: quat, location). Each gets a request with `velocity = transform X × Speed`.
  - **Single** (`USpawnMethodSingleProjectile`, vt 0x145680428, +0x240 0x141595dd0): one transform.
  - **Burst** (`USpawnMethodBurstProjectile`, vt 0x145680680, +0x240 0x141595800):
    - count = rand in [MinProjectileCount +0x28, MaxProjectileCount +0x2C];
    - horizontal cone [Min +0x30, Max +0x34] widened by the caller's dynamic spread; vertical cone [+0x38, +0x3C];
    - with bUseDistributionGridForRandomPlacement (+0x40): DistributionGridHeight +0x44 × Width +0x48 cells, shuffled by an MT19937 seeded from the shot, an LCG (×0xBB38435 + 0x3619636B) deviation within a cell (DeviationScaleWithinCell +0x50), and the cell's vertical angle in 0x14158bed0;
    - optionally one central projectile.
  - **Port:** uniform within the cone per grid cell, the same approximation as the ranged pellets (UNVERIFIED #25).

## 3. Request (`0x14142e080`)

- If FluidTypeInfo.DropletClass (+0x38) is set and the droplet cvar is on: a **droplet** (`UFluidSimDropletManager`, world subsystem +0x5E8 → +0x478, add 0x14146fd00). Each type keeps up to 10000 droplets of 0x50 bytes (+0x220).
- Otherwise: the ProjectileClass actor (+0x30) is spawned along the velocity (0x1415ac260). Its rotation is the velocity's, speed = |velocity| (+0x2C), amount +0x128.

## 4. Droplets (`UFluidSimDropletManager` vt 0x14549cbd0; tick through its FTickableGameObject vtable 0x14549ce08 slot 0 → 0x141471320 → per type 0x141471940)

**Config** (`FFluidSimDropletConfig` in BP_Fluid_Droplet_<Type>):
- FluidTypeInfo +0x0.
- ProjectileParams `FFluidSimDropletProjectileConfig` +0x8, with native defaults from the struct ctor 0x141c0ffa0:
  - CollidesWith = {WorldStatic, WorldDynamic};
  - MinUpdateInterval 0.1 s (+0x50);
  - Lifetime 5 s (+0x54).
- PayloadParams `FFluidSimDropletPayloadConfig` +0x60: FluidPayloadClass (BP_Fluid_Puddle_<Type>), FluidPayloadRadius, InitialActiveStates, bOverrideFluidsOnConsume, bCritical, bOverridePriority, SpawnPriority, ImpactVelocityTransferMultiplier.
- PointImpactParams +0xA8.

**Each tick:**
1. Trace results first: a hit runs the impact (0x141465580) and kills the droplet (state 2).
2. A droplet older than Lifetime dies.
3. A flying droplet (state 0) whose last trace is ≥ MinUpdateInterval old steps (0x141474370):
   - `dt = now − lastTrace`;
   - `pos += v·dt + ½·g·dt²`, `v += g·dt`, with `g = (0, 0, World GravityZ)`;
   - an async line trace runs from the old position to the new one against CollidesWith, ignoring the source actors;
   - then state 1 (awaiting the trace).

**Impact (0x141465580):**
- An optional splatter (0x141450f90).
- Then the payload: the FluidPayloadClass actor (an `AFluidInstanceActor`, a puddle):
  - at the hit's ImpactPoint (+0x1C), rotated from the ImpactNormal (+0x34);
  - FluidTypeInfo from the config;
  - radius = the droplet's radius, else the config's FluidPayloadRadius;
  - plus the config's states / priority.

## 5. Puddles (`AFluidInstanceActor`, BP_Fluid_Puddle_<Type>)

Each puddle has:
- two decal components (Primary / Secondary);
- a collision sphere;
- an AOE responder;
- a state transmitter (Burning / Electrified, used by petrol and water).

**Where a payload goes** (`AFluidManager` request 0x141456ea0):
- Candidates: same-type instances within MergeMaxRange (256), found through the grid 0x141449140. The nearest valid one is chosen by 0x14145d810.
- Merge condition 0x141474c00:
  - reach = R × k;
  - k = Curve_FluidConsumption(R) when the type's bUseCurveForSpawnDistanceWhenSkippingConsmuption is set (Blood: 1.0 at R ≤ 40, 0.8 at 166.2);
  - otherwise k = SpawnDistanceRequirementWhenSkippingConsumption when R > MinimumPuddleSizeForSkippingConsumption, else 1;
  - the payload is accepted when R·k > R or dist ≤ R·k.
- **Add** (0x14142c790):
  - R = sqrt(R² + r²), capped at +0x344 (taken as MaxRadius; the source of the cap is not traced). The overflow area goes to flow, which is not ported.
  - It restores opacity and resets the idle timer (0x14143cdf0).
- **New instance** (init 0x14143e8a0):
  - R = max(r, MinRadius);
  - target opacity = rand[MinOpacity, MaxOpacity];
  - visual radius = StartingDecalRadiusMultiplierIfActorIsImpact × R × VisualRadiusMultiplier.

**Tick** (0x141440f30):
- Restoring opacity: FInterpTo(opacity, target, dt, OpacityRestorationInterpolationSpeed) (FInterpTo 0x141f27800).
- Visual radius: FInterpTo(visual, VisualRadiusMultiplier·R, dt, VisualRadiusInterpolationSpeed).
- After TimeIdleBeforeAutoEvaporate seconds idle, evaporation starts (0x1414464c0): rate = sqrt(EvaporationAreaPerSec / π) × target opacity / R, and opacity −= rate·dt. The instance goes at 0.

**Decals** (0x14143aef0):
- Scale Y/Z = visual / DecalSize.Y/Z, so the decal's half extent = the visual radius.
- Depth = DecalSize.X.
- Opacity goes to the decal at +0x51C (DecalParams, used by the shader as cb0[16].x·y).

**M_FluidDecal** (FDeferredDecalPS, shader archive 10960; `extracted/shaders/annotated/DeadIsland_010960_*`). With p in decal space and pixels outside ±1 discarded:
- a = 1 − min(1, y² + z²);
- dither = (1 − a²)^DitherFalloffCurve (8) × (MaxDither 0.5 − MinDither 0.02) + MinDither;
- ign = InterleavedGradientNoise(pixel + frame·(32.665, 11.815)) − 0.5;
- coverage = sat((ign·dither + 1) · OpacityScale (1) · a²) × (1 − |x|) × fade × opacity;
- rgb = "Fluid Type" (blood (0, 1, 1)).
- This goes into DI2's fluid buffer, not the GBuffer.

## 6. Fluid compose (`/Engine/Private/DS/Internal/Fluids.usf`)

Decompiled from Global 1856 / 1857 (FFluidDetailFilterPS) and 1858 (FFluidComposePS) into `extracted/shaders/dis/Global_00185*_fluid*.hlsl`.

**FFluidComposePS**, with c = the filtered coverage (discarded < 0.001) and t = the type buffer (rgb, w):
- sel = sat((1 − t.rgb) / (t.w + 1e−7)). Blood's (0, 1, 1) gives sel = (1, 0, 0).
- colour:
  - start from lerp(View[235], View[236], sel.x);
  - then lerp it toward lerp(View[233], View[234], 1 − c²) by sel.z;
  - then toward lerp(View[231], View[232], 1 − c²) by sel.y.
  - So blood = View[236]. The edge/colour pairs (fuel, acid) shade thin fluid (low c) toward the second colour.
- out1 (base colour) = (min(1, rgb^(FluidDensity · c²)), colour.w · c);
- out0 = rgb × (1 + 5·colour.w·c), alpha 0;
- out2 = (metallic 0, specular 0.35, roughness FluidRoughness, alpha sqrt(c)).
- **Pass setup** (render function 0x1425dcc20):
  - FFluidDetailFilterPS (shader type 0x146d60df0, permutation 1 when the setting is on) binds static blend state 0x14693d560 (creator 0x14062a200).
  - FFluidComposePS (0x146d60f00) binds static blend state 0x14693d578, rasterizer 0x146b74778 and depth-stencil 0x146d633e8.
- **The compose blend state** (built in 0x1425d5850; FBlendStateInitializerRHI::FRenderTarget = {ColorOp, ColorSrc, ColorDst, AlphaOp, AlphaSrc, AlphaDst, WriteMask}):
  - RT0 = {Add, SrcAlpha, SrcColor, Add, One, One, RGB}: out0's alpha is 0, so dst.rgb × out0.rgb = dst × rgb·(1 + 5·w·c).
  - RT1 = {Add, SrcAlpha, SrcColor, Add, One, One, RGB}: dst.rgb × rgb + rgb·(w·c).
  - RT2 = {Add, SrcAlpha, InvSrcAlpha, Add, One, One, G|B}: specular and roughness lerp toward (0.35, FluidRoughness) by sqrt(c).
  - RT3 = {Add, Zero, SrcColor, …, RGB}: unused by the shader.
  - So the fluid **multiplies** the surface by its transmittance rgb^(FluidDensity·c²) (absorption). It does not paint a colour.
- Which GBuffer each of RT0 / RT1 is (base colour vs scene colour or diffuse) is not traced (UNVERIFIED). Both are multiplicative.
- Blood: C = (0.88, 0.1956, 0.1467), so at c = 1 T = (0.279, ~0, ~0). A thick puddle keeps 28% of the surface's red and none of its green/blue.

**Sources of the constants:**
- **`AFluidParamsUpdateActor`** (an Engine config class placed in levels; ctor 0x1436ff060):
  - DetailSize 55;
  - AbsorbencyRampEnd 1.0, AbsorbencyRampStart 0.6;
  - MaxFluidOnWalls 0.9;
  - FluidDensity 10;
  - NormalStrength 0.05;
  - NormalFlatnessWalls 0.96, NormalFlatnessFloors 0.993;
  - FluidRoughness 0.08.
  - Per-level instances may override these; maps are not extracted, so this is UNVERIFIED.
- **The colours** are DI2 additions to `FPostProcessSettings`:
  - BloodColor +1852, WaterColor +1836, FuelEdgeColor +1820, FuelColor +1804, AcidEdgeColor +1788, AcidColor +1772;
  - TintedBloodColor +1756 … TintedAcidColor +1676.
  - Which set feeds View[231..236] is TODO.

## 7. Port (`game/scripts/di2_fluids.gd`, class DI2Fluids)

- **Emission:** `DI2Fluids.emit_ce(node, ce, pos, base)` from `zombie._play_hit_particles`, with the CE's spawn basis (+X = HitEffectSpawn's forward).
  - Single: one droplet along X.
  - Burst: count rand[Min, Max] (native 3/3); yaw / pitch uniform per DistributionGrid cell (UNVERIFIED #25, as for the pellets).
- **Droplets:**
  - step every MinUpdateInterval with g = DefaultGravityZ −980 cm/s²;
  - a ray against Util.WORLD (characters don't stop them);
  - Lifetime 5 s.
  - The trace is immediate; DI2's lands one tick later.
- **Puddles:** merge / add / new / tick / evaporate as in §5. A per-scene cap of 256 instances (the recreation's; DI2's pool size isn't traced).
- **Drawing:** DI2's fluid buffer + compose (§5-6).
  - DI2Fluids renders every puddle's M_FluidDecal coverage (`game/shaders/di2_fluid_coverage.gdshader`: a², IGN dither over map texels, opacity) into a top-down fluid map: a SubViewport over `DI2Fluids.map_area`, 2.5 cm texels, a = coverage (alpha-over), r = coverage-weighted surface height. It re-renders only when a puddle changed.
  - The map is published as the global shader uniforms `di2_fluid_*` (project.godot [shader_globals]).
  - World materials include `game/shaders/di2_fluid.gdshaderinc` and call `di2_fluid_compose(world_pos, ALBEDO, ROUGHNESS, SPECULAR)`, which applies:
    - depth fade 1 − |dy|/DecalSize.X;
    - the detail filter's ×12 sharpening;
    - albedo = T·(albedo + w·c) with T = min(1, BloodColor^(FluidDensity·c²));
    - specular/roughness → (0.35 as Godot sqrt(0.35/2), FluidRoughness) by sqrt(c).
  - The arena floor (`game/shaders/arena_floor.gdshader`) uses it. Characters don't include it.
  - Only near-flat surfaces show puddles (the map is top-down).
- **Not ported:**
  - flow and overflow;
  - drips (DripParticleType);
  - gibs (GibProbability 0 for blood);
  - pooling-angle rules (MaxSurfaceNormalDeviationFromFlatForPoolingInDegrees);
  - wall behaviour (MaxFluidOnWalls);
  - the Secondary decal;
  - the detail filter's normal / absorbency terms;
  - the electrified state (Burning is ported: §9.5);
  - FluidStrength (forwarded to the payload as a TOptional; flow).

## 8. Wound fluid (gradual damage effects)

`UDamageRepercussions` processes a wound in 0x14129a8e0 (recon/RE_DISMEMBER.md §2.1). It calls `RequestGradualDamageEffect` (0x1412ae1f0), and then emits the effect's InitialEffect fluid.

**Data** (`FDamageEffectSet` = InitialEffect +0x30 / OverTimeEffect +0x1A0 of `UGradualDamageEffect`):
- Fields: SplatterInfo +0, SplatterModifiers +168, FluidType +344, FluidAmount +352, FluidStrength +356, EmissionVelocity +360.
- Native defaults, from StructOps 0x141c61490 (Construct = memset 0x170 + ctor 0x141c63830): FluidType null, FluidAmount 20, FluidStrength 2, EmissionVelocity 20.
- `UGradualDamageEffect` ctor 0x141c635d0: Duration (+0x318) −1, EmmissionPeriod (+0x31c) 0.5, ParticleSystem (+0x310) null.
- `tools/build_gradual_damage.py` resolves these into `game/data/gradual_damage.json`.

**Initial fluid** (0x14129a8e0, after the request, owner role Authority):
- One `0x14142e080` request with FluidType = InitialEffect.FluidType.
- Location = the wound's LastHitLocation.
- Velocity = `&FVector::ZeroVector` (0x146cbd598: the request compares against it), so the blood drops straight down.
- Amount = InitialEffect.FluidAmount (+0x190).
- Strength = {InitialEffect.FluidStrength, set}.
- InitialEffect.EmissionVelocity is not used.

**The gradual particle system:** `RequestGradualDamageEffect` spawns ParticleSystem (+0x310) attached to the wound bone at the wound transform (0x143745a30). With bRenderCustomDepth (+0x328) set, it also enables custom depth with the stencil mask (+0x324).

**Over time** (timer callback 0x14129b260):
- The timer period is 0.2 s when OverTimeEffect's splatter does anything ((SplatterType & 0xFE) ≠ 0 or any decal texture). Otherwise it is EmmissionPeriod when a FluidType is set (none if < 0), else Duration (none if ≤ 0).
- Each update: elapsed += dt.
- With a FluidType and owner Authority, and while n · EmmissionPeriod ≤ elapsed, one request (n += 1):
  - at the wound location (the bone's current transform × the instance's relative transform);
  - velocity = the instance's stored emission direction (the hit rotation's forward put into bone space at creation, × scale), rotated by the bone, × OverTimeEffect.EmissionVelocity;
  - amount = OverTimeEffect.FluidAmount;
  - strength = {FluidStrength, unset}.
- Then the splatter (DisplacementScale × dt/Duration).
- The instance ends when elapsed ≥ Duration.

**Other request callers:** the CE FluidParticle (0x14143ffa0) and 0x141470450 (not traced).

**Port** (zombie.gd `_gradual_particles` / `_gradual_initial_fluid` / `_gradual_over_time`):
- as above, through DI2Fluids.request;
- the wound rotation (LastHitRotation, writer untraced) is taken as the hit's travel direction (UNVERIFIED #54);
- the timer dt is taken as the period.

## 9. Molotov: burning petrol

Decompiles: `extracted/ghidra/explosion_{aoe,aoetick,xmit,fsproj,spread}.c`; BP bytecode: `extracted/json_bp/.../EnvHazards/`
(tools/bpdump, tools/bp_pretty.py).

### 9.1 Bottle → petrol projectiles (`BP_MolotovCocktail_Projectile`)

On world collision, two `InvokeCollisionLocationResponse`s each run a `ProjectileResponseSpawnProjectile` (vt 0x14520c988)
that spawns `BP_Fluid_Projectile_Petrol` through a `SpawnMethodBurstProjectile` (§2):

| Response | Burst (count, cone h / v, MinSpreadDistance +0x54 / Max +0x58) | Speed (rand) | FractionOfParentVelocityToInherit | SpawnDirectionAxis | FluidPayloadRadius | InitialActiveStates |
|---|---|---|---|---|---|---|
| 0 (asset .18 / .29 / .6) | 4, ±90° / ±90°, 75 / 75 | 300–400 | 0.25 | Z | 80 | Burning |
| 1 (.19 / .30 / .7) | 1, 0° / 0°, 50 / (0) | 50 | 0.5 | (X, default) | 128 | Burning |

`InvokeParentProjectileLocationResponse` → `ProjectileResponseCreateExplosion` (DA_ExplosionArchetype_Molotov, ported in
di2_explosion.gd). Direct hits: 5 Fire damage (`ApplyPointImpactCollisionResponse`), Thrown. Creation params
(`FluidSimProjectileCreationParams`, members from reflection): bRandomRangeInitialProjectileSpeed, OverrideInitalProjectileSpeed
+0x2C, …RangedMin +0x30, …RangedMax +0x34. RequestType PlayerRequest.

### 9.2 Petrol projectile (`AFluidSimProjectile` : `AModularProjectileActor`)

- Classes: AFluidSimProjectile StaticClass 0x141c0e790, ctor 0x14144bda0, vt 0x1451acda0 (213 slots); AModularProjectileActor
  0x141d48690, ctor 0x1415881f0, vt 0x145208fa0.
- Ctor: CollisionComp = USphereComponent radius **5** (+0x510 = 0x40a00000), collision profile "FluidSimProjectile";
  FluidPayloadRadius (+0x6E0) 32 (BP_Base_Fluid_Projectile_Petrol CDO: 60; the creation params override it).
- Movement: AModularProjectileActor's `DIProjectileMovementComponent` (+0x2B8): InitialSpeed 0 / MaxSpeed **3000**
  (0x141588564), bRotationFollowsVelocity set, **bShouldBounce cleared** (0x141588583); ProjectileGravityScale **1.0**
  (UProjectileMovementComponent ctor 0x143600047). Both petrol BPs leave the component at these defaults. So the flight is
  UE's projectile movement: v0 = spawn axis × speed + fraction × parent velocity, gravity = World GravityZ, sweep, stop at the
  first blocking hit.
- Slot 210 (0x141468eb0, creation params applied): params (+0x6F0); FluidActorInitialState (radius +0x128, states) → the
  `SpawnFluidActorCollisionResponse` (+0x6F8) that spawns the payload (BP_Fluid_Puddle_Petrol) on collision.
- `CosmeticEffectsSphere` (Trigger profile, overlaps Pawn) → BP OnOverlap: BP_StatusEffect_Flammable (Duration 20) on any actor
  with a BPC_StatusEffect component.

### 9.3 Puddle states (`UFluidActorStateTransmitterComponent` : `UStateTransmitterComponent`)

- Classes: UFluidActorStateTransmitterComponent 0x141c0e1b0, ctor 0x141425150, vt 0x1451a19b8; UStateTransmitterComponent
  0x141dfdb10, ctor 0x14144dbf0, vt 0x1451aac00 (179 slots). Owner = +0xD0.
- **Config defaults** (`UStateTransmitterConfig` ctor 0x141dfd640; `UFluidStateTransmitterConfig` 0x141c0f720 adds only the map):
  bBeginWithStatusActive 0, FiniteStatusLifetime (+0x34) −1, bIsTransmitter 1, InitialTransmitRadius (+0x3C) 1,
  bAddOwnerRadiusToTransmitRadius 1, InitialTransmitTick (+0x44) 1, FirstTransmitDelay (+0x48) 0, bDirectedAcyclicTransmissions 0,
  TransmissionOriginStrength 1, MaximumTransmissionDistance FLT_MAX, bIsReceiver 1, bAddOwnerRadiusToReceiveRadius 1,
  AreaOfEffectResizePolicy (+0x68) **1 = AutoResizeToOwnerCollisionRadius** (enum: 0 NoAutoResize, 1 AutoResizeToOwnerCollisionRadius,
  2 AutoResizeToTransmitRadius), MaximumRelativeVerticalOffsetAllowed 25, Minimum 0, OverloadTransmitRadius / Tick 1.
  DA_FluidEnvMessageRelay_Ignite sets InitialTransmitRadius 30, InitialTransmitTick 0.1, FirstTransmitDelay 0.05,
  ForcedEvaporationAreaPerSecond[Burning] 25, AreaOfEffectClass BP_AOE_DamageOverTime_Fluid_Burning, bRestrictRelativeVerticalAreaDimensions,
  bUseOnlyCosmeticEffects, CosmeticEffect CE_Fluid_State_Flammable, DefaultParticleType PS_Burning_Liquid.
- **Fluid overrides** (owner IsA AFluidInstanceActor; puddle fields: FluidTypeInfo +0x2C8, Radius R +0x330, opacity +0x350,
  target opacity +0x354, evaporation flags +0x358, forced area/s +0x35C, rate +0x360):
  - GetOwnerCollisionRadius (slot 172, 0x141432610) = R. Slot 173 (0x141432570) = MaxRadius × VisualRadiusMultiplier.
  - Status activated (slot 175, 0x141434f70): the particle's scale parameter = VisualRadiusMultiplier × R (also refreshed each
    tick by 0x1414421f0 when it or the opacity changes, the opacity going to a vector parameter); the particle is activated;
    if ForcedEvaporationAreaPerSecond[status] > 0: +0x35C = it and evaporation flag 2 is set (0x1414464c0(puddle, 2, 1)).
  - Status deactivated (slot 176, 0x141436e70): +0x35C = 0, flag 2 cleared.
  - CanTransmit (slot 178, 0x141429900): puddle +0x2D4 ≤ opacity, then the base check.
- **Evaporation flags** (0x1414464c0): bit 1 idle, bit 2 forced. Any flag set → rate = sqrt(A/π) × target opacity / R with
  A = the forced area (+0x35C) when bit 2 is set, else the type's EvaporationAreaPerSec. So a burning puddle starts evaporating
  at once at A = 25, without waiting for TimeIdleBeforeAutoEvaporate.
- **AOE per active status** (slot 168, 0x14146cc50): `NewObject(AreaOfEffectClass)` → instance +0x58, set up on the owner,
  SetEffectInstigator (0x1412b1820, AOE +0x304) = the status's instigator, registered.
- **Transmitter tick** (slot 102, 0x141471850): per active status with an AOE, policy 1: CanTransmit false → the AOE is destroyed;
  else SetEffectRadius(GetOwnerCollisionRadius()) (0x1412b1af0: the AOE's USphereComponent SphereRadius (+0x510) = R).
  Policy 2: radius = the instance's transmit radius (+0x28).
  **So the burning AOE is a sphere of the puddle radius R.** AreaOfEffectRadiusScalar is not on this path.

### 9.4 Burning AOE (`BP_AOE_DamageOverTime_Fluid_Burning` → `UDamageAOEDamageOverTime` → `UDamageAreaOfEffect` → `UAreaOfEffectBase`)

- Classes (all USceneComponents): UAreaOfEffectBase 0x141b4de20, ctor 0x14128f370, vt 0x145162130; UDamageAreaOfEffect
  0x141ba72e0, ctor 0x141ba7890, vt 0x1453fed08; UDamageAOEDamageOverTime 0x141ba7590, ctor 0x141ba7790, vt 0x1453ff828.
- **Base defaults** (0x14128f370): EffectApplicationTickInterval (+0x2B0) 1, DelayTimeBeforeFirstEffectApplication (+0x2B4) 0,
  InitialEffectRadius (+0x2B8) 100, bAllowUseOfSuggestedInstigator 1, MultipleOverlapRule (+0x2C9) **0**,
  bRestrictRelativeVerticalAreaDimensions (+0x2E0) 0, MaximumRelativeVerticalOffsetAllowed (+0x2E4) **10**, Minimum (+0x2E8) 0,
  Strength (+0x300) **1**. BP_Base_AOE_DamageOverTime: tick 0.5, InitialEffectRadius 10; the Fluid_Burning child sets
  bRestrictRelativeVerticalAreaDimensions.
- **Vertical rule** (0x14129af70(aoe, point, halfHeight)): with the restriction on, z = the target point's height in the AOE
  shape's local frame; rejected when z − halfHeight > Max or z + halfHeight < Min. So an actor whose vertical extent overlaps
  [0, 10] cm above the puddle is affected.
- **Who may be affected** (slot 171, 0x1412b2450): not one of IgnoreActorTypes.
- **Tick** (per affected actor, receiver component tick 0x1412b5ce0): AOEs are listed per actor by category; each entry keeps a
  next-application time. While an AOE isn't active its time is pushed to now + Delay. When now ≥ time: if MultipleOverlapRule ≠ 0
  or the AOE is the **first in its category list**, TickAppliedToActor (slot 170, 0x141294c50: broadcast TickAppliedToActorDelegate
  + BP UpdateActorAffected); then time += EffectApplicationTickInterval. So overlapping burning puddles (all
  DA_AreaOfEffectCategory_Fire) don't stack: one applies per 0.5 s.
- **BP UpdateActorAffected** (owner has authority) → CanAffectTarget → RequestImpactOnTarget:
  - CanAffectTarget: alive (BPFL IsActorAlive) and, for a DICharacter, not `#ImmuneToPuddleDamage` (DT_ExpressionAliases_Attachments:
    empty expression); the Fluid_Burning override also requires !IsBodyBurnt for dead actors (unreachable: the base needs alive).
  - Damage = HazardDamageToApply (11), or HazardDamageToApply × StatusEffectScalar (1) when the target's KB fact IgnoreDamageKbFact
    (IsOnFire) is true; × GetCurrentStrength() (1).
  - GeneralImpactEvent: DamageEventsToApply [{DamageType BP_DamageType_Fire, quantity}], AttackOrigin = the AOE's location,
    bFriendlyFireAllowed, CriticalHit multipliers 1, DismembermentChanceOnKill 1, ImpactSettings {WeaponSizeMultiplier 0.5,
    EnvironmentalMessagesToTransmit [Burning activation strength 1], AccumulatingEffectsToApply [Burning 0.3, can extend],
    WorldSpaceImpulseMagnitude 2000 along (0,0,0), PhysicalizedReactionMagnitude 0, bCanCauseCosmeticFlinches, !bCanLaunch,
    DamageLevelScalingPolicy ScaledToInstigatorLevelFallbackToVictimLevel, AccumulatingEffectsScalingPolicy 1, ImpactStimDuration 0.5},
    NetworkingPolicy 1, ImpactGameplayCategory 3.

- **Ignition spread** (transmit timer set on activation in slot 168: FTimerManager::SetTimer(instance +0x38, rate = instance +0x2C
  (InitialTransmitTick 0.1), loop, first delay FirstTransmitDelay 0.05 (config +0x48))). Each transmit queries receivers
  (0x14145f430(status, transmitter, world, origin, radius = instance +0x28 = InitialTransmitRadius 30)): the transmitter adds its
  GetOwnerCollisionRadius when bAddOwnerRadiusToTransmitRadius (config +0x40); a candidate (a receiver of that status from the
  world's spatial query 0x141468fd0) adds its own when its config's bAddOwnerRadiusToReceiveRadius (+0x59); it is reached when the
  3D distance between the components ≤ 30 + R_transmitter + R_receiver. 0x1414606b0 = the transmit radius (+0x28 + owner R).
  Receivers of Burning here: puddles whose type has a Burning config (petrol; blood has no transmitter). DA_EnvMessageRelay_Ignite_Zombie
  / _Player have bIsReceiver false (radius 100, AutoResizeToTransmitRadius): burning characters ignite puddles, never the reverse.
- **MinSpreadDistance / MaxSpreadDistance** (burst +0x54 / +0x58): not read by the burst's transforms (0x141595800) or its spawn
  slot 71 (0x1415abaf0); no float read of +0x58 in 0x141590000–0x1415b0000. The port ignores them (UNVERIFIED #61).
  BurstProjectileTargetRule (+0x5C) only decides whether a projectile keeps its target.

### 9.5 Port (`game/scripts/di2_fluids.gd`, data `game/data/fluids.json` from tools/build_fluids.py)

- **Data:** `state_configs` (the types' DA_FluidEnvMessageRelay_* over the §9.3 config defaults), `aoe` (their AOE classes'
  BP CDO chains over the §9.4 base defaults), `projectiles` (BP_Fluid_Projectile_* over the §9.2 defaults), `molotov_spawns`
  (the bottle's two ProjectileResponseSpawnProjectile with creation params and bursts), each type's decal `FluidTypeColor`.
- **Bottle:** player_moves.gd `Curveball._ignite(at, normal)` → DI2Explosion "Molotov" + `DI2Fluids.molotov_burst(node, at,
  normal, bottle velocity, player)`: collision frame MakeFromZ(normal) (0x141f2b7c0), spawn X = its SpawnDirectionAxis
  (MakeFromX), burst directions (`_burst_dirs`, uniform without the distribution grid), speed rand(min, max) + fraction × the
  bottle's velocity. The old Fx.fire_area / `_burn` stand-in is gone.
- **Projectiles:** `spawn_projectile` / `_tick_projectiles`: UE ProjectileMovement step (v' = clamp(v + g dt, MaxSpeed),
  Δ = v dt + (v' − v) dt / 2), the 5 cm sphere's sweep as the centre ray extended by the radius along the motion, against Util.WORLD; the first hit → `_payload` with the
  creation radius, then `activate_state` for each InitialActiveStates (also when the payload merged into a puddle: UNVERIFIED #61).
- **Evaporation flags:** `_set_evap` = 0x1414464c0 (idle / forced bits, rate recomputed on a change); `_add` clears only the
  idle bit (0x14143cdf0).
- **States:** `activate_state(puddle, status, instigator)` (type remapping, config, AOE, transmit timer, cosmetic effect
  CE_Fluid_State_Flammable → PS_Burning_Liquid with "Radius" = VisualRadiusMultiplier × R and "Opacity" = (o, o, o), forced
  evaporation); `_tick_states`: CanTransmit = opacity ≥ 0.3 (else the AOE goes), `_transmit` (30 + R + R'), `_tick_aoe`.
- **AOE:** `_tick_aoe` per zombie: sphere R vs the root capsule, the vertical rule against [0, 10] cm, one AOE per category per
  zombie (the first to claim it), first application at overlap + Delay (0), then every 0.5 s; `_aoe_apply` = the BP's
  RequestImpactOnTarget through `Zombie.take_hit` (bone = the hitbox nearest the AOE origin, kind "fire") and
  `Zombie.accumulate` (Burning 0.3, can extend, instigator level), `on_damage_dealt` for the instigator.
- **Compose:** the fluid map's g / b = 1 − FluidType.r / .b; di2_fluid.gdshaderinc selects lerp(Water, Blood, sel.x) then
  lerp(Fuel, FuelEdge, 1 − c²) by sel.z (globals di2_fluid_fuel / _fuel_edge / _water, the level colours). Acid (sel.y) is not
  encoded.
- **Test:** flesh suite `_petrol_check` (5 projectiles, burning puddles with forced evaporation, ≥ 2 AOE ticks of damage and a
  Burning build-up on a zombie in the fire, spread at 120 cm but not 200 cm); captures `molotov_petrol*.png`. Verified
  2026-10-08 (game/test_out/gore_petrol): ok; the 5 projectiles merge into one R 128 burning puddle (MaxRadius; DI2 sends the
  overflow to flow, not ported); a zombie in it lost 81 health in 2 s with its Burning build-up active.
- **Look:** PS_Burning_Liquid still draws as black flipbook-atlas quads: its masked fire materials (area_flames_Masked,
  Fire_sourceSmallMasked) are on the particle port's fallback master (recon/PARTICLES.md hand-off item 3, Fire_OpacityMask);
  a particles session owns that.
- **Not ported:** the petrol projectiles' CosmeticEffectsSphere → BP_StatusEffect_Flammable (Duration 20; a debuff with
  CE_StatusEffect_Flammable / PS_Petrol_Lingering), the AOE's EnvMessages Burning activation on characters (their
  DA_EnvMessageRelay_Ignite_Zombie / _Player transmitters: burning characters igniting petrol within 100 cm), flow / overflow,
  CE_Extinguished_Fire (water blocking Burning), the fire PS's proper deactivation (the node is freed).
