# 1:1 work list (approved by the user: "Yes do everything as 1 to 1 with DI2 as possible")

**Top priority: zombies must look, take damage and gore exactly like DI2 — full FLESH replication.**

Every item comes from the user's own DI2 install (static extraction only; the game is never launched).

| # | Item | Status |
|---|------|--------|
| 1 | All weapon archetypes (melee + ranged), their 1P animation classes and DI2 selection rules | done (159 weapons, 42 classes) |
| 2 | Physics asset: ragdoll + hit-impact physical reaction | done (PA_ZombieStandard) |
| 3 | Attack camera animations (`Player1P/Weapon/Camera/*`, triggered by `BP_TriggerCameraAnimation` notifies) | baked (`game/data/camera_anims.json`, 75 clips); runtime hook parked behind gore |
| G | **FLESH 1:1: zombie materials, splatter wounds (SplatterMesh/SplatterSet), viscera, spawnable parts, gibs, blood fluid/decals, hit effects** | in progress: DI2 HitEffectTrees pick every hit's effects (data/hit_effects.json, all 28 trees + causer sets); their SplatterMesh stamps / SplatterSets render on the body (flesh.gd, flesh.gdshader); native splatter logic decompiled (recon/RE_FLESH.md: progressive damage, blend mode, orientation, defaults) and implemented; bodies spawn with their CharacterInitialState wound set; verified by `--fleshtest` (tools/run_test.sh). Next: splatter/material shaders (flesh-shaders session), outfit variants + attachments, viscera / spawnable parts, particles + fluids (item 5) |
| 4 | Audio (Wwise events + media: weapon swings/impacts, gore, zombie vocals, guns, Dani) via vgmstream | todo |
| 5 | DI2 VFX: blood / impact / gore particle systems and their textures | todo |
| 6 | Throwable / curveball archetypes (17 `DA_ThrowingWeaponArchetype_*`) with their data and meshes | todo |
| 7 | A DI2 map to test in | todo |
| 8 | Special zombies on their own bodies (Screamer, Slobber, Butcher, Mutator, Whipper, Suicider, Reformer, Crusher) | todo |
| 9 | Native stand-ins in `recon/UNVERIFIED.md`, recovered by static RE of the exe | todo |
