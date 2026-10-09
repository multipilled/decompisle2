# DI2 FLESH shaders: decompiled from the shipping shader archives

Static analysis only of the user's own install (`C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2`), for personal use.
The game is never run. Nothing extracted is committed or shared.

This document covers:
- the Splatter plugin's GPU side: projection, render-target channels, accumulation, dilation and vertex deformation;
- the zombie character materials that read the splatter render targets (Walker skin `M_Skin`, clothing `M_Clothing`,
  the muscle "interior shell", viscera, bone, cut caps and gibs).

Every formula below is read off decompiled DXBC (3Dmigoto `cmd_Decompiler` HLSL, cross-checked against the
`fxc /dumpbin` disassembly). Names come from DI2's own data: the frozen shader maps, the material uniform expression
sets, `MPC_CharacterGameWideParams`, and the exe's string pool. CPU-side facts (how `FSplatterMeshInfo` is packed into
the shader constants, blend states, render-target formats) are **not** in the shaders. Each of those is flagged
**[CPU]** and collected in §10 for the exe session (`recon/RE_FLESH.md`).

Notation: `sat()` = saturate; `lerp(a,b,t)`; `tent(x) = 1 - |2x - 1|`;
`contrast(x,c) = sat((x - 0.5)*c + 0.5)`; `pow` is computed as `exp2(k*log2(max(1e-6,x)))`.

---------------------------------------------------------------------------------------------------------------------

## 0. Answers to recon/UNVERIFIED.md #31–#36 (summary)

| # | Question | Shader answer | Status |
|---|---|---|---|
| 31 | Progressive-damage blend | Not GPU. RE_FLESH.md "Modify" settles it on the CPU (curves summed; MaxDecal far from death). The shader side of MaxDecal is §3.6. | Resolved by exe + §3.6 |
| 32 | Stamp projection / frame | §3: box `abs(x)<1, abs(y)<1, abs(z·S.z)<1` in decal space (depth box **symmetric** about decal z = 0); `uv = xy·0.5+0.5` (+v along decal +Y, no flip); depth fade `sat(S.x·(1−min(1,abs(z·S.z))))`; angle wrap from `dot(N, decal +Z)` with two curves; radial variant. Planar projection space is skinned world (`_World`), un-skinned bind pose (`_Local`), or mesh UV (`_UV`). | Resolved in shader; matrix/scale packing **[CPU]** |
| 33 | Texture channels | Two RTs in mesh UV0 space. **DispSplatterRT:** R wound depth, G blood, B bruise, A coverage. **DiffuseSplatterRT:** R drips, G cauterisation, B fuel, A clear fluid (water). Decal RGBA × FXScale → Diffuse RT; Displacement RGB × WoundScale → Disp RT. | Resolved (RT side). Which `FSplatterMeshInfo` field feeds which scale component is **[CPU]**, but strongly indicated by the data (§8). |
| 34 | Cauterisation / Rupture / SplatterType / bSubtractive / BoneIndex | Cauterisation = Diffuse RT G: darkens up to 98%, roughness → 0.8, cauterised-flesh detail (§5.6). ApplyMin/ApplyMax element combine (min / max / add) keyed by sign bits of `ScaleVec.z/.w` (§3.6). Clear passes (§3.8, §4.2 p83). Rupture, SoftInfluence, BoneBreak and Dismember go through compute shaders (§4, §9) whose CPU inputs aren't traced. | Partly resolved |
| 35 | Wound channel per element | DI2 has **one** wound-depth channel (Disp R). Element looks come from *which textures and amounts* a preset uses: fire/shock → Diffuse G cauterisation (acid presets set CauterisationAmount 0); fuel/water status → Diffuse B/A; bruise → Disp B. No separate burn/melt/scorch channels exist in M_Skin. | Resolved |
| 36 | Defaults for unset fields | Not GPU. RE_FLESH.md lists the native FSplatterMeshInfo constructor (UVScale default **10**, not 30.149). | Resolved by exe |

---------------------------------------------------------------------------------------------------------------------

## 1. Sources, formats and how the shaders were identified

### 1.1 Files
- `DeadIsland/Content/ShaderArchive-Global-PCD3D_SM5.ushaderbytecode`: 491 shader maps, 3023 shaders.
- `DeadIsland/Content/ShaderArchive-DeadIsland-PCD3D_SM5.ushaderbytecode`: 3106 shader maps, 58530 shaders.
- `DeadIsland/Content/ShaderArchive-DeadIsland-PCD3D_SM5.ushaderresources`: DI2-specific, 2974 entries (below).
- `Engine/GlobalShaderCache-PCD3D_SM5.bin`: 492 global shader map sections.

All four come from `pakchunk_shaders` (extracted with `tools/di2x.sh raw`, then moved to `extracted/shaders/archive/`).

### 1.2 Formats (verified by parsing every byte)
- **`.ushaderbytecode`** is UE4.27 `FSerializedShaderArchive` version 2, followed by
  - an **FString compression-format name, `"Zstd"`**;
  - the code blob. Entry offsets are relative to the end of that FString, and each entry is one zstd frame.

  All 61,553 entries decode (`tools/shaders/shader_archive.py`).
- **Shader code** = UE `FBaseShaderResourceTable` header (resource-table bits; SRV, sampler, UAV and texture token maps) + a DXBC container (`ISGN`/`OSGN`/`SHEX`; **RDEF reflection stripped**) + optional data.
  - `'p'`: packed resource counts.
  - `'u'`: one uniform-buffer name per constant-buffer slot.

  These give the cbuffer and t-register names. A handful of shaders are DXIL (SM6); none of the FLESH ones are.
- **`.ushaderresources`**: `u32 2, u32 count, {SHA1, u64 offset, u32 size}[count]`, then blobs.
  - DI2 material assets don't inline their shader maps. A `MaterialInstance` with a static permutation stores a 20-byte hash (CUE4Parse reads it as `CustomGameData`), and the hash keys this table.
  - Each blob is the usual inline stream: `i32 count`, then per resource `bCooked, bValid, FMaterialShaderMapId, frozen FMaterialShaderMapContent, pointer table, bShareCode, ResourceHash`.
  - Names are FStrings and there is **no MinimalNames count** (4.25-style). See `tools/shaders/frozen.py`.
- **Frozen FShader layout (DI2)**, worked out from the data:
  - DI2 replaces `TMemoryImageArray` inside `FShader` with a single 8-byte pointer to `{u16 count, items}`.
  - `+0x80` Type, `+0x88` VFType (TIndexedPtr: `index<<1|1` into the pointer table), `+0x90` Target (bits 0-3 = frequency), `+0x94` ResourceIndex, `+0x98` NumInstructions.
  - **Checked on all 587,179 material shaders and all 4,327 global shaders:** every ResourceIndex lands on an archive shader of the same frequency, and every Type field equals the map's ShaderTypes entry.
  - CUE4Parse's own DI2 FShader reader returns garbage for these fields, which is why `frozen.py` exists.

### 1.3 Names
- Shader type names come from the exe's string pool (UTF-16, `tools/shaders/exe_strings.py`), hashed as FHashedName = `CityHash64WithSeed(UPPER(name), 0)` (CUE4Parse's rule, `shadermaps.exe hash`). 1223 of 1251 global type hashes resolve.
- The Splatter global shader sections are `/Engine/Private/DS/Internal/SplatterComputeShader.usf` and `.../SplatterPixelShader.usf`. The material shaders' source is `.../SplatterVertexShader.usf` (exe strings).
- **Uniform buffer `SplatterData` = `FSplatterBatchParameters`.** The exe lists its members in this order: `DecalMatrix, SafeRegionMatrix, ScaleVec, WoundScale, FXScale, RangeParams`. With 16-element arrays that is 64+64+16+16+16+16 float4 = 192, which matches the 16-element PS exactly; the 1-element PS uses cb0[0..176]. Element *i* reads `cb0[4i..4i+3]`, `cb0[64+4i..]`, `cb0[128+i]`, `cb0[144+i]`, `cb0[160+i]`, `cb0[176+i]`, so the order is fixed by the code.
- **Material constants.** In DI2's `Material` uniform buffer the **virtual-texture uniforms come first** (7 float4 here), then `VectorExpressions[]`, then `ScalarExpressions[]` packed 4 per float4.
  - Each slot's parameter comes from the uniform expression set's preshader programs, decoded in `tools/shaders/annotate.py`.
  - The opcode numbers are inferred from argument sizes and stack balance: 2 Constant, 3 ScalarParameter, 4 VectorParameter, 6 Sub, 7 Mul, 8 Div, 35 ComponentSwizzle, 36 AppendVector. The unary 20/22/24 aren't needed by FLESH.
  - The layout was checked against usage: noise speeds × `View.GameTime`, `Detail Tiling` × UV, `(1.5W − EpidermisBlendStart)/(End − Start)`.
- **MaterialCollection0 = `MPC_CharacterGameWideParams`** (StateId `DF8AB2E2-4D459C16-2DE80E9B-51C88CA5`). Its 103 scalars are packed 4 per float4 in asset order, then its 9 vectors. The values below are the asset defaults. **[CPU]**: code or Blueprints may override MPC values at runtime.

### 1.4 Shader identification (archive index → output hash)

| Shader | Archive / index | Out hash (SHA1) |
|---|---|---|
| FSplatterPS_OneElement | DeadIsland 1900 | 244b7ccae31fa23d9428039be06f9933718d7a37 |
| FSplatterPS_OneElement_Radial | DeadIsland 1943 | 9fd8ce6dbf9a40d969b0cbdfec4f37f23250053d |
| FSplatterPS_TwoElement / _Radial | DeadIsland 1902 / 1916 | 2885381b… / 4f90a283… |
| FSplatterPS_FourElement / Eight / Sixteen | DeadIsland 1923 / 1908 / 1901 | 63187a5f… / 3b9ef784… / 25dfe475… |
| FSplatterVS_World (TGPUSkinVertexFactoryDefault, Walker skin) | DeadIsland 1959 | cb63e8debbb15ff61ed65f72351be7858816b077 |
| FSplatterVS_Local / FSplatterVS_UV (GPUSkin Default) | DeadIsland 1947 / 1919 | a9ebe436… / 57d135be… |
| FSplatterClearPS | Global 1877 | 9121c794c6eabf100577828eaed8eab0cc1c5ce5 |
| FSplatterDilatePS_H / _V | Global 1874 / 1875 | 106e1bc6… / 30e41c8c… |
| FSplatterDilateCS | Global 1876 | 8b32bdb1… (0 instructions, empty stub) |
| FSplatterDeformMeshCS p80 (1 decal, skinned world) | Global 936 | c3ec0083… |
| FSplatterDeformMeshCS p81 / p82 / p83 / p84 | Global 884 / 926 / 885 / 881 | ref-pose planar / ref-pose radial / clear / planar |
| FSplatterGeometryCS_FourBone | Global 903 | 48b467e3… |
| Walker skin base pass PS / VS (MI_WalkerMaleUpperA[VarB], High, GPUSkin Default) | DeadIsland 3213 / 3184 | b4cd2a4a… / 4850e7e6… |
| Walker clothing base pass PS / VS (MI_WalkerMaleUpperClothingCVarC) | DeadIsland 3410 / 3368 | e6903cef… / 3654595c… |
| Walker interior shell PS / VS (MI_WalkerMaleUpperIntA) | DeadIsland 3094 / 3070 | d5303480… / 8f41d41e… |

- The FSplatterPS_* code is **one shader per type across all 355 `bUsedWithSplatter` materials** (×3 quality levels = 1065 maps), so the projection is material-independent.
- FSplatterVS_World has up to 29 variants per vertex factory, presumably material-dependent vertex code. The Walker's has none: plain skinning only.
- Decompiled files: `extracted/shaders/dis/<lib>_<index>_<label>.{hlsl,asm,meta.json}`. Annotated material shaders: `extracted/shaders/annotated/*.hlsl` and `*.slots.txt`.

---------------------------------------------------------------------------------------------------------------------

## 2. Pipeline overview (what runs on the GPU)

1. **Projection / RT write.** `FSplatterVS_{World|Local|UV}` + `FSplatterPS_{One|Two|Four|Eight|Sixteen}Element[_Radial]` draw the **whole mesh section in UV0 space** into two render targets with MRT:
   - **SV_Target0 = DiffuseSplatterRT** (`DiffuseSplatterRT_%s_%s_%s_PIE_%d`);
   - **SV_Target1 = DispSplatterRT** (`DispSplatterRT_...`).

   One draw applies a batch of up to 16 decals. These are mesh *material* shaders (VF-specific vertex fetch); the material only selects the VS vertex code.
2. **Vertex deformation.** `FSplatterDeformMeshCS` runs one thread per triangle over the mesh's vertex buffers. It applies the same batch's displacement textures to each **vertex** and accumulates a per-vertex depth (half float) in the deform buffer, which the character's vertex shader reads as `ATTRIBUTE16` (§4).
3. **Clear.** `FSplatterClearPS` (RT) and the CLEAR permutation of `FSplatterDeformMeshCS` (vertex depth).
4. **Dilation.** `FSplatterDilatePS_H` then `_V` (scratch RTs `DilationScratchRT_%dx%d_%d`) grow coverage across UV seams.
5. **Dismemberment / geometry.** `FSplatterGeometryCS_FourBone[_TwoUV]`, `FSplatterGeometryIndicesCS_FourBone`, `FSplatterConsolidate*CS`, `FSplatterBreakCS`, `FSplatterCopyIndicesCS` rebuild cut geometry (copying positions, tangents, UVs, skin and deform streams). Not decoded in detail here (§9).
6. **Character material.** `M_Skin` / `M_Clothing` sample `SplatterDisplace` (= DispSplatterRT) and `SplatterDiffuse` (= DiffuseSplatterRT) at **UV0** and shade wounds, blood, bruise, drips, cauterisation and major cuts (§5–§7).

---------------------------------------------------------------------------------------------------------------------

## 3. Projection: FSplatterVS / FSplatterPS

### 3.1 Vertex shaders (rasterise into UV space)

All three variants output the same clip position:
```hlsl
// DeadIsland 1947/1919/1959 (FSplatterVS_*), v8 = ATTRIBUTE5 = UV0
r0.xy = frac(v8.xy); r0.z = 1 - r0.y;
o2.xy = r0.xz * 2 - 1;  o2.zw = (0,1);           // SV_Position: texel (u, v) of UV0, wrapped by frac()
p1    = max(1, length(v5.xyz));                  // DEFORM0, v5 = ATTRIBUTE16 (DI2 deform stream, §4)
```
They differ in the position passed to the PS (`TEXCOORD0`, the space the `DecalMatrix` maps from) and the normal (`TEXCOORD1`):

| Variant | TEXCOORD0 (projection position) | TEXCOORD1 (normal for AngleWrap) |
|---|---|---|
| `FSplatterVS_World` | Skinned position (4 bone matrices from `t0`, plus 2 DI2 "soft" influences from `t1` weighted by `ATTRIBUTE12.xy * .z`, indices `ATTRIBUTE11`) → `Primitive.LocalToWorld` → **absolute world** (adds then subtracts `View.PreViewTranslation`), w = 1 | Skinned `ATTRIBUTE2` (TangentZ) → LocalToWorld 3×3, **not normalised** |
| `FSplatterVS_Local` | **Un-skinned bind-pose position** `ATTRIBUTE0` (mesh/component space), w = 1. This is the `bReferencePose` path (exe permutation define `REFERENCE_POSE`). | Un-skinned `ATTRIBUTE2` |
| `FSplatterVS_UV` | `(UV0 * 2 - 1, 0, 0)`: **UV space** (`bUVSpaceSplatter`, define `UV_SPACE`) | `(0,0,1)` |

