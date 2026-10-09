# DI2 level as the recreation's test environment

> **Hand-off (2026-10-09 ~14:15 ET, di2-whole-map session, N1 PAUSED on the user's request; resume from here):**
> Done (commits fd34596, 382e28c + this one): step 1 inventory + plan; step 2 `--map=nh04` = every Fixed / Lighting
> tile + Main + Vista, Blueprint-template meshes (467 BP packages), per-cell groups / collision, build report
> (game/assets/di2/maps/nh04/build_report.json); step 3 landscape (86 components, heightfield collision, DI2's
> M_LandscapeLite blend transcribed from PS 26989, game/shaders/di2_landscape.gdshader); step 4 foliage
> (NH_04_Vegetation, 9.7k instances, DI2 InstanceEndCullDistance). Verified on run4 (before HLOD):
> map loads (43.5 s, 23,919 instances, 66k shapes), bot walked 368 m with no fall-through (one leg stuck at UE-ish
> (79.8, -2.7, -28.1) Godot), captures in game/test_out/di2-whole-map/run4 (labels were shifted by one: fixed since).
> **Perf is the blocker:** 18 fps / 18,400 draw calls / 15.5 M primitives. In progress (code written, NOT verified):
> DI2's HLOD (LODActor proxies + LODDrawDistance -> Godot visibility_range_begin / visibility_parent,
> build_test_map.py "hlod"). Last build said `hlod: proxies 0, orphans 6848` and 303 `mesh_no_glb`: the HLOD_Root
> cluster meshes' glb file names don't match glb_path() (check what mapx writes under
> extracted/test_map/nh04/mesh/DeadIsland/Content/DI2/Horde/Maps/NH_04/SubLevels/HLOD/) -> fix glb_path, rebuild,
> rerun the walk test (command in "Whole map" below), compare fps. The current nh04 build on disk is that broken
> HLOD build (proxies missing, children ungrouped but still drawn). Also open: 1 Jolt hull error (now hulls > 64
> points go in as trimesh; unverified), load-time breakdown (di2_map.gd now logs ms_* per phase), 22 masters drawn
> with default grey (build report "material_approximated": M_VehicleLayered, M_PlateGlass, M_PVC, ...), step 5
> (_Dynamic props / breakables, Hazards01), step 6 (4,079 DecalComponents), flesh suite with `--map=nh04`, perf
> line, Knowledge note. UNVERIFIED #108-#111.

