# DI2 per-vertex deform stream (`ATTRIBUTE16`, `DeformBufferSRV`)

Static analysis only: the cooked skeletal meshes (via `tools/di2x.sh raw`) and the shipping exe in a separate headless
Ghidra project (`extracted/ghidra_mesh/DI2mesh`, no auto-analysis). The game was never run. Personal research notes.

Tools (all new, in `tools/deform/`):
- `di2mesh.py`: parser for DI2's cooked `FSkeletalMeshLODRenderData` (sections, buffers, deform block).
- `glb.py`: minimal glb reader.
- `export_deform.py`: writes `game/assets/di2/<body>/<body>.deform.{bin,json}` and runs every check quoted below.
- `DeformDecompileAt.java`: copy of `tools/re/DecompileAt.java` (class renamed so Ghidra's script cache doesn't clash).
Decompiled C: `extracted/ghidra_mesh/decomp_deform*.c`.

## 1. Summary

- Every DI2 skeletal-mesh LOD carries one extra vertex buffer, **8 bytes per vertex = half4 `(x, y, z, depth)`**. It
  sits in the LOD record right after the standard UE 4.27 streamed data (exe: `FSkeletalMeshLODRenderData` member at
  `+0x1d8`, RHI friendly name "Deformation vertices"). CUE4Parse skips it (`FDeadIsland2SkeletalMesh.SkipExtraVertexData`).
- **xyz is an inward vector in cm, in the mesh's bind-pose space.** On skin and cloth it points against the vertex
  normal. Per section, 94–100 % of skin vertices and 83–100 % of cloth vertices have cos(D, N) < 0, with median cos
  between −0.69 and −0.99 (§4).
- **The `*IntA` interior shell is built from the same data.** Each shell vertex is an exact copy of an outer skin
  vertex: same position, same xyz, same UV0 and TangentX. Only three things differ:
  - the cooked depth is **1.0** instead of 0.0;
  - the normal is **negated**;
  - the triangles are the skin's triangles with **reversed winding**, and many are collapsed (index-degenerate) where no
    shell is wanted.

  The VS draws `P + Deform.xyz * Deform.w`, so the shell renders at `P_skin + D`: **every skin vector's tip is its
  shell twin's rendered position, to 0.0 cm** (all 4 bodies, all shells). A skin vertex sunk to depth 1 therefore lands
  exactly on the shell, which confirms the expectation in the brief. `|D|` is the local skin-to-shell thickness:
  - 0.5–1.7 cm on heads;
  - about 2–3 cm on the torso;
  - up to 15–17 cm on thighs.
- The shell only exists where its triangles are live. The share of skin vertices whose tip is a live shell vertex
  is (§5):
  - heads: 79–97 %;
  - upper body / torso: 30–41 %;
  - lower body: 10–14 %.

  Elsewhere the skin still sinks by `D` at depth 1, but there is no shell surface at the tip.
- **Cloth** vectors also point inward and roughly follow the skin vector beneath them (cos ≈ 0.86–0.97). They are
  longer than the cloth-to-skin gap: tips end a median 0.5–1.6 cm past the skin. They do **not** land on the shell or on
  the skin exactly. How cloth vectors were authored is **not determined**.
- Eyes, skull/brain, viscera, hair and skeleton sections have all-zero vectors.
- The glbs are matched vertex-for-vertex. The cooked positions equal the glb POSITIONs **bit-exactly (max diff 0)** on
  all 131,916 glb vertices; UV0 is bit-exact and normals agree to ≤ 0.0017.

## 2. Exe side (static)

| What | Address | Evidence |
|---|---|---|
| `FSkeletalMeshLODRenderData::Serialize` (DI2) | `0x143b072f0` | strip flags, bIsLODCookedOut, bInlined, RequiredBones, sections (`FUN_143aefcb0`), ActiveBoneIndices, BuffersSize, inlined stream, then the DI2 tail below |
| LOD render-data ctor | `0x143aed2c0` | calls the deform-buffer ctor with `this + 0x1d8` |
| Deform buffer ctor (leaf, no .pdata) | `0x143a4b5c0` | vtable `0x145df3e18`; ListIndex −1; zeroes `+0x10..+0x40`; object size 0x48 (deleting dtor frees 0x48) |
| Deform buffer vtable | `0x145df3e18` | dtor `0x143a52250`, InitDynamicRHI / ReleaseDynamicRHI = empty stub `0x140784e40`, **InitRHI `0x143a70060`**, ReleaseRHI `0x143a7aa80`, InitResource, ReleaseResource, **GetFriendlyName `0x143a6ab30` → "Deformation vertices"** |
| `DeformBuffer::Serialize(Ar, bNeedsCPUAccess)` | `0x143a7e660` | `Ar << u32 @+0x18; Ar << u32 @+0x1c`; if loading and `+0x1c != 0`: allocate the vertex data (`0x143a53450`); then `VertexData->Serialize(Ar)` = BulkSerialize; cache the data pointer at `+0x40` |
| Vertex-data allocator | `0x143a53450` | `new` 0x28 bytes, vtables `0x145df3db8` / `0x145df3d78` (`TStaticMeshVertexData`-style), `+0x20 = bNeedsCPUAccess`; then **`this+0x18 = data->GetStride()`** |
| Element stride | `0x1409afd80` | `mov eax, 8; ret` (vtable slot +0x20); GetAllocatedSize `0x142fcc4a0` = `Max * 8` |
| InitRHI | `0x143a70060` | `RHICreateVertexBuffer(size, usage 0x209 = Static\|UnorderedAccess\|ShaderResource)`; SRV (stride 4) and UAV with format `PF_R32_FLOAT` (0xd), or `PF_R32_UINT` (0x1c) when the bool at `+0x20` is set |

