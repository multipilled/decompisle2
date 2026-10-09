# DI2 zombie hit reactions (CT_HitReact_* trees)

## Hand-off (2026-10-08, port-di2-hit-react-trees session) - read first

**State.** DI2's trees drive zombie reactions (section 11 and recon/ANIMATION.md section 8). The files are:
- `hit_react_trees.gd`: tree walk, anim-set pick, remaps, direction facts.
- `launch_math.gd`: ULaunchSettings impulses.
- `di2_expr.gd`: KB expressions.
- `zombie_reactions.gd`: responses, plus the KO hold -> ragdoll -> recharge -> StandUp sequence.

Open stand-ins are in recon/UNVERIFIED.md #58. `zombie_reactions.gd` is now unowned, so ask the coordinator before you edit it.

**Done and verified.**
- **Tree walks** (`walk.gd`) give the documented responses:

  | Hit | Response |
  |---|---|
  | Force 12 | Small |
  | Force 24 | StumbleSmall |
  | Force 35, heavy | StumbleMedium |
  | No interrupt | procedural |
  | Killing blow, Force 20 | KOMedium |
  | Stability 0 | KO |
  | CanLaunch | Launch |

- **Ported from the exe, with code comments:**
  - FRangeRemapSettings: 0x141b07560.
  - Direction facts: 0x1412c6a20 (cos 45 = 0.70710677).
  - Posture: 0.0871558.
  - ULaunchSettings: ctor defaults and impulse math.
  - StandingUpPosition: 0x141209860 -> 0x141209680 (eps at 0x14687ace8).
  - BP_Action_Ragdoll_AI: recharge (0.6 s at zero stability, then the knockdown duration, min 0.4, 1.0 after impacts while down).
  - BP_Base_AI.InitHitReactBalacingData: CTI scalars.
- **Captures** (`game/test_out/hitsel/cap2`): z_ko, z_launch and z_knockdown run hit / KO -> ragdoll air -> settle -> recharge -> get-up in that order, with no script errors.
- **Flesh suite:** passes with 0 script errors.

**Open RE (exe addresses). P3: extra fidelity; no other workstream waits on it.**
- **Get-up capsule alignment:** the StandUp ctor reads +0xbc (<= 2.0 s). The port aligns at once.
- **Lying orientation:** the EStandUpOrientation -> FName table at 0x141209920 isn't read. The ragdoll root transform (RagdollStateComponent +0x9c0) is stood in for by the pelvis.
- **Unported paths:**
  - LaunchCharacterAction's non-ragdoll branch: 0x1411ca9f0 / 0x1411cec90.
  - The Ragdoll action's IntoMontage path: 0x1411e93a0.