> **Hand-off (2026-10-09, exposure / lighting session, board milestone 9):** DI2's exposure, eye adaptation, LUT and
> tonemap now run on `--map=nh04_street` (section "Exposure and tone mapping"): a CompositorEffect
> (game/scripts/di2_post.gd) with DI2's histogram + FEyeAdaptationPS math, DI2's own FLUTBlenderPS translated to GLSL
> at build time (tools/re_exposure/hlsl2glsl.py -> git-ignored post_lut.glsl; DI2's SDR device runs ACES RRT+ODT), the
> tonemap pass (exposure, vignette 0.6, PQ LUT); lights pre-exposed by P = 1.83e-5; sun 5780 K colour and DI2's
> cascades (225 m, 4 splits); UE height fog (2 layers). Street settles at EV100 12.32 (Lhist ~6100 cd/m2).
> Verified: `TEST_EXTRA_ARGS=--map=nh04_street TEST_OUT=game/test_out/exposure2 tools/run_all_tests.sh flesh`
> -> exit 0, 0 script/shader errors, no panic; captures in game/test_out/exposure2/flesh. Perf below.
> Open (UNVERIFIED #57): **lightmaps** (the level's sky light is Static and the sun Stationary: ambient, bounce and sky
> occlusion are baked; without them shadows are too dark; next step = decode MapBuildData lightmaps + volumetric
> lightmap, Godot LightmapGI can't bake runtime MultiMesh maps), local lights (BP_FixedLight_* templates), volumetric
> fog, bloom + dirt, mesopic, raw particle emissives * PreExposure (particle shaders: coordinator), static batching.

> **Hand-off (2026-10-08, di2-test-map session):** done and verified (rating P2: milestone, nothing blocked on it). `--map=nh04_street` passes the flesh suite
> (exit 0, 0 SCRIPT/SHADER errors, all checks ok); captures in game/test_out/test_map/flesh, arena pair in
> game/test_out/test_map_arena. Run: `TEST_EXTRA_ARGS=--map=nh04_street TEST_OUT=game/test_out/<you>
> tools/run_all_tests.sh flesh`. Rebuild: `tools/with_cpu.sh <you> python -u tools/build_test_map.py nh04_street`.
> Perf map vs arena: idle 103 vs 144 fps, after hits 48 vs 72 fps (GPU draw count). Open: UNVERIFIED #57; explosion
> camera clips a speaker stack (6 m clear width); a follow-up (draw cost + decals) is proposed as a session card.
> Default arena unchanged; switching the default is the coordinator's call.

> **Brief (2026-10-09, queue item N1, P1, milestone 6, di2-whole-map session):** build the whole Horde NH_04 level as
> the playground from DI2's own assets. Steps, committing after each: (1) inventory NH_04: every streaming tile /
> sublevel with counts per component type (static meshes, ISM / HISM, landscape, instanced foliage, _Dynamic physics
> props / breakables, DecalComponents, lights, blocking volumes) as a table here, then plan the order; (2) all
> static-mesh tiles with collision; (3) landscape: heightfield + collision + the layered landscape material from DI2's
> shader / material data (a new di2 landscape shader); (4) vegetation / instanced foliage (MultiMesh); (5) _Dynamic
> tiles: physics props and breakables (RigidBody where DI2 simulates; static stand-ins logged UNVERIFIED otherwise);
> (6) decals (DecalComponents with their DI2 decal materials) if time remains. Map `--map=nh04` (keep `nh04_street`
> working). Test positions stay on floor. Owned: tools/build_test_map.py, tools/test_map/*, game/scripts/di2_map.gd,
> game/shaders/di2_env*.gdshader(inc) + new map / landscape / foliage shaders, game/assets/di2/maps/*, this doc, own
> UNVERIFIED rows; main.gd's `--map` branch and di2_post.gd hooks only via exact proposals to the coordinator. Done
> when: `--map=nh04` loads every tile; build report 0 missing meshes / materials (or each logged with a reason); a
> scripted bot walks a waypoint loop across the level without falling through; fixed-camera captures per area
> (game/test_out/di2-whole-map/); `TEST_EXTRA_ARGS=--map=nh04 tools/run_all_tests.sh flesh` 0 script/shader errors, no
> [panic; one perf line (idle + after hits). Then a Knowledge note (UE4 level / landscape / foliage), a hand-off here,
> a short final message to the coordinator.

`main.gd --map=<name>` loads a section of a real DI2 level instead of the procedural arena: DI2's own static meshes,
materials, collision, time of day and sky, placed so that the level's spawn origin (an open floor area found from the
real triangles) is the Godot origin. Every fixed test position (Dani at +Z 6 m, zombies at -Z 2..6 m) lands on DI2
floor. Default (no switch) is still the procedural arena.

Personal use only: everything is read from the user's own install; `game/assets/di2/maps/` and `extracted/` stay local.

## Pipeline

| Step | Tool | Notes |
|---|---|---|
| Level packages -> JSON | `tools/di2x.sh json` | `.umap` exports (CUE4Parse) |
| Placements, transforms | `tools/test_map/level.py` | attach chains, ISM instances, hidden / collision flags, UE -> Godot |
| Open-area survey | `tools/test_map/find_open.py`, `occupancy.py`, `probe_point.py`, `survey_*.py` | used to pick the level |
| Build | `tools/build_test_map.py <map>` (through `tools/with_cpu.sh`) | writes `game/assets/di2/maps/<map>/` |
| Mesh + texture export | `tools/test_map/mapx` (.NET, CUE4Parse) | glb per static mesh (LOD0, no materials), cooked mips |
| Material chains | `tools/shaders/build_flesh_materials.py` (read-only reuse) | MI -> parent -> master, shader-map defaults |
| DDS | `tools/build_dani_materials.py` `write_dds` (read-only reuse) | cooked BC data, mips above 1024 px dropped |
| Runtime | `game/scripts/di2_map.gd` (`DI2Map`), `game/shaders/di2_env*.gdshader` | MultiMesh per mesh/material set, raw DDS, collision on `Util.WORLD` |

## How DI2 stores its levels (facts used)

- Campaign and Horde maps are split into tiles: `<Map>_T<nn>_Fixed` (static art), `_Dynamic` (physics props,
  breakables), `_Lighting` (local lights, reflection captures, local post-process volumes), plus map-wide
  `*_GlobalLighting`, `*_<Scenario>_LightingScenario` / `Horde_Lighting_Main` (time of day), `*_Global_Fluid`
  (water / acid pool volumes `BP_FluidVolume_*`), `*_Terrain` (landscape), `*_Vegetation`.
- DI2's cooker merges every static component of a level into StaticWorldActor `Cooked_StaticDataActor`; the
  `Cooked_StaticDataActorHidden` twin (bHidden) holds whitebox blockers (collision only). Their RelativeLocation is
  world space unless the component has an AttachParent.
- `<Level>_<n>_HLOD_Root*` meshes are hierarchical-LOD proxies (far-distance stand-ins); the test map skips them.
- No ISM / HISM instances in the tiles surveyed (Metro, Hotel, Pier, Horde NH_01 / NH_04 / Shelter).
- References in the JSON dumps (`ObjectPath ".../Map.N"`) are 0-based export indices of that package.
- `BP_BasicTimeOfDay` (DSCore/Lighting) is every level's time of day: sun (DirectionalLightComponent, Intensity in
  lux), HDRI sky (`SkyTexture`, `Sky Brightness`), height fog, and a PostProcessComponent whose class template holds
  DI2's base post-process (exposure, bloom, AO, SSR, fuel colours, see below).
- `r.DefaultFeature.AutoExposure.ExtendDefaultLuminanceRange=True` (DefaultEngine.ini): post-process auto exposure
  values are EV100.

## Level settings: fluids (for recon/RE_FLUIDS.md §6)

Searched: the name tables of all 2,033 `.umap` packages (`tools/test_map/mapx scan`, extracted/test_map/fluid_scan*.txt)
and every Blueprint / data asset / material package under DI2, DIShared and DSCore whose path matches the gameplay /
core folders, for `FluidParamsUpdateActor`, `Default__FluidParamsUpdateActor`, the twelve colour properties and the
fluid-param property names.

- **No level places an `AFluidParamsUpdateActor`** (0 of 2,033 maps reference the class; no Blueprint / data asset in
  the scanned folders references it either). DI2 therefore renders fluids with the class's native defaults (ctor 0x1436ff060, RE_FLUIDS.md §6: DetailSize 55,
  AbsorbencyRampEnd 1.0, AbsorbencyRampStart 0.6, MaxFluidOnWalls 0.9, FluidDensity 10, NormalStrength 0.05,
  NormalFlatnessWalls 0.96, NormalFlatnessFloors 0.993, FluidRoughness 0.08), unless the game spawns one at runtime
  from native code (not traced).
- **No level PostProcessVolume overrides any fluid colour** (0 maps carry the property names).
- **FPostProcessSettings defaults** (DI2's additions), from the fully serialised `FPostProcessSettings` default of
  `/Game/DIShared/Effects/Blueprints/BPC_PostProcess_Reticle` (`InitialPPMaterials`: all 522 fields incl. every
  `bOverride_*` = false and stock UE 4.27 values such as FilmSlope 0.88, VignetteIntensity 0.4, AutoExposure -10..20,
  i.e. the struct's constructor values). Linear RGBA:

  | Property | R | G | B | A |
  |---|---|---|---|---|
  | BloodColor / TintedBloodColor | 0.88 | 0.195553 | 0.146666 | 0.02 |
  | WaterColor / TintedWaterColor | 0.95 | 0.95 | 0.95 | 0.0 |
  | FuelColor / TintedFuelColor | 0.733507 | 0.338542 | 0.8125 | 0.0 |
  | FuelEdgeColor / TintedFuelEdgeColor | 0.947917 | 0.69714 | 0.16786 | 0.0 |
  | AcidColor / TintedAcidColor | 0.890017 | 1.0 | 0.057292 | 0.05 |
  | AcidEdgeColor / TintedAcidEdgeColor | 0.782943 | 1.0 | 0.140625 | 1.0 |

  Not yet cross-checked against the exe's FPostProcessSettings constructor (offsets +1676..+1852, RE_FLUIDS.md §6).
- **Every level overrides the fuel colours**: `BP_BasicTimeOfDay`'s PostProcessComponent class template
  (`NODE_AddPostProcessComponent-3`, unbound, priority 0; the actor is in every lighting scenario, 32 maps) sets
  `bOverride_` + FuelColor = FuelEdgeColor = TintedFuelColor = TintedFuelEdgeColor = (0.642579, 0.574219, 0.65625, 0.0).
  Blood, water and acid stay at the defaults above. (Level PostProcessVolumes with higher priority don't touch them.)

## Why Horde NH_04 (map `nh04_street`)

Surveyed (tools/test_map/survey_*.py, find_open.py, occupancy.py, and the builder's triangle search):
- `Maps/TestMaps`: only Blank_TestMap and a cutscene test map ship as umaps (the other test maps' data assets ship
  without their levels). Blank_TestMap is an empty grid.
- Loading-screen dioramas (`Diorama01..15_P_Main`): a mannequin and two meshes each; no floor to fight on.
- Horde `NH_Shelter`: the yard is landscape (heightfield + layered landscape material, not ported), the house interior
  is small rooms.
- Pier (SunClouds sun at 4.7 deg) and Metro (Day sun at 10 deg, mostly underground): low or no sun, poor captures.
- Halperin Hotel tiles: big open areas found were rooftops / building blocks; the lobby submap holds 3 components.
- **Horde NH_04** (chosen): a Bel-Air street block built for horde fights (asphalt road meshes `SM_LSC_NH_04_RoadA_*`,
  sidewalks / kerbs, mansion walls, cars, street props), static meshes only around the road (no landscape in the
  play space), lit by `Horde_Lighting_Main` (BP_BasicTimeOfDay: sun 90,000 lux at 45 deg elevation, 5780 K,
  T_VeniceBeach_HDR sky at Sky Brightness 60,000, PostProcessVolume_Global AutoExposureMaxBrightness 13 EV100).

Spawn origin: for each seed in MAPS["nh04_street"]["seeds"] (the centres of NH_04's road meshes), the builder samples
every triangle within 37 m (12 cm spacing), takes the highest near-horizontal surface per 25 cm cell, marks cells with
anything 15..220 cm above it, and looks per 40 cm floor-height bucket for the largest clear rectangle that (a) has
loaded floor all around it (8 m margin, else 5 / 3 m: the tests' cameras must not look past the edge of the loaded
geometry, where Godot shows the black lower sky) and (b) fits the tests: 16 x 9, 14 x 8, 12 x 9, 12 x 7.5 (the flesh
suite's own footprint: X +-3.6 m, Z -5.5 .. +6 m), 16 x 6.5, 12 x 6 m, in that order. Result: a 17 x 6 m clear stretch
of the T04 road by the horde arena's concert stage, at UE (-311, -70472, 809.5), long side along UE X, map turned
90 deg so it runs along Godot Z; geometry kept within +-25 m (`extracted/test_map/nh04_street/spawn_area.png`).
Trade-off: no seed has a 16 x 9 m clear area with an 8 m floor margin (DI2's street is cluttered with cars, barriers,
stage gear); the 6 m width leaves the flesh suite's explosion camera at X -3.0 m inside a black speaker stack
(explosion_pipebomb_late.png).

## NH_04 inventory (whole map, 2026-10-09)

What DI2 streams for Horde NH_04: `Horde_Persistent_Main` lists the levels (`tools/test_map/streaming.py`). Always
loaded: `NH_04_Main`, `NH_04_Performance`, `Horde_Lighting_Main`, `Horde_Navigation`, `Horde_Audio`. Streamed in
(LevelStreamingDynamic, bShouldBeLoaded / bShouldBeVisible true, identity LevelTransform): `NH_04_T01..T07_Fixed /
_Dynamic / _Lighting`, `NH_04_T02_Effects`, `NH_04_Terrain`, `NH_04_Vegetation`, `NH_04_Vista`, `NH_04_Spawning`,
`Hazards/NH_04_Hazards01`, `PerformanceMaps/Horde_NH04_Performance_Probes`. The ~160 scenario sublevels under
NH_04/{Boss, Conquest, Defence, Fetch, Interact, Loot, Lull, Muster, Vote} are LevelStreamingDynamic with no flags
(loaded per horde event; not part of the base playground). T06's three levels and T05_Lighting are empty.

Counts per level (`python tools/test_map/inventory.py --md <packages>`; export types in the CUE4Parse dumps):
smc = StaticMeshComponent with its own StaticMesh; smc_tmpl = mesh from the Blueprint class template (doors, vehicle
glass, lamp fixtures, hazard props, spawn-point editor meshes); hlod = HLOD proxies (skipped); spline = SplineMeshComponent;
foliage = FoliageInstancedStaticMeshComponent (+ instances); physics = mesh components with BodyInstance.bSimulatePhysics;
land / land_col / grass = LandscapeComponent / LandscapeHeightfieldCollisionComponent / GrassMeshComponent; light =
point / spot / rect / directional / sky light components; refl = reflection captures; volume = other brush volumes;
bp = Blueprint actors. No ISM / HISM component and no BlockingVolume in any NH_04 level (whitebox blockers are hidden
SMCs in `Cooked_StaticDataActorHidden`). Extents = world X / Y of the placed mesh components.

| Level | smc | smc_tmpl | hlod | spline | foliage | foliage_inst | physics | land | land_col | grass | decal | light | refl | volume | particles | skel | bp | extent (UE, m) | top Blueprint classes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| NH_04_Main | 317 |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | 1 | X -90..138 Y -742..-563 | BP_Horde_TutorialTrigger_Torch 1 |
| NH_04_T01_Fixed | 2449 | 62 | 48 | 2 |  |  |  |  |  |  | 652 | 55 |  |  | 3 | 3 | 63 | X 44..116 Y -643..-568 | BP_VEH_Glass_Base 33, BP_Door_Static 10, BP_IconMetadata_WorldMap_Discovered 10 |
| NH_04_T01_Dynamic | 727 | 20 |  | 27 |  |  | 697 |  |  |  | 16 |  |  |  | 10 | 3 | 775 | X 32..112 Y -638..-571 | BP_DPR_BoxCardboardA_03 15, BP_DPR_CigaretteBoxA_01 14, BP_BreakableGlassPane_Generic 13 |
| NH_04_T01_Lighting | 21 | 101 |  |  |  |  |  |  |  |  |  | 218 | 3 | 3 |  |  | 84 | X 50..98 Y -636..-573 | BP_FixedLight_CeilingLightSpotD_Med_01 20, BP_FixedLight_WallLightChandelierClassicB_Shade_01 14, BP_FixedLight_WallLightHotelClassicA_01 9 |
| NH_04_T02_Fixed | 2462 | 169 | 74 |  |  |  |  |  |  |  | 560 | 161 |  |  | 1 | 2 | 163 | X -37..78 Y -654..-552 | BP_VEH_Glass_Base 79, BP_IconMetadata_WorldMap_Discovered 32, BP_TextDecal 11 |
| NH_04_T02_Dynamic | 390 | 2 |  |  |  |  | 365 |  |  |  |  |  |  |  | 3 |  | 398 | X -28..52 Y -650..-572 | BP_DPR_ArchiveCardboardBoxA_01 22, BP_DPR_BoxFileA_01 19, BP_BreakableGlassPane_Generic 16 |
| NH_04_T02_Lighting | 9 | 95 |  |  |  |  |  |  |  |  |  | 210 | 5 |  |  |  | 72 | X 35..42 Y -635..-615 | BP_FixedLight_WallLightHotelClassicA_01 12, BP_FixedLight_CeilingLightSpotC_01 10, BP_FixedLight_WallLightChandelierClassicB_Shade_01 8 |
| NH_04_T03_Fixed | 2566 | 218 | 67 | 8 |  |  | 1 |  |  |  | 1433 | 188 |  |  | 1 |  | 205 | X 34..169 Y -736..-619 | BP_VEH_Glass_Base 107, BP_IconMetadata_WorldMap_Discovered 32, BP_Door_Static 11 |
| NH_04_T03_Dynamic | 454 | 16 |  |  |  |  | 444 |  |  |  |  |  |  |  | 22 | 4 | 491 | X 32..135 Y -709..-657 | BP_BreakableGlassPane_Generic 26, BP_DPR_BoxCardboardA_02 8, BP_DPR_BoxCardboardA_04 7 |
| NH_04_T03_Lighting | 335 | 35 |  | 11 |  |  |  |  |  |  |  | 75 | 4 |  |  |  | 33 | X 87..116 Y -674..-656 | BP_FixedLight_MiscLightFairyLights_01 7, BP_LHT_WallLampSetA_06 6, BP_FixedLight_CeilingLightBattenA_5ft_01 4 |
| NH_04_T04_Fixed | 2206 | 81 | 58 |  |  |  | 2 |  |  |  | 736 | 72 |  |  | 7 |  | 131 | X -37..75 Y -773..-619 | BP_TextDecal 48, BP_VEH_Glass_Base 32, BP_IconMetadata_WorldMap_Discovered 12 |
| NH_04_T04_Dynamic | 546 | 15 |  |  |  |  | 535 |  |  |  | 2 |  |  |  | 1 | 6 | 582 | X -24..36 Y -731..-671 | BP_DPR_PartyItemsA_Cup_02 50, BP_DPR_PackagedWaterA_01 27, BP_BreakableGlassPane_Generic 25 |
| NH_04_T04_Lighting | 2 | 15 |  |  |  |  |  |  |  |  |  | 32 |  |  |  |  | 18 | X 31..36 Y -698..-692 | BP_FixedLight_CeilingLightSpotC_01 8, BP_TechArtOnly_SpotLight_01 3, BP_FixedLight_CeilingLightGenericSquareA_01 2 |
| NH_04_T05_Fixed | 631 | 14 | 38 |  |  |  |  |  |  |  | 125 | 11 |  |  | 1 |  | 17 | X -30..167 Y -673..-633 | BP_VEH_Glass_Base 10, BP_IconMetadata_WorldMap_Discovered 2, BP_Horde_CarBatterySlot 1 |
| NH_04_T05_Dynamic | 4 | 1 |  |  |  |  | 4 |  |  |  |  |  |  |  |  | 1 | 5 | X 68..70 Y -645..-644 | BP_DPR_CanoePaddleA_01 2, BP_DPR_DinghyPlasticA_01_Paddle 2, BP_DPR_InflatableUnicornA_01 1 |
| NH_04_T07_Fixed | 1941 | 1 | 18 |  |  |  |  |  |  |  | 359 |  |  |  |  |  | 4 | X -4..49 Y -726..-666 | BP_TextDecal 3, BP_HordeObjectiveActor_WaterPump 1 |
| NH_04_T07_Dynamic | 35 | 3 |  |  |  |  | 35 |  |  |  |  |  |  |  | 18 | 1 | 36 | X -3..38 Y -720..-667 | BP_DPR_AlcholeBottleA_01 5, BP_DPR_Bucket_01 4, BP_DPR_AlcoholBottleC_01 3 |
| NH_04_T07_Lighting |  | 113 |  |  |  |  |  |  |  |  |  | 115 | 1 | 3 | 3 |  | 41 |  | BP_FixedLight_WallLightIndustrialCageC_01 25, BP_BasicVolFogVolume 5, BP_FixedLight_MiscLightGlowstick_A 4 |
| NH_04_T02_Effects |  |  |  |  |  |  |  |  |  |  |  |  |  |  | 57 |  |  |  |  |
| NH_04_Terrain |  |  |  |  |  |  |  | 86 | 85 | 34 |  |  |  |  |  |  |  |  |  |
| NH_04_Vegetation | 1 |  |  |  | 138 | 9727 |  |  |  |  |  |  |  |  |  |  |  | X 47..47 Y -591..-591 |  |
| NH_04_Vista | 573 |  |  |  |  |  |  |  |  |  |  |  |  |  | 3 |  |  | X -234..445 Y -949..-399 |  |
| NH_04_Spawning | 12 | 1094 |  |  |  |  |  |  |  |  | 31 |  |  |  |  |  | 1301 | X -3..110 Y -712..-611 | BP_ZombieSpawnPoint 964, BP_Horde_TSL_ZombieCluster 152, BP_Activity_Feasting 38 |
| NH_04_Performance |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  | 29 |  | BP_GameArea_Triggerable 29 |
| NH_04_Hazards01 | 60 | 632 |  | 134 |  |  | 4 |  |  |  | 165 |  |  |  |  | 34 | 3191 | X -20..130 Y -732..-571 | BP_ModularEffect_RunCustomEvent 584, BP_ModularCondition_EvaluateExpression 255, BP_ModularEffect_DestroyActor 252 |
| Horde_Lighting_Main |  | 2 |  |  |  |  |  |  |  |  |  | 2 | 133 | 5 | 5 |  | 1 |  | BP_BasicTimeOfDay 1 |
| Horde_Navigation |  |  |  |  |  |  |  |  |  |  |  |  |  | 167 |  |  | 293 |  | BP_TraversalNavLink 293 |
| **total** | 15741 | 2689 | 303 | 182 | 138 | 9727 | 2087 | 86 | 85 | 34 | 4079 | 1139 | 146 | 178 | 135 | 54 | 7934 | | |

2,684 unique static meshes (no HLOD) over the tiles, Main, Vegetation, Vista and Hazards. Play space about X -37..169,
Y -773..-552 m (206 x 221 m); the Vista ring of backdrop meshes reaches X -234..445, Y -949..-399 m; the three
landscape actors (`NH04_Landscape_Canals`, `NH4_Landscape_T1_2`, ...; 63-quad components, heightmap and weightmap
textures cooked into NH_04_Terrain) cover X -84..294, Y -762..-497 m.

**Plan (order of work, one commit per step):**
1. This inventory.
2. Static art: every `_Fixed` tile + `_Lighting` fixture meshes + Main + Vista, Blueprint-template meshes resolved
   through the component's Template (archetype) chain, HLOD skipped; collision as today; instance groups split into
   spatial cells so Godot frustum-culls them; map `nh04` = the whole level with the same origin / yaw as
   `nh04_street` (UE (-311, -70472, 809.5), yaw 90), so every test position is on the same floor. Bot waypoint loop +
   per-area fixed-camera captures (a new autotest under my files or a proposal).
3. Landscape: heightfield from the cooked heightmaps (+ HeightfieldShape3D collision), DI2's landscape material
   (weightmap layers) as a new `di2_landscape.gdshader`.
4. Foliage: the 138 FISM components (9,727 instances) as MultiMesh, with their masters' masked / two-sided settings.
5. `_Dynamic` + Hazards01: physics props (RigidBody3D where bSimulatePhysics), breakable glass / DSDestructible
   stand-ins (UNVERIFIED).
6. DecalComponents (4,079) with their decal materials, if time remains.
Out of scope here: local lights / reflection captures (milestone 7), Spawning (milestone 5), particles in
T02_Effects (milestone 9), scenario sublevels.

## Whole map (`--map=nh04`, 2026-10-09)

Build: `tools/with_cpu.sh <you> python -u tools/build_test_map.py nh04` (needs `tools/test_map/landscape_prep.py nh04`
once for the terrain maps; Blueprint templates: `tools/test_map/dump_templates.py <levels>`). Test (own scene, no
main.gd hook): `RUN_TEST_LIMIT=1200 RUN_TEST_ENGINE_ARGS="res://scenes/map_walk_test.tscn" tools/with_cpu.sh <you>
tools/with_lock.sh <you> tools/run_test.sh --mapwalktest=game/test_out/<you> [--map=nh04] [--no-walk] [--no-shots]`
(game/scripts/autotest_map_walk.gd: load stats, two perf probes, a high and a street-level fixed camera per level
package, then the bot walk). `main.gd --map=nh04` needs no change (it loads any built map); `nh04_street` is untouched.

- **Levels:** NH_04_Main, NH_04_Vista, T01..T05 + T07 `_Fixed`, the `_Lighting` tiles' fixture meshes, NH_04_Vegetation,
  NH_04_Terrain (T06 is empty). Same origin / yaw as nh04_street (UE (-311, -70472, 809.5), yaw 90), so the tests'
  fixed positions stand on the same street floor; the fluid map keeps the street's 51.2 m square and height range.
- **Blueprint actors** (vehicles, doors, lamp fixtures, glass): their components store only what differs from the
  archetype, so the mesh / transform often come from the component's `Template` (the class's `<Name>_GEN_VARIABLE`
  template, its own Template the parent class's, ...). `level.merged_props` walks that chain (StaticMesh,
  OverrideMaterials, relative transform, visibility, BodyInstance; never package-local references such as
  AttachParent); MIDs inside a Blueprint resolve to their Parent. 467 Blueprint packages, all resolved.
- **Culling:** instance groups and the concave collision are split into 32 m cells (a port parameter) so Godot culls
  them per MultiMesh / body. DI2 itself swaps clusters for HLOD proxies (`LODActor`: `LODDrawDistance`, e.g.
  6,205 cm; 2,665 T03 components carry `LODParentPrimitive`): not ported yet (UNVERIFIED #111).
- **Collision:** as nh04_street; hulls Jolt cannot build are cleaned (UNVERIFIED #108).
- **Build report** (`game/assets/di2/maps/nh04/build_report.json`): every mesh / material / texture the build could not
  draw, with the reason. NH_04: 0 meshes without JSON / glb, 0 unresolved materials, 0 missing textures; 181
  materials skipped on purpose (mesh decals M_Decal_* / M_DecalPOM_* and cobwebs: SKIP_MASTERS).

## Landscape (NH_04_Terrain)

Three `Landscape` actors (NH04_Landscape_Canals scale 50 x 50 x 100, NH4_Landscape_T1_2 / T3_4 50 x 50 x 50), 86
components of 63 quads (64 x 64 vertices, 50 cm apart). `tools/test_map/landscape.py`: heights from the cooked
B8G8R8A8 heightmaps (R * 256 + G, (h - 32768) / 128 local units), layer weights from the weightmaps by
`WeightmapLayerAllocations` (channel per LayerInfo; LayerInfo assets' `LayerName` Layer1..5; `DataLayer` = holes),
one mesh per component in Godot space, weights in COLOR (layers 1..4) + UV2.x (layer 5), the UE world XY (cm) in UV,
and the same triangles as collision. mapx names textures cooked into a level `<Outer>.<Name>` (the three landscapes
reuse export names).

Material: both MIs (MI_LSC_NH04_01 / _02) are M_LandscapeLite with five layers (per layer Diffuse Colour Map, Normal
Map, Packed MRO Map, Heightmap `_AHA`, Diffuse Colour Tint, Height Blend Influence, Roughness Adjustment, ...;
"Texture Tiling (in cm)" 400 / 100). The blend is transcribed from DI2's own pixel shader for a five-layer component
(`mapx matkeys` -> LMIC key E6C4D48E..., `material_map.py` -> PS 26989, `decompile.py`; slot names from the
preshaders via `mapx matres` + `annotate.py`: cb3[27].x tiling, [27].yzw / [28].xy Height Blend Influence 1..5,
[30] / [31].x Roughness Adjustment, tints at cb3[7..15], weightmap channels via LayerMask_Layer1..5):
uv = world XY / tiling; h' = sat((AHA.g - 0.5) * influence + 0.5); b = clamp(2w + h' - 1, 1e-4, 1), normalised;
albedo = sat(sum b * diffuse * tint); roughness = sum b * sat(MRO.g + adjustment); metallic 0; specular 0.5; layer
normals blended and reoriented onto the terrain normal. `game/shaders/di2_landscape.gdshader`. Open: UNVERIFIED #109,
#110.

## What the port reproduces, and what it approximates

Exact (from DI2 data):
- Placement: component transforms (attach chains), hidden / collision flags, LOD0 meshes, material slots and
  per-component material overrides; DI2's cooked BC textures (mips above 512 px dropped for memory).
- Material inputs: each MI chain resolved to the master (leaf-first overrides, else the master's shader-map default):
  "Diffuse Colour Map", "Normal Map", "Packed MRO Map", blend mode, two-sidedness, opacity clip.
- Collision: each mesh's BodySetup simple shapes (boxes, convex hulls, spheres, capsules) in world space;
  CTF_UseComplexAsSimple or meshes without simple shapes use their LOD0 triangles. All on Util.WORLD.
- Sun direction / intensity, sky HDRI, exposure clamp: the level's BP_BasicTimeOfDay and post-process volumes.

Approximate / not ported (open):
- Master material features beyond the base maps: detail maps, the second vertex-blended layer (M_Opaque "2 - ..."),
  tints, emissive, POM, M_Interior_Horde's fake-interior cubemap, glass (drawn as a plain translucent surface).
- Mesh decals (M_Decal_*, M_DecalPOM_*) and cobweb cards are left out (the "Packed ARA" decoding isn't done);
  DecalComponents (dirt / grime; 1,433 in NH_04_T03_Fixed alone) are not placed yet.
- Vehicle MaterialInstanceDynamics cooked into the level use their parent material (the MID's own parameter values
  aren't applied).
- Lighting: DI2's exposure, tone mapping, sun colour / cascades and height fog are ported (next section). Not
  reproduced: baked lightmaps (incl. the Static sky light's light and occlusion), reflection captures, local lights,
  volumetric fog, bloom. Godot's sky ambient stands in for the lightmaps, so shadowed areas are darker than DI2's.
- Landscape (NH_04_Terrain), vegetation, `_Dynamic` tiles (physics props, breakables) are not loaded.

## Exposure and tone mapping (DI2's chain, 2026-10-08)

Static RE only (exe + DI2's global shader archive; tools: `tools/re_exposure/*`, decompiles in
`extracted/shaders/lighting/Global_<lib>_<label>.*` via `tools/re_lighting/ldis.py`). Port: `tools/test_map/post.py`
(builder side), `game/scripts/di2_post.gd` (a Godot CompositorEffect after transparents), `game/shaders/di2_post_*.glsl`.

**Settings.** The effective FPostProcessSettings = the struct defaults (BPC_PostProcess_Reticle InitialPPMaterials) +
the unbound volumes by priority where bOverride_* is set (an override equal to the archetype default is not serialised,
so the default stands): BP_BasicTimeOfDay's PostProcessComponent template (priority 0: Histogram method, Low/High 10 /
90 %, Min 1.4 EV, Speed 7 / 7, HistogramLog -10..20, Bias curve Curve_ExposureComp, Derived* clamp 1 / scale 3 / pow
1, vignette 0.6 default, bloom 0.35, film params) then PostProcessVolume_Global (priority 1: Max 13 EV, WhiteTemp 9500,
ColorGamma (1, 0.979, 0.877), T_VeniceDay_LUT, DS_FilmMaxToe 0.45). Bound volumes (T01 mansions: disabled; T07 sewer
grading) are away from the test area and not applied.

**Exe facts** (CVar registrations, `tools/re_exposure/disasm.py`): r.EyeAdaptation.LensAttenuation 0.65 (help text:
"0.65 to match previous versions (1.0cd/m^2 becomes 1.2 at EV100)" -> EV100 luminance = 1.2 * 2^EV), ExponentialTransition
Distance 1.5, BlackHistogramBucketInfluence 0, r.HDR.Display.OutputDevice 0 ("0: sRGB (LDR)"), Editor.HDRNITLevel 160
(read by the LUT and tonemap parameter code).

**View uniform buffer** (member registration functions: `movsxd; lea Name; ... mov [rsp+30h], Offset`;
`tools/re_exposure/ub_members.py`): cb0[134].y PreExposure (0x864), cb0[152] **CurrentEyeAdaption** (0x980, a DI2
member), cb0[225].y DesaturationAmount (Fury), cb0[239].x OverallLUTGradingIntensity (DI2). Shader cbuffer offsets of
global shaders: the frozen FShaderParameterBindings (`tools/re_exposure/bindings.py`: {u16 BufferIndex, BaseIndex,
ByteOffset, ByteSize}, the first DI2 compact array of FShader).

**Eye adaptation** (FEyeAdaptationPS, Global 1553, DI2-modified; FHistogramCS Global 2481 stock): histogram of
mean(rgb) / PreExposure in 64 log2 bins over HistogramLogMin..Max + log2 1.2; Lhist = exp2(mean bin position between
Low and High percent of the weight); grey = 0.18 + 0.8 (1 - DesaturationAmount) (albedoMean - 0.18) (albedoMean: a
DI2 3-byte scene-colour texture, t8); L = Lhist / grey; derived = (volumetric-lightmap SH ambient at the camera, else L)
* DerivedMaxBrightnessScale; target = min(max(Min, L), ClampInfluence > 0.5 ? clamp(derived, Min, Max) : Max) with Min /
Max = MinAverageLuminance / 0.18, MaxAverageLuminance / 0.18; log2-space smoothing (linear at Speed beyond the transition
distance, else exponential * ExponentialUp/DownM); exposure = 2^Bias * 2^curve(log2(Lavg / 1.2)) / smoothed. Output
texels: 0 = HDR-display controls, 1 = albedo, 2 = VLM irradiance, 3 = SDR controls. Measured on the street: Lhist
6116 cd/m2 -> target EV100 12.32, exposure 1.35e-5 (curve -1.125 EV).

**LUT** (FLUTBlenderPS p1, Global 2460, DI2-modified): input coordinates are ST-2084 (PQ) of AP1 * EditorNITLevel;
white balance (Bradford, WhiteTemp / WhiteTint), the level's grading LUT applied *in PQ space* weighted by
OverallLUTGradingIntensity, UE colour correction (shadows / midtones / highlights), DI2's hard-coded blue correction;
then per OutputDevice: **0 (sRGB) runs ACES RRT + ODT (48-nit cinema range, D60 -> D65) on the graded colour, then
UserGamma, sRGB OETF and BlackPoint..WhitePoint**; the UE film curve (FilmSlope / Toe / Shoulder / Clip, with DI2's toe
lerped by CurrentEyeAdaption.w between MinToeParameters / FilmToe / MaxToeParameters, i.e. DS_FilmMin/MaxToe*) only
feeds the other devices. The port runs DI2's shader itself: `tools/re_exposure/hlsl2glsl.py` translates the 3Dmigoto
HLSL to GLSL at build time (written to the git-ignored map folder as post_lut.glsl), dispatched once over 32^3 with the
constants from `post.lut_cb0`.

**Tonemap** (FTonemapPS p9533 Global 2527 + FTonemapVS Global 2585): scene * OneOverPreExposure * ColorScale0 (+
bloom * (ColorScale1 + dirt * tint), DI2 bloom scale from CurrentEyeAdaption), mesopic / Purkinje desaturation
(DI2: MesopicParameters, PurkinjeShiftColor), * DefaultEyeExposure (VS), vignette 1 / (1 + |0.6 v|^2)^2, grain, AP1 ->
PQ(* EditorNITLevel / 10000) -> LUT * 1.05. Ported: exposure, vignette, LUT. Not ported: bloom, mesopic (identity for
daylight luminances), chromatic aberration (SceneFringeIntensity 0.3), sharpen, grain (intensity 0).

**Lights.** Pre-exposure P = 0.18 / (1.2 * 2^13) = 1.83e-5 (DI2's exposure at the Max clamp, no compensation): sun
energy = 90,000 lux * P / pi, sky energy = Sky Brightness 60,000 * P; the compositor divides P out. Sun colour =
FLinearColor::MakeFromColorTemperature(5780 K) (bUseTemperature; the same constants are in DI2's LUT shader). Sun
cascades from the template (Stationary; DynamicShadowDistanceStationaryLight 225 m, 4 cascades, exponent 3 default ->
splits 0.025 / 0.1 / 0.325, fade-out 0.2, transition 0.3). Sky light: the level uses NODE_AddSkyLightComponent-2, a
**Static** sky light (lightmap-only; the Movable ones have MinOcclusion 1): DI2's sky lighting and its occlusion are
baked, so they arrive with the lightmaps (open).

**Height fog** (BP_BasicTimeOfDay.SetupFogComponent, json_bp): FogDensity 0.02 (class default), falloff 0.2, second
fog 0.003 / 0.8 / -15 m, fog height = the actor (UE z 525 = 2.84 m below the test floor), cubemap TC_VeniceBeach_Cube_HDR
* tint 60,000, volumetric fog on (scattering 0.7, 60 m). Ported: the two-layer line integral and the non-directional
inscattering (`di2_post_fog.glsl`) on opaque pixels.

**Particles.** DI2 particle emissive with exposure compensation = lerp(Bright, Dark, sat((X - 5e-5) / (0.005 - 5e-5)))
/ X * PreExposure, X = CurrentEyeAdaption.y. DI2Map feeds DI2ParticleMaterials.scene_exposure (the blend: 0 in daylight)
and emissive_exposure_scale = P / X. Raw HDR emissives without compensation (DI2's base pass multiplies them by
PreExposure) need a PreExposure multiply inside the particle shaders: reported to the coordinator.

## Verification (flesh suite)

`TEST_OUT=game/test_out/test_map TEST_EXTRA_ARGS=--map=nh04_street tools/run_all_tests.sh flesh`
(`run_all_tests.sh` passes TEST_EXTRA_ARGS to every suite; TEST_OUT keeps the results apart from the default runs).

2026-10-08, first passing map build (an earlier 18 x 6.75 m spawn by the T03 road; numbers for the final T04 spawn
are below it): exit 0, 0 SCRIPT / SHADER errors, every check ok
(fluid_check: the bat hit's droplets landed on the street at y 0; the fluid map covers them). perf_check, map vs the
procedural arena run back to back (game/test_out/test_map_arena):

| | map nh04_street | arena |
|---|---|---|
| idle (8 zombies) | 126.3 fps / 10.99 ms process / 1.80 ms physics | 140.9 fps / 14.46 ms / 1.33 ms |
| after hits | 57.5 fps / 47.25 ms / 1.73 ms | 57.9 fps / 46.74 ms / 1.68 ms |
| after hits, no hit particles / fluids | 57.4 fps / 29.91 ms | 58.9 fps / 29.46 ms |
| GoreBody.process (all 8) | 1.48 ms | 1.68 ms |

Map load (DI2Map.create): 1.2 s for 855 instances / 400 meshes / 399 materials / 5,096 collision shapes in 26 static
bodies (Jolt runs out of sub-shape ID bits with them all in one compound) / 172 MB of DDS.

Final build (T04 spawn, 17 x 6 m, 8 m floor margin), map then arena back to back on 2026-10-08:

| | map nh04_street | arena |
|---|---|---|
| idle (8 zombies) | 103.0 fps / 13.07 ms process / 1.48 ms physics | 144.3 fps / 14.39 ms / 1.07 ms |
| after hits | 48.2 fps / 51.23 ms / 1.72 ms | 71.5 fps / 35.99 ms / 1.39 ms |
| after hits, no hit particles / fluids | 53.4 fps / 32.80 ms | 77.4 fps / 30.26 ms |
| GoreBody.process (all 8) | 1.71 ms | 1.30 ms |

Map load 1.2 s: 1,922 instances in 493 MultiMesh groups, 434 meshes, 425 materials, 6,892 collision shapes in 35
bodies, 168 MB DDS. The fps cost is GPU-side (draw calls: groups x surfaces, plus the sun's shadow cascades); CPU
process time is the same idle and +2.5 ms after hits without particles / fluids. The larger after-hits gap with them
on comes with the hit particles and fluid droplets (more world shapes to trace against). Not optimised yet: static
batching per material / cell, or a smaller keep radius, would cut the draw count.

2026-10-09, DI2 exposure / tonemap / fog / DI2 cascades (game/test_out/exposure2; "before" = the 2026-10-08 final
build above, same machine, other sessions' jobs running in both):

| | before (AgX, fixed exposure, 60 m 3-split shadows) | after (DI2 post chain, 225 m 4-split shadows, fog) |
|---|---|---|
| idle (8 zombies) | 103.0 fps / 13.07 ms process | 92.9 fps / 9.42 ms process / 5.39 ms physics |
| after hits | 48.2 fps / 51.23 ms | 38.8 fps / 53.17 ms |
| after hits, no hit particles / fluids | 53.4 fps / 32.80 ms | 48.8 fps / 23.56 ms |

The post chain is 4 compute dispatches (fog, histogram, tonemap; LUT once); the idle drop is probably mostly the longer shadow
range (225 m vs 60 m) over the 1,922 static instances (not isolated; machine load differs between runs). Static batching is still the open perf lever.