Which variant a stamp uses is chosen by the CPU **[CPU]** (`bReferencePose`, `bUVSpaceSplatter`, otherwise World).

### 3.2 FSplatterBatchParameters (`SplatterData`, cb0), per element *i* (0..15)

| Member | cbuffer | Use in the PS |
|---|---|---|
| `DecalMatrix[i]` (float4x4, row-vector) | cb0[4i .. 4i+3] | `L = P.x·M[0] + P.y·M[1] + P.z·M[2] + M[3]` (P = TEXCOORD0) |
| `SafeRegionMatrix[i]` | cb0[64+4i ..] | radial variant only: the radial frame (§3.5) |
| `ScaleVec[i]` | cb0[128+i] | **x** depth-fade gain; **y** displacement amplitude in the deform CS (§4); **\|z\|** depth scale, **sign(z)<0** = ApplyMin; **\|w\|** AngleWrap, **sign(w)<0** = ApplyMax |
| `WoundScale[i]` | cb0[144+i] | xyz scale the displacement texture's RGB; **w>0** enables `×3/max(1,length(deform))` on R |
| `FXScale[i]` | cb0[160+i] | xyzw scale the diffuse (decal) texture's RGBA |
| `RangeParams[i]` | cb0[176+i] | x = input minimum, y = input range: `t = (tex − x) / y` on every channel |

Textures and samplers, confirmed from the frozen bindings: the derived shader holds two `FShaderResourceParameter[16]` arrays (t0..t15, then t16..t31; for N elements t0..tN−1 and tN..t2N−1), declared in the exe's order `DecalTexture_%d`, `DisplacementTexture_%d`. Samplers: `s0 = DecalTextureSampler`, `s1 = DisplacementTextureSampler`.
- **DecalTexture (= FSplatterMeshInfo.DiffuseDecalTexture)** is sampled RGBA, scaled by FXScale and written to SV_Target0.
- **DisplacementTexture (= DisplacementDecalTexture)** is sampled RGB, scaled by WoundScale and written to SV_Target1.

### 3.3 Planar element (DeadIsland 1900, FSplatterPS_OneElement, complete)
```hlsl
r0.xyz = cb0[1].xyz*v0.yyy + v0.xxx*cb0[0].xyz + v0.zzz*cb0[2].xyz + cb0[3].xyz;   // L = P * DecalMatrix
r0.w   = abs(cb0[128].z) * r0.z;                                                   // z' = L.z * |S.z|
inside = all(abs(float3(L.x, L.y, z')) < 1);
if (inside) {
  uv    = saturate(L.xy * 0.5 + 0.5);
  fade  = saturate(cb0[128].x - min(1,abs(z')) * cb0[128].x);                      // S.x * (1 - min(1,|z'|))
  k     = abs(cb0[128].w) * float3(2,4,4) - 1;                                     // a = |S.w| (AngleWrap)
  f     = dot(v1.xyz, float3(cb0[0].z, cb0[1].z, cb0[2].z)) * 0.5 + 0.5;          // N . (DecalMatrix column z)
  wrap  = saturate((f + k.xzz) / (1 - max(0, -k)));                                // (wR, wGB, wGB)
  D = (t0.Sample(s0, uv) - cb0[176].x) / cb0[176].y;                               // DecalTexture RGBA
  W = (t1.Sample(s1, uv).xyz - cb0[176].x) / cb0[176].y;                           // DisplacementTexture RGB
  D = cb0[160] * D * fade * wGB;                                                   // FXScale
  W = cb0[144].xyz * W * fade * float3(wR, wGB, wGB);                              // WoundScale
  if (cb0[144].w > 0) W.x *= 3 / DEFORM0;                                          // DEFORM0 = max(1,|deform.xyz|)
  o0 = D;  o1 = float4(W, 1);
  if (cb0[128].z < 0) { o0 = min(0,o0); o1 = min(0,o1); }                          // ApplyMin: negative only
  if (cb0[128].w < 0) { o0 = max(0,D);  o1 = max(0,float4(W,1)); }                 // ApplyMax: positive only (wins)
} else { o0 = 0; o1 = 0; }
```
In plain terms:
- **Box.** In decal space the stamp covers `−1<x<1`, `−1<y<1` and `−1 < z·|S.z| < 1`. Both the depth box and the depth fade are **symmetric about decal z = 0**. Where z = 0 lies relative to the impact point (`DecalMatrix` translation) is **[CPU]**. If it is the impact point, the recreation's `[−4 cm, DepthScale]` box is not DI2's.
- **UV.** `u = x/2 + 0.5`, `v = y/2 + 0.5`. Image +u runs along decal +X, image +v (down the image) along decal **+Y**. There is no flip. Bilinear, clamp-to-edge via `saturate` (**[CPU]** sampler state).
- **Depth fade.** `fade = sat(S.x · (1 − min(1, |z·S.z|)))`. It is linear in |depth|, symmetric front and back, and a stamp with `S.x ≤ 1` never reaches full strength except at the plane.
  - If the CPU sets `S.x = 1/(1 − DepthFadeStart)`, this gives full strength for `|z′| ≤ DepthFadeStart` and a linear fall to 0 at the box face. DepthFadeStart = 1 (252 data entries) then means no fade.
  - That encoding is **[CPU]**; the shader formula is exact.
- **Angle wrap.** `f = ½ + ½·dot(N, Zcol)`, where `Zcol = (M00.z, M10.z, M20.z)`, the input-space direction that increases decal Z. N is the VS normal in the projection's own space: world (World VS), bind pose (Local VS) or (0,0,1) (UV VS).
  - The normal isn't normalised, and neither is Zcol (an un-normalised normal enters `f` as-is). With `a = |S.w|`:
    - `wR  = sat((f + 2a − 1) / (1 − max(0, 1 − 2a)))`: wound depth;
    - `wGB = sat((f + 4a − 1) / (1 − max(0, 1 − 4a)))`: blood, bruise and **all four diffuse channels**.
  - For a ≥ 0.5 (resp. 0.25) the curve is `sat(f + 2a − 1)`, which reaches 1 everywhere once a ≥ 1 (AngleWrap 1, 1.12, 100 in the data = no angular limit). For smaller a it ramps linearly from `f = 1 − 2a` to `f = 1`.
  - The wound therefore wraps half as far round the body as the blood and bruise.
  - Orientation constraint: the data has AngleWrap 0.25 / 0.39 / 0.5 stamps, which only show on the struck face if that face has `f ≈ 1`. So **decal +Z must point out of the surface, against the projection direction.** How Orient's rotation (RE_FLESH.md) becomes `DecalMatrix` is **[CPU]** (SplatterDecal).
- **Input remap.** `(tex − RangeParams.x) / RangeParams.y` on all seven channels. RangeParams is almost certainly `(InputMinimum, InputRange)`: same role, defaults 0/1, and 3 data entries use 0.3/0.2 and 0.45. **[CPU]**
- **Deform normalisation.** If `WoundScale.w > 0`, wound R is multiplied by `3 / max(1, |Deform.xyz|)`, where Deform.xyz is the vertex's DI2 deform vector (§4). This matches `bAbsoluteDeformation` (default true) in spirit. **[CPU]**
- **Coverage.** SV_Target1.a = 1 wherever a non-subtractive element's box covers the texel. Dilation keys off this (§3.7). The material never samples DispSplatterRT.a.

### 3.4 Multi-element batches (Two / Four / Eight / Sixteen)
Element 0 is computed exactly as in §3.3. Each further element *i* is computed unclamped and folded in:
```hlsl
acc.rgba = (S_i.z < 0) ? min(acc, e_i) : acc + e_i;     // ApplyMin: strongest subtraction wins, else ADD
acc.rgba = (S_i.w < 0) ? max(acc, e_i) : acc;           // ApplyMax: largest wins (takes precedence)
```
This applies to both targets. Each element's wound alpha is 1, so in add mode acc.w counts the covering elements. In min mode alpha stays acc.w in the 2-element shader and becomes min(acc.w, 1) in the 16-element one.

### 3.5 Radial element (`_Radial`, DeadIsland 1943)
```hlsl
y   = dot(P, DecalMatrix col y) + M[3].y;                         // axial coordinate
q   = (dot(P, SR col y) + SR[3].y,  dot(P, SR col z) + SR[3].z);  // SR = SafeRegionMatrix[i], radial plane
r   = length(q);
w   = (|y| < 1) * (1 - sat(4 * (r - 1)));                        // full inside r ≤ 1, fades to 0 at r = 1.25
uv  = sat(float2(q.y / r, y) * 0.5 + 0.5);                       // u = sine/cosine of the angle round the axis
```
There is **no depth fade and no angle wrap**: `w` replaces both. Remap, scales, the deform factor and sign modes are as in §3.3. It is a cylindrical wrap round an axis, so `ScaleVec.x` and `|S.w|` are unused here **[CPU]**: which effects use radial.

### 3.6 SplatterType ↔ shader modes
RE_FLESH.md: `ESplatterType` Decal 1, ApplyMin 16, MinDecal 17, ApplyMax 32, MaxDecal 33, and Modify turns `Decal` into `MaxDecal` while far from death.
- The shader has exactly two sign flags: `ScaleVec.z < 0` (**min**) and `ScaleVec.w < 0` (**max**). These match the ApplyMin/ApplyMax bits.
- **[CPU]** what remains: (a) that ApplyMin → sign(z) and ApplyMax → sign(w); (b) the RT blend state per batch. A MaxDecal batch has "max-blend" semantics across hits only if the RTs use a MAX blend for it, because the PS only maxes among the elements of one batch. Conversely, min-mode outputs (≤ 0) only have an effect under an ADD blend (subtraction). So the only consistent states are **ADD for Decal/ApplyMin and MAX for ApplyMax**; confirm in the exe.
- `bSubtractive` (261 data entries) and `bInvertSplatter` (4) have no shader flag of their own. They must be encoded in signs or values on the CPU (e.g. negative scales, `1 − t` via RangeParams) **[CPU]**.

### 3.7 Dilation (Global 1874 `FSplatterDilatePS_H`, 1875 `_V`)
Inputs: `t0 = DilationTarget0` (the RT whose **alpha = coverage**, i.e. DispSplatterRT, see §3.3) and `t1 = DilationTarget1` (the other RT). One texel per pass, point loads.
```hlsl
c0 = t0[p]; c1 = t1[p];
if (c0.a == 1) { o0 = (c0.rgb, 1); o1 = c1; return; }           // covered texel: unchanged
for n in (p - 1texel, p + 1texel)    // H: ±x, V: ±y, left/up first then right/down
    if (c0.a < t0[n].a) { c0 = t0[n] * sign(t0[n].a); c1 = t1[n] * sign(t0[n].a); }
o0.rgb = c0.rgb;  o1 = c1;
o0.a = H ? (c0.a > 0 ? 0.5 : 0) : 0;
```
In plain terms: H then V gives a one-texel 3×3 grow of both RTs from covered texels (alpha 1) into empty ones. Pulled texels are marked 0.5 after H (so V can propagate them) and 0 after V. The number of H+V iterations and the scratch RT sizes are **[CPU]**. `FSplatterDilateCS` is an empty 0-instruction stub.

### 3.8 RT clear (Global 1877 `FSplatterClearPS`)
`o0 = saturate(1 − cb0[0])` (cb0[0] is the loose `c_ClearMask` / `ClearMaskParameter`). Writing `1 − mask` only clears if the blend state multiplies: `dst · src` keeps the channels with mask 0 and zeroes those with mask 1 **[CPU]**.

---------------------------------------------------------------------------------------------------------------------

## 4. Vertex deformation (FSplatterDeformMeshCS + the character VS)

### 4.1 The deform stream (`ATTRIBUTE16`)
DI2's skin vertex factories (all of them: GPUSkin Default/Extra and Morph) carry an extra **half4 per vertex**: `Deform = (xyz, depth)`.
- `xyz` is a per-vertex displacement vector.
- `depth` is the accumulated wound depth in [0,1].

The base pass, depth, shadow and velocity VS all apply it **before skinning**. From the Walker skin base VS (DeadIsland 3184):
```hlsl
P = ATTRIBUTE0.xyz + ATTRIBUTE16.xyz * ATTRIBUTE16.w + ATTRIBUTE9.xyz;   // ATTRIBUTE9 = morph delta (Morph VFs)
... skin P with the 4 bones (t0) + 2 soft influences (t1) ...
TEXCOORD1.xy, TEXCOORD2.x = (ATTRIBUTE0 + Deform.xyz*Deform.w).xyz     // bind-pose position for 3D noise
TEXCOORD2.y               = Deform.w                                    // depth -> material "vertex gradient"
TEXCOORD3.y               = saturate(Color.g + (Deform.w >= 0.001))     // section visibility (§5.8)
COLOR0                    = ATTRIBUTE13 (vertex colour)
```
So the **mesh is pushed along `Deform.xyz` by `depth`** (bind-pose units). Where `Deform.xyz` comes from is **unresolved**.
- The deform CS only ever rewrites the depth half and keeps xyz.
- The geometry CS copies the stream into cut geometry.
- Its initial value comes from the mesh's own deform vertex buffer (`DeformBufferSRV` in the CS parameter list), a DI2 custom skeletal-mesh stream that CUE4Parse doesn't decode (RECON.md: "UV1–7 come out as zeros").

### 4.2 Depth accumulation (Global 936, `FSplatterDeformMeshCS` p80: 1 decal, skinned world)
One thread per triangle. An atomic stamp (`InterlockedExchange` against `cb0[217].w`) processes each vertex once per pass. Per vertex:
```hlsl
pos, n   = skinned (4 or 8 bones) bind position / TangentZ -> c_LocalToWorldMatrix (cb0[8..11])
L        = pos * DecalMatrix[i] (cb0[24+4i]);  z' = L.z*|S.z|;  inside = |L.x|,|L.y|,|z'| < 1
fade     = sat(S.x*(1-min(1,|z'|)))
wrap     = sat((dot(n, Zcol)*0.5 + 0.5 + 2a - 1) / (1 - max(0, 1-2a)))           // same as the PS's wR
t        = DisplacementTexture[i].Load(uv * size, mip 0).r                          // POINT sample, R only
v        = ((t - Range.x)/Range.y) * S.y * fade * wrap * inside
if (DeformParams.x > 0 && Deform != 0)    v *= 3 / max(1, |Deform.xyz|)         // DeformParams = cb0[168+i]; any half != 0
v = (S.z < 0) ? (DeformParams.y < 0 ? 1 - v : v)  :  DeformParams.y * v
s = v / 0.9
depth = (S.w < 0) ? sat(max(s, depth)) : (S.z < 0) ? sat(min(s, depth)) : sat(depth + s)
store Deform.zw = (z unchanged, f16(depth))
```
- `cb0` here is the CS's loose `$Globals`.
- `S = c_ScaleVecArray` at cb0[152+i]: the same roles as the PS's ScaleVec, so it's the same CPU packing.
- `Range` = cb0[184+i]: used exactly like RangeParams.
- `c_ClearValueArray` = cb0[200+i].
- `DeformParams` = cb0[168+i]: **x>0** enables the deform normalisation; **y** is a signed multiplier, and in min mode **y<0** selects `1 − v`.
- Edge case: when the whole deform half4 is 0, the CS uses factor 1, while the PS always uses `3/max(1,|xyz|)` = 3.