So the members are: `+0x10` VertexBufferRHI, **`+0x18` Stride, `+0x1c` NumVertices**, `+0x20` bool (picks the
R32_UINT views; not serialized, set elsewhere **[unknown]**), `+0x28` SRV, `+0x30` UAV, `+0x38` vertex data,
`+0x40` data pointer.

The GPU sees each vertex as two 32-bit words: `(x|y<<16)` and `(z|w<<16)`. That matches the deform CS, which rewrites
only the second word, keeping z and storing `f16(depth)` (SHADERS_FLESH.md §4.2). The half4 interpretation rests on
two things:
- the shaders' `ATTRIBUTE16` half4 and that CS packing;
- the decoded values themselves: depth is exactly 0.0 or 1.0, and lengths are in plausible centimetres. Decoding the
  same bytes as anything else gives no such structure.

The tail of `0x143b072f0`, after the standard 4.27 inlined stream data (decompiled):
```c
FUN_143a4ee50(Ar, LOD + 0x498);                      // TArray<uint8> (i32 count + bytes); count 0 in all 20 LODs
if (Ar.CustomVer(B2114303-D56B4B47-A93C5D7B-103CB47D) > 0)
    DeformBuffer_Serialize(LOD + 0x1d8, Ar, bNeedsCPUAccess);      // 0x143a7e660
if (Ar.CustomVer(same GUID) > 3)
    Ar << (bool32)LOD[0x484];                        // 1 in all 20 LODs; meaning [unknown]
```
(the GUID is the 16 bytes at `0x14697f3c0`; `Ar.UsingCustomVersion` on it is the function's first call). CUE4Parse's
reading `Position += 8 // Unknown and vertex stride ... ReadBoolean()` is byte-compatible: its "unknown" u32 is the
empty `TArray<uint8>` count and its trailing bool is `LOD+0x484`.

## 3. Cooked layout

All 20 LOD records (4 bodies × 5 LODs) parse end-to-end with these rules. Each deform block ends exactly where the next
LOD record begins, with no slack bytes. Every LOD has `bInlined = 1` and strip flags (1, 0).

```
FSkeletalMeshLODRenderData (cooked, inlined)
  u8,u8      FStripDataFlags                      (1, 0)
  bool32     bIsLODCookedOut                      0
  bool32     bInlined                             1
  TArray<u16> RequiredBones
  TArray<Section> RenderSections                  (layout below)
  TArray<u16> ActiveBoneIndices
  u32        BuffersSize
  -- inlined stream (UE 4.27 SerializeStreamedData) --
  u8,u8      FStripDataFlags                      (1, 0)
  index      u8 DataTypeSize, i32 ElemSize, i32 Count, data      DI2: indices are SECTION-RELATIVE
  positions  u32 Stride=12, u32 N, i32 12, i32 N, N*float3 (cm)
  tangents/UV i32 NumTexCoords, i32 N, bool32 FullPrecisionUVs(0), bool32 HighPrecisionTangents(0),
             i32 8, i32 N, N*(TangentX, TangentZ) packed int8x4,  i32 4, i32 N*NTC, half2 UVs
  skin wts   strip, bool32 variable, u32 maxInfl, u32 numBones, u32 N, bool32 16-bit idx, bulk u8; strip, i32 N, bulk u32
  colours    strip, u32 Stride=4, u32 N, i32 4, i32 N, N*BGRA8
  adjacency  u8 size, i32 elem, i32 count, data   (present: stream class strip bit 0 clear)
  i32        FSkinWeightProfilesData count = 0
  -- DI2 tail --
  i32        TArray<uint8> count = 0              (LOD+0x498)
  u32        Deform Stride = 8                    (LOD+0x1d8+0x18)
  u32        Deform NumVertices = N               (LOD+0x1d8+0x1c)
  i32,i32    BulkSerialize ElemSize = 8, Count = N
  N * half4  (x, y, z, w)   little-endian IEEE half
  bool32     LOD+0x484 = 1
```

Section (`FSkelMeshRenderSection`, DI2 cooked). The order follows CUE4Parse `FSkelMeshSection.SerializeRenderItem`:
- strip(2), i16 MaterialIndex, i32 BaseIndex, i32 NumTriangles, bool32 bRecomputeTangent;
- **no** RecomputeTangentsVertexMaskChannel byte;
- bool32 bCastShadow, u32 BaseVertexIndex;
- TArray<64-byte FMeshToMeshVertData> (cloth mapping), TArray<u16> BoneMap;
- i32 NumVertices, i32 MaxBoneInfluences, i16 CorrespondClothAssetIndex, 20-byte FClothingSectionData;
- bool32 bDisabled;
- DI2-specific: TArray<18-byte item> + 2 bytes.

The DI2 18-byte items read as `(u32 NumTriangles, u32 BaseIndex, u32 BaseVertexIndex, u16 NumVertices, u16 1|0, u16 0)`
sub-ranges of the section: one item on skin sections, many on skull/viscera. The trailing 2 bytes are 0, except
1 and 2 on the walker's two disabled skeleton sections. Their meaning is **not established**; the deform stream
doesn't need them.

Two side facts for RECON.md's "UV1–7 come out as zeros": the cooked meshes have NumTexCoords 2 (walker, shambler,
thug) or 3 (runner), and the deform stream is a separate buffer, not a UV channel.

