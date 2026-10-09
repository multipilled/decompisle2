# DI2 accumulating effects (status build-up): native code

These are static RE notes on `DeadIsland-Win64-Shipping.exe`. The decompiled C is in `extracted/ghidra/explosion_accum*.c`, `explosion_accscale*.c` and `explosion_impproc.c`.

The port lives in three places:
- `rust/gore-core/src/status.rs`: the meters.
- `GoreBody.accumulate` / `set_accumulating_def` / `accumulating_state`: the Godot bindings.
- `game/scripts/accumulating_effects.gd`: the appliers' data and the level scaling.

The data comes from `tools/build_accumulating.py` and is written to `game/data/accumulating_effects.json`.

## Where the effects come from

- **Weapon mods.** Each `DA_WeaponModConfig_*.WeaponModConfigs[]` entry (one per BP_WeaponMod_<Name>_Level_N) has:
  - `OnHitAccumulatingEffects`: `{EffectType, bApplyMaxValue, ValueToApply, CanExtendEffectDuration}`.
    - Melee level 1/2/3: 0.3 / 0.4 / 0.5. Tearing: 0.4 / 0.5 / 0.6.
    - Ranged: 0.22 at level 1.
  - `ImpactRequestModifiers`:
    - A `ConvertDamageTypeAndQuantityCommand` (Physical → the element, 1.0).
    - An `ImpactRequestModifierDataDriven` with an `AddAccumulatingEffectsCommand` (+0.25 of the mod's type), an `OnImpactModifiedCosmeticEffect` (CE_Fire_Lingering ...) and `ImpactKBRequirements`. Melee requires `{Hit}.HeavyAttack`; ranged requires `{Hit}.Head`.
  - Weapons use `AccumulatingEffectsScalingPolicy = ScaledBasedOnWeaponLevel`.
- **Explosions.** `DamageDefinitions[].AccumulatingEffectsToApply` (same struct), plus `bUseScalingOnAccumulatingEffects`. Examples:
  - Molotov: Burning 1.0 ×2, extends.
  - ElectricBomb: Electrocuted 1.0 ×2.
  - AcidBomb: Corroded 1.0 ×2, extends.
- **Zombie perks.** E.g. `DA_PerkDefinition_StatusEffect_Zombie_AddBurningBuildUpOnHit`: a burning zombie's outgoing impacts add Burning 0.25. Not ported.

## Impact processing (`0x1413d8af0`)

1. `0x1413c7d00(policy, effects[], instigator, victim, overrideSettings, defaultSettings, weaponLevel)` scales each entry. With policy ≠ None and a valid victim level:
   - `x = victimLevel − sourceLevel`, as a float. The source is the instigator's level (policy 1) or the weapon's (policy 2).
   - `value = Evaluate(settings, value, x)` (`0x14117f490`).
   - ELevelScalingMethod values: None 0, Linear 1, Ranged 2, Increment 3, Curve 4, Explicit 5.
   - Curve: `value × UCurveFloat(x)`.
   - The default settings are `DA_AccumulatingEffectsLevelScaling_Default` → `Curve_AccumulatingEffectsLevelScaling`: (0, 1) (1, 0.8) (2, 0.65) (3, 0.5) (4, 0.35) (5, 0.25). Values are held outside the keys.
2. `0x1413ca090` passes every 12-byte entry `{u8 type, u8 bApplyMax, f32 value, u8 canExtend}` to `UAccumulatingEffectComponent::UpdateEffectValue` (`0x141473550`).
3. UpdateEffectValue skips immune types (`0x141462b10`). Otherwise it finds the instance for the type (`0x14145a690`) and calls its update (`0x1414746f0`).
4. How an `AddAccumulatingEffectsCommand` combines with an on-hit entry of the same type isn't traced: summed or appended. Both give the same meter, because each value adds to it. The port sums.

## The instance (`UAccumulatingEffectInstance`)

**Fields:**

| offset | field | source |
|---|---|---|
| +0x29 | state | Accumulating 0, Active 1, Paused 2, Idle 3 (EAccumulatingEffectState) |
| +0x2C | stored value | |
| +0x30 | last update time | world seconds |
| +0x34 | rate | |
| +0x38 | DecayMultiplier | |
| +0x3C | DurationMultiplier | |
| +0x40 | AccumulatingPauseDuration | |
| +0x44 | PauseDuration | |
| +0xB0 | reset timer | |
| +0xB8 | pause-end timer | |
| +0x140 | GainMultiplier | |
| +0x144 | AccumulatingDecayRatePerSecond | |
| +0x148 | DefaultEffectDuration | |
| +0x158 | implementation | |

**Value** (`0x14145df40`):
- `elapsed = now − last`.
- While Idle or Accumulating: `elapsed = max(0, elapsed − AccumulatingPauseDuration)`.
- `value = max(0, stored − elapsed × rate)`.

**Rate** (`0x14145e010`):
- Idle / Accumulating: `DecayRate × DecayMult`.
- Active: `1 / (DefaultEffectDuration × DurationMult)`.
- Paused: 0.

**Add** (`0x141450ec0`):
- `v = bApplyMax ? 1 : (v > 0 ? v × GainMult : v)`.
- `stored = clamp(value + v, 0, 1)`; `last = now`.

**SetRate** (`0x1414729a0`):
- If the rate changed: `stored = value`, `last = now`, then the new rate.
- If a reset timer exists, re-arm it (`0x141473310`) to `value × DefaultEffectDuration × DurationMult`, keeping it paused if it was paused.

**Update** (`0x1414746f0`):
- **Accumulating:** add. If stored ≥ 1, go Active. Otherwise re-arm the reset timer to `value / rate + AccumulatingPauseDuration`, firing Reset.
- **Active:** if canExtend, go Paused.
- **Paused:** if canExtend, re-arm the pause timer to PauseDuration.
- **Idle:** add. If stored ≥ 1, go Active; otherwise, if stored > 0, go Accumulating.

**SetState** (`0x141472a50`):
- **→ Accumulating:** SetRate(decay); arm the reset timer as above.
- **→ Active:** SetRate(active). `UAccumulatingEffectImplementation::BeginEffect` (`0x141b19560`) applies the status with the instigator and location. Then, if a reset timer exists, UnPauseTimer; otherwise set the reset timer to `DefaultEffectDuration × DurationMult`.
- **→ Paused:** SetRate(0); PauseTimer(reset). The pause timer is set to PauseDuration, firing Active (thunk `0x14146ef90`, `mov dl, 1`).
- **→ Idle:** SetRate(decay); EndEffect if the effect was running.

**Reset** (`0x14146c340`): clears both timers and the instigator/contributors, sets stored = 0, then SetState(Idle).

So the meter fills from hits. AccumulatingPauseDuration (2.5 s) after the last gain, it decays at 0.05/s; at 0 it resets.

At 1 the status begins and the meter drains to 0 over DefaultEffectDuration, and the status ends then. Hits with CanExtendEffectDuration freeze the drain for PauseDuration (1 s), and re-arm the freeze while it lasts.

## Configs

`BP_StoryGameMode.AccumulatingEffectDefinitions` maps:
- DefaultAI → `DA_AccumulatingEffectConfig_Walker_Default`.
- Specials → `DA_AccumulatingEffectConfig_Specials`.
- Player → `DA_AccumulatingEffectConfig_Player`.

Characters pick their recipient with `EffectsDefinitionToUse`:
- BP_Base_AI → DefaultAI.
- BP_Base_Thug / Butcher / Mutator / Screamer / Slobber / Reformer / Whipper → Specials.

Walker_Default values:
- Every type: decay 0.05, AccumulatingPauseDuration 2.5, PauseDuration 1.
- Durations: Burning 5, Electrocuted 4, Corroded 5, Bleed 5 (Draining), Weakened 7 and Disoriented 5 s (Specials: Disoriented 4 s).
- Each type applies its `BP_StatusEffect_*_Zombie`.
- Gain / Decay / Duration multipliers: DefaultValueOverride 1.

## Weakened and Disoriented (2026-10-09)

BP bytecode: `extracted/json_bp/.../StatusEffects/{ApplyDebuff/Exposed,Stun/Disorientated}` and
`Core/StatusEffects/{ApplyDebuff,Stun}` (tools/bpdump + tools/bp_pretty.py).
- **Weakened** (tearing mods): `BP_StatusEffect_Weakened` → `BP_Base_StatusEffect_ApplyDebuff`. ReceiveBeginInstance
  calls the params' `GetModifiers` and `ApplyModifiableValues` (AddModifier per entry, policy RefCountDuplicates, value
  now because `ApplyDebuffOnBeginInstance` defaults true); ReceiveEndInstance removes them.
  `BP_StatusEffectParams_Weakened.GetModifiers` = {DA_ModifiableValueDef_PhysicalDamageReceivedModifier,
  DamageTakenModifier 0.3}. Look: BurstCosmeticEffectDefinition CE_StatusEffect_Weakened_Burst, ParticleToApply
  PS_Enemy_Weakened_StatusFX, AudioChime CE_StatusEffect_Weakened_Zombie_Audio, TickInterval 1.