The vertex depth takes the **same max/min/add modes** as the RT, scaled by `1/0.9`. It uses **only the displacement texture's R**, point-sampled at mip 0 at the vertex's UV.

Permutations (each 5-wide group is repeated for batch sizes 16/8/4/2/1 → 22/14/10/8/7 SRVs):

| Permutation | Behaviour |
|---|---|
| p80 | Skinned world planar |
| p81 | Bind-pose (REFERENCE_POSE) planar |
| p82 | Bind-pose radial: radial frame from `c_SafeRegionMatrixArray` (cb0[88+4i]); no wrap, no deform normalisation |
| p83 | **CLEAR**: `depth = c_ClearValueArray[i].x`, i.e. ClearToValue / DisplacementClearValue **[CPU]** |
| p84 | Another planar variant |

The second group of 10 (one UAV) is presumably the soft-body (`APPLY_TO_SOFT_BODY`) set; not decoded.

---------------------------------------------------------------------------------------------------------------------

## 5. Walker skin: M_Skin

Chain: `MI_WalkerMaleUpperA[VarB]` → `MMI_WalkerMaleUpper` → `MMI_WalkerSkin` → `MMI_ZombieSkin` → **`M_Skin`**.
- Static switches: Enable Splatter, Enable Zombie Veins Effect, Enable Cheap Zombie Veins Effect.
- UpperA, UpperAVarB and MMI_ZombieSkin share shader map `8BA14C21…`.
- Shader: DeadIsland 3213 (PS, High), 3184 (VS); annotated copy in `extracted/shaders/annotated/`.

### 5.1 Inputs
- `UV = TEXCOORD0` (UV0, the same atlas the splatter VS rasterises).
- `VC = COLOR0` (vertex colour). **VC.r = "detail mask"**: it lerps blood, cauterisation and bruise detail, and drip flattening. **VC.g = visibility** (§5.8).
- `Pb` = bind-pose position, deformed (TEXCOORD1.xy, TEXCOORD2.x), used for 3D noise.
- `dv` = Deform.w (TEXCOORD2.y).
- Splatter samples: `Disp = SplatterDisplace.rgb`, `Dif = SplatterDiffuse.rgba`, both at UV0 with `s0` = `View.MaterialTextureBilinearWrapedSampler`. The height-normal taps on Disp.r use the texture's own sampler (`Material.Texture2D_4Sampler`) with `SampleBias(View.MaterialTextureMipBias)`. Every sample's exact sampler is in `game/data/flesh_materials.json` (§13).

Textures (Walker values):

| Slot | Texture |
|---|---|
| Wound Gradient Map | **T_GoreGradWalker** (MMI_WalkerSkin) |
| Inner Diffuse / Inner Normal | T_RunnerMaleUpperIntA_D / _N (MMI_WalkerMaleUpper) |
| Blood Drip Map | T_RunnerMaleUpperA_Drip_D |
| constants | T_SkinSplatterWoundNoise_N/_H, T_SkinBloodSplatterDetail_A, T_SkinBloodSplatterDetail_ReduceNoise_N, T_CauterizedFlesh_A/_N, T_Bruise_D, TV_Global3dNoise |

Material scalars (resolved through the chain; M_Skin default when no instance sets it):

| Parameter | Value |
|---|---|
| 03 - Epidermis Map Tiling | 32 |
| 02 - Blood Splatter Map Tiling | 1.75 |
| 02 - Blood Drip Map Tiling | 1 |
| 07 - Cauterization Map Tiling | 2.25 |
| 01 - Bruise Map Tiling | 6 |
| 05 - Bruise Desaturation | 0.5 |
| Inner Desaturation | 0.25 |
| inner Roughness | 0.22 |
| Splatter Opacity Offset | 0 |
| Blood Colour | (0.8, 0.502, 0.48) |
| 06 - Bruise Colour Tint | (1,1,1) |
| inner Colour Tint | (1,1,1) |
| BloodMapUVOffset | (1.4, 0.4) |

`BloodMapUVOffset` and `LargeNoiseRandomOffset` look per-instance; whether a dynamic instance overrides them is **[CPU]**.

MPC (`MPC_CharacterGameWideParams` defaults; names abbreviated `ChrSplatter*` → `*`):

| Parameter | Value |
|---|---|
| StandardWoundGradScale | 1.5 |
| DeformationNormalStrength | 6 |
| DeformationNormalJitter | 0.007 |
| EpidermisBlendStart / End | 0.1 / 0.18 |
| MeatManGradientPower | 20 |
| BloodDetailNormalBlendThresh | 3 |
| BloodEdgeContrast | 1.2 |
| BloodMaxCoverage | 0.8 |
| BloodDensity | 12 |
| BruiseIntensity | 1 |
| BloodDetailMaskStrength | 1.5 |
| SkinEdgeShift | 0.12 |
| SkinEdgeContrast | 4 |
| SkinEdgeFattyNoiseContribution | −1 |
| SkinEdgeEpidermisNoiseContribution | −0.7 |
| WoundDetailNormalsContribution | 1 |
| BloodInWoundFade | 1.5 |
| BloodRoughness | 0.15 |
| CauterizationDetailStrength | 1.2 |
| CauterizationEdgeContrast | 1.6 |
| CauterizationMaxDarkening | 0.98 |
| MaxCauterization | 0.75 |
| CauterizationRoughness | 0.8 |
| CauterizationWoundFalloff | 0.4 |
| BloodDripDetailStrength | 1 |
| BloodDripEdgeContrast | 1.7 |
| BloodDripMaxCoverage | 1 |
| MajorCutAlphaGradStart / End | 0.9 / 1.0 |
| MajorCutAlphaRaggedness | 10 |
| VertexGradientPower | 3 |
| VertexGradientAmount | 1 |
| VolTexTiling | 3.7 |
| VolTexNrmStrength | 0.1 |
| VolTexNrmSampleDist | 0.03 |
| VolTexMult | 1 |
| VolTexOffset | −0.18 |
| ChrFuelSplatterColour | (0.6025, 0.6461, 0.6927) |

### 5.2 Wound value and layer masks
```
W      = max(Disp.r, VertexGradientAmount * sat(dv)^VertexGradientPower)    // dv^3: vertex depth also opens wounds
g      = StandardWoundGradScale * W                                         // 1.5 W
inner  = (g > 0.5)                                                          // hard switch to the inner (muscle) maps
e      = sat((g - EpidermisBlendStart) / (max(Start,End) - Start))          // sat((1.5W - 0.1)/0.08)
T      = tent(g)                                                            // 1 - |3W - 1|, peaks at W = 1/3
nV     = sat(VolTexMult * Vol(Pb/VolTexTiling).w + VolTexOffset)            // 3D noise, 0..1
nH     = T_SkinSplatterWoundNoise_H(UV * EpidermisTiling).g
open   = contrast(sat(sat(g + T*(nV-0.5)*SkinEdgeFattyNoise - T*(nH-0.5)*SkinEdgeEpidermisNoise) / SkinEdgeShift), SkinEdgeContrast)
```
`open` is the "skin is split" mask: with the defaults it reaches 1 at about `1.5W ≥ 0.12` (plus noise).

### 5.3 Gore gradient (skin → fat → muscle → bone)
```
inner_d = lerp(InnerDiffuse, luminance(InnerDiffuse), InnerDesaturation)                  // lum = (.3,.59,.11)
U       = sat( (1 - sat(innerTint.g * inner_d.g))^MeatManGradientPower * lerp(nH, nV, e) )
V       = g = 1.5 W                                                                        // sampler from View (clamp)
G       = WoundGradientMap(U, V)                                                           // RGBA
```
V is wound depth; U picks meat (dark green in the inner map → (1−g)^20 ≈ 1) versus fat/tendon (bright → U ≈ 0), modulated by noise.