## 4. Per body (LOD0)

| body | cooked verts | sections | deform block @ | data @ | glb verts / prims | max \|Δpos\| | max \|ΔUV0\| | max \|Δn\| | merged-vertex conflicts |
|---|---|---|---|---|---|---|---|---|---|
| walker | 39186 | 19 | 0x3baf50 | 0x3baf64 | 35049 / 17 | 0 m | 0 | 0.0017 | 0 |
| runner | 28862 | 18 | 0x382f99 | 0x382fad | 24724 / 15 | 0 m | 0 | 0.0017 | 0 |
| shambler | 26763 | 16 | 0x33e89e | 0x33e8b2 | 22631 / 13 | 0 m | 0 | 0.0017 | 0 |
| thug | 54772 | 15 | 0x4c7451 | 0x4c7465 | 49512 / 15 | 0 m | 0 | 0.0017 | 0 |

Offsets are into `extracted/raw/<path>.uasset`. The block offset points at the `TArray<uint8>` count before Stride. The normal difference is below one 8-bit quantisation step (1/127.5).

### Primitives (glb order = enabled cooked sections in order)

|D| is in cm. cos is against the cooked vertex normal (TangentZ). "against" = the share of vertices with cos < 0. w0 = cooked depth (Deform.w).

**walker**

| prim | section | material | glb verts | w0 | zero vecs | \|D\| p50 / max | cos p5 / p50 / p95 | against |
|---|---|---|---|---|---|---|---|---|
| 0 | 0 | MI_WalkerMaleUpperAVarB | 4114 | 0.0 | 0 | 2.67 / 8.28 | -1.00 / -0.94 / -0.51 | 0.999 |
| 1 | 1 | MI_WalkerMaleUpperClothingCVarC | 2257 | 0.0 | 0 | 2.80 / 3.85 | -1.00 / -0.96 / -0.44 | 0.993 |
| 2 | 2 | MI_WalkerMaleLowerAVarF | 1682 | 0.0 | 0 | 6.19 / 15.15 | -1.00 / -0.95 / -0.73 | 1.000 |
| 3 | 3 | MI_WalkerMaleLowerClothingGCVarB | 2905 | 0.0 | 0 | 2.78 / 4.14 | -1.00 / -0.94 / +0.65 | 0.914 |
| 4 | 4 | MI_WalkerMaleLowerAVarB | 792 | 0.0 | 0 | 4.50 / 8.26 | -0.99 / -0.77 / -0.10 | 0.958 |
| 5 | 5 | MI_WalkerMaleFeetClothingL | 1006 | 0.0 | 0 | 1.48 / 1.98 | -1.00 / -0.95 / -0.80 | 1.000 |
| 6 | 6 | MI_WalkerFemaleEyeR | 194 | 0.0 | 194 | – | – | – |
| 7 | 7 | MI_WalkerFemaleEyeL | 194 | 0.0 | 194 | – | – | – |
| 8 | 8 | MI_HumanFemaleEyeOverlay | 46 | 0.0 | 46 | – | – | – |
| 9 | 9 | MI_WalkerMaleHeadS | 1650 | 0.0 | 0 | 0.52 / 2.83 | -1.00 / -0.99 / -0.34 | 0.980 |
| 10 | 10 | MI_WalkerSkullMidFront | 4358 | 0.0 | 4358 | – | – | – |
| 11 | 11 | MI_WalkerViscera | 9383 | 0.0 | 9383 | – | – | – |
| 12 | 12 | MI_WalkerVisceraVarB | 1934 | 0.0 | 1934 | – | – | – |
| 13 | 13 | MI_WalkerViscera | 1143 | 0.0 | 1143 | – | – | – |
| 14 | 16 | MI_WalkerMaleUpperIntA | 1545 | 1.0 | 0 | 2.52 / 8.28 | +0.52 / +0.95 / +1.00 | 0.004 |
| 15 | 17 | MI_WalkerMaleLowerIntA | 240 | 1.0 | 0 | 5.95 / 15.15 | +0.68 / +0.95 / +1.00 | 0.000 |
| 16 | 18 | MI_WalkerMaleHeadIntA | 1606 | 1.0 | 0 | 0.52 / 2.83 | +0.34 / +0.99 / +1.00 | 0.021 |

