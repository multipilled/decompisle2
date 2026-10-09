# Animation quality: Dani (1P) and zombies, matched to DI2's animation data

Personal-use research notes for the . recreation. Every value below cites its DI2 source (asset in
`extracted/json`, Blueprint bytecode in `extracted/json_bp`, or an exe address). Items DI2 decides in native code that
could not be recovered are marked **UNVERIFIED**.

## 0. Hand-off (2026-10-09, locomotion round 3 / di2-loco3; next session starts here)

**Done (sections 13-15, commits ca0e1a8, 6b01e7f, e75a049, 35ec54b):**
- Attack-montage root motion: per-sequence bEnableRootMotion / RootMotionRootLock table, root at the ref pose, capsule
  moved by the montage (segment-crossing extraction). The z_walk_chase IntoStatic -> attack pop is gone (pelvis 68 ->
  1.8 cm at the boundary, capsule steps 0.55-0.6 m through the swipe).
- Strafing Move: Fwd / Bwd blend spaces by StrafeAngle, BackwardBlendValue, primary / secondary swap (exe Move entry /
  tick decoded); zombie.gd passes cmd move_dir. Chasing zombies now sample at their facing error.
- LOCO_SETS / MOVE_SETS / LOCO_DEF for Screamer / Slobber / Suicider / Butcher; their clip sets
  zombie_clips/<body>_loco.glb (85 / 73 / 77 / 91 clips, built with build_zombie_clips.py, imported).
- Blend profiles: DI2 has no Inertialization in ABP_ZombieWalker; Starts -> Move uses BlendToRootMotion, whose math is
  now decoded and ported (per-bone weight scales). The z_loco f252 wrap drops 22 -> 14 cm at the foot; the rest is 1:1.
