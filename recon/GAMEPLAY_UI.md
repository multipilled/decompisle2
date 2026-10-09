# Gameplay + UI audit (queue N3, milestones 1 + 2)

> **Brief (from the coordinator "DI2 workstreams", a worker, 2026-10-09).** Task N3 (P1, milestones 1 + 2): a
> read-only audit of the player's gameplay mechanics and the UI against DI2's own data, turned into a ranked task list
> the coordinator can brief from. No game code changes. Read first: COORDINATION.md, recon/SPEC.md, recon/DANI.md and
> recon/WEAPON_VFX.md tops, recon/UNVERIFIED.md (player / HUD rows). Knowledge library first (index/di2.md, MAP.md;
> notes/tools/unreal4-cooked-data-extraction.md, notes/engines/unreal4-card-dealer-ai.md). Digest first (an LLM digest tool
> `digest` with paths), spot-check its claims. Deliverable (this file, committed as I go): 1. mechanics table (DI2
> mechanic | DI2 source | ours today file:line | gap | S/M/L); 2. UI table (each screen / widget | DI2 source | ours |
> gap | size); 3. ranked task list (P1 playable showcase on NH_04, P2, P3), each task with owned files, a scripted
> background done-check and effort, sized for one fresh 2-4 h session; 4. UI tech per screen (UMG vs Scaleform) and the
> port route. Owned: recon/GAMEPLAY_UI.md, tools/re_ui/*. Every claim cites a DI2 asset path or exe address; unknowns go
> in recon/UNVERIFIED.md (my section). Heavy jobs via `tools/with_cpu.sh di2-gp-audit`. Done when both tables and the
> ranked list are here with the P1 tasks fully specified. End: Knowledge library note + lint, short final message.

> **Hand-off (2026-10-09, di2-gp-audit). COMPLETE.** Done: §1 mechanics, §2 UI, §3 ranked tasks (P1 fully specified), §4 UI tech
> + port route, UNVERIFIED #101-#106. New dumps already on disk (no need to redo): `tools/re_ui/dump_ui.sh` exported
> DI2/UI, Horde/UI, BalancingData/{Player/Skills, Loot, Inventory, Player/Stamina, Player/Movement}, Core/OptionsSystem,
> Core/Player/Inventory, Horde/BalancingData/{Player, Loot} to `extracted/json/...`; `tools/re_ui/carve_gfx.py` carves
> GFx movies from `extracted/raw/.../SWF_*.uasset` (3 samples in `extracted/re_ui/gfx`); JPEXS opens them.
> **Decided (coordinator, 2026-10-09): base-game UI as ranked; Horde UI stays P3 (user may override).** Was: **Decision for the coordinator:** base-game UI flavour (Dani / Berserker skill deck, base pause + player menu) vs
> Horde mode's own UI (NH_04 is a Horde map; Horde has its own pause, workbench, lobby, class abilities, session HUD).
> This list assumes **base-game screens + base HUD** (they match Dani's Berserker data we already use); Horde-only
> screens are P3.

Paths below: `DI2/...` = `extracted/json/DeadIsland/Content/DI2/...` (JSON dumps of `/Game/DI2/...`). Our files are
`game/scripts/*.gd` unless noted.

## Key findings (read these first)
1. **Our movement numbers are invented.** `weapons.json "player"` (walk 3.2 m/s, sprint 5.6, dodge 2.4 m / 18 stamina,
   regen 22/s after 0.8 s, block 15 stamina/hit) is copied forward from the old hand-made file
   (`tools/build_weapons.py:468` `old.get("player", {})`). DI2 holds them in
   `DI2/BalancingData/Player/Movement/DA_PlayerMovementParamSets.json` (`ParamSets[]`: MaxMoveSpeed 400 / 450 / 600
   cm/s, Acceleration 1000, Deceleration 2000, DodgeDuration 0.4-0.45, DodgeDistance 150-180 cm, DesiredJumpHeight 100
   cm, JumpTimeToApex 0.4 s, ...) and `DI2/BalancingData/Player/Stamina/Curve_StaminaRecharge_Berserker.json`
   (0 -> 0.4 @5 -> 0.8 @15 -> 1.0 @25). The ParamSets array is indexed by a native enum (UNVERIFIED #101).
2. **DI2's skill deck is pure data** (`DI2/BalancingData/Player/Skills/SkillSlots/...`): slot categories per class
   (Berserker: Innate 2, Survivor 5, Slayer 5, Numen 3, Abilities 5 = Defence / JumpKick / SpecialAttack / FuryBuildUp /
   FurySpecialAttack), cards = `DA_SlottableSkillDefinition_*` with `EffectsByLevel` (`ApplyPlayerPerkSkillEffect`,
   `ActionAliasBindingSkillEffect`). **Block vs Dodge, Drop Kick vs Flying Kick, Ground Pound, Overhead Smash are cards**
   (`DA_SlottableSkillDefinition_Block.json:83`, `_Dodge.json:83`, `_DropKick.json:67`, `_FlyingKick.json:67`,
   `_GroundPound.json:81`); our build hard-wires block + dodge + kick + head stomp at once.
3. **DI2 UI is Scaleform GFx, not UMG.** 173 `SWF_*` assets vs 6 `WBP_*` (`extracted/files.txt`). A menu =
   `DA_MenuType_*.MenuClass` -> `BP_MenuInstance_*` {`SwfAsset` SWF_SharedMenu, `MoviePlayer` BP_DSGFxMoviePlayer_*,
   `ScreenClassesMap`, `DefaultOpeningScreen`} -> `BP_MenuScreen_*` loading `SWF_Screen_*` / `SWF_MenuView*` via
   `LoaderSwfMovie` (`DI2/UI/Menus/Frontend/BP_MenuInstance_FrontEnd.json:44-48,267-314`). HUD = `BP_HUDState_*` ->
   `HUDObjectClasses` -> `BP_HUDObject_*.HUDAssetClasses` -> `BP_GFxMoviePlayer_*.SwfMovie`
   (`DI2/UI/HUD/Objects/Health/BP_HUDObject_Health.json:35-42`). The cooked `SWF_*.uasset` embeds the GFx v15 movie
   verbatim (`GFX` signature + u32 length; textures external as `T_*.tga` names = UE textures); JPEXS
   (`tools/ffdec/ffdec-cli.exe`) exports its shapes, frames and AS2 scripts. AS2 holds only display glue
   (`_root.Bar.Background` etc.); behaviour lives in the BP movie players / HUD objects (bytecode, `bpdump`).
4. Loot is data: `DI2/BalancingData/Loot/ZombieLootGroups/DA_LootListDefinition_Walker_Default.json` (Cash 0.35,
   MiscEnemyLoot 0.18 = health items / ammo, Weapons 0.01, ...), containers `.../LootableContainers`, rarity by level
   `.../Loot/Progression`. Inventory category sizes `DI2/BalancingData/Inventory/DA_InventoryCategory_*` (Weapons 16,
   Ammo 7, Consumables 2, Throwables 14, Ingredients 30).

## 1. Mechanics table

Size: S < 2 h, M = one 2-4 h session, L = several sessions.

| DI2 mechanic | DI2 source | Ours today | Gap | Size |
|---|---|---|---|---|
| Walk / run / sprint speeds, accel / decel | `DI2/BalancingData/Player/Movement/DA_PlayerMovementParamSets.json` (MaxMoveSpeed, Acceleration, Deceleration, Forward/Backward/StrafeSpeedScalar); slope / stair curves `Curve_Slope*`, `Curve_Stair*` same folder; `DA_ModifiableValueDef_Player_MaxMoveSpeed*` | player.gd:906-998 (`_physics_process`, speed from weapons.json `player.walk_speed` 3.2 / `sprint_speed` 5.6, instant velocity) | invented numbers; no accel / decel / strafe / backward scalars; ParamSets enum index unknown (UNV #101) | M |
| Sprint (stamina, input) | `DI2/Player/Actions/Sprint/DA_ActionDefinition_Player_Sprint.json` -> `BP_Action_Player_Sprint_C`; `DA_ModifiableValueDef_StaminaCost_Movement` (Player/Stamina) | player.gd:908-909 (hold to sprint, no cost) | sprint stamina cost / rules in BP params (bytecode) | S |
| Stamina pool + recharge | `DI2/BalancingData/Player/Stamina/Curve_StaminaRecharge_Berserker.json`; attribute `StaminaMax` (combat.json `dani.attributes`, from DA_CharacterAttributeValues_Berserker_Female) | player.gd:430-432 `use_stamina`, :895-897 linear regen 22/s after 0.8 s | recharge curve not used; delay invented; per-action costs mostly invented (UNV #22, #23) | S |
| Jump | `DA_PlayerMovementParamSets` DesiredJumpHeight 100 cm, JumpTimeToApex 0.4 s, GravityScalar, InAir*; `DI2/Player/Actions/Jump/DA_ActionDefinition_Player_Jump.json` | player.gd:920-922 `velocity.y = 4.6` | DI2 gives v0 = 2h/t = 5 m/s, g = 2h/t² = 12.5 m/s² (vs Godot default); no air control | S |
| Crouch | `DI2/Player/Actions/Crouch/DA_ActionDefinition_Player_Crouch.json` (StatContext Crouch, reticle spread fact); its ParamSet | none (player.gd:584 fact `Self.Crouch` = false) | not implemented (1P crouch clips exist in Player1P anim sets) | M |
| Slide | `DI2/Player/Actions/Slide/*` (SlideRequest / SlideCooldown); ParamSet MaxMoveSpeed 450; attrs SlideDamage 15 / SlideForce 35 (combat.json `dani.attributes`); perk `DA_ExplosionArchetype_Perk_SlideDamageBuff` | none | not implemented | M |
| Vault / ledge grab / ladder | `DI2/Player/Actions/LedgeGrab/*` (LedgeGrabActionParams), `Ladder/*`, `PlayerLadder/*` | none | not implemented; NH_04 needs ledge grab for walls / fences (map-dependent) | L |
| Dodge | `DA_PlayerMovementParamSets` DodgeDuration / DodgeDistance; `Player/Actions/Dodge/Curve_Dodge_StrengthOverTime_Float`; card `DA_SlottableSkillDefinition_Dodge` | player_moves.gd:430-486 (curve + lens from combat.json `dodge`; distance 2.4 m / stamina 18 from weapons.json) | distance / stamina invented (DI2 180 cm); always on (DI2: card in the Defence slot, exclusive with Block) | S |
| Block / perfect block | `Player/Actions/Block/DA_PlayerBlockSuccessConfigParams` (StaminaChangeOnBlock 0), `DA_PlayerPerfectBlockConfigParams` (1.5 / cooldown 1.5); card `DA_SlottableSkillDefinition_Block` | player_moves.gd:158-222 (perfect window 0.25 guessed, block 1.2x damage stamina) | base window + block stamina rule native (UNV #5, #22) | S |
| Kick / drop kick / flying kick / head stomp | `Player/Actions/{DropKick,FlyingKick,HeadStomp}`; `BalancingData/Player/Attacks/DropKick` (radius 150, impulse 50000, stability 40, launch settings); cards `_DropKick`, `_FlyingKick` | player_moves.gd:354-423 (kick + stomp + shove; drop kick radius / stability only) | Flying Kick missing; drop kick impulse / launch / slomo missing; head stomp unlocked for testing (UNV #14, #15) | M |
| Melee light / heavy / charge / lunge | combat.json classes from `DA_AnimSet_StandardAttack_*`, `HeavyAttack/Curve_*`, MeleeArchetypeData | player_melee.gd:114-329 | good; native defaults open (UNV #16-#18) | — |
| Ground Pound / War Cry / Overhead Smash (special attacks) | `Player/Actions/SpecialAttacks/{GroundPound,WarCry}` (GroundPound r750 dmg30 stab60; SuperHeroLanding r1000 dmg60) | Fury smash only (player_moves.gd:640-676) | special-attack slot not implemented | M |
| Fury mode | `Player/Actions/Fury/DA_ActionDefinition_Player_Fury` (BP_Action_FuryMasterAction); Fury specials (OverheadSmash r350 dmg75 stab125; Cone r1200 dmg50; Scream r1200 stab500; Slobber spit) ; `DA_FuryGainSource_Default` | player_moves.gd:640-676, gain player.gd:661-665 (claw 45, smash 70, 15 s: guesses, UNV #12) | fury attacks / durations from data; fury gain rules | M |
| Weapons, slots, switching | weapons.json (162 weapons, build_weapons.py); inventory `DA_InventoryCategory_Weapons` Size 16 | player.gd:744-798 (3-slot test loadout + F3 catalogue) | no inventory; DI2 weapon wheel `SWF_HUD_WeaponWheel` / `BP_HUDState_Wheel` | M (with inventory) |
| Durability / repair | weapon `Durability` attrs (`BalancingData/Weapons/Melee/AttributeTypes/DA_Attribute_Melee_MaxDurability`); `Player/Actions/BrokenWeapon` | player.gd:196-198, player_melee.gd:559-566 (broken -> 0.4x dmg), T = repair cheat | broken multiplier unsourced; repair is a workbench action (`BP_MenuActionData_Repair`) | S |
| Ranged: fire / ADS / reload / ammo | each gun's RangedWeaponModulesComponent (weapons.json) | player_ranged.gd:106-384 | reserve = 5x mag stand-in; ammo should come from inventory `DA_InventoryCategory_Ammo` + pickups | S |
| Throwables / curveballs | `DI2/Items/ThrowableWeapons/<Name>/BP_Projectile_*`, `DI2/Items/Pickups/Weapons/DA_ItemSpec_{PipeBomb,MolotovCocktail,Shuriken,Flashbang,MeatBait}`; `Player/Actions/{Throw,QuickThrow}` | player_moves.gd:564-902 (pipe bomb, molotov, shuriken; cooldown 12 s "shortened for testing") | recharge times per curveball not read (item specs); 6+ curveballs missing (flashbang, meat bait, stickies, electric star, nail bomb, grenade); UNV #13 | M |
| Medkits / health items | `Player/Actions/Heal/{BP_Action_Player_UseMedkit, DA_ActionDefinition_Player_UseMedkit_*}`; `DI2/Items/Pickups/DA_ItemSpec_Health_HealthPack`; `DA_InventoryCategory_Consumables` Size 2 | player_moves.gd:755-760 (+50% instantly, no anim) | heal amount / use animation / carry cap from item spec + action; regen attr `DA_AttributeType_HealthRegen` | S |
| Health, damage taken, knockdown / stun / limp | attrs (combat.json `dani.attributes` MaxHealth 110); `Player/Actions/{PlayerKnockdown,PlayerStun,Limp,PlayerKnockback}` | player.gd:824-852 `take_zombie_hit` / `_hurt` | no knockdown / stun / limp reactions to zombie hits | M |
| Death / respawn | `Player/Actions/Death/*` (Downed, Dead, Reviving); `DI2/Gameplay/Respawn` (BP_RespawnLocationOption, DA_DonutRespawnPickerRules); HUD `BP_HUDStateRespawning` | player.gd:848-861 `die` / `respawn` (instant, full heal, same spot) | respawn picker rules + fail-screen flow | S |
| Pickups / loot drops / containers | `DI2/BalancingData/Loot/{ZombieLootGroups,LootableContainers,Progression}`, `DA_LootGroup_{Cash,MiscEnemyLoot,AllIHealthItems}`; actors `DI2/Gameplay/LootContainers/BP_LootContainer_*`, `DI2/Items/Pickups/*` | only re-picking thrown weapons (player_moves.gd:597-606) | no drops, no world pickups, no containers, no cash | L |
| Inventory / backpack | `DI2/BalancingData/Inventory/DA_InventoryCategory_*` (sizes), `DI2/Core/Player/Inventory/BP_*Inventory*` | loadout / ammo / medkits vars only (player.gd:39-62) | no inventory model | M |
| Weapon mods / perks / crafting | `DI2/BalancingData/Weapons/WeaponMods/BP_WeaponMod_*_Level_*`, weapon perks `.../Weapons/Perks`, workbench actions `BP_MenuActionData_{Craft,Scrap,Repair}` | player_melee.gd:18-66 cycle 4 mods (fire / acid / electric / bleed), no perks, no crafting | per-weapon mod slots, weapon perks, craft costs (ingredients) | L |
| Skill cards (deck) | `DI2/BalancingData/Player/Skills/SkillSlots/...` (categories, `DA_SlottableSkillDefinition_*`, defaults `bIsDefaultAssignedSkill`) | 3 perks hard-wired (player_melee.gd:514-518 chain, player_moves.gd:763-773 bloodlust, stamina streak) | no deck model, no card effects beyond 3 perks; ability exclusivity (Block vs Dodge, kick type) | L |
| Perks system | `DI2/Core/Perks/{PerkDefinitions,PerkConditions,PerkEffects}`, `DI2/BalancingData/Player/Perks/...` | the 3 above, ad hoc | a generic perk interpreter (condition -> effect, like the card-dealer note) | L |
| XP / levels | `DI2/BalancingData/Player/DA_PlayerProgressionLevels.json` (XP totals), `DA_Reward_PlayerProgression_LevelUp` | progression.gd:1-60, player.gd:864-876 (stat growth +4% / +2% / +10% are estimates) | level stat growth source; skill-point rewards | S |
| Interaction prompts | `DI2/UI/ContextualInputSystem/*`, `Player/Actions/AllowInteraction` | player.gd:721-722 (thrown weapon pickup only) | generic interact (containers, doors, pickups) | M (with loot) |
| Pause / time | `DI2/UI/Menus/InGamePauseMenu/BP_MenuInstance_InGamePauseMenu.json:323` | ESC releases the mouse only (main.gd:250-253) | no pause | S (see UI) |

## 2. UI table

All DI2 sources are under `DI2/UI/...` (or `DI2/Horde/UI/...`); tech = Scaleform GFx unless noted.

| DI2 screen / widget | DI2 source (instance / object -> SWF) | Ours today (hud.gd) | Gap | Size |
|---|---|---|---|---|
| HUD: health + medkits | `HUD/Objects/Health/BP_HUDObject_Health` -> `BP_GFxMoviePlayer_Health` -> `SWF_HUD_Health` | `_draw_player_status` hud.gd:184 (DI2 textures) | layout / anim from the SWF not the guess | S |
| HUD: stamina | `HUD/Objects/Stamina` -> `SWF_HUD_Stamina` (carved: T_HUD_Health_StaminaBarTexture, T_HUD_Stamina_BackgroundTexture) | hud.gd:184 | same | S |
| HUD: Fury | `HUD/Objects/Fury` -> `SWF_HUD_Fury` | hud.gd:184 (shockwave frames) | — | S |
| HUD: equipped weapon / throwable | `SWF_HUD_EquippedWeapon`, `SWF_HUD_EquippedThrowable`; icons `UI/Shared/SWF_Icons_Items` | `_draw_weapon` hud.gd:213 (rendered 3D icon, UNV #24) | real item icons from SWF_Icons_Items (shapes + T_ textures) | M |
| HUD: weapon wheel | `BP_HUDState_Wheel`, `BP_GFxMoviePlayer_WeaponWheel` -> `SWF_HUD_WeaponWheel` | none (number keys / F3 catalogue) | wheel | M |
| HUD: reticle + hit markers | `HUD/Objects/Reticle` -> `SWF_HUD_Reticle` | `_draw_reticle` hud.gd:251 (JPEXS pieces) | done-ish | — |
| HUD: enemy name slates | `UI/IconSystem/*`, `SWF_HUD_IconSystem` | `_draw_enemy_slates` hud.gd:271 | IconSystem rules (distance, show conditions) | S |
| HUD: XP bar / level up | `SWF_HUD_XPBar` | `_draw_progression` hud.gd:326 | — | S |
| HUD: hints / tutorial tips | `SWF_HUD_HintPopUp`, `SWF_HUD_TutorialTextTip`; `DI2/Narrative/Tutorials/DA_Tutorial_*` | `_draw_hint` hud.gd:347 (strings ours) | DI2 strings (`UI/Strings` ST_*) | S |
| HUD: pickup log / message log / central notifications | `SWF_HUD_PickUpLog`, `SWF_HUD_MessageLog`, `SWF_HUD_CentralNotifications` | popups hud.gd:307 | pickup log needs loot | S |
| HUD: compass bar / current mission | `SWF_HUD_CompassBar`, `SWF_HUD_CurrentMission` | none | compass (needs map markers) | M |
| HUD: hit direction indicator | `HUD/PROTO_Elements/WBP_HUD_HitIndicator` (**UMG**) on every HUD state (`HUD/States/BP_HUDStateDowned.json:33`) | `_draw_hurt` hud.gd:366 | read the WBP layout | S |
| HUD states (which objects show when) | `HUD/States/BP_HUDState*` + `DA_HUDObjectsGroup_{CoreRequired,CorePlayer}` | all-or-nothing `_draw` hud.gd:127 | state machine (gameplay / pause / player menu / downed / respawning / wheel) | S |
| Death / fail screen | `BP_HUDStateRespawning`, `SWF_HUD_FailScreen`, `SWF_HUD_Downed` | hud.gd:144-149 (T_HUD_FailScreen_DeathScreen) | respawn timing / flow | S |
| Fader / loading / save icon | `SWF_HUD_Fader`, `WBP_HUDFaderSimple` (UMG), `SWF_HUD_LoadingScene`, `SWF_HUD_SaveIcon` | none | P3 | S |
| Front end (title, main menu, character select) | `Menus/DA_MenuType_FrontEnd` -> `Menus/Frontend/BP_MenuInstance_FrontEnd` (SWF_SharedMenu; screens MainMenu, CharacterCreate, Extras, Credits, ... `:50-260`); `SWF_Screen_MainMenu`, `SWF_MenuViewCharacterSelect` | none (boots into the arena / map) | front end -> start NH_04 | M |
| Pause | `BP_MenuInstance_InGamePauseMenu` (screens PauseMain, PlayerStats, PlayerList, FriendsList + Options / Tutorials groups; `:285-323`) | none | pause + resume / options / quit | M |
| Player menu hub | `BP_MenuInstance_PlayerMenu` (DefaultOpeningScreen Main = `BP_MenuScreen_PlayerMenuSelect`; screens Inventory, UpgradeTypes, WeaponDetailedStats, Map, Quests, SlottableSkills, SkillSlot, Character, Challenges + Collectibles group) | none | hub | M |
| Inventory | `BP_MenuScreen_InventoryTabbed` tabs Consumables / Resources / Keys / Weapons / Equipment (`:646-754`), view `SWF_MenuViewItemListLayout` | none | needs inventory model | M |
| Weapon stats / mods (upgrades) | `UpgradeTypes` -> `SWF_MenuViewWeaponUpgradesOverview`, `Upgrades` -> `SWF_MenuViewWeaponUpgrades`, `WeaponDetailedStats` | none (key cycles mods) | needs mod model | M |
| Workbench (craft / scrap / repair / upgrade) | `DA_MenuType_Workbench`, `BP_MenuScreen_WorkbenchTabbed` tabs Weapons / Crafting, actions `BP_MenuActionData_{Craft,Scrap,Repair,ViewUpgrades}` (`:185-260,557-583`) | none | needs world workbench + ingredients | L |
| Skill deck | `BP_MenuScreen_SkillCards` -> `SWF_MenuViewSkillCards` (carved; imports SWF_PlayerMenuElements*.swf) | none | needs deck model | M |
| Map | `BP_MenuScreen_Map` -> `SWF_MenuViewWorldMap` (`:163-385`), `BP_HUDState_WorldMap` | none | NH_04 map texture + markers | M |
| Journal / quests / collectibles / challenges | `SWF_MenuViewJournals`, `DA_MenuScreenGroup_Collectibles`, Challenges screens | none | P3 (no quests in the showcase) | L |
| Options / settings | `DA_MenuScreenGroup_Options` + `_OptionsShared` (Video, Audio, Controls, KeyRebind, UI, Gamepad, Brightness, ...); data `DI2/Core/OptionsSystem/DT_Options_{Video,Audio,Controls}`, `DA_OptionsCollectionData_GeneralOptions` | none | options pages wired to Godot settings | M |
| Horde: lobby / talents / mission select / results / session end / Horde HUD (BondMeter, ClassAbility, MiniMap, SessionProgress, TrapWheel) | `Horde/UI/Menus/*` (`BP_MenuInstance_LobbyScreen`, `_MissionSelection`, `_HordeMissionResult`, `_SessionEnd`), Horde HUD objects | none | only if the showcase becomes a Horde session (decision above) | L |

## 3. Ranked task list

Ownership: player*.gd, hud.gd, progression.gd, weapons.json / combat.json are **unowned** (COORDINATION.md row 24), so the
coordinator assigns them per task; tasks touching player.gd run **one at a time**. New UI code goes into new files
(`game/scripts/ui/*`) so UI tasks can run beside gameplay tasks. Every task: data from DI2 assets with the path in a
code comment; unknowns to UNVERIFIED.md; heavy jobs via `tools/with_cpu.sh <name>`; Godot via `tools/with_lock.sh` +
`tools/run_test.sh`; effort medium unless stated.

### P1: needed for a playable showcase on NH_04

**P1-1 Movement + stamina from DI2 data** (M, effort high: one native enum to resolve).
- Do: resolve the `DA_PlayerMovementParamSets.ParamSets[]` index -> movement state (UNV #101: reflection enum near the
  `PlayerMovementParamSets` property / the ParamSet select in the exe; `tools/re/di2exe.py`). New `tools/build_player_data.py`
  writes `game/data/player.json` {param_sets by state, stamina recharge curve Berserker, StaminaCost_Movement, slope /
  stair curves, jump height / apex}. player.gd reads it: accel / decel, walk / sprint / backward / strafe scalars, jump
  v0 + gravity, curve-based stamina recharge, dodge distance / duration. Retire weapons.json `"player"` (build_weapons.py:468).
- Owns: tools/build_player_data.py, game/data/player.json, player.gd movement section (`_physics_process`,
  `_walk_run_sprint_x`), player_moves.gd `dodge` / `_update_dodge`, autotest_combat.gd movement CHECKs.
- Done-check: `tools/run_test.sh --combattest=...` prints `CHECK move walk_speed=4.00 sprint=6.00 accel=10 decel=20 ok`,
  `CHECK jump apex=1.00m t=0.40s ok`, `CHECK dodge dist=1.80m dur=0.40s ok`, `CHECK stamina recharge curve ok` (values
  read back from player.json, measured from the simulated body), 0 script errors.

**P1-2 Skill deck model + ability exclusivity** (M).
- Do: `tools/build_skills.py` -> `game/data/skills.json` from `DI2/BalancingData/Player/Skills/SkillSlots` (Berserker
  categories, slot counts, level gates `...Fury_Berserker.json:465-504`, cards with `EffectsByLevel`, defaults
  `bIsDefaultAssignedSkill` in `SlottableSkills/Collect/Berserker/*`). New `game/scripts/skill_deck.gd` holds slotted cards; abilities gate Block vs Dodge
  (Defence slot), Drop Kick vs Flying Kick (JumpKick slot), Ground Pound (SpecialAttack), fury cards; perk cards map
  to the 3 existing perks (others listed as not-yet). Replace the hard-wired head stomp unlock (player.gd:518-519).
- Owns: tools/build_skills.py, game/data/skills.json, game/scripts/skill_deck.gd (new class_name: run the import),
  the ability gates in player_moves.gd (`block_pressed`, `dodge`, `kick`), autotest_combat.gd skill CHECKs.
- Done-check: combat suite `CHECK deck default = every bIsDefaultAssignedSkill card of `SlottableSkills/Collect/Berserker/DA_SlottableSkillCollection_*_Berserker` (+ `Starter_Berserker_Female` for Dani) ok` (list printed, built from the data, not hard-coded); `CHECK defence Block -> block works, dodge refused ok` and the reverse; 0 errors.

**P1-3 Pause menu + HUD states + options (video / audio / controls)** (M).
- Do: new `game/scripts/ui/menu_pause.gd` (+ `ui/hud_states.gd`): ESC pauses (`get_tree().paused`), PauseMain items
  from `BP_MenuInstance_InGamePauseMenu` (Resume, Options, Quit; PlayerStats / PlayerList are co-op, skip), options
  pages from `DT_Options_Video` / `DT_Options_Audio` rows mapped to Godot (FoV, VSync, MaxFramerate, Resolution,
  WindowedMode, volumes, subtitles), mouse sensitivity / invert from `DA_OptionsCollectionData_GeneralOptions`.
  HUD state table from `HUD/States/BP_HUDState*` (which objects show in gameplay / pause / downed / respawning).
  Art: `DI2/UI/Textures/*` + menu fonts already in `game/assets/di2/ui`; visuals from the carved `SWF_SharedMenu`
  / `SWF_Screen_MainMenu` frames (P1-4 tooling) or plain text in DI2 fonts until then.
- Owns: game/scripts/ui/menu_pause.gd, game/scripts/ui/hud_states.gd, hud.gd `_draw` gating, main.gd ESC handler
  (coordinator change: exact one-line hook), new `game/scripts/autotest_ui.gd` + `--uitest=` in main.gd.
- Done-check: `tools/run_test.sh --uitest=game/test_out/ui` presses ESC, navigates PauseMain -> Options ->
  Video -> change FoV -> Back -> Resume by synthetic input, captures each screen, prints `CHECK ui pause ok`, `CHECK
  ui options fov applied ok`, `CHECK hud state gameplay/pause ok`, 0 errors.

**P1-4 GFx asset pipeline: carve + export every SWF** (M, tooling).
- Do: extend `tools/re_ui/carve_gfx.py` + a batch `tools/re_ui/export_gfx.sh`: `di2x raw '/SWF_[^/]*\.'` (all 173),
  carve, JPEXS `-export shape,image,frame,sprite,script` per movie, resolve external `T_*.tga` names to
  `di2x tex` exports, write `game/assets/di2/ui/gfx/<movie>/` (PNG frames + SVG shapes) and an index json
  {movie, size, imports, external textures, frame labels}. Feeds P1-3, P1-5 and every menu task.
- Owns: tools/re_ui/*, game/assets/di2/ui/gfx/ (gdignore'd raw parts; game files never committed).
- Done-check: `python tools/re_ui/check_gfx.py` reports 173/173 carved, every movie exported, 0 unresolved external
  textures (or each one listed in UNVERIFIED), and a contact sheet PNG of all frame-1 renders.

**P1-5 Weapon wheel + real item icons** (M; after P1-4).
- Do: icons from `UI/Shared/SWF_Icons_Items` (frame label per item; the weapon's `UIIconFrameLabel`-style field in its
  item spec) replace the rendered 3D icons (UNV #24); weapon wheel from `SWF_HUD_WeaponWheel` + `BP_HUDState_Wheel`
  (hold to open, slow-mo if the BP says so: read `BP_GFxMoviePlayer_WeaponWheel` bytecode with bpdump).
- Owns: game/scripts/ui/weapon_wheel.gd, hud.gd `weapon_icon` / `_draw_weapon`, autotest_ui wheel CHECK.
- Done-check: uitest `CHECK icons 162/162 weapons have a SWF_Icons_Items frame ok`, `CHECK wheel select slot 2 ->
  machete equipped ok`, captures.

**P1-6 Medkits, curveball recharge, ammo + health drops** (M).
- Do: medkit heal amount / use animation / max count from `DI2/Items/Pickups/DA_ItemSpec_Health_HealthPack` +
  `Player/Actions/Heal/DA_ActionDefinition_Player_UseMedkit_*`; curveball recharge per item spec
  (`DA_ItemSpec_{PipeBomb,MolotovCocktail,Shuriken,...}`) replacing `CURVEBALL_COOLDOWN 12` (player_moves.gd:12);
  zombie drops from `DA_LootListDefinition_Walker_Default` (Cash 0.35, MiscEnemyLoot 0.18 -> health items / ammo by
  `DA_LootGroup_MiscEnemyLoot` weights) as world pickups (DI2 pickup meshes `DI2/Art/Gameplay/Pickups/{HealthpackA,
  AmmoBoxA}`), auto-pickup + `SWF_HUD_PickUpLog` line. Reserve ammo then comes from pickups, not 5x mag.
- Owns: tools/build_loot.py, game/data/loot.json, game/scripts/pickups.gd (new), player_moves.gd `medkit` /
  curveball cooldown, player.gd ammo reserve, autotest_combat loot CHECKs.
- Done-check: combat suite kills 200 scripted Walkers with a fixed seed and prints drop rates within 3 sigma of the
  data (`CHECK loot walker cash=0.35 misc=0.18 ok`), `CHECK medkit heal=<spec> ok`, `CHECK curveball pipebomb
  recharge=<spec>s ok`.

### P2: milestone progress, nothing waits on it

| Task | Owned files | Done-check | Effort |
|---|---|---|---|
| P2-1 Inventory model + inventory screen (category sizes `DA_InventoryCategory_*`, tabs of `BP_MenuScreen_InventoryTabbed`) | game/scripts/inventory.gd, ui/menu_player.gd | uitest navigates Player menu -> Inventory tabs, `CHECK inventory caps weapons=16 ammo=7 consumables=2 ok` | M |
| P2-2 Skill deck screen (`SWF_MenuViewSkillCards` frames + card art `ThumbnailImage`) on P1-2's model | ui/menu_skills.gd | uitest swaps Dodge -> Block by input, `CHECK deck swap applies ok`, capture | M |
| P2-3 Flying kick + special attacks (Ground Pound, War Cry) + drop kick launch / impulse / slomo from `BalancingData/Player/Attacks` + `SpecialAttacks` | player_moves.gd kick section | combat `CHECK flyingkick / groundpound radius dmg stab = data ok` | M |
| P2-4 Fury from data (fury specials explosion archetypes, gain sources, duration) replacing UNV #12 guesses | player_moves.gd fury | combat `CHECK fury smash r=3.5 dmg=75 stab=125 ok` | M |
| P2-5 Player hit reactions: knockdown / stun / limp / knockback (`Player/Actions/{PlayerKnockdown,PlayerStun,Limp,PlayerKnockback}` + 1P clips) | player.gd `_hurt` | combat: Thug heavy hit -> `CHECK knockdown ok` | M |
| P2-6 Crouch + slide (ParamSets, Slide actions, SlideDamage / SlideForce) | player.gd movement | combat `CHECK slide speed=4.5 dmg=15 ok` | M |
| P2-7 Weapon mods + weapon perks per weapon (`BalancingData/Weapons/{WeaponMods,Perks}`), upgrades screen | player_melee.gd mods, ui/menu_upgrades.gd | weapons suite `CHECK mod slots per weapon = data ok` | L (2 sessions) |
| P2-8 Front end -> start NH_04 (`BP_MenuInstance_FrontEnd`: Splash -> MainMenu -> Continue / New) | ui/menu_frontend.gd, main.gd boot | uitest boots to front end, presses Start, map loads | M |
| P2-9 Map screen (`SWF_MenuViewWorldMap`, NH_04 map texture) + compass bar | ui/menu_map.gd | uitest capture, player marker at the right place | M |
| P2-10 Death / respawn flow (`DA_DonutRespawnPickerRules`, `BP_HUDStateRespawning`, `SWF_HUD_FailScreen`) | player.gd die / respawn, ui | combat `CHECK respawn at rule point ok` | S |
| P2-11 Level stat growth + skill points from data (replace +4% / +2% / +10% estimates, player.gd:864-876) | progression.gd | combat `CHECK level 10 stats = data ok` | S |

### P3: polish / not needed for the showcase
Workbench + crafting + ingredients (L), loot containers in the map (M, with the N1 map work), journals / challenges /
collectibles (L), ledge grab / vault / ladders (L, only if NH_04 traversal needs it), the Horde UI set (lobby,
mission select, results, Horde HUD: L), fader / loading / save icon (S), subtitles + ST_ string tables (S).

## 4. UI tech per screen and the port route

| Screen | DI2 tech | Port route |
|---|---|---|
| Every HUD element except the hit indicator / fader | Scaleform GFx (`SWF_HUD_*` via `BP_GFxMoviePlayer_*`) | carve GFx (P1-4), JPEXS shapes / frames -> Godot `Control` drawing (as hud.gd does), behaviour from the `BP_HUDObject_*` / movie-player bytecode (`bpdump` + `tools/bp_pretty.py`) |
| Hit indicator, simple fader | UMG (`HUD/PROTO_Elements/WBP_HUD_HitIndicator`, `WBP_HUDFaderSimple`) | widget tree is in the cooked JSON (CUE4Parse); rebuild as Godot Controls |
| Front end, pause, player menu, inventory, upgrades, workbench, skill deck, map, journals, options | Scaleform: shell `SWF_SharedMenu` + `SWF_Screen_*` + `SWF_MenuView*`, screens are BP (`BP_MenuScreen_*`), actions `BP_MenuActionData_*` | screen graph (ScreenClassesMap / DefaultOpeningScreen / BackAction) and option rows from JSON; visuals from carved movies; navigation logic from the menu-screen bytecode where JSON isn't enough |
| Game lobby | UMG (`UI/Screens/WBP_GameLobby`, from `BP_MenuScreen_GameLobby.json:49-51`) | not needed (co-op) |
| Horde menus | Scaleform (`SWF_Horde_*`) on the same SWF_SharedMenu shell | same route, P3 |

Tools that exist: `tools/di2x.sh json|raw|tex` (CUE4Parse), `tools/re_ui/carve_gfx.py` (GFx carve, new),
`tools/ffdec/ffdec-cli.exe` (JPEXS 1:1 export of GFx shapes, sprites, frames, AS2), `bpdump` + `tools/bp_pretty.py`
(BP bytecode). There is no Scaleform runtime for Godot; the route is to rebuild each movie as Godot Controls from its
exported parts, not to play the movie.