**runner**

| prim | section | material | glb verts | w0 | zero vecs | \|D\| p50 / max | cos p5 / p50 / p95 | against |
|---|---|---|---|---|---|---|---|---|
| 0 | 0 | MI_RunnerFemaleEyeRVarB | 194 | 0.0 | 194 | – | – | – |
| 1 | 1 | MI_RunnerFemaleEyeLVarB | 194 | 0.0 | 194 | – | – | – |
| 2 | 2 | MI_RunnerSkullMidFront | 4383 | 0.0 | 4383 | – | – | – |
| 3 | 3 | MI_HumanFemaleEyeOverlay | 46 | 0.0 | 46 | – | – | – |
| 4 | 4 | MI_RunnerMaleHeadS | 1653 | 0.0 | 0 | 0.57 / 3.86 | -1.00 / -0.99 / -0.06 | 0.956 |
| 5 | 5 | MI_RunnerMaleLowerAVarB | 2474 | 0.0 | 0 | 5.39 / 16.03 | -0.99 / -0.93 / -0.40 | 0.987 |
| 6 | 6 | MI_RunnerMaleLowerB | 1417 | 0.0 | 0 | 2.80 / 3.65 | -1.00 / -0.95 / +0.18 | 0.934 |
| 7 | 7 | MI_RunnerMaleFeetClothingCVarB | 920 | 0.0 | 0 | 1.26 / 5.00 | -1.00 / -0.92 / +0.53 | 0.901 |
| 8 | 8 | MI_RunnerMaleUpperAVarB | 4114 | 0.0 | 0 | 2.98 / 8.72 | -1.00 / -0.95 / -0.54 | 1.000 |
| 9 | 9 | MI_RunnerMaleUpperClothingF | 1507 | 0.0 | 0 | 2.30 / 4.21 | -1.00 / -0.94 / -0.10 | 0.962 |
| 10 | 10 | MI_HumanMaleHeadSHairShellA | 336 | 0.0 | 336 | – | – | – |
| 11 | 11 | MI_HumanMaleHeadSHairA | 4175 | 0.0 | 4175 | – | – | – |
| 12 | 15 | MI_RunnerMaleHeadIntA | 1550 | 1.0 | 0 | 0.56 / 3.82 | +0.10 / +0.99 / +1.00 | 0.041 |
| 13 | 16 | MI_RunnerMaleLowerIntA | 234 | 1.0 | 0 | 6.34 / 16.03 | +0.69 / +0.97 / +1.00 | 0.000 |
| 14 | 17 | MI_RunnerMaleUpperIntA | 1527 | 1.0 | 0 | 2.87 / 8.72 | +0.58 / +0.96 / +1.00 | 0.001 |

**shambler**

