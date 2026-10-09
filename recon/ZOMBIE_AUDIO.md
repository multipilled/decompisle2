# DI2 zombie voice / breathing audio (port status 2026-10-08)

## Hand-off (session stopped 2026-10-08, coordinator request)
**Done and verified**
- 2,940 male voice wems of the 4 port families -> ogg + per-1024-sample peaks (`tools/zaudio/convert_voices.py`,
  own converter `wwvorbis.py`; 0 failures, lengths = wem sample counts). Assets: `game/assets/di2/zombie_vox/`.
- Data: `tools/build_zombie_audio.py` -> `game/data/zombie_audio.json` (DamLoc voices/triggers/rules/lines, Wwise
  event volumes / busses / attenuations, meter, 248 montages' breathing notifies, native defaults
  `tools/zaudio/component_native.json`).
- Runtime: `game/scripts/zombie_voice.gd` (class ZombieVoice, registered by headless --import; class cache 17:36,
  combat suite 17:42 has no ZombieVoice errors - older autotest.log errors predate the import). Hook in zombie.gd:
  `var voice` + `voice = ZombieVoice.new(self); add_child(voice)` after `reactions`.
- Capture: every body breathes per DI2 (calm / alert lines, holds), montage exerts fire, jaw follows the voice
  (corr 0.92-1.00, lag 1-2 frames) - section 5.

**Open** (section 6; for recon/UNVERIFIED.md)
- DamLoc rule choice inside 0x140e747b0 (tie-break, Shuffle, priority interruption) not read; play path
  0x14116ca90 -> 0x140e4b200; rule XML parser 0x140e66ae0. Port: first rule of highest CriteriaComplexity, shuffled bag.
- No-rule failure (DI2 stalls with +0x435 set; port advances).
- Not ported: voice HPF + the 2 EQs before the meter (FxShareSets 2410675494 / 3295502291), HDR busses, aux sends,
  ST_Grapple state props, SFX_Walker_Distance walla switch, audio AI-LOD, Combat NewTarget / TargetKilled barks.
- Female voices are in the data but not converted (port bodies are male).

**How to test** (silent: dummy driver; ZombieVoice never plays under `*test=` unless `--voiceaudio`)
```
RUN_TEST_ENGINE_ARGS="--fixed-fps 60 --audio-driver Dummy" tools/with_cpu.sh zaudio tools/with_lock.sh zaudio \
  tools/run_test.sh --combattest=game/test_out/zaudio --animcap=z_face --voicelog=game/test_out/zaudio/voice.jsonl
~/AppData/Local/Programs/Python/Python312/python.exe -I tools/zaudio/face_report.py game/test_out/zaudio game/test_out/zaudio/voice.jsonl
```
After editing a class_name script: `tools/with_cpu.sh zaudio tools/with_lock.sh zaudio
tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --import`.

Personal-use static RE of the user's own install. Nothing was run from the game. Exe addresses are in
`DeadIsland-Win64-Shipping.exe`, decompiled in my own Ghidra project `extracted/ghidra_zaudio`
(`tools/re_zaudio/decomp.sh`). Outputs: `extracted/ghidra_zaudio/{meter,breath1..5}.c`.

## 1. Files
| what | where |
|---|---|
| wem -> ogg converter (own port of the ww2ogg algorithm; data input: the aoTuV 6.03 packed-codebook table already on the PC at `C:\Program Files (x86)\Sound Editor\tools\ww2ogg\packed_codebooks_aoTuV_603.bin`; no exe from there is run) | `tools/zaudio/wwvorbis.py` |
| batch convert + per-1024-sample peaks (ffmpeg, user-installed winget build, only decodes the standard ogg) | `tools/zaudio/convert_voices.py` -> `game/assets/di2/zombie_vox/<Voice>/<Folder>/*.ogg` (.gdignore) + `peaks.json` |
| Wwise bank readers (bank v135 = Wwise 2019.2; every HIRC object parses to its exact size) | `tools/zaudio/wwise_bank.py`, `wwise_hirc.py` |
| exe-recovered native defaults | `tools/zaudio/component_native.json` |
| data builder | `tools/build_zombie_audio.py` -> `game/data/zombie_audio.json` |
| runtime | `game/scripts/zombie_voice.gd` (class ZombieVoice); hook: 2 lines in zombie.gd (`var voice`, created after `reactions`) |
| RE helpers | `tools/re_zaudio/natives.py`, `find_plugin_reg.py`, `class_vtable.py`, `find_copy.py` |
| capture check | `tools/zaudio/face_report.py <capture_dir> [voice.jsonl]` |