- **Native code not yet located:**
  - `HitReactInterrupt` / `MinimumHitReaction` setter (#H9).
  - Stun-lock counting (#H19).
  - ApplyFlinchImpulse input (#H20).
  - RagdollLanded / RagdollResting thresholds.

**Perf regression (flesh perf_check 51 -> 123 ms "process"): cause and fix.**
- **Cause.** DI2Expr re-tokenized every expression and every alias it reached on each evaluation. It also evaluated every operand of `||` / `&&`.
  - One `select()` cost 13.5 ms per hit. Of that, `HitReactTrees.evaluate` was 13.7 ms and `#SuppressAllHitReacts` alone 2.8 ms; `pick_montage` added 2.7 ms.
  - perf_check makes its 8 hits in one frame, which therefore cost about 130 ms.
  - `Performance.TIME_PROCESS` is the maximum over the last second, so that single frame dominates perf_check's 2 s average. FPS hardly changed.
- **Fix.** `di2_expr.gd` now parses each string once into a cached node tree and short-circuits `||` / `&&`. The grammar and API are unchanged.
- **Equivalence test** (`game/test_out/hitsel/expr_equiv.gd`):
  - Inputs: all 799 expression strings in game/data, each over 12 random fact sets.
  - Reference: the old evaluator, kept at `test_out/hitsel/di2_expr_old.gd`.
  - Result: 0 mismatches, 8.1x faster.
- **After the fix** (`perf2.gd`, per hit):

  | Call | Before | After |
  |---|---|---|
  | `select()` | 13.5 ms | 0.59 ms |
  | `evaluate` | 13.7 ms | 0.33 ms |
  | `pick_montage` | 2.7 ms | 0.16 ms |

- **Warm caches** (`perf.gd`): 8 hits cost 37.7 ms in `take_hit` with DI2 reactions, against 27.4 ms with no reaction (Empty_AI).
- **Flesh suite** (`TEST_OUT=game/test_out/hitsel/suite tools/run_all_tests.sh flesh`): exit 0 with 0 script errors.

  | perf_check | 14:54 (before) | After the fix |
  |---|---|---|
  | After hits | 105.5 ms | 44.7 ms |
  | After hits, no particles | 79.9 ms | 24.9 ms |
  | Idle | 12.1 ms | 10.9 ms |

  The 13:2x baseline before the port was 51 ms after hits.
- **Not changed:** `HitReactTrees.ensure()` still costs 24 ms on its first load, which lands on the first hit of a run.

**Open, for fresh sessions, in priority order (P1 critical path, P2 milestone, P3 polish).**
1. **P2: get-up flashes one stale frame.**
   - What happens: `_stand_up` frees the ragdoll. Until DI2Anim evaluates again, the skeleton shows its old animated bone poses (standing idle) for one frame. In capture `game/test_out/hitsel/cap2/anim/z_ko.jsonl`, the pelvis is at 0.97 m at f539, then from f540 it is exactly on the ragdoll pose. z_launch (f492) and z_knockdown (f490) show the same.
   - Fix: in `zombie_reactions.gd` `_stand_up`, right after the snapshot is filled, write it to the skeleton (or evaluate `z.anim_ctl.a` once).
   - Lead on the late evaluation: `zombie_anim._process` returns early when `not z.anim.is_playing()`.
   - Already fine in cap2 (report.txt): the KO montage -> ragdoll hand-off (<= 3.8 cm per frame) and the ragdoll air / settle / recharge phases.
2. **P2: missing clips** (brief from animations, a worker). Without these clips, 154 reaction sequences play nothing.
   - Source: extract hit_reacts.json `clips_missing` with `tools/di2x.sh rawanim` (new files only).
   - Output: skin-only per-body glbs `game/assets/di2/zombie_reacts/<body>_reacts.glb`.
   - Build them like `tools/build_zombie_facial.py`: copy `facial_glb()`, keep all bones, use `merge_anims.retarget`, and keep merge_anims' root-track extraction so montage root motion works.
   - Register the glbs in `DI2Anim.extra` the way `ZombieAnim.FaceLayer._load_lib` does, and add them to the per-body segments in `montages_zombie.json`.
   - Run the headless `--import` under with_lock afterwards.
   - Never touch the body glbs or `<body>/clips.json`; bodies / combat own them.
3. P3: `game/test_out/hitsel/standup_map.gd` is written but not run. It checks FaceDown -> 'Front' etc. against the first frames of the KO_Recovery_* clips.
4. P3: call `HitReactTrees.ensure()` at spawn so its 24 ms first load doesn't land on the first hit.

**Test tools.**
- Scripts: `game/test_out/hitsel/{check,walk,perf,perf2,expr_equiv}.gd`.
- `anim_capture.gd` scenarios: z_hits, z_knockdown, z_launch, z_ko, z_death_ko.
- Report: `python tools/anim_report.py <dir>`.
- Script check (headless): `tools/with_cpu.sh <you> tools/with_lock.sh <you> tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://test_out/hitsel/expr_equiv.gd`.
- Off-screen scripts: `RUN_TEST_ENGINE_ARGS="--script res://test_out/hitsel/perf.gd" tools/with_cpu.sh <you> tools/with_lock.sh <you> tools/run_test.sh`.
- Captures: `RUN_TEST_ENGINE_ARGS="--fixed-fps 60" tools/with_lock.sh <you> tools/run_test.sh --combattest=<dir> --animcap=z_ko,z_launch,z_knockdown`.
- Flesh suite into your own folder: `TEST_OUT=game/test_out/<you>/suite tools/run_all_tests.sh flesh`.

How Dead Island 2 chooses a zombie's reaction to a hit (flinch, stumble, knockdown, death, launch, ragdoll,
head organs, bisection), extracted from the user's own install for the port. Everything below comes from DI2's
data (`extracted/json`) or static reading of the shipping exe. Anything not settled that way is marked
**UNVERIFIED** and collected in section 10.

- Data: `game/data/hit_reacts.json`
- Builder: `python tools/build_hit_reacts.py [--missing <file>] [--fetch]` (about 1 s)
- Related: hit *effects* (wounds, blood) are a separate system, see `tools/build_hit_effects.py` and
  `game/scripts/flesh.gd`. This document covers only the reaction side.

## 0. Status

Every DI2 asset the extraction references is now dumped (`missing` is empty). The dumps were done in passes
through `tools/with_cpu.sh` with the main session's OK; they only added new files under `extracted/json`.

| Part | State |
|---|---|
| Tree sets (Common / Special_Large / Butcher), all 28 reachable HitReactTrees, 2 modules, 106 responses | complete |
| Response parameters (anim set names, play-weight remaps, rate deviations, KB counter facts, CEs, launch settings) | complete; BP response CDO defaults merged |
| Archetype wiring for Walker / Runner / Shambler / Thug: tree set, stability, stun-lock, collections, anim sets | complete |
| Launch settings (+ impulse filter sets), corpse / killing-blow flinch curves, `HitReactions.Launch` | complete |
| Montage → port clip mapping | 536 montages dumped, 368 map to a clip. The rest are **missing from the port's glbs** (`clips_missing`: 154 sequences for Walker / Runner / Shambler, 153 for Thug) |

To rebuild after new dumps or clip merges:

```bash
python tools/build_hit_reacts.py
```

If a future DI2 change adds references, `tools/with_cpu.sh hitreacts python tools/build_hit_reacts.py --fetch`
dumps only the missing names (never re-dumps an existing file) and rebuilds until nothing is missing.

**Clips the port lacks.** The Walker's `clips.json` has none of these sequence families, so their montages
have no clip (the same holds for the other bodies, which copy the Walker's `A_ZMB_Base_*` reaction clips):
- `A_ZMB_Base_Hit_Stumble_Light_*`: StumbleSmall, the most common interrupting reaction
- `A_ZMB_Base_Ko_Stumble_Light_*` / `_Med_*`: KOStumbleSmall / KOStumbleMedium
- `A_ZMB_Base_Hit_Recovery_Hunched/OnKnees/OnFeet/PushUp/SitUp_*`: DuringRecovery
- `A_ZMB_Base_Hit_Ground_*` / `A_ZMB_Crawler_Hit_Ground_*`: DuringRagdoll
- `A_ZMB_Base_Ko_Environmental*`, `A_ZMB_Base_StatusFX_Electrocuted_Ko_*`, `A_ZMB_Base_Ko_Recovery_Crawler_*`

`hit_reacts.json` → `clips_missing.<body>` lists the exact sequence names to merge (for the session that owns
the bodies' glbs and `clips.json`).

Montages cannot be mapped by name. Of the dumped zombie reaction montages, most wrap a sequence whose name is
not `A_` + the montage suffix (e.g. `AM_ZMB_Base_Crawler_Hit_Light_LH_Head_F` wraps
`A_ZMB_Base_Crawler_Hit_Light_LH_Head_F_01`). Always go through `montages.<AM>.slots[].segments[].seq`.

## 1. Pipeline

```
hit ──► facts ({Hit}.*, {Victim}.*, {Attacker}.*, bare victim KB facts)
     ──► HitReactTreeSet: first entry whose expression holds ──► HitReactTree
     ──► walk the tree: response nodes fire and continue, link nodes run another tree in place
     ──► responses, in order: CE (vocal), KB counter facts, animated flinch / stumble / knockdown / death,
         ragdoll, launch, organ parts, bisection, status effect ...
     ──► animated responses name an anim set ("HitReactions.Small")
     ──► the zombie's AnimSetCollections resolve it to an AnimSetData
     ──► the first group whose expression holds (and that has items) ──► weighted / ordered pick ──► montage
     ──► montage ──► AnimSequence ──► port clip (game/assets/di2/<body>/clips.json)
```

The archetype's `HitDeathReactionsClass` component (native class `HitDeathReactions`) evaluates this. Its
`HitReactTrees` property names the tree set (section 2).

## 2. Archetype wiring (`archetypes` in the JSON)

Each archetype BP CDO is followed through its template chain (`BP_Base_<Type>` → `BP_Base_Zombie` →
`BP_Base_AI`), and each component BP through its parent chain. The most derived value wins.

| | Walker | Runner | Shambler | Thug |
|---|---|---|---|---|
| Hit-death component | `BPC_HitDeathReactions_Walker` | `_Runner` | `_Shambler` | `_Special_Large` |
| **Tree set** (`HitReactTrees`) | Zombie_Common | Zombie_Common | Zombie_Common | **Zombie_Special_Large** |
| `bDetectStunLock` | true | true | **false** | true |
| `ConsecutiveHitReactsForStunLock` | native default (unset) | native default (unset) | native default (unset) | **2** |
| `ResetStunLockCounterGraceTime` | 2.5 | 2.5 | 2.5 | **4.0** |
| `TimeHitReactingForAutoStunLock` | 10 | 10 | 10 | 10 |
| `LaunchWeightScalar` (`{Victim}.LaunchWeightScalar`) | 1.0 | 1.0 | **1.4** | 1.0 |
| `CanBeLaunched` | true | true | true | native default (unset) |
| Stability component | `BPC_Stability_Walker` | `_Runner` | `_Shambler` | `_Thug` → `_Special_Large` |
| `MaxStamina` (stability pool) | 500 | 500 | 400 | 680 |
| Leg stability damage multiplier | 1.25 | **1.45** | 1.25 | 1.25 |
| Stability cooldown / recharge | base curves | base curves | base curves | `CooldownSeconds` 20, `CooldownSecondsFromZero` 999, `TimeToFullyRecharge` 8 s |
| HitReactions collection | `HitReactions_Zombie` | `HitReactions_Runner` | `HitReactions_Zombie` | `HitReactions_Zombie` |
| `GrappleExit` set | `DA_AnimSet_GrappleExit_Walker` | `_Runner` | none | none |
| `StandUp` set (get-up) | `StandUp_Fast_Zombie` | `StandUp_VeryFast_Zombie` | `StandUp_Slow_Zombie` | `StandUp_Fast_Zombie` |
| VulnerableRequirement Light / Medium / Heavy | `!#HitReactState_WindUp && !#HitReactState_Attack` / `!#HitReactState_Attack` / `""` | `!#HitReactState_Attack` / `""` / `""` | `!#HitReactState_Attack` / `""` / `""` | `False` / `InterruptionInviteState \|\| AttackRecoveryState` / same |
| ArchetypeSpecificFacts | IsWalker, CanFeast, CanBangOnSurface, …, **AllowGrappleInterruption** | IsRunner, … | IsShambler, CanFeast, **Frail**, … | IsThug, **SuppressCounterable**, **LargeSpecial** |
| ForceInterrupt levels VeryLow…Max | 0.12 0.24 0.33 0.44 0.5 1.0 | 0.3 0.5 0.6 0.75 0.8 1.0 | 0.1 0.19 0.31 0.54 0.75 1.0 | 0.11 0.136 0.143 0.2 0.4 1.0 |

Every body's hit-death component inherits `HitReactActionDefinitions = DA_ActionDefinitions_HitReact_Zombie`,
`StunLockingHitReactActionNames = [DismembermentReact, MajorAnimatedFlinch, AnimatedKnockback]` and
`NetworkResolutionTable = DA_HitReactNetResolutionTable_Shared` from `BPC_HitDeathReactions_Zombie` /
`BPC_Base_HitDeathReactions_AI`. The stun-lock settings are the inputs of `{Victim}.StunLocked` (used by
`#NotStunLocked`); the counting itself is native (**#H19**).

The Thug runs the Special_Large set and carries the `LargeSpecial` fact. That selects the `LargeSpecial`
branches in Knockdown_Zombie (KnockdownStun status instead of a KO), StumbleSmall / StumbleMedium and
Interrupting (no knockback edge-detection launch). Its Light vulnerability is `False`.

**ForceInterrupt.** Attack montages carry `BP_AnimNotifyState_ModifiableValues_InterruptThreshold_<Type>`
windows with a `MappingValue` (e.g. `AM_ZMB_Walker_Attack_Lurch_Impact`: `Low` from 0.167 s for 0.611 s). The
notify's `DA_ForceInterruptThreshold_<Type>` maps the level to a value. `DA_ModifiableValueDef_ForceInterruptThreshold`
pushes that value to the zombie's KB as `ForceInterrupt` and resolves overlapping windows by taking the
maximum. No tree or alias reads `ForceInterrupt`, so native code consumes it. It is the best lead for
`HitReactInterrupt` and the `HitReactStabilityCTI*` multipliers (**#H8, #H9**).

Anim set names are `CollectionName.Key`. The collection whose `CollectionName` is `HitReactions` answers
`HitReactions.Small`. A name without a dot (`GrappleExit`, `StandUp`) is looked up in collections with no
`CollectionName` (the `*_Misc` ones). The first listed collection that has the key wins (**UNVERIFIED #H2**:
the order of precedence is native; no two collections of these four bodies share a key, so they are
unaffected).

## 3. Tree sets (`tree_sets`)

`DA_HitReactTreeSet_Zombie_Common`. The first entry whose expression holds is used, and an empty expression
always holds. The `net` policy (Everyone / ServerOnly) does not matter single-player.

| # | Tree | Expression |
|--:|---|---|
| 0 | Empty_AI | `#SuppressAllHitReacts` |
| 1 | Turbine | `{Hit}.TurbineKill \|\| {Hit}.TurbineBlow` |
| 2 | RagdollBackup | `#RagdollBackupRequired` |
| 3 | GrappleInterruption_Zombie | `#GrappleInterruptionRequirement` |
| 4 | PairedAnimImpact_AI | `{Hit}.PairedAnimImpact` |
| 5 | Death_Zombie | `{Hit}.KillingBlow` |
| 6 | Dead_AI | `{Victim}.Dead` |
| 7 | DuringRagdoll_AI | `{Victim}.Ragdoll` |
| 8 | Traversal_Zombie | `{Victim}.NavLinkTraversal` |
| 9–14 | Knockdown / Dismemberment / GrappleExit / Empty / Hit, crawler versions | `{Victim}.Crawler && ...` |
| 15 | Knockdown_Zombie | `{Victim}.StabilityFraction <= 0` |
| 16 | Knockdown_Zombie | `#ClassExclusiveKickHitReactRequirements \|\| ({Hit}.CanLaunch && Disoriented && {Hit}.ImpactMod) \|\| #ShoulderBargeHitReactRequirements` |
| 17 | Dismemberment_Zombie | `#LimbKilled` |
| 18 | GrappleExit_Zombie | `{Hit}.GrappleKickExit` |
| 19 | Empty_AI | `{Hit}.ImpactEventType == "General"` |
| 20 | Hit_ArmouredImpact_Zombie | `#IsArmouredImpact` |
| 21 | Hit_Zombie | (always) |

## 4. The trees, condensed

Names drop the `CT_HitReact_` prefix. "→" means continue to the next node. Every response is listed with its
anim set or parameters. Exact node graphs are in the JSON.

- **Hit_Zombie** (the normal hit): CE `CE_HitReact_Standard_Zombie` @Head → link **Organs_Head_Zombie** →
  module **InterruptionLevel_Zombie**:
  - `Interrupting` → link **Interrupting_Zombie**
  - `Medium Layered` → MinorAnimatedFlinch `HitReactions.LayeredMedium`
  - `Small Layered` → MinorAnimatedFlinch `HitReactions.LayeredSmall`
  - `Upper Body Layered` → MinorAnimatedFlinch `HitReactions.LayeredMedium_UpperBody`
  - `Backup` → link **Backup_AI**
- **InterruptionLevel_Zombie** (module), tested in order:
  1. `GuardingAgainstHitReactInterruption` → Backup
  2. `{Victim}.KOStun` → Upper Body Layered
  3. `#StateForStationaryLayeredReact` (= `Counterable && !LargeSpecial && !MediumSpecial`) → `#SmallStabilityDamage` ? Medium Layered : Small Layered
  4. `HitReactInterrupt` → Interrupting
  5. otherwise → Backup
- **Interrupting_Zombie** (full-body interrupt):
  - `{Hit}.FluidImpact` → KB `StunLock_FluidImpact` 4 s, then joins the next line.
  - `PoseContextDesired` (or `{Victim}.Crouch`) → KB `StopActions` 0.3 s → AnimatedKnockback `HitReactions.DuringRecovery`
  - else, first that holds:
    - `#LargeStabilityDamage` or `MinimumHitReaction == "MediumStumble"` → **StumbleMedium_AI**
    - `#MediumStabilityDamage` or `MinimumHitReaction == "Stumble"` → **StumbleSmall_AI**
    - `{Victim}.AnimatedKnockback && {Victim}.Stumbling` → **Backup_AI**
    - `#SmallStabilityDamage`, `MinimumHitReaction == "Medium"` or `#AnySpecialAttack && (!{Hit}.Flurry || !{Hit}.Rapid)` → **Medium_AI**
    - otherwise → **Small_AI**
- **Small_AI** / **Medium_AI**: KB `StopActions` 0.3 s → MajorAnimatedFlinch `HitReactions.Small` / `.Medium`.
- **StumbleSmall_AI** / **StumbleMedium_AI**: KB `StopActions` 0.3 s → AnimatedKnockback
  `HitReactions.StumbleSmall` / `.StumbleMedium`. The `{Victim}.LargeSpecial` branch only nulls
  `EdgeDetectionLaunchSettings`.
- **Backup_AI** (no animated reaction):
  - Leg hit, not a crawler, no cooldown → KB `LegHitSlowdownCooldown` 15 s and KB `Hit` 1.5 s.
  - Then if `{Hit}.CanCauseCosmeticFlinches`: ranged hits are rate-limited by KB `StunLock_RangedCosmeticFlinch` 0.33 s.
  - Then ProceduralHitReact: strength = remap(`{hit}.force`, 10..40 → 75..130), variation 0.05,
    radial bones `head`, `spine_02`.
- **Knockdown_Zombie** (stability gone):
  - Always: link Organs_Head.
  - `{Victim}.Knockdown` → Backup_AI.
  - LargeSpecial: KOStun ? LayeredMedium_UpperBody flinch : CE Knockdown + status `BP_StatusEffect_KnockdownStun` 9999 s.
  - Otherwise CE `CE_HitReact_Knockdown_Zombie`, then:
    - `#LaunchRequirements` → **Launch_Zombie**
    - standing and `#PoseContextGrounded` → Ragdoll
    - else KnockdownAction with the first that holds: `#LargeStabilityDamage` → `KOStumbleMedium`,
      `#MediumStabilityDamage` → `KOStumbleSmall`, `#StateForStatusEffectHitReact` → `StatusEffectDeath`,
      `#SmallStabilityDamage` → `KOMedium`, else `KOSmall`.
- **Death_Zombie** (killing blow): module **Bisect_Zombie**.
  - `Should Bisect` → BisectionTrigger.
  - `Should Not Bisect` → if not `#Beheaded`: CE `CE_HitReact_Death_Zombie` + link Organs_Head.
  - Then, first that holds:

    | Condition | Response |
    |---|---|
    | in a level sequence | DeathAction `AM_ZMB_Base_Ko_Environmental_Runner_03` |
    | `{Victim}.Ragdoll` | ApplyFlinchImpulse `Curve_KillingBlowFlinches_ImpulseScale_AI` |
    | `#LaunchRequirements` | **Launch_Zombie** |
    | crawler | Ragdoll if knocked down or transitioning, else DeathAction `KOCrawler` / `KOCrawlerBlendLeftFoot` |
    | `{Victim}.Crouch` | `KOMedium` |
    | `{Victim}.KOStun` | DeathAction `AM_ZMB_Base_Ko_Med_Torso_B_Layered` (rate −0.35) |
    | both legs gone | `AM_ZMB_Base_Ko_Med_Stomach_B` (rate −0.5) |
    | `{Victim}.Knockdown` | Ragdoll if `#SmallStabilityDamage`, else nothing |
    | `GuardingAgainstHitReactInterruption`, `#PoseContextGrounded` or `Asleep` | Ragdoll |
    | `PoseContextDesired` or `#LargeStabilityDamage` | `KOStumbleMedium` |
    | `#MediumStabilityDamage` | `KOStumbleSmall` |
    | `#SmallStabilityDamage` | `KOMedium` |
    | `#StateForStatusEffectHitReact` | `StatusEffectDeath` |
    | otherwise | `KOSmall` |

    Note the order: unlike Knockdown_Zombie, Death tests SmallStabilityDamage *before* StatusEffect.
- **Bisect_Zombie** (module): `CanBisect && #CanBeBisected && (BisectionChance >= 1 ? (ThrownAttack ? CanBisectWhenThrown : true) : !(BisectionChance < rnd(0,1)))`.
- **Dismemberment_Zombie** (`#LimbKilled`, not killed): CE `CE_HitReact_Dismemberment_Zombie`, then:
  - in a level sequence → KnockdownAction `AM_ZMB_Base_Ko_Environmental_Runner_03`
  - leg → nothing
  - arm, `KOStun` → LayeredMedium_UpperBody flinch (weight deviation −0.1)
  - arm, `#PoseContextUnsuitableForBlendIntoMontage` or guarding → nothing
  - arm, otherwise → **Interrupting_Zombie**
  - head / torso → nothing
- **Dead_AI** (hit on a corpse):
  - Ragdolled: unless `SuppressCorpseHitReacts`, ApplyFlinchImpulse `Curve_CorpseFlinches_ImpulseScale_AI`
    → Organs_Head → Bisect (BisectionTrigger).
  - Not ragdolled: `#LaunchRequirements` (or `CanLaunch && AlternateLaunchImpact`) → Launch → Organs_Head
    → Bisect; else Ragdoll unless `#HasALeg` → Organs_Head → Bisect. The Organs link continues into the
    Bisect module on every path.
- **DuringRagdoll_AI**: CE Standard. If `{Victim}.RagdollLanded`, AnimatedRagdollHitReact
  `HitReactions.DuringRagdoll` (`DA_ActionDefinition_AnimatedRagdollHitReactAction_AI`).
- **Launch_Zombie**:
  - `ImpactEventType == "General"` → Ragdoll
  - `{Hit}.OverrideLaunchSettings` and no overlap risk → LaunchingImpact with the impact's own settings
  - otherwise LaunchingImpact with an override: Radial → `DA_LaunchSettings_ExplosiveDefault`,
    Ranged → `_RangedDefault`, may overlap geometry → `_MeleeDefault_NoAnimatedLaunches`, else `_MeleeDefault`
- **Organs_Head_Zombie** (head hits): SpawnablePart `Jaw` (spawn / detach) and `LeftEye` / `RightEye`.
  - Gated by `{Victim}.HealthFraction_Head < 0.8`, not a counter.
  - Then `CanBreak` / KillingBlow / Force thresholds (40, 36..70, 110), HealthFraction and `rnd(0,1)` rolls.
  - Stabbing weapons (`{Attacker}.WeaponStabbing`) take their own eye-only branch.
- **PairedAnimImpact_AI**:
  - Always KB `StopActions` (no duration).
  - Counter that does not kill, and non-counter non-kill: Ragdoll + CE Knockdown if stability is 0, else nothing.
  - Counter that kills: nothing.
  - Non-counter kill: Ragdoll → Bisect; if not bisected and not beheaded, CE Death.
- **GrappleInterruption_Zombie**: exit kick → **GrappleExit_Zombie**; else CE Major → **Launch_Zombie**.
- **GrappleExit_Zombie**: CE Major → KB `StopActions` 0.3 → AnimatedKnockback `GrappleExit` (slot `DefaultSlot`)
  → KB `GrappleExitBuffer` 1.5 s.
- **Hit_ArmouredImpact_Zombie**:
  - `ArmourPieceBroken` → Interrupting.
  - Else module InterruptionLevel: `Interrupting` with a kick/slide, `Disorientated` (sic) or
    `#AltAttack_Interrupt_Special` → Interrupting; everything else → Backup_AI.
- **Traversal_Zombie**: `#Impact_SevereInterrupt` or stability 0 → (in a level sequence ? Launch : StumbleMedium); else Backup.
- **RagdollBackup**: Ragdoll. **Empty_AI**: nothing. **Turbine**: Despawn / Ragdoll (DLC turbine).
- Crawler trees (`*_Crawler`) mirror these with `HitReactions.Crawler*` / `KOCrawler*` sets and
  `{Victim}.BlendingFoot == 'BlendLeftFoot'` picking the LH variants.

Sample walks with the exported data (a scratch Python walker), Walker, front torso hit:

| Inputs | Responses |
|---|---|
| Force 12, `HitReactInterrupt` | CE Standard, KB StopActions 0.3, MajorAnimatedFlinch `Small` |
| Force 24, interrupt | KB StopActions 0.3, AnimatedKnockback `StumbleSmall` |
| Force 35 heavy, interrupt | KB StopActions 0.3, `StumbleMedium` |
| Force 12, no interrupt fact | CE Standard, ProceduralHitReact |
| Killing blow, Force 20 | CE Death, DeathAction `KOMedium` |
| Stability 0 | CE Knockdown, KnockdownAction `KOMedium` |

All walks used CTI multipliers of 1.

## 5. JSON format (`game/data/hit_reacts.json`)

Top level: `tree_sets`, `trees`, `modules`, `archetypes`, `parts`, `collections`, `anim_sets`, `montages`,
`assets`, `facts`, `aliases`, `missing`.

**tree_sets**: `{set: [{expr, tree, net}]}`, in order.

**trees** / **modules**: `{name: {kind, start, nodes: {id: node}, outputs?}}`. Node kinds (`bool`, `str`,
`module` and `result` are identical to `hit_effects.json`):

| k | fields | DI2 node | walk |
|---|---|---|---|
| `bool` | expr, t, f | BooleanExpression | t if expr else f |
| `str` | expr, links {value: id}, default | StringExpression | (not used by these trees) |
| `num` | expr, ranges [[min, max, id]], default | NumericExpression | first range containing the value (**UNVERIFIED #H3**: bounds inclusive?); used only with `rnd(0,1)` and ranges 0–0.5 / 0.5–1 |
| `module` | module, links {label: id} | Module | run the module (in `modules`), follow its result's link; missing link ends |
| `result` | label | ModularResult | module output |
| `resp` | r, next | HitDeathReactionResponse | fire `r`, continue at `next` |
| `link` | tree, next | LinkMultipleResults | run `tree` from its start (its responses are added), then continue at `next` |

A null id ends that walk.

**resp.r**: `{class, id, native?, cdo?, ...properties}`:
- expressions are plain strings, object references are asset names;
- for BP responses (`*_C`), `native` is the native parent and `cdo` lists which keys came from the BP CDO;
- remap settings are `{InputValueStartRangeExpression, InputValueEndRangeExpression,
  OutputValueAtStartRangeExpression, OutputValueAtEndRangeExpression}`.

**archetypes**: `{Walker|Runner|Shambler|Thug: {bp, chain, <props>, hit_death_reactions?, stability?,
anim_sets: {name: {collection, set | montage, class}}}}`. `hit_death_reactions` and `stability` appear once
those BPs are dumped.

**parts**: `DT_ZombiePartBoneDefinition`, `{PartId: [bones]}`. These are the `{Hit}.<PartId>` facts.

**collections**: `{collection: {name, keys: {key: {set, class} | {montage}}}}`, only the ones that serve the
names used.

**anim_sets**:
- AnimSetData: `{kind: "groups", groups: [{name, expr, order, null_ok, items: [[weight, montage]]}]}`.
  `order` is `Random` or `FirstThenRandom`.
- AnimSetVelocityData: `{kind: "velocity", speed_groups: [{expr, speed: {lo, lo_type, hi, hi_type},
  angle_groups: [{zero, order, dir, cos_extent, items}]}]}`.

**montages**: `{AM: {dumped, length, rate, blend_in, blend_out, blend_out_trigger, auto_blend_out,
slots: [{slot, segments: [{seq, start, from, to, rate, loops}]}], sections, notifies: [[name, t, dur]],
clips: {body: clip key | [keys]}}}`. `clips` comes from reverse lookup of each body's `clips.json`.

**assets**: referenced data packages, followed through each other: CE_HitReact_* vocal events, `DA_LaunchSettings_*`
(root / mesh impulses, clamps, `OptionalLaunchAnimSetName`, `RagdollBlendInTime`), `DA_ImpulseFilterSet_*`, and
the two flinch impulse curves (`Curve_CorpseFlinches_ImpulseScale_AI` 0→0, 1→2.2; `Curve_KillingBlowFlinches_ImpulseScale_AI`
0→0, 1→7, both linear).

**clips_missing**: `{body: [AnimSequence]}`, the sequences that body's reachable reaction montages play but its
`clips.json` lacks.

**archetypes.<Name>.hit_death_reactions / stability**: `{class, chain, native, ...merged CDO properties}` along
the component's BP parent chain. **force_interrupt**: `{notify, asset, value: "ForceInterrupt", levels}`.

**facts**: `{fact: {scope: Hit | Victim | Attacker | bare, used_by: [...]}}`. These are the leaf facts after
alias expansion. **aliases**: the alias definitions used.

## 6. Facts the trees need, and where they come from

DI2 names are FNames, which are **case-insensitive**: the data mixes `{hit}.leg_left` / `{Hit}.Leg_Left` and
`statuseffect_electrocute` / `StatusEffect_Electrocute`. The data also contains two typos that DI2 evaluates as
unknown, i.e. false:
- `{Hit}.Arm_Righ` in `DA_AnimSet_Reaction_KO_Medium` group `Back90_ArmR`
- `{Hit}.Backe90` in `DA_AnimSet_Reaction_Hit_Crawler_Medium_LH`

For a 1:1 port, keep them false.

### 6.1 Hit facts (`{Hit}.X`, built natively per impact)

| Fact(s) | Meaning / source |
|---|---|
| `Front90 Back90 Left90 Right90 Above90 Below90`, `Front180 Back180 Left180 Right180 Above180 Below180` | **Decoded from the exe**, see 6.4 |
| `VictimUpright / VictimFaceUp / VictimFaceDown` | **Decoded from the exe**, see 6.4 |
| `Head Arm_Left Arm_Right Leg_Left Leg_Right Chest Torso_Upper Torso_Lower Torso_Bisectable` | body part ids from `DT_ZombiePartBoneDefinition` (`parts`). The hit bone's part(s). Whether every row containing the bone is set (spine_03 is in Chest, Torso_Upper and Torso_Bisectable; neck_01 in Head and Chest) is **UNVERIFIED #H4**. Note: the port's `hit_facts()` derives zones from gore-core part ids, which have no torso parts, so `Torso_Upper/Lower` (most reaction groups) are never set today |
| `Force` | impact force (weapon / attack Force, see `weapons.json`; UNVERIFIED #4 covers the native force path) |
| `ImpactForceSeverityBonus` | native, unknown source (**#H5**); 0 is the neutral value in `#ImpactForceSeverity = Force * (1 + bonus)` |
| `KillingBlow`, `Dismembered`, `Broken`, `CanDismember`, `CanBreak` | the damage outcome and the damage type's flags (BP_DamageType_* CDOs) |
| `HeavyAttack`, `CriticalHit`, `ThrownAttack`, `Flurry`, `Rapid`, `Kick`, `Slide`, `ClassExclusiveKick`, `FlyingKick`, `ShoulderBarge`, `GrappleKickExit`, `Counter`, `CounterAction/Push/Kill`, `PairedAnimImpact`, `ControlledFallImpact` | the attack (player move / weapon fire mode) |
| `WeaponClass` | `"Light" / "Medium" / "Heavy"`; the source property is **#H6** |
| `ImpactEventType` | `"General"` (environment / status ticks), `"Radial"` (explosions); other values unknown (**#H6**) |
| `ImpactGameplayCategory` | `"Melee"`, `"Ranged"` (from the impact configuration) |
| `CanLaunch`, `OverrideLaunchSettings`, `ImpactMod` | weapon impact configuration (`bCanLaunch`), weapon mod (CT_WeaponModType facts) |
| `CanCauseCosmeticFlinches`, `FluidImpact`, `ArmouredTorsoImpact`, `Turbine*` | native impact flags (#H6) |

### 6.2 Victim facts (`{Victim}.X` and bare names)

Bare names are read without a scope: `Crawler`, `Ragdoll`, `ImpactEventType`, `StabilityFraction`,
`HitReactInterrupt`, ... The same fact appears both scoped and bare (`{Victim}.Ragdoll` / `Ragdoll`,
`{Hit}.ImpactEventType` / `ImpactEventType`). So the hit's and the victim's facts are both visible unscoped,
which is also what the port's `hit_facts()` does for hit effects. The exact native lookup order is
**UNVERIFIED #H7**.

| Group | Facts | Source |
|---|---|---|
| Stability | `StabilityFraction`, `HitReactStabilityCTIXSmall/Small/Medium/Large` | stability component. The CTI* multipliers scale the 16 / 23 / 30 force requirements. They are not exe strings and not in any dumped asset, including every `BPC_Stability_*` chain and the archetype BPs, so they are computed natively, most likely from the KB `ForceInterrupt` value (section 2) (**#H8**) |
| Interruptibility | `HitReactInterrupt`, `MinimumHitReaction` ("Medium" / "Stumble" / "MediumStumble"), `GuardingAgainstHitReactInterruption`, `Counterable`, `InterruptionInviteState`, `AttackRecoveryState`, `StunLocked` | `GuardingAgainstHitReactInterruption` comes from `BP_AnimNotifyState_ScopedFacts_GuardingAgainstHitReactInterruption` on attack montages. `HitReactInterrupt` and `MinimumHitReaction` are in no dumped asset and are not exe strings (**#H9**). Likeliest inputs: the archetype's `VulnerableRequirement_*` expressions and the KB `ForceInterrupt` value from attack-montage notifies (section 2) |
| State | `Dead`, `Ragdoll`, `RagdollLanded`, `Knockdown`, `KOStun`, `Crawler`, `CrawlerTransition`, `StandingUp`, `Stumbling`, `AnimatedKnockback`, `Crouch`, `Asleep`, `Grapple`, `Counter`, `HeadStompVictim`, `NavLinkTraversal`, `*LevelSequence*`, `PoseContext` ("Hunched", "SitUp", "PushUp", ...), `PoseContextDesired`, `PoseContextUnsuitableForBlendIntoMontage_*`, `BlendingFoot` (`'BlendLeftFoot'`), `StandingUpPosition` ('Front' / 'Back' / 'Left' / 'Right'), `speed`, `statuseffect_electrocute`, `ForceElectrocutedKO1..`, `LargeSpecial`, `MediumSpecial` | the zombie's own state machine / anim notifies / status effects |
| Health | `HealthFraction`, `HealthFraction_Head`, `HealthFraction_Leg_Left/Right`, `HealthFraction_Arm_*`, `HealthFraction_Torso_Bisectable`, `JawDislocated`, `EyeLoose` | multi-part health (`BPC_MultiPartHealth_*`) and spawnable parts |
| Armour | `IsArmoured_Helmet/Torso/LeftArm/...`, `ArmourPieceBroken` | armour attachments (not on the four port bodies) |
| Archetype | `AllowGrappleInterruption` (Walker), `LaunchWeightScalar` (−1 = never launch), `IsWalker`, ... | `ArchetypeSpecificFacts`; `LaunchWeightScalar` is the hit-death component's property (Shambler 1.4, others 1.0) |
| Timed KB facts written by the trees | `StopActions` 0.3, `Hit` 1.5, `LegHitSlowdownCooldown` 15, `StunLock_FluidImpact` 4, `StunLock_RangedCosmeticFlinch` 0.33, `StunLock_Block` 0.3, `GrappleExitBuffer` 1.5 | `KnowledgeBaseCounterResponse {Fact, Duration}`. They add a fact to the victim's KB for Duration seconds. Whether it is a counter or a flag, and what a missing Duration means (PairedAnimImpact's `StopActions`), is native (**#H10**) |

### 6.3 Attacker facts

- `{Attacker}.IsFuryMode`: the player is in fury.
- `{Attacker}.WeaponStabbing`: the weapon stabs (`weapons.json` `stabbing`).

### 6.4 Direction and posture facts (static RE of the shipping exe)

`0x1413c45d0` adds them to the impact's fact set. It is called from `0x1413c5680` and `0x1413c5870`.

**Direction** (`0x1412c6a20` → `0x1412bf9d0` ×3; names from the FName table at `0x146bd2ed0`, filled by
`0x1404c1840`):

1. `T` is the victim transform from `0x1412d21a0`: the root component's ComponentToWorld (actor+0x160 → +0x230),
   or for some character class a transform from `0x141271d10` (unidentified; **#H11**).
2. `d = T.Rotation.UnrotateVector(v)` is the hit vector in the victim's local frame. UE axes:
   forward = +X (`0x14692b848`), right = +Y (`…868`), up = +Z (`…828`).
3. For each `(A, N1, N2, pos180, pos90, neg180, neg90)` in
   `(Fwd, Up, Right, Front180, Front90, Back180, Back90)`,
   `(Right, Up, Fwd, Right180, Right90, Left180, Left90)` and
   `(Up, Fwd, Right, Above180, Above90, Below180, Below90)`:
   ```
   p1 = normalize(d - (d·N1)·N1)     # zero vector if |.|² < 1e-8
   p2 = normalize(d - (d·N2)·N2)
   a1 = A·p1 ; a2 = A·p2
   if a1 >= 0:  add pos180 ; if a1 >= 0.70710677 and a2 >= 0.70710677: add pos90
   else:        add neg180 ; if a1 <= -0.70710677 and a2 <= -0.70710677: add neg90
   ```

So every hit has one of Front180/Back180, one of Right180/Left180 and one of Above180/Below180. The `*90` fact is
the dominant axis of `d` (ties set several). A degenerate projection counts as the positive half
(`0 >= 0`).

`v`: caller `0x1413c5680` passes **−(impact+0xB8)**. Caller `0x1413c5870` passes
`normalize(P − Actor.RootLocation)` with `P = struct+0xD8`. Both point from the victim toward the hit's
source, so `Front90` = "hit came from in front". This is consistent with the montage names (Front90 → `_F`
clips), but the struct fields are not identified (**#H11**).

**Posture** (`0x1412c6920`, FName table `0x146bd2e98`): `s = T.Rotation.RotateVector(+X) · U`, where `U` is
the root component's up vector (`0x1436112b0`) or `(0,0,1)`.
- `s >= 0.0871558` (sin 5°) → `VictimFaceUp`
- `s <= −0.0871558` → `VictimFaceDown`
- otherwise `VictimUpright`

`DA_AnimSet_Reaction_DuringRagdoll` uses these.

The port's `ZombieReactions.dir_code()` (|y| > 0.65 first, then the larger horizontal axis) is not DI2's rule.

## 7. Responses (what each class carries)

| Class (count) | Parameters in data | Port meaning |
|---|---|---|
| MinorAnimatedFlinchHitReactResponse (6) | AnimSetName, MontagePlayWeightDeviation, MaxMontagePlayWeight query + remap, play-rate deviations | layered flinch (`*_Layered` montages / upper body) over the current action |
| MajorAnimatedFlinchHitReactResponse (6) | same | full-body flinch (`HitReactions.Small/Medium`, crawler sets). Interrupts the action (paired with KB `StopActions`) |
| BP_AnimatedKnockbackHitReactResponse_AI_C → AnimatedKnockbackHitReactResponse (7) | AnimSetName, rate ±0.15, weight remap, `EdgeDetectionLaunchSettings` (CDO `DA_LaunchSettings_KnockbackEdgeDetection`, impulse bone `spine_03`; nulled for LargeSpecial), `AnimationSlotToAdopt` | stumble with root motion. Edge detection launches the zombie off ledges (native) |
| KnockdownActionResponse (8) | AnimSetName or ReactionMontageChoices, ApplyMultiVictimMontageDelay | KO montage → down → get-up. `StandUp` (`DA_AnimSet_StandUp_Fast_Zombie`, by `StandingUpPosition` / `#HasBothArms` / Crawler) is exported as an extra. Down time is `DA_AIAttributeValues_<type>.KnockdownDuration` (already in archetypes.json) |
| DeathActionResponse (11) | AnimSetName or ReactionMontageChoices, rate / weight deviations | death montage, then ragdoll (native hand-off **#H12**) |
| RagdollResponse (10) | none | ragdoll now |
| LaunchingImpactResponse (5) | bUseImpactProvidedLaunchSettings, OverrideLaunchSettings | launch with `DA_LaunchSettings_*` (`assets`): e.g. MeleeDefault root impulse 600 clamped 500–1200, blend 0.775 toward the instigator's forward, +0.5 vertical, mesh linear 800, angular 2500, and the `HitReactions.Launch` anim set |
| ApplyFlinchImpulseResponse (2) | ImpulseScale / ImpulseStrengthToBoneTrauma curves (corpse 0→2.2, killing blow 0→7), bIncludeMultiVictimDelayTime | impulse on a ragdoll / corpse; the curve input is native (**#H20**) |
| ProceduralHitReactResponse (1) | strength query + remap, StrengthVariation, RadialImpactReactionBones | physical (PA) flinch, the port's `physical_reaction.gd` |
| SpawnCosmeticEffectResponse (14) | Definition (CE_HitReact_*), SocketName `Head` | vocal: Standard → `DX_Walker_Pain_PLAY` (trigger Breathing/HitReact), Knockdown → `DX_Walker_Knock_Down_Out_PLAY` ... (`assets`) |
| KnowledgeBaseCounterResponse (15) | Fact, Duration | timed victim fact (6.2) |
| SpawnablePartResponse (15) | Slots (Jaw / LeftEye / RightEye), bSpawn, bDetach | head organs |
| BisectionTriggerResponse (3) | none | bisect (not in the port yet) |
| ApplyStatusEffectResponse (1) | BP_StatusEffect_KnockdownStun, 9999 s, Victim | LargeSpecial only |
| BP_AnimatedRagdollHitReactResponse_AI_C (1) | AnimSetName `HitReactions.DuringRagdoll`, action `DA_ActionDefinition_AnimatedRagdollHitReactAction_AI` | animated hit on a landed ragdoll |
| DespawnActorReactionResponse (1) | TurbineKill | DLC only |

**Play weight.** When `bSpecifyMaxMontagePlayWeightUsingRangeRemapper` is set, the montage's maximum blend
weight is `remap(query, InStart..InEnd → OutStart..OutEnd)`. Light hits therefore play the reaction partly
blended. For example Small_AI: query `#ReactWeightingModulation` = 100 for special attacks / kicks / killing
blows, else `Force − 0.2·Force·CanDismember`; range `11 .. 11 + (16−11)·0.7` → `0.8 .. 1`. Whether the remap
clamps outside the range, and how `MontagePlayWeightDeviation` and the rate deviations (±0.15) are sampled, is
native (**#H13**). The native defaults of unset response properties (e.g. MinorAnimatedFlinch without a remap)
are also native (**#H14**).

## 8. Anim set selection

The groups are ordered. The convention used by the port (`class_data.gd`, the hit-effect causer sets) is
"first group whose expression holds and that has items". Most sets end with a catch-all `Default` /
`Front90 No Bone` group. Within a group, `Random` is a weighted random pick (all weights 1 in these sets).
`FirstThenRandom` (crawler sets) presumably plays the first item first, then random. Both orders are native
(**#H15**). `bAllowSingleNullEntry` is false everywhere.

Velocity sets (`StatusEffectDeath`):
- pick the first speed group whose expression holds and whose speed range contains the victim speed
  (bound types Inclusive / Exclusive / Open);
- then the angle group whose `CosAngleRangeCentreExtent` cone around `AngleRangeCentreDirection` contains the
  velocity (`bMatchesZeroVelocity` for standing still).

The details are native (**#H16**).

Slots of the 107 dumped montages:
- 100 use `DefaultSlot`;
- the 7 crawler ground hits (`AM_ZMB_Crawler_Hit_Ground_*`, from `DuringRagdoll`) use the `Ragdoll` slot.

All 536 montages are dumped now: 437 segments in `DefaultSlot`, 47 in `LHR_UpperBody` and 14 in `LHR_FullBody` (the 61 `*_Layered` montages: LayeredSmall / LayeredMedium / LayeredMedium_UpperBody), 15 in `Ragdoll` (ground hits). Blend times vary per montage (layered mostly 0.07–0.08 s in, 0.4–0.7 s out; full-body light hits 0.07 s in, 0.5–0.6 s out); use each montage's own `blend_in` / `blend_out` (null = the UE default).

## 9. Porting into zombie.gd

Owners (COORDINATION.md): `take_hit`, `stagger` and `_physics_process` belong to the combat session, as do
`zombie_reactions.gd` and the reaction selection. This section is the spec for that port.

1. **Load** `res://data/hit_reacts.json` once (like `Flesh._ensure`). Pick the tree set by the body's
   `archetypes.<Name>.hit_death_reactions.HitReactTrees`: Zombie_Common for Walker / Runner / Shambler,
   Zombie_Special_Large for Thug.
2. **Evaluator.** Reuse `Flesh.evaluate`'s loop and add three kinds:
   - `num`: first `[min, max]` containing `value(expr)`
   - `resp`: append `r`, go to `next`
   - `link`: recurse into `trees[tree]` with the same output list, then `next`

   `module` uses `modules` (same as `Flesh.module_result`). Return the ordered response list. Guard against
   cycles (none in the data).
3. **DI2Expr additions** needed by these expressions (`di2_expr.gd` has none of them yet):
   - `*` (in the stability aliases) and `/`
   - `rnd(a, b)` (uniform) and `floatbranch(cond, a, b)`
   - single-quoted strings (`'BlendLeftFoot'`)
   - case-insensitive fact lookup
   - `!a <= 0` (GrappleInterruption) parses as `!(a <= 0)` in `di2_expr.gd`. That gives the same answer as C
     precedence for `StabilityFraction >= 0`.
4. **Facts.** Build one dictionary per hit with `Hit.X`, `Victim.X`, `Attacker.X` and the bare names:
   - Hit: `Force`, `KillingBlow`, `HeavyAttack`, `CriticalHit`, `ThrownAttack`, `Kick` / `Slide` /
     `ClassExclusiveKick` / `ShoulderBarge` (player moves), `GrappleKickExit`, `Counter*`, `Dismembered` /
     `Broken` (gore-core outcomes), `CanDismember` / `CanBreak` (damage type), `CanLaunch` (weapon
     `bCanLaunch`), `ImpactGameplayCategory` ("Melee" / "Ranged"), `ImpactEventType`, `WeaponClass` (#H6).
   - Body-part facts: from `parts` (6.1).
   - Direction and posture facts: per 6.4, with `v` = unit vector from the zombie toward the hit source, in
     the zombie's own forward / right / up.
   - Victim: `StabilityFraction` (gore-core stability), `HitReactStabilityCTI*` (#H8: no data yet; 1.0 is
     the neutral multiplier, but it is a stand-in), `HitReactInterrupt` / `MinimumHitReaction` (#H9),
     `Crawler`, `Knockdown`, `KOStun`, `Ragdoll`, `Dead`, health fractions, `PoseContext`, `speed`.
   - The timed KB facts the responses write (keep a per-zombie `{fact: expiry}` dictionary).
5. **Responses → zombie_reactions.gd:**

   | Response | Port action |
   |---|---|
   | Minor flinch | layered clip at the remapped weight, AI action continues |
   | Major flinch | full-body one-shot |
   | Knockback | root-motion stumble |
   | Knockdown | KO clip → down for KnockdownDuration → `StandUp` set |
   | Death | death clip → ragdoll |
   | Ragdoll / Launch / ApplyFlinchImpulse | `_start_ragdoll` / physics |
   | Procedural | `physical_reaction.gd` |
   | SpawnCosmeticEffect | sound only |
   | SpawnablePart | jaw / eye gibs |
   | Bisection | not ported |

   Pick the montage per 8 from `archetypes.<Name>.anim_sets[AnimSetName].set`, then play
   `montages[AM].clips[<body>]`. A montage without a clip needs its sequence merged first (`clips_missing`, see 0);
   do not substitute a similarly named clip.
6. Layered flinches (`LHR_UpperBody` / `LHR_FullBody` slots) play over the current animation instead of
   replacing it, at the remapped max weight.
7. Keep DI2's typos (6) and the order quirks (Death vs Knockdown tier order) as they are.

## 10. Unknown / UNVERIFIED (H-list)

| # | Question | Lead |
|---|---|---|
| H1 | ~~Which tree set each body uses~~ | **resolved**: Common for Walker / Runner / Shambler, Special_Large for Thug (section 2) |
| H2 | Collection precedence when two collections share a key | native AnimSetCollection lookup |
| H3 | NumericExpression range bounds | native |
| H4 | Which part facts a bone sets (all rows containing it?) | native impact-fact builder; `DT_ZombiePartBoneDefinition` overlaps |
| H5 | `{Hit}.ImpactForceSeverityBonus` | native impact facts |
| H6 | `WeaponClass`, `ImpactEventType` values, `CanCauseCosmeticFlinches`, `FluidImpact` | impact configuration structs |
| H7 | Bare-name lookup scope (victim KB vs hit facts) | native ConditionalTree context |
| H8 | `HitReactStabilityCTIXSmall/Small/Medium/Large` values per archetype | not in any asset (stability BPs checked); lead: the KB `ForceInterrupt` value set by attack-montage notifies (section 2); native RE |
| H9 | Who sets `HitReactInterrupt` / `MinimumHitReaction` | not in any asset or exe string; leads: KB `ForceInterrupt` (attack-montage notifies, `DA_ForceInterruptThreshold_<Type>`), `VulnerableRequirement_*`; native RE |
| H10 | KnowledgeBaseCounterResponse semantics (count vs flag, no-duration case) | native |
| H11 | Direction vector source fields (impact+0xB8, struct+0xD8) and `0x141271d10` transform | struct reflection / more RE |
| H12 | Death montage → ragdoll hand-off timing | native DeathAction |
| H13 | Play-weight remap clamping, rate / weight deviation sampling | native AnimatedFlinch responses |
| H14 | Native defaults of unset response properties | class constructors (RE) |
| H15 | `Random` / `FirstThenRandom` semantics, group choice rule | native AnimSet_DataDriven |
| H16 | AnimSet_Velocity matching | native |
| H17 | ~~Launch settings and flinch curves~~ | **resolved** (`assets`) |
| H18 | ~~Layered montage slots, reaction montage → sequence mapping~~ | **resolved**; what remains is merging the `clips_missing` sequences into the bodies |
| H19 | Stun-lock counting (`ConsecutiveHitReactsForStunLock` native default, `TimeHitReactingForAutoStunLock`, grace time) | native HitDeathReactions |
| H20 | Input of the flinch impulse curves | native ApplyFlinchImpulse |

## 11. Port status (2026-10-08, hit-react port session; details in recon/ANIMATION.md section 8)

The trees now drive `zombie_reactions.gd` (`hit_react_trees.gd`, `launch_math.gd`). H-items settled on the way:

| # | Now |
|---|---|
| H8 | **resolved**: BP_Base_AI.InitHitReactBalacingData writes HitReactStabilityCTILarge / Medium / Small from DT_EnemyGenericData (Walker 1/1/1, Runner .8, Shambler .7/.7/.5, Thug 1.4/1.1/0); CTIXSmall is never written |
| H9 | partly: `HitReactInterrupt` is in no asset or exe string; the only rule in DI2's data is BP_Base_AIController.DetermineIfVulnerableDebug = KB.Evaluate(VulnerableRequirement_<player WeaponClass>) (WeaponClass = the held weapon's FactsSetWhenHeld). Used as the stand-in. `MinimumHitReaction`: still unknown (unset) |
| H12 | **resolved**: KO / death montages end with a `HitReactRagdoll` notify that hands over to the Ragdoll action |
| H13 | **resolved**: FRangeRemapSettings (exe 0x141b07560) clamps (OutStart before the start, OutEnd past the end); deviation sampling: rate 1 + uniform(neg, pos) is still the port's reading |
| H17 | the weapons' own launch settings (DA_LaunchSettings_MeleeDefault_CrowdControl_* / FuryFists / Misc_Low) dumped too; ULaunchSettings native defaults read from its constructor (bApplyRagdoll true, bAnimateLaunch false) |
| LaunchWeightScalar | CanBeLaunched (BP bool, default false) ? LaunchWeightScalar : -1 (InitHitReactBalacingData) -> the Thug never launches |
| CanCauseCosmeticFlinches / CanLaunch | FImpactSettings struct defaults (from cooked deltas): bCanCauseCosmeticFlinches true, bCanLaunch false |