| prim | section | material | glb verts | w0 | zero vecs | \|D\| p50 / max | cos p5 / p50 / p95 | against |
|---|---|---|---|---|---|---|---|---|
| 0 | 0 | MI_ShamblerMaleHeadA | 1628 | 0.0 | 0 | 1.68 / 4.08 | -1.00 / -0.95 / -0.05 | 0.958 |
| 1 | 1 | MI_HumanFemaleEyeOverlay | 46 | 0.0 | 46 | – | – | – |
| 2 | 2 | MI_ShamblerBrainMidBack | 4358 | 0.0 | 4358 | – | – | – |
| 3 | 3 | MI_ShamblerFemaleEyeR | 194 | 0.0 | 194 | – | – | – |
| 4 | 4 | MI_ShamblerFemaleEyeL | 194 | 0.0 | 194 | – | – | – |
| 5 | 5 | MI_ShamblerMaleUpperClothingF | 3289 | 0.0 | 0 | 2.98 / 4.02 | -1.00 / -0.93 / +0.81 | 0.877 |
| 6 | 6 | MI_ShamblerUpperAVarC | 4163 | 0.0 | 0 | 2.19 / 7.07 | -0.99 / -0.87 / -0.28 | 0.994 |
| 7 | 7 | MI_ShamblerMaleLowerClothingCVarC | 1476 | 0.0 | 0 | 2.84 / 4.37 | -1.00 / -0.94 / -0.10 | 0.955 |
| 8 | 8 | MI_ShamblerLowerAVarC | 2572 | 0.0 | 0 | 4.77 / 13.01 | -1.00 / -0.93 / -0.18 | 0.980 |
| 9 | 9 | MI_ShamblerMaleHeadAHairA | 1332 | 0.0 | 1332 | – | – | – |
| 10 | 13 | MI_ShamblerMaleHeadIntA | 1365 | 1.0 | 0 | 1.62 / 4.08 | +0.22 / +0.97 / +1.00 | 0.024 |
| 11 | 14 | MI_ShamblerMaleUpperIntA | 1692 | 1.0 | 0 | 1.86 / 5.73 | +0.22 / +0.77 / +0.99 | 0.011 |
| 12 | 15 | MI_ShamblerMaleLowerIntA_LandscapeBlend | 322 | 1.0 | 0 | 3.73 / 8.88 | -0.06 / +0.92 / +0.99 | 0.056 |

**thug**

| prim | section | material | glb verts | w0 | zero vecs | \|D\| p50 / max | cos p5 / p50 / p95 | against |
|---|---|---|---|---|---|---|---|---|
| 0 | 0 | MI_ThugMaleFeetClothingA | 2279 | 0.0 | 0 | 1.84 / 3.26 | -0.98 / -0.69 / +0.80 | 0.829 |
| 1 | 1 | MI_ThugMaleLowerClothingA | 2737 | 0.0 | 0 | 1.88 / 4.39 | -0.99 / -0.82 / +0.27 | 0.929 |
| 2 | 2 | MI_ThugMaleBodyA | 6100 | 0.0 | 0 | 7.63 / 17.12 | -1.00 / -0.91 / -0.43 | 0.994 |
| 3 | 3 | MI_WalkerFemaleEyeL | 354 | 0.0 | 354 | – | – | – |
| 4 | 4 | MMI_WalkerSpecialHeadViscera | 4619 | 0.0 | 4619 | – | – | – |
| 5 | 5 | MI_ThugMaleHeadA | 4209 | 0.0 | 259 | 1.50 / 10.22 | -1.00 / -0.92 / +0.11 | 0.942 |
| 6 | 6 | MI_WalkerFemaleEyeR | 354 | 0.0 | 354 | – | – | – |
| 7 | 7 | MI_HumanFemaleEyeOverlay | 112 | 0.0 | 112 | – | – | – |
| 8 | 8 | MI_ThugMaleHeadAHairTransition | 1203 | 0.0 | 1203 | – | – | – |
| 9 | 9 | MI_ThugMaleHeadAHairBottomLyr | 2000 | 0.0 | 2000 | – | – | – |
| 10 | 10 | MI_ThugMaleHeadAHairTopLyr | 3778 | 0.0 | 3778 | – | – | – |
| 11 | 11 | MI_WalkerSkeleton | 6164 | 0.0 | 6164 | – | – | – |
| 12 | 12 | MI_WalkerSpecialViscera | 10549 | 0.0 | 10549 | – | – | – |
| 13 | 13 | MI_ThugMaleBodyAInt | 1838 | 1.0 | 0 | 9.12 / 17.12 | +0.62 / +0.96 / +1.00 | 0.000 |
| 14 | 14 | MI_ThugMaleHeadAInt | 3216 | 1.0 (132 glb verts at 0.0) | 132 | 1.53 / 10.22 | +0.46 / +0.95 / +1.00 | 0.014 |

## 5. Shells and tips