2,940 wems of the 24 male voices of the four port families were converted (0 failures; every decode = the wem's
sample count). Female voices are in the data but not converted (port bodies are male; `voices_converted` gates).

## 2. Data sources (all DI2)
- **Voices**: DamLoc database `StagedData/DamLoc/Data/DialogueData.xml` (voices, voice sets, triggers, rules,
  communications/variations) + `DialogueList.xml` (per file: Wwise event, Volume dB). Files are
  `StagedData/DamLoc/Windows/English/Main/Voices/<Voice>/<Folder>/*.wem` (Wwise Vorbis, mono 48 kHz).
- **Voice choice**: `CT_Voice_<Family>` (Female? / Thug SpecialVariant) -> ProceduralVoiceTreeData (VoiceName,
  CharacterVoiceDefinition, SFX_Zombie_Type fact). Runner definitions set CalmHoldBreathIn/Out 0.0.
- **Trigger priorities**: native UENUM `EDialoguePriority` (exe enum table): inactive 0, dynamicUsingContext 1,
  localBreathing 2, localExert 3, localRoar 6, localHitReact 9, globalDialogue 20, localDeath 33 (full list in the
  enum, 0..35).
- **Wwise** (event-based packaging: each `DX_*` AkAudioEvent uasset holds its own bank): voices are external
  sources (codec 8) routed `Sound -> SwitchCntr(SFX_Walker_Distance: Normal = the voice, Walla/Ambient = crowd) ->
  ActorMixer 24509831 -> 616915094 (-3 dB, bus "Zombie_DamLoc - M") -> 527134155 (bus DX_Vocalisation_3D)`.
  Object/bus volumes, bus attenuations (Talk bus: flat to 400 m, cone 90/185 deg -0.5 dB; Shout/Scream:
  0 -> -2 dB at 5.2 m, cone 220/360 -3 dB; Thug Special_Large: object attenuations to 30-50 m), curves decode as
  linear-gain-minus-one (round dB values confirm). Init bank parsed from `WwiseAudio/InitBank.uasset`.
- **Mouth meter**: FxShareSet 220051762 = Wwise Meter (plugin 0x00810003): Peak, scope GameObject, attack 0,
  release 0.1 s, hold 0, min -48, max 0, no downstream volume, game param RTPC_Zombie_Mouth_Volume
  (STMG default -48, no ramp). It is the last FX of ActorMixer 24509831's chain
  [Convolution (bypassed by RTPC_IsArmoured_Helmet < 0.5), ParamEQ (notch Q by RTPC_Built_In_Distance), ParamEQ
  (low shelf on elevation), Meter]. DI2 audio frame = 1024 samples @ 48 kHz (DefaultGame.ini).

## 3. Native logic recovered (exe)
- **Meter** (Wwise plugin code statically linked): level per buffer = clamp(20 log10(peak), min, max)
  (0x14421dcf6); ballistics 0x14421d800: rise -> value = level (attack 0; else +10 dB per attack time), fall ->
  max(value - 10 dB * dt / release, level), hold bins (unused at hold 0); a voice that ends keeps metering silence
  until min (0x14421e0e6); global callback 0x14421e6e0 sets the RTPC to the max over the game object's instances,
  no transition; a stopped voice's instance contributes min and is removed.
