# DI2 Gore Lab

A personal test bed. It recreates Dead Island 2's gore system (internally "Splatter", marketed as FLESH) and its zombies, with the simulation written in Rust and a playable arena in Godot 4.7. You play Dani in first person with DI2's bat, machete and pistol.

**Personal testing only.** `game/assets/di2/` and `extracted/` hold content pulled from your own DI2 install. Don't share them or commit them. The `.gitignore` already excludes them. The Rust core and the tools are original code.

**Progress: about 46% of the goal** (a fully playable showcase build on Horde map NH_04 with the full UI, gameplay, gore, every zombie variant and the whole map rendered as in game). Milestone table under [Status](#status).

## Run

| | |
|---|---|
| `play.bat` | Arena: Dani vs. 5 Walkers |
| `edit.bat` | Godot editor |
| `test.bat` | Scripted test in an unfocusable, off-screen window. Writes screenshots and a log to `game/test_out` |
| `python tools/build_body_proxies.py` | DI2 BodyProxy_ZombieStandard nodes + DamageEffectsPropagation config -> `game/data/body_proxies.json` (recon/RE_PROPAGATION.md) |
| `python tools/build_accumulating.py` | DI2 accumulating effects (status build-up): recipient configs, weapon mod on-hit values and modifiers, level-scaling curve -> `game/data/accumulating_effects.json` (recon/RE_ACCUMULATING.md) |
| `python tools/build_explosions.py` | DI2 explosion archetypes, curves and balancing -> `game/data/explosions.json` (recon/RE_EXPLOSIONS.md) |
| `tools/re_explosion/decomp.sh <name> <addr...>` | Headless Ghidra decompile (extracted/ghidra project) for the explosion RE |
| `tools/run_all_tests.sh [flesh autotest combat weapon]` | Every autotest in the background (off-screen, CPU-throttled); logs in `game/test_out/logs/` |
| `tools/with_cpu.sh <who> <cmd>` | Shared CPU budget for heavy jobs: 2 at a time, below-normal priority |
| `cd rust && cargo test -p gore-core` | 16 unit tests of the gore and zombie rules |
| `cd rust && cargo build -p gore-godot` | Rebuilds the Godot extension after Rust changes |

### Controls
- **Moving:** WASD to move, Shift to sprint, Space to jump, mouse to look.
- **Fighting:** LMB attacks (hold it for a charged heavy attack; automatic guns fire while held). RMB blocks with melee weapons and aims down sights with guns. Block just before a hit lands for a perfect block, then LMB for the paired counter. F or middle mouse to kick (look down to kick low, at a knocked-down zombie's head to stomp), Alt or C to dodge, G to throw the weapon (E picks it up), Q throws the curveball (Tab cycles it), V starts Fury, H uses a medkit.
- **Weapons:** 1-8 select loadout slots, mouse wheel to switch. **F3 opens the catalogue of every DI2 weapon** (159 campaign archetypes): Up/Down/PgUp/PgDn to browse, Enter puts it in the current slot. R reloads, T repairs, M cycles the weapon mod (none, fire, acid, shock, bleed).
- **Testing:** K spawns a zombie, J changes which archetype K spawns (all 22 DI2 types with their DI2 stats; the Runner, Shambler and Thug families spawn on their own DI2 bodies, the rest on the Walker body). Z toggles slow motion, F2 shows limb health for the zombie under your crosshair, F1 hides the help.
- **Automated runs:** `--combattest=<dir>` drives Dani's whole kit; `--weapontest=<dir> [--only=<class_id>]` equips one weapon of every DI2 class and logs the DI2 clip each action played and whether it hit.

## What comes from DI2, and what is recreated

| Piece | Source |
|---|---|
| Walker, Runner (`RunnerMaleCas01`), Shambler (`ShamMaleCas01`) and Thug (`ThugA01`) meshes with skin, clothing, hair, muscle layer, skull and organ sections; Dani's 1P arms; bat, machete and pistol meshes | Your install, exported with CUE4Parse (`tools/di2x`) |
| Animations: Walker clips; for Runner, Shambler and Thug, 21 locomotion/attack/crawl clips of their own plus DI2's 292 shared `A_ZMB_Base_*` hit, stumble, knockdown, get-up and crawler-hit reactions (`game/assets/di2/<type>/clips.json`); 51 Dani 1P clips | Your install. Most are ACL 1.3 compressed, decoded by `tools/acl13dec`, then merged into the glb by `tools/merge_anims.py`, which also retargets them per bone the way UE does (so the Thug can play the shared hit, fall and crawl clips) |
| Health per limb, dismember and break chances, survival rules for all 22 archetypes | `BPC_MultiPartHealth_*` and `DT_ZombiePartBoneDefinition`, converted by `tools/convert_archetypes.py` |
| Zombie health, attack damage, attack spacing | `DA_AIAttributeValues_*` |
| Every campaign weapon (159): name, mesh and damaged/broken meshes, damage, force, durability, stamina, crits, limb / counter / thrown multipliers, anticipation and repetition timings, heavy charge time and curves, hit pause, camera shake, sweep reach, trail sockets, damage type | `DA_*WeaponArchetype_*`, `BP_Weapon_*` (with blueprint inheritance), weapon skeleton sockets; `tools/build_weapons.py` -> `game/data/weapons.json` |
| Guns: ammo, reload handler (standard / looping), fire modes, spread and recoil handlers, hitscan swept-sphere and pellet bursts, falloff, ADS | each gun's `RangedWeaponModulesComponent` with attribute-sourced values resolved, plus its `*_Weapon` gun animations |
| Every weapon class's first-person animations (3,142 clips) and how DI2 chooses them | `DA_HeldItemClassData_*` -> `AnimSetCollection` slots -> anim set groups and expressions (`tools/di2_animsets.py`, `tools/build_class_data.py` -> `game/data/classes/*.json`), facts from `DT_ExpressionAliases_*` (`game/data/expression_aliases.json`), character contexts `DA_Context_*` |
| Ragdoll and hit-impact physics | `PA_ZombieStandard` (bodies, masses, damping, joint limits, PhysicalAnimation "Reaction" profile), `tools/build_ragdoll.py` |
| Gore gradient, wound noise, blood drips, bruise and char textures | `MaterialFunctions/Splatter` |
| Walker, Runner, Shambler and Thug speeds | Measured from the root motion of each body's own clips by `merge_anims.py` and fed into `archetypes.json` (walk / chase / crawl: Walker 0.6 / 1.5 / 0.37, Runner 3.6 / 5.6 / 1.0, Shambler 0.4 / 1.34 / 0.37, Thug 0.6 / 1.15 / 0.37 m/s) |
| Zombie attack hit timing and length | The `AIDetectMeleeHits` window in each attack clip's `AM_*` montage, and the clip length |
| Damage logic, wound field, crawler and survival rules, zombie brain | Rewritten in Rust (`rust/gore-core`), based on that data |
| Wound shading (layered reveal, cuts, bruises, char, acid, scorch), cut masking | Rewritten (`game/shaders/flesh.gdshader`) |
| Values DI2 computes in native code (perfect-block window, weapon pitch thresholds, melee sweep shape and auto-aim scoring, stability force scale, ...) | **Stand-ins**, each listed in `recon/UNVERIFIED.md` until recovered |

### Adding a DI2 body
1. `tools/di2x.sh json 'DA_ModelVariantAsset_<Variant>\.uasset'`. Its `Model` names the merged `SK_*` mesh. Export that with `tools/di2x.sh mesh '/SK_<Variant>\.uasset'`.
2. Write `game/assets/di2/<type>/clips.json`, mapping Godot clip names to DI2 sequences (the Runner's is a good template). Export the sequences with `tools/di2x.sh rawanim '/(<seq>|<seq>...)\.uasset'`, then run `python tools/merge_anims.py <SK_*.glb> game/assets/di2/<type>/<type>.glb game/assets/di2/<type>/clips.json`.
3. `python tools/pack_materials.py game/assets/di2/<type>/<type>.glb`
4. Add the family to `BODIES` in `game/scripts/zombie.gd` and in `tools/convert_archetypes.py`, then run `python tools/convert_archetypes.py`.
5. `test.bat` (or add `--bodies-only` after `--autotest=<dir>` to run just the body check, part D). Part D's screenshots go to `<dir>/bodies/`.

## How the gore works
1. **Hitboxes.** Each zombie has one per bone. A weapon ray hits a bone, and `GoreBody.hit()` (Rust, `rust/gore-godot`) maps the impact into the skeleton's bind pose.
2. **Damage.** `gore-core` applies it to the body and to the part that owns the bone, as in DI2's MultiPartHealth. When a part runs out of health:
   - sharp weapons and bullets cut it off at the nearest cut bone;
   - blunt weapons break it (arms dangle);
   - a second blunt depletion, or a gun, bursts the head.
   The archetype's survival rule then decides whether the zombie dies. For example, a Walker that has lost a leg needs both arms.
3. **Wounds.** Each wound is a capsule in bind-pose space, projected along the impact direction. The flesh shader turns them into torn skin coloured by DI2's gore gradient, bruises with dents, char, acid melt and scorch. Deep wounds discard the skin so the muscle, skull and organ meshes underneath show through.
4. **Severing.** Every vertex stores how much of its skin weight sits under each cut bone. The body hides that region at the 50% weight line. A copy of the posed mesh shows only that region and flies off as a rigid body.

## Cut caps & gibs
- **Caps.** A severed part leaves no hole. `GoreBody.add_cut_caps()` builds a cap from the exact edge of the cut: the line where the skin and clothing stop drawing. It adds one cap to the stump and one, facing the other way, to the flying piece. The caps are skinned like the body, so they deform with the stump. They use the flesh shader (layer 8), so wounds, blood, char and later cuts apply to them.
  - The cap shows a cross-section: torn muscle (DI2's breakage flesh texture, coloured through the gore gradient), a fat band and the skin's raw edge around it, and a bone with marrow at the bone axis.
  - The code is in `rust/gore-godot/src/caps.rs`, called from `Zombie._sever` and `_burst_head`.
- **Where hits land.** `GoreBody.hit()` refines the hitbox impact against the posed mesh, skinned on the CPU as the GPU draws it. The damaged bone is the one under the impact, and the wound sits on that exact spot of the moving body.
- **Where cuts happen.** DI2 cuts a limb at the centre of its VisceraProxy box nearest the hit: about 15%, 46% or 80% along each limb bone, not only at joints. `tools/convert_cut_points.py` writes these positions to `game/data/cut_points.json`, and each mid-bone cut becomes a bind-pose plane per cut slot.
- **Gibs.** `Fx.gibs()` throws DI2's own meshes, which `tools/pack_gore.py` packs into `game/assets/di2/gore/` from the `di2x.sh mesh` exports:
  - the breakage shards SM_BreakageA-E;
  - the Walker's skull, brain and jaw pieces (a burst head throws them from where they sat);
  - its organs, each named after the VisceraProxy it belongs to (`viscera.json` holds the bone);
  - flat SM_BloodGibs splats on the floor.
- **Test.** The autotest's part B (`--severing-only` after `--autotest=<dir>`) frames the capped stump and capped piece of a leg cut, then an arm cut. It also hits a walking zombie on six body areas and cuts its forearm mid-bone.

## Reusing it in other games
`rust/gore-core` has no engine dependency. Feed it a skeleton (bone names and parents) and an archetype JSON. Call `Body::apply_hit` and `WoundField::add_hit`, render `WoundField::pack()` in your own shader, and read the `Outcome` list for severing, breaking and death. `rust/gore-godot` is one adapter for it. A Bevy or Unreal adapter would follow the same pattern.

## Known gaps
- Everything in `recon/UNVERIFIED.md`: the remaining stand-ins for values DI2 keeps in native code.
- Torso bisection isn't implemented. (DI2 has it disabled in the Walker's data anyway.)
- Only Walker, Runner, Shambler and Thug have their own bodies (one variant each). The specials (Screamer, Slobber, Butcher, Mutator, Whipper, Suicider, Reformer) still use the Walker body with their own stats; paired counters and grapples are played by the Walker only.
- Zombies steer straight at you, with no navmesh.

## Status
A test bed, about 46% of the current goal: a fully playable showcase build on Horde map NH_04 (Bel-Air) with the
full UI, gameplay, gore, every zombie variant and the whole map rendered as in game. Done so far: all 22 elemental and
hazard variants, the specials' abilities, the gameplay and UI audit, and the NH_04 map tiles, landscape and foliage.
Next: map performance (HLOD).

| Milestone | Weight | Done |
|---|---|---|
| UI: HUD and menus | 7 | 30% |
| Player gameplay: movement, melee and ranged, weapons and mods, throwables, skills, progression | 14 | 40% |
| Gore: FLESH splatter, dismemberment, viscera, damage model and statuses, blood fluids | 13 | 85% |
| Every zombie variant: look, animation, reactions, AI and abilities | 20 | 60% |
| Variants spread across the map (spawners, horde director) | 5 | 0% |
| The whole map from the game's assets: tiles, landscape, foliage, props, decals, collision | 13 | 50% |
| Rendering parity: sky, environment shaders, shadows, reflections, wet surfaces, lighting, post | 14 | 30% |
| Performance with crowds on the full map | 6 | 25% |
| Weapon and world VFX, audio | 6 | 55% |
| Showcase capture | 2 | 0% |
| **Overall** | 100 | **~46%** |

Want to help? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Fan project disclaimer
This is a non-commercial fan project for research and learning. It is not affiliated with, endorsed or sponsored by
Deep Silver, Dambuster Studios or PLAION; Dead Island 2 and all related names are their trademarks. You need your own legal copy of the game: this
repository contains no game files, no extracted assets and no decompiled code (game data is read from your install
into git-ignored folders). Comments may cite function addresses in the retail executable as research notes. If you
represent a rights holder and want something changed or removed, open an issue and it will be done promptly.


## Game files
You need your own copy of Dead Island 2. No game files are in this repository: everything from the game is extracted
locally from your install into git-ignored folders.

## Layout
- `rust/`: the Rust core (gore, fluids, damage, data readers), built by the scripts below.
- `game/`: the Godot 4.7 project (scenes, gameplay, UI); `play.bat` runs it, `edit.bat` opens the editor.
- `tools/`: extraction, conversion and check scripts; `test.bat` runs every test.
- `recon/`: research notes on how the original works.
- `CONTRIBUTING.md`: how to help. License: MIT (`LICENSE`).