| body | shell | verts | depth values | verts with exact outer twin | twin sections | live / total tris | live tris = reversed outer tri | same winding | max \|outer tip − rendered shell vertex\| |
|---|---|---|---|---|---|---|---|---|---|
| walker | MI_WalkerMaleUpperIntA | 4114 | 1.0: 4114 | 4114 | MI_WalkerMaleUpperAVarB 4114 | 2817 / 7412 | 2817 | 0 | 0.0 cm |
| walker | MI_WalkerMaleLowerIntA | 1682 | 1.0: 1682 | 1682 | MI_WalkerMaleUpperAVarB 33, MI_WalkerMaleLowerAVarF 1649 | 316 / 3090 | 316 | 0 | 0.0 cm |
| walker | MI_WalkerMaleHeadIntA | 1650 | 1.0: 1650 | 1650 | MI_WalkerMaleUpperAVarB 6, MI_WalkerMaleHeadS 1644 | 2865 / 3137 | 2865 | 0 | 0.0 cm |
| runner | MI_RunnerMaleHeadIntA | 1653 | 1.0: 1653 | 1653 | MI_RunnerMaleHeadS 1653 | 2712 / 3137 | 2712 | 0 | 0.0 cm |
| runner | MI_RunnerMaleLowerIntA | 1682 | 1.0: 1682 | 1682 | MI_RunnerMaleLowerAVarB 1682 | 290 / 3090 | 290 | 0 | 0.0 cm |
| runner | MI_RunnerMaleUpperIntA | 4114 | 1.0: 4114 | 4114 | MI_RunnerMaleUpperAVarB 4114 | 2792 / 7412 | 2792 | 0 | 0.0 cm |
| shambler | MI_ShamblerMaleHeadIntA | 1628 | 1.0: 1628 | 1628 | MI_ShamblerMaleHeadA 1628 | 2467 / 3133 | 2467 | 0 | 0.0 cm |
| shambler | MI_ShamblerMaleUpperIntA | 4163 | 1.0: 4163 | 4163 | MI_ShamblerMaleHeadA 4, MI_ShamblerUpperAVarC 4159 | 3112 / 7503 | 3112 | 0 | 0.0 cm |
| shambler | MI_ShamblerMaleLowerIntA_LandscapeBlend | 1720 | 1.0: 1720 | 1720 | MI_ShamblerUpperAVarC 40, MI_ShamblerLowerAVarC 1680 | 472 / 3166 | 472 | 0 | 0.0 cm |
| thug | MI_ThugMaleBodyAInt | 6100 | 1.0: 6100 | 6100 | MI_ThugMaleBodyA 6100 | 3283 / 10874 | 3283 | 0 | 0.0 cm |
| thug | MI_ThugMaleHeadAInt | 4209 | 0.0: 259, 1.0: 3950 | 4209 | MI_ThugMaleBodyA 60, MI_ThugMaleHeadA 4149 | 5595 / 7846 | 5595 | 0 | 0.0 cm |

Outer (skin / cloth) primitives, vertices with a non-zero vector:
- "tip on live shell": the vertex's tip is a vertex of a live shell triangle.
- "vertex→shell / \|D\|": distance from the undeformed vertex to the live shell surface, over \|D\|, for those vertices.
- The cloth columns are distances to the undeformed skin surface, in cm: p50 [p5–p95].

| body | primitive | cloth | has shell twin | tip on live shell | tip → live shell surface p50 (cm) | vertex→shell / \|D\| p50 | cloth → skin | cloth tip → skin |
|---|---|---|---|---|---|---|---|---|
| walker | MI_WalkerMaleUpperAVarB |  | 1.000 | 0.376 | 16.78 | 0.91 | – | – |
| walker | MI_WalkerMaleUpperClothingCVarC | yes | 0.000 | 0.000 | 5.48 | – | 1.48 [0.30–4.80] | 1.35 [0.12–2.57] |
| walker | MI_WalkerMaleLowerAVarF |  | 1.000 | 0.144 | 32.48 | 0.78 | – | – |
| walker | MI_WalkerMaleLowerClothingGCVarB | yes | 0.000 | 0.000 | 36.24 | – | 1.91 [0.29–4.56] | 1.02 [0.10–2.76] |
| walker | MI_WalkerMaleLowerAVarB |  | 0.021 | 0.000 | 87.94 | – | – | – |
| walker | MI_WalkerMaleFeetClothingL | yes | 0.000 | 0.000 | 87.13 | – | 1.41 [0.34–2.55] | 0.46 [0.05–1.25] |
| walker | MI_WalkerMaleHeadS |  | 1.000 | 0.973 | 0.00 | 0.97 | – | – |
| runner | MI_RunnerMaleHeadS |  | 1.000 | 0.938 | 0.00 | 0.99 | – | – |
| runner | MI_RunnerMaleLowerAVarB |  | 0.681 | 0.096 | 30.65 | 0.86 | – | – |
| runner | MI_RunnerMaleLowerB | yes | 0.000 | 0.000 | 9.94 | – | 1.73 [0.27–4.82] | 1.35 [0.12–3.23] |
| runner | MI_RunnerMaleFeetClothingCVarB | yes | 0.000 | 0.000 | 53.85 | – | 1.09 [0.10–3.18] | 0.53 [0.05–1.82] |
| runner | MI_RunnerMaleUpperAVarB |  | 1.000 | 0.372 | 18.47 | 0.94 | – | – |
| runner | MI_RunnerMaleUpperClothingF | yes | 0.000 | 0.000 | 3.83 | – | 1.44 [0.35–4.06] | 1.27 [0.12–2.67] |
| shambler | MI_ShamblerMaleHeadA |  | 1.000 | 0.839 | 0.00 | 0.98 | – | – |
| shambler | MI_ShamblerMaleUpperClothingF | yes | 0.000 | 0.000 | 1.53 | – | 2.29 [0.40–6.35] | 1.31 [0.15–3.31] |
| shambler | MI_ShamblerUpperAVarC |  | 1.000 | 0.407 | 15.83 | 0.71 | – | – |
| shambler | MI_ShamblerMaleLowerClothingCVarC | yes | 0.000 | 0.000 | 4.53 | – | 1.46 [0.16–5.60] | 1.58 [0.25–2.88] |
| shambler | MI_ShamblerLowerAVarC |  | 0.673 | 0.126 | 54.55 | 0.83 | – | – |
| thug | MI_ThugMaleFeetClothingA | yes | 0.000 | 0.000 | 101.16 | – | 2.43 [0.63–4.20] | 1.05 [0.12–2.78] |
| thug | MI_ThugMaleLowerClothingA | yes | 0.000 | 0.000 | 18.63 | – | 1.16 [0.35–5.17] | 0.65 [0.06–2.78] |
| thug | MI_ThugMaleBodyA |  | 1.000 | 0.302 | 45.54 | 0.98 | – | – |
| thug | MI_ThugMaleHeadA |  | 1.000 | 0.793 | 0.00 | 0.92 | – | – |