- **UBreathingAudioComponent** (size 0x548; ctor 0x141b67a90): triggers default Breathing.{BreathIn, BreathOut,
  QuickBreathIn, Exert}; all hold times 0 (BPC_BreathingAudio_AI CDO sets Calm 0.1/0.1; CharacterVoiceDefinition
  ctor 0x141b7e8b0 also 0.1/0.1); JustDamaged vocal Breathing.HitReact (chance 0.33), Dying vocal Breathing.Death,
  both gated by bHas* flags that are false (bool offsets via SetBit: bUseDialogueTriggers +0xf4,
  bHasJustDamagedVocalAsset +0x248, bHasDyingVocalAsset +0x309); initial state HoldingBreathOut.
  State machine (EBreathingState 0..7): tick 0x141173b30, advance 0x141157bb0, breath-out 0x141170980, play pending
  0x14116c220, HandleVocalEvent 0x1411658b0 (queue while waiting; Dead accepts only DyingVocal; DontInterrupt; calm
  -> InterruptPlayImmediately; Immediate / QuickInhale (0x141164c20) / WaitForExhale), HandleEvent 0x141163d00
  (Light/Normal/Heavy exert -> ExertTrigger + context ExertType), SetMentalState 0x141b6abd0 (+0x432), RTPC poll
  every >= 0.033333335 s (0x141177340), mouth mapping already ported by the animation session (0x1411745e0).
- **AnimNotify_BreathingEvent::Notify** (0x14110fa59): Event != Vocal -> HandleEvent, else HandleVocalEvent;
  native defaults Event Exert, VocalPlayType InterruptQuickInhaleThenPlay, flags 0 (ctor 0x141b41640).
- **Play** 0x14116ca90: posts the trigger through the dialogue component (FUN_140e4b200, line callback
  0x1411635c0; VocalPlayFlags bit 2 AllowSamePriority is passed on); on -1 it only logs, the waiting flag (+0x435)
  stays set (no timeout found in the tick), so a voice without a matching rule stalls its breathing. The port
  advances instead (UNVERIFIED: real DI2 zombies always have a rule for their triggers).
- **Voice apply** 0x14119afd0 (the procedural voice tree's pick): sets the DialogueComponent's voice
  (0x140e477e0 with ProceduralVoiceTreeData.VoiceName), copies the CharacterVoiceDefinition onto the component
  wholesale (0x141170bd0: PostEventExtraParams, BlockBreathingExpression, every Calm/Alerted/Grapple event + hold
  time, bHasJustDamagedVocalAsset, Chance, JustDamagedVocalAsset, bHasDyingVocalAsset, DyingVocalAsset,
  FactsAndSwitchGroups / RTPCs, MouthAnimationConfig), then 0x141167b10 sets bUseDialogueTriggers (+0xf4) =
  (the voice name resolves in DamLoc) and +0x476 = 1. So DamLoc zombies run on dialogue triggers (resolved), and
  their JustDamaged / Dying vocals are off (the definitions leave both bHas* flags false and the assets empty).
- **Pain / knockdown / death vocals** come from the hit-react trees' CEs (CE_HitReact_Standard/Major/
  Dismemberment/Knockdown/Death_Zombie -> CosmeticEffect_BreathingVocalEvent), which the port's
  `zombie_reactions.gd` already selects; ZombieVoice reads `z.reactions.last` (no edit to that file).

## 4. Runtime (zombie_voice.gd)
Per zombie: pick voice -> breathing machine -> DamLoc trigger resolution (base-voice-set inheritance, rule with the
highest CriteriaComplexity whose criteria hold, timeSince/rnd/{Speaker}/{Context} facts, Begin/End KB actions) ->
Shuffle variation -> AudioStreamPlayer3D on a `head` BoneAttachment3D, volume = line Volume + object + bus volumes +
attenuation curve + cone (Godot attenuation disabled). Notifies are polled from the DI2Anim montage slot
(248 zombie montages carry breathing notifies / BlockBreathing windows). The meter runs on game time per 1024-sample
frame over `peaks.json`, and `z.anim_ctl.face.mouth_db` gets the RTPC every >= 1/30 s. Background autotests are
muted unless `--voiceaudio`; `--voicelog=<file>` writes each zombie's played lines.

