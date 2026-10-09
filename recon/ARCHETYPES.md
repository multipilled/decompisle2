# DI2 zombie archetypes: roster, bodies and port status

## Hand-off (top, keep current)
- **Q14 P2 variants DONE 2026-10-09:** all 22 P2 Blueprints (Walker / Runner x Burning, Fireman, Shocking, Caustic, Spiky,
  Vicious; Walker FuelTank, WaterTank, Corrosive, GrenadeVest, InsectSwarm, Radio, RiotGear Light / Medium / VeryLight / Heavy)
  spawn on their own mesh (first VariantAssets mesh) with their class clips, FLESH stamps, dismemberment, deform, viscera and
  character state; archetypes.json has a row each (class stats, facts + perks as data); zombie.gd BODIES 239e368 + 123fcd4.
  Captures: game/test_out/di2-arch-meshes/run/di2-arch-meshes/<body>_look_front|back.png, <body>_hit_lowerarm_l.png (66), contact
  sheet game/test_out/di2-arch-meshes/variants_front_sheet.png. Default flesh runs capture one smoke variant (suite limit 300 s);
  all of them: `RUN_TEST_LIMIT=800 TEST_EXTRA_ARGS="--map=nh04_street --archetype-variants" tools/run_all_tests.sh flesh`.
  Tests: flesh exit 0 / 0 errors (263 s), combat exit 0 / 0 errors (361 s), all-variants flesh exit 0 / 0 errors (366 s), no [panic.
  Perf (--archetype-perf, 8 P1 specials): idle 142.5 fps / 34.3 ms process; after hits 59.3 fps / 250.6 ms (first-hit compiles);
  second round 56.7 fps / 57.4 ms. Disk: variant body folders 180 MB, shared texture pool 1.2 GB, Godot import cache +916 MB.
  **Next (queued by the coordinator): the first-spawn hitch.** borrow_clips re-targets every clip: walker variants 2.2-3.8 s,
  runner 0.5-0.7 s, per variant type. Sharing untouched clips (6658953) doesn't help: every clip animates the ~55 differing face
  bones (AnimationRelative only, see each <body>.retarget.json). Cheapest exact fix: no clip copies at all, a SkeletonModifier3D
  on the variant skeleton applying t + dt / q * dq to those bones after ZombieAnim's pose (check that every clip has those
  tracks, else apply only where it does), or a prewarm at map load. Other open: UNVERIFIED 95-98, Q15 behaviours.
