# DI2 recreation: spec index (read first)

Every session reads this, COORDINATION.md and UNVERIFIED.md before working. Each note below holds the static RE of the
shipping exe and DI2's cooked data for one system: exe addresses, data paths and what the Godot port does. Personal
testing only: never share these notes or the data they cite.

| Note | System | Owner |
|---|---|---|
| [RECON.md](RECON.md) | Static recon of the install: paks, AES, tooling (CUE4Parse / di2x, shader archives) | gore |
| [PLAN_1to1.md](PLAN_1to1.md) | The approved 1:1 work list | gore |
| [UNVERIFIED.md](UNVERIFIED.md) | Every stand-in or unproven value, by system (the "never assume" audit) | shared |
| [RE_FLESH.md](RE_FLESH.md) | FLESH splatter: stamps, orientation, hit-effect trees, hit-effect spawn transform | gore |
| [RE_DISMEMBER.md](RE_DISMEMBER.md) | Mesh-edit splatter passes: dismember, bone break, bisection, gradual damage effects | gore |
| [SHADERS_FLESH.md](SHADERS_FLESH.md) | Decompiled FLESH skin / cloth / wound shaders | flesh-shaders |
| [DEFORM_STREAM.md](DEFORM_STREAM.md) | Per-vertex deform stream (wound depth) | gore |
| [VISCERA_PARTS.md](VISCERA_PARTS.md) | Viscera and spawnable parts | gore |
| [RE_EXPLOSIONS.md](RE_EXPLOSIONS.md) | Explosions: blast front, falloff curves, victim point, occlusion | gore |
| [RE_ACCUMULATING.md](RE_ACCUMULATING.md) | Status build-up meters (burning / corroded / electrocuted) | gore |
| [RE_PROPAGATION.md](RE_PROPAGATION.md) | Burning / corroded spreading over body proxies | gore |
| [RE_FLUIDS.md](RE_FLUIDS.md) | Gameplay fluids: droplets, puddles, fluid buffer + compose, wound fluid | gore |
| [PARTICLES.md](PARTICLES.md) | Hit particle effects: Cascade emulation, materials | particles |
| [WEAPON_VFX.md](WEAPON_VFX.md) | Muzzle flashes, tracers, shell ejects, environment hit trees | weapon-vfx |
| [HIT_REACTS.md](HIT_REACTS.md) | Zombie hit reactions (CT_HitReact trees) | animations |
| [ANIMATION.md](ANIMATION.md) | Animation layers, blends, notifies, facial layer | animations |
| [ZOMBIE_AUDIO.md](ZOMBIE_AUDIO.md) | Zombie voice / breathing audio (drives the facial mouth) | animations |
| [DANI.md](DANI.md) | Dani first-person mesh, materials, hand blood | dani-model |
| [DEFERRED_LIGHTING.md](DEFERRED_LIGHTING.md) | DI2's deferred light pass and BxDFs (skin, cloth, hair, eye) | dani-model |
| [TEST_MAP.md](TEST_MAP.md) | DI2 level (NH_04 street) as the test environment, level fluid / lighting settings | di2-test-map |

Tools: `tools/re/di2exe.py` (exe reflection / xrefs), `tools/re_*/decomp.sh` (headless Ghidra per session),
`tools/di2x.sh json|raw` (CUE4Parse export), `tools/shaders/decompile.py` (shader archives), `bpdump.exe` +
`tools/bp_pretty.py` (Blueprint graphs). Tests: `tools/run_all_tests.sh [flesh autotest combat weapon]`.