Masks from each mesh's `DIEngineMaterialMasks` asset user data, reading bit i as material slot i:

- **walker**: DeformationMask = MI_WalkerMaleUpperAVarB, MI_WalkerMaleUpperClothingCVarC, MI_WalkerMaleLowerAVarF, MI_WalkerMaleLowerClothingGCVarB, MI_WalkerMaleLowerAVarB, MI_WalkerMaleFeetClothingL, MI_WalkerMaleHeadS. ClothingMask = MI_WalkerMaleUpperClothingCVarC, MI_WalkerMaleLowerClothingGCVarB, MI_WalkerMaleFeetClothingL.
- **runner**: DeformationMask = MI_RunnerMaleHeadS, MI_RunnerMaleLowerAVarB, MI_RunnerMaleLowerB, MI_RunnerMaleFeetClothingCVarB, MI_RunnerMaleUpperAVarB, MI_RunnerMaleUpperClothingF. ClothingMask = MI_RunnerMaleLowerB, MI_RunnerMaleFeetClothingCVarB, MI_RunnerMaleUpperClothingF.
- **shambler**: DeformationMask = MI_ShamblerMaleHeadA, MI_ShamblerMaleUpperClothingF, MI_ShamblerUpperAVarC, MI_ShamblerMaleLowerClothingCVarC, MI_ShamblerLowerAVarC. ClothingMask = MI_ShamblerMaleUpperClothingF, MI_ShamblerMaleLowerClothingCVarC.
- **thug**: DeformationMask = MI_ThugMaleFeetClothingA, MI_ThugMaleLowerClothingA, MI_ThugMaleBodyA, MI_ThugMaleHeadA. ClothingMask = MI_ThugMaleFeetClothingA, MI_ThugMaleLowerClothingA.

What the masks show, as an inference: `ClothingMask` matches the cloth slots exactly on all four bodies, and
`RegeneratesMask` matches the skin slots. That supports reading these masks as bit = material slot. On that reading,
**`DeformationMask` (= `WriteSplatterMask`) covers skin and cloth only.** It excludes:
- the IntA shells, so the deform CS would never change their cooked depth of 1;
- eyes, skull, viscera and hair, whose vectors are zero anyway.

The exe code that consumes `DeformationMask` was **not traced**, so the claim that the CS skips masked-out sections is
unverified.

The thug's head shell is the only one with mixed depth. Its 259 depth-0 cooked vertices are exactly its 259
zero-vector vertices (132 glb vertices), so their position is the same at any depth.

## 6. Export: `game/assets/di2/<body>/<body>.deform.{bin,json}`

**`.bin`**: no header, float32 LE `(x, y, z)` per glb vertex. Primitives follow the glb's `meshes[0].primitives` order,
each primitive's vertices in its POSITION order.
- Values are already in glTF space: UE `(x, y, z)` cm → `(x, z, y) * 0.01`, the exact transform CUE4Parse applies to
  POSITION.