- **Design (coordinator decision 2026-10-09, zombie.gd hooks 239e368):** a variant body is a mesh-only glb (tools/archetype_bodies.py
  VARIANTS, `built()` = those with a body folder; every per-body builder loops over built()). zombie.gd keeps `body` = class clip folder
  (walker / runner: ZombieAnim, AI, reactions, hit reacts, facial unchanged) and `mesh_body` for mesh data. game/scripts/body_variant.gd
  lends the class AnimationLibrary, re-targeted class mesh -> variant mesh with <body>.retarget.json (UE RetargetBoneTransform composes
  for Skeleton / AnimationScaled / AnimationRelative; Walker clips verified retargeted onto walker's rest). Textures: pack_materials.py
  --pool (existing bodies' copies referenced in place, the rest once in game/assets/di2/textures/), part glbs too (build_viscera_parts.py).
- **State 2026-10-09:** P1 done: Screamer, Slobber, Butcher, Suicider spawn on their own DI2 bodies
  (game/assets/di2/<body>/, built by `python tools/archetype_bodies.py <body>`), take FLESH hits and dismember.
  Captures: game/test_out/archetypes/<body>_look_front|back.png, <body>_hit_<bone>.png (flesh suite hook ->
  game/scripts/autotest_archetypes.gd; `--archetype-perf` adds a perf_check line for 8 specials).
- Per-body data, regenerated with the bodies added to each builder's BODIES (existing 4 bodies' outputs unchanged, only additive
  changes): flesh_materials (build_flesh_materials.py), character_states, viscera_parts (+ DA_SpawnableParts_* dumps),
  <body>.subsections.json, <body>.deform.bin (export_deform.py), <body>.dismember.json (export_dismember_data.py <body>),
  hit_reacts (build_hit_reacts.py), zombie_facial (build_zombie_facial.py; Slobber left out: its facial idles are
  UE-codec, which that builder doesn't decode).
- archetypes.json: tools/merge_archetype_loco.py (merge-only; see "archetypes.json provenance").
- **Open / next:** (1) zombie_anim.gd LOCO_SETS for the new bodies and montages_zombie.json regeneration: locomotion
  worker (tools/build_zombie_montages.py already lists them). (2) P2 elemental / hazard meshes: done (Q14, top bullet). (3) Butcher has no crawl clip (no crawler locomotion in its data). (4) Slobber facial. (5) Other
  variants of each class (UNVERIFIED 70).
- Pipeline per new body: `di2x mesh` (SK_*), `di2x rawanim` (+ `di2x anim` PSA for FUECompressedAnimData sequences),
  archetype_bodies.py, build_flesh_materials.py, pack_materials.py (again, so eye overlays resolve), build_character_states.py,
  build_viscera_parts.py, build_subsections.py, export_deform.py <body>, export_dismember_data.py <body>, build_hit_reacts.py,
  build_zombie_facial.py, zombie.gd BODIES, Godot `--import`, flesh suite.
- Tool: `python tools/list_archetypes.py [--json out.json]` regenerates the variant table at the end of this file.
- **Q1 attack clips (2026-10-09):** `python tools/build_zombie_clips.py attacks2 tools/zombie_clips_attacks2.json` built
  game/assets/di2/zombie_clips/{walker,runner,shambler,thug}_attacks2.glb (96 sequences for the 116 montages in the zombie-AI
  note; montage -> clip list in hand-over notes attacks2-clips.md); the existing zombie_clips sets stayed byte-identical.
  montages_zombie.json regenerated by the locomotion worker (2dbcea2). Q1 accepted by the coordinator. Confirming run
  2026-10-09: flesh exit 0 / 0 errors (278 s), combat exit 0 / 0 errors (288 s). Next for the zombie AI: drop its
  UNVERIFIED 80 fallback.
  Reaction clips: hit_reacts.json clips_missing lists ~150 DI2 reaction sequences per body. The same tool can build them,
  but build_hit_reacts.py / hit_react_trees.gd only resolve clips from <body>/clips.json, not "x:<seq>", so that needs a
  hit-react side change first (unowned; coordinator).

## Brief Q14 (P2, 2026-10-09, session di2-arch-meshes)
Port the P2 rows of the port table (elemental / hazard Walker / Runner variants) as mesh swaps on the existing walker /
runner clips: Burning (+ Fireman), Shocking, Caustic, Spiky / Vicious, FuelTank / WaterTank / Corrosive, GrenadeVest /
InsectSwarm / Radio / RiotGear. Per row, commit after each: export SK_* (di2x), BODIES entries in archetype_bodies.py and
the per-body builders (walker or runner clip set), merge the variant's DA_AIAttributeValues stats into archetypes.json
(merge-only, back up first, that variant's rows only), spawn it in the archetypes capture, mark the row M A D S.
Mesh / material / data only: elemental behaviours (auras, tank / grenade explosions) are Q15, logged here, not built.
Owned: archetype_bodies.py, merge_archetype_loco.py, deform/export_deform.py, build_viscera_parts.py,
build_flesh_materials.py (BODIES only), re_dismember/*, autotest_archetypes.gd, this doc, own UNVERIFIED rows. Not owned
(exact change to the coordinator): zombie.gd, zombie_anim.gd, build_zombie_montages.py, build_character_states.py,
build_hit_reacts.py, build_zombie_facial.py. Done when every P2 row is M A D S (or blocked with a reason), captures in
game/test_out/di2-arch-meshes/, `tools/run_all_tests.sh flesh combat` 0 script/shader errors and no [panic; report
--archetype-perf once.
**Facts found 2026-10-09:** P2 = 19 Blueprints (BP_Walker_/BP_Runner_ Burning, Fireman, Shocking, Caustic, Spiky, Vicious;
BP_Walker_ FuelTank, WaterTank, Corrosive, GrenadeVest, InsectSwarm, Radio, RiotGear_Light / _Medium / _Heavy /
_VeryLight). None has its own DA_AIAttributeValues or BPC_MultiPartHealth asset in extracted/json (only Walker / Runner
class assets), and archetypes.json has no rows for them yet. A P1 body cost ~200 MB (glb 62 MB + per-body texture copies
~144 MB, only 15-35 % shared with walker) before Godot's import cache; D: had 3.3 GB free.

## How DI2 picks a zombie's mesh (from the cooked data)
`BP_<Class>_<Variant>` (Super `BP_Base_<Class>`, or another variant) has a `ProceduralCharacterPropertiesComponent`
whose `GenerationConfig.ModelVariation` is a `DA_ModelVariation_*`. Its `VariantAssets[]` are
`{Model: DA_ModelVariantAsset_*, Frequency}`; each `DA_ModelVariantAsset_*.Model` is the merged `SK_*` skeletal mesh
(plus `AddedFacts`, e.g. `Female`). Rarity / rank are in the same GenerationConfig. UI names come from
`UINameRowHandle.RowName` (e.g. BP_Thug_Inferno = INFERNOCRUSHER, BP_Walker_Corrosive = CAUSTICWALKER,
BP_Walker_FuelTank = INCENDIARY, BP_Walker_GrenadeVest = GRENADIER, BP_Screamer_Electric = VOLTAICSCREAMER).
**Every zombie mesh checked (28 specials and variants) uses `SKEL_ZombieStandard`**, so the existing retarget
(tools/merge_anims.py) carries over. Physics assets differ: PA_Screamer, PA_Slobber, PA_Butcher, PA_Suicider,
PA_Mutator, PA_Oscar (Whipper), PA_Cameron (Reformer), PA_Thug, PA_ZombieBackpack (FuelTank / WaterTank / Corrosive),
PA_WalkerMaleLrg (BurningWalker01), PA_ZombieStandard (the rest).

## Classes (BP_Base_*) and their data
Health / limb pool = game/data/archetypes.json health / BPC_MultiPartHealth MaxHealth. For the specials the json health is a fallback; see "archetypes.json provenance" below.
Anim sets = `AnimSetData/Zombie/Collections/DA_AnimSetCollection_*` that name the class.

| Class | Health / limb pool | Survive expression | Own anim sets | Example meshes |
|---|---|---|---|---|
| Walker | 150 / 120 | floatbranch(!#HasBothLegs, #HasBothArms, true) | yes (shipped) | SK_WalkerMaleCas01 |
| Runner | 120 / 90 | floatbranch(!#HasBothLegs, #HasBothArms, #HasAnArm) | yes (shipped) | SK_RunnerMaleCas01 |
| Shambler | 80 / 60 | #HasAnArm | Walker + Personality (shipped) | SK_ShamMaleCas01 |
| Thug | 540 / 450 | (none) | yes (shipped) | SK_ThugA01 |
| Screamer | 250 / 250 | floatbranch(!#HasBothLegs, #HasBothArms, true) | Locomotion, Misc, Crawler, StatusEffect, Facial | SK_Screamer01-03 |
| Slobber | 300 / 300 | #HasAnArm \|\| !IsPutrefied | Locomotion, Misc, RangedAttacks, HitReactions, StatusEffect, Facial | SK_SlobberA |
| Butcher | 120 / 120 | (none) | Standing/Crawling_Locomotion, Misc, HitReactions, StatusEffect, Facial | SK_Butcher01-03 |
| Suicider | 120 / 120 | (none) | Locomotion, Misc, StatusEffect, Facial | SK_SuiciderA |
| Mutator | 450 / 450 | (none) | Locomotion, Misc (Transformed / Untransformed), RangedAttacks, HitReactions, PlayDead, Facial | SK_BaseMutator01 -> SK_Mutator01 |
| Whipper (Exp2) | 120 / 120 | #HasAnArm | Locomotion/Misc/StatusEffect/Facial _Oscar | SK_Oscar02 |
| Reformer (Exp2) | 450 / 450 | (none) | Locomotion/Misc/StatusEffect/Facial _Cameron | SK_Cameron01 |
| Walker_RiotGear | (Walker) | | Walker | SK_RiotGearHelmetTorso / NoHelmet / TorsoOnly |

## Port priority (common specials first, apex last)
Status: - = not started, M = mesh+materials, A = anims, D = data (archetypes.json + BODIES), S = spawns in suite, done = all.

| P | Archetype (Blueprint) | DI2 meshes (ModelVariation) | Plan | Status |
|---|---|---|---|---|
| 1 | Screamer (BP_Screamer_Generic) | SK_Screamer01/02/03 | own body `screamer` | M A D S |
| 1 | Slobber (BP_Slobber_Generic) | SK_SlobberA | own body `slobber` | M A D S |
| 1 | Butcher (BP_Butcher_Generic) | SK_Butcher01/02/03 | own body `butcher` | M A D S |
| 1 | Suicider (BP_Suicider_Generic) | SK_SuiciderA | own body `suicider` | M A D S |
| 2 | Walker_Burning / Runner_Burning / *_Fireman | SK_BurningWalker01-02, SK_BurningRunner01-02, SK_BurningFireman* | mesh on walker / runner clips | M A D S (first mesh per Blueprint, mesh-only body on class clips) |
| 2 | Walker_Shocking / Runner_Shocking | SK_ShockingWalker01-03, SK_ShockingRunner01-03 | mesh on walker / runner clips | M A D S (first mesh per Blueprint, mesh-only body on class clips) |
| 2 | Walker_Caustic / Runner_Caustic | SK_WalkerMaleCaustic01-02, SK_RunnerMaleCaustic01-02 | mesh on walker / runner clips | M A D S (first mesh per Blueprint, mesh-only body on class clips) |
| 2 | Walker_Spiky / _Vicious, Runner_Spiky / _Vicious | SK_SpikyWalker01-03, SK_ViciousWalker01/03, SK_SpikyRunner01-03, SK_ViciousRunner01-03 | mesh on walker / runner clips | M A D S (first mesh per Blueprint, mesh-only body on class clips) |
| 2 | Walker_FuelTank (INCENDIARY) / WaterTank / Corrosive (CAUSTICWALKER) | SK_FuelTank01, SK_WaterTank01-03, SK_Corrosive01 (+ BP_EnemyTank_Walker_*) | mesh on walker clips | M A D S (first mesh per Blueprint, mesh-only body on class clips) |
| 2 | Walker_GrenadeVest (GRENADIER), InsectSwarm, Radio, RiotGear_* | SK_GrenadeVest01-05, SK_InsectSwarm01-02, SK_Radio01, SK_RiotGear* | mesh on walker clips | M A D S (first mesh per Blueprint, mesh-only body on class clips) |
| 3 | Thug_Inferno (INFERNOCRUSHER) | SK_ThugInferno01-03 | mesh on thug clips | - |
| 3 | Screamer_Electric (VOLTAICSCREAMER) | SK_ScreamerElectric01 | mesh on screamer clips | - |
| 3 | Slobber_Firestorm / Slobber_Putrefied | SK_SlobberFirestorm01, SK_SlobberPutrefied01 | mesh on slobber clips | - |
| 3 | Butcher_Vicious | SK_ButcherVicious01 | mesh on butcher clips | - |
| 3 | Thug variants (Generic B / FemThug, MilitaryThug, Bride, PalmTree "Crusher" meshes) | SK_ThugB01-04, SK_FemThugBasketball*, SK_MilitaryThug, SK_FemThugBride, SK_CrusherEx201-204 | mesh on thug clips | - |
| 4 | Whipper (Exp2) | SK_Oscar02 | own body `whipper` | - |
| 4 | Reformer (Exp2) | SK_Cameron01 | own body `reformer` | - |
| 5 | Mutator (apex: Untransformed -> Transformed) | SK_BaseMutator01, SK_Mutator01 (+ SK_Mutator_Transformation) | own body `mutator` | - |
| - | Cosmetic re-skins (Revenant, Haus, Reveal, PalmTree, WW2, outfit sets of Walker/Runner/Shambler) | see table below | mesh swaps, optional | - |

## archetypes.json provenance (coordinator: merge-only, 2026-10-08)
Only two merges may write game/data/archetypes.json: `tools/merge_archetype_loco.py` (locomotion speeds of rows whose
family has its own body; this worker) and convert_archetypes.py `attack_timing()` (hit_time / duration; locomotion
worker). Pre-merge backup: game/test_out/archetypes/archetypes.json.bak. A dry run of `tools/convert_archetypes.py`
(into scratch, 2026-10-08) differs from the current file only in these rows (hit times and locomotion excluded):

| Rows | Field | Current json | Converter (DA_AIAttributeValues_<Class>) |
|---|---|---|---|
| Screamer, Screamer_Revenant, Screamer_HausReveal | health / base_force / swipe damage / cooldown | 250 / none / 12 / 1.2 | 350 / 20 / 15 / 0.5 |
| Slobber (Slobber_Revenant: no health change) | health / base_force / swipe damage / cooldown | 300 / none / 12 / 1.2 | 450 / 30 / 20 / 0.5 |
| Butcher, Butcher_Revenant | health / base_force / knockdown / swipe damage / cooldown | 120 / none / [3.5, 5] / 12 / 1.2 | 400 / 25 / [3, 6] / 18 / 0.5 |
| Suicider | health / swipe damage | 120 / 12 | 80 / 10 |
| Mutator | health / base_force / swipe damage / cooldown | 450 / none / 12 / 1.2 | 750 / 40 / 25 / 0.25 |
| Whipper, Whipper_Revenant | health / base_force / swipe damage / cooldown | 120 / none / 12 / 1.2 | 400 / 25 / 15 / 1.0 |
(Grapple / Bite damage scale with the swipe damage: x1.5 / x0.7.)
Sub-variant with its own asset (coordinator follow-up): **Screamer_HausReveal** reads DA_AIAttributeValues_Screamer_HausReveal:
health 1100, BaseForce 20, BaseDamage 15; AttackSpacingDuration is left on bUseTypeDefaultValue, so the swipe / bite
cooldown is DA_AttributeType_AttackSpacingDuration.DefaultValue = 1.0. Its KnockdownDuration is a single DesiredValue 9.0
with no Min / Max range, and the converter only reads ranges, so the row keeps knockdown_duration [3.5, 5.0]
(UNVERIFIED 74). No other row has its own DA_AIAttributeValues asset (the *_Revenant, Haus, PalmTree, Reveal rows use the class asset).
**Merged 2026-10-08 (coordinator):** tools/merge_archetype_loco.py now writes the converter's values for these fields and rows (source: DA_AIAttributeValues_<Class>, the class before the first "_"; UNVERIFIED 73 closed). Explanation: every "current" value is the converter's own fallback for an archetype
without a DA_AIAttributeValues dump (health = BPC_MultiPartHealth MaxHealth, damage 12, spacing 1.2, no force,
knockdown [3.5, 5.0]), and the specials' DA_AIAttributeValues_* json first appear in extracted/json at 21:06 on
2026-10-08, after the file was generated. Walker / Runner / Shambler / Thug (dumped earlier) don't differ. The converter
also reads the class asset for sub-variants (`name.split("_")[0]`), although e.g. DA_AIAttributeValues_Screamer_HausReveal
exists.

## Full variant table (tools/list_archetypes.py)
| Blueprint | Parent | ModelVariation | Meshes (frequency) | CR | Perks |
|---|---|---|---|---|---|
| BP_Butcher_Generic | BP_Base_Butcher | DA_ModelVariation_Butcher_Generic | SK_Butcher01 (1), SK_Butcher02 (1), SK_Butcher03 (1) | None | DamageModifiers_Butcher, DamageModifiers_Special |
| BP_Butcher_Vicious | BP_Base_Butcher | DA_ModelVariation_Butcher_Vicious | SK_ButcherVicious01 (1) | 5.0 | ApplyBleedingOnHit_Butcher_Vicious, OnReceivingKickOrPunchApplyDamageAndBleedToCauser_Butcher_Vicious, AddAggressiveBuffInsteadOfFeeding_Butcher_Vicious, IncrementRightArmGore_Butcher_Vicious, IncrementLeftArmGore_Butcher_Vicious, ArmsGoreCosmetics_Butcher_Vicious, DamageModifiers_Butcher_Vicious, DamageModifiers_Special |
| BP_Butcher_Vicious_Revenant | BP_Base_Butcher | DA_ModelVariation_Butcher_Vicious_Revenant | SK_ButcherViciousRev (1) | 5.0 | ApplyBleedingOnHit_Butcher_Vicious, OnReceivingKickOrPunchApplyDamageAndBleedToCauser_Butcher_Vicious, AddAggressiveBuffInsteadOfFeeding_Butcher_Vicious, IncrementRightArmGore_Butcher_Vicious, IncrementLeftArmGore_Butcher_Vicious, ArmsGoreCosmetics_Butcher_Vicious, DamageModifiers_Butcher_Vicious, DamageModifiers_Revenant |
| BP_Mutator_Transformed | BP_Base_Mutator | DA_ModelVariation_Mutator_Transformed | SK_Mutator01 (1) | None |  |
| BP_Mutator_Untransformed | BP_Base_Mutator | DA_ModelVariation_Mutator_Untransformed | SK_BaseMutator01 (1) | None | PreTransformationDebuffs_Mutator_Untransformed |
| BP_Reformer_Generic | BP_Base_Reformer | DA_ModelVariation_Reformer | SK_Cameron01 (1) | None |  |
| BP_Runner_Army | BP_Base_Runner | DA_ModelVariation_Runner_Army | SK_RunnerMaleArmy01 (1), SK_RunnerMaleArmy02 (1), SK_RunnerFemaleArmy01 (1), SK_RunnerFemaleArmy02 (1) | None |  |
| BP_Runner_Beach | BP_Base_Runner | DA_ModelVariation_Runner_Beach | SK_RunnerFemSwim01 (1), SK_RunnerFemSwim02 (1), SK_RunnerFemSwim03 (1), SK_RunnerFemSwim04 (1), SK_RunnerFemSwim06 (1), SK_RunnerFemSwim07 (1), SK_RunnerMaleSwim01 (1), SK_RunnerMaleSwim02 (1), SK_RunnerMaleSwim03 (1), SK_RunnerMaleSwim04 (1), SK_RunnerFemSwim05 (1) | None |  |
| BP_Runner_Burning | BP_Base_Runner | DA_ModelVariation_Runner_Burning | SK_BurningRunner01 (1), SK_BurningRunner02 (1) | 2.5 | InfernoBody_Common, DamageDuringInfernoBody_Runner_Burning, OnReceivingKickApplyDamageAndFireToCauser_Runner_Burning |
| BP_Runner_Burning_WickerMan | BP_Base_Runner | DA_ModelVariation_Runner_Burning | SK_BurningRunner01 (1), SK_BurningRunner02 (1) | 2.5 | InfernoBody_Common, DamageDuringInfernoBody_Runner_Burning, OnReceivingKickApplyDamageAndFireToCauser_Runner_Burning |
| BP_Runner_CDC | BP_Base_Runner | DA_ModelVariation_Runner_CDC | SK_RunnerMaleCDC01 (1), SK_RunnerMaleCDC02 (1), SK_RunnerMaleCDC03 (1), SK_RunnerFemCDC01 (1), SK_RunnerFemCDC02 (1), SK_RunnerFemCDC03 (1) | None |  |
| BP_Runner_Casual | BP_Base_Runner | DA_ModelVariation_Runner_Casual | SK_RunnerFemCas01 (1), SK_RunnerFemCas02 (1), SK_RunnerFemCas03 (1), SK_RunnerFemCas04 (1), SK_RunnerFemCas05 (1), SK_RunnerFemCas06 (1), SK_RunnerFemCas07 (1), SK_RunnerFemCas08 (1), SK_RunnerFemCas09 (1), SK_RunnerMaleCas01 (1), SK_RunnerMaleCas02 (1), SK_RunnerMaleCas03 (1), SK_RunnerMaleCas04 (1), SK_RunnerMaleCas05 (1), SK_RunnerMaleCas06 (1), SK_RunnerMaleCas07 (1), SK_RunnerMaleCas08 (1), SK_RunnerMaleCas09 (1), SK_RunnerMaleCas10 (1), SK_RunnerFemCas10 (1), SK_RunnerFemCas11 (1) | None |  |
| BP_Runner_Fireman | BP_Base_Runner | DA_ModelVariation_Runner_Fireman | SK_BurningFiremanRunner01 (1), SK_BurningFiremanRunner02 (1), SK_BurningFiremanRunner03 (1) | 2.5 |  |
| BP_Runner_FoodService | BP_Base_Runner | DA_ModelVariation_Runner_Food | SK_RunnerFemFood01 (1) | None |  |
| BP_Runner_Glam | BP_Base_Runner | DA_ModelVariation_Runner_Glam | SK_RunnerFemGlam01 (1), SK_RunnerFemGlam02 (1), SK_RunnerFemGlam03 (1) | None |  |
| BP_Runner_HausCulDeSac | BP_Base_Runner | DA_ModelVariation_Runner_Haus_CulDeSac | SK_RunnerFemEx1Cul03 (1), SK_RunnerFemEx1Cul04 (1), SK_RunnerFemEx1Cul05 (1), SK_RunnerFemEx1Cul06 (1), SK_RunnerFemEx1Cul07 (1), SK_RunnerFemEx1Cul08 (1), SK_RunnerFemEx1Cul10 (1), SK_RunnerFemEx1Cul11 (1), SK_RunnerFemEx1Cul12 (1), SK_RunnerMaleEx1Cul03 (1), SK_RunnerMaleEx1Cul05 (1), SK_RunnerMaleEx1Cul06 (1), SK_RunnerMaleEx1Cul07 (1), SK_RunnerMaleEx1Cul08 (1), SK_RunnerMaleEx1Cul09 (1) | None |  |
| BP_Runner_HausDeeper | BP_Base_Runner | DA_ModelVariation_Runner_Haus_Deeper | SK_RunnerFemEx1Deep01 (1), SK_RunnerFemEx1Deep02 (1), SK_RunnerFemEx1Deep05 (1), SK_RunnerFemEx1Deep09 (1), SK_RunnerMaleEx1Deep01 (1), SK_RunnerMaleEx1Deep02 (1), SK_RunnerMaleEx1Deep04 (1), SK_RunnerMaleEx1Deep09 (1) | None |  |
| BP_Runner_HausDiner | BP_Base_Runner | DA_ModelVariation_Runner_Haus_Diner | SK_RunnerFemEx1Cul03 (1), SK_RunnerFemEx1Cul04 (1), SK_RunnerFemEx1Cul05 (1), SK_RunnerFemEx1Cul06 (1), SK_RunnerFemEx1Cul07 (1), SK_RunnerFemEx1Cul08 (1), SK_RunnerFemEx1Cul10 (1), SK_RunnerFemEx1Cul11 (1), SK_RunnerFemEx1Cul12 (1), SK_RunnerMaleEx1Cul03 (1), SK_RunnerMaleEx1Cul05 (1), SK_RunnerMaleEx1Cul06 (1), SK_RunnerMaleEx1Cul07 (1), SK_RunnerMaleEx1Cul08 (1), SK_RunnerMaleEx1Cul09 (1), SK_RunnerFemEx1Cul01 (1), SK_RunnerFemEx1Cul02 (1), SK_RunnerMaleEx1Cul01 (1), SK_RunnerMaleEx1Cul02 (1) | None |  |
| BP_Runner_HausFinale | BP_Base_Runner | DA_ModelVariation_Runner_Haus_Finale | SK_RunnerFemEx1Finale01 (1), SK_RunnerFemEx1Finale02 (1), SK_RunnerFemEx1Finale03 (1), SK_RunnerFemEx1Finale04 (1), SK_RunnerFemEx1Finale05 (1), SK_RunnerFemEx1Finale06 (1), SK_RunnerFemEx1Finale07 (1), SK_RunnerMaleEx1Finale01 (1), SK_RunnerMaleEx1Finale02 (1), SK_RunnerMaleEx1Finale03 (1), SK_RunnerMaleEx1Finale04 (1), SK_RunnerMaleEx1Finale05 (1), SK_RunnerMaleEx1Finale06 (1) | None |  |
| BP_Runner_HausForest | BP_Base_Runner | DA_ModelVariation_Runner_Haus_Forest | SK_RunnerFemEx1Cul03 (1), SK_RunnerFemEx1Cul04 (1), SK_RunnerFemEx1Cul05 (1), SK_RunnerFemEx1Cul06 (1), SK_RunnerFemEx1Cul07 (1), SK_RunnerFemEx1Cul08 (1), SK_RunnerFemEx1Cul10 (1), SK_RunnerFemEx1Cul11 (1), SK_RunnerFemEx1Cul12 (1), SK_RunnerMaleEx1Cul03 (1), SK_RunnerMaleEx1Cul05 (1), SK_RunnerMaleEx1Cul06 (1), SK_RunnerMaleEx1Cul07 (1), SK_RunnerMaleEx1Cul08 (1), SK_RunnerMaleEx1Cul09 (1), SK_RunnerFemEx1Cul01 (1), SK_RunnerFemEx1Cul02 (1), SK_RunnerMaleEx1Cul01 (1), SK_RunnerMaleEx1Cul02 (1) | None |  |
| BP_Runner_HausMainHall | BP_Base_Runner | DA_ModelVariation_Runner_Haus_MainHall | SK_RunnerFemEx1Latex03 (1), SK_RunnerFemEx1Latex04 (1), SK_RunnerFemEx1Latex05 (1), SK_RunnerFemEx1Latex06 (1), SK_RunnerFemEx1Latex07 (1), SK_RunnerFemEx1Latex08 (1), SK_RunnerFemEx1Latex09 (1), SK_RunnerFemEx1Latex10 (1), SK_RunnerFemEx1Latex11 (1), SK_RunnerFemEx1Latex12 (1), SK_RunnerFemEx1Latex13 (1), SK_RunnerMaleEx1Latex03 (1), SK_RunnerMaleEx1Latex04 (1), SK_RunnerMaleEx1Latex05 (1), SK_RunnerMaleEx1Latex06 (1), SK_RunnerMaleEx1Latex07 (1), SK_RunnerMaleEx1Latex08 (1), SK_RunnerMaleEx1Latex09 (1) | None |  |
| BP_Runner_Haus_Corpse | BP_Base_Runner | DA_ModelVariation_Runner_Haus_CorpseAcid | SK_CorpseAcidEx1 (1) | 2.5 | InfernoBody_Common, DamageDuringInfernoBody_Runner_Burning, OnReceivingKickApplyDamageAndFireToCauser_Runner_Burning |
| BP_Runner_LAPD | BP_Base_Runner | DA_ModelVariation_Runner_LAPD | SK_RunnerMaleLAPD01 (1), SK_RunnerMaleLAPD02 (1), SK_RunnerMaleLAPD03 (1) | None |  |
| BP_Runner_Lifeguard | BP_Base_Runner | DA_ModelVariation_Runner_Lifeguard | SK_RunnerFemLife01 (1), SK_RunnerMaleLife01 (1) | None |  |
| BP_Runner_LootSatchel | BP_Base_Runner | DA_ModelVariation_Runner_LootSatchel | SK_LootSatchel01 (1), SK_LootSatchel02 (1), SK_LootSatchel03 (1) | None |  |
| BP_Runner_MeatSlurry | BP_Base_Runner | DA_ModelVariation_Runner_Slurry | SK_RunnerFemMeatSlurry01 (1), SK_RunnerFemMeatSlurry02 (1), SK_RunnerFemMeatSlurry03 (1) | None |  |
| BP_Runner_Medical | BP_Base_Runner | DA_ModelVariation_Runner_Med | SK_RunnerFemMed01 (1), SK_RunnerMaleMed01 (1), SK_RunnerMaleMed02 (1), SK_RunnerFemMed02 (1) | None |  |
| BP_Runner_Metro | BP_Base_Runner | DA_ModelVariation_Runner_Sport | SK_RunnerFemSport01 (1), SK_RunnerFemSport02 (1), SK_RunnerFemSport03 (1), SK_RunnerFemSport04 (1), SK_RunnerFemSport05 (1), SK_RunnerFemSport06 (1), SK_RunnerMaleSport01 (1), SK_RunnerMaleSport02 (1) | None |  |
| BP_Runner_PalmTree_CasualFestival | BP_Base_Runner | DA_ModelVariation_Runner_PalmTree_CasualFestival | SK_RunnerMaleEx2Cas01 (1), SK_RunnerMaleEx2Cas02 (1), SK_RunnerMaleEx2Cas03 (1), SK_RunnerMaleEx2Cas04 (1), SK_RunnerFemEx2Cas01 (1), SK_RunnerFemEx2Cas02 (1), SK_RunnerFemEx2Cas03 (1), SK_RunnerFemEx2Cas04 (1), SK_RunnerFemEx2Cas05 (1), SK_RunnerMaleEx2Stage01 (0.5), SK_RunnerMaleEx2Stage02 (0.5), SK_RunnerMaleEx2Stage03 (0.5), SK_RunnerFemEx2Stage01 (0.5), SK_RunnerFemEx2Stage02 (0.5), SK_RunnerFemEx2Stage03 (0.5), SK_RunnerFemEx2Food01 (0.5), SK_RunnerMaleEx2Food01 (0.5), SK_RunnerMaleEx2Food02 (0.5), SK_RunnerFemEx2Cas06 (1), SK_RunnerFemEx2Cas07 (1), SK_RunnerFemEx2Cas08 (1), SK_RunnerMaleEx2Cas05 (1), SK_RunnerMaleEx2Cas06 (1), SK_RunnerMaleEx2Cas07 (1) | None | Aggressive_Exp2 |
| BP_Runner_PalmTree_Club | BP_Base_Runner | DA_ModelVariation_Runner_PalmTree_Club | SK_RunnerFemEx2Spr01 (1), SK_RunnerFemEx2Spr02 (1), SK_RunnerFemEx2Spr03 (1), SK_RunnerFemEx2Spr04 (1), SK_RunnerFemEx2Spr05 (1), SK_RunnerFemEx2Spr06 (1), SK_RunnerFemEx2Spr07 (1), SK_RunnerMaleEx2Spr01 (1), SK_RunnerMaleEx2Spr02 (1), SK_RunnerMaleEx2Spr03 (1), SK_RunnerMaleEx2Spr04 (1), SK_RunnerMaleEx2Spr05 (1), SK_RunnerMaleEx2Spr06 (1), SK_RunnerMaleEx2Spr07 (1) | None | Aggressive_Exp2 |
| BP_Runner_PalmTree_Swimwear | BP_Base_Runner | DA_ModelVariation_Runner_PalmTree_Swimwear | SK_RunnerFemEx2Spr01 (1), SK_RunnerFemEx2Spr02 (1), SK_RunnerFemEx2Spr03 (1), SK_RunnerFemEx2Spr04 (1), SK_RunnerFemEx2Spr05 (1), SK_RunnerFemEx2Spr06 (1), SK_RunnerFemEx2Spr07 (1), SK_RunnerMaleEx2Spr01 (1), SK_RunnerMaleEx2Spr02 (1), SK_RunnerMaleEx2Spr03 (1), SK_RunnerMaleEx2Spr04 (1) | None | Aggressive_Exp2 |
| BP_Runner_PalmTree_VIP | BP_Base_Runner | DA_ModelVariation_Runner_PalmTree_VIP | SK_RunnerFemEx2VIP01 (1), SK_RunnerFemEx2VIP02 (1), SK_RunnerFemEx2VIP03 (1), SK_RunnerFemEx2VIP04 (1), SK_RunnerFemEx2VIP05 (1), SK_RunnerMaleEx2VIP01 (1), SK_RunnerMaleEx2VIP02 (1), SK_RunnerMaleEx2VIP03 (1), SK_RunnerMaleEx2VIP04 (1) | None | Aggressive_Exp2 |
| BP_Runner_Sewer | BP_Base_Runner | DA_ModelVariation_Runner_Sewer | SK_RunnerMaleSewer01 (1), SK_RunnerMaleSewer02 (1), SK_RunnerMaleSewerCas01 (1), SK_RunnerMaleSewerCas02 (1), SK_RunnerMaleSewerCas03 (1), SK_RunnerMaleSewerCas04 (1), SK_RunnerMaleSewerCas05 (1), SK_RunnerFemSewerCas01 (1), SK_RunnerFemSewerCas02 (1), SK_RunnerFemSewerCas03 (1), SK_RunnerFemSewerCas04 (1), SK_RunnerFemSewerCas05 (1) | None |  |
| BP_Runner_Shocking | BP_Base_Runner | DA_ModelVariation_Runner_Shocking | SK_ShockingRunner01 (1), SK_ShockingRunner02 (1), SK_ShockingRunner03 (1) | 2.5 | ShockingBuildUp_Runner_Shocking |
| BP_Runner_Spiky | BP_Base_Runner | DA_ModelVariation_Runner_Spiky | SK_SpikyRunner01 (1), SK_SpikyRunner02 (1), SK_SpikyRunner03 (1) | 2.5 | OnReceivingKickApplyDamageAndBleedToCauser_Runner_Spiky, ApplyBleedingOnHit_Runner_Spiky |
| BP_Runner_Sportswear | BP_Base_Runner | DA_ModelVariation_Runner_Sport | SK_RunnerFemSport01 (1), SK_RunnerFemSport02 (1), SK_RunnerFemSport03 (1), SK_RunnerFemSport04 (1), SK_RunnerFemSport05 (1), SK_RunnerFemSport06 (1), SK_RunnerMaleSport01 (1), SK_RunnerMaleSport02 (1) | None |  |
| BP_Runner_WW2 | BP_Base_Runner | DA_ModelVariation_Runner_WW2 | SK_RunnerMaleWW2FilmSet01 (1) | None |  |
| BP_Runner_Wedding | BP_Base_Runner | DA_ModelVariation_Runner_Wedding | SK_RunnerFemWed01 (1) | None |  |
| BP_Screamer_Electric | BP_Base_Screamer | DA_ModelVariation_Screamer_Electric | SK_ScreamerElectric01 (1) | 4.0 | AttachCosmeticEffectWhenScreaming_Screamer_Electric, ApplyElectricOnHit_Screamer_Electric, DamageModifiers_Screamer_Electric, DamageModifiers_Special |
| BP_Screamer_Electric_Revenant | BP_Base_Screamer | DA_ModelVariation_Screamer_Electric_Revenant | SK_ScreamerElectricRev (1) | 4.0 | AttachCosmeticEffectWhenScreaming_Screamer_Electric, ApplyElectricOnHit_Screamer_Electric, DamageModifiers_Screamer_Electric, DamageModifiers_Revenant |
| BP_Screamer_Generic | BP_Base_Screamer | DA_ModelVariation_Screamer_Generic | SK_Screamer01 (1), SK_Screamer02 (1), SK_Screamer03 (1) | None | AttachCosmeticEffectWhenScreaming_Screamer, DamageModifiers_Screamer, DamageModifiers_Special |
| BP_Shambler_Army | BP_Base_Shambler | DA_ModelVariation_Shambler_Army | SK_ShamMaleArmy01 (1), SK_ShamMaleArmy02 (1), SK_ShamMaleArmy03 (1) | None |  |
| BP_Shambler_Beach | BP_Base_Shambler | DA_ModelVariation_Shambler_Beach | SK_ShamMaleSwim01 (1), SK_ShamMaleSwim02 (1), SK_ShamFemSwim01 (1), SK_ShamFemSwim02 (1), SK_ShamFemSwim03 (1), SK_ShamMaleSwim03 (1) | None |  |
| BP_Shambler_Casual | BP_Base_Shambler | DA_ModelVariation_Shambler_Casual | SK_ShamFemCas01 (1), SK_ShamFemCas02 (1), SK_ShamFemCas03 (1), SK_ShamFemCas05 (1), SK_ShamMaleCas02 (1), SK_ShamMaleCas03 (1), SK_ShamFemCas06 (1), SK_ShamMaleCas01 (1), SK_ShamFemCas04 (1) | None |  |
| BP_Shambler_Glam | BP_Base_Shambler | DA_ModelVariation_Shambler_Glam | SK_ShamFemGlam01 (1), SK_ShamFemGlam02 (1), SK_ShamMaleGlam01 (1), SK_ShamMaleGlam02 (1) | None |  |
| BP_Shambler_Haus | BP_Base_Shambler | DA_ModelVariation_Shambler_Haus | SK_ShamFemEx1Cas01 (1), SK_ShamFemEx1Cas02 (1), SK_ShamFemEx1Cas03 (1), SK_ShamFemEx1Cas04 (1), SK_ShamFemEx1Cas05 (1), SK_ShamFemEx1Cas06 (1), SK_ShamFemEx1Cas07 (1), SK_ShamFemEx1Cas08 (1), SK_ShamMaleEx1Cas01 (1), SK_ShamMaleEx1Cas02 (1), SK_ShamMaleEx1Cas03 (1), SK_ShamMaleEx1Cas04 (1), SK_ShamMaleEx1Cas05 (1) | None |  |
| BP_Shambler_LAPD | BP_Base_Shambler | DA_ModelVariation_Shambler_LAPD | SK_ShamMaleLAPD01 (1), SK_ShamMaleLAPD02 (1) | None |  |
| BP_Shambler_Lifeguard | BP_Base_Shambler | DA_ModelVariation_Shambler_Lifeguard | SK_ShamMaleLife01 (1), SK_ShamFemLife01 (1) | None |  |
| BP_Shambler_MeatSlurry | BP_Base_Shambler | DA_ModelVariation_Shambler_Slurry | SK_ShamMaleMeatSlurry01 (1), SK_ShamMaleMeatSlurry02 (1), SK_ShamMaleMeatSlurry03 (1) | None |  |
| BP_Shambler_Medical | BP_Base_Shambler | DA_ModelVariation_Shambler_Med | SK_ShamMaleMed01 (1), SK_ShamMaleMed02 (1) | None |  |
| BP_Shambler_PalmTree_CasualFestival | BP_Base_Shambler | DA_ModelVariation_Shambler_PalmTree_CasualFestival | SK_ShamFemEx2Cas01 (1), SK_ShamFemEx2Cas02 (1), SK_ShamFemEx2Cas03 (1), SK_ShamFemEx2Cas04 (1), SK_ShamFemEx2Cas05 (1), SK_ShamMaleEx2Cas01 (1), SK_ShamMaleEx2Cas02 (1), SK_ShamMaleEx2Cas03 (1), SK_ShamMaleEx2Cas04 (1), SK_ShamMaleEx2Cas05 (1) | None | Aggressive_Exp2 |
| BP_Shambler_PalmTree_Club | BP_Base_Shambler | DA_ModelVariation_Shambler_PalmTree_Club | SK_ShamFemEx2Spr01 (1), SK_ShamFemEx2Spr02 (1), SK_ShamFemEx2Spr03 (1), SK_ShamMaleEx2Spr01 (1), SK_ShamMaleEx2Spr02 (1), SK_ShamMaleEx2Spr03 (1), SK_ShamFemEx2Spr04 (1) | None | Aggressive_Exp2 |
| BP_Shambler_PalmTree_Swimwear | BP_Base_Shambler | DA_ModelVariation_Shambler_PalmTree_Swimwear | SK_ShamFemEx2Spr01 (1), SK_ShamFemEx2Spr02 (1), SK_ShamFemEx2Spr03 (1), SK_ShamMaleEx2Spr01 (1), SK_ShamMaleEx2Spr02 (1), SK_ShamMaleEx2Spr03 (1) | None | Aggressive_Exp2 |
| BP_Shambler_PalmTree_VIP | BP_Base_Shambler | DA_ModelVariation_Shambler_PalmTree_VIP | SK_ShamFemEx2VIP01 (1), SK_ShamFemEx2VIP02 (1), SK_ShamFemEx2VIP03 (1), SK_ShamMaleEx2VIP01 (1), SK_ShamMaleEx2VIP02 (1), SK_ShamMaleEx2VIP03 (1) | None | Aggressive_Exp2 |
| BP_Shambler_Sewer | BP_Base_Shambler | DA_ModelVariation_Shambler_Sewer | SK_ShamMaleSewer01 (1), SK_ShamMaleCas01 (1), SK_ShamMaleCas02 (1), SK_ShamMaleCas03 (1), SK_ShamFemCas01 (1), SK_ShamFemCas02 (1), SK_ShamFemCas03 (1), SK_ShamFemCas04 (1), SK_ShamFemCas05 (1), SK_ShamFemCas06 (1) | None |  |
| BP_Shambler_Smart | BP_Base_Shambler | DA_ModelVariation_Shambler_Smart | SK_ShamMaleCas02 (1), SK_ShamMaleCas03 (1), SK_ShamFemCas01 (1), SK_ShamFemCas02 (1), SK_ShamFemCas03 (1), SK_ShamFemCas05 (1), SK_ShamMaleGlam01 (1), SK_ShamMaleGlam02 (1) | None |  |
| BP_Shambler_WW2 | BP_Base_Shambler | DA_ModelVariation_Shambler_WW2 | SK_ShamMaleWW2Filmset01 (1), SK_ShamMaleWW2Filmset02 (1), SK_ShamMaleWW2Filmset03 (1) | None |  |
| BP_Slobber_Firestorm | BP_Base_Slobber | DA_ModelVariation_Slobber_Firestorm | SK_SlobberFirestorm01 (1) | 4.0 | AttachCosmeticEffectWhenSpewing_Slobber_Firestorm, AttachCosmeticEffectWhenSpitting_Slobber_Firestorm, SpawnAndAttachCosmeticSmokeOnImpact_Slobber_Firestorm, ApplyBurningOnHit_Slobber_Firestorm, DamageModifiers_Slobber_Firestorm, AttachCosmeticEffectWhenGrappleVomitting_Slobber_Firestorm, TrackProjectileAccuracy_Slobber_Firestorm, DamageModifiers_Special |
| BP_Slobber_Firestorm_Revenant | BP_Base_Slobber | DA_ModelVariation_Slobber_Firestorm_Revenant | SK_SlobberFirestormRev (1) | 4.0 | AttachCosmeticEffectWhenSpewing_Slobber_Firestorm, AttachCosmeticEffectWhenSpitting_Slobber_Firestorm, SpawnAndAttachCosmeticSmokeOnImpact_Slobber_Firestorm, ApplyBurningOnHit_Slobber_Firestorm, DamageModifiers_Slobber_Firestorm, AttachCosmeticEffectWhenGrappleVomitting_Slobber_Firestorm, TrackProjectileAccuracy_Slobber_Firestorm, DamageModifiers_Revenant |
| BP_Slobber_Generic | BP_Base_Slobber | DA_ModelVariation_Slobber_Generic | SK_SlobberA (1) | None | AttachCosmeticEffectWhenSpewing_Slobber_Generic, AttachCosmeticEffectWhenSpitting_Slobber_Generic, DamageModifiers_Slobber, AttachCosmeticEffectWhenGrappleVomitting_Slobber_Generic, TrackProjectileAccuracy_Slobber_Generic, DamageModifiers_Special |
| BP_Slobber_Putrefied | BP_Base_Slobber | DA_ModelVariation_Slobber_Putrefied | SK_SlobberPutrefied01 (1) | None | DamageModifiers_Slobber_Putrefied, AttachCosmeticEffectWhenGrappleVomitting_Slobber_Putrefied, AttachCosmeticEffectWhenSpitting_Slobber_Putrefied, TrackProjectileAccuracy_Slobber_Putrefied, DamageModifiers_Special |
| BP_Suicider_Generic | BP_Base_Suicider | DA_ModelVariation_Suicider_Generic | SK_SuiciderA (1) | None | DamageModifiers_Suicider |
| BP_Thug_Generic | BP_Base_Thug | DA_ModelVariation_Thug_Generic | SK_ThugA01 (1), SK_ThugA02 (1), SK_ThugA03 (1), SK_ThugB01 (1), SK_ThugB02 (1), SK_ThugB03 (1), SK_ThugB04 (1), SK_FemThugBasketball (1.3), SK_FemThugBasketball02 (1.3), SK_FemThugBasketball03 (1.3) | None | DamageModifiers_Thug, DamageModifiers_Special |
| BP_Thug_Inferno | BP_Base_Thug | DA_ModelVariation_Thug_Inferno | SK_ThugInferno01 (1), SK_ThugInferno02 (1), SK_ThugInferno03 (1) | 4.0 | InfernoArms_Thug_Inferno, DamageDuringInfernoArms_Thug_Inferno, IgniteSurroundingAreaFromRoar_Thug_Inferno, DamageModifiers_Thug_Inferno, DamageModifiers_Special |
| BP_Thug_Inferno_Revenant | BP_Base_Thug | DA_ModelVariation_Thug_Inferno_Revenant | SK_ThugRevInferno (1) | 4.0 | InfernoArms_Thug_Inferno, DamageDuringInfernoArms_Thug_Inferno, IgniteSurroundingAreaFromRoar_Thug_Inferno, DamageModifiers_Thug_Inferno_Revenant, DamageModifiers_Revenant |
| BP_Walker_Army | BP_Base_Walker | DA_ModelVariation_Walker_Army | SK_WalkerMaleArmy01 (1), SK_WalkerMaleArmy02 (1), SK_WalkerMaleArmy03 (1), SK_WalkerMaleArmy04 (1), SK_WalkerMaleArmy05 (1), SK_WalkerMaleArmy06 (1), SK_WalkerMaleArmy07 (1), SK_WalkerFemArmy01 (1), SK_WalkerFemArmy02 (1) | None |  |
| BP_Walker_Beach | BP_Base_Walker | DA_ModelVariation_Walker_Beach | SK_WalkerFemSwim01 (1), SK_WalkerFemSwim02 (1), SK_WalkerFemSwim03 (1), SK_WalkerFemSwim05 (1), SK_WalkerFemaleLrg01 (1), SK_WalkerFemaleLrg02 (1), SK_WalkerMaleLrg01 (1), SK_WalkerMaleSwim01 (1), SK_WalkerFemSwim04 (1) | None |  |
| BP_Walker_Burning | BP_Base_Walker | DA_ModelVariation_Walker_Burning | SK_BurningWalker01 (1), SK_BurningWalker02 (1) | 2.0 | InfernoBody_Common, DamageDuringInfernoBody_Walker_Burning, OnReceivingKickApplyDamageAndFireToCauser_Walker_Burning |
| BP_Walker_CDC | BP_Base_Walker | DA_ModelVariation_Walker_CDC | SK_WalkerMaleCDC01 (1), SK_WalkerMaleCDC02 (1), SK_WalkerMaleCDC03 (1), SK_WalkerMaleCDC04 (1), SK_WalkerFemCDC01 (1), SK_WalkerFemCDC02 (1), SK_WalkerFemCDC03 (1) | None |  |
| BP_Walker_Casual | BP_Base_Walker | DA_ModelVariation_Walker_Casual | SK_WalkerMaleCas01 (1), SK_WalkerMaleCas02 (1), SK_WalkerMaleCas03 (1), SK_WalkerMaleCas04 (1), SK_WalkerMaleCas05 (1), SK_WalkerMaleCas06 (1), SK_WalkerMaleCas07 (1), SK_WalkerMaleCas08 (1), SK_WalkerMaleCas09 (1), SK_WalkerMaleCas10 (1), SK_WalkerMaleCas11 (1), SK_WalkerMaleCas12 (1), SK_WalkerFemCas01 (1), SK_WalkerFemCas02 (1), SK_WalkerFemCas03 (1), SK_WalkerFemCas04 (1), SK_WalkerFemCas05 (1), SK_WalkerFemCas06 (1), SK_WalkerFemCas08 (1), SK_WalkerFemCas09 (1), SK_WalkerFemCas10 (1), SK_WalkerFemCas11 (1), SK_WalkerMaleLrg02 (1), SK_WalkerFemCas07 (1), SK_WalkerMaleLrg03 (1), SK_WalkerFemaleLrg03 (1), SK_WalkerMaleCas13 (1), SK_WalkerMaleCas14 (1), SK_WalkerMaleCas15 (1), SK_WalkerMaleCas16 (1), SK_WalkerFemaleLrg04 (1), SK_WalkerFemaleLrg05 (1), SK_WalkerMaleLrg04 (1), SK_WalkerMaleLrg05 (1), SK_WalkerFemaleLrg06 (1), SK_WalkerFemaleLrg07 (1), SK_WalkerFemCas12 (1), SK_WalkerFemCas13 (1), SK_WalkerFemCas14 (1), SK_WalkerFemCas15 (1) | None |  |
| BP_Walker_Corrosive | BP_Base_Walker | DA_ModelVariation_Walker_Corrosive | SK_Corrosive01 (1) | 1.5 | ApplyCorrodedOnHit_Walker_Corrosive |
| BP_Walker_FilmSet | BP_Base_Walker | DA_ModelVariation_Walker_Filmset | SK_WalkerFemFilmset01 (1), SK_WalkerFemFilmset02 (1), SK_WalkerFemFilmset03 (1), SK_WalkerFemFilmset04 (1), SK_WalkerFemFilmset05 (1), SK_WalkerMaleFilmSet01 (1), SK_WalkerMaleFilmSet02 (1), SK_WalkerMaleFilmSet03 (1), SK_WalkerMaleFilmSet04 (1), SK_WalkerMaleFilmSet05 (1) | None |  |
| BP_Walker_FilmSet_Spider | BP_Base_Walker | DA_ModelVariation_Walker_Filmset_Spider | SK_WalkerMaleSpid01 (1), SK_WalkerMaleSpid02 (1), SK_WalkerMaleSpid03 (1), SK_WalkerMaleSpid04 (1), SK_WalkerMaleSpid05 (1) | None |  |
| BP_Walker_Fireman | BP_Base_Walker | DA_ModelVariation_Walker_Fireman | SK_BurningFiremanWalker01 (1), SK_BurningFiremanWalker02 (1) | 2.0 |  |
| BP_Walker_FoodService | BP_Base_Walker | DA_ModelVariation_Walker_Food | SK_WalkerMaleFood01 (1), SK_WalkerFemFood01 (1), SK_WalkerFemFood02 (1), SK_WalkerFemFood03 (1) | None |  |
| BP_Walker_FuelTank | BP_Base_Walker | DA_ModelVariation_Walker_FuelTank | SK_FuelTank01 (1) | 1.5 |  |
| BP_Walker_Glam | BP_Base_Walker | DA_ModelVariation_Walker_Glam | SK_WalkerFemGlam01 (1), SK_WalkerFemGlam02 (1), SK_WalkerFemGlam03 (1), SK_WalkerFemGlam04 (1), SK_WalkerFemGlam05 (1), SK_WalkerMaleGlam01 (1), SK_WalkerMaleGlam02 (1), SK_WalkerMaleGlam03 (1), SK_WalkerMaleGlam04 (1) | None |  |
| BP_Walker_GrenadeVest | BP_Base_Walker | DA_ModelVariation_Walker_GrenadeVest | SK_GrenadeVest01 (1), SK_GrenadeVest02 (1), SK_GrenadeVest03 (1), SK_GrenadeVest04 (1), SK_GrenadeVest05 (1) | 1.5 |  |
| BP_Walker_HausCulDeSac | BP_Base_Walker | DA_ModelVariation_Walker_Haus_CulDeSac | SK_WalkerMaleEx1Cul03 (1), SK_WalkerMaleEx1Cul05 (1), SK_WalkerMaleEx1Cul06 (1), SK_WalkerMaleEx1Cul07 (1), SK_WalkerMaleEx1Cul08 (1), SK_WalkerMaleEx1Cul09 (1), SK_WalkerFemEx1Cul03 (1), SK_WalkerFemEx1Cul04 (1), SK_WalkerFemEx1Cul05 (1), SK_WalkerFemEx1Cul06 (1), SK_WalkerFemEx1Cul07 (1), SK_WalkerFemEx1Cul08 (1), SK_WalkerFemEx1Cul10 (1), SK_WalkerFemEx1Cul11 (1), SK_WalkerFemEx1Cul12 (1) | None |  |
| BP_Walker_HausDeeper | BP_Base_Walker | DA_ModelVariation_Walker_Haus_Deeper | SK_WalkerFemEx1Deep01 (1), SK_WalkerFemEx1Deep02 (1), SK_WalkerFemEx1Deep09 (1), SK_WalkerFemEx1Deep13 (1), SK_WalkerMaleEx1Deep01 (1), SK_WalkerMaleEx1Deep02 (1), SK_WalkerMaleEx1Deep05 (1), SK_WalkerMaleEx1Deep09 (1) | None |  |
| BP_Walker_HausDiner | BP_Base_Walker | DA_ModelVariation_Walker_Haus_Diner | SK_WalkerMaleEx1Cul03 (1), SK_WalkerMaleEx1Cul05 (1), SK_WalkerMaleEx1Cul06 (1), SK_WalkerMaleEx1Cul07 (1), SK_WalkerMaleEx1Cul08 (1), SK_WalkerMaleEx1Cul09 (1), SK_WalkerFemEx1Cul03 (1), SK_WalkerFemEx1Cul04 (1), SK_WalkerFemEx1Cul05 (1), SK_WalkerFemEx1Cul06 (1), SK_WalkerFemEx1Cul07 (1), SK_WalkerFemEx1Cul08 (1), SK_WalkerFemEx1Cul10 (1), SK_WalkerFemEx1Cul11 (1), SK_WalkerFemEx1Cul12 (1), SK_WalkerFemEx1Cul01 (1), SK_WalkerFemEx1Cul02 (1), SK_WalkerMaleEx1Cul01 (1), SK_WalkerMaleEx1Cul02 (1) | None |  |
| BP_Walker_HausFinale | BP_Base_Walker | DA_ModelVariation_Walker_Haus_Finale | SK_WalkerFemEx1Finale01 (1), SK_WalkerFemEx1Finale02 (1), SK_WalkerFemEx1Finale03 (1), SK_WalkerFemEx1Finale04 (1), SK_WalkerFemEx1Finale05 (1), SK_WalkerFemEx1Finale06 (1), SK_WalkerFemEx1Finale07 (1), SK_WalkerMaleEx1Finale01 (1), SK_WalkerMaleEx1Finale02 (1), SK_WalkerMaleEx1Finale03 (1), SK_WalkerMaleEx1Finale04 (1), SK_WalkerMaleEx1Finale05 (1), SK_WalkerMaleEx1Finale06 (1) | None |  |
| BP_Walker_HausForest | BP_Base_Walker | DA_ModelVariation_Walker_Haus_Forest | SK_WalkerMaleEx1Cul03 (1), SK_WalkerMaleEx1Cul05 (1), SK_WalkerMaleEx1Cul06 (1), SK_WalkerMaleEx1Cul07 (1), SK_WalkerMaleEx1Cul08 (1), SK_WalkerMaleEx1Cul09 (1), SK_WalkerFemEx1Cul03 (1), SK_WalkerFemEx1Cul04 (1), SK_WalkerFemEx1Cul05 (1), SK_WalkerFemEx1Cul06 (1), SK_WalkerFemEx1Cul07 (1), SK_WalkerFemEx1Cul08 (1), SK_WalkerFemEx1Cul10 (1), SK_WalkerFemEx1Cul11 (1), SK_WalkerFemEx1Cul12 (1), SK_WalkerFemEx1Cul01 (1), SK_WalkerFemEx1Cul02 (1), SK_WalkerMaleEx1Cul01 (1), SK_WalkerMaleEx1Cul02 (1) | None |  |
| BP_Walker_HausMainHall | BP_Base_Walker | DA_ModelVariation_Walker_Haus_MainHall | SK_WalkerFemEx1Latex03 (1), SK_WalkerFemEx1Latex04 (1), SK_WalkerFemEx1Latex05 (1), SK_WalkerFemEx1Latex06 (1), SK_WalkerFemEx1Latex07 (1), SK_WalkerFemEx1Latex08 (1), SK_WalkerFemEx1Latex09 (1), SK_WalkerFemEx1Latex10 (1), SK_WalkerFemEx1Latex11 (1), SK_WalkerFemEx1Latex12 (1), SK_WalkerFemEx1Latex13 (1), SK_WalkerMaleEx1Latex03 (1), SK_WalkerMaleEx1Latex04 (1), SK_WalkerMaleEx1Latex05 (1), SK_WalkerMaleEx1Latex06 (1), SK_WalkerMaleEx1Latex07 (1), SK_WalkerMaleEx1Latex08 (1), SK_WalkerMaleEx1Latex09 (1) | None |  |
| BP_Walker_Hills | BP_Base_Walker | DA_ModelVariation_Walker_Hills | SK_WalkerFemHills01 (1), SK_WalkerFemHills02 (1), SK_WalkerFemHills03 (1), SK_WalkerFemHills04 (1), SK_WalkerFemHills05 (1), SK_WalkerFemHills06 (1), SK_WalkerFemHills07 (1), SK_WalkerMaleHills01 (1), SK_WalkerMaleHills02 (1), SK_WalkerMaleHills03 (1), SK_WalkerMaleHills04 (1), SK_WalkerMaleHills05 (1), SK_WalkerMaleHills06 (1), SK_WalkerMaleHills07 (1), SK_WalkerMaleHills08 (1), SK_WalkerMaleHills09 (1) | None |  |
| BP_Walker_Hotel | BP_Base_Walker | DA_ModelVariation_Walker_Hotel | SK_WalkerFemHal01 (1), SK_WalkerFemHal02 (1), SK_WalkerMaleHal01 (1), SK_WalkerMaleHal02 (1) | None |  |
| BP_Walker_InsectSwarm | BP_Base_Walker | DA_ModelVariation_Walker_InsectSwarm | SK_InsectSwarm01 (1), SK_InsectSwarm02 (1) | 2.0 | ReduceAggressionAndSpeedWhileHiveIsActive_Walker_InsectSwarm, StopEngagementWhileCombatTargetIsNotClose_Walker_InsectSwarm |
| BP_Walker_LAPD | BP_Base_Walker | DA_ModelVariation_Walker_LAPD | SK_WalkerMaleLAPD01 (1), SK_WalkerMaleLAPD02 (1), SK_WalkerMaleLAPD03 (1), SK_WalkerMaleLAPD04 (1), SK_WalkerMaleLAPD05 (1), SK_WalkerFemLAPD01 (1), SK_WalkerFemLAPD02 (1), SK_WalkerFemLAPD03 (1) | None |  |
| BP_Walker_Lifeguard | BP_Base_Walker | DA_ModelVariation_Walker_Lifeguard | SK_WalkerFemLife01 (1), SK_WalkerMaleLife01 (1) | None |  |
| BP_Walker_MeatSlurry | BP_Base_Walker | DA_ModelVariation_Walker_Slurry | SK_WalkerMaleMeatSlurry01 (1), SK_WalkerMaleMeatSlurry02 (1), SK_WalkerMaleMeatSlurry03 (1) | None |  |
| BP_Walker_Medical | BP_Base_Walker | DA_ModelVariation_Walker_Med | SK_WalkerFemMed01 (1), SK_WalkerMaleMed01 (1), SK_WalkerFemMed02 (1), SK_WalkerFemMed03 (1), SK_WalkerFemMed04 (1), SK_WalkerMaleMed02 (1), SK_WalkerMaleMed03 (1), SK_WalkerMaleMed04 (1) | None |  |
| BP_Walker_Metro | BP_Base_Walker | DA_ModelVariation_Walker_Metro | SK_WalkerFemMetro01 (1), SK_WalkerFemMetro02 (1), SK_WalkerFemMetro03 (1), SK_WalkerMaleMetro01 (1), SK_WalkerMaleMetro02 (1), SK_WalkerMaleMetro03 (1) | None |  |
| BP_Walker_PalmTree_CasualFestival | BP_Base_Walker | DA_ModelVariation_Walker_PalmTree_CasualFestival | SK_WalkerMaleEx2Cas01 (1), SK_WalkerMaleEx2Cas02 (1), SK_WalkerMaleEx2Cas03 (1), SK_WalkerMaleEx2Cas04 (1), SK_WalkerFemEx2Cas01 (1), SK_WalkerFemEx2Cas02 (1), SK_WalkerFemEx2Cas03 (1), SK_WalkerFemEx2Cas04 (1), SK_WalkerFemEx2Stage01 (0.5), SK_WalkerFemStage02 (0.5), SK_WalkerMaleEx2Stage01 (0.5), SK_WalkerMaleEx2Stage02 (0.5), SK_WalkerMaleEx2Food01 (0.5), SK_WalkerMaleEx2Food02 (0.5), SK_WalkerFemEx2Food01 (0.5), SK_WalkerFemEx2Food02 (0.5), SK_WalkerFemEx2Cas05 (1), SK_WalkerFemEx2Cas06 (1), SK_WalkerFemEx2Cas07 (1), SK_WalkerFemEx2Cas08 (1), SK_WalkerMaleEx2Cas05 (1), SK_WalkerMaleEx2Cas06 (1), SK_WalkerMaleEx2Cas07 (1), SK_WalkerMaleEx2Cas08 (1) | None | Aggressive_Exp2 |
| BP_Walker_PalmTree_Club | BP_Base_Walker | DA_ModelVariation_Walker_PalmTree_Club | SK_WalkerFemEx2Spr01 (1), SK_WalkerFemEx2Spr02 (1), SK_WalkerFemEx2Spr03 (1), SK_WalkerFemEx2Spr04 (1), SK_WalkerFemEx2Spr05 (1), SK_WalkerMaleEx2Spr01 (1), SK_WalkerMaleEx2Spr02 (1), SK_WalkerMaleEx2Spr03 (1), SK_WalkerMaleEx2Spr04 (1), SK_WalkerMaleEx2Spr05 (1), SK_WalkerMaleEx2Spr06 (1) | None | Aggressive_Exp2 |
| BP_Walker_PalmTree_Swimwear | BP_Base_Walker | DA_ModelVariation_Walker_PalmTree_Swimwear | SK_WalkerFemEx2Spr01 (1), SK_WalkerFemEx2Spr02 (1), SK_WalkerFemEx2Spr03 (1), SK_WalkerFemEx2Spr04 (1), SK_WalkerFemEx2Spr05 (1), SK_WalkerMaleEx2Spr01 (1), SK_WalkerMaleEx2Spr02 (1) | None | Aggressive_Exp2 |
| BP_Walker_PalmTree_VIP | BP_Base_Walker | DA_ModelVariation_Walker_PalmTree_VIP | SK_WalkerFemEx2VIP01 (1), SK_WalkerFemEx2VIP02 (1), SK_WalkerFemEx2VIP03 (1), SK_WalkerFemEx2VIP04 (1), SK_WalkerFemEx2VIP05 (1), SK_WalkerMaleEx2VIP01 (1), SK_WalkerMaleEx2VIP02 (1), SK_WalkerMaleEx2VIP03 (1), SK_WalkerMaleEx2VIP04 (1) | None | Aggressive_Exp2 |
| BP_Walker_Radio | BP_Base_Walker | DA_ModelVariation_Walker_Radio | SK_Radio01 (1) | None |  |
| BP_Walker_Sewer | BP_Base_Walker | DA_ModelVariation_Walker_Sewer | SK_WalkerMaleSewer01 (1), SK_WalkerMaleCas01 (1), SK_WalkerMaleCas02 (1), SK_WalkerMaleCas03 (1), SK_WalkerMaleCas04 (1), SK_WalkerMaleCas05 (1), SK_WalkerMaleCas06 (1), SK_WalkerMaleCas07 (1), SK_WalkerMaleCas08 (1), SK_WalkerMaleCas09 (1), SK_WalkerMaleCas10 (1), SK_WalkerMaleCas11 (1), SK_WalkerMaleCas12 (1), SK_WalkerFemCas01 (1), SK_WalkerFemCas02 (1), SK_WalkerFemCas03 (1), SK_WalkerFemCas04 (1), SK_WalkerFemCas05 (1), SK_WalkerFemCas06 (1), SK_WalkerFemCas08 (1), SK_WalkerFemCas09 (1), SK_WalkerFemCas10 (1), SK_WalkerFemCas11 (1), SK_WalkerMaleLrg01 (1), SK_WalkerFemCas07 (1), SK_WalkerMaleLrg02 (1), SK_WalkerFemaleLrg03 (1), SK_WalkerMaleCas13 (1), SK_WalkerMaleCas14 (1), SK_WalkerMaleCas15 (1), SK_WalkerMaleCas16 (1), SK_WalkerFemaleLrg04 (1), SK_WalkerFemaleLrg05 (1), SK_WalkerMaleLrg04 (1), SK_WalkerMaleLrg05 (1), SK_WalkerFemaleLrg06 (1), SK_WalkerFemaleLrg07 (1), SK_WalkerFemCas12 (1), SK_WalkerFemCas13 (1), SK_WalkerFemCas14 (1), SK_WalkerFemCas15 (1) | None |  |
| BP_Walker_Shocking | BP_Base_Walker | DA_ModelVariation_Walker_Shocking | SK_ShockingWalker01 (1), SK_ShockingWalker02 (1), SK_ShockingWalker03 (1) | 2.0 | ShockingBuildUp_Walker_Shocking |
| BP_Walker_Smart | BP_Base_Walker | DA_ModelVariation_Walker_Smart | SK_WalkerFemSmart01 (1), SK_WalkerFemSmart02 (1), SK_WalkerMaleSmart01 (1), SK_WalkerMaleSmart02 (1), SK_WalkerFemSmart03 (1), SK_WalkerFemSmart04 (1), SK_WalkerMaleSmart03 (1), SK_WalkerMaleSmart04 (1) | None |  |
| BP_Walker_Spiky | BP_Base_Walker | DA_ModelVariation_Walker_Spiky | SK_SpikyWalker01 (1), SK_SpikyWalker02 (1), SK_SpikyWalker03 (1) | 2.0 | OnReceivingKickApplyDamageAndBleedToCauser_Walker_Spiky, ApplyBleedingOnHit_Walker_Spiky |
| BP_Walker_Sportswear | BP_Base_Walker | DA_ModelVariation_Walker_Sport | SK_WalkerMaleSport02 (1), SK_WalkerMaleSport01 (1), SK_WalkerMaleSport03 (1), SK_WalkerFemSport01 (1), SK_WalkerFemSport02 (1), SK_WalkerFemSport03 (1), SK_WalkerFemSport04 (1) | None |  |
| BP_Walker_WW2 | BP_Base_Walker | DA_ModelVariation_Walker_WW2 | SK_WalkerMaleWW2FilmSet01 (1), SK_WalkerMaleWW2FilmSet02 (1), SK_WalkerMaleWW2FilmSet03 (1) | None |  |
| BP_Walker_WaterTank | BP_Base_Walker | DA_ModelVariation_Walker_WaterTank | SK_WaterTank01 (1), SK_WaterTank02 (1), SK_WaterTank03 (1) | 1.5 |  |
| BP_Walker_Wedding | BP_Base_Walker | DA_ModelVariation_Walker_Wedding | SK_WalkerFemWed01 (1), SK_WalkerFemWed02 (1), SK_WalkerMaleWed01 (1), SK_WalkerMaleWed02 (1), SK_WalkerMaleWed03 (1) | None |  |
| BP_Walker_RiotGear_Light | BP_Base_Walker_RiotGear | DA_ModelVariation_Walker_RiotGear_Light | SK_RiotGearHelmetTorso (1) | 2.5 |  |
| BP_Walker_RiotGear_Medium | BP_Base_Walker_RiotGear | DA_ModelVariation_Walker_RiotGear_Medium | SK_RiotGearNoHelmet (1) | 3.0 |  |
| BP_Walker_RiotGear_VeryLight | BP_Base_Walker_RiotGear | DA_ModelVariation_Walker_RiotGear_VeryLight | SK_RiotGearTorsoOnly (1) | None |  |
| BP_Whipper_Generic | BP_Base_Whipper | DA_ModelVariation_Whipper | SK_Oscar02 (1) | None | Aggressive_Exp2 |
| BP_Butcher_Clown | BP_Butcher_Generic | DA_ModelVariation_Butcher_Clown | SK_ClownButcher01 (1) | None |  |
| BP_Butcher_Haus | BP_Butcher_Generic | DA_ModelVariation_Butcher_Haus | SK_ButcherEx101 (1) | None |  |
| BP_Butcher_Revenant | BP_Butcher_Generic | DA_ModelVariation_Butcher_Revenant | SK_ButcherRev (1) | None | DamageModifiers_Butcher, DamageModifiers_Revenant |
| BP_Mutator_Reuben | BP_Mutator_Transformed | DA_ModelVariation_Mutator_Transformed_Reuben | SK_MutatorReuben (1) | None |  |
| BP_Mutator_Revenant | BP_Mutator_Transformed | DA_ModelVariation_Mutator_Revenant | SK_MutatorRev01 (1) | None | DamageModifiers_Mutator_Revenant |
| BP_Runner_Caustic | BP_Runner_CDC | DA_ModelVariation_Runner_Caustic | SK_RunnerMaleCaustic01 (1), SK_RunnerMaleCaustic02 (1) | None |  |
| BP_Runner_Caustic_PalmTree | BP_Runner_Caustic | DA_ModelVariation_Runner_PalmTree_Caustic | SK_HazmatRunnerEx201 (1), SK_HazmatRunnerEx202 (1) | None | Aggressive_Exp2 |
| BP_Runner_Shocking_PalmTree | BP_Runner_Shocking | DA_ModelVariation_Runner_Shocking_PalmTree | SK_ShockingRunnerEx201 (1) | None | ShockingBuildUp_Runner_Shocking, Aggressive_Exp2 |
| BP_Runner_Vicious | BP_Runner_Spiky | DA_ModelVariation_Runner_Vicious | SK_ViciousRunner01 (1), SK_ViciousRunner02 (1), SK_ViciousRunner03 (1) | None |  |
| BP_Screamer_Glam | BP_Screamer_Generic | DA_ModelVariation_Screamer_Glam | SK_ScreamerGlam01 (1), SK_ScreamerGlam02 (1) | None |  |
| BP_Screamer_Haus | BP_Screamer_Generic | DA_ModelVariation_Screamer_Haus | SK_ScreamerGlam01 (1) | None |  |
| BP_Screamer_HausReveal | BP_Screamer_Generic | DA_ModelVariation_Screamer_HausReveal | SK_ScreamerEx1 (1) | None | AttachCosmeticEffectWhenScreaming_Screamer, DamageModifiers_Screamer, DamageModifiers_Reveal, ApplyBleedingOnHit_Screamer_HausReveal, DamageModifiers_Screamer_HausReveal |
| BP_Screamer_Huntress | BP_Screamer_Generic | DA_ModelVariation_Screamer_Huntress | SK_ScreamerHuntressA (1) | None |  |
| BP_Screamer_Reveal | BP_Screamer_Generic | DA_ModelVariation_Screamer_Huntress | SK_ScreamerHuntressA (1) | None | AttachCosmeticEffectWhenScreaming_Screamer, DamageModifiers_Screamer, DamageModifiers_Reveal |
| BP_Screamer_Revenant | BP_Screamer_Generic | DA_ModelVariation_Screamer_Revenant | SK_ScreamerRev (1) | None | AttachCosmeticEffectWhenScreaming_Screamer, DamageModifiers_Screamer, DamageModifiers_Revenant |
| BP_Screamer_RollerGirl | BP_Screamer_Generic | DA_ModelVariation_Screamer_RollerGirl | SK_ScreamerRollergirlA (1), SK_ScreamerRollergirlA02 (1), SK_ScreamerRollergirlA03 (1) | None |  |
| BP_Slobber_Firestorm_Haus | BP_Slobber_Firestorm | DA_ModelVariation_Slobber_Firestorm_Haus | SK_SlobberFirestormEx101 (1) | None |  |
| BP_Slobber_Burger66 | BP_Slobber_Generic | DA_ModelVariation_Slobber_Burger66 | SK_SlobberFastFoodA (1) | None |  |
| BP_Slobber_PostalService | BP_Slobber_Generic | DA_ModelVariation_Slobber_PostalService | SK_SlobberPostalServiceA (1) | None |  |
| BP_Slobber_Reveal | BP_Slobber_Generic | DA_ModelVariation_Slobber_Reveal | SK_FilmsetSlobber (1) | None | AttachCosmeticEffectWhenSpewing_Slobber_Generic, AttachCosmeticEffectWhenSpitting_Slobber_Generic, DamageModifiers_Slobber, AttachCosmeticEffectWhenGrappleVomitting_Slobber_Generic, TrackProjectileAccuracy_Slobber_Generic, DamageModifiers_Reveal |
| BP_Slobber_Revenant | BP_Slobber_Generic | DA_ModelVariation_Slobber_Revenant | SK_SlobberRev (1) | None | AttachCosmeticEffectWhenSpewing_Slobber_Generic, AttachCosmeticEffectWhenSpitting_Slobber_Generic, DamageModifiers_Slobber, AttachCosmeticEffectWhenGrappleVomitting_Slobber_Generic, TrackProjectileAccuracy_Slobber_Generic, DamageModifiers_Revenant, DamageModifiers_Slobber_Revenant |
| BP_Suicider_CHiPs | BP_Suicider_Generic | DA_ModelVariation_Suicider_CHiPs |  | None |  |
| BP_Thug_Bride | BP_Thug_Generic | DA_ModelVariation_Thug_Bride | SK_FemThugBride (1) | None |  |
| BP_Thug_Haus | BP_Thug_Generic | DA_ModelVariation_Thug_Haus | SK_ThugMaleEx101 (1), SK_ThugMaleEx102 (1) | None |  |
| BP_Thug_LongPiglet | BP_Thug_Generic | DA_ModelVariation_Thug_LongPiglet | SK_ThugLongPiglet (1) | None | DamageModifiers_Thug, ApplyBleedingOnHit_Thug_LongPiglet, DamageModifiers_Thug_LongPiglet |
| BP_Thug_MilitaryThug | BP_Thug_Generic | DA_ModelVariation_Thug_MilitaryThug | SK_MilitaryThug (1) | None |  |
| BP_Thug_PalmTree | BP_Thug_Generic | DA_ModelVariation_Thug_PalmTree | SK_CrusherEx201 (1), SK_CrusherEx202 (1), SK_CrusherEx203 (1), SK_CrusherEx204 (1) | None |  |
| BP_Thug_Reveal | BP_Thug_Generic | DA_ModelVariation_Thug_Bride | SK_FemThugBride (1) | None | DamageModifiers_Thug, DamageModifiers_Reveal |
| BP_Thug_Revenant | BP_Thug_Generic | DA_ModelVariation_Thug_Revenant | SK_ThugRev (1) | None | DamageModifiers_Thug, DamageModifiers_Revenant, DamageModifiers_Thug_Revenant |
| BP_Thug_WW2 | BP_Thug_Generic | DA_ModelVariation_Thug_WW2 | SK_MilitaryThugWW201 (1) | None |  |
| BP_Thug_Inferno_Haus | BP_Thug_Inferno | DA_ModelVariation_Thug_Haus | SK_ThugMaleEx101 (1), SK_ThugMaleEx102 (1) | None |  |
| BP_Thug_Inferno_PalmTree | BP_Thug_Inferno | DA_ModelVariation_Thug_Inferno_PalmTree | SK_CrusherInfernoEx201 (1) | None |  |
| BP_Walker_Caustic | BP_Walker_CDC | DA_ModelVariation_Walker_Caustic | SK_WalkerMaleCaustic01 (1), SK_WalkerMaleCaustic02 (1) | None |  |
| BP_Walker_Caustic_PalmTree | BP_Walker_Caustic | DA_ModelVariation_Walker_PalmTree_Caustic | SK_HazmatWalkerEx201 (1), SK_HazmatWalkerEx202 (1) | None | Aggressive_Exp2 |
| BP_Walker_FuelTank_PalmTree | BP_Walker_FuelTank | DA_ModelVariation_Walker_FuelTank_PalmTree | SK_FuelTankEx201 (1) | None | Aggressive_Exp2 |
| BP_Walker_FuelTank_WW2 | BP_Walker_FuelTank | DA_ModelVariation_Walker_FuelTank_WW2 | SK_FuelTankWW201 (1) | None |  |
| BP_Walker_GrenadeVest_PalmTree | BP_Walker_GrenadeVest | DA_ModelVariation_Walker_GrenadeVest_PalmTree | SK_GrenadeVestEx201 (1), SK_GrenadeVestEx202 (1), SK_GrenadeVestEx203 (1) | None | Aggressive_Exp2 |
| BP_Walker_GrenadeVest_WW2 | BP_Walker_GrenadeVest | DA_ModelVariation_Walker_GrenadeVest_WW2 | SK_GrenadeVestWW201 (1) | None |  |
| BP_Walker_Security | BP_Walker_LAPD | DA_ModelVariation_Walker_Security | SK_WalkerMaleSec01 (1), SK_WalkerMaleSec02 (1), SK_WalkerMaleSec03 (1) | None |  |
| BP_Walker_RiotGear_Medium_Haus | BP_Walker_RiotGear_Medium | DA_ModelVariation_Walker_Haus_RiotGear | SK_RiotGearEx1NoHelmet01 (1), SK_RiotGearEx1NoHelmet02 (1), SK_RiotGearEx1NoHelmet03 (1) | None |  |
| BP_Walker_Shocking_PalmTree | BP_Walker_Shocking | DA_ModelVariation_Walker_Shocking_PalmTree | SK_ShockingWalkerEx201 (1) | None | ShockingBuildUp_Walker_Shocking, Aggressive_Exp2 |
| BP_Walker_Vicious | BP_Walker_Spiky | DA_ModelVariation_Walker_Vicious | SK_ViciousWalker01 (1), SK_ViciousWalker03 (1) | None |  |
| BP_Whipper_Reveal | BP_Whipper_Generic | DA_ModelVariation_Whipper_Reveal | SK_Oscar01 (1) | None | Aggressive_Exp2, CutsceneExit_AI |
| BP_Whipper_Revenant | BP_Whipper_Generic | DA_ModelVariation_Whipper_Revenant | SK_OscarRev (1) | None | Aggressive_Exp2, CutsceneExit_AI |
