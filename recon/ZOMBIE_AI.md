# DI2 zombie AI: card dealer, decks, attack rules, engagement rings

Owner: zombie-ai session. Personal-use research notes; never share. Static RE of DI2's cooked data (CUE4Parse dumps in
extracted/json, `tools/di2x.sh json`) and the shipping exe (headless Ghidra project extracted/ghidra_ai).

## Hand-off (top, keep current) - 2026-10-09
**Q8 brief (coordinator, 2026-10-09; session di2-ai-specials).** Make DI2's special zombies use their abilities,
starting with the Screamer's scream. Steps, committing after each: (1) drop the zombie AI's nearest-variant clip
fallback (UNVERIFIED 80) now that attacks2 exists, so attacks play their real montages; close row 80. (2) Screamer
scream: port the staged state machine + Explosion_Scream (radial effect on the player / other zombies per DI2 data)
with its Scream / ScreamEnd anim sets from zombie_ai.json. (3) Then, in order, as far as the evidence goes: Suicider
explode (alert + explode clip; dies on the hit), Slobber spit / spew / vomit, Butcher abilities. (4) Ring-assignment RE
only if time remains. Owned: zombie_ai.gd, autotest_zombie_ai.gd, tools/build_zombie_ai.py, game/data/zombie_ai.json,
tools/re_ai/*, this file, own UNVERIFIED rows; zombie.gd small hooks only after a message to the coordinator;
explosions via di2_explosion.gd (ask before changing it); VFX via DI2Particles.play_ce. Done when the Screamer screams
per DI2 data in a capture (game/test_out/di2-ai-specials/), further abilities verified the same way,
`tools/run_all_tests.sh combat flesh` has 0 script / shader errors and no [panic, zombie_ai CHECKs ok.

**Q8 state (di2-ai-specials, 2026-10-09)**
- **Next:** Q17 (specials' attack clips) then drop `_card_playable` (UNVERIFIED 94); ring-assignment RE (UNVERIFIED 74;
  also routes the Slobber's Medium / LongRangedAttacks decks, so it deals Spew on its own); the Butcher's reactive
  Block / Crouch actions (BP_Action_Block_Butcher, DA_ActionDefinition_AI_Butcher_Crouch; hit-reaction side, unowned);
  player hooks for Slowed_Screamer / acid / Corroded; the projectile and scream CEs (particles).
- Slobber done (3f33823, section 11): its fire modes (Spew / Vomit / Spit0 / Spit1) from
  DA_RangedWeaponModuleConfig_Slobber are fired by the montages' ActivateProjectileStream windows. BP_Projectile_Spew_
  Slobber deals 5 acid + Corroded 0.1 and detonates into the SlobberBile acid fluid. Verified (--zombieai, Spew card
  started by the test): 11 shots in the 3 windows, 0.28 s apart, each hitting the player.
- Butcher done (builder Super-chain fix, this commit): BP_AIController_Butcher had lost the Base_Zombie Master deck
  because the builder followed exps[0]'s Super. It now deals its own cards (WaitUntilNotPeeked, SliceSliceStab) and
  attacks. Its SliceSliceStab / DoubleStab montages lack body clips (Q17).
- Step 1 done (322ba7e; hooks 9249f63): attacks play exactly the montage DI2 picks, segment-only attacks2 montages by
  name through ZombieAnim.play. Verified: walker 29 / runner 28 / shambler 17 / thug 13 segment-only montages resolve,
  and attacks play them. UNVERIFIED 80 closed; the distance choice moved to 88.
- Step 2 done (6444c67, section 9; DI2Anim "_loop" import-name fix 2b1765e). Verified (--zombieai, 02:04): wind-up
  1.24 s, then ScreamAngle 0 picks the Loop, ScreamEffectsBegin at 0.6 s, explosion Scream_Screamer, a Walker 5 m
  away turns Aggressive (lingers 12 s), the player is in the 1300 cm sphere, natural end at MaxDuration 12 s, then
  the ScreamEnd outro. Capture game/test_out/di2-ai-specials/zombie_ai/scream_effects.png (blast ring).
- Temporary deal filter (UNVERIFIED 94, drop with coordinator Q17): melee cards whose attack montage a body lacks are
  not dealt (the Screamer's Swipe / MultipleSwipe / Ripper meanwhile).
- Step 3, Suicider done (35e749b, section 10). Arming from DT_SuicideBalancing_Suicider, TriggerSuicideAnticipation,
  then the detonation card, then death + Explosion_Suicide by status. Verified: armed 4.07 s, exploded 5.45 s;
  game/test_out/di2-ai-specials/zombie_ai/suicider_explode.png.
- Slobber, not started (evidence gathered): Spit / Spew / DownwardVomit already play through the generic anim-set
  action (DA_ActionDefinition_AI_Slobber_Spew = BP_Action_AnimSet_AI). The ability is the montage notify state
  BP_AnimNotifyState_ActivateProjectileStream {FireModeIdentifier "Spew"} (CDO: MeshSocketToSetManualPositionFrom
  head_mouth, ManualOffsetRotationLimit 90). It fires BP_Projectile_Spew_Slobber, a modular native projectile
  (DIProjectileMovementComponent, ApplyPointImpactCollisionResponse, detonate on lifetime). Its bytecode is dumped in
  extracted/json_bp/.../Slobber/. Next: the "Spew" fire mode on BP_Base_Slobber (stream rate, projectile class, speed),
  the sub-object values, and a player damage hook (player is unowned).
- Butcher: not started.
- Screamer melee: its Short / Long Ripper / Slap montages have no body clips (only Med); Q17 builds the specials'
  attack clip sets, then remove `_card_playable` (UNVERIFIED 94).
- Not ported, logged only (UNVERIFIED 89-93):
  - the Screamer's Slowed_Screamer on the player (needs a player hook; its BP is dumped now), the HearScream stim,
    zombie backup, the CE_Screamer_Scream_* CEs (not in particles.json);
  - the Aggressive scalars;
  - DI2Explosion: no angle scale, no player victim, no causer exclusion;
  - the Suicider's other perks and its explosion on non-suicide deaths.
- Builder: build_zombie_ai.py now also writes actions / action_defs / curves / explosion_sets / spheres / balancing,
  reading Blueprint classes from extracted/json_bp in actions() only. Finding: the cards' BP_ActionParams_* defaults in
  json_bp (e.g. ApproachBeeline PeekedCardCheckInterval 0.3, MaximumDurationExpression 99999) are not merged into the
  decks yet, because merging changes the ported archetypes' behaviour. Decide in a follow-up.
- Tests: `TEST_OUT=game/test_out/di2-ai-specials TEST_EXTRA_ARGS=--zombieai tools/run_all_tests.sh combat`
  (zombie-AI scenarios only, ~5 min plus slot wait; log zombie_ai/zombie_ai.log, scream / suicider captures).
- Ring assignment RE (step 4): not reached.

**Done (earlier)**
- RE of DI2's zombie AI (sections 1-8); port game/scripts/zombie_ai.gd over game/data/zombie_ai.json
  (`python tools/build_zombie_ai.py`, local). Hooked in zombie.gd `_physics_process` (`ai.think`, `ai.interrupt()`).
- Tests: game/scripts/autotest_zombie_ai.gd, from autotest_combat.gd (`--zombieai` runs only these).

**Open RE (UNVERIFIED 74-88):** engagement-ring assignment (EngagementRingMovementMode.cpp 0x141085aa0; walk the key
list at 0x146b749e0); FacingCombatTarget angle semantics; Short / Med / Long choice; AggressionLevel's writer;
WaitAction end rule. Strafe movement: Q7.

**Tools**
- `tools/re_ai/ue_flat.py <asset>`: one line per property.
- `tools/re_ai/deck_tree.py <asset>`: decks / BTs / sequences as trees.
- `tools/re_ai/reach.py <Arch>`: what a class's decks reach.
- `tools/re_ai/members.py <Prop>`: reflected members.
- `tools/re_ai/ctor.py <class-name VA>`: native ctor defaults.
- `tools/re_ai/disasm.py`, `tools/re_ai/refs.py`, `tools/re_ai/callers.py`, `tools/re_ai/wstrings.py`.
- `tools/re_ai/batch.sh <out> "<cmd>"`: one CPU slot for find + decompile (extracted/ghidra_ai/<out>.c).
- `tools/re_ai/bpdump.sh <regex>`: Blueprint bytecode to extracted/json_bp; read it with tools/bp_pretty.py.
- `tools/re_ai/bp_cdo.py <dump> [name]`: class-default properties; `tools/re_ai/attack_coverage.py [Arch] [-v]`: which
  attack montages a body plays; `tools/re_ai/json_diff.py <a> <b> [key]`; `tools/re_ai/glb_anims.py <glb>`.

## 1. Architecture (data)
DI2 has no per-archetype hand-written brain. Each zombie's AI controller (BP_AIController_<Type>, parent
BP_AIController_Base_Zombie) runs a behaviour tree and a **card dealer** (`AICardDealerComponent`, plugin
`Plugins/CardDealer`, exe source paths CardDealerComponent.cpp / CardGenerator*.cpp / CardPlayerComponent.cpp;
DI2 side `AI/AttackManagement/ActionCardPlayer.cpp`). The tree only picks the deck context; every combat decision
(attack, approach, strafe, idle break, grapple) is a **card** drawn from a **deck**.

- BT_Zombie_Walker -> loop BT_Base_Zombie. BT_Base_Zombie: BTComposite_BehaviourIssuer over issuers StopAll / Combat /
  Search / Alert / Calm; branch by `BTDecorator_CheckCombatState` (ECombatState Combat / Search / Alert / Calm).
  Combat runs `BT_CombatInit` (when CombatTargetChanged) then `BT_Combat` (blackboard keys).
- BT_Combat_AI: `BTTask_SetDeck Context=Master`, then Wait 999 looped, with scoped fact `ShouldDrawCards` and service
  `BTService_RequestCombatMovementMode MovementMode=BP_CombatMovementMode_EngagementRings_AI` (Query EQSQuery_Surround,
  MoveTargetName EngagementRingPoint).
- Deck contexts -> decks: AICardDealerComponent.Contexts on the controller CDO (Walker below; the base controller adds
  Calm=DA_Deck_Calm_AI, Search=DA_Deck_Search_AI, Master=DA_Deck_CombatMaster_AI, Occupied=DA_Deck_Occupied_AI,
  CannotReachTargetOccupied=DA_Deck_CannotReachTarget_Occupied_AI).
  Walker: EnterCombat=DA_Deck_EnterCombat_Walker, InnerRing=DA_Deck_InnerRing_Walker, OuterRing=DA_Deck_OuterRing_Walker,
  Crawler=DA_Deck_Walker_Crawler, CannotReachTarget=DA_Deck_CannotReachTarget_Master_AI (+ CRT sub-decks),
  BangOnSurface=DA_Deck_BangOnSurface_Walker.
- Combat aggro component (CombatAgentClass) BPC_CombatAggro_Walker: EngagementPriority 1, **InnerRingRadius 150**,
  **OuterRingOccupyRadius 400, OuterRingOccupyVariation 250** (cm). CombatStims DA_CombatStims_Walker (parent
  DA_CombatStims_Zombie_Common: SeeHostileHumanoid score 20, FeelHostileHit 50, FeelHostileHumanoidClose 15, ...).
- CombatTargetAggressorIdentifiers: Default_ / Walker_ / Common_TotalAggressorsDesireInnerRing (counts of attackers that
  want the inner ring around one target; the inner ring deck reads `Default_TotalAggressorsDesireInnerRing > 3`).

## 2. Master deck (DA_Deck_CombatMaster_AI), generator order as stored
0 IncludeDeck PriorityCombatActions; 1 `CanEnterCombat` & counter EnterCombat <= 0 -> PriorityEnterCombat;
2 `!Crawler` -> (SetBoolFactOnDraw CanEnterCombat) CannotReachTarget; 3 `CanEnterCombat` & EnterCombat <= 0 -> EnterCombat;
4 target `#Occupied` -> Occupied_Crawler (Crawler) / Occupied; 5 `Crawler` -> CrawlerCannotReachTarget / Crawler;
6 `DesiredEngagementRing == "Inner" || (DesiredEngagementRing == "Outer" && EngagementRing == "Outer")` ->
EngagementRingAgnostic; 7 `DesiredEngagementRing == "Inner"` -> InnerRing; 8 Outer & in Outer -> OuterRing;
9 Always DA_Card_Approach_AI.

## 3. Walker inner ring (DA_Deck_InnerRing_Walker)
Root: VerticalRangeToCombatTarget [-250, 250] -> Selector:
0. cvar ai.EnableOffscreenBehaviours & `!StatusEffect_Aggressive && !#HasEverAttacked` & target NOT facing agent
   (CombatTargetToAgent, inverse, 180): dist > 200 -> Approach, else AttackRules OffScreenIdleCooldown -> OffScreenSignposting.
1. `DistanceFromTarget <= 280` -> Selector: counter InnerRingIdleBreak >= 1 & !Aggressive -> IdleBreakOutro;
   counter ActiveCombat >= 1 (OnDrewCard sets ActiveCombat) -> [target KB `Default_TotalAggressorsDesireInnerRing > 3`
   & facing 110 -> IdleBreak_InnerRing] else facing -> Random{3: IdleBreak_InnerRing, 2: AttackSequenceOutro}.
2. `DistanceFromTarget < 20 && !#MouthCovered`, vertical [-30, 30] from target, facing 45, rules UpCloseBite -> Bite.
3. offscreen cvar & 1 player & counter NonOffScreenStrafeCardsToPlay <= 0: strafe R (target->agent 130, offset 115) / L (-115).
4. cvar ai.combat.GrappleEnabled & `#HasBothArms && !#MouthCovered && !ScriptedAttackBuffer` & target `#StateForGrapple`
   & rules Grapple_Walker + Grapple_AI -> DA_Card_Grapple_Walker.
5. `!#HasAnArm` -> Bite.
6. `#HasBothArms` -> Selector{ Selector{ Aggression > 0 && dist > 80: rules Windmill (WarmUpStartedFactName
   First_EnteredInnerRing) -> Windmill; Aggression <= -1 && dist < 180: Windmill; Aggression <= -1 &&
   !ScriptedAttackBuffer: rules Lurch -> Lurch }, Selector{ Aggression <= -1: Random{3 MultipleSwipes_Shambler,
   1 Swipe_Shambler}; Aggression == 0 / >= 1: Random{2 SwipeCombo1, 2 SwipeCombo2, 1 SwipeCombo3} each behind its rules } }.
7. `!#HasBothArms` -> Random{1 SwipeCombo3_OneArmAlt, 2 Swipe}. 8. Always SwipeCombo3.
Distances in cm. "AggressionLevel" is a KB fact (UNVERIFIED source; section 7).

Outer ring (DA_Deck_OuterRing_Walker): strafe pair (offscreen); facing 65 + rules InterruptibleIdleBreak ->
IdleBreak_OuterRing; rules OuterRingMovementBuffer + StrafeOnScreen_Walker (WarmUpStartedFactName Last_EnteredOuterRing)
-> strafe L (offset -40, angle 40) / R; target not facing (inverse 50) -> Approach_FaceCombatTargetUntilNotPeeked;
else StandStillUntilNotPeeked.

Enter combat (DA_Deck_EnterCombat_Walker): `!#ShouldSkipEnterCombat` -> rules EnterCombat_Walker -> facing 60 ->
dist > 400 & !Crawler: Random{EnterCombat_Moving, EnterCombat_Static} else Static; FaceTargetTimeElapsed < 1 ->
Approach_EnterCombat_FaceCombatTargetUntilNotPeeked; or rules EnterCombat_Grapple_Walker & `#EnterCombatGrapple`
(both arms, dist > 500, standing, mouth free) & target #StateForGrapple & cvar -> Grapple. Fallback Approach.

Crawler (DA_Deck_Walker_Crawler): ActiveCombat >= 2 & facing 120 & dist < 300 -> IdleBreak_InnerRing; vertical
[-10, 10], mouth free, target #StateForGrapple, rules Walker_Crawler_Grapple + Grapple_Crawler + Grapple_AI, facing,
dist < 300 -> Grapple_Walker_Crawler; dist < 50 (or < 70 with vertical [-50, 50]): facing 35 -> Random 1:1 of the
two hand orders by `#CanUseRightArm_Crawler` (BlendingFoot == BlendLeftFoot) / `#CanUseLeftArm_Crawler`; Approach >= 1
& target behind -> IdleBreak_TargetBehind_Crawler (rules); else Approach_FaceCombatTargetUntilNotPeeked;
DesiredEngagementRing Inner or EngagementRing None -> ApproachBeeline (EQS Crawler_MeleeCombat_Approach);
facing 60 -> IdleBreak_InnerRing; else Approach_FaceCombatTargetUntilNotPeeked.

## 4. Cards (GenericActionCard)
{Action (DA_ActionDefinition_*), Parameters, CounterModificationOnSuccess / OnFailure (CountersToModify add,
CountersToSet), ShouldContinueExpression, Min/MaximumDurationExpression, SelfPeekedCard / PeakedCardToMaintainAction,
LifetimeFacts, AttackRulesFactToSetOnEnd}. Examples:
- DA_Card_Swipe_Walker: AttackSequence DA_AttackSequence_Walker_Swipe, ActiveCombat += 1 on success and failure,
  ShouldContinue `#StandardMeleeContinuation`.
- DA_Card_Approach_AI: DA_ActionDefinition_Wait_Moving_AI, duration 0..9999, SelfPeekedCard = itself, Approach += 1.
- DA_Card_IdleBreak_InnerRing: sequence DA_AttackSequence_IdleBreak_InnerRing_AI; success: IdleBreak += 1,
  InnerRingIdleBreak += 1, set ActiveCombat = 0 (and ReachingSwipes, CrawlerMovementFailed, SearchApproach,
  FollowingSearchDirection = 0).
- DA_Card_AttackSequenceOutro_AI: WaitMoving_FaceCombatTarget, MinimumDuration 1.0 x DA_AttributeType_AttackSpacingDuration,
  LifetimeFacts AllowBlock.
- DA_Card_StandStillUntilNotPeeked_AI: Wait_Stationary, SelfPeekedCard itself, sets Last_EnteredEngagementRing on end.

## 5. Attack sequences and attack definitions
DA_AttackSequence_* Units[] = BP_AttackSequenceUnitAction_Melee {AttackDefinition, AttackParams
(bShouldAlwaysPerformFixedWindUp), EffectivenessModifier, FactsToIncrement}. SwipeCombo1_Walker = Swipe_Jab (always fixed
wind-up), Swipe_Jab (EffectivenessModifier -0.4, increments AllowStumbles).
DA_AttackDef_*: DamageType, AttackRules[] (Walker swipes: DA_AttackRules_MeleeImpact = "AttackCooldown",
TargetPostStartCooldown 0.28), MaxAngleToLaunchAttack 32, MaxAngleToLaunchFallbackAttack 120, bUseFallbackAttack,
WindUps[] {WindUp DA_WindUpDef_*, Condition (`#CanUseRightArm` / `#CanUseLeftArm`), Duration 0.4,
WindUpVisibleAtDistance 600, CancelWindUpAtDistance 1050, CancelWindUpAfterSeconds 5, DefaultImpactProfile,
Max Forward/Backward LeadDistance 50, Attacks[] {FixedWindUpMontage, Montage, AttackLocationOffset,
OverrideSuccessDistance} (Short / Med / Long)}. Reflected layout (exe): WindUp entry 0x70 bytes, fields as listed.

## 6. Attack rules (AttackRules data assets)
Reflected members: Name @48, CommitExpression @56, WarmUp @112, TargetPostStartCooldown @152, GlobalPostStartCooldown
@156, AttackerPostEndCooldown @160, TargetPostEndCooldown @200, GlobalPostEndCooldown @240 (random-number structs
{Distribution, ExpectedValue, StandardDeviation, Min, Max}). AttackRules generator: {AttackRules[], WarmUpStartedFactName}.
Exe format strings: `AttackRules_%s_WarmUp`, `AttackRules_%s_WarmUpGenerated`, `AttackRules_%s_%s_%s` (fact names).

| Rules | WarmUp | AttackerPostEnd | TargetPostEnd | other |
|---|---|---|---|---|
| Walker_SwipeCombo1/2/3 | min 2 max 12 | E0 sd0.7 [7,15] | E0 sd2 [3,5] | commit #VisibleAttackCommitment |
| Walker_Windmill | U[2,12] | U[9,45] | U[6,8] | |
| Walker_Lurch | - | U[4,15] | U, E5 | commit #VisibleAttackCommitment |
| Grapple_Walker | U[7,10] | U[8,12] | N(12, 2) min 12 | |
| Grapple_AI (SharedGrapple) | - | - | U[4,6] | commit FixedWindUp or Attack sub-action |
| UpCloseBite_Walker | E5 | - | E15 | |
| MeleeImpact (AttackCooldown) | - | - | - | TargetPostStartCooldown 0.28 |
| EnterCombat_Walker | - | E90 | E12 | commit EnterCombatAttackRulesCommitment |
| EnterCombat_Grapple_Walker | - | - | U[8,12] | |
| Walker_Crawler_Grapple | U[3,6] | U[6,8] | N(8, 2) | |
| Grapple_Crawler | - | - | U[4,6] | |
| OuterRingMovementBuffer | E1.4 | - | - | |
| StrafeOnScreen_Walker | - | U[1,3] | - | |
| Zombie_InterruptibleIdleBreak | - | U[0.7,1.6] | [0.2,0.5] | |
| PlayerKnockdownResponse | - | U[1,3] (E0.5) | - | |
U = Uniform, N = Normal, E = ExpectedValue; a struct without Distribution uses the native default (section 7).

## 7. Native semantics (open)
To decode from the exe: generator evaluation order and failure fall-through (Deck.Generators, Selector, Random),
FacingCombatTarget / VerticalRange tests, AttackRules checks (warm-up start, which cooldown applies to whom, commit),
the random-number struct default distribution and sampling, dealer cadence (peek / SelfPeekedCard, ShouldContinue),
engagement-ring assignment (DesiredEngagementRing, inner-ring capacity), AggressionLevel.
AttackRules.cpp fact-name builders: 0x14103d600 (uses `AttackRules_%s_WarmUp(Generated)`), 0x141040e50
(`AttackRules_%s_%s_%s`). EngagementRingMovementMode.cpp: 0x141085aa0.

Decoded so far:
- **AttackRules state lives in knowledge-base facts.** FUN_14103d600 builds, per rules Name, the fact names
  `AttackRules_<Name>_WarmUpGenerated`, `AttackRules_<Name>_WarmUp`, and via FUN_141040e50 two triples
  `AttackRules_<Name>_<scope>_Started` and `AttackRules_<Name>_<scope>_InProgress` (scope = three runtime FNames,
  read from globals 0x146bbe9c0 / 0x146bbeb50 / 0x146bbe9d0; by the struct's three cooldown pairs most likely
  Attacker / Target / Global, UNVERIFIED until the reader is decoded).
- **AttackRules runtime (decoded).** Scopes Attacker / Target / Global = the attacker's, the combat target's and the
  world knowledge base (FUN_1410629b0: attacker KB, target KB, owner->+0x150()->+0x138 KB).
  - Check, all rules of a generator's set (FUN_14104ac10): warm-up (FUN_141051530) and cooldowns (FUN_1410519b0).
  - Warm-up: no WarmUpStartedFactName -> passes. Else the start fact must exist; its float value is the start time;
    when that value differs from `_WarmUpGenerated`, store it there and sample WarmUp into `_WarmUp` (if > 0);
    passes when `_WarmUp <= now - start`.
  - Cooldowns, per scope: fails if `_<scope>_Started` exists or `_<scope>_InProgress` exists.
  - Commit (FUN_141043990): attacker `_InProgress` = sample(AttackerPostEndCooldown) if >= 0; target / global: if
    Target/GlobalPostStartCooldown > 0, add `_Started` (true) and remove it after that time (FUN_140a61b50 = remove
    fact after t, t <= 0 now); `_InProgress` = sample(Target/GlobalPostEndCooldown) if >= 0.
  - End (FUN_141049eb0): remove `_Started` now; remove `_InProgress` after its value (s).
  - So a rules asset with a PostEnd cooldown >= 0 is exclusive per scope while its attack runs (DI2's attack
    "token": one attacker per target per rules name) and for the sampled time after.
  - UAttackRules ctor (InternalConstructor 0x141b55f20): WarmUp = RNG(0), Attacker / Target / GlobalPostEndCooldown =
    RNG(-1) (constant 0x144bcf204), Target / GlobalPostStartCooldown 0. CardGenerator_AttackRules ctor (0x141b70ec0):
    WarmUpStartedFactName None.
- **Random-number struct (decoded).** FRandomNumberGenerator_Float {Distribution @0, ExpectedValue @4,
  StandardDeviation @8, Min @12, Max @16, Lambda @20, Offset @24}; ctor FUN_141ae9700(v): AbsoluteValue, v, 1, 0, 1,
  1, 0. Sampler FUN_141aeae20: AbsoluteValue -> ExpectedValue; Uniform -> Min + u (Max - Min); Normal ->
  ExpectedValue + SD N(0,1) (Marsaglia polar, **no clamp**); Cauchy -> Offset + Lambda tan((u - 0.5) pi).
  Consequence: assets that leave Distribution at its default use ExpectedValue only (SwipeCombo1-3 WarmUp = 0,
  AttackerPostEnd = 0, TargetPostEnd = 0: exclusive while attacking, no cooldown after; their Min/Max are unused).
  Int struct `ERandomIntGeneratorDistribution` {Absolute, Uniform}.
- **CombatAggroComponent ctor (0x14106b430), cm / s:** ScoreThreshold 10, TargetPerceptionGracePeriod 0.5,
  CurrentTargetScoreModifier 10, Threat 1, EngagementPriority 0, TraversalPullDistance 100, InnerRingRadius 120,
  InnerRingOccupyRadius 100, InnerRingSquishAmount 50, InnerRingOccupyVariation 50, OuterRingRadius 500,
  OuterRingOccupyRadius 400, OuterRingSquishAmount 100, OuterRingOccupyVariation 100, OccupyTolerance 20
  (offsets from reflection: 456..488). BPC_CombatAggro_<Type> override these (section 1).
- **Generator defaults:** FacingCombatTarget ctor (0x141b71020): FacingType AgentToCombatTarget, bIsInverse false,
  MaxFacingAngle 90, RotationalOffset 0. VerticalRangeToCombatTarget (0x141b71080): RangeToCombatTarget, min / max 0.
- **Actions (Blueprint bytecode, extracted/json_bp):** BP_Action_Strafe_AI peeks every CheckPeakedCardFrequency 0.5 s
  starting at StrafeParams.MinDuration (1.0) and ends when PeekCard != PeakedCardToMaintainAction; sets the
  CombatAggro Threat to 0 while strafing and restores it at the end; hard-coded EndAction(0, 20.0). BP_ActionParams
  _Strafe_AI: MinDuration 1, StrafeDirection default Left, RandomiseStrafeDirection, BlockedDurationToModifyCounters 2
  (sets NonOffScreenStrafeCardsToPlay = 2). BP_ActionParams_Wait_AI: Min 0.5, Max 99999, PeekedCardCheckInterval 0.3,
  CardCounterModificationOnBegin ActiveCombat = 0. BP_Action_WaitMoving_AI requests the EngagementRings combat
  movement mode while it runs.
- Other enums: EComparisonOperator {Equal, NotEqual, Greater, GreaterEqual, Less, LessEqual}, EFacingCombatTargetType
  {AgentToCombatTarget, CombatTargetToAgent}, ECombatTargetRangeType {RangeToCombatTarget, RangeFromCombatTarget},
  EEngagementRing {InnerRing, OuterRing}, EEngagementRingPointFilter {None, EdgesAndClosest}.
- AIAttributeValues (DA_AIAttributeValues_Walker): AttackSpacingDuration 1.5 (scales the AttackSequenceOutro card's
  MinimumDuration 1.0 via DA_AttributeType_AttackSpacingDuration), StrafeDuration [2, 3], BaseDamage 15,
  KnockdownDuration [3.5, 5].

## 8. Expression aliases
DIShared/Core/ExpressionAliases DT_ExpressionAliases_* (rows alias -> expression). Key ones:
`#HasBothArms` = left && right arm (HealthFraction_Arm_* > 0 or _Blade); `#CanUseLeftArm` = has left arm && floatbranch(
CanUseInterruptionAttack, AttackInterruptionState_LeftArm, (!#HasRightArm || FirstAttackInSequence || LastAttackHand !=
"Left")); `#StateForGrapple` = !CannotBeGrappled && !IsFuryMode && !#Occupied && !NotUnlocked_GrappleAttack && (!Crouch
|| HasUncrouchClearance); `#Occupied` = PlayerKnockdown || Unassailable; `#MouthCovered` = IsArmoured_Helmet || HasMask;
`#StandardMeleeContinuation` = !((#AnyIncompletePath || #Occupied || AllowDistractionMeleeCancellation ||
AllowMeleeCancellation) && (AIMeleeSubAction_VariableWindUp || AIMeleeSubAction_InvisibleWindUp) && !WaitingForClaimCycle);
`#EnterCombatGrapple` = both arms && DistanceFromTarget > 500 && !Crawler && !#MouthCovered && !ControlledByElectricScreamer;
`#ShouldSkipEnterCombat` = !EnterCombatMandatory && (HasReceivedDamageFromTarget || UsedScriptedAttack || ForceCombat);
`#HasEverAttacked` = hasfact("none", "IsAttacking").

## 9. Archetype actions: the Screamer's scream (Q8, 2026-10-09)
Sources: Blueprint bytecode in extracted/json_bp (`python tools/bp_pretty.py <dump>`, CDOs with
`python tools/re_ai/bp_cdo.py <dump>`), cooked data in extracted/json. Port: zombie_ai.gd "archetype actions".

**Dispatch.** An `AttackSequenceUnit_AnimSetAction`'s ActionName is looked up in the character's action definitions.
BP_Base_Screamer's `BPC_AI_CharacterAction.ArchetypeSpecificActionDefinitions` = DA_ActionDefinitions_AI_Screamer
overrides the generic ones by Name: "EnterCombat" -> DA_ActionDefinition_ScreamStateMachine_Screamer (Category Melee,
LifetimeFacts StopEngagement, StopCombatTimers, ScreamAttack; Implementation BP_Action_ScreamStateMachine_Screamer).
DA_Card_Scream_Screamer -> DA_AttackSequence_Screamer_Scream = one AnimSetAction unit, ActionName "EnterCombat".
The Screamer's decks hold no generic EnterCombat card. build_zombie_ai.py exports this as `actions`, `action_defs`
(with the implementation's class defaults), `curves`, `explosion_sets` and `spheres`.

**State machine** (BP_Action_ScreamStateMachine_Screamer; states 1 WindUp, 2 Scream, 3 Outro, 4 End):
- OnBegin: SetState(`Crawler || AmbushSkipWindUp` ? Scream : WindUp). SetState = EndState (cancels the running
  sub-action, reason 2) + BeginState.
- WindUp: anim set AnimSetName "Scream" (DA_ActionDefinition_ScreamAnimset_AI -> BP_Action_AnimSet_AI) with
  CounterFacts [ScreamWindup], MontageEndEvent 1 -> AM_ZMB_Screamer_Attack_Scream_Windup.
- Scream: DA_ActionDefinition_Scream_Screamer (BP_Action_Scream_Screamer, LifetimeFacts LocomotionSyncState,
  SoundBoost_Critical), anim set "Scream" with fact ScreamAngle. ScreamAngle = DetermineFacingActorOffset2D(Screamer,
  CombatTarget), negated when (ActorRight * SearchDirection).X + .Y < 0 (SearchDirection = unit vector to the aggro
  search location). It stays 0 when SkipScreamDirectionalAngleAdjustmentExpression ("AmbushSkipWindUp") holds or the
  search location is invalid. The bands: Loop |a| <= 22.5, L45 / R45 .. L180 / R180 (negative = left).
- Outro: BP_ActionParams_AnimSet_AI, AnimSetName "ScreamEnd", BlendOutDurationOverride 0.8,
  ThresholdInterruptionParams {DamageRequiredAsHealthPortion 0.1, AllotedTimePeriod -1} -> AM_ZMB_Screamer_Attack_Scream_End.
- GetNextState(reason): WindUp: 0 -> Scream, 1 / 2 / 3 -> End. Scream: 0 / 1 / 2 -> Outro, 3 -> End. Outro -> End.
  End = EndAction(0).

**Scream action** (BP_Action_Scream_Screamer CDO):
- MaxDuration 12, MinDuration 2, DetermineIfPrematureEndFrequency 0.5, FacingTargetAngleToMaintainScream 180,
  DelayBeforeAdditionalCancellationSettings 1.5, DamageThresholdForVulnerability 0.12 /
  ThresholdInterruptionParams 0.12 -> VulnerabilityFact MadeVulnerableByDamageThresholdReached.
- Effects wait for BeginScreamEffectsExpression "ScreamEffectsBegin". The Loop montages' AnimNotifyState_ScopedFacts
  {FactsArray [ScreamEffectsBegin]} raises it at 0.5984 s (Loop; ~0.6 s in the angled loops).
- Then IntialiseScreamEffects:
  - PlayCE_OnBegin: Blood_CE CE_Screamer_Scream_Blood_Loop and Continuous_CE CE_Screamer_Scream_Loop
    (+Z 22 cm) at head_mouth; ConeAngle from Curve_ScreamIntensityScale_Angle's change point / 360;
  - NumberOfScreamsStarted + 1;
  - SpawnStim DA_Stim_HearScream (ID Scream), YelpRadius 4000 cm, at the combat target;
  - SpawnExplosion: anim set 'Explosion_Scream' -> DA_DataSetCollection_Explosions_Screamer ->
    DA_ExplosionArchetype_Scream_Screamer (explosions.json Scream_Screamer: OuterRadius 1200, BlastSpeed 2500,
    Damage 0, StabilityDamageForce 80, BlastImpulse 20000, AngleScaleCurve Curve_Explosion_AngleScale_Scream,
    CE_EnemyAttack_Scream) at socket "Head" with the mesh rotation, Causer = Screamer, via DA_ActionDefinition_Explosion;
  - SummonZombieBackup (ScriptedSequenceComponent RequestStartSequence) and BP_BehaviourModifier_RememberTarget;
  - the ScreamSphere overlap (BP_Base_Screamer SphereComponent, SphereRadius 1300 cm, SetActorGridEntryType 4).
- Timers once the effects began:
  - MaxDuration -> EndAction(0);
  - MinDuration, then DetermineIfPrematureEnd every 0.5 s: IsActorFacingActor2D(Screamer, Target, 180, true) ->
    EndAction(2);
  - after 1.5 s an expression listener on #DamageOverTimeStatusEffect -> EndAction(2);
  - combat state back to 0 -> EndAction(2).
  - RemoveBurningAccumulation clears fire accumulation (type 0) on overlapping AI the Screamer faces within 100 deg,
    and on itself.
- Overlap (OnOverlapScreamSphere, by faction reaction):
  - friendly: BP_StatusEffect_Aggressive, Duration -1. The KB fact StatusEffect_Aggressive is what the decks read.
    BP_StatusEffectParams_Aggressive: StunDurationScalar -0.5, AttackSpacingScalar -0.6, KnockdownDurationScalar -0.6,
    OuterRingInviteDelayReduction -10; RememberTarget modifier; material Aggressive Veins Normal 2 / Density 3 / Iris 10.
  - hostile: BP_StatusEffect_Slowed_Screamer, Duration -1, TickInstanceInterval 0.1, MovementSpeedModifier -0.9,
    MinDistance 250, MaxDistance = sphere radius, Distance / Direction / Angle intensity curves, block thresholds 0.3,
    FacingTargetAngleForEffectiveBlock 90.
  - neutral: none.
  - EndSphereOverlap: a held Aggressive becomes a lingering one for MapRangeClamped(time in scream, 2, 12, 4, 12) s
    (ScaleLingeringAggressiveByTimeInScream; else LingeringStatusEffectDefaultDuration 15); Slowed is removed.
- Intensity curves (linear): Angle (0, 1) (75, 1) (105, 0) (180, 0); Direction (0, 0) (0.5, 0.2) (1, 1);
  Distance (0, 0) (0.05, 0.2) (1, 1).
- UnintialiseScreamEffects(reason): NaturalEnd_CE CE_Screamer_Scream_Exit for reasons 0 / 1, Interrupted_CE
  CE_Screamer_Scream_Interrupt for 2 / 3 (each destroyed after 2 s), collision off, EndStim, CancelZombieBackup,
  modifiers ended, RemoveHealthTracking.
- The legacy single montage AM_ZMB_Screamer_Attack_Scream (sections WindUp / Scream / End) carries
  BP_AnimNotify_SpawnExplosion_Scream_Screamer at 2.1634 s (head_mouth, BaseStaminaDamage 50). The state machine's
  montages don't; the action spawns the explosion itself.

Open (UNVERIFIED 89-92): sub-action end timing, the facing helpers, Slowed_Screamer on the player, the stim,
backup, the Aggressive scalars, DI2Explosion's angle scale / player / causer.

## 10. The Suicider's arming and detonation (Q8, 2026-10-09)
Sources: BP_Base_Suicider and BP_Action_SuicideDetonation_Suicider bytecode (extracted/json_bp, `tools/bp_pretty.py`),
DT_SuicideBalancing_Suicider, DA_DataSet_Suicide_Suicider. Port: zombie_ai.gd "arming and detonation"; data in
zombie_ai.json `balancing` / `curves` / `explosion_sets`.
- DT_SuicideBalancing_Suicider (read by the construction script): ExecutionSphereRadius 250, ArmingDuration 4,
  FastTrackArmingDuration 0.5, ArmingCooldown 10, DamagePortionToIntensityBoost 1, DamageIntensityBoostCap 0.2,
  CatiousIntensityBoost 0.3, DelayUntilTriggerDeathWhenFrozen 1. ExplosionExecutionSphere.SetSphereRadius(250).
- ArmingIntensity timeline: curves Curve_ArmingBuildUp_Weight (0, 0) (0.8, 1) (1, 1) -> MorphTargetsWeight and
  Curve_ArmingBuildUp_Speed (0, 0.65) (1, 1.45) -> MorphTargetsPlayRate (the SuiciderOrgans morph layer);
  CurrentArmingIntensity = position, also the Wwise RTPC_Suicider_Arm_Intensity.
- ExecuteStateResponse (on CombatStateChanged; skipped once CommittedToSuicide): state 0 -> SetArming(false,
  ArmingCooldown); state 2 -> target overlapping the sphere ? ArmingIntensityFastTrack (SetArming(true, 0.5)) :
  SetArming(true, ArmingDuration); no target -> BoostIntensity(0.3, 0.3) + PauseArming; other states nothing.
- SetArming(active, duration): play rate 1 / duration; active -> Play, or AttemptRequestSuicideExecution when the
  position is already 1; inactive -> Reverse. The sphere's begin overlap with the combat target -> fast track.
- AttemptRequestSuicideExecution (timeline finished): position == 1 && (target overlaps the sphere ||
  TargetConditionNotRequired) -> KB bool fact TriggerSuicideAnticipation. DA_Deck_Suicider deals
  DA_Card_SuicideDetonation_Suicider on `TriggerSuicideAnticipation && DistanceFromTarget < 800`;
  DA_Card_EnterCombat_Moving_Suicider cancels on `TriggerSuicideAnticipation && !OffScreenEnterCombatSignposting`.
- OnDamageReceived: BoostIntensity(clamp(DamageTaken / MaxHealth x 1, 0, 0.2), 1). BoostIntensity(p, limit): when
  position < limit, SetNewTime(clamp(p x length + position, 0, limit)).
- Detonation (DA_ActionDefinition_AI_Suicider_SuicideDetonation, Category Errand, LifetimeFacts CommittedToSuicide,
  LocomotionSyncState): plays anim set "Suicide" (StatusEffect_Aggressive ? AM_ZMB_Suicider_Attack_Explosion_
  Anticipation_Aggressive 0.8 s : ..._Anticipation 1.3 s; both attack_explode 1.8 / 2.3 -> 3.1 s). OnCompleted /
  OnBlendOut (once) -> SuccessfulSuicide + 1, GeneralImpactEvent on itself (ImpactGameplayCategory 6), EndAction(0);
  OnInterrupted -> EndAction(1).
- Death: perk DA_PerkDefinition_RequestExplosionOnDeath_Suicider with the explosion set Explosion_Suicide =
  DA_DataSet_Suicide_Suicider: IsBeingElectrocuted -> SuicideElectric, IsCorroded -> SuicideAcid, IsOnFire ->
  SuicideBurning, IsDrained -> SuicideBleed, else Suicide_Suicider (OuterRadius 700, BlastSpeed 2000, Damage 75
  explosive, StabilityDamageForce 150, CE_Explosions_ZombieExplosion_Suicider).
- Not ported (UNVERIFIED 93): other perks, the morph targets, the frozen-death timer, the explosion on non-suicide
  deaths.

## 11. Ranged fire modes: the Slobber's spit / spew / vomit (Q8, 2026-10-09)
Sources: BP_Base_Slobber (RangedWeaponModulesComponent x2, ManualMovement / MoveWithBone),
DA_RangedWeaponModuleConfig_Slobber (`tools/di2x.sh json`), BP_Projectile_Spew_Slobber (bytecode dump),
AM_ZMB_Slobber_Attack_* notifies. Port: zombie_ai.gd "ranged fire modes"; data in zombie_ai.json `fire_modes` /
`projectiles` / `streams` (build_zombie_ai.py fire_modes() / streams()).
- The cards: DA_Card_Spew_Slobber / DA_Card_DownwardVomit_Slobber -> DA_ActionDefinition_AI_Slobber_Spew
  (BP_Action_AnimSet_AI, LifetimeFacts StopLookAt, StopSubsequentFieldOfViewChecks) with anim sets Spew /
  DownwardVomit. The ability is in the montages: BP_AnimNotifyState_ActivateProjectileStream windows
  (CDO MeshSocketToSetManualPositionFrom head_mouth, ManualOffsetRotationLimit 90, ManualOffsetPitchOverride -1):
  - Spew: 3 windows (1.5239 s / 0.9027, 2.9886 / 1.3381, 5.3573 / 0.3918), FireModeIdentifier "Spew";
  - DownwardVomit: 2.2417 / 2.4082, "Vomit";
  - Spit: 1.4468 / 0.3075, "Spit", UseDistanceVariants [1400, 2000], rotation limit 60, pitch override 25.
- Fire modes (RangedWeaponFireMode UniqueIdentifier -> ActorProjectileSpawnModule, StandardShotHandler):
  - Spew: BP_Projectile_Spew_Slobber, speed 610, burst 1, DelayTimeBetweenShotsInBurst 0.28, no trajectory helper;
  - Vomit: the Spew projectile at its InitialSpeed 1000, burst 1, delay 0.6, parabola helper (default settings);
  - Spit0 / Spit1: BP_Projectile_Spit_Slobber, speed 1480 / 2000, single, 1 shot, delay 0.15, parabola
    (DA_ParabolaLaunchParams_Slobber), AIDeviation BaseAccuracy (DefaultDeviationRange 0, segment 22 deg).
  - all: MuzzleOriginBoneOrSocketName head_mouth, RaycastFromMuzzle.
- BP_Projectile_Spew_Slobber: DIProjectileMovementComponent InitialSpeed 1000; DetectMeshCollisions;
  ApplyPointImpactCollisionResponse BP_DamageType_Acid 5, Corroded +0.1 (extendable), bFriendlyFireAllowed; collision
  -> InvokeParentProjectileResponse (detonate, once); detonation -> InvokeParentProjectileLocationResponse ->
  ProjectileResponseSpawnProjectile BP_Fluid_Projectile_Acid_SlobberBile (FluidPayloadRadius 80; fluids.json has it
  and its BP_AOE_DamageOverTime_Acid_SlobberBile) + destroy; lifetime expiry detonates.
- The Slobber's Spit isn't reachable from the exported decks (no card in `reach.py Slobber`); its data is exported anyway.
- Variants: DA_RangedWeaponModuleConfig_Slobber_Firestorm / _Putrefied and BP_Projectile_Spew_Slobber_Firestorm exist
  (elemental variants, not ported).

## Appendix: attacks2 clips (montage -> zombie_clips sequences)
```
AM_ZMB_Runner_Attack_Flurry_End_LH -> x:A_ZMB_Runner_Attack_Flurry_End_LH
AM_ZMB_Runner_Attack_Flurry_End_RH -> x:A_ZMB_Runner_Attack_Flurry_End_RH
AM_ZMB_Runner_Attack_Flurry_Fast -> x:A_ZMB_Runner_Attack_Flurry, x:A_ZMB_Runner_Attack_Flurry_End_LH
AM_ZMB_Runner_Attack_Jump_MissToFloor -> x:A_ZMB_Runner_Attack_Jump, x:A_ZMB_Runner_Attack_Jump_Attack_MissToFloor
AM_ZMB_Runner_Attack_Lunge_Long -> x:A_ZMB_Runner_Attack_Lunge_Long
AM_ZMB_Runner_Attack_Push_Long -> x:A_ZMB_Runner_Attack_Push_Long_01
AM_ZMB_Runner_Attack_Push_Med -> x:A_ZMB_Runner_Attack_Push_Med_01
AM_ZMB_Runner_Attack_Push_ScriptedEntrance -> x:A_ZMB_Runner_Attack_Push_Long_01
AM_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Long -> x:A_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Long, x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Long_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Long
AM_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Short -> x:A_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Short, x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Short_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_LH_VertDown_Attack_Short
AM_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Long -> x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Long, x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Long_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Long
AM_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Med -> x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Med, x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Med_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Med
AM_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Short -> x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Short, x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Short_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_LH_VertUp_Attack_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Long -> x:A_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Long, x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Long_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Long
AM_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Short -> x:A_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Short, x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Short_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_RH_VertDown_Attack_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Long -> x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Long, x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Long_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Long
AM_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Med -> x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Med, x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Med_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Med
AM_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Short -> x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Short, x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Impact_Short
AM_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Short_FixedWindUp -> x:A_ZMB_Runner_Attack_Swipe_RH_VertUp_Attack_Short
AM_ZMB_Runner_OutOfReach_SwipeForward_L_01 -> x:A_ZMB_Runner_OutOfReach_SwipeForward_L_01
AM_ZMB_Runner_OutOfReach_SwipeForward_L_02 -> x:A_ZMB_Runner_OutOfReach_SwipeForward_L_02
AM_ZMB_Runner_OutOfReach_SwipeForward_R_01 -> x:A_ZMB_Runner_OutOfReach_SwipeForward_R_01
AM_ZMB_Runner_OutOfReach_SwipeForward_R_02 -> x:A_ZMB_Runner_OutOfReach_SwipeForward_R_02
AM_ZMB_Runner_OutOfReach_SwipeUp_L_01 -> x:A_ZMB_Runner_OutOfReach_SwipeUp_L_01
AM_ZMB_Runner_OutOfReach_SwipeUp_L_02 -> x:A_ZMB_Runner_OutOfReach_SwipeUp_L_02
AM_ZMB_Runner_OutOfReach_SwipeUp_R_01 -> x:A_ZMB_Runner_OutOfReach_SwipeUp_R_01
AM_ZMB_Runner_OutOfReach_SwipeUp_R_02 -> x:A_ZMB_Runner_OutOfReach_SwipeUp_R_02
AM_ZMB_Walker_Crawler_Attack_LH_Grapple_WindUp -> x:A_ZMB_Runner_Crawler_Attack_LH_01
AM_ZMB_Walker_Crawler_Attack_RH_Grapple_WindUp -> x:A_ZMB_Runner_Crawler_Attack_RH_01
AM_ZMB_Shambler_Attack_Uncontrol_Long -> x:A_ZMB_Shambler_Attack_Uncontrol_Attack_Long
AM_ZMB_Shambler_Attack_Uncontrol_Long_FixedWindUp -> x:A_ZMB_Shambler_Attack_Uncontrol_Attack_Long
AM_ZMB_Shambler_Attack_Uncontrol_ScriptedEntrance -> x:A_ZMB_Shambler_Attack_Uncontrol_Attack_Long
AM_ZMB_Shambler_Attack_Uncontrol_Short -> x:A_ZMB_Shambler_Attack_Uncontrol_Attack_Short
AM_ZMB_Shambler_Attack_Uncontrol_Short_FixedWindUp -> x:A_ZMB_Shambler_Attack_Uncontrol_Attack_Short
AM_ZMB_Shambler_SwipeL_Horiz_Long -> x:A_ZMB_Shambler_Attack_Swipe_LH_Horiz_Long
AM_ZMB_Shambler_SwipeL_Horiz_Long_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_LH_Horiz_Long
AM_ZMB_Shambler_SwipeL_Horiz_Short -> x:A_ZMB_Shambler_Attack_Swipe_LH_Horiz_Short
AM_ZMB_Shambler_SwipeL_Horiz_Short_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_LH_Horiz_Short
AM_ZMB_Shambler_SwipeL_Upward_Long -> x:A_ZMB_Shambler_Attack_Swipe_LH_Upward_Long
AM_ZMB_Shambler_SwipeL_Upward_Long_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_LH_Upward_Long
AM_ZMB_Shambler_SwipeL_Upward_Med -> x:A_ZMB_Shambler_Attack_Swipe_LH_Upward_Med
AM_ZMB_Shambler_SwipeL_Upward_Med_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_LH_Upward_Med
AM_ZMB_Shambler_SwipeL_Upward_Short -> x:A_ZMB_Shambler_Attack_Swipe_LH_Upward_Short
AM_ZMB_Shambler_SwipeL_Upward_Short_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_LH_Upward_Short
AM_ZMB_Shambler_SwipeL_Vert_Short -> x:A_ZMB_Walker_Attack_Swipe_LH_Vert_Attack_Short
AM_ZMB_Shambler_SwipeL_Vert_Short_FixedWindUp -> x:A_ZMB_Walker_Attack_Swipe_LH_Vert_Attack_Short
AM_ZMB_Shambler_SwipeR_Horiz_Long -> x:A_ZMB_Shambler_Attack_Swipe_RH_Horiz_Long
AM_ZMB_Shambler_SwipeR_Horiz_Long_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_RH_Horiz_Long
AM_ZMB_Shambler_SwipeR_Horiz_Short -> x:A_ZMB_Shambler_Attack_Swipe_RH_Horiz_Short
AM_ZMB_Shambler_SwipeR_Horiz_Short_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_RH_Horiz_Short
AM_ZMB_Shambler_SwipeR_Upward_Long -> x:A_ZMB_Shambler_Attack_Swipe_RH_Upward_Long
AM_ZMB_Shambler_SwipeR_Upward_Long_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_RH_Upward_Long
AM_ZMB_Shambler_SwipeR_Upward_Med -> x:A_ZMB_Shambler_Attack_Swipe_RH_Upward_Med
AM_ZMB_Shambler_SwipeR_Upward_Med_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_RH_Upward_Med
AM_ZMB_Shambler_SwipeR_Upward_Short -> x:A_ZMB_Shambler_Attack_Swipe_RH_Upward_Short
AM_ZMB_Shambler_SwipeR_Upward_Short_FixedWindUp -> x:A_ZMB_Shambler_Attack_Swipe_RH_Upward_Short
AM_ZMB_Shambler_SwipeR_Vert_Short -> x:A_ZMB_Walker_Attack_Swipe_RH_Vert_Attack_Short
AM_ZMB_Shambler_SwipeR_Vert_Short_FixedWindUp -> x:A_ZMB_Walker_Attack_Swipe_RH_Vert_Attack_Short
AM_ZMB_Thug_Attack_Flail_1Hit_LH -> x:A_ZMB_Thug_Attack_Flail_End_LH
AM_ZMB_Thug_Attack_Flail_1Hit_RH -> x:A_ZMB_Thug_Attack_Flail_End_RH
AM_ZMB_Thug_Attack_Flail_Main -> x:A_ZMB_Thug_Attack_Flail_WindUp_RH, x:A_ZMB_Thug_Attack_Flail_Med, x:A_ZMB_Thug_Attack_Flail_End_LH
AM_ZMB_Thug_Attack_Punch_LH_Long -> x:A_ZMB_Thug_Attack_Punch_LH_Long
AM_ZMB_Thug_Attack_Punch_LH_Short -> x:A_ZMB_Thug_Attack_Punch_LH_Short
AM_ZMB_Thug_Attack_Punch_RH_Long -> x:A_ZMB_Thug_Attack_Punch_RH_Long
AM_ZMB_Thug_Attack_Punch_RH_Short -> x:A_ZMB_Thug_Attack_Punch_RH_Short
AM_ZMB_Thug_Attack_Smash_Aggressive_Med -> x:A_ZMB_Thug_Attack_Smash_IntoStatic_Med, x:A_ZMB_Thug_Attack_Smash_Aggressive_Med
AM_ZMB_Thug_Attack_Smash_Aggressive_Short -> x:A_ZMB_Thug_Attack_Smash_Aggressive_Short
AM_ZMB_Thug_Attack_Smash_Long -> x:A_ZMB_Thug_Attack_Smash_IntoStatic_Long, x:A_ZMB_Thug_Attack_Smash_Long
AM_ZMB_Thug_Attack_Smash_Short -> x:A_ZMB_Thug_Attack_Smash_IntoStatic_Short, x:A_ZMB_Thug_Attack_Smash_Short
AM_ZMB_Thug_Attack_Smash_Short_FixedWindUp -> x:A_ZMB_Thug_Attack_Smash_IntoStatic_Short
AM_ZMB_Thug_OutOfReach_SwipeUp_L -> x:A_ZMB_Thug_OutOfReach_SwipeUp_L
AM_ZMB_Thug_OutOfReach_SwipeUp_R -> x:A_ZMB_Thug_OutOfReach_SwipeUp_R
AM_ZMB_Walker_Attack_Bite_Long -> x:A_ZMB_Walker_Attack_Bite_Attack_IntoStatic_Long, x:A_ZMB_Walker_Attack_Bite_Attack_Long
AM_ZMB_Walker_Attack_Bite_Long_FixedWindUp -> x:A_ZMB_Walker_Attack_Bite_Attack_IntoStatic_Long
AM_ZMB_Walker_Attack_Bite_Short_FixedWindUp -> x:A_ZMB_Walker_Attack_Bite_Attack_IntoStatic_Short
AM_ZMB_Walker_Attack_Lurch_Long -> x:A_ZMB_Walker_Attack_Lurch_Attack_IntoMoving_Long, x:A_ZMB_Walker_Attack_Lurch_Attack_Long
AM_ZMB_Walker_Attack_Lurch_Long_FixedWindUp -> x:A_ZMB_Walker_Attack_Lurch_Attack_IntoMoving_Long
AM_ZMB_Walker_Attack_Lurch_ScriptedEntrance -> x:A_ZMB_Walker_Attack_Lurch_Attack_IntoMoving_Long, x:A_ZMB_Walker_Attack_Lurch_Attack_Long
AM_ZMB_Walker_Attack_Lurch_Short -> x:A_ZMB_Walker_Attack_Lurch_Attack_IntoStatic_Short, x:A_ZMB_Walker_Attack_Lurch_Attack_Short
AM_ZMB_Walker_Attack_Lurch_Short_FixedWindUp -> x:A_ZMB_Walker_Attack_Lurch_Attack_IntoStatic_Short
AM_ZMB_Walker_Attack_Windmill_End_LH -> x:A_ZMB_Walker_Attack_Windmill_Impact_LH
AM_ZMB_Walker_Attack_Windmill_End_RH -> x:A_ZMB_Walker_Attack_Windmill_Impact_RH
AM_ZMB_Walker_Attack_Windmill_Fast -> x:A_ZMB_Walker_Attack_Windmill_IntoMoving, x:A_ZMB_Walker_Attack_Windmill_Cycle_Fast, x:A_ZMB_Walker_Attack_Windmill_End_RH_Fast
AM_ZMB_Walker_Attack_Windmill_Slow -> x:A_ZMB_Walker_Attack_Windmill_WindUp_Short, x:A_ZMB_Walker_Attack_Windmill_Cycle_Slow, x:A_ZMB_Walker_Attack_Windmill_End_RH_Slow
AM_ZMB_Walker_Grapple_Miss_Long -> x:A_ZMB_Walker_Attack_Grapple_IntoMoving_Long, x:A_ZMB_Walker_Attack_Grapple_Miss_Long
AM_ZMB_Walker_Grapple_Miss_Short -> x:A_ZMB_Walker_Attack_Grapple_IntoMoving_Short, x:A_ZMB_Walker_Attack_Grapple_Miss_Short
AM_ZMB_Walker_Grapple_ScriptedEntrance -> x:A_ZMB_Walker_Attack_Grapple_IntoMoving_Long, x:A_ZMB_Walker_Attack_Grapple_Miss_Long
AM_ZMB_Walker_OutOfReach_SwipeForward_L_01 -> x:A_ZMB_Walker_OutOfReach_SwipeForward_L_01
AM_ZMB_Walker_OutOfReach_SwipeForward_L_02 -> x:A_ZMB_Walker_OutOfReach_SwipeForward_L_02
AM_ZMB_Walker_OutOfReach_SwipeForward_R_01 -> x:A_ZMB_Walker_OutOfReach_SwipeForward_R_01
AM_ZMB_Walker_OutOfReach_SwipeForward_R_02 -> x:A_ZMB_Walker_OutOfReach_SwipeForward_R_02
AM_ZMB_Walker_OutOfReach_SwipeUp_L_01 -> x:A_ZMB_Walker_OutOfReach_SwipeUp_L_01
AM_ZMB_Walker_OutOfReach_SwipeUp_L_02 -> x:A_ZMB_Walker_OutOfReach_SwipeUp_L_02
AM_ZMB_Walker_OutOfReach_SwipeUp_R_01 -> x:A_ZMB_Walker_OutOfReach_SwipeUp_R_01
AM_ZMB_Walker_OutOfReach_SwipeUp_R_02 -> x:A_ZMB_Walker_OutOfReach_SwipeUp_R_02
AM_ZMB_Walker_SwipeL_Upward_Long -> x:A_ZMB_Attack_Swipe_LH_Upward_Attack_Long
AM_ZMB_Walker_SwipeL_Upward_Long_FixedWindUp -> x:A_ZMB_Attack_Swipe_LH_Upward_Attack_Long
AM_ZMB_Walker_SwipeL_Upward_Med -> x:A_ZMB_Attack_Swipe_LH_Upward_Attack_Med
AM_ZMB_Walker_SwipeL_Upward_Med_FixedWindUp -> x:A_ZMB_Attack_Swipe_LH_Upward_Attack_Med
AM_ZMB_Walker_SwipeL_Upward_Short -> x:A_ZMB_Attack_Swipe_LH_Upward_Attack_Short
AM_ZMB_Walker_SwipeL_Upward_Short_FixedWindUp -> x:A_ZMB_Attack_Swipe_LH_Upward_Attack_Short
AM_ZMB_Walker_SwipeR_Upward_Long -> x:A_ZMB_Attack_Swipe_RH_Upward_Attack_Long
AM_ZMB_Walker_SwipeR_Upward_Long_FixedWindUp -> x:A_ZMB_Attack_Swipe_RH_Upward_Attack_Long
AM_ZMB_Walker_SwipeR_Upward_Med -> x:A_ZMB_Attack_Swipe_RH_Upward_Attack_Med
AM_ZMB_Walker_SwipeR_Upward_Med_FixedWindUp -> x:A_ZMB_Attack_Swipe_RH_Upward_Attack_Med
AM_ZMB_Walker_SwipeR_Upward_Short -> x:A_ZMB_Attack_Swipe_RH_Upward_Attack_Short
AM_ZMB_Walker_SwipeR_Upward_Short_FixedWindUp -> x:A_ZMB_Attack_Swipe_RH_Upward_Attack_Short
```
