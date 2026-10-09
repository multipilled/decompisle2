# File formats

One note per format the project reads: layout, every field's meaning, and how the reader was proven (a byte-for-byte
round trip where possible, otherwise a check against the importer's export). Readers live in `rust/` (tested with
`cargo test`, no engine) or `tools/`.

| Format | Note | Reader | Proof |
|---|---|---|---|
| IoStore containers (`.utoc` / `.ucas`), AES | `recon/RECON.md` (Paks) | `tools/di2x` | exports match the game's asset list |
| ACL 1.3 animation | `recon/ANIMATION.md` | `tools/acl13dec` | clip lengths match each sequence's SequenceLength |
| Custom LOD deform stream | `recon/DEFORM_STREAM.md` | `tools/deform/` | round trip of the stream |
| Named subsections / shared render data | `recon/VISCERA_PARTS.md` | `tools/build_subsections.py` | sections resolve on every body |
| Scaleform GFx movies (UI) | `recon/GAMEPLAY_UI.md` | `tools/re_ui/` | movies carved verbatim from their assets |

New formats get a row here and a note in this folder.