- **Damage categories** (BP_DamageType_* DamageCategory): Physical = Blunt, Sharp, Projectile, Explosive, **Bleed**;
  Elemental = Fire, Acid, Electric. Both DamageReceivedModifier defs: DefaultValueOverride 1, MaxValueLimit 2, Additive.
- **ModifiableValues** (UModifiableValuesComponent; exec table AddModifier 0x141d44e30 → 0x141a89bd0 → per-value add
  0x141a897d0, GetCurrentValue 0x141d45440 → 0x141a9aff0, recompute 0x141aadf70): value = base, then each source's
  entry combined by the def's ResolutionType (def +0x40: Additive 0, Min 1, Max 2, Multiplicative 3); base =
  DefaultValueOverride when bOverrideDefaultValue (+0x38/+0x3C), else 1 for Min / Multiplicative and 0 otherwise;
  clamped by MinValueLimit (+0x41/+0x44) and MaxValueLimit (+0x48/+0x4C). A repeated AddModifier from the same source
  only adds a GUID (RefCountDuplicates), not a second value. So Weakened = physical damage taken x 1.3; Corroded's
  ElementalDebuffToApply 0.25 = elemental x 1.25.
- **Disoriented** (impact mods): `BP_StatusEffect_Disoriented` → `BP_Base_StatusEffect_Stun`. ReceiveBegin increments
  the KB counter facts FactKeysToApplyWithAction (StopActions, StopEngagementOpportunity), ReceiveEnd decrements them;
  the AI action DA_ActionDefinition_Stun_Disorientated_AI (ConstructActionParams: IntoAnimSet Disorientated,
  OutroAnimSet DisorientatedEnd, AnimPlayRate = 1 ± AnimPlayRateVariationPercentage 20 %, AnimSetStream =
  MakeRandomStream(RandomInteger(20))). AddDeviationModifier: AddModifier(DA_ModifiableValue_AccumulatingEffect_-
  Disoriented_DurationMultiplier (Multiplicative, default 1), 'DeviationModifier', RandomFloatInRange(0.85, 1.15)),
  removed at ReceiveEnd. On a player it also applies Blinded (AccuracyReduction -0.2) and Slowed (-0.5, 3 s).