- The bin holds xyz only. The cooked depth is per primitive in the json (`initial_depth`, 1.0 for shells, 0.0 for
  everything else), with `initial_depth_exceptions` listing glb vertex indices whose depth differs (thug head shell
  only).

**`.json`** fields:

| Field | Contents |
|---|---|
| `primitives[]` | material, `vertex_count`, `float_offset` into the bin, cooked section / base vertex / counts, `degenerate_triangles_dropped_by_gltf`, `initial_depth*`, \|D\| and cos statistics |
| `interior_shells[]` | twin and winding checks (§5) |
| `tips_vs_shell[]` | tip coverage and distances (§5) |
| `masks_by_material_slot` | the DIEngineMaterialMasks bits, decoded by slot |
| `material_slots` | the mesh's material slot names |
| `verification` | the match numbers below |
| `ue_lod0` | block offsets and header values |

**How the glb was matched.** CUE4Parse's glTF writer (`CUE4Parse-Conversion/Writers/Gltf/Gltf.cs`) works per enabled
section. It feeds every cooked triangle, in index order, to SharpGLTF, which:
- dedups vertices with equal attributes (so glb vertex order is first-use order);
- drops degenerate triangles.

So glb triangle k of a primitive is the k-th surviving cooked triangle. The exporter walks the cooked triangles,
pairing each with the next glb triangle when the three converted positions are bit-identical. It asserts that:
- every glb triangle is paired;
- every skipped cooked triangle is degenerate;
- every glb vertex gets a cooked source.

The checks above are then run over that mapping:
- positions are bit-exact on all 131,916 glb vertices;
- UV0 is exact;
- normals are within 0.0017;
- no glb vertex merges cooked vertices with different deform values.

The degenerate triangles dropped this way are the collapsed shell triangles; this is why the glb IntA primitives have
fewer vertices and triangles than their cooked sections.

**Decoding, minimal form** (see `tools/deform/di2mesh.py` for the full walk):
```python
lod, _ = parse_lod(data, find_lod_starts(data)[0])          # walks the LOD record to lod["deform_header"]
r = Reader(data, lod["deform_header"])
assert r.i32() == 0                                          # TArray<uint8> at LOD+0x498 (empty)
stride, n = r.u32(), r.u32()                                 # 8, NumVertices
elem, count = r.i32(), r.i32()                               # 8, NumVertices (BulkSerialize)
deform = np.frombuffer(data, "<f2", count=4 * n, offset=r.p).reshape(n, 4)   # x, y, z (cm), depth
r.p += 8 * n
lod_bool_484 = r.boolean()                                   # 1; next LOD record starts here
```

Re-run with `python tools/deform/export_deform.py [walker runner shambler thug]`, about 5 minutes per body; the
point-to-triangle statistics are the slow part.

## 7. What this means for the recreation (facts only; the shader work is the main session's)

- DI2 renders every skin and cloth vertex at `P + D * depth` in **bind pose, before skinning**. `depth` starts at 0 and
  is driven by the deform CS (SHADERS_FLESH.md §4.2). The `3 / max(1, |D|)` normalisation uses |D| in **cm**, so with
  the glTF-space bin use `|D_bin| * 100`.
- **The IntA shell primitives in our glbs sit exactly on the skin.** Same positions; CUE4Parse ignores the stream.
  Their winding is reversed and their normals negated relative to the skin, so their front faces point into the body.
  DI2 draws them at `P + D` (cooked depth 1): the inside-out skin surface, |D| beneath it. That is where a skin vertex
  pushed to depth 1 lands.
- Applying the vector after skinning (as an engine that skins before the vertex shader would have to) needs the vector
  transformed by the vertex's skin matrices like a direction. DI2 itself adds it to the bind position before skinning.

## 8. Open / not established

- The bool at LOD+0x484 (1 everywhere) and the R32_UINT-view bool at DeformBuffer+0x20: no consumer found.
- The `TArray<uint8>` at LOD+0x498: empty in all 20 LODs; purpose unknown.
- The DI2 per-section 18-byte items and 2-byte tail (§3).
- **How cloth vectors were authored.** They are not copies of the skin vectors beneath, and their tips don't land on any
  mesh surface. The `def_merged` morph target (present on SK_WalkerMaleCas01 with `bStripOnCook = True`, no cooked
  data) is a plausible editor-side source of the whole stream, but this is **not proven**.
- The deform CS's use of `DeformationMask` / per-section filtering in the exe.
- The walker's two disabled `MI_WalkerSkeleton` sections index into the UpperIntA vertex range (same BaseVertexIndex
  31740), so they share its vertices and depth 1. They are not in the glbs, and their role is not established.