### 5.4 Base colour
```
C = skin colour (diffuse × tint × vein tint, unchanged from the unwounded material)
C *= lerp(1, bruiseCol, bruiseAmt)
     bruiseCol = lerp(BruiseTint*(0.557292,0.142254,0.139323), desat(T_Bruise_D(UV*BruiseTiling), BruiseDesat)*BruiseTint, VC.r)
     bruiseAmt = lerp(BruiseIntensity*Disp.b*nS, BruiseIntensity*Disp.b, VC.r)   // nS = 1-(1-n.y)(1-n.x) (3D noise screen)
C  = lerp(C, innerTint*inner_d, inner)
C  = lerp(C, G.rgb, G.a * open)
-- fluids --
fb = sat(1e-5 + Disp.g);  s = fb + Dif.a + Dif.b
mixC = (fb/s)*BloodColour + (Dif.a/s)*(1,1,1) + (Dif.b/s)*ChrFuelSplatterColour
mixC = lerp(mixC, BloodColour, drip)                                             // drip from §5.5
C *= min(1, mixC ^ (BloodDensity * blood))                                       // Beer-Lambert style absorption
C *= 1 - caut * CauterizationMaxDarkening
```
(Frost, landscape blend and Fury tint follow; they aren't FLESH.)

### 5.5 Blood, drips and wetness
```
B     = min(BloodMaxCoverage, sat(Dif.a + Disp.g + Dif.b))                     // blood + clear fluid + fuel
dB    = T_SkinBloodSplatterDetail_A((UV + BloodMapUVOffset.xy) * BloodSplatterTiling).g
blood = contrast(sat(tent(B)*(dB-0.5)*BloodDetailMaskStrength*VC.r + B), BloodEdgeContrast) * lerp(nS, dB, VC.r)
dR    = min(BloodDripMaxCoverage, Dif.r);  dm = BloodDripMap(UV*DripTiling)
drip  = dm.r * contrast(sat(tent(dR)*(dm.g-0.5)*BloodDripDetailStrength + dR), BloodDripEdgeContrast)
blood = max(blood, drip) * (max(1e-6, 1 - g))^BloodInWoundFade                // blood fades out inside deep wounds
wet   = sat(BloodDetailNormalBlendThresh * blood)
```

### 5.6 Cauterisation (Diffuse RT G)
```
c0   = min(MaxCauterization, Dif.g) * (max(1e-6, 1 - g))^CauterizationWoundFalloff
dc   = lerp(nS, (T_CauterizedFlesh_A(UV*CautTiling).g - 0.5)*CauterizationDetailStrength, VC.r)
caut = contrast(sat(tent(c0)*dc + c0), CauterizationEdgeContrast)
```

### 5.7 Normals and roughness (tangent space, UE "BlendAngleCorrectedNormals" = RNM)
- Base normal → `lerp(·, InnerNormal, inner)`.
- **Wound normal:**
  - **Height normal from Disp.r:** `normalize(S·(h(u+j) − h(u−j)), S·(h(v+j) − h(v−j)), 2)` with `S = DeformationNormalStrength` (6) and `j = DeformationNormalJitter` (0.007 UV), sampled with the Texture2D_4 sampler.
  - **Detail normal:** `lerp(T_SkinSplatterWoundNoise_N(UV·EpidermisTiling), volumetric-noise normal from TV_Global3dNoise, e)`, RNM onto the inner normal, then scaled toward flat by `WoundDetailNormalsContribution`.
  - The wound normal is the RNM of the height normal and the detail normal.

  `N = lerp(N, woundN, G.a·open)`.
- **Blood normal:** `T_SkinBloodSplatterDetail_ReduceNoise_N`, flattened by `0.5·drip` and by `1 − VC.r`. `N = lerp(N, bloodN, wet·(1 − open))`.
- **Cauterisation normal:** `lerp(lerp(volN, flat, 0.4), T_CauterizedFlesh_N, VC.r)`. `N = lerp(N, cautN, caut·(1 − open))`.
- **Roughness:** base → Vein Roughness by vein mask → `inner Roughness` (0.22) by `inner` → `inner Roughness` by `G.a·open` → **BloodRoughness 0.15** by `wet` → **CauterizationRoughness 0.8** by `caut` (then frost and landscape).

### 5.8 Opacity (masked, clip 0.1): the "major cut"
```
a     = sat((W - MajorCutAlphaGradStart) / (max(Start,End) - Start))          // 0 at W <= 0.9, 1 at W >= 1
rag   = MajorCutAlphaRaggedness * (InnerNormal.x + InnerNormal.y)              // unpacked inner normal xy
keep  = sat(1 - a - tent(a)*(1 + rag))
alpha = sat(SplatterOpacityOffset + keep) * ATA.x * sat(VC.g + (dv >= 0.001)) [* LOD dither]
clip(alpha - 0.1)
```
So the **outer skin disappears where W ≥ ~0.95** (ragged), revealing the separate inner meshes. VC.g is a per-vertex visibility mask that deformation overrides. On the Walker, skin sections have VC.g mostly 1 (`MI_WalkerMaleLowerAVarB` mean 0.16); inner and viscera sections have 1 (read from `extracted/mesh/.../SK_WalkerMaleCas01.glb` COLOR_0).

---------------------------------------------------------------------------------------------------------------------

## 6. Walker clothing: M_Clothing (MI_WalkerMaleUpperClothingCVarC → MMI_WalkerMaleClothing → MMI_WalkerClothing → M_Clothing; PS 3410)

- Reads **SplatterDiffuse.gba only**: the drip input is a constant `min(0, BloodDripMaxCoverage) = 0`, so **no drips on clothing**. It also reads SplatterDisplace.rgb.
- **Cauterisation:** as skin, but the wound term is the constant `0.3^0.4`, i.e. `c0 = min(0.75, Dif.g)·exp2(−1.737·0.4)`.
- **Blood:**
  ```
  b = Disp.g^ClothingBloodPow(1) + ClothingTearScale(5)*Disp.r
  b += cav * b^ClothingBloodCavityPower(1)
  B = min(0.8, sat(b + Dif.a + Dif.b))
  ```
  Here `cav = sat(ClothingCavityNormalsContribution(3)·(1 − |n.z|/|n|))` from the cloth normal map. B then takes the same tent / detail / contrast steps as skin, with T_FabricSplatterDetail_A and ClothingDetailMaskStrength 0.5.
- **Colour mix:** as skin, with two differences: the blood fraction uses `fb = sat(1e-5 + b)` (b from the line above, tear and cavity included) instead of Disp.g, and the clear-fluid term is `lerp(1, base, ChrSplatterWetClothingDarkening 0.15)·(Dif.a/s)` instead of white.
- **Tear (opacity):**
  ```
  tear = sat(5*Disp.r - Disp.b)
  K    = sat((1 - tear) + tent(tear)*(T_FabricTearDetail_A(UV*FabricTearTiling).r - 0.5)*ClothingTearDetailStrength(5) - tent*cav)
  alpha = ATA.x * (1 - RipAmount*(1 - K))
  ```
  **Wound depth tears cloth holes**; bruise reduces tearing.
- **Roughness:** ClothingBloodRoughness 0.25 by wet, CauterizationRoughness 0.8 by caut.
- **The splatter PS is the same code on cloth and skin sections.** Clothing-only parameters (`ClothingDisplacementScale`, `ClothingDepthScale`, `ClothingInteraction` ClothOnly/ClothNever) must therefore act on the CPU: per-section scales or section filtering via `SplatterClothingGroupMask` / `SplatterGroupMask` / `WriteSplatterMask` **[CPU]**.

## 7. Interior shell, viscera, bone, caps, gibs

- **Interior (muscle) shell** `MI_WalkerMaleUpperIntA` (M_Skin with "Interior Shell Material"; PS 3094):
  - Samples SplatterDisplace.r only.
  - Has the **same major-cut opacity** as §5.8 with `W = max(0, Disp.r)` (no vertex-gradient term) and its own `Splatter Opacity Offset` (0).
  - So when the RT wound depth reaches ~0.95, both the skin and the interior shell at those UVs are cut away, exposing viscera and bone. Visibility factor `sat(VC.g + (dv ≥ 0.001))`, and VC.g = 1 on IntA sections.
  - Otherwise unlit-by-splatter: inner diffuse and normal, frost.
  - Whether the shell shares the skin's RT pair or has its own group RT is **[CPU]** (`Group_%d`, `SplatterGroupMask`).
- **Viscera** (`MI_WalkerViscera` → MI_RunnerViscera → MMI_ZombieViscera → MMI_Viscera → M_Skin) and **bone** (`MI_WalkerSkeleton`): permutations of M_Skin with **no splatter textures** (plain PBR: Diffuse, Normal, MRO, ATA, detail).
- **Cut caps** `MI_Breakage` (SM_BreakageA–E) uses **M_Clothing's default permutation**: Normal, MRO, ATA, Diffuse only. **No splatter.**
- **Gibs** `MI_BloodGibs` (M_Opaque): no splatter.

---------------------------------------------------------------------------------------------------------------------

### 7.1 Eyes and hair also read the splatter RTs (found while building §13)

The full eye materials are in §14; this subsection only covers their splatter use.

All of these sample at **UV1** (`TEXCOORD1.xy` = `ATTRIBUTE6`; checked in VS 3741, 4133 and 4083), so their UV1 maps
into the body's splatter atlas.

- **Eye** `M_EyeRefractive` (MI_*EyeL/R; PS 3791):
  ```
  D = SplatterDisplace.rgb (UV1)
  E = min(ChrSplatterEyeBloodMaxCoverage 0.6, max(D.r, D.g, D.b))
  n = T_SkinBloodSplatterDetail_A(0.5*(UV0 + 0.2*(D.r + D.g - D.b))).r
  E = sat(tent(E)*(n - 0.5)*ChrSplatterEyeBloodDetailStrength 1.5 + E)
  colour *= min(1, BloodColour^(ChrSplatterBloodDensity 12 * E))      // the eye MI's own 'Blood Colour'
  ```
- **Eye occlusion overlay** `M_EyeOcclusion` (MI_HumanFemaleEyeOverlay; PS 4166): opacity `*= 1 − sat(ChrSplatterEyeOverlayRemovalScale 60 · SplatterDisplace.r)`.
- **Hair** `M_Hair` (head hair cards and shells; PS 4056):
  ```
  f = sat(Disp.g + Dif.a + Dif.b) + ChrSplatterHairRemovalScale 2 * Disp.r      (UV1)
  colour *= min(1, mix^(12*f))       // mix as skin: blood fraction -> 'Blood Colour', Dif.a -> white, Dif.b -> fuel
  alpha  *= 1 - sat(2 * Disp.r)      // wounds remove hair
  ```
  `sat(f)` also drives the wet look.
- **Splatter path identical across permutations.** The other skin permutations (PS 3569, the lower-body sections) and clothing permutations (PS 3813, 4130, 3479) use exactly the same `ChrSplatter*` MPC set and FLESH textures as 3213 and 3410. Their differences are non-FLESH: veins, landscape blend. This was compared by parameter and texture usage, not instruction by instruction.

## 8. Render-target channel table

| RT.channel | Meaning in M_Skin / M_Clothing | Written by | FSplatterMeshInfo field (indicated **[CPU]**) |
|---|---|---|---|
| Disp.r | **Wound depth**: gore gradient V, skin split, inner switch, major cut, height normal; cloth: blood + tear | DisplacementTexture.r × WoundScale.x (× 3/\|deform\|) | DisplacementScale (0 on paint-only presets; the wound textures carry R) |
| Disp.g | **Blood** (BloodColour) | DisplacementTexture.g × WoundScale.y | FluidSplatterAmount |
| Disp.b | **Bruise**; cloth: reduces tearing | DisplacementTexture.b × WoundScale.z | BruisingAmount (blunt presets 2.0; Wound textures have B) |
| Disp.a | coverage for dilation (not read by materials) | 1 | none |
| Dif.r | **Drips** (skin only), lerped to BloodColour | DecalTexture.r × FXScale.x | FluidDripsAmount (drip-only presets: Drip_01_FX R only, FluidDrips 2.5/15, everything else 0) |
| Dif.g | **Cauterisation** | DecalTexture.g × FXScale.y | CauterisationAmount (Fire/Shock presets keep 1 on G-bearing textures; Acid presets set 0 on the *same* textures; Burning status: G-only texture, Cauterisation 1.5–2) |
| Dif.b | **Fuel** (ChrFuelSplatterColour), counts as fluid coverage | DecalTexture.b × FXScale.z | **TextureInfluence** (RE_FLESH.md: FXScale.z = TI). Consistent: T_FuelImpact01_FX_A R+B on `CE_StatusEffect_Flammable` has FluidSplatter 0, FluidDrips 0 |
| Dif.a | **Clear fluid / water**: white in the absorption mix (skin), wet-darkened (cloth), counts as fluid coverage | DecalTexture.a × FXScale.w | **TextureInfluence** (FXScale.w = TI), as for Dif.b |

The previous reading in flesh.gdshader ("diffuse G = blood smear", "displacement R → per-element wound channel") is superseded. Diffuse G is cauterisation, and blood comes from **Disp.G plus Dif.A and Dif.B**.

---------------------------------------------------------------------------------------------------------------------

## 9. Not decoded here (explicit)

- Splatter compute shaders other than DeformMeshCS. `FSplatterGeometryCS_FourBone[_TwoUV]` (1900 instructions), `FSplatterGeometryIndicesCS_FourBone`, `FSplatterConsolidate*CS`, `FSplatterBreakCS` and `FSplatterCopyIndicesCS` are dismemberment / bone-break mesh editing with safe-region and bone-end planes (`c_SafeRegionMatrix`, `c_TargetBoneData`, `c_BinaryDismember`, `c_UseTrim`). Decompiled HLSL is in `extracted/shaders/dis/Global_*`; not analysed.
- The soft-body path (`SoftPosition`, `SoftAxis`, `SoftRadius`, `SoftInfluence`, `SoftFade`, `SoftNumVolumes`, `APPLY_TO_SOFT_BODY`) and the Rupture parameters: CPU-driven, not reached here.
- Low/Medium quality permutations: only High was read. Same structure expected; not verified.
- Other archetypes (Runner/Shambler/Thug skins, `MMI_SplatterableHumanSkin`): same M_Skin master. Their MI chains choose the gradient textures (e.g. Thug → T_GoreGradWalker per RECON.md), but their parameter overrides weren't dumped.

## 10. Open [CPU] questions for the exe session (RE_FLESH.md "SplatterDecal")

**Update 2026-10-08:** questions 1–6 are answered in `recon/RE_FLESH.md` "Batch packing".
- DecalMatrix rows: (Orient Y, −Orient Z, −Orient X, location); rows 0/1 scaled by UVScale/2; inverted.
- ScaleVec = (1/clamp(1−DepthFadeStart, 1e-4, 1), DisplacementScale, ±1/DepthScale with − for ApplyMin, ±clamp(AngleWrap, 0, 1) with − for ApplyMax).
- WoundScale = (Disp·TI, Fluid·TI, Bruise·TI, bAbsoluteDeformation ? TI : 0); FXScale = (Drips·TI, Caut·TI, TI, TI); RangeParams = (InputMinimum, InputRange); DeformParams = (bAbsoluteDeformation, bSubtractive ? −1 : 1).

This matches every reading in §3–§4 and §8; FXScale.b/.a (fuel / water) are simply TextureInfluence. Still open from this list: the blend state per batch, RT formats, dilation iterations, and the initial per-vertex Deform.xyz.

1. **DecalMatrix construction.** How Orient's rotation, UVScale, DepthScale and the impact location become `DecalMatrix`, and `ScaleVec.z`.
   - Which rotation axis maps to decal Z: §3.3 requires decal +Z to point **out of** the surface for AngleWrap < 0.5 to work.
   - The half-extent units: is `|x| < 1` at UVScale/2 cm?
2. **ScaleVec packing:** `.x` (fade gain; is it `1/(1−DepthFadeStart)`?), `.y` (deform amplitude, from DisplacementScale/DepthScale?), `|.z|`, `|.w|` = AngleWrap, and the **sign flags** (ApplyMin → z<0, ApplyMax → w<0?).
3. **WoundScale / FXScale component sources** (table §8), TextureInfluence's role, the Clothing* scales, and **bSubtractive / bInvertSplatter** encoding.
4. **RangeParams** = (InputMinimum, InputRange)?
5. **Blend state per batch type** (ADD vs MAX; and the clear's multiply), **RT formats** (UNORM8? saturation), RT size per mesh/group (`r.Splatter.TextureReduction`), dilation pass count.
6. **DeformParams.x/y** source (bAbsoluteDeformation? sign for subtractive?).
7. Initial **Deform.xyz** per vertex (mesh deform buffer), and whether `bReferencePose`/`bUVSpaceSplatter` select the Local/UV VS.

---------------------------------------------------------------------------------------------------------------------

## 11. Concrete changes proposed for the recreation (main session owns these files)

### 11.1 game/shaders/flesh.gdshader
1. **Replace the analytic multi-channel wound model with DI2's two RTs.**
   - Either bake stamps into two UV0-space textures per body (closest to DI2: accumulate, saturate, dilate, persist; Godot: a SubViewport rendering the mesh with `VERTEX = vec3(UV*2−1, 0)` and the stamp math below, plus a dilation pass),
   - or, as a minimal step, keep per-fragment evaluation but output the same 8 values: `Disp = (wound, blood, bruise, cov)` and `Dif = (drips, caut, fuel, water)`.

   Drop `cut/crush/burn/melt/scorch` and `fields()`'s channel switch from the stamp path (#35).
2. **stamps() projection (§3.3):**
   - box `abs(x)<1 && abs(y)<1 && abs(z*zs)<1` with `x, y` = decal coordinates normalised to ±1. The depth box is **symmetric about decal z = 0**: replace the `−0.04 .. DepthScale` test, keeping the origin at the impact point until the exe session confirms the matrix translation (§10.1).
   - `uv = vec2(x, y)*0.5 + 0.5` with no v flip relative to the decal +Y axis.
   - `fade = clamp(sx*(1.0 − min(1.0, abs(z*zs))), 0, 1)` (replace the smoothstep).
   - `f = dot(N, zaxis)*0.5 + 0.5` with zaxis = decal +Z pointing **out** of the surface, then
     `wR = clamp((f + 2a − 1)/(1 − max(0, 1 − 2a)), 0, 1)` and `wGB` the same with 4a. Apply wR to wound depth only, wGB to everything else. Replace the `smoothstep(th ± 0.15)` test.
   - Input remap `(tex − InputMinimum)/InputRange` on every channel.
   - Channels: `Dif += DecalTex.rgba * FXScale * fade * wGB` and `Disp.rgb += DispTex.rgb * WoundScale * fade * (wR, wGB, wGB)`.
   - Element combine: add, or min/max per §3.4 / §3.6.
3. **Radial stamps** (§3.5) need their own path if any preset uses them **[CPU]**: which ones.
4. **Shading:** port §5 (skin) and §6 (cloth) literally.
   - Inputs: W, `inner` switch at 1.5W > 0.5, `e`, `open`, gore gradient sampled at `(U, 1.5W)` with clamp, bruise multiply, fluid mix `(blood, white, fuel)` and absorption `mixC^(12·blood)`, cauterisation darkening 0.98, roughness targets 0.15 / 0.8 / 0.22, and the RNM normal blends.
   - Import `MPC_CharacterGameWideParams` values as constants (§5.1).
   - Needs DI2 textures not yet exported: T_SkinSplatterWoundNoise_N/_H, T_SkinBloodSplatterDetail_A/_ReduceNoise_N, T_CauterizedFlesh_A/_N, T_Bruise_D (exists as `bruise_tex`?), TV_Global3dNoise (3D), T_FabricSplatterDetail_A, T_FabricTearDetail_A, per-body Inner Diffuse/Normal and Blood Drip Map.
   - The existing `gore_gradient` use (`texture(gore_gradient, vec2(noise, depth))`) becomes the exact `(U, 1.5W)`.
5. **Major cut instead of `flesh > 0.9 → discard`:** use §5.8's `keep` / `alpha` with clip 0.1 on skin. The interior shell (layer muscle) uses the same formula with `W = Disp.r`. Remove the recreation's "inner anatomy only where a wound reveals it" discard for layers 2–4: DI2 draws them always and hides the **outer** layers instead.
6. **Vertex displacement:** `VERTEX += deform_xyz * depth` (bind pose, before skinning), with depth accumulated per vertex as in §4.2. This replaces `VERTEX -= NORMAL * (crush*0.02 + ...)` and the stamp `disp` push. It needs per-vertex deform vectors from DI2's mesh data (unresolved, §4.1); until then keep the current push and flag it.
7. Cut caps / viscera / bone / gibs: plain PBR in DI2 (§7). The cap layer (8) shouldn't receive splatter shading at all; the current `cap` branch's wound tinting has no DI2 counterpart.

### 11.2 game/scripts/flesh.gd
1. `params_for()`: pass `InputMinimum`, `InputRange`, `TextureInfluence`, `bSubtractive`, `bInvertSplatter`, `bAbsoluteDeformation`, `bReferencePose`, `bUVSpaceSplatter` and the `SplatterType` bits (ApplyMin 16 / ApplyMax 32; Modify's MaxDecal) to the stamp. Pack `fluid → Disp.G scale`, `bruise → Disp.B`, `drips → Dif.R`, `cauterise → Dif.G` (§8), and `displacement → Disp.R` / deform amplitude. Keep the exact packing flagged until the exe session confirms it (§10.2–10.3).
2. Remove `channel_for()` (#35): element looks come from textures and amounts already in the preset data. `CauterisationAmount` **is** used (Diffuse G); acid presets zero it.
3. `apply_set()`: `ClearToValue` / `ClearSplatter` map to the clear passes (§3.8, §4.2 p83) instead of being skipped. `MaxDecal` / `MinDecal` map to the max/min modes, not to "skip" (#34).
4. Frame (`orient()` / `frame()`): the shader needs decal +Z = out of the surface, decal +X/+Y = image u/v, and half-extents at |x|, |y| = 1. Reconcile with RE_FLESH.md's Orient once SplatterDecal's matrix build is traced (§10.1).

---------------------------------------------------------------------------------------------------------------------

## 12. Reproduce

```
tools/di2x.sh raw 'ShaderArchive-|GlobalShaderCache-PCD3D'      # then move into extracted/shaders/archive/
python tools/shaders/shader_archive.py extracted/shaders/archive/ShaderArchive-Global-PCD3D_SM5.ushaderbytecode extracted/shaders/Global
python tools/shaders/shader_archive.py extracted/shaders/archive/ShaderArchive-DeadIsland-PCD3D_SM5.ushaderbytecode extracted/shaders/DeadIsland
python tools/shaders/exe_strings.py <exe> <regex>                # name candidates -> extracted/shaders/name_candidates.txt
tools/shaders/shadermaps/bin/out/shadermaps.exe hash extracted/shaders/name_candidates.txt extracted/shaders/name_hashes.tsv
tools/shaders/shadermaps/bin/out/shadermaps.exe material <ushaderresources> <names> extracted/shaders/materials '<asset regex>'
python tools/shaders/material_map.py <MI shader hash> [type regex]   # VF/type -> archive index
python tools/shaders/decompile.py DeadIsland <index> <label>         # fxc /dumpbin + 3Dmigoto cmd_Decompiler 1.3.16
python tools/shaders/annotate.py <material json> 1 DeadIsland <index> <master json>
```
- Python: miniconda (`zstandard`).
- Global shader sections: `frozen.global_cache()` / `global_shaders()`.
- cmd_Decompiler comes from the official 3Dmigoto GitHub release 1.3.16 (`tools/shaders/bin`).
- fxc is from the Windows SDK 10.0.22621.

---------------------------------------------------------------------------------------------------------------------

## 13. FLESH material data for the port (`game/data/flesh_materials.json`, `game/assets/di2/flesh/`)

Built by `tools/shaders/build_flesh_materials.py` (miniconda python; it runs `tools/shaders/shadermaps`, `tools/di2x`
(json, for missing asset dumps) and a generated CUE4Parse texture dumper in `extracted/shaders/flesh_build/`).

**74 entries:**
- **58 mesh sections** of SK_WalkerMaleCas01, SK_RunnerMaleCas01, SK_ShamMaleCas01 and SK_ThugA01, from the meshes' `SkeletalMaterials`.
- **15 spawn-time material variants** (`"variant_of": <source section>`): each body's `CharacterInitialStateWrapper.MaterialVariants`, the same data as `game/data/character_states.json`. Identity substitutions are skipped.
- **1 attachment material** (`"attachment": "AttachmentSpec_WalkerMaleHatAVarC"`): `MI_WalkerMaleHatClothingA` on static mesh SM_WalkerMaleHatAVarC, socket `head`, slot `T_WalkerMaleHatClothingA`. The spec has no material overrides.
  - Its base pass is the FLocalVertexFactory one (PS 3814): M_Clothing's splatter permutation, sampling the splatter RTs at UV0.
  - Whether the hat gets its own splatter render targets (it is a separate static mesh actor, `BP_StaticMeshAttachment`) is decided by the Blueprint and native code. **[CPU]**

All variants are M_Clothing clothing permutations (PS 3410 / 3813 / 3479 / 4130), the same splatter path as §6.

### 13.1 Resolution rules
- **Chain:** MI → Parent → … → UMaterial.
- **Value of a parameter:** the first instance in the chain (leaf first) that overrides it; otherwise the master default stored in the effective shader map's uniform expression set (`DefaultValue`; textures: `TextureIndex` → master `ReferencedTextures`). The JSON records which (`source`).
- **Effective shader map:** the first chain entry with a static-permutation shader map; otherwise the master's.
- **`used`:** whether the permutation's uniform expression set contains the parameter. Parameters the port asked for are always listed; unused ones carry the chain override or `null`.
- **`render`:** BlendMode, TwoSided, OpacityMaskClipValue and ShadingModel. For each, the first instance (leaf first) whose `BasePropertyOverrides` sets `bOverride_<X>`, else the master's property, else the UE4.27 UMaterial default (`source: "UE default"`: Opaque, one-sided, 0.3333, DefaultLit). Cooked instances copy inherited values into their struct; only the `bOverride_*` flags say which are their own.
- **`pack_layer`:** the bodies' `materials.json` layer. Variants take their source section's layer (`pack_layer_source`). The attachment's `cloth` is derived from kind `clothing`, and its `pack_layer_source` says so.
- **`kind`:**
  - `skin`: M_Skin, samples SplatterDisplace and SplatterDiffuse (§5);
  - `interior_shell`: M_Skin with static switch "Interior Shell Material", samples SplatterDisplace only (§7);
  - `clothing`: M_Clothing (§6);
  - `other_splatter`: eyes and hair (§7.1);
  - `none`: viscera, skull, bone. Their masters have `bUsedWithSplatter`, but the permutation samples no splatter texture.

### 13.2 Samplers (how to sample each texture in the port)
Every texture parameter of a non-`none` section has `samples: [{op, sampler}]`, read from the decompiled High-quality
`TBasePassPSFNoLightMapPolicy` (GPUSkin Default) through the shader resource table.

| sampler name in the JSON | what it is | port setting |
|---|---|---|
| `View.MaterialTextureBilinearWrapedSampler` | View UB resource 0: the shared material sampler | repeat, linear + mipmaps |
| `View.MaterialTextureBilinearClampedSampler` | View UB resource 1 | **clamp**, linear + mipmaps |
| `Material.Texture2D_<n>Sampler` / `Material.VolumeTexture_0Sampler` | the texture asset's own sampler | the texture's `address` (all `TA_Wrap` here) and `filter` (`TF_Default` = texture-group default) |
| `Material.Wrap_WorldGroupSettings` | material shared sampler | repeat |

- **Identifying View res0/res1.** Resource-table token `0x0` / `0x101` are `s0` / `s1`. `t0` = View res2 is read as `Texture3D<uint4>` with `Load` (VolumetricLightmapIndirectionTexture), which places the two material samplers at res0/res1 as in UE4.27's `FViewUniformShaderParameters`. Their states (bilinear wrap / clamp) are the engine's, not verified in DI2's exe.
- **sRGB is a texture property, not a sampler one:** use `textures[name].srgb` (`source_color` in Godot).
  - sRGB: inner diffuse maps, the gore gradients, T_Bruise_D.
  - Linear: all `TC_Masks`, `TC_Normalmap`, drip maps and TV_Global3dNoise.
- `SampleBias` uses `View.MaterialTextureMipBias` (0 at default settings).
- Note: the **Wound Gradient Map is sampled with the clamped View sampler** although its asset says wrap (V = 1.5·wound exceeds 1).
- `tools/shaders/decompile.srt()` (and so `annotate.py`'s `.slots.txt`) skips token `0x0`, so `s0` is missing there. The build script has the correct parser.

### 13.3 Textures
Fields: `textures.<name>`: `role` (`flesh` | `base_map`), `png` (res:// path, or null), `extracted_png` (base maps already in extracted/), `asset`, `class`, `width`, `height`, `png_layout`, `pixel_format` (as cooked), `srgb`, `address`, `filter`, `lod_group`, `compression`.

- **Base maps** (Diffuse Colour Map, Normal Map, Packed MRO, Packed ATA) are listed for **every** entry (`used` says whether the permutation samples them).
  - If a PNG of that name exists under `extracted/mesh` or `extracted/tex` (where `tools/pack_materials.py` looks them up by name), the entry has `extracted_png` and `png: null`; those PNGs come from the earlier CUE4Parse mesh/texture exports.
  - Otherwise they are exported here, raw like the FLESH textures: 37 of 148 (variant outfits and a few skin maps).
- Metadata (sRGB, address, compression) is filled for every texture either way.

- **PNG contents:** CUE4Parse's decode of the first (largest) cooked mip, written by PIL with **channels untouched** (RGBA kept unassociated; checked: T_GoreGradWalker keeps RGB where A = 0). Native size, no resize.
  - BC5 normal maps have B reconstructed by the decoder; the material only uses RG (`xy*2−1`, `z = sqrt(1−x²−y²)`).
  - DXT1 masks carry A = 1.
  - A float texture would be written as an uncompressed half-float `.exr`; no FLESH texture is float.
- **TV_Global3dNoise** (VolumeTexture 128³, B8G8R8A8 uncompressed, linear, `TC_VectorDisplacementmap`, address wrap) is a **2D atlas 128 wide × 16384 high**. Slice z occupies rows `[128z, 128z+128)`; channels as stored (RGBA). The skin samples it at `bindPosition / ChrSplatterVolTexTiling` with trilinear wrap (`.w` → nV, `.x/.y` → nS, §5.2), and for veins and frost with its own sampler.
- **Exported (40):**
  - FLESH constants: T_SkinSplatterWoundNoise_N/_H, T_SkinBloodSplatterDetail_A/_ReduceNoise_N, T_CauterizedFlesh_A/_N, T_Bruise_D, T_FabricSplatterDetail_A, T_FabricTearDetail_A, T_SkinBloodDrips_A, TV_Global3dNoise.
  - Gore gradients: T_GoreGradWalker/Runner/Shambler.
  - The default RT placeholders: T_BlackMaskAlpha_A, T_BlackMask_A.
  - Every section's Inner Diffuse/Normal and Blood Drip Map.
  - Eye and hair sections use only shared textures for their splatter path, so their own maps aren't exported.

### 13.4 JSON schema
```
{
 "_about": str,
 "samplers": {sampler name: description},
 "materials": {                                   // keyed by material (section) name
   "<MI name>": {
     "asset": "/Game/...MI.0", "bodies": [body,...], "in_materials_json": [body,...], "pack_layer": str|null,
     "variant_of"?: source section name, "pack_layer_source"?: str,                    // spawn-time variants
     "attachment"?: spec name, "attachment_mesh"?: mesh, "attachment_socket"?: socket, "vertex_factory"?: str,
     "render": {"BlendMode"|"TwoSided"|"OpacityMaskClipValue"|"ShadingModel": {"value": ..., "source": str}},
     "chain": [leaf, ..., master], "master": "M_Skin"|"M_Clothing"|"M_Hair"|..., "used_with_splatter": bool,
     "static_switches": {name: bool}, "shader_map": {"owner": chain entry, "resource_hash": hex|null},
     "samples_splatter": ["SplatterDiffuse"?, "SplatterDisplace"?],
     "kind": "skin"|"interior_shell"|"clothing"|"other_splatter"|"none",
     "base_pass_ps": {"archive": "DeadIsland", "index": int, "vertex_factory": str},   // non-"none" only
     "splatter_uv": {"interpolators": ["TEXCOORD0.xy"], "uv_channel": [0|1]},
     "params": {
       "scalars":  {name: {"value": float|null, "source": str|null, "used": bool}},
       "vectors":  {name: {"value": [r,g,b,a]|null, "source": ..., "used": ...}},
       "textures": {name: {"value": texture name|null, "source": ..., "used": ..., "slot": "Texture2D_<n>",
                           "samples": [{"op": "Sample"|"SampleBias"|"SampleLevel", "sampler": name}]}}
     }                                             // unnamed material constants are keyed "const <texture name>"
   }
 },
 "textures": {name: {"role", "png"|null, "extracted_png"?, ...§13.3}},
 "mpc": {"MPC_CharacterGameWideParams": {"scalars": {name: value}, "vectors": {name: [r,g,b,a]}}}
}
```

---------------------------------------------------------------------------------------------------------------------

## 14. Eyes: M_EyeRefractive and M_EyeOcclusion

Zombie eyes are two sections on the body mesh:
- the **eyeball** (`MI_*EyeL/R` → `M_EyeRefractive`): Masked, clip 0.3333, **MSM_Eye**, one-sided;
- the **occlusion overlay** (`MI_HumanFemaleEyeOverlay` → `M_EyeOcclusion`): **Translucent**, **Unlit**, one-sided.

The Thug uses the Walker's eye MIs. Decompiled:
- eyeball: PS DeadIsland 3791 (`B107C25F…` shader map, High, GPUSkin Default), VS 3741;
- overlay: PS 4166 (`28B99C82…`), VS 4133.

Annotated copies are in `extracted/shaders/annotated/DeadIsland_003791_*`, `*_004166_*` and `*_003741_*`. Slots resolve exactly as in §1.3 (no virtual-texture block in these materials: `VectorExpressions` start at `cb4[0]`).

### 14.1 Inputs (eyeball)
- `UV` = TEXCOORD0.xy = **UV0** (ATTRIBUTE5): every eye map.
- `UVs` = TEXCOORD1.xy = **UV1**: the splatter RT only.
- TEXCOORD2.xy + TEXCOORD3.x = bind position + deform (`ATTRIBUTE0 + Deform.xyz·Deform.w`, like the skin): frost noise only. TEXCOORD3.y = frost amount.
- `V` = normalize(camera − pixel), the unit vector to the camera.
- Tangent frame `T, B, Nv` = the vertex tangent basis; B = cross(Nv, T)·sign.
- The vertex shader has no world-position offset; position is skinned `ATTRIBUTE0 + Deform.xyz·Deform.w`.

Samplers:

| Texture | Sampler |
|---|---|
| `NormalMap` (T_EyeWet_N), `ScleraColor`, `IrisColor` | **View clamped sampler** (`s1`) |
| `T_Eye_N`, `T_EyeMidPlaneDisplacement_Example` | their own samplers (wrap) with `SampleBias(View.MaterialTextureMipBias)` |
| SplatterDisplace, T_SkinBloodSplatterDetail_A | View wrap sampler |

### 14.2 Iris coordinates and masks
```
R      = 0.16                                       // iris UV radius: a compiled-in constant (not a parameter)
S      = IrisScale * (1 + ChrIrisShrinkFixAmount * sat((SV_Position.w - ChrIrisShrinkFixOffset) / ChrIrisShrinkFixLength))
                                                    // MPC defaults: amount 0 -> S = IrisScale
irisUV = (UV - 0.5) / S + 0.5
d      = length(irisUV - 0.5)
maskC  = smoothstep01(sat(1 - (d - (R - LimbusUVWidthColor))   / LimbusUVWidthColor))     // x*x*(3-2x)
maskS  = smoothstep01(sat(1 - (d - (R - LimbusUVWidthShading)) / LimbusUVWidthShading))
```
Both masks are 1 inside `d ≤ R − width` and 0 outside `d ≥ R`. `maskC` drives colour, roughness, the refraction offset and normal flattening; `maskS` becomes the GBuffer **IrisMask**.

### 14.3 Normals
```
Nw  = unpack(T_EyeWet_N(UV))                         // xy*2-1, z = sqrt(1 - x²- y²)
f   = lerp(FlattenNormal, 1, maskC)
Nt  = lerp(Nw, (0,0,1), f)                            // wet normal flattened, fully flat on the iris
Nt  = lerp(Nt, frostNormal, frost)                    // frost only (Freeze Amount, MPC frost params)
N   = normalize(Nt.x*T + Nt.y*B + Nt.z*Nv)            // written to the GBuffer normal (o1 = N*0.5+0.5)
Ne  = unpack(T_Eye_N(UV)) -> E = normalize(Ne.x*T + Ne.y*B + Ne.z*Nv)   // "eye direction": the iris-plane normal
```
`E` is the **IrisNormal**: octahedral-encoded into GBuffer CustomData.yz (`UnitVectorToOctahedron(E)*0.5+0.5`).

### 14.4 Refraction through the cornea and the iris depth offset
```
eta  = 1.00029 / LensIoR
c    = dot(N, V)
k    = 1 - eta²(1 - c²)
Rd   = normalize((eta*c - sqrt(k)) * N - eta * V)    // refracted view ray (into the eye)
h0   = T_EyeMidPlaneDisplacement_Example(0.5 + R*IrisScale, 0.5).r       // depth at the limbus
h    = max(0, T_EyeMidPlaneDisplacement_Example(UV).rgb - h0) * IrisDepth   // R=G=B in the texture
off  = -Rd * h / (0.325 + 0.675 * dot(V, E)²)
T'   = normalize(T - dot(T, E) * E)                    // vertex tangent made orthogonal to E
B'   = cross(T', E)
irisUVr = irisUV + maskC * float2(-R * dot(T', off), R * dot(B', off))
```
In plain terms: the iris is a plane recessed under the cornea by `IrisDepth × (mid-plane height − limbus height)`. The view ray is refracted at the wet surface, and the iris texture is looked up where that ray meets the plane. That gives parallax, scaled by `1/(0.325 + 0.675·cos²)` toward grazing angles.

### 14.5 Pupil, iris colour, limbus, sclera
```
c0    = (irisUVr - 0.5) / (2R)                           // 3.125 = 1/(2*0.16): iris edge at |c0| = 0.5
L     = length(c0)
p     = sat(PupilSize * (1 - 2L))
c1    = (c0 / L) * 0.5 * (1 - p)                          // radius remapped to 0.5*(1-p): r' = 0.5(1-P) + P*L for P <= 1
iris  = IrisColor(0.5 + c1).rgb * (AggressiveIris * AggressiveEyesColor(MPC 1.5,0.719,0.691) + IrisBrightness)
iris *= 1 - min(1, length(LimbusDarkening * c1))^LimbusDarkeningFalloff
sclera = lerp(1, ScleraColor(UV).rgb, Veins) * ScleraBrightness
col   = lerp(sclera, iris, maskC)
```
At `LimbusDarkening = 0` (Walker, Shambler) the limbus factor is 1. The iris texture covers the iris disk only: its radius 0.5 is the limbus.

### 14.6 Blood (splatter) in the eye
```
D   = SplatterDisplace(UVs).rgb
Eb  = min(ChrSplatterEyeBloodMaxCoverage 0.6, max(D.r, D.g, D.b))
n   = T_SkinBloodSplatterDetail_A(0.5 * (UV + 0.2 * (D.r + D.g - D.b))).r
Eb  = sat(tent(Eb) * (n - 0.5) * ChrSplatterEyeBloodDetailStrength 1.5 + Eb)
col *= min(1, BloodColour^(ChrSplatterBloodDensity 12 * Eb))       // per-MI 'Blood Colour'
```
So yes, **wounds over the eye (any of wound / blood / bruise) bloody it**, up to 60% coverage. After this comes only frost (`lerp` toward the frost colours, Max Base Color Blend 0.7).

### 14.7 Roughness, specular, other outputs, opacity
- **Roughness:** `lerp(ScleraRougness, IrisRoughness, maskC)` (then frost roughness by the frost mask).
- **Specular:** written as **1.0**, multiplied by a DI2 View term (`View[225].z`, which also drives a highlight tint keyed by a per-primitive byte; it isn't material data). The material has no specular input of its own.
- **GBuffer (UE4.27 eye shading model):**

  | Slot | Value |
  |---|---|
  | `Metallic` | **IrisDistance** = `min(1, (6.25 · IrisConcavityScale · length(irisUVr − 0.5))^IrisConcavityPower)` (6.25 = 1/R) |
  | `CustomData.w` | `1 − min(1, maskS)` (1 − IrisMask) |
  | `CustomData.yz` | IrisNormal `E`, octahedral-encoded |
  | `CustomData.x` | the subsurface profile (`__SubsurfaceProfile`) |
  | Shading model | 9 = Eye |

  The engine's eye BRDF uses these to light the iris with `E` and to darken by IrisDistance (concavity). That lighting is engine code, not in this shader.
- **AO:** none. GBufferC.a is a quantisation dither.
- **Opacity:** none. The only clip is UE's LOD dither fade (`clip(dither − 0.3333)`), so the eyeball is effectively opaque.

### 14.8 Eye occlusion overlay (M_EyeOcclusion, PS 4166)
A translucent, unlit card over the eye that **blurs and darkens the eyeball behind it** (a screen-space "wet meniscus / lid shadow"). All terms are functions of the overlay's UV0 `(u, v)`.
```
blur  = OverallBlurAmount * ( OuterCornerBlurAmount * (1-u)^OuterCornerBlurFalloff
                            + BottomBlurAmount * v^BottomBlurFalloff
                            + sat(PerimeterBlurAmount * (1 - T_Eye_O(uv).r)^PerimeterBlurFalloff)
                            + TearductBlurAmount * (1 - min(1, |(u - TearductBlurCentre) * TearductBlurFalloff|)) )
r     = blur / sceneLinearDepth                       // NDC-space radius; depth of the opaque eyeball behind
scene = mean of 16 SceneColorCopy taps at NDC offsets r*{(0,±2),(±2,0),(±1,±1),(0,±1),(±1,0),(±0.5,±0.5)}
        (each tap decoded as 10 * View[134].z * s^4; offsets clamped to ±0.999 NDC)
occ   = 1 - sat(OverallOcclusionAmount * ( (1-sat(OuterCornerOcclusionAmount*(1-u)^OuterCornerOcclusionFalloff))
                                         * (1-sat(InnerCornerOcclusionAmount*u^InnerCornerOcclusionFalloff))
                                         * (1-sat(TopOcclusionAmount*(1-v)^TopOcclusionFalloff))
                                         * (1-sat(BottomOcclusionAmount*v^BottomOcclusionFalloff)) - 1) + 1)
rgb   = scene * lerp(1, OcclusionColour, occ)
alpha = (1 - sat(ChrSplatterEyeOverlayRemovalScale 60 * SplatterDisplace(UV1).r)) * fade
```
- `fade` = `PrimitiveFade[0].x / 254` (DI2 primitive fade byte; 254 when fully shown) **[CPU]**.
- The output is pre-exposed (`× View[134].y`).
- With alpha 1 the overlay **replaces** what's behind it with the blurred, occlusion-tinted copy. Wounds over the eye (`Disp.r` > 1/60) remove it.
- `T_Eye_O` (G8 grayscale, linear) is used **only** for the perimeter blur term, not as an alpha or AO mask.
- **For the port:** Godot can do this with `hint_screen_texture` + `hint_depth_texture`. Keep the 16-tap kernel and radius `blur/depth`. The `10·s⁴` decode is DI2's scene-colour-copy encoding: with a linear screen texture, use the sample directly.

### 14.9 Resolved values (flesh_materials.json; L and R identical per body)

| Parameter | Walker (also Thug) | Runner | Shambler |
|---|---|---|---|
| IrisColor | T_WalkerFemaleIrisBlkBld_D | T_RunnerFemaleIrisVarB_D | T_ShamblerFemaleIrisBlkBld_D |
| ScleraColor | T_RunnerFemaleScleraVarB_D | T_RunnerFemaleScleraVarC_D | T_ShamblerFemaleSclera_D |
| Iris Scale | 1.0 | 1.0 | 1.0 |
| LimbusUVWidthColor / Shading | 0.06 / 0.05 | 0.04 / 0.045 | 0.06 / 0.05 |
| FlattenNormal | 0.95 | 0.95 | 0.95 |
| Lens IoR | 1.376 | 1.376 | 1.376 |
| Iris Depth | 1.0 | 1.2 | 1.2 |
| Pupil Size | 0.75 | 0.715 | 0.75 |
| Iris Brightness | 0.6 | 0.35 | 0.7 |
| Aggressive Iris | 0 | 0 | 0 |
| Limbus Darkening / Falloff | 0 / 6 | 2 / 6 | 0 / 6 |
| Sclera Brightness | 0.22 | 0.22 | 0.17 |
| Veins | 1.0 | 1.0 | 1.0 |
| ScleraRougness / IrisRoughness | 0.1 / 0.1 | 0.1 / 0.1 | 0.1 / 0.1 |
| Iris Concavity Scale / Power | 0.15 / 0.55 | 0.111628 / 0.32 | 0.15 / 0.55 |
| Blood Colour | (0.9635, 0.8431, 0.8431) | (0.9635, 0.8431, 0.8431) | (0.9427, 0.8738, 0.7738) |

Overlay (`MI_HumanFemaleEyeOverlay`, all bodies):

| Parameter | Value |
|---|---|
| Overall Blur Amount | 1 |
| Outer Corner Blur Amount / Falloff | 0.3 / 8 |
| Bottom Blur Amount / Falloff | 0.4 / 8 |
| Perimeter Blur Amount / Falloff | 0.4 / 12 |
| Tearduct Blur Amount / Centre / Falloff | 0.4 / 0.78 / 8 |
| Outer Corner Occlusion Amount / Falloff | 0.98 / 12 |
| Inner Corner Occlusion Amount / Falloff | 0.2 / 6 |
| Top Occlusion Amount / Falloff | 0.98 / 4 |
| Bottom Occlusion Amount / Falloff | 0.4 / 8 |
| Overall Occlusion Amount | 0.8 |
| Occlusion Colour | (0.3, 0.3, 0.3) |
| Depth Offset | 1 (not used by the PS) |

The MPC values used are ChrIrisShrinkFixAmount 0, Offset 200, Length 800, AggressiveEyesColor (1.5, 0.719, 0.691), and the splatter and eye-blood values in §5.1 / §7.1.

### 14.10 Eye textures (game/assets/di2/flesh/, role `eye`)

| Texture | Format | Encoding |
|---|---|---|
| T_WalkerFemaleIrisBlkBld_D / T_RunnerFemaleIrisVarB_D / T_ShamblerFemaleIrisBlkBld_D | DXT1 | **sRGB** |
| T_RunnerFemaleScleraVarB_D / VarC_D / T_ShamblerFemaleSclera_D | DXT1 | **sRGB** |
| T_EyeWet_N, T_Eye_N | BC5 | linear normal maps |
| T_Eye_O | G8 | linear, written as an L8 PNG |
| **T_EyeMidPlaneDisplacement_Example** | FloatRGBA (TC_HDR), 256² | **uncompressed half-float OpenEXR** (`.exr`); R=G=B, A=1, range 0..1.934 (1.934 at the centre, ~1.545 near the limbus) |

- The EXR was checked bit-exact against the raw decode with the official OpenEXR 3.5 reader. Godot reads it via `Image.load_from_file` / `load_exr_from_buffer` in editor builds (TinyEXR).

---------------------------------------------------------------------------------------------------------------------

## 15. Light-pass inputs per section, and the port's light()

This section covers what each zombie base pass writes for DI2's light pass (GBufferB.x / .y, CustomData), read off the
same decompiles. It also covers how `game/shaders/flesh.gdshader` and `eye.gdshader` feed those values to their
`light()`. The BxDFs themselves are in recon/DEFERRED_LIGHTING.md §4 (light pass) and §6 (reflections).

Two terms are left out of the formulas below:
- **landscape blend:** `LandscapeBlend` is 0 in every resolved entry. That adds (1 + ChrLandscapeBlendMaxDistance 120)
  to the RVT height distance, so the mask is 0 (PS 3213 l.636–641).
- **frost:** a runtime freeze-status input (vertex `TEXCOORD2.x`, plus `Freeze Amount` = 0).

### 15.1 Shading model and base pass per section

| Port layer | Material / permutation | Shading model | Base pass PS |
|---|---|---|---|
| 0 skin | M_Skin splatter, `Enable Zombie Veins Effect` on | SubsurfaceProfile | 3213 |
| 0 skin (lower bodies) | M_Skin splatter, full veins off (cheap veins on) | SubsurfaceProfile | 3569 |
| 2 interior shell | M_Skin `Interior Shell Material` | SubsurfaceProfile | 3094 |
| 4 organs, 3 skull / brain | M_Skin `Viscera Material`, veins on (MMI_ZombieViscera map) | SubsurfaceProfile | 2071 |
| 3 skeleton | M_Skin `Viscera Material`, both vein switches off (MI_WalkerSkeleton map) | SubsurfaceProfile | 1939 |
| 1 clothing | M_Clothing splatter | Cloth | 3410 |
| 8 cut caps | MI_Breakage → M_Clothing directly (master defaults, MSM_Cloth) | Cloth | not decompiled |
| 6 hair | M_Hair | Hair | 4056 |
| 5 eye (eye.gdshader) | M_EyeRefractive | Eye | 3791 |

PS 2071 and 1939 were found for this section with `material_map.py`
(TBasePassPSFDeferredPrecomputedVolumetricLightmapLightingPolicy, TGPUSkinVertexFactory*) and decompiled and annotated
into `extracted/shaders/annotated/DeadIsland_002071_VisceraPS.hlsl` and `…_001939_SkeletonPS.hlsl`. Their GBuffer
writes don't depend on the lighting policy.

### 15.2 SubsurfaceProfile (M_Skin)

Inputs:
- `O = MRO.b`;
- `inner`, `open·G.a` and `wet` as in §5.2–5.5;
- `vein` = the vein mask (veins aren't ported, so 0).

```
Diffuse  = lerp(D, lum(D), 'Desaturation') · 'Colour Tint'                         3213 l.703–706, 2071, 1939
S        = lerp(lerp(0.5·O^'Specular Occlusion Power', 0.5, inner), 0.5, G.a·open)  3213 l.682–693, 3569 l.622–633
oil      = MRO.r · (1 − inner) · (1 − G.a·open) · (1 − wet)                          3213 l.694–700, 3569 l.634–640
GBufferB.x = sat('Debug Oil Layer' + oil)                                            3213 l.782, 3569 l.711
GBufferB.y = sat(129/255 + min(0.5, S))                                              3213 l.783–784
BaseColor  = sat(min(max(colour, 0.018·S), 0.875 + 0.125·oil))                       3213 l.701, 794–795
CustomData.a (SSS opacity):
  3213, 2071   lerp(lerp(lerp('Base Subsurface Scattering', 'Vein Subsurface Scattering', vein), 1, inner), 1, G.a·open)
  3569         lerp(lerp(MRO.b, 1, inner), 1, G.a·open)                              l.726–731
  1939         sat(MRO.b · sat('Translucency Adjustment' + ATA.g))                   l.90–92
  3094         1                                                                     l.384
```

The other permutations differ:
- **Viscera (2071) and skeleton (1939):** `S = 0.5·O^p`, `GBufferB.x = sat(Debug Oil + MRO.r)`, and roughness
  `sat('Roughness Adjustment' + MRO.g)`.
- **Interior shell (3094):**
  - it samples no MRO;
  - `GBufferB.x = sat(Debug Oil)`, `GBufferB.y = 1` (the Fury factor);
  - roughness = `'inner Roughness'`;
  - the colour is the Inner Diffuse, lerped toward luminance by `'Inner Desaturation'` and × `'inner Colour Tint'`,
    clamped to [0.009, 0.875] (l.366–383).

**Subsurface profile.** UE 4.27 `UMaterialInstance::GetSubsurfaceProfile_Internal` takes the first instance (leaf
first) with `bOverrideSubsurfaceProfile` set, else the master's profile. Several instances serialise a profile *without*
the flag, and it is ignored: MI_WalkerMaleUpperAVarB → SSP_WalkerMaleSkinA, MI_WalkerMaleLowerIntA → SSP_HumanIntMale.

Effective result:
- 34 of 35 M_Skin entries resolve to **SSP_DefaultLightSkin**.
- **MI_ShamblerMaleHeadA** resolves to **SSP_WalkerMaleSkinA**.

`flesh_materials.json` now records this as `subsurface_profile` per entry and `subsurface_profiles` at the top level.
Each profile lists its asset fields, plus the exe's defaults (DEFERRED_LIGHTING §7.3) for the fields the asset omits:

| Profile | ScatterRadius | SubsurfaceColor | FalloffColor | Kernel |
|---|---|---|---|---|
| SSP_DefaultLightSkin | 1.5 | (0.915, 0.75165, 0.6039) | (1, 0.433, 0.37) | separable |
| SSP_WalkerMaleSkinA | 1.5 | (1, 1, 1) | (0.359375, 0, 0.03663) | separable |
| SSP_HumanIntMale (inactive) | 1.0 | (1, 1, 1) | (0.51, 0.012072, 0) | separable |

### 15.3 Cloth (M_Clothing, PS 3410)

```
Cloth      = sat('Force Cloth' + ATA.g)                                         l.140, 430
D'         = Diffuse · lerp(1, 'Cloth Colour Tint', Cloth)                      l.486–488
mB         = lerp(sat(MRO.r), 'Cloth Translucency', Cloth) · (1 − wet)          l.429–432, 478–483
BaseColor  = sat(min(max(colour, 0.009), 0.875 + 0.125·mB))                    l.484, 523–524
GBufferB.x = min(0.99, sat(mB)),  GBufferB.y = 1                                l.606, 615, 621
CustomData.a   = Cloth · (1 − wet)                                              l.612–614
CustomData.rgb = sat('Sheen Colour Multiplier' · desat(lerp(D', D'_mip16, 'Sheen Colour Averaging Amount'),
                                                       'Sheen Colour Desaturation'))      l.568–576
```
`D'_mip16` = `Diffuse.SampleLevel(16)` × the tint, i.e. the map's average.

The roughness also adds `'Detail Roughness Strength'·ATA.b·(DRO.y − 0.5)` from the Detail DRO map (l.525–529). The port
doesn't have it (material side).

M_Clothing master defaults (also what MI_Breakage, the cut caps, uses):
- Cloth Translucency 0.25, Force Cloth 0;
- Sheen Colour Averaging Amount 0.25, Sheen Colour Desaturation 0.1, Sheen Colour Multiplier 1.5;
- Cloth Colour Tint (1, 1, 1).

### 15.4 Hair (M_Hair, PS 4056)

`HD` = Packed Hair Data (SampleBias −2, linear). Its channels: x root-to-tip, y texture occlusion, z per-strand
variation, w opacity.

```
AO        = sat((HD.x^'Root Occlusion Curve'·'Root Occlusion Amount' + 1 − 'Root Occlusion Amount')
                · ('Texture Occlusion Amount'·(HD.y − 1) + 1) · ('Vertex Alpha Occlusion Amount'·(COLOR.a − 1) + 1))  l.227–239
colour    = sat(lerp('Root Colour', 'Tip Colour', HD.x^'Root-Tip Colour Curve') · 'Overall Brightness'
                · (1 + 'Brightness Variation'·(HD.z − 0.5)))                                                  l.252–258
scatter   = 'Scatter' · avg(colour)                     → GBufferB.x = sat(scatter)                          l.259–260, o2.x
S         = lerp(0.5·AO, 0.5, sat(f))                   (f = §7.1's splatter amount)                          l.240–252
BaseColor = min(max(splatter(colour·AO), 0.018·S), 0.875 + 0.125·scatter)                                    l.287, 322–323
roughness = lerp(max(0.35, 'Roughness' + 'Roughness Variation'·(HD.z − 0.5)), 0.25, sat(f))                  l.394–399
tangent   = s · normalize(TBN · normalize(s·flow.xy, 'Flow Variation'·(1 − 2·HD.z)))   flow = FlowMap.xy·2 − 1     l.95–118, 215–225
            s = Primitive[4].w · View[140].w · (front face ? 1 : −1)
CustomData.xyz = the vertex (card) normal, not flipped on back faces                                          l.607
```

### 15.5 The port

**flesh.gdshader.** `fragment()` computes the values above per layer and hands them to `light()` as varyings:
- `v_model`: 0 SubsurfaceProfile (layers 0, 2, 3, 4), 1 Cloth (1, 8), 2 Hair (6), 3 DefaultLit (7);
- `v_rough`, `v_spec_mul = 2·S'`, `v_oil`, `v_op`, `v_cloth`, `v_bx`, `v_fuzz`;
- `v_tan` (the strand tangent) and `v_ncard` (the card normal).

`light()` runs DEFERRED_LIGHTING §4.5 (skin), §4.8 (cloth), §4.7 (hair, with the DI2 card term) and §4.1 (DefaultLit),
one branch per model. The skin and cloth code is the same as player.gdshader's.

The fragment outputs:
- **`SPECULAR`:** Godot's ambient F0 is 0.16·SPECULAR². The output folds in DI2's reflection-pass F0 (0.028 for
  SubsurfaceProfile, 0.04 otherwise) and its 2·S' multiplier: `sqrt(F0·2S'/0.16)`, the recon/DANI.md 4.5 convention.
  For cloth it also folds in `(1 − |NoV|·C)`, and `ROUGHNESS` uses the reflection pass's `lerp(R, 0.1, sat((C−0.9)·10))`.
- **SSS (SubsurfaceProfile layers):** `SSS_STRENGTH = sat(10·op) · (radius·P00 / 2z) / subsurface_scattering_scale`,
  with `render_mode sss_mode_skin`.

**Per-material values.** `build_flesh_materials.py lighting_block()` writes `"lighting": {"uniforms": {...},
"textures": {...}}` into every entry:
- **M_Skin:** `ssp_op` (the opacity source above), `sss_base`, `spec_occ_power`, `debug_oil`, `translucency_adj`,
  `base_desat`, `base_tint`, `sss_radius_m`. The radius is ScatterRadius for separable kernels, MFP × WorldUnitScale
  for Burley.
- **M_Clothing:** `cloth_translucency`, `force_cloth`, `sheen_avg`, `sheen_desat`, `sheen_mult`, `cloth_tint`.
- **M_Hair:** the `hair_*` scalars and colours, plus the textures `hair_data_tex` / `hair_flow_tex` with their
  `has_*` flags. These export as role `hair` to `game/assets/di2/flesh/`.

GoreBody applies the block generically (the lib.rs hook). Without the block, the shader defaults apply:
- the Walker skin values;
- the M_Clothing and M_Hair master defaults;
- the hair falls back to the packer's flat colour, with tangent (0, −1), the mean direction of DI2's flow maps.

**eye.gdshader (§14, DEFERRED_LIGHTING §4.9).**
- The eye writes Specular 1.0, so S' = 0.49606. Hence `F0 = 0.08·S' = 0.0397` and specular × 2·S' (0.99213) × the
  light's specular amount.
- The iris and sclera transmission use `(1 − F)` with the same `F` at V·H.
- Ambient `SPECULAR = sqrt(0.028·0.99213/0.16)`: the reflection pass uses F0 0.028 for MSM_Eye. It was 1.0 (F0 0.16).

Open items and approximations: recon/UNVERIFIED.md #56.

---------------------------------------------------------------------------------------------------------------------

## Appendix A: reference code (Godot shader language, transcribed from the decompiled HLSL)

These are transcriptions, not new designs. Comments name the source shader. The inputs marked **[CPU]** take
whatever the exe session confirms. D3D `saturate(NaN) = 0`, but GLSL `clamp(NaN)` is undefined, hence the
`den > 0` guards.

```glsl
// --- FSplatterPS element (DeadIsland 1900; same per element in 1902/1923/1908/1901), planar --------------------
// p, n : projection-space position / normal (World VS: world; Local VS: bind pose; UV VS: (uv*2-1, 0), (0,0,1))
// M0..M3: DecalMatrix rows (UE row-vector convention)  S: ScaleVec  WS: WoundScale  FS: FXScale  R: RangeParams.xy
// deform_len: length(Deform.xyz) of the vertex (the VS passes DEFORM0 = max(1, deform_len))
// dec / dsp: the element's DecalTexture / DisplacementTexture (bilinear, clamp [CPU: sampler state])
bool splatter_element(vec3 p, vec3 n, vec4 M0, vec4 M1, vec4 M2, vec4 M3, vec4 S, vec4 WS, vec4 FS, vec2 R,
        sampler2D dec, sampler2D dsp, float deform_len, out vec4 o_dif, out vec4 o_dsp) {
    o_dif = vec4(0.0); o_dsp = vec4(0.0);
    vec3 L = p.x * M0.xyz + p.y * M1.xyz + p.z * M2.xyz + M3.xyz;
    float zp = abs(S.z) * L.z;
    if (!(abs(L.x) < 1.0 && abs(L.y) < 1.0 && abs(zp) < 1.0)) return false;
    vec2 uv = clamp(L.xy * 0.5 + 0.5, 0.0, 1.0);
    float fade = clamp(S.x - min(1.0, abs(zp)) * S.x, 0.0, 1.0);
    vec3 k = abs(S.w) * vec3(2.0, 4.0, 4.0) - 1.0;                       // (2a-1, 4a-1, 4a-1), a = AngleWrap
    float f = dot(n, vec3(M0.z, M1.z, M2.z)) * 0.5 + 0.5;
    vec3 den = 1.0 - max(vec3(0.0), -k);
    float wR = den.x > 0.0 ? clamp((f + k.x) / den.x, 0.0, 1.0) : 0.0;
    float wGB = den.z > 0.0 ? clamp((f + k.z) / den.z, 0.0, 1.0) : 0.0;
    vec4 D = (texture(dec, uv) - R.x) / R.y;
    vec3 W = (texture(dsp, uv).rgb - R.x) / R.y;
    o_dif = FS * D * fade * wGB;                                         // r3 * cb0[160] * fade * r2.zyzz
    W = WS.xyz * W * fade * vec3(wR, wGB, wGB);                          // r0 * cb0[144] * fade * r2.xyz
    if (WS.w > 0.0) W.x *= 3.0 / max(1.0, deform_len);
    o_dsp = vec4(W, 1.0);
    return true;
}
// --- batch fold: element 0 (fold_first), then i = 1..N-1 (fold_next); an element whose box misses the texel
//     contributes nothing (the accumulator passes through unchanged) -------------------------------------------
void fold_first(vec4 S, inout vec4 dif, inout vec4 dsp) {
    vec4 d0 = dif, w0 = dsp;
    if (S.z < 0.0) { dif = min(d0, vec4(0.0)); dsp = min(w0, vec4(0.0)); }   // ApplyMin [CPU: bit mapping]
    if (S.w < 0.0) { dif = max(d0, vec4(0.0)); dsp = max(w0, vec4(0.0)); }   // ApplyMax (wins)
}
void fold_next(vec4 S, vec4 e_dif, vec4 e_dsp, inout vec4 acc_dif, inout vec4 acc_dsp) {
    vec4 a = (S.z < 0.0) ? min(acc_dif, e_dif) : acc_dif + e_dif;
    vec4 b = (S.z < 0.0) ? min(acc_dsp, e_dsp) : acc_dsp + e_dsp;
    if (S.w < 0.0) { a = max(acc_dif, e_dif); b = max(acc_dsp, e_dsp); }
    acc_dif = a; acc_dsp = b;
}
// Then RT <- blend(RT, acc): ADD for Decal / ApplyMin, MAX for ApplyMax  [CPU: confirm]; RT format [CPU].

// --- Radial element (DeadIsland 1943): SR = SafeRegionMatrix rows ------------------------------------------
//  y = dot(p, vec3(M0.y,M1.y,M2.y)) + M3.y
//  q = vec2(dot(p, vec3(SR0.y,SR1.y,SR2.y)) + SR3.y, dot(p, vec3(SR0.z,SR1.z,SR2.z)) + SR3.z)
//  r = length(q); w = (abs(y) < 1.0 ? 1.0 : 0.0) * (1.0 - clamp(4.0 * (r - 1.0), 0.0, 1.0))
//  uv = clamp(vec2(q.y / r, y) * 0.5 + 0.5, 0.0, 1.0); then as above with fade*wrap replaced by w on every channel.

// --- Dilation (Global 1874 H / 1875 V), one texel; t0 = RT carrying coverage alpha (DispSplatterRT) --------
//  c0 = t0[p]; c1 = t1[p]; if (c0.a == 1.0) { out0 = vec4(c0.rgb, 1); out1 = c1; return; }
//  for n in (p - axis, p + axis):  if (c0.a < t0[n].a) { c0 = t0[n] * sign(t0[n].a); c1 = t1[n] * sign(t0[n].a); }
//  out0 = vec4(c0.rgb, H ? (c0.a > 0.0 ? 0.5 : 0.0) : 0.0); out1 = c1;

// --- Deform CS per vertex (Global 936), depth in Deform.w ---------------------------------------------------
//  v = ((Disp.r_point(uv) - R.x) / R.y) * S.y * fade * wR * inside
//  if (DeformParams.x > 0.0 && any(Deform != 0)) v *= 3.0 / max(1.0, length(Deform.xyz));
//  v = (S.z < 0.0) ? ((DeformParams.y < 0.0) ? 1.0 - v : v) : DeformParams.y * v;
//  s = v / 0.9;
//  depth = (S.w < 0.0) ? clamp(max(s, depth), 0, 1) : (S.z < 0.0) ? clamp(min(s, depth), 0, 1) : clamp(depth + s, 0, 1);
//  VS: P_bind = Position + Deform.xyz * depth  (before skinning)

// --- M_Skin splatter shading (DeadIsland 3213), Walker values ----------------------------------------------
const float STD_WOUND_GRAD = 1.5, EPI_START = 0.1, EPI_END = 0.18, SKIN_EDGE_SHIFT = 0.12, SKIN_EDGE_CONTRAST = 4.0;
const float EDGE_FAT_NOISE = -1.0, EDGE_EPI_NOISE = -0.7, MEATMAN_POW = 20.0, VTX_GRAD_POW = 3.0, VTX_GRAD_AMT = 1.0;
const float VOL_MULT = 1.0, VOL_OFFSET = -0.18, VOL_TILING = 3.7;
const float BLOOD_MAX_COV = 0.8, BLOOD_DETAIL_MASK = 1.5, BLOOD_EDGE_CONTRAST = 1.2, BLOOD_IN_WOUND_FADE = 1.5;
const float BLOOD_DENSITY = 12.0, BLOOD_NRM_THRESH = 3.0, BLOOD_ROUGH = 0.15;
const float DRIP_MAX_COV = 1.0, DRIP_DETAIL = 1.0, DRIP_EDGE_CONTRAST = 1.7;
const float CAUT_MAX = 0.75, CAUT_WOUND_FALLOFF = 0.4, CAUT_DETAIL = 1.2, CAUT_EDGE_CONTRAST = 1.6;
const float CAUT_MAX_DARK = 0.98, CAUT_ROUGH = 0.8, BRUISE_INTENSITY = 1.0;
const float MAJOR_CUT_START = 0.9, MAJOR_CUT_END = 1.0, MAJOR_CUT_RAGGED = 10.0;
const vec3 FUEL_COLOUR = vec3(0.602512, 0.646108, 0.692708);
float tent(float x) { return 1.0 - abs(2.0 * x - 1.0); }
float contrast(float x, float c) { return clamp((x - 0.5) * c + 0.5, 0.0, 1.0); }
float pw(float x, float k) { return exp2(k * log2(max(1e-6, x))); }
// Inputs: disp = SplatterDisplace.rgb, dif = SplatterDiffuse.rgba (both at UV0), dv = Deform.w, vc = vertex colour.
// One TV_Global3dNoise sample n3 at Pb / VOL_TILING (Pb = deformed bind position):
//   nV = clamp(VOL_MULT * n3.w + VOL_OFFSET, 0, 1);  nS = 1 - (1 - n3.y) * (1 - n3.x)
// nH = T_SkinSplatterWoundNoise_H(uv * epidermisTiling).g
//   W     = max(disp.r, VTX_GRAD_AMT * pw(clamp(dv, 0, 1), VTX_GRAD_POW));
//   g     = STD_WOUND_GRAD * W;            inner = g > 0.5 ? 1.0 : 0.0;
//   e     = clamp((g - EPI_START) / (max(EPI_START, EPI_END) - EPI_START), 0, 1);
//   T     = tent(g);
//   open  = contrast(clamp(clamp(g + T*(nV-0.5)*EDGE_FAT_NOISE - T*(nH-0.5)*EDGE_EPI_NOISE, 0, 1) / SKIN_EDGE_SHIFT, 0, 1), SKIN_EDGE_CONTRAST);
//   innerD= mix(innerDiffuse, vec3(dot(innerDiffuse, vec3(0.3, 0.59, 0.11))), innerDesaturation);
//   U     = clamp(pw(1.0 - clamp(innerTint.g * innerD.g, 0, 1), MEATMAN_POW) * mix(nH, nV, e), 0, 1);
//   G     = texture(goreGradient /*clamp*/, vec2(U, g));
//   bruiseCol = mix(bruiseTint * vec3(0.557292, 0.142254, 0.139323), desat(bruiseTex(uv * bruiseTiling), bruiseDesat) * bruiseTint, vc.r);
//   bruiseAmt = mix(BRUISE_INTENSITY * disp.b * nS, BRUISE_INTENSITY * disp.b, vc.r);
//   C *= mix(vec3(1.0), bruiseCol, bruiseAmt);  C = mix(C, innerTint * innerD, inner);  C = mix(C, G.rgb, G.a * open);
//   B     = min(BLOOD_MAX_COV, clamp(dif.a + disp.g + dif.b, 0, 1));
//   dB    = bloodDetailA((uv + bloodMapUVOffset) * bloodSplatterTiling).g;
//   blood = contrast(clamp(tent(B) * (dB - 0.5) * BLOOD_DETAIL_MASK * vc.r + B, 0, 1), BLOOD_EDGE_CONTRAST) * mix(nS, dB, vc.r);
//   dR    = min(DRIP_MAX_COV, dif.r);  dm = dripMap(uv * dripTiling);
//   drip  = dm.r * contrast(clamp(tent(dR) * (dm.g - 0.5) * DRIP_DETAIL + dR, 0, 1), DRIP_EDGE_CONTRAST);
//   blood = max(blood, drip) * pw(1.0 - g, BLOOD_IN_WOUND_FADE);      wet = clamp(BLOOD_NRM_THRESH * blood, 0, 1);
//   fb = clamp(1e-5 + disp.g, 0, 1); s = fb + dif.a + dif.b;
//   mixC = (fb / s) * bloodColour + vec3(dif.a / s) + (dif.b / s) * FUEL_COLOUR;  mixC = mix(mixC, bloodColour, drip);
//   C *= min(vec3(1.0), exp2(BLOOD_DENSITY * blood * log2(mixC)));
//   c0   = min(CAUT_MAX, dif.g) * pw(1.0 - g, CAUT_WOUND_FALLOFF);
//   caut = contrast(clamp(tent(c0) * mix(nS, (cautA(uv * cautTiling).g - 0.5) * CAUT_DETAIL, vc.r) + c0, 0, 1), CAUT_EDGE_CONTRAST);
//   C *= 1.0 - caut * CAUT_MAX_DARK;
//   rough = mix(mix(mix(mix(rough, innerRough, inner), innerRough, G.a * open), BLOOD_ROUGH, wet), CAUT_ROUGH, caut);
//   a     = clamp((W - MAJOR_CUT_START) / (max(MAJOR_CUT_START, MAJOR_CUT_END) - MAJOR_CUT_START), 0, 1);
//   keep  = clamp(1.0 - a - tent(a) * (1.0 + MAJOR_CUT_RAGGED * (innerN.x + innerN.y)), 0, 1);
//   alpha = clamp(splatterOpacityOffset + keep, 0, 1) * ata.x * clamp(vc.g + (dv >= 0.001 ? 1.0 : 0.0), 0, 1);  // clip 0.1
// Normal blends (RNM as decompiled: b' = (b.xy, b.z + 1), a' = (-a.xy, a.z); r = b' * dot(b', a') - a' * b'.z):
//   N = mix(N, innerN, inner); N = mix(N, woundN, G.a * open); N = mix(N, bloodN, wet * (1 - open));
//   N = mix(N, cautN, caut * (1 - open))
```

---------------------------------------------------------------------------------------------------------------------

## Appendix B: eye reference code (Godot shader language, transcribed from PS 3791 / 4166)

```glsl
// --- M_EyeRefractive (eyeball), spatial shader. Inputs: UV (UV0), UV2 (UV1, splatter), vertex tangent frame. ---
const float IRIS_R = 0.16;
uniform sampler2D eye_wet_n   : hint_normal, filter_linear_mipmap, repeat_disable;   // T_EyeWet_N   (View clamped)
uniform sampler2D sclera_tex  : source_color, filter_linear_mipmap, repeat_disable;  // ScleraColor   (View clamped)
uniform sampler2D iris_tex    : source_color, filter_linear_mipmap, repeat_disable;  // IrisColor     (View clamped)
uniform sampler2D eye_dir_n   : hint_normal, filter_linear_mipmap, repeat_enable;    // T_Eye_N (own sampler, wrap)
uniform sampler2D midplane    : filter_linear_mipmap, repeat_enable;                 // T_EyeMidPlaneDisplacement_Example (.exr)
uniform sampler2D splatter_displace : filter_linear_mipmap, repeat_enable;           // body DispSplatterRT, at UV1
uniform sampler2D blood_detail : filter_linear_mipmap, repeat_enable;                // T_SkinBloodSplatterDetail_A
uniform float iris_scale = 1.0, limbus_w_color = 0.06, limbus_w_shading = 0.05, flatten_normal = 0.95;
uniform float lens_ior = 1.376, iris_depth = 1.0, pupil_size = 0.75, iris_brightness = 0.6, aggressive_iris = 0.0;
uniform float limbus_darkening = 0.0, limbus_darkening_falloff = 6.0, sclera_brightness = 0.22, veins = 1.0;
uniform float sclera_roughness = 0.1, iris_roughness = 0.1, iris_concavity_scale = 0.15, iris_concavity_power = 0.55;
uniform vec3 blood_colour = vec3(0.963542, 0.843099, 0.843099);
const vec3 AGGRESSIVE_EYES_COLOR = vec3(1.5, 0.718995, 0.691243);
const float EYE_BLOOD_MAX = 0.6, EYE_BLOOD_DETAIL = 1.5, BLOOD_DENSITY = 12.0;

vec3 unpack_n(vec2 xy) { xy = xy * 2.0 - 1.0; return vec3(xy, sqrt(max(0.0, 1.0 - dot(xy, xy)))); }
float smooth01(float x) { return x * x * (3.0 - 2.0 * x); }
float tent(float x) { return 1.0 - abs(2.0 * x - 1.0); }

// T, B, Nv: world-space vertex tangent, bitangent, normal; V: unit vector from the pixel to the camera (world).
void eye_refractive(vec2 uv, vec2 uv1, vec3 T, vec3 B, vec3 Nv, vec3 V,
        out vec3 albedo, out vec3 normal_ws, out float roughness, out float iris_mask, out float iris_distance,
        out vec3 iris_normal_ws) {
    float S = iris_scale;                                     // x (1 + ChrIrisShrinkFixAmount * ...) = x 1 at MPC defaults
    vec2 iuv = (uv - 0.5) / S + 0.5;
    float d = length(iuv - 0.5);
    float maskC = smooth01(clamp(1.0 - (d - (IRIS_R - limbus_w_color)) / limbus_w_color, 0.0, 1.0));
    float maskS = smooth01(clamp(1.0 - (d - (IRIS_R - limbus_w_shading)) / limbus_w_shading, 0.0, 1.0));
    vec3 nt = mix(unpack_n(texture(eye_wet_n, uv).rg), vec3(0.0, 0.0, 1.0), mix(flatten_normal, 1.0, maskC));
    vec3 N = normalize(nt.x * T + nt.y * B + nt.z * Nv);
    vec3 ne = unpack_n(texture(eye_dir_n, uv).rg);
    vec3 E = normalize(ne.x * T + ne.y * B + ne.z * Nv);
    // refraction + mid-plane parallax
    float eta = 1.00029 / lens_ior;
    float c = dot(N, V);
    float k = 1.0 - eta * eta * (1.0 - c * c);
    vec3 Rd = normalize((eta * c - sqrt(max(k, 0.0))) * N - eta * V);
    float h0 = texture(midplane, vec2(0.5 + IRIS_R * iris_scale, 0.5)).r;
    vec3 h = max(vec3(0.0), texture(midplane, uv).rgb - h0) * iris_depth;
    float ve = dot(V, E);
    vec3 off = -Rd * h / (0.325 + 0.675 * ve * ve);
    vec3 Tp = normalize(T - dot(T, E) * E);
    vec3 Bp = cross(Tp, E);
    vec2 iuvr = iuv + maskC * vec2(-IRIS_R * dot(Tp, off), IRIS_R * dot(Bp, off));
    // pupil + iris + limbus + sclera
    vec2 c0 = (iuvr - 0.5) / (2.0 * IRIS_R);
    float L = length(c0);
    float p = clamp(pupil_size * (1.0 - 2.0 * L), 0.0, 1.0);
    vec2 c1 = (L > 0.0 ? c0 / L : vec2(0.0)) * 0.5 * (1.0 - p);
    vec3 iris = texture(iris_tex, 0.5 + c1).rgb * (aggressive_iris * AGGRESSIVE_EYES_COLOR + iris_brightness);
    iris *= 1.0 - pow(max(1e-6, min(1.0, length(limbus_darkening * c1))), limbus_darkening_falloff);
    vec3 sclera = mix(vec3(1.0), texture(sclera_tex, uv).rgb, veins) * sclera_brightness;
    vec3 col = mix(sclera, iris, maskC);
    // blood from the body's displacement RT (UV1)
    vec3 D = texture(splatter_displace, uv1).rgb;
    float Eb = min(EYE_BLOOD_MAX, max(max(D.r, D.g), D.b));
    float n = texture(blood_detail, 0.5 * (uv + 0.2 * (D.r + D.g - D.b))).r;
    Eb = clamp(tent(Eb) * (n - 0.5) * EYE_BLOOD_DETAIL + Eb, 0.0, 1.0);
    col *= min(vec3(1.0), exp2(BLOOD_DENSITY * Eb * log2(blood_colour)));
    albedo = col;
    normal_ws = N;
    roughness = mix(sclera_roughness, iris_roughness, maskC);
    iris_mask = min(1.0, maskS);
    iris_distance = min(1.0, pow(max(1e-6, length(iuvr - 0.5) / IRIS_R * iris_concavity_scale), iris_concavity_power));
    iris_normal_ws = E;
    // Godot has no eye BRDF: iris_mask / iris_distance / iris_normal are what UE's MSM_Eye lighting consumes
    // (light the iris with E instead of N, darken by iris_distance). Specular is written as 1.0.
}

// --- M_EyeOcclusion (overlay card), unlit, blend_mix, depth test on, no depth write. ----------------------------
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture;
uniform sampler2D eye_o : filter_linear_mipmap, repeat_disable;     // T_Eye_O (View clamped sampler)
// MI_HumanFemaleEyeOverlay values
const float OVERALL_BLUR = 1.0, OC_BLUR = 0.3, OC_BLUR_F = 8.0, BOT_BLUR = 0.4, BOT_BLUR_F = 8.0;
const float PERIM_BLUR = 0.4, PERIM_BLUR_F = 12.0, TEAR_BLUR = 0.4, TEAR_C = 0.78, TEAR_F = 8.0;
const float OC_OCC = 0.98, OC_OCC_F = 12.0, IC_OCC = 0.2, IC_OCC_F = 6.0, TOP_OCC = 0.98, TOP_OCC_F = 4.0;
const float BOT_OCC = 0.4, BOT_OCC_F = 8.0, OVERALL_OCC = 0.8;
const vec3 OCC_COLOUR = vec3(0.3);
float pw(float x, float k) { return exp2(k * log2(max(1e-6, x))); }
// uv: overlay UV0; ndc: this fragment's NDC xy (y up); lin_depth: linear depth of the opaque surface behind
vec4 eye_occlusion(vec2 uv, vec2 uv1, vec2 ndc, float lin_depth) {
    float blur = OC_BLUR * pw(1.0 - uv.x, OC_BLUR_F) + BOT_BLUR * pw(uv.y, BOT_BLUR_F)
               + clamp(PERIM_BLUR * pw(1.0 - texture(eye_o, uv).r, PERIM_BLUR_F), 0.0, 1.0)
               + TEAR_BLUR * (1.0 - min(1.0, abs((uv.x - TEAR_C) * TEAR_F)));
    float r = OVERALL_BLUR * blur / lin_depth;
    const vec2 K[16] = vec2[](vec2(0,-2), vec2(2,0), vec2(0,2), vec2(-2,0), vec2(-1,-1), vec2(1,-1), vec2(-1,1), vec2(1,1),
                              vec2(0,-1), vec2(1,0), vec2(0,1), vec2(-1,0), vec2(-0.5,-0.5), vec2(0.5,-0.5), vec2(0.5,0.5), vec2(-0.5,0.5));
    vec3 scene = vec3(0.0);
    for (int i = 0; i < 16; i++) {
        vec2 q = clamp(ndc + r * K[i], vec2(-0.999), vec2(0.999));
        scene += texture(screen_tex, vec2(q.x, -q.y) * 0.5 + 0.5).rgb;   // DI2 decodes 10*s^4 (its copy encoding)
    }
    scene /= 16.0;
    float occ = (1.0 - clamp(OC_OCC * pw(1.0 - uv.x, OC_OCC_F), 0.0, 1.0)) * (1.0 - clamp(IC_OCC * pw(uv.x, IC_OCC_F), 0.0, 1.0))
              * (1.0 - clamp(TOP_OCC * pw(1.0 - uv.y, TOP_OCC_F), 0.0, 1.0)) * (1.0 - clamp(BOT_OCC * pw(uv.y, BOT_OCC_F), 0.0, 1.0));
    occ = 1.0 - clamp(OVERALL_OCC * (occ - 1.0) + 1.0, 0.0, 1.0);
    vec3 rgb = scene * mix(vec3(1.0), OCC_COLOUR, occ);
    float alpha = 1.0 - clamp(60.0 * texture(splatter_displace, uv1).r, 0.0, 1.0);   // x DI2 fade byte /254 [CPU]
    return vec4(rgb, alpha);
}
```