- **Port** (gore-core status.rs, zombie.gd `_on_status_started`): both meters run like the others (Walker_Default /
  Specials configs); Weakened multiplies physical damage taken by 1.3; Disoriented's deviation scales its running
  DurationMultiplier (`set_duration_deviation`, cleared at the end); zombie.gd calls `reactions.disoriented_start()`
  if the reactions owner adds it (the Disorientated anim sets and StopActions are theirs).
- **Open:** whether the accumulating instance's DurationMultiplier (+0x3C) follows the ModifiableValue live (assumed:
  the deviation would otherwise do nothing; the writer of +0x3C would settle it); the Weakened / Disoriented looks
  (particle port); the consumer of the DamageReceivedModifier (the multiply in the damage calculation is not traced,
  same as Corroded's).

## Port gaps (UNVERIFIED #52)

- **Mod damage conversion.** The mods' `ConvertDamageTypeAndQuantityCommand` isn't ported. The recreation still adds a separate 0.35× elemental hit.
- **Mod level.** `player_melee.mod_level` defaults to 1.
- **Weapon level.** It is Dani's level.
- **Explosion distance scaling.** Explosions apply their entries in full; whether the blast distance scales them isn't traced.
- **Molotov area.** The molotov stand-in's fire area reapplies the Molotov archetype's entries every tick.
- **Weakened / Disoriented:** ported 2026-10-09 (section above); Disoriented's anim and AI stop need the reactions owner's hook.
- **Modifier CEs (BLOCKED, 2026-10-09).** The modifiers' `OnImpactModifiedCosmeticEffect` (CE_Fire_Lingering =
  PS_Fire_Lingering_Smoke, CE_Sharp_Tear = PS_Tear_Sharp_Directional bForceNotAttached, CE_Blunt_Large_Normal = blood
  burst + fluids ... on heavy attacks or headshots) isn't played. Traced so far (tools/re_gore/*.py, own Ghidra
  project extracted/ghidra_gore):
  - UImpactRequestModifierDataDriven: size 0x1F8, OnImpactModifiedCosmeticEffect +0x1F0 (GeneralImpactEffects +0x1E0,
    RadialImpactEffects +0x1D0, PointImpactEffects +0x1C0, AnyImpactEffects +0x1B0, Radial/PointImpactAngularLimitations
    +0x198 / +0x180); GetPrivateStaticClass 0x141ccd730, InternalConstructor 0x141ccd900, vtable 0x145196710 (154 slots).
  - The only code reading +0x1F0 is the class's own last virtual, slot 153 (0x14140c4a0): it calls the super
    (0x1413d3b80, which broadcasts a delegate at +0xC8 with the impact), then, if the CE is set and the weak object
    pointer at +0x148 resolves, spawns the CE (0x140ccc3a0) attached to that actor's root component (+0x160) at the
    component's +0x240 location with the constant rotation at 0x146cbd5a8 (bounds-centre-style, not the impact point).
  - +0x148 is set by the base's init 0x1413d1ef0 from its 4th argument (a pawn: vtable +0x6B0 / +0x6B8 checks set
    +0x165). No direct callers of the init or of slot 153 (+0x4C8) were found by a call scan: both are virtual.
  - The CEs are hit effects (blood bursts, a directional tear) and the fire-mod hit trees already play
    CE_Fire_Lingering, so +0x148 is probably the victim; not proven. **Settles it:** Ghidra with auto-analysis (or a
    vtable-slot xref pass) for the callers of the init (which actor is passed) and of slot 153 (once per modified
    impact or once per activation). Until then nothing is played (no double-up risk).
  `AccumulatingEffects.mod_cosmetic_effects` lists them.
- **Immunities.** `ImmunityAccumulatingEffects` (e.g. fireman zombies) isn't ported.
- **Corroded decay.** Corroded's damage decay follows the meter. DI2's status curve runs over the status's own time, which pauses don't change.