## 5. Verification (game/test_out/zaudio, 2026-10-08)
`RUN_TEST_ENGINE_ARGS="--fixed-fps 60 --audio-driver Dummy" tools/with_cpu.sh zaudio tools/with_lock.sh zaudio
tools/run_test.sh --combattest=game/test_out/zaudio --animcap=z_face --voicelog=game/test_out/zaudio/voice.jsonl`,
then `python -I tools/zaudio/face_report.py game/test_out/zaudio game/test_out/zaudio/voice.jsonl`. 0 script errors;
no audio output (dummy driver, players muted under run_test).
- Every body breathes per DI2: calm BreathIn / BreathOut lines with the 0.1 s holds (Runner 0 s), after the target
  is set AlertBreathIn / AlertBreathOut (rules 301/302 and 5525/5526 on {Speaker}.CombatState); the Runner's lunge
  montage notify played RunnerExertLunge (VocalBreathingOut, BreathingZombieRunner.ExertLunge). Ogg lengths equal
  the wem sample counts.
- Mouth vs voice (jaw angle in head space vs the DI2 mouth input 2^((dB + 48) / 10), facial layer on, best lag):

| body | calm | combat |
|---|---|---|
| Walker | 0.978 @ 1 frame, jaw 0-21 deg | 0.919 @ 2, 0-17 deg |
| Runner | 1.000 @ 1, 0-11 deg | 0.983 @ 1, 0-14 deg |
| Shambler | 0.994 @ 1, 0-21 deg | 0.994 @ 1, 0-21 deg |
| Thug | 0.998 @ 1, 0-22 deg | 0.997 @ 1, 0-17 deg |

  The 1-2 frame lag is FaceLayer's 7/s blend-space weight interpolation (DI2's). The capture's diagnostic sweep
  segment mixes two writers (the sweep and the voice's 1/30 s poll) and is not a measure.
- The combat suite (`tools/run_all_tests.sh combat`) shows no GDScript errors; its 2 counted errors are the Rust
  GDExtension shutdown panics that the animation session's own run shows too.

## 6. UNVERIFIED / not done
- DamLoc native rules: tie-breaking between equal-complexity rules (the port takes the first, derived first),
  Shuffle semantics (port: shuffled bag, no repeat across refills), the (BaseVoiceSet, Trigger) lookup across voice
  sets, and dialogue-component priority interruption (only the breathing machine's own interrupts are ported).
  The play path is 0x14116ca90 -> 0x140e4b200 -> 0x140e747b0 (rule choice inside, not read); the rule XML parser
  0x140e66ae0 reads Index / CriteriaComplexity / CriteriaBoost with _wtoi.
- No-rule failure: DI2 logs and leaves the waiting flag set; the port advances (see section 3).
- Meter input skips the voice HPF and the two distance/elevation EQs before the meter; HDR busses, aux reverb
  sends, ST_Grapple state props, SFX_Walker_Distance walla switching and the audio AI-LOD budget are not ported.
- Combat/NewTarget, TargetKilled (CombatZombie, globalDialogue) triggers are in the data but nothing fires them yet.
- Grapple flag = `reactions.state == "paired"`; combat state = FaceLayer.combat_state stand-in.
- The anim session's z_face diagnostic sweep writes mouth_db; ZombieVoice now overwrites it every poll.
- Voice choice among a CT_Voice chain: uniform random (native, not read).
- run_test.sh doesn't pass `--audio-driver Dummy` itself; ZombieVoice never starts playback when a `*test=` argument
  is present (unless `--voiceaudio`), so suites stay silent either way.