- `tools/run_all_tests.sh combat flesh` (TEST_OUT game/test_out/di2-loco3/suites): exit 0, 0 script / shader errors,
  no [panic.

**Done-checks (game/test_out/di2-loco3/s4, anim_capture.gd z_attack_rm / z_strafe / z_specials_walk):**
- z_attack_rm (AM_ZMB_Walker_SwipeR_Vert_Med, the old f307 case): pelvis 3.6 cm max at the IntoStatic -> attack boundary
  (was 68 cm); the capsule travels 0.69 m with the montage.
- z_strafe: facing -Z, move_dir +X then -X at 1.0 m/s: moved +1.75 m / -1.43 m sideways, yaw 0.0, MoveSwap at +90 / -90,
  combat_straferwd / strafelwd clips, no spike over 1.7 cm.
- z_specials_walk: Screamer / Slobber / Suicider / Butcher run Starts -> Move -> Stops -> Idle on their own sets
  (x:A_ZMB_Screamer_Start_Slow ...), 2.6 / 4.4 / 5.0 / 4.7 m in 4 s at 1.2 m/s.
- `tools/run_all_tests.sh combat flesh` (TEST_OUT game/test_out/di2-loco3/suites2): flesh 0 errors; combat 1 script
  error, not animation: DI2Explosion._apply (di2_explosion.gd:269) passes a freed instigator (the detonated Suicider)
  to Zombie.take_hit. No [panic in either. The earlier run (suites, before the anim_capture scenarios) was 0 / 0.

**Open / follow-ups:**
- Clip rate bug in shared tooling: merge_anims.load_psa / build_zombie_clips use the PSA AnimRate (NumFrames /
  SequenceLength) as the key rate; UE spaces keys at (NumFrames - 1) / SequenceLength. Every built clip runs n / (n - 1)
  fast and holds its end (the 2-frame hold at attack segment boundaries). Owner: whoever owns merge_anims.
- Strafing Starts (StartCombat set) not decoded (UNVERIFIED 99); AttackCorrection warping not ported (98); pivots;
  crawler sets for the specials (100).

## 0. Hand-off (2026-10-09, clip timing Q19 + Q18 / di2-clip-timing; newest, next session starts here)
**Done (commits 3135721, 1f7634c, 52cb49f + this one; details 0q.1-0q.4):**
- merge_anims.load_psa keys PSA clips at (NumFrames - 1) / SequenceLength (UE GetTimeAtFrame); all 51 PSA sequences now
  end exactly at SequenceLength (were up to 14% short). ACL path was already exact (1420 sequences, 0.0%).
- DI2 "_loop" names survive import: merge_anims.keep_clip_names writes `nodes/use_name_suffixes=false` into every
  clip glb's .import (merge_anims + build_zombie_clips). Godot check (game/test_out/di2-clip-timing/loopcheck.log):
  dani medium1h_throw + _loop, medium2h_attack_throw + _loop, skill_groundpound + _loop + _falling_loop all present;
  walker paired_counter_*_loop and screamer scream_loop too; each glb's clip count = its glTF animation count.
- Rebuilt every body (walker, runner, shambler, thug, 4 specials, dani) and every zombie_clips set; set inputs now in
  tools/zombie_clips_{loco,attacks,attacks2,windup,windup_additive}.json. 109 clips changed length > 1% (all PSA).
- Checks: z_attack_rm IntoStatic -> attack boundary hand_r spike 23.3 -> 12.5 cm, pelvis 3.6 cm spike gone; z_loco
  identical to round 3 (ACL clips); z_walk_chase pelvis 3.9 -> 3.2 cm; foot slide unchanged. `run_all_tests.sh
  combat flesh` (TEST_OUT game/test_out/di2-clip-timing/suites): both exit 0, 0 script / shader errors, no [panic;
  all zombie_ai CHECKs ok.

**Next step (Q19/Q18 itself is finished; HOLD from the coordinator 2026-10-09):** coordinator applies the
`_imported()` drop below, then the archetypes owner re-checks archetypes.json speeds against the rebuilt anims.json.
**Open / follow-ups:**
- di2_anim.gd `_imported()` is now dead weight (exact names win in has_clip / clip); proposed to the coordinator to
  drop it (it would otherwise hand back the wrong clip if a "_loop" clip ever went missing).
- Root speeds of the changed PSA clips dropped by n / (n - 1) (e.g. Butcher Combat_Walk_L45_Fast 6.04 -> 5.93 m/s,
  Screamer Stop_Fast 0.33 -> 0.31); anything in archetypes.json copied from those anims.json values is stale (owner:
  archetypes, merge-only). Hit times come from montage notifies, not clip lengths.
- Multi-sequence joined clips keep a one-key boundary interval (UNVERIFIED 107).
- Gotcha: never wrap tools/run_all_tests.sh in with_lock.sh; it takes the lock per suite (deadlocks until yours exits).

## 0q. Brief: clip timing + "_loop" names (queue Q19 + Q18, P1, M4, session di2-clip-timing, 2026-10-09)
Fix PSA clip timing in the clip pipeline (merge_anims.load_psa keyed at the ActorX AnimRate = NumFrames /
SequenceLength; UE keys at SequenceLength / (NumFrames - 1)), rebuild every body's clips and every zombie_clips set
(walker, runner, shambler, thug, the 4 specials, dani; variants borrow class clips), and make DI2's "_loop" clip names
survive Godot's import (Dani pairs medium1h_throw / medium2h_attack_throw / skill_groundpound). Steps: 1 prove + fix
(ACL path checked the same way); 2 "_loop" names, exact DI2Anim._imported() drop proposal to the coordinator; 3 rebuild
through with_cpu one job at a time, anims.json lengths / root speeds before vs after, list clips changed > 1%; 4 re-run
anim_capture z_loco / z_walk_chase / z_attack_rm + tools/anim_report.py. Owns tools/merge_anims.py,
tools/build_zombie_clips.py, tools/zombie_clips_*.json, clips.json / anims.json outputs, the clip glbs, this section,
own UNVERIFIED rows. Done when PSA clip lengths match SequenceLength within a frame, the three Dani pairs import as
separate clips, `tools/run_all_tests.sh combat flesh` 0 script / shader errors and no [panic, zombie_ai CHECKs and
anim_capture checks pass. Then Knowledge notes + lint, hand-off here, short message to the coordinator.

### 0q.1 Step 1: PSA rate (proof and fix)
- Proof (scratch prove_rate.py over every anims.json): 51 PSA sequences, all keys == NumFrames; built length
  (n - 1) / AnimRate vs SequenceLength off by up to 14.3% (A_ZMB_Base_Hit_Launch_Torso_U etc.: 7 keys, AnimRate 35,
  built 0.171 s, SequenceLength 0.2). 1420 ACL sequences: acl13dec's rate already gives (n - 1) / rate ==
  SequenceLength exactly (0.0% worst), so the ACL path was right.
- Fix: load_psa returns rate = (NumFrames - 1) / SequenceLength (UE 4.27 UAnimSequenceBase::GetTimeAtFrame); after it
  all 51 PSA sequences match SequenceLength (0.0%). build_zombie_clips uses load_psa, so it is fixed too.

### 0q.2 Step 2: "_loop" names
- Godot 4.7.2's scene importer renames any clip ending in _loop / -loop / _cycle / _loop_mode (after trailing digits,
  dots, spaces; "$loop" anywhere) to the bare name and sets LOOP_LINEAR (test glb in a scratch project: bar_loop -> bar,
  baz-Loop -> baz). With `nodes/use_name_suffixes=false` in the .import every name survives.
- Route: merge_anims.keep_clip_names(glb) sets that param in the output's .import (patched in place, uid and other params
  kept; minimal .import written if missing); merge_anims.main and build_zombie_clips call it. No renaming, so clip
  names in Godot are exactly the clips.json / anims.json names. Affected today: dani_fp 11 names (the pairs
  medium1h_throw / medium2h_attack_throw / skill_groundpound + jump loops), walker 8 paired_counter_*_loop,
  screamer scream_loop; no zombie_clips or weapon clip names. Loop modes come from the scripts (DI2's graphs), so
  losing the importer's LOOP_LINEAR changes nothing sampled in [0, length].

### 0q.3 Step 3: rebuild (scratch rebuild_one.py, one with_cpu job per body)
- Rebuilt walker, runner, shambler, thug, screamer, slobber, butcher, suicider, dani (merge_anims from the
  extracted/mesh SK_* glbs and each clips.json) and every zombie_clips set (tools/zombie_clips_{loco,attacks,attacks2,
  windup,windup_additive}.json, the first four now written from the existing outputs). Each body glb: non-animation
  glTF json identical to the old one, same clip names / order.
- 3897 clips compared: 109 changed length by > 1%, every one a PSA sequence, now == SequenceLength
  (game/test_out/di2-clip-timing/length_changes.txt). Groups: shared A_ZMB_Base_Hit_Launch_* 0.171 -> 0.2 s (+16.7%)
  and Ko_Med_ArmL_F / ArmR_F / Stomach_R (+3.4-4.3%) on every body; Butcher attacks / combat walk-fast / turns
  (+1.2-5.9%); Screamer attacks + Stop_Fast / TurnOnSpot (+2-4%); walker IntoStatic lead-ins 0.502 -> 0.533 (+6.2%),
  Grapple_IntoMoving_Short, Lurch_Attack_IntoStatic (+9.1%), paired_counter_m_2h_sweeping_into_l; Dani pistol equip /
  reload, machete heavy charge into (+8.3%), block transition 0.075 -> 0.1 (+33%). Root speeds drop by the same factor
  (e.g. Butcher Combat_Walk_L45_Fast 6.04 -> 5.93); the walker / runner / shambler / thug walk / chase / crawl clips
  are ACL and unchanged.

## 0z. Earlier hand-off (2026-10-09, wind-up / locomotion-sync session)

**Done (sections 11-12):**
- Walker (and Thug / Shambler) locomotion-layer attack wind-up from AnimInterest_Melee (exe). Attacks without a fixed
  wind-up now lead by WindUps[].Duration: Walker swipes hit at 0.58 s, was 0.18 s. Only hit_time / duration were
  merged into archetypes.json (merge-only file; backup in game/test_out/wu).
- DI2's Starts -> Move sync is a native forward-foot tracker (AnimNotify_ForwardFoot), not stock marker sync. It is
  ported, plus UE marker sync inside the Move blend space.
- Start / Stop / TurnOnSpot Durations come from AnimNotify_LocomotionTransition, as in the exe.
- TurnOnSpot -> Starts never fires in DI2 (no writer of its bTransitionToStart), so the f53 cut is gone.
- anim_report.py's slide metric now measures stance frames only.

**Open, in priority order:**
1. **Start -> Move pop** (z_loco f252, 22 cm): coordinator says keep DI2's data path 1:1. Lead for round 3: the
   Starts -> Move transition is TLT_StandardBlend (no Inertialization anywhere in ABP_ZombieWalker), but it uses
   BlendProfile SKEL_ZombieStandard:BlendToRootMotion (per-bone blend-time scales). The port doesn't apply blend
   profiles. Port it (the profile's bone scales are in the skeleton asset) and re-check whether it hides the wrap.
2. **Attack root motion:** montage segment boundaries jump (z_walk_chase f307, 68 cm IntoStatic -> attack). Apply
   montage root motion to the capsule and stop holding each segment clip's root at its frame 0 (9.4).
3. **Step 5, strafe locomotion** (coordinator, not started): Forward / BackwardStrafeBlendSpace by StrafeAngle, and
   cmd move_dir / speed / face from zombie_ai.gd (fields in recon/ZOMBIE_AI.md). Best done in a fresh session.
4. LOCO_SETS for the screamer / slobber / butcher / suicider bodies (BS_ZMB_<Class>_Start / Stop / TurnOnSpot).
5. Move's WindUpRun blend space (its Cycle clips aren't extracted); the VariableWindUp approach phase (needs the brain).

## 0a. Brief: locomotion round 3 (queue Q7, P2, session di2-loco3, 2026-10-09)
Steps, commit after each:
1. Attack-montage root motion: apply DI2's montage root motion during attacks (z_walk_chase f307 pop, 68 cm at the
   IntoStatic -> attack segment boundary), following DI2's montage root-motion mode from the data / exe.
2. Strafe: DI2's strafe blend spaces; zombie movement honours cmd["move_dir"] at the DA_MovementSpeed Strafe speed,
   so strafe cards side-step instead of standing.
3. LOCO_SETS for Screamer / Slobber / Butcher / Suicider (build_zombie_montages.py + zombie_anim.gd) from their anim sets.
4. Does ABP_ZombieWalker blend Start -> Move with Inertialization or a blend profile? If so port it (would hide the
   z_loco f252 22 cm wrap as DI2 does); if not, keep the pop (1:1, coordinator's decision).
Owned: zombie_anim.gd, di2_anim.gd, build_zombie_montages.py, build_character_states.py, anim_report.py,
montages_zombie.json, this file, own UNVERIFIED rows. zombie.gd: only movement / _drive_rm / root-motion hook lines,
exact-match, after a message to the coordinator. Not zombie_ai.gd (di2-ai-specials).
Done when: anim_report shows no attack-segment pop in z_walk_chase; a capture shows a strafe card side-stepping; the 4
specials walk / chase with their own sets; `tools/run_all_tests.sh combat flesh` 0 script/shader errors, no [panic.
Captures: game/test_out/di2-loco3/. At the end: Knowledge notes + lint, hand-off here, short message to the coordinator.

## 0b. Previous hand-off (2026-10-08)

**State.** Dani and the zombies are posed by DI2Anim (`game/scripts/di2_anim.gd`) and ZombieAnim (`zombie_anim.gd`)
from DI2 montages, state machines and blend spaces (sections 3-4).

Done and verified:
- **Face:** DI2 has no spawn fade. The facial layer switches off while the zombie is paired (CoopActionSlave, 1.0 s) (section 7).
- **Attack lead-ins:** they replace MIN_HIT_TIME. The DI2 montage timeline and fixed wind-ups are in, and
  convert_archetypes.py now uses montage-relative hit times (section 9).
- **Voice:** ZombieVoice, by the voice helper. It drives FaceLayer.mouth_db (recon/ZOMBIE_AUDIO.md).
- **Perf:** idle zombie anim update 267 -> ~90 us, with output verified identical.
- **Root-motion extraction:** `ZombieAnim.root_motion(delta)` works (TurnOnSpot L90 turns exactly 90 deg) but is
  **not wired into zombie.gd**.

`Failed loading res://assets/di2/zombie_clips/{walker,thug}_attacks.glb` (combat.log 17:42) is **fixed**. The clip
glbs needed the headless import (done 18:05/18:31). The .godot/imported entries now exist for every
zombie_clips/*.glb. Rule: re-run the import after rebuilding them with tools/build_zombie_clips.py.
Last check (end of session): headless import 0 errors, then `tools/run_all_tests.sh combat` exit 0, 0 script/shader
errors, no `Failed loading` (game/test_out/logs/combat.log).

**Open, in priority order:**
1. **P1 - zombie locomotion starts / stops / turn-in-place.** **Ported 2026-10-08 (section 10)**: standing zombies
   move by root motion through DI2's Starts / Move / Stops / TurnOnSpot states. Start, stop and turn verified
   (z_loco). Not met: z_walk_chase's slide metric (still 57 / 34 cm/s; see 10.3 for why). Earlier text kept below:
   (z_walk_chase foot slide 54 cm/s; the DI2 animation's own slide is 17 cm/s).
   - **Design (agreed by the retired coordinator, awaiting gore-lead's go):**
     - `anim_ctl.root_motion(delta) -> {velocity, yaw, active}`, with DI2's steering spring and montage weighting;
     - zombie.gd uses it when `active` and keeps its current path otherwise;
     - `drive()` gets `target_dir` as a new last argument with a default;
     - zombie_reactions' montage root motion folds into the same call (check its yaw sign: correct is -delta-yaw).
   - **Steps:**
     - (a) DI2Anim.BS evaluates the exported UE GridSamples (`grid` in anim_graphs.json; algorithm in UNVERIFIED #62's note).
     - (b) The Idle / Start / Move / Stop / TurnOnSpot logic behind `rm_locomotion`, from the exe RE in
       extracted/ghidra_anim/states.c, decide.c, loco2.c, steer.c and locoset.c.
     - (c) The zombie.gd hook.
   - **Done-check:** `--animcap=z_rootmotion` and z_walk_chase with planted-foot slide near DI2's intrinsic 17 cm/s,
     no switch spike above the 0.2 s crossfades, combat suite 0 errors.
   - Full plan and decoded rules: hand-over note `animation-handover.md` (folder
     earlier notes).
2. **P2 - Walker locomotion-layer attack wind-up** (AnimInterest_Melee.AttackWindUpAmount + DA_WindUpDef additives).
   Swipes now land 0.18 s after the command, where DI2 shows a 0.4 s wind-up pose (9.4).
   **Done-check:** a z_hits / combat capture shows the wind-up pose before the swipe.
3. **P2 - pop check** for hit-react -> locomotion and attack -> recover in the flesh and combat suites.
4. **P3:**
   - eye/head look-at (DA_LookAtLimit_Zombies);
   - pivots;
   - the HighFidelityLocomotion layer flag that enables stops (UNVERIFIED #62).

**How to test** (always in the background, never a foreground Godot):
- After new class_names or new glbs:
  `tools/with_cpu.sh <you> tools/with_lock.sh <you> tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --import --audio-driver Dummy`
- Suites: `tools/run_all_tests.sh combat` (and flesh), 0 script errors expected.
- Captures: `RUN_TEST_ENGINE_ARGS="--fixed-fps 60" tools/with_cpu.sh <you> tools/with_lock.sh <you> tools/run_test.sh --combattest=game/test_out/<you> --animcap=<scenario>`
  with scenarios z_walk_chase, z_hits, z_knockdown, z_face, z_perf, z_rootmotion. Then
  `python tools/anim_report.py game/test_out/<you> --sheets`.

## 1. How it was measured

- `game/scripts/anim_capture.gd` - frame-exact captures, run through the combat test:
  `RUN_TEST_ENGINE_ARGS="--fixed-fps 60" tools/with_cpu.sh anim tools/with_lock.sh anim tools/run_test.sh --combattest=<dir> --animcap[=a,b]`
  (`tools/run_test.sh` gained the `RUN_TEST_ENGINE_ARGS` hook). Scenarios: `p_locomotion`, `p_light_chain`,
  `p_heavy`, `p_block_kick_dodge`, `p_switch_pistol`, `z_walk_chase`, `z_turn`, `z_hits`, `z_knockdown`,
  `z_runner`, `z_death`. Each writes one JSON record per 1/60 s frame (camera-space pose of Dani's hands / weapon,
  world pose of zombie feet / pelvis / head, the playing montages with position and weight, the base state) and a
  frame strip.
- `tools/anim_report.py <dir> [--sheets]` - per-frame second differences (cm, deg) of the watched bones, the
  largest spike right after every clip switch (a cut or a snapped blend shows there), planted-foot slide speed,
  and contact sheets around each scenario mark.
- Captures: `game/test_out/anim/before` (original code), `base` (original + the class-id fix, so the arms
  animate at all), `after*` (the fixes below).

## 2. What made it rough (evidence)

| # | Problem | Evidence (capture) | Cause |
|---|---|---|---|
| A1 | **Dani's arms never animated** | `before`: hands frozen at the rest pose for every scenario; `test_out/combat/combat.log` "anim=" empty | `weapons.json` was regenerated by `build_weapons.py` (22:11) without the `class_id` field `build_class_data.py` added (21:46) -> `Player.cls()` found no class -> no clip ever played |
| A2 | Hard cuts antic -> attack | `base` p_light_chain: hand/weapon jump 22-29 cm in one frame at every attack start | `player_melee` played the attack clip with blend 0.0 |
| A3 | Snaps when chaining / rebounding | 52-60 cm, 65-104 deg in one frame | invented 0.03-0.08 s linear crossfades, clips restarted |
| A4 | Snaps entering block / kick / heavy / select | 18-40 cm per frame | invented 0.03-0.05 s linear blends instead of DI2's montage blends |
| A5 | Recovery cut short | recovery clip cut at min(len, 0.9 s) then 0.2 s blend to idle | DI2's recovery montages blend out over their own BlendOut (bat 1.2 s) |
| A6 | Idle / walk / sprint switched by name | walk <-> sprint swapped with a 0.2 s linear crossfade | DI2 blends a 1D blend space by speed, and crosses Idle/Move with 0.5 s Cubic / 0.6 s Sinusoidal |
| A7 | All montage timings wrong | DetectHits / Chainable / camera / PlayMontageNotify times read as absolute | see 3.2: UE stores them segment-relative |
| A8 | Attack-speed scaling on the whole clip | antic/attack clips scaled end to end | DI2 scales only inside AnimNotifyState_ScalePlayRate windows (3.4) |
| A9 | Additive clips played as full poses | 335 1P sequences are additive (AAT_RotationOffsetMeshSpace 323, AAT_LocalSpaceBase 12), e.g. the pistol's Shoot_ADS / Move_Walk_F_ADS / every weapon-sway pose | merge_anims decodes them as absolute local poses; see 6 |
| Z1 | Same reaction re-triggered = hard restart | `before` z_hits: 21 cm hand jump when hit_med_torso_b restarts | Godot's AnimationPlayer cannot crossfade a clip into itself (`play()+seek(0)`) |
| Z2 | Reaction blends invented | all reactions 0.08 s linear | DI2 reaction montages have their own BlendIn/Out (e.g. Hit_Medium_Torso_B 0.07 / 0.6 HermiteCubic) |
| Z3 | Get-up pops | `before` z_knockdown: 55 cm head / 62 cm foot jump at the get-up | get-up picked by hit direction, not by how the body lies; DI2 picks by `StandingUpPosition` |
| Z4 | Locomotion: nearest clip + clamped speed_scale | walk <-> walk_slow swaps, 0.25 s linear | DI2: Base_Locomotion state machine + 2D blend space on SpeedTarget |
| Z5 | Turn rate invented | 200 deg/s | BP_Base_Walker CharMoveComp RotationRate Yaw 110 |
| Z6 | Knockdown held as "AnimationPlayer finished" | KO pose held only because the clip ended | DI2 holds the lying body natively (pose snapshot / ragdoll slot) |
| Z7 | Launch held mid-air | `before` z_knockdown: the 0.2 s Hit_Launch start's last (airborne) frame held on the ground for the whole knockdown | DI2 continues launches with LaunchingImpactResponse (air / land or ragdoll); the bodies have no air / land clips |
| I1 | Godot import adds rest tracks | every imported clip has a one-key rest-pose track for each bone the glTF animation doesn't key (handgun `pistol_move_walk_f_ads`: 264 tracks vs 232 glTF channels) | harmless for full poses (= reference pose); wrong for additive clips (rest rotation read as a delta) - the additive pass skips them |

## 3. DI2 data recovered

### 3.1 Montage blend defaults (exe)
`UAnimMontage` InternalConstructor -> 0x1434b3ee0: FAlphaBlend ctor with 0.2 (0x14346e3d0), then
`SetBlendTime(0.1)` (0x14348a6d0: BlendTime = max(x, 0)) and `SetBlendOption(2)` (0x14348a6c0) on **both**
BlendIn (+0xA8) and BlendOut (+0xE0); BlendOutTriggerTime (+0x114) = -1. EAlphaBlendOption 2 = HermiteCubic.
So every cooked montage without an explicit BlendIn / BlendOut (cooked data only stores what differs from the CDO)
blends **0.1 s HermiteCubic** - not UE's stock 0.25 s. Explicit values range 0 - 1.2 s with Cubic / Sinusoidal /
CircularIn / CircularOut / ExpOut etc. All are in `game/data/montages.json` (1P, 1,676 montages) and
`game/data/montages_zombie.json` (1,629 AM_ZMB montages).

### 3.2 Montage notify times (data-format fix)
FAnimLinkableElement: `LinkValue` is relative to the linked montage segment - `Absolute` = montage seconds,
`Relative` = seconds after SegmentBeginTime, `Proportional` = fraction of SegmentLength after SegmentBeginTime;
unlinked elements keep an absolute LinkValue. `tools/di2_animsets.py link_time()`. Verified:
- all 4,149 notify states of all montages: start + Duration == resolved EndLink;
- BranchingPointMarkers.TriggerTime equals the resolved notify time (e.g. AM_Medium2H_Sweeping_StandardAttack_Down_L
  BP_TriggerCameraAnimation: 0.4880 x 0.4333 = 0.2115 = TriggerTime 0.211457).
Effect: the bat Down_L swing's BP_DetectHits was 0.2295-0.4646 s and is 0.0994-0.3346 s; its BP_Chainable was
0-0.3 s and is the Decision section 0.4333-0.7333 s; the head stomp's PlayMontageNotify was 0.42 s and is 0.868 s.
`game/data/classes/*.json` regenerated (`build_class_data.py --classes-only`).
**Same bug, not fixed here (bodies session's file):** `tools/convert_archetypes.py montage_hits()` reads
AIDetectMeleeHits' LinkValue as seconds -> zombie attack hit times in archetypes.json.

### 3.3 1P anim graph (ABP_PlayerCharacter_1P, BakedStateMachines)
UpperBody: Idle->Move 0.5 Cubic, Move->Idle 0.6 Sinusoidal, Idle->InAir 0.3 HermiteCubic, InAir->Idle 0.5
HermiteCubic, Move->InAir 0.3, InAir->Move 0.4, slides 0.2 (all HermiteCubic). Slots: `Arms` (montages),
`AdditiveArmsLocomotion`, `AdditiveArmsCustomState/Event`, `Camera`, `FullBody`, `Legs`. Additive layers: aim
offset (LocalSpacePitch), arm sway (ForwardBack / LeftRight / UpDown), weapon pose (`BasePose` anim set, e.g.
A_1P_Medium2H_Sweeping_Aimpose_F / Weaponpose_InRange_F ... by #InRangePose / #CombatPose / #AlertPose /
#CrouchPose), upper-body corrective poses. All in `game/data/anim_graphs.json`.
Move = the class's UpperBodyWalkRunSprintBlendSpace (e.g. BS_Medium2H_Sweeping_IdleToRun: 1D "Speed" 0..2, idle 0,
walk 0.5 and 1, sprint 1.025 and 2, BSIT_Linear, TargetWeightInterpolationSpeedPerSec 2.6).

### 3.4 Playback-rate windows (bytecode + exe)
`AnimNotifyState_ScalePlayRate` (BP subclasses: Anticipation, AttackSpeed [bScaleByNotifyLength false], Decision,
Repetition). NotifyBegin (exe 0x14113e6b0): duration = AnimInstance.GetPlayrateDuration(key); if bScaleByNotifyLength
(default true, ctor 0x141125c50 writes +0x40 = 1): rate = notify length / duration, else rate = duration; written to
the montage instance's PlayRate. NotifyEnd (0x141140130) sets it back to 1.0.
Durations (BP_Base_MeleeWeaponItem ExecuteUbergraph bytecode, dumped with tools/bpdump):
`AddPlayrateDuration("Anticipation", MeleeArchetypeData.WeaponStandardAttackAnticipationTime)`,
`("AttackSpeed", WeaponStandardAttackSpeed)`, `("Repetition", WeaponStandardAttackRepetitionTime)`,
`("Decision", Player.HeavyAttackHoldTransitionTime)` = 0.75 (BP_Base_Player CDO).

### 3.5 Standard attack structure (montages)
Antic montage (BlendIn 0.2) -> Attack montage, sections `Attack` -> `Decision` -> `DecisionLoop` (loops on the last
frame); BP_Chainable covers the Decision section; `AttackDecisionEntered` at the Decision start calls native
`DIAnimInstance::AttackDecisionEntered` (exe 0x141100350, broadcasts a delegate at this+0x2d0). The Recovery montage
(e.g. BlendIn 0.2, BlendOut 1.2) starts with the same AttackDec clip the Decision section plays (466 of 480 DI2
attack items), then the Recovery clip.

### 3.6 Zombies
- Root motion (CORRECTED 2026-10-08): UAnimInstance's ctor (exe 0x14348eed0) sets RootMotionMode (+0x30) = 3, but
  DINPCAnimInstance's InternalConstructor (0x141bcb350) ends with SetRootMotionMode(2) (0x143468f00 writes +0x30) =
  RootMotionFromEverything, and the ABP CDO doesn't override it. So DI2 moves zombies by the root motion of the
  locomotion animation (walk blend space, starts, stops, turns, pivots) as well as montages; the AI's desired
  velocity only picks the samples. The earlier reading (montages only) was from the wrong function.
- ABP_ZombieWalker: Base_Locomotion Idle->Move 0.2 HermiteCubic, Move->Idle 0.8 ExpOut, Idle->Starts 0.2 Linear,
  Starts->Move 0.7, Move->Stops 0.2, Stops->Idle 0.5, Idle->TurnOnSpot 0.2, TurnOnSpot->Idle 0.4, pivots 0.4, ...;
  Crawler_Locomotion Idle<->Move 0.4 HermiteCubic, TurnOnSpot 0.2 / 0.3. Move input = AnimState_Move.SpeedTarget
  (cm/s) and PrimaryStrafeAngle.
- RunCombatFwd per family (DA_AnimSetCollection_<Family>_Locomotion): Walker BS_ZMB_Walker_Walk_F (forward samples
  Walk_Slow @40 x0.67, Walk_Slow @60, Walk_Med @160, Walk_Fast @240, TargetWeightInterpolationSpeedPerSec 3.0),
  Thug BS_ZMB_Thug_Walk, Runner BS_ZMB_Runner_Run.
- BP_Base_Walker CharMoveComp: MaxAcceleration 150, BrakingDecelerationWalking 100, RotationRate Yaw 110.
- StandUp: DA_AnimSet_StandUp_Fast_Zombie picks AM_ZMB_Base_Ko_Recovery_* by `StandingUpPosition`
  ('Front'/'Back'/'Left'/'Right') and Crawler / #HasBothArms (hit_reacts.json, recon/HIT_REACTS.md).

## 4. What changed

### 4.1 Engine: `game/scripts/di2_anim.gd` (DI2Anim)
UE-style evaluation on a Skeleton3D, the AnimationPlayer used only as clip library:
per-bone sampling; UE blending (weighted translation sum, quaternion sum aligned to the first contributor and
normalised, unkeyed bones at the reference pose); FAlphaBlend curves (all EAlphaBlendOption shapes); montage
instances (BlendIn/Out with DI2's curves, sections + NextSection links incl. self-loops, segments with
AnimStartTime/EndTime/PlayRate/LoopingCount, auto blend-out at BlendOut / BlendOutTriggerTime, a new montage stopping
the playing ones with its own BlendIn, ScalePlayRate windows); slot weighting over the base pose
(SlotEvaluatePose: montage weights normalised above 1, base fills the rest); base layer of state-machine states with
standard-blend transitions; 1D/2D blend spaces with TargetWeightInterpolationSpeedPerSec and normalised-time sync;
`play_after` (start a montage in the same update its predecessor starts blending out, = UE's OnMontageBlendingOut
chaining, so a 0 s BlendOut -> 0 s BlendIn hand-over never shows a frame of the base pose).
Cost: ~0.2 ms per update for Dani's 178-bone rig.

### 4.2 Dani
- `Player._ready`: class ids derived from DI2's class asset name when weapons.json lacks them (A1).
- Every move plays its DI2 montage (`play_role`): select, light antic/attack/recovery, heavy intro (Windup -> looping
  Loop section) and heavy attack, rebound, block in / pose (looping) / out / success / perfect / fail, kicks and
  stomps (hit on the montage's PlayMontageNotify), dodge movement -> recovery, player knockback, ADS in / loop / out,
  shoot, reload (standard reloads stretched to the reload duration).
- Standard attack: antic -> attack chained on the antic's blend-out; Decision entry: buffered press chains, held
  button stays in Decision (0.75 s) then goes heavy, else the Recovery montage starts at the AttackDec time reached
  and blends back with its own BlendOut. Hit detection and chain windows use montage time.
- Playrate durations registered per weapon from the bytecode-sourced values (3.4).
- Base layer: UpperBody state machine (Idle / Move blend space / InAir) with DI2's crossfades.

### 4.2b Additive layers
- Montages carry their slot and skeleton slot group (SKEL_MaleStandard SlotGroups: DefaultGroup / CameraGroup /
  AdditiveArmsLocomotionGroup / AdditiveArmsCustomEventGroup / AdditiveArmsCustomStateGroup). Montage_Play stops
  only its own group; montages in the AdditiveArms* groups are applied after the Arms result as mesh-space rotation
  additives (UE FAnimationRuntime::AccumulateMeshSpaceRotationAdditiveToLocalPose; deltas = target_mesh *
  base_mesh^-1, applied delta * base_mesh). Used for the ADS shot (AM_Handgun_Pistol_Shoot_ADS,
  AdditiveArmsCustomState) and the ADS walk (AdditiveArmLocomotion -> AM_1P_Pistol_Move_Walk_F_ADS,
  AdditiveArmsLocomotion), which the port used to play as full poses.

### 4.3 Zombies (`zombie_anim.gd` ZombieAnim + `zombie_reactions.gd`; zombie.gd only hooks)
- Locomotion: Base/Crawler_Locomotion states with DI2 crossfades; Move = the family's RunCombatFwd forward samples
  as a 1D blend space on SpeedTarget (cm/s), no speed_scale stretching.
- Every one-shot (reactions, KOs, get-ups, attacks, falls, paired, stun) plays as DI2's montage for its clip
  (BlendIn/BlendOut/sections/segments) - a repeated hit crossfades into itself (Z1, Z2). Attacks keep the port's
  clip (gameplay hit timing is the bodies session's) with their DI2 montage's BlendIn / BlendOut.
- Root motion read at the montage's segment/time, weighted by the montage weight.
- KO pose held until the get-up; get-up side chosen by the lying pelvis (StandingUpPosition) and the node aligned.
- Standing launches play the port's KO fallback (ends lying) instead of holding the 0.2 s launch start (Z7).
- Idle set switches (calm / alert / combat) cross 0.3 s Linear (the Idle state's BlendListByEnum on
  InternalCombatState, BlendTime 0.3, Linear).
- Turn rate 110 deg/s (CharMoveComp RotationRate).

## 5. Results (before -> after)
Captures: `game/test_out/anim/base` (original code + class fix) / `before` (original) vs `final`; contact sheets in
`<dir>/sheets/`, numbers in `<dir>/report.txt`. "Switch spike" = largest one-frame second difference of the bone
within 6 frames after a clip change (a cut shows here; in-clip motion of a fast swing is ~1-5 cm).

| Scenario | Metric | Before | After |
|---|---|---|---|
| Dani: any | arms animate | no (rest pose, A1) | yes |
| p_light_chain (bat x3) | max switch spike hand / weapon | 52.1 / 59.9 cm | 5.0 / 6.3 cm (one DI2-authored segment junction 19.6 cm, see 6) |
| p_light_chain | switches > 10 cm | 8 of 10 | 0 of 10 (+ the DI2 junction) |
| p_heavy | max switch spike hand | 14.8 cm | 9.8 cm (HeavyAttack Intro BlendIn is 0 s in DI2) |
| p_block_kick_dodge | max switch spike hand | 16.6 cm (dodge in-between: 90.7 cm one-frame glitch in a first version) | 10.9 cm (BlockOut BlendIn 0.05 s in DI2) |
| p_locomotion | switch spike hand | 1.1 cm (0.2 s linear, clip swap) | 0.5 cm (blend space + DI2 transitions) |
| p_pistol_ads | ADS walk / ADS shot | played as full poses (hand jumps 30+ cm) | additive: arms stay, shot kick ~3 cm |
| p_switch_pistol | select spike | 15-21 cm (0.05 s linear) | 30-41 cm: DI2's Select montages BlendIn 0 (after the 0.01 s AM_Base_DeselectNoAnimation) - a cut in DI2 too |
| z_hits | same reaction re-hit (hand) | 21.2 cm restart | 14.7 cm crossfade (DI2 BlendIn 0.07 s) |
| z_hits | planted-foot slide | 4.5 / 2.3 cm/s | 3.7 / 1.8 cm/s |
| z_knockdown | KO -> get-up (head / hand) | 55.2 / 40.9 cm | 45.5 / 16.5 cm (see 6: DI2 bridges this natively) |
| z_knockdown | planted-foot slide | 48 / 70 cm/s | 7.7 / 7.4 cm/s |
| z_walk_chase | walk switches | 0.25 s linear swaps | blend space, <= 2.7 cm |
| z_walk_chase | planted-foot slide | 57 / 56 cm/s | 54 / 48 cm/s (in-place clips at constant capsule speed; DI2 moves zombies by root motion, see 3.6 - root-motion locomotion is the fix) |
| z_runner | planted-foot slide | 165 / 198 cm/s | 159 / 260 cm/s (unchanged: see 6, Runner clips) |

## 6. UNVERIFIED / not done
- **Camera FOV** (recon/UNVERIFIED.md #10): DI2's DIPlayerCameraComponent is a cine camera (FieldOfView 37.85 =
  35 mm on its 24 x 13.5 filmback, set at runtime from the FOV user setting; exe has OnFOVUserSettingChanged /
  BaseFOV / RequestGameplayFOV, no default in data). The camera follows `camera_root` (exe references the wide
  string "camera_root"; BP_Base_Player attaches the 1P mesh to the capsule at Z -95 cm and the camera to the mesh).
  At idle Dani's right hand sits ~37 deg below the view axis, so with the port's 95 deg horizontal FOV the hands are
  just below the frame (only the weapon shows); they'd need > ~106 deg. Not changed (FOV is not mine to invent).
- 1P blend-space input `WalkRunSprintBlendSpaceNormalizedVelocity`: native, from NormalizedWalkRunVelocityMagnitude
  (+0x140) and NormalizedSprintVelocityMagnitude (+0x13C) of AnimInterest_Player_Locomotion_UpperBody. The port maps
  walk speed -> 1 and sprint speed -> 2 (the blend spaces' walk/sprint sample positions).
- UpperBody transition rules (bTransitionToMove ...) are native: Move above 0.5 m/s, InAir when not on the floor.
- Attack Decision -> Recovery hand-off is native (OnAttackDecisionEntered listeners); implemented from the data (3.5).
- Antic -> Attack chaining moment (native melee action): implemented as OnMontageBlendingOut.
- Additive layers still not applied: weapon pose (`BasePose` set), aim offset, arm sway, upper-body correctives
  (the AdditiveArms* montages - ADS shot / ADS walk - are, see 4.2b). Additive clips must never be played as full
  poses.
- Zombie Starts / Stops / Pivots / TurnOnSpot states: their sequences are not in the body glbs (TurnOnSpot only 4 of
  36 walker samples) - not ported. Runner body: its glb holds Combat_Run_*_F, not BS_ZMB_Runner_Run's Run_*_02, so its
  Move blend uses its own clips at their measured root speeds.
- Zombie montage slots other than DefaultSlot (layered `LHR_UpperBody` light hits, `Ragdoll` slot with the pose
  snapshot) - light reactions play full body.
- Get-up: section 8 (Ragdoll action -> StandUp by EStandUpOrientation, PoseSnapshot fade over RagdollBlendOutTime).
  Before that: get-up alignment (node turned/moved onto the lying pelvis) stood in for DI2's snapshot blend. The KO end poses
  (e.g. Ko_Med_Torso_B ends half-seated, pelvis 0.44 m up) match no get-up's first frame closely (best pelvis score
  0.8), and both montages use 0 s blends, so a get-up step remains: DI2 bridges it through its Ragdoll slot /
  PoseSnapshot (native RagdollBlendWeight), not ported.
- Launches: done in section 8 (DI2's trees, LaunchCharacterAction impulses into the Ragdoll action; the dumped
  launch settings never animate the launch).
- Standing <-> crawler machine switch: 0.3 s Linear from the bIsCrawler BlendListByBool (node mapping inferred).
- Level-sequence pairs (counters) and the dani_fp.glb legacy clips (grapple, fury, drop kick, ground pound) play
  with DI2's montage default blend (0.1 s HermiteCubic); their level-sequence easing is not exported.
- Hit pause uses Engine.time_scale (global) - DI2's ImpactPauseSettings target is native.
- **DI2-authored discontinuities** (not port defects): e.g. A_1P_Medium2H_Sweeping_Attack_Left_To_Right_01_AttackDec's
  last frame vs _01_Recovery's first frame differ by 36 deg on clavicle_r, and AM_..._Left_01_Recovery plays them
  back to back (the _02 pair is continuous); several Select / BlockOut / Heavy Intro montages have 0 - 0.05 s
  BlendIn. The port reproduces these as DI2 has them.
- Runner foot slide: runner.glb's walk clips are Combat_Run_*_F with large intra-cycle root-speed variation
  (std 0.5-0.6 m/s); BS_ZMB_Runner_Run uses Run_*_02 sequences that the body glb doesn't have (bodies session).
- Godot's scene importer optimises the clips (e.g. 17 -> 15 keys on lowerarm_r of Dodge_L_Out; constant tracks keep 1
  key); no visible error found, import settings unchanged.

## 7. Zombie faces (facial animation)

### 7.1 What was missing
The zombie glbs carry the face rig (139 of SKEL_ZombieStandard's 140 bones under `face`; only `glasses` is absent; no
morph targets), but no locomotion / attack / idle clip keys them: only the 86 full-rig clips (KO, launch, paired) do.
So the face sat in its bind pose (mouth closed, neutral) and nothing ever moved it - DI2 drives it from a separate
facial sub-graph, which the port lacked. Nothing was dropped by CUE4Parse / merge_anims: the body sequences just
don't key the face.

### 7.2 How DI2 animates a zombie face (sources)
- **ABP_ZombieWalker** (`tools/abp_graph.py` on extracted/json_bp; LinkID = index among the generated class's AnimNode
  properties): cached pose "Facial" = LayeredBoneBlend(base = body graph incl. montages / layered hit reacts, blend =
  SubInstance **ABP_ZombieWalkerFacial**, branch `face` depth 0, BlendWeights = `Layer_Facial`, local space). The
  baked PerBoneBlendWeights give exactly `face` + its 140 descendants. Above it: "MorphTargets" (TwoWayBlend at
  `Layer_MorphTargets`, a curve-only blend space; the NPCMorphTargets layer's base weight is 0.0 -> off), then
  personality / IK / Twitch. The sub-instance gets InternalCombatState, parentClass and Layer_ProceduralMouth
  (ubergraph bytecode, `tools/bp_pretty.py`).
- **ABP_ZombieWalkerFacial** (parent DIFacialAnimInstance): state machine WAIT (unconnected = ref pose) -> Idle once
  `isReady` (first update with a valid parentClass); Idle -> Combat when InternalCombatState == 2, back when != 2
  (ECosmeticCombatState Calm 0 / Alert 1 / Combat 2, exe enum strings); all three transitions 0.2 s HermiteCubic;
  bSkipFirstUpdateTransition. Each state = LayeredBoneBlend(base = AnimSetSequencePlayer of `Facial.Idle_Calm` /
  `Facial.Idle_Combat`, blend = BlendSpacePlayer(AnimInterest_Facial_Mouth.MouthMovementBlendSpace, X =
  MouthAdditiveHorizontal, Y = MouthAdditiveVertical), branches `face` 0 / `eye_r` -1 / `eye_l` -1, BlendWeights =
  `Layer_ProceduralMouth`): baked weights = 137 bones (all but eye_r, eyeEnd_r, eye_l, eyeEnd_l).
- **AnimSetSequencePlayer** (FAnimNode_AnimSetSequencePlayer::UpdateAssetPlayer, exe 0x141175170; resolve
  0x141168010): bLoopAnimation true, PlayRate 1, StartPosition 0, ResolveRemainingTime 0.1: when the playing sequence
  has < 0.1 s left it re-resolves the anim set (new pick) and restarts at StartPosition - no crossfade.
- **Per family** (BP_Base_<Family>.AnimSetCollections -> DA_AnimSetCollection_<Family>_Facial):
  Walker and Shambler: DA_AnimSet_Walker_Facial (Calm_Idle_01-03 / Combat_Idle_01-03, AnimSetSelectionOrder_Random,
  weights 1); Runner: DA_AnimSet_Runner_Facial (Calm 01-02 / Combat 01-02, Random); Thug: AnimSet_Single
  (A_ZMB_Facial_Thug_Calm_Idle_01 / _Combat_Idle_01). MouthMovement: BS_ZMB_Facial_<Family>_Additives - every
  family's uses the six A_ZMB_Facial_Walker_Additive_{Base, Left, Right, Open, OpenLeft, OpenRight} samples at
  Horizontal {0, 1, -1} x Vertical {0, -1}, TargetWeightInterpolationSpeedPerSec 7, axes -1..1 (GridNum 2 x default 4,
  15 GridSamples). The samples are 2-frame **full** face poses (AdditiveAnimType none despite the name).
- **Layer weights**: BPC_AnimationLayer_AI lists NPCFacial and NPCProceduralMouth; both use a
  LinearBlendLayerWeightProvider with native defaults - InternalConstructor exe 0x140c94c90: DesiredLayerWeight 1.0,
  TransitionTime 0.33 s (+0x34 = 0x3ea8f5c3), Inverse computed as 1 / TransitionTime in 0x140c91cf0. The AnimBP's
  AlphaLayerChange event writes `Layer_<Name>` (bytecode). Layer groups that disable NPCFacial: Dead, PlayDead,
  CoopAction, GameSequence_DefaultCutscene, StatusEffect_Frozen, AILOD_Level1. NPCProceduralMouth is in none.
  Consequence: with ProceduralMouth at 1, jaw / lips / lids / brows come from the mouth blend space and the facial
  idles only show on the eyes (they also animate the jaw ~28 deg, lips and blinks - overridden in DI2 too).
- **Mouth driver** = UBreathingAudioComponent (tick 0x141173b30, mouth 0x1411745e0, apply 0x141158110 ->
  0x141064cd0 writes the facial instance's +0xEB8 / +0xEBC = MouthAdditiveHorizontal / Vertical, the
  AnimationSlaveFacialState fields): every >= 1/30 s it reads the Wwise RTPC **RTPC_Zombie_Mouth_Volume** on the
  zombie's game object (0x141177340, GetRTPCValue type GameObject) - the zombie voice's meter level in dB.
  Vertical = -0.03589682 * 2^((dB + 48) * 0.1) (= -2^(dB/10): -0.036 at the -48 dB floor, -1 = Open at 0 dB);
  Horizontal = 0 unless a debug CVar enables a sine. Then the per-event config of
  DA_BreathingAudioMouthDamLocWalker (DX_Walker_Shout / Scream, else the default state; native default Min -1, Max -1,
  bClamp false - ctor 0x141b6d750 - and the asset sets the default's Max to 1): out = (|v| * (max - min) + min) *
  sign(v) with min clamped to >= 0 -> identity for every walker case.

### 7.3 Port
- `tools/build_zombie_facial.py` -> `game/data/zombie_facial.json` (masks from the baked weights, state machine,
  player settings, family sets, mouth blend spaces, layer + mouth constants) and
  `game/assets/di2/zombie_facial/<body>_facial.glb`: skin-only glbs (joints + inverse binds, no meshes) holding the
  family's facial idles + the 6 mouth samples, face bones only, retargeted onto each body's rest pose like
  merge_anims (face bones are AnimationRelative). Imported with remove_immutable_tracks=false.
- `zombie_anim.gd` FaceLayer (registered as a DI2Anim post layer, so it runs after base + montages and before the
  mesh-space additives, where DI2's LayeredBoneBlend sits): WAIT / Idle / Combat machine with DI2's crossfades,
  re-resolving players, the mouth blend space (bilinear on the sample lattice = UE's grid, weights at 7/s), layer
  weights (1.0, 0.33 s), local-space blends. ECosmeticCombatState from the port's brain state (Idle / CrawlIdle =
  Calm, Alert = Alert, else Combat). `FaceLayer.mouth_db` is the RTPC input (stays -48 dB: no zombie voice audio).
  With the mouth layer at full weight the blended mouth pose is cached and only the eyes are blended per frame.
- `di2_anim.gd`: `extra` clip sources and `post_layers`.

### 7.4 Results (game/test_out/anim_face, `--animcap=z_face`, all four bodies)
| | before | after |
|---|---|---|
| face pose | bind pose (mouth closed) on every non-KO clip | DI2 mouth Base pose (+3.6 % Open at the meter floor): parted lips, teeth |
| eyes | static | facial idles: eye_l range 2 - 29 deg per 2.5 s phase (Thug 2 - 3 deg) |
| jaw / lips at silence | static | static (as DI2: the mouth layer overrides the idles) |
| calm -> combat | - | Idle -> Combat 0.2 s HermiteCubic, a Combat idle picked |
| voice level sweep -48 -> 0 dB (diagnostic) | - | lowerJaw 23.6 deg, upLip_01 11.3, lowLip_01 8.2 |
| cost per zombie (anim update, median) | 134 us | 193 us |

The combat regression (autotest_combat) runs through with the face layer.

### 7.5 UNVERIFIED / not done
- **Zombie voice audio** is not in the port, so the audio-driven mouth stays at the floor; DI2 opens it with every
  breath / growl / shout. Porting it needs the Wwise events (DX_Walker_*, breathing states, AttackBreathingEvent
  notifies), their wems and the meter settings - a separate audio task. `FaceLayer.mouth_db` is the hook.
- AnimSetSelectionOrder_Random treated as a uniform pick with repeats (all weights 1); the class wasn't decompiled.
- RESOLVED, spawn: no fade-in. UAnimationLayerComponent's layer registration (0x140c8f350) sets each layer's weight
  straight to its BaseLayerWeightProvider's desired weight (vtable +0x240) and pushes the weights to the anim
  instance, so Layer_Facial / Layer_ProceduralMouth start at 1.0 as the port does.
- RESOLVED, switch-offs (raw package name maps, then dumps): BP_Action_Grapple_Master_AI and
  BP_Action_Counter_Master_AI disable DA_AnimLayerGroup_NPC_CoopAction (holds NPCFacial) while active
  (GameEventStateResponse_DisableAnimationLayerGroup, reason CoopActionSlave); BP_Action_Dead_AI disables NPC_Dead;
  BP_Base_SpawnActivity_PlayDead / BP_StatefulActivity_Corpse / BP_StatusEffect_Frozen use their groups;
  BP_AnimNotifyState_Disable_NPC_Facial (OverrideTransitionTime 1.0) is used by no dumped zombie montage. Blend: the
  component ctor (0x140c94c00) makes DefaultEnable (desired 1.0) / DefaultDisable (desired 0.0) linear providers,
  TransitionTime 0.33 s; ULinearBlendLayerWeightProvider update (0x140c93e50) = move_toward at 1/TransitionTime per s.
  Ported: the face blends out over 0.33 s while zombie_reactions.state == "paired" (the port's grapple and counter)
  and back in after. Not ported (no such states in the port): Dead (the port stops animating on death), PlayDead,
  Frozen, AILOD_Level1.
- Look-at IK on the eyes / head (NPCIKLookAt* layers, AnimGraphNode_NPCLookAt) and the MorphTargets layer (base
  weight 0) are not ported.
- ECosmeticCombatState comes from the port's brain states, not DI2's combat state machine.

## 8. Hit reactions from DI2's trees (knockdowns, launches, get-ups)

`zombie_reactions.gd` no longer picks reactions from gore-core's tier x part x direction names. Every impact runs
DI2's hit-react selection (recon/HIT_REACTS.md is the tree spec):

- `zombie.take_hit` -> `reactions.select()` right after `GoreBody.hit_ex` (before a kill is applied) builds the
  impact's facts, walks the archetype's HitReactTreeSet (`hit_react_trees.gd`, data/hit_reacts.json) and
  `reactions.execute()` runs the responses after the outcomes; `zombie._die` -> `reactions.start_death()`.
- Responses: MinorAnimatedFlinch (layered `LHR_UpperBody` / `LHR_FullBody` slot), MajorAnimatedFlinch and
  AnimatedKnockback (full-body DefaultSlot montage, root motion), KnockdownAction (KO montage -> ragdoll at its
  `HitReactRagdoll` notify), DeathAction (death montage -> death ragdoll at the notify), Ragdoll, LaunchingImpact,
  KnowledgeBaseCounter (timed facts), SpawnablePart (jaw / eyes). Montages play by DI2 name through
  `ZombieAnim.play_montage` with their DI2 slot; play rate 1 + uniform(neg, pos deviation); max weight from the range
  remapper.
- Montages whose sequences the body lacks (`hit_reacts.json` clips_missing) are skipped and logged
  (`reactions.history`), never replaced. Walker coverage: Small 68/68, Medium 34/34, StumbleMedium 26/26, Layered*
  all, KOSmall 28/28, KOMedium 29/29, StandUp (standing) 8/8 - but StumbleSmall 0/26, KOStumbleSmall/Medium 4/28,
  Launch 11/23, DuringRecovery 5/41, DuringRagdoll 0/15, StatusEffectDeath 0/13. A KnockdownAction without its clip
  ragdolls at once (the step the montage would have led to).

### 8.1 DI2 sources recovered (this pass)

| Item | Source |
|---|---|
| `HitReactStabilityCTILarge/Medium/Small` (#H8) | BP_Base_AI.InitHitReactBalacingData (bytecode) writes them from DT_EnemyGenericData (GenericBalancingDataRow): Walker 1/1/1, Runner .8/.8/.8, Shambler .7/.7/.5, Thug 1.4/1.1/0; CTIXSmall is never written (reads 0) |
| `LaunchWeightScalar` | same function: CanBeLaunched ? LaunchWeightScalar : -1; CanBeLaunched is a BP bool on BPC_Base_HitDeathReactions_AI, default false -> the Thug never launches |
| WeaponClass | the weapon BP's FactsSetWhenHeld (player KB string, Light/Medium/Heavy; wood bat Heavy, metal bat / machete Medium); `tools/build_hit_react_extra.py` -> data/hit_react_extra.json |
| {Hit}.CanLaunch / impact LaunchSettings / CanCauseCosmeticFlinches | the weapon's ImpactConfiguration.Settings; struct-delta defaults: bCanLaunch false, bCanCauseCosmeticFlinches true (BP_DamageType_Blunt sets bCanDismember false, Sharp bCanBreak false) |
| `HitReactInterrupt` (#H9) | no exe string, no extracted asset (~10.8k raw packages scanned). The one rule in data: BP_Base_AIController.DetermineIfVulnerableDebug (the "Hit React Vulnerability" debug line) = KB.Evaluate(VulnerableRequirement_<player WeaponClass>), unknown class -> false. Used as the port's rule (UNVERIFIED) |
| Knockdown hold | KO montages end with a `HitReactRagdoll` notify (149 of them); BP_Action_Ragdoll_AI: on ground + RagdollResting -> ZeroStabilityDuration 0.6 s -> stability recharge TimeToFullyRecharge = DA_AttributeType_AIKnockdownDuration (min MinimumRechargeDuration 0.4; an impact while down resets it to 1.0 s) -> StartStandUpExpression `StabilityFraction >= 1 && !StopRagdollRecovery` -> StandUp action (StandingUp fact). BPC_Base_Stability_AI drains stability on Knockdown / Launch / Ragdoll |
| Stand-up side | UStandUpCharacterAction (exe 0x141209860 -> 0x141209680): actor up U vs the ragdoll root transform: U.X <= -cos45 FaceDown, >= cos45 FaceUp, else U.Y <= -cos45 OnRightSide else OnLeftSide (EStandUpOrientation 0..3) |
| Ragdoll -> animation | BPC_PhysicalizedHitReact_AI: RagdollBlendOutTime 1.0, Curve_PhysicalizedReactions_RagdollBlendWeightToPhysicsBlendWeight_BlendOut_AI (dumped); the port fades a PoseSnapshot of the ragdoll into the StandUp montage over 1.0 s along that curve |
| Capsule alignment to the get-up | UStandUpCharacterAction ctor +0xbc = 2.0 s max, using the montage's extracted root motion (0x141213560) |
| Launch | LaunchingImpactResponse::Execute 0x1413e2830 -> LaunchCharacterAction (vtable 0x1455eed10): with bApplyRagdoll (ULaunchSettings ctor 0x141cf0170 default **true**; bAnimateLaunch default **false**, so the dumped settings never play the launch montage) the Ragdoll action gets root / mesh-point / angular impulses (0x1411a4e00, 0x14126ba80). Formulas: `launch_math.gd` (0x1411a5e10, 0x1411cf5a0, 0x1411ce870, 0x1411cece0, 0x1411cfff0, 0x1411a5240, 0x1411a3d50, 0x1411a54d0, 0x1411a5820, 0x1411f1660) |
| `#LaunchImpulse` | `((Force * LaunchWeightScalar * ...) + 2000) * max(1, LaunchScalar)` -> the 10..100 -> 0.6..1 remap saturates at 1.0 (the remapper must clamp, #H13) |
| LHR slots | ABP_ZombieWalker: Slot LHR_UpperBody under LayeredBoneBlend (spine_01, depth 0, local); Slot LHR_FullBody over it; SKEL_ZombieStandard slot group LayeredHitReactions |
| Mesh impulse application | RagdollStateComponent 0x141284eb0 -> 0x14126b5c0 (root velocity, <= 10000 cm/s, added to all bodies), 0x14126b820 (each mesh impulse = AddImpulse(v, Bone, bVelChange) on its bone, <= 10000 cm/s), 0x141269d90 (angular, <= 3600 deg/s, all bodies) |
| Range remapper (#H13) | 0x141b07560: lerp inside [in0, in1], OutEnd past the end, OutStart before the start (clamped) |

### 8.2 Port

- `game/scripts/hit_react_trees.gd` (HitReactTrees): tree set -> tree walk (bool / num / str / module / resp / link)
  -> responses; anim-set montage pick (groups: first group whose expression holds with items, weighted Random /
  FirstThenRandom; velocity sets); DI2's direction (0x1412c6a20) and posture (0x1412c6920) facts; the remapper;
  rich curves.
- `game/scripts/zombie_reactions.gd` (ZombieReactions): facts, select / execute, the actions above, the Ragdoll
  action's rest -> recharge -> stand-up, PoseSnapshot fade, capsule alignment. `reactions.history` logs each impact's
  tree and responses (including skipped montages).
- `game/scripts/launch_math.gd` (LaunchMath): the launch impulses (8.1), UE units / axes, converted to Godot
  (UE (x, y, z) = Godot (x, z, y); angular velocities change sign under that axis swap).
- `game/scripts/di2_expr.gd`: `*` `/`, rnd(), floatbranch(), max() / min(), single quotes, case-insensitive facts,
  aliases and string compares (FNames).
- `game/scripts/di2_anim.gd`: layered montage slots (`Montage.layer`, `layer_masks`, `_layered_pass`) and the pose
  snapshot (`snapshot_w`); `zombie_anim.gd`: `play_montage(am)` in the DI2 slot, `notifies(am)`, the LHR masks.
- `tools/build_hit_react_extra.py` -> `game/data/hit_react_extra.json`.
- `anim_capture.gd`: `z_knockdown` now waits for the stand-up (<= 16 s); new `z_launch` (bat, zero stability),
  `z_ko` (Force 30 then 20 -> KOMedium montage -> ragdoll -> stand-up), `z_death_ko` (Force 20 kill -> DeathAction
  KOMedium -> ragdoll at its notify). Zombie bones are recorded from the ragdoll bodies while a simulator is active:
  the skeleton's bone poses keep the animation values under a PhysicalBoneSimulator3D, so earlier captures (e.g.
  `final` z_death) show ragdolled bodies as standing still.
- `zombie._drive_animation` no longer plays a `hit_med_*` clip in gore-core's brain "Stagger" window (a port
  reaction on top of DI2's; the brain still pauses the zombie for it).

### 8.3 UNVERIFIED / not done (hit reactions)

- **HitReactInterrupt** (#H9): the DetermineIfVulnerableDebug rule stands in; `MinimumHitReaction` is never set.
- **Missing clips**: StumbleSmall, KOStumble*, half of Launch, DuringRecovery, DuringRagdoll, StatusEffectDeath,
  crawler get-ups (hit_reacts.json clips_missing) need merging into the bodies' glbs (owner: combat / bodies).
- AIMeleeSubAction_WindUp / Attack (VulnerableRequirement_Light / Medium inputs) come from the port's attack montage,
  not DI2's native melee sub-actions. Stun-lock counting (#H19) not ported (`StunLocked` false).
- RagdollLanded / RagdollResting thresholds are native: the port waits for every body < 0.2 m/s and < 30 deg/s.
- Stand-up: the ragdoll root transform (RagdollStateComponent +0x9c0) is stood in for by the pelvis carrying the
  character's rest-pose forward / right; the enum -> 'Front' / 'Back' / 'Left' / 'Right' name table (0x141209920) is
  not read (FaceDown -> Front etc. follow the get-up clips' first frames). The capsule alignment is applied at once
  (the get-up's first-frame pelvis on the lying pelvis), not interpolated over <= 2 s with the montage root motion.
- Stability during the knockdown is the Ragdoll action's recharge timer (Curve_StabilityRecharge_Float over the
  knockdown duration); gore-core's own meter / FORCE_SCALE (UNVERIFIED #4) still decides the zero-stability hit.
- ProceduralHitReactResponse (DA_ProceduralAnimationReactions_AI) is logged, not played; the port's per-impact
  physical reaction (physical_reaction.gd) stays. ApplyFlinchImpulse (corpse curves, #H20 input) keeps the port's
  corpse impulse. BisectionTrigger stays with zombie.gd's existing bisection rule. KnockdownStun (Thug) only sets KOStun.
- LaunchCharacterAction's non-ragdoll branch (bAnimateLaunch / capsule LaunchCharacter, 0x1411ca9f0 / 0x1411cec90)
  and the Ragdoll action's IntoMontage path (0x1411e93a0) are not used by the dumped launch settings and not ported.

## 9. Zombie attack timeline (lead-in segments, fixed wind-ups, hit windows)

Coordinator decision (2026-10-08): match DI2's timeline instead of clamping hit times (`MIN_HIT_TIME = 0.25` in
convert_archetypes.py was a port value and is gone).

### 9.1 DI2 data
- Attack montages compose a lead-in segment and the attack sequence: e.g. AM_ZMB_Walker_SwipeL_Horiz_Med =
  A_ZMB_Walker_Attack_Swipe_LH_Horiz_IntoStatic_Med (AnimStartTime 0.266 - 0.533) + ..._Attack_Med (StartPos 0.2673).
  Its BP_AIDetectMeleeHits_SwipeL_Walker window is 0.1825 - 0.3734 s montage time (LinkValue resolved over the
  segment chain, di2_animsets.link_time).
- DA_AttackDef_*: WindUps[] {WindUp (WindUpDefinition), Duration, Attacks[] {FixedWindUpMontage, Montage}};
  DA_AttackSequence_* units name the definition and AttackParams.bShouldAlwaysPerformFixedWindUp.
  A montage in several definitions takes the one a regular (non-CannotReachTarget) sequence uses: the Walker's
  swipes come from DA_AttackDef_Walker_Swipe (DA_AttackSequence_Walker_Swipe, FixedWindUpMontage null, WindUp
  DA_WindUpDef_Walker_SwipeL/R, Duration 0.4); DA_AttackDef_Walker_Swipe_Horiz / _Vert (FixedWindUp montages) are only
  used by the CannotReachTarget sequences.
- Fixed wind-ups for the port's attack clips: Walker bite (0.35 s), Runner swipes (0.5 s, = the FixedWindUp montage =
  the clip's first 0.5 s; the attack montage starts the clip at AnimStartTime 0.5), Shambler swipes (0.68 s, montage
  0.4 s) and Uncontrol (0.5 s, montage 0.6 s). No fixed wind-up (WindUpDefinition only): Walker swipes and grapple,
  Runner lunge, every Thug attack.
- DA_WindUpDef_*: WindUpIdleAdditive (e.g. A_ZMB_Walker_Attack_Swipe_RH_Horiz_WindUp_Static), IdleAnimationLength 0.5,
  WindUpStartAdditive, WindUpRun (BS_ZMB_Walker_WindUp_Swipe_RH_Horiz): the locomotion-layer wind-up driven by the
  native AnimInterest_Melee.AttackWindUpAmount (ABP_ZombieWalker Idle WindUp evaluator / Start ApplyAdditive_2 /
  TwoWayBlend_7). Not ported.

### 9.2 Port
- tools/build_zombie_clips.py: skin-only clip glbs for sequences the body glbs lack (game/assets/di2/zombie_clips/
  <body>_<set>.glb + .anims.json, merge_anims' retarget and root handling). Set "attacks": 15 lead-in / impact /
  crawler wind-up sequences (walker 12, runner 2, thug 1). ZombieAnim registers them as "x:<sequence>".
- tools/build_zombie_montages.py: segments resolve to those clips; each montage lists its DI2 "seqs"; attack clips
  map to their whole attack montage (by_clip) instead of a _FixedWindUp partner; "windup" = attack montage ->
  [FixedWindUpMontage, Duration].
- zombie_anim.gd play(): an attack montage with a playable fixed wind-up plays the wind-up, then the attack montage
  after Duration (a new montage or a hit cancels it).
- convert_archetypes.py: hit_time = wind-up Duration (fixed wind-up only) + the AIDetectMeleeHits window start in
  montage time; duration = wind-up + montage length.

### 9.3 Before -> after (hit_time / duration, s; attack start = the brain's attack command)
| body | card | before (clip clock, MIN_HIT_TIME clamp) | after (DI2 montage timeline) |
|---|---|---|---|
| Walker | LeftHandSwipe | 0.25 / 1.401 | 0.182 / 1.401 |
| Walker | RightHandSwipe | 0.25 / 1.401 | 0.167 / 1.401 |
| Walker | Grapple | 0.712 / 1.012 | 0.712 / 4.333 (AM_ZMB_Walker_Grapple_Miss_Med played whole) |
| Walker | Bite | 0.25 / 1.4 | 0.515 / 1.75 (0.35 s fixed wind-up) |
| Runner | Left/RightHandSwipe | 0.68 / 1.033 | 0.68 / 1.5 (0.5 s fixed wind-up + attack montage) |
| Shambler | Left/RightHandSwipe | 0.598, 0.654 / 2.3 | 0.878, 0.933 / 2.58 (0.68 s fixed wind-up; montage starts the clip at 0.4) |
| Shambler | Grapple | 0.824 / 3.333 | 0.724 / 3.233 |
| Thug | Grapple | 1.005 / 3.967 | 1.405 / 3.967 (Smash with its IntoStatic lead-in) |
Combat suite after the change: 0 errors; zombies still attack into the player's block / perfect-block window.
Re-running convert_archetypes.py also picked up the hit-react session's new DA_AIAttributeValues dumps: Thug /
Thug_Revenant / Thug_LongPiglet health 450 -> 540, base_force 60, attack damage 22, cooldown 0.4 (DI2 data).

### 9.4 UNVERIFIED / not done
- The locomotion-layer wind-up (WindUpDefinition additives, AttackWindUpAmount) is native and not ported, so attacks
  without a fixed wind-up start their montage at once: the Walker's swipes land 0.18 s after the attack command,
  where DI2 shows a 0.4 s wind-up pose first. Porting AnimInterest_Melee's wind-up is next on the attack list.
- A fixed wind-up montage shorter than its Duration (Shambler 0.4 s vs 0.68 s) holds its last frame until the attack
  starts; AIMeleeSubAction_FixedWindUp is native (hold vs. stretch not decoded).
- Attack root motion (the lead-ins step forward ~1 m/s) is recorded in the clip glbs' .anims.json but not applied to
  the capsule; per-variant hit times (short / long / vertical clips zombie.gd picks) use the card's Med montage.


## 10. Root-motion locomotion: starts, stops, turn-in-place (2026-10-08)

### 10.1 DI2 sources
- **Blend spaces** (UE 4.27 GetRawSamplesFromBlendInput):
  - clamp the input to the axis range; n = (v - min) / cell;
  - take the 4 surrounding grid points, element index = X * (GridNumY + 1) + Y, with bilinear weights;
  - sum the weights per sample, drop < 1e-5, normalise.
  - Unsynced players (Start / Stop / TurnOnSpot) advance normalised time by dt / sum(w * len / rate)
    (FUN_1411502d0). bLoop = true in the ABP CDO.
- **LocomotionStruct** (instance +0x1838, ctor FUN_1410fa530, DA_LocomotionDefinition_<Family> overrides):

  | Family | MoveSteer +0x183c | StartsAngleThr +0x1844 | StartsSteer +0x1848 | TOSSteer +0x184c | TOSLag +0x1850 |
  |---|---|---|---|---|---|
  | defaults / Shambler | 180 | 60 | 15 | 0 | 0.05 |
  | Walker, Thug | 180 | 120 | 140 | 90 | 0.05 |
  | Runner | 180 | 120 | 140 | 180 | 0.02 |

  Other fields:
  - TurnOnSpotThreshold 10 deg, Delay 0.3 s, LeadTime 0.2 s;
  - MaxDistanceToPrioritiseFacingDirection 200 cm;
  - RotationSpeed Calm / Alert / Combat 0 / 100 / 100;
  - Idle MinStateWeightForTurnOnSpot 0.25;
  - exit margins Start 0.2, Stop 0.4 (MaxRemainingTimeToIdle), TurnOnSpot 0.2 s. Duration = BS length at the input
    minus the margin.
- **Steering spring** FUN_14116ed50 (critically damped, deg):
  - omega = 2 / lag, x = omega * dt, e = 1 / (1 + x + 0.48x^2 + 0.235x^3);
  - temp = (-wrap(rem) * omega + vel) * dt, vel = (vel - temp * omega) * e;
  - clamp vel to +-max speed, step = fmod(vel * dt + 540, 360) - 180.
  - Lag: Move 0.2, Start 0.2 (after the latch acos(fwd . start dir) < StartsSteeringAngleThreshold), TurnOnSpot TOSLag.
- **State functions:** Idle FUN_14114a060, Start FUN_14114b1f0, TurnOnSpot FUN_14114b6e0, turn-vs-start
  FUN_141126cc0, stop test FUN_141117920 (DistanceToFinalDestination <= the stop clip's root travel).
- **Base_Locomotion transitions:**
  - Idle -> Starts 0.2 Linear;
  - Starts -> Move 0.7, Starts -> Stops 0.1, Move -> Stops 0.2, Stops -> Idle 0.5, Idle -> TurnOnSpot 0.2,
    TurnOnSpot -> Idle 0.4, TurnOnSpot -> Starts 0.1 (all HermiteCubic);
  - Move -> Idle 0.8 ExpOut.

### 10.2 Port
- **di2_anim.gd BS:** grid evaluation, `unsynced`, `loop`, `length_now()`.
- **zombie_anim.gd:**
  - `_drive_rm` / `_rm_tick` (LOCO_SETS, LOCO_DEF);
  - `loco_log` records each state entry as [time, state, input X, input Y, Duration].
- **Pose tick:** with `rm_locomotion` the pose ticks in `_physics_process` (process_physics_priority -1), so
  zombie.gd consumes the root motion in the same frame. This is UE's TickCharacterPose-then-move order.
- **zombie.gd:**
  - velocity and yaw come from `anim_ctl.root_motion()` for standing zombies;
  - CharMoveComp's 110 deg/s turn is kept only while a montage plays;
  - the base layer's root motion is dropped while zombie_reactions owns the capsule.
- **Capture:** `--animcap=z_loco` runs an Alert turn-in-place to 90 deg right, a Start L90 at 1.5 m/s, a walk and a
  Stop.

### 10.3 Results
- **z_loco** (game/test_out/rm2_z_loco):

  | Step | Result | loco_log |
  |---|---|---|
  | Turn-in-place | TurnOnSpot after the 0.3 s delay; node yaw 0 -> -90.0 deg exactly | `TurnOnSpot X 90 Y 100, Duration 0.533` |
  | Start L90 | yaw back to 0.0 deg | `Starts X -90 Y 150, Duration 1.0` |
  | Walk | Move after the Start | `Move` |
  | Stop | the zombie travels 0.31 m after the stop command, then Idle | `Stops 0.4` |

- **Foot-slide metric** (anim_report.py: ball within 3 cm of its lowest point, descending):

  | Capture | ball_l (cm/s) | ball_r (cm/s) |
  |---|---|---|
  | z_loco, f60+ | 25 | 25 |
  | z_walk_chase, f60+ | 57 | 34 (baseline 54 / 48) |

  - Planted frames in the walk move 0-10 cm/s, against 54 before.
  - The mean is dominated by three things:
    - **Starts -> Move pop** at f116: a 19 m/s foot jump in one frame. Move enters at phase 0; DI2 syncs it by sync
      markers, which are not ported.
    - **TurnOnSpot -> Starts cut** at f53-55: 8 m/s. The Alert idle-turn is cut by the move input through the 0.1 s
      edge; the exe's gate for that edge is not decoded.
    - **Shuffle swings counted as planted:** walk_med / walk_slow barely lift the feet (ball 3-8 cm), so the metric
      counts their swing frames as planted.

### 10.4 UNVERIFIED / not done
- Steering subtracts the clip's own remaining yaw (Start / TurnOnSpot) from the facing error.
- BlendingFoot (Stop_LFoot vs Stop_RFoot) is native; a stand-in picks the set whose first frame matches the current
  foot placement.
- DistanceToFinalDestination: the port has no path. zombie.gd passes 0 when the brain commands no speed, else
  INF, so stops start at the stop command.
- Stop X input = the angle to the target.
- FUN_141126cc0's CVar / FUN_141120000 conditions / post-turn distance check are not modelled.
- TurnOnSpot -> Starts on any move input.
- Move steering through FUN_14111b2f0 is assumed to be the same spring.
- Steering velocity resets on state entry, and steering pauses under montages.
- No sync-marker sync on Starts -> Move (the f116 pop).
- **Shambler:** its glb lacks the Personality_LeftLeg Start / WalkToIdle clips (36 / 41 and 5 / 20 missing). Its
  states fall back to the Idle <-> Move edges; only its TurnOnSpot (Walker set) plays.
- Pivots (Pivoting state) are not ported.
- Attack root motion and the zombie_reactions montage yaw sign are untouched (see the hand-over note).


## 11. Locomotion-layer attack wind-up (AnimInterest_Melee, 2026-10-08)

### 11.1 DI2 sources
- **AnimInterest_Melee** (DINPCAnimInstance +0x1510, vtable 0x1450f1ee8): AttackWindUpAmount +0x10, LastWindUpDefinition
  +0x18, StaticSlotName +0x20, rate +0x2c, state byte +0x30, ChosenWindUpDefinition +0x38.
  - Tick FUN_141118680 (ticked by FUN_14110e8d0 before the states): state 0 -> 1 (no step that tick); 1: amount +=
    dt * rate, clamped, at 1 -> state 3 (held); 2: amount -= dt * rate, at 0 -> state 4 and Chosen = null.
  - Begin FUN_141101e90(&interest, &WindUps[i]): resets an active wind-up, Chosen = WindUps[i].WindUp, state 0,
    rate = 1 / WindUps[i].Duration (Duration <= 0 -> 1). Called by AIMeleeSubAction_VariableWindUp's begin
    0x1410bad60 (vtable 0x14534c190 slot 81), which also sets its own progress rate 1 / Duration (+0xf4).
  - End FUN_141103730: state 2 (ramp down), or straight to 4 when the amount is 0; FUN_141104140 resets at once.
    The sub-action end 0x1410af640 picks one by its bool argument.
  - NativeUpdate FUN_141112af0: LastWindUpDefinition = ChosenWindUpDefinition when set.
- **UWindUpDefinition**: WindUpIdleAdditive +0x30 (a full pose, AAT_None), IdleAnimationLength +0x38,
  WindUpStartAdditive +0x40 (AAT_LocalSpaceBase), WindUpRun +0x48 (blend space).
- **ABP_ZombieWalker** (every zombie body's AnimClass), Base_Locomotion states:
  - Idle: BlendListByEnum_1 by InternalCombatState [0,1,2]; Combat = TwoWayBlend_10(idle, SequenceEvaluator(
    AnimState_Idle.WindUpAnimSequence @ WindUpSamplePosition)) by WindUpBlendValue. FUN_14114e4e0: sequence =
    WindUpIdleAdditive, position = its length * clamp(amount), blend = clamp(amount * 10).
  - Starts: BlendListByEnum_2 [0,0,1]; Combat = ApplyAdditive_2(BS, SequenceEvaluator_1(WindUpStartAdditive)) with
    alpha = amount and the evaluator's unbound ExplicitTime 0.55 (CDO).
  - Stops / TurnOnSpot: ApplyAdditive_3 / _4 of LastWindUpDefinition.WindUpStartAdditive at amount * length, alpha
    MapRangeClamped(amount, 0, 0.1, 0, 1) (ubergraph 540-825 / 1329-1511).
  - Move: TwoWayBlend_7(move, BlendSpacePlayer_5 = AnimState_Move.WindUpRunAnimSequence) by amount.
- DA_AttackDef_Walker_Swipe: WindUps[] {WindUp DA_WindUpDef_Walker_SwipeL/R, Duration 0.4, FixedWindUpMontage null}.

### 11.2 Port
- build_zombie_montages.py: `windup` = [fixed montage, Duration, WindUpDefinition]; `windup_defs` = the defs' sequences.
- build_zombie_clips.py: set "windup" (WindUpIdleAdditive full poses, walker / shambler / thug glbs) and `--additive`
  <body>_windup.additive.json (WindUpStartAdditive deltas in Godot space; UE's baked-additive retarget rules).
- zombie_anim.gd: `wu_begin` / `wu_end` / `_wu_tick` mirror the interest. play() of an attack montage without a fixed
  wind-up but with a WindUpDefinition begins the wind-up and plays the montage after Duration, then ramps it down.
  WindUpLayer (post layer, before the face) applies the Idle / Starts / Stops / TurnOnSpot nodes above.
- convert_archetypes.py: Duration leads the hit time for these attacks too. Walker swipes 0.182 / 0.167 -> 0.583 /
  0.567 s, Walker grapple 0.712 -> 1.111 s, Thug punches 0.6 -> 0.9 s, Thug smash 1.405 -> 1.705 s (durations +0.4 /
  +0.3 s). Only hit_time / duration were merged into archetypes.json: the converter's other fields differ from the
  current file (health, damage, cooldown, base_force) and were left alone.
- Capture `--animcap=z_windup` (records `wu` = [amount, state, LastWindUpDefinition]): the attack command at f50
  begins the wind-up, the amount reaches 0.917 by f75, when the montage starts and the amount ramps down; the
  wind-up pose shows in the frame strips (game/test_out/wu).

### 11.3 UNVERIFIED (row 64)
- The attack starts once Duration has passed. DI2's VariableWindUp also runs while the zombie walks in
  (WindUpVisibleAtDistance, LeadTimeWith/WithoutFixedWindUp, MinVariableWindUpToPerform); that needs the brain.
- Ramp-down vs instant reset at attack start; "Attack" -> Combat set; Move's WindUpRun not ported; Walker Bite /
  Grapple start additives are UE-codec; blends act on the composed pose.


## 12. Locomotion sync, state exits and the foot-slide metric (2026-10-09)

### 12.1 DI2 sources
- **Forward-foot tracker** (DINPCAnimInstance +0x1100, vtable 0x1450f1e70; ctor: foot 0, time -1, rate -1):
  - AnimNotify_ForwardFoot (FootType +0x38: EFoot 0 BlendLeftFoot / 1 BlendRightFoot; vtable 0x1450f5248, Notify slot 72
    = FUN_141110b00) -> FUN_141111e50: foot +0x11 = FootType, time +0x14 = world time, rate +0x18 = 1 / (anim time to the
    clip's next ForwardFoot of the other foot; wrapped by the play length; the play length when there is none; 0.3 if 0).
  - The walk clips' ForwardFoot notifies sit on their RightFoot / LeftFoot sync markers (Walk_Med: R 0, L 0.407, ...).
- **Move start position** (Move entry FUN_1411291b0 -> FUN_1411088d0(tracker, BS, angle, SpeedTarget)): the heaviest
  sample at the input; t1 = its first ForwardFoot of the tracked foot, t2 = the next ForwardFoot after it; result
  t1 + (t2 - t1) * (now - time) * rate (fraction only when time >= 0), t1 without t2, 0 without t1. That goes to
  AnimState_Move.BlendSpaceStartPosition, bound to the Move players' StartPosition, and FAnimNode_BlendSpacePlayer::
  Reinitialize (exe 0x14116f316 / 0x1411767f9) clamps it to [0, 1.0] as the normalised play time. DI2 feeds seconds
  into a normalised slot; the port does the same.
- **Sync groups:** only Move's BlendSpacePlayer_6-9 are in a group ("Locomotion", CanBeLeader). Start / Stop /
  TurnOnSpot players are ungrouped. Samples inside a group-leading blend space sync by marker (UE 4.27).
- **Native state machine:** FUN_141116cb0 = SetState (OnExit / OnEnter per ELocomotionState: 0 Idle +0xb98, 1 Move
  +0xe58, 2 Start +0xc18, 3 Stop +0xcc0, 4 Pivot +0xd28, 5 StanceChange +0xd80, 6 TurnOnSpot +0xdd0). The ABP rules read
  the states' bTransitionTo* bools.
  - Bool offsets come from reflection order (members are listed in reverse): Start 0x28 Idle / 0x29 Move / 0x2a
    MoveCombat / 0x2b Stop; TurnOnSpot 0x28 Start / 0x29 Idle.
  - PreLocomotionTransition(Old, New, bool&) (FUN_141bccc30 -> ProcessEvent; BlueprintNativeEvent, native default
    0x141114130 sets the bool true; no zombie ABP overrides it) gates each raise.
  - **TurnOnSpot tick** FUN_14114b6e0 raises only bTransitionToIdle, once Duration has passed (or inst+0x171c).
    No code stores TurnOnSpot's bTransitionToStart (inst+0xdf8; the store scan finds only the ctor and SetState
    clearing it). So DI2's TurnOnSpot -> Starts edge never fires for zombies: the turn plays out, goes to Idle, and
    Idle starts the move.
  - Start tick FUN_14114b1f0: Move once Duration has passed (MoveCombat when inst+0x1764 == 2), Stop when the stop test
    also passes, Idle on inst+0x171c.
- **Durations** (FUN_1411615a0(BS, mode, input, margin) -> FUN_141150550 -> FUN_141162050): each weighted sample's first
  AnimNotify_LocomotionTransition (class FUN_141b3fe40) with NotifyTransition == mode, weighted. Without one on every
  weighted sample, it falls back to the BS length minus the margin. Modes: ETransition 0 EndStopToMove (Start), 1
  EndMoveToStop (Stop), 2 EndPivot, 3 EndTurnOnSpot (TurnOnSpot). E.g. Start_Fast_L90 exits at 0.844 s (was 1.0),
  Combat_TurnOnSpot_Fast_R90 at 0.558 s (was 0.533), Stop_Fast_RFoot at 0.556 s.

### 12.2 Port
- build_zombie_montages.py: `forward_foot`, `loco_transition` and `sync_markers` tables (from the sequence jsons; 275
  loco sequences newly dumped with `di2x json`).
- zombie_anim.gd:
  - `_ff_scan` fires the ForwardFoot notifies the base layer crossed each tick into `ff_foot` / `ff_time` / `ff_rate`;
  - `_enter_move` sets the Move BS phase to clamp(`_ff_start_position`, 0, 1);
  - `_notify_duration` gives Start / Stop / TurnOnSpot Durations;
  - TurnOnSpot no longer cuts to Starts.
- di2_anim.gd BS: `markers` / `_marker_sync` / `sample_time(i)`. A synced BS's samples follow the heaviest by marker
  pairs (names + fraction); samples without markers keep normalised sync. Used by the Move source, root motion and the
  foot scan.
- anim_report.py foot slide: planted also requires vertical speed < 30 cm/s and no forward swing past the pelvis
  (relative velocity along the facing <= 5 cm/s); frames with a montage weighted over 0.05 are skipped.

### 12.3 Results (game/test_out/ff, new metric)
| capture | ball_l / ball_r (cm/s) |
|---|---|
| z_loco | 18.3 / 15.8 (old code: 17.1 / 15.2 with the same metric) |
| z_walk_chase | 24.5 / 21.1 (locomotion frames; this run the new zombie AI attacks mid-chase at 167 cm/s) |
- The old f53-55 TurnOnSpot -> Starts cut is gone (TurnOnSpot now plays out to Idle).
- The Start -> Move pop remains (z_loco f251-252, 22 cm): the Start players loop (ABP CDO bLoop true, ungrouped). Start
  exits at its EndStopToMove notify (0.844 of 1.2 s) and wraps 0.36 s into the 0.7 s StandardBlend crossfade (Move
  weight 0.54). This is DI2's own data path, so DI2 should show the same. Not changed (escalated).
- The z_walk_chase attack pop (f307, 68 cm) is the IntoStatic -> attack segment boundary of
  AM_ZMB_Walker_SwipeR_Vert_Med. Each segment clip holds its root at frame 0, and attack root motion is not applied
  (9.4). Not a locomotion item.

### 12.4 UNVERIFIED (row 65)
- Notify firing across states and samples: every weighted player fires, oldest state first.
- The weighted-average form of FUN_141150550's return.
- inst+0x171c's source (FUN_1410f7bc0 over inst+0x1908) is taken as false.
- Marker sync picks the matching marker pair nearest ahead of the follower's last time (UE's exact follower search not
  transcribed).


## 13. Attack-montage root motion (2026-10-09, locomotion round 3)

### 13.1 DI2 sources
- RootMotionFromEverything (DINPCAnimInstance ctor 0x141bcb350, 3.6): montages give root motion like the locomotion.
- Per sequence, cooked `bEnableRootMotion` (749 dumped zombie sequences true, every attack lead-in and attack) and
  `RootMotionRootLock`: not serialised = the stock UE 4.27 ctor default RefPose; 19 sequences AnimFirstFrame (crawler
  spawns / mantles, a runner crawler turn, a Mutator recovery), 3 Zero (none of the port's). With root motion extracted,
  UAnimSequence::ResetRootBoneForRootMotion poses the root bone at the lock.
- Why z_walk_chase f307 popped 68 cm: the attack sequences are authored continuing the IntoStatic lead-in, so their
  frame 0 root sits where the lead-in ended (A_ZMB_Walker_Attack_Swipe_RH_Vert_Attack_Med 0.68 m from the ref pose,
  the Horiz / Long ones 0.50-0.91 m, Grapple_Miss 1.39 m). merge_anims / build_zombie_clips hold every clip's root at its
  own frame 0 (= AnimFirstFrame), so the body jumped forward by that offset at the segment boundary while the capsule
  stood still.
- AnimNotifyState_AttackCorrection (MaxCorrectionDistance 10, MaxCorrectionAngle 90, AngularCorrectionWindow 0.9 on
  AM_ZMB_Walker_SwipeR_Vert_Med): native attack warping, not ported.

### 13.2 Port
- build_zombie_montages.py `root_motion`: sequence -> lock ("RefPose" / "AnimFirstFrame" / "Zero", "!" = bForceRootLock).
- di2_anim.gd: `add(..., ref_root)` poses the root bone at the reference pose; Montage.ref_root {segment clip: lock}.
- zombie_anim.gd `_rm_flag`: before a montage first poses the body it takes root motion when the capsule moves by
  root_motion() (rm_locomotion) and zombie_reactions doesn't own it (its state is "" one tick after the play: reactions
  and paired clips keep their own capsule handling and held root offsets). `_montage_root_delta` extracts across segment
  boundaries (FAnimTrack::ExtractRootMotionFromTrackRange). zombie.gd unchanged: it already applies root_motion().

### 13.3 Results (game/test_out/di2-loco3)
- s2 z_walk_chase, AM_ZMB_Walker_SwipeR_Horiz_Med (IntoStatic -> attack at f304): pelvis 1.8 cm, head 3.9 cm; the
  capsule moves 0.55-0.6 m forward through the attack (before: 68 cm pelvis pop, capsule still).
- Left: a 2-frame hold at the boundary (hand 13 cm second difference). The clip builders take the PSA AnimRate
  (NumFrames / SequenceLength = 17 / 0.533 = 31.875) as the key rate, so every built clip runs n / (n - 1) fast and
  ends early (UE spaces n keys over SequenceLength). Shared tooling (merge_anims.load_psa / build_zombie_clips); reported.

## 14. Strafing Move (AnimState_Move, 2026-10-09)

### 14.1 DI2 sources
- ABP_ZombieWalker Move state = TwoWayBlend_7(BlendListByBool_3, WindUpRun) ; BlendListByBool_3 (bActiveValue =
  AnimState_Move.bPrimarySystem, BlendTime 1.0, QuarticInOut, BlendProfile BlendToRootMotion) of TwoWayBlend_8 /
  _9 (A = BlendSpacePlayer ForwardStrafeBlendSpace, B = BackwardStrafeBlendSpace, Alpha = BackwardBlendValue); the
  players' X = Primary / SecondaryStrafeAngle, Y = SpeedTarget; all four in sync group "Locomotion".
- Blend spaces: anim sets "Locomotion.RunCombatFwd" / "RunCombatBwd" of DA_AnimSetCollection_<Family>_Locomotion
  (Walker Walk_F / Walk_B, Thug Walk / Walk_B, Runner Run / RunB, Screamer Walk / WalkB, Slobber Walk_Fwd / _Bwd,
  Suicider Walk / Walk_Bwd, Butcher Combat_Walk / Combat_Walk_B; Shambler's LeftLeg personality maps both to its Walk_FB).
- Move entry FUN_1411291b0, tick FUN_14114a510 (AnimState_Move offsets): bForward +0xb8, BackwardBlendValue +0xa4,
  bPrimarySystem +0x98, Primary / Secondary angle +0x9c / +0xa0, last angle +0xbc.
  - entry: angle = FUN_141135f00 (signed angle facing -> velocity +0x167c, facing = +0x1800 if unit else the actor's);
    bForward = |angle| <= YawForwardAnimationMax; BackwardBlendValue = bForward ? 0 : 1; primary on, both angles set.
  - tick: BackwardBlendValue = FInterpConstantTo (FUN_141f277a0, decompiled) toward bForward ? 0 : 1 at
    FwdBwdLerpingSpeed; bForward = (|angle| - YawForwardAnimationMax < 0) once that difference's size >=
    BoundaryBlendDegree; |wrap(last - angle)| < MaxStrafePivotYaw updates the active system's angle, else the other
    system takes the angle (the old one keeps its last) and bPrimarySystem flips.
  - LocomotionStruct (reflected offsets): YawForwardAnimationMax +0x1880 135, BoundaryBlendDegree +0x1884 10,
    MaxStrafePivotYaw +0x1888 90, FwdBwdLerpingSpeed +0x188c 2.0 (Walker 3.0), MoveStrafeSteeringSpeed +0x1840 180
    (Slobber 120). FUN_14110aaa0 (strafing: desired facing . facing <= 0.99) picks MoveStrafeSteeringSpeed.

### 14.2 Port
- zombie_anim.gd: MoveBS (both players' samples in one list weighted by BackwardBlendValue, each player with its own
  weight interpolation, marker sync over all), `_move_bs`, `_full_bs` (the full 2D grid), `_strafe_angle`,
  `_move_tick`; the swap is a Move -> Move state crossfade (STRAFE_SWAP, BlendToRootMotion).
- zombie.gd: `anim_ctl.move_dir = cmd.get("move_dir", Vector3.ZERO)` (the AI's strafe direction).
- Chasing zombies now sample the blend spaces at their facing error (DI2's X input) instead of Angle 0.

## 15. Blend profiles on transitions (2026-10-09)
- ABP_ZombieWalker: Starts -> Move (0.7), Move <-> Pivoting (0.4) and BlendListByBool_3 use
  SKEL_ZombieStandard:BlendToRootMotion {Root 20, Pelvis 3}; no Inertialization node anywhere in the ABP.
- DI2's math (exe, decompiled): state-machine transition 0x1434dba80 and BlendListBase::Update 0x143099750 set each
  profiled bone's weight to next Alpha x BlendScale and previous (1 - Alpha) / BlendScale (GetEntryBlendScale
  0x1434e7140), then normalise per bone (0x143514480). So a profiled bone's next-state weight is
  a s^2 / (a s^2 + 1 - a). There is no EBlendProfileMode in DI2's engine (4.27; time-factor modes are UE5).
- Port: DI2Anim.set_state(..., bprofile) and per-bone weight factors in the base-layer composition (bone_f);
  zombie_anim `_bprofile`, profiles exported to montages_zombie.json (blend_profiles, loco_profiles).
- z_loco (s2 -> s3): the Starts -> Move wrap at f252 drops from 22.1 to 14.4 cm (foot), the pelvis spike there goes away,
  the head's rises 4.1 -> 6.8 cm (the pelvis hands over three times faster). The rest is DI2's own data path (looping
  ungrouped Start player, 12.3), kept 1:1.
