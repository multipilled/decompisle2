# decompisle2: plan

**Goal:** the whole of Dead Island 2 playable 1:1 from your own install: every map, the story and side quests, every
zombie, every slayer, weapons, mods, crafting, skills, the economy, cutscenes, audio and UI, behaving and rendering as in
the original. New code only. The game's assets and data are read at runtime from your own copy and never ship with
this repository. Online co-op is out of scope (single player, offline).

This repository starts from the **DI2 Gore Lab**: a working recreation of DI2's gore system (FLESH), zombies, Dani in
first person with DI2's weapons, and a Horde map, built on a Rust core and Godot 4.7. Milestone 1 below finishes that lab
as a showcase; the later milestones grow it into the full game.

## How the original is built (facts, see `recon/RECON.md`)
- A customized Unreal Engine 4 (4.27-era IoStore layout, TOC version 3). One shipping executable, no PDB.
- 46 `.utoc` containers; 38 are AES-encrypted with one key. The key is recovered locally from your own executable
  (`tools/find_aes_key.py`) into a git-ignored file and is never committed or shared.
- No anti-cheat. Epic Online Services is present for co-op, so the original is kept offline whenever it's compared.
- Animation is mostly ACL-compressed (decoded by `tools/acl13dec`), with some sequences in UE's own codec (exported as
  PSA); UI is Scaleform GFx (173 SWF movies, `recon/GAMEPLAY_UI.md`); audio is Wwise.

## Architecture
| Layer | Where | Notes |
|---|---|---|
| Importer | `tools/di2x` (+ `tools/test_map/mapx`) | reads the containers and exports JSON, meshes, textures and animations into git-ignored folders |
| Converters | `tools/build_*.py`, `tools/convert_*.py` | DI2 data assets -> `game/data/*.json` (git-ignored, regenerated) |
| Formats library | `rust/` | readers and rules tested without the engine (`cargo test`); new readers for formats we own go here, each proven by a round trip (`docs/formats/`) |
| Simulation core | `rust/gore-core` | headless and deterministic: gore, statuses, fluids, damage; unit-tested |
| Engine project | `game/` (Godot 4.7) + `rust/gore-godot` (GDExtension) | rendering, animation, AI, player, UI, maps |
| Behaviour notes | `recon/*.md`, then `docs/behavior/` | plain-words descriptions of how the original works and how each fact was checked |

Every number, timing and rule comes from the game's data or static analysis of its executable and is cited in a code
comment (asset path or address). Unknowns are listed in `recon/UNVERIFIED.md` until resolved; nothing is guessed.

## Milestones
Each milestone ends in a check a scripted, background test can run (off-screen, silent, never taking focus).

| # | Milestone | Weight | Done | Done-check |
|---|---|---|---|---|
| M0 | Foundation: container reader, importer, converters, commit guard, headless test harness | 8 | 70% | `cargo test`; the importer exports every container listed in the install; the guard blocks game files and private strings |
| M1 | Combat showcase (the Gore Lab goal): full UI and gameplay, gore, every zombie variant, the whole Horde map NH_04 rendered as in game | 25 | 46% | the lab's suites (flesh, combat, weapons, zombie AI, archetypes, map walk) at 0 errors on NH_04, plus a recorded showcase |
| M2 | Game framework: saves, inventory, economy, crafting and mods, skill deck, progression, pickups and loot | 14 | 5% | save round trip; inventory, crafting and skill math checked against DI2's data tables |
| M3 | World: every map streamed, traversal, doors, fast travel, loading | 14 | 5% | every map loads headless; a bot walks each district's loop without falling through |
| M4 | Story: quests, NPCs and dialogue, cutscenes, subtitles | 14 | 0% | each quest driven to completion by a scripted bot; cutscene frames and subtitle timings checked against the data |
| M5 | Every playable slayer: stats, innate skills, first-person bodies | 5 | 10% | each slayer's stats and innate skills checked against DI2's data; first-person captures |
| M6 | Audio: Wwise banks, events, music states, voice | 6 | 10% | every bank decodes; event-to-media resolution tests; music state tests (decode only, no playback in tests) |
| M7 | Front end and the whole UI (Scaleform screens) | 6 | 10% | every screen captured and navigated by scripted input |
| M8 | Performance: crowds at frame rate in every district | 4 | 5% | a perf check per district at the target frame rate |
| M9 | Expansions and modes: Haus, SoLA, Horde | 4 | 0% | their maps load and their quests or rules pass the M3 / M4 checks |
| | **Overall** | 100 | **~20%** | |

## How the Gore Lab is reused
- Everything in this repository today is the Gore Lab's public source: the Rust core, the Godot project, the importer
  and converters, and the research notes. Nothing is thrown away; M1 finishes it.
- Development happens in a private upstream checkout of the Gore Lab, which keeps the full history, the working board and
  the hand-over notes. This public repository receives scrubbed snapshots of it, and pull requests made here are
  ported back.
- Game files, extracted assets, decompiled code and the container key never come across, in either direction.

## Clean room and public-repo rules
- Decompiled code is read only to understand behaviour and stays in the git-ignored `gamedata/` folder (indexed by
  `gamedata/re/SPEC.md`). It is never pasted or paraphrased into tracked files. Comments may cite executable addresses
  as research notes.
- Behaviour is written up in plain words first, and code is written from those notes.
- The commit guard (`.githooks/pre-commit`; enable with `git config core.hooksPath .githooks`) blocks game files,
  decompiler-looking text and private strings.

## Decisions
Made:
- Name: decompisle2 (avoids the publisher's trademark as the project name).
- License: GPL-3.0-or-later.
- Published when it's ready (the user's call); until then it's committed locally only. The private upstream lab stays
  the working copy.
- Stack: keep the Gore Lab's Rust core + Godot 4.7.

Open (recommendation first):
1. Order after M1: M2 (framework) before M3 (world), since quests need saves and inventory. Alternative: M3 first, for
   a walkable game sooner.
2. Container reading: keep the existing importer for now, then write our own Rust reader for the formats the game
   needs at runtime, so play doesn't depend on a pre-export step. Alternative: stay with pre-exports.
3. Which slayers after Dani: all five others in M5, after checking whether they share Dani's first-person rig.
