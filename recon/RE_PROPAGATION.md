# DI2 damage-effects propagation (burning and corroded spreading; static RE, personal-use notes)

**Port:**
- `tools/build_body_proxies.py` writes `game/data/body_proxies.json`;
- `game/scripts/damage_propagation.gd` is the runtime;
- `zombie.gd` hooks it in through `_begin_propagation` and `_electrocute_look`.

Decompiles: `extracted/ghidra/explosion_prop*.c`, `explosion_stop*.c`, `explosion_encode.c` (tools/re_explosion/decomp.sh).
BP bytecode: `extracted/json_bp/.../StatusEffects` (tools/bpdump + tools/bp_pretty.py).

## Component

- **Class:** `UDamageEffectsPropagationComponent`:
  - StaticClass 0x141ba7220;
  - InternalConstructor 0x141ba77f0;
  - vtable 0x1451495c0, whose tick at slot 0x330 is 0x141223b50.
- **Instance:** `BP_Base_AI` carries it as `DamageEffectsPropagation`:
  - **Tree:** BodyProxyTree `BodyProxy_ZombieStandard`.
  - **Burning:**
    - CE `CE_StatusEffect_Burning_Propagation`, CosmeticEffectParameters {Extinguished: 0}, threshold 0.5;
    - PropagationSpeed is 12 if `StatusEffect_Flammable`, else 6.
  - **Corroded:** CE `CE_StatusEffect_Corroded_Propagation`, threshold 0.5, speed 6.

**Body nodes** (BuildBodyNodes 0x1412026e0, node builder 0x141206130, world transform 0x141208920):
- The asset has 24 `BodyNode`s on 21 `BodyProxy`s.
- Each proxy has a BoneName and, optionally, a Transform.
- Each node has:
  - a Transform, relative to its proxy;
  - `BodyNodeData`, e.g. `Size` 0 / 0.5 / 1;
  - `Links`.
- A node's world transform is node.T × proxy.T × bone.
- Links are made two-way.
- A node whose bone maps to conflicting physics bodies is marked invalid (−2).

## API (BlueprintCallable; exec thunks at 0x141ba97d0 and nearby)

**StartEffect(name, Location, BoneName, Amount)** → 0x14121f3e0:
- The effect index comes from FindEffectIndex (0x141205cd0) and must be bEnabled.
- The node is the one nearest Location among nodes on BoneName (0x1412066c0), else the nearest of all.
- value[node] = sat(value[node] + Amount).
- WeightEffectData then runs from that node.

**StartEffectWithParameters(…, Parameters, …)** is the same, plus a KB of CE parameters for this effect's CEs.

**StopEffect(name)** → 0x141221590(name, None, 0, 0) → 0x14121c560:
- resets the effect's node values;
- destroys every CE it spawned (CE manager Destroy) and removes the effect state.

**StopEffectWithParameter(name, param, value)** first sets that parameter on the spawned CEs (0x14121e2b0).

## WeightEffectData (0x141227d30, 0x141228030)

Its purpose is to throttle which nodes may show the CE.

**Weights:**
- w[i] = FRand() for every node;
- the start node gets +EpicentreWeight;
- its links, recursively, get +(EpicentreWeight − k·EpicentreFalloff) while that stays above 0.

**Shown** = w[i] > fx.DamagePropagationThreshold × 2 × mean(w).

**Cvar inits:**

| Cvar | Init | Default |
|---|---|---|
| `fx.DamagePropagationThrottleEpicentreWeight` | 0x1404b9b70 | 0.5 |
| `fx.DamagePropagationThrottleEpicentreFalloff` | 0x1404b9b00 | 0.1 |
| `fx.DamagePropagationThreshold` | 0x1404b9a90 | bss 0 |

`fx.DamagePropagationThreshold` is set to 0.0 at every level in DefaultScalability.ini, so every node is shown.

## Tick (0x141223b50)

For each running effect (state stride 0x90):

1. **Spread.** If speed > 0, every valid node with v < 1 takes m = the max of its valid neighbours' values. If
   v < m, then v' = min((m − v)·speed·dt + v, 1). Values are read from the previous tick and written to a copy.
2. **Pick.** Pick the one node with the largest value at or above CosmeticEffectThreshold that hasn't spawned and
   is shown. The comparison starts from nextafterf at the threshold.
3. **Spawn.** If a node was picked, spawn its CE through the CE manager (0x140ccd260). The CE is attached to the mesh
   at the node's bone, with the node's world transform. Its parameter KB merges:
   - the effect's CosmeticEffectParameters;
   - the node's BodyNodeData, e.g. `Size`; one special parameter is clamped to < 1 → 0.8 / ≥ 1 → flag;
   - the StartEffectWithParameters parameters.

   The handle is kept per node, so each node spawns once per effect run.

## Status effect BPs (bytecode)

**BP_StatusEffect_DamageOverTime:**
- ReceiveBegin:
  - EstimatedDamage = EstimateDamageToOwner(InitialDamage);
  - BeginCosmeticEffect: StatusEffectCosmeticEffect attached at the actor location + CosmeticEffectOffset;
  - adds the PerkToAdd perk and the KbFactToApply fact;
  - applies InitialDamage.
- `Begin Propagation Effect(name)`:
  - StartEffectWithParameters(name, Instance.Params.OriginLocation.VectorLocation,
    EncodeSplatterMeshDamageParamsForPropagation(Health, MaxHealth, EstimatedDamage),
    OriginLocation.BoneName, 1.0);
  - without a SimpleHealthComponent it calls plain StartEffect.
- EncodeSplatterMeshDamageParamsForPropagation (0x14123f750) gives the same facts as the hit encoder 0x14123f640:
  - DamageAsFractionOfMaxHealth = est / max;
  - HealthRemainingAsFractionOfMaxHealth = (health − est) / max.
- Tick damage: DamagePerSecond × DamageDecayCurve(1 − remaining/duration) × dt, when the curve is set.

**Burning:**
- ReceiveBeginInstance → `Begin Propagation Effect('Burning')`.
- ReceiveBegin sets the `IsBodyBurnt` fact and the state transmitter status 2.
- Zombie: InitialDamage 30, base DPS 15, fact IsOnFire.
- The zombie's ReceiveEnd → `StopEffect('Burning')`.

**Corroded:**
- `Begin Propagation Effect('Corroded')`.
- InitialDamage 15, DPS 7, DamageDecayCurve.
- Adds the ElementalDamageReceived modifier and the fact `IsBodyCorroded`.
- ReceiveEnd → `StopEffect('Corroded')`.

**Electrocute:**
- No propagation.
- CE_StatusEffect_Electrocute is spawned attached at the mesh's `spine_01` socket with a zero rotation:
  - SplatterMesh UVScale 300, cauterisation 5, Duration 8;
  - plays the `ElectrocuteAdditive` montage.
- Zombie InitialDamage 25 (base 30).

## Port gaps (UNVERIFIED #52)

- **Status lifecycle.** The recreation's gore-core statuses (build-up 100, durations 6 / 3 / 8 s, DPS as fractions
  of max health) are stand-ins. DI2's StatusEffectParams durations and the accumulating build-up come from the
  appliers, and are not traced.
- **Fire and acid particles:**
  - the propagation CEs' ConditionalInstanced particles (by Size);
  - CE_StatusEffect_Burning's own effects;
  - the Extinguished parameter.

  These wait for the particle port. DamagePropagation calls DI2Particles.play_ce when it has the CE.
- **EstimatedDamage** is taken as the zombie status's InitialDamage, without the damage estimate's modifiers.
