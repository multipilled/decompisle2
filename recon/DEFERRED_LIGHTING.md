# DI2 deferred lighting: the light pass and its per-shading-model BxDFs

Static analysis only of the user's own install (`ShaderArchive-Global-PCD3D_SM5.ushaderbytecode` +
`GlobalShaderCache-PCD3D_SM5.bin`, extracted by the FLESH shader session). The game is never run. Personal use.

This document answers recon/DANI.md §4.3, §4.5 and §7.1 (DI2's custom light pass), and gives the light() changes the
Godot shaders need (§10). Every formula is read off the decompiled DXBC (`fxc /dumpbin`, register-level) and
cross-checked against the 3Dmigoto HLSL. Shader references are **Global archive index + permutation id**, and
"asm N–M" are line numbers in `extracted/shaders/lighting/Global_<index>_p<perm>.asm`.

Notation: `sat()` = saturate, `lerp(a,b,t)`, `lum(c) = dot(c, (0.3, 0.59, 0.11))`, `pow5(x) = x^5`.
`N` = GBuffer normal, `V` = direction to the camera, `L` = direction to the light, `H = normalize(V+L)`.
`DLU[i]` = `DeferredLightUniforms` float4 *i*; `View[i]` = `View` float4 *i*. **[CPU]** = set by the exe, not visible
in the shaders.

---------------------------------------------------------------------------------------------------------------------

## 0. Summary: how DI2's light pass differs from UE 4.27

The previous note (DANI.md §4.3) said the light pass "reads a packed per-pixel layout from structured buffers". That was
one permutation: **Global 2174 p16241 is `USE_HAIR_LIGHTING = 2`, the hair-strands (groom) path** (§1.3). Its
`t4/t5/t7` are UE 4.27's HairStrands visibility buffers, filled by the strands visibility passes, **not** a conversion
of the GBuffer. Every other light permutation reads the ordinary GBuffer textures A–E. There is no GBuffer→packed pass.

What DI2 changed in the light pass (all permutations, plus clustered and tiled shading, §1.4):

| # | Change | Where |
|---|---|---|
| 1 | **F0 is fixed:** `SpecularColor = lerp(0.04, BaseColor, metallic)`. For SubsurfaceProfile and Eye the constant is **0.028**. The material's Specular no longer sets F0. | §2.3 |
| 2 | **Specular byte = flag + 7-bit specular intensity.** `GBufferB.y = sat(129/255 + min(0.5, S))`. The pass decodes `S' = 0.5·sat((B.y − 129/255)·512/255)` and multiplies **all specular by `2·S'`** (≤ 0.992). Bit "B.y ≥ 129/255" is a Fury-mode tint exemption flag. | §2.2, §3.5 |
| 3 | **SubsurfaceProfile is a DI2 BxDF:** Burley diffuse plus **two GGX lobes** (roughness² and roughness), mixed by **GBufferB.x, which M_Skin fills with an "Oil Layer" amount**. Metallic is forced to 0 on skin. The profile's Roughness0/1/LobeMix are not used. | §4.5 |
| 4 | **Cloth is a DI2 BxDF:** the fuzz lobe is **Charlie sheen** (not UE's inverse-GGX), the diffuse loses `Cloth·NoL·Vis·F_fuzz`, and **ClothTranslucency becomes back-scatter transmission**: `sat(Cloth·m·BaseColor)` is taken out of the diffuse colour and lit with a `(1−sat(−NoL))³` wrap and forward lobe. FuzzColor is stored linearly (no sqrt). | §4.8 |
| 5 | **Hair**: stock UE 4.27 Marschner/Kajiya, times a DI2 term `(1 − sat(−dot(Ncard, L)))⁴`. `Ncard` is the hair card's vertex normal, stored in CustomData.xyz. | §4.7 |
| 6 | **Subsurface** uses UE5's wrapped back-scatter. DI2 adds shading model **12 = `MSM_SubsurfaceDerived`** (exe enum string): subsurface colour = `BaseColor·GBufferB.x`. | §4.2 |
| 7 | **Eye**: stock UE 4.27 EyeBxDF (F0 = 0.08·S'), but S' ≤ 0.496, so the cornea F0 is ≤ 0.0397, and the 2·S' multiplier applies. | §4.9 |
| 8 | **Shadow terms:** hair and cloth use the *surface* shadow as transmission shadow. Radial lights un-shadow near the light source. Cloth specular and transmission are multiplied by `sat(1 + SSAO − Cloth)`. Directional lights run DI2 contact shadows. Spot lights have two extra DI2 shape parameters (`DLU[9]`). | §3 |
| 9 | Ambient/reflection pass: same F0 rules and 2·S'. The oil layer is a second, sharper reflection lobe. Cloth reflection is damped by `1 − |NoV|·Cloth`. | §6 |

What is **stock UE 4.27**: GBuffer A/C/E encoding, the capsule/sphere area-light integration (SphereMaxNoH,
EnergyNormalization, LineIrradiance, SphereHorizonCosWrap), D_GGX, Vis_SmithJointApprox, F_Schlick, DefaultLit,
PreintegratedSkin, the SubsurfaceProfile *transmission* (profile LUT + HG phase), the light accumulator / SSS split, and
the SSS post-process (recombine).

---------------------------------------------------------------------------------------------------------------------

## 1. Sources and method

### 1.1 Tools (new, `tools/re_lighting/`, read-only reuse of `tools/shaders/`)
- `list_global.py <regex> [--json f]` lists global shaders: type, permutation, archive index, instruction count, source .usf.
- `ldis.py <index>[:label] … | --type <regex>` writes `extracted/shaders/lighting/Global_<i>_<label>.{asm,hlsl,dxbc,meta.json}`.
  The meta file includes the resource table (`srt`), which maps SRV slots to uniform-buffer members.
- `features.py` summarises each permutation's code (resource counts, structured buffers, falloff, and so on).
- `cases.py` / `casediff.py` split a light shader into its shading-model `switch` cases and diff one case between two
  permutations with registers stripped.
- `xref_rip.py <va>…` finds RIP-relative references in the exe's .text (used for the SSS-profile defaults, §7.3).

### 1.2 FDeferredLightPS: 768 permutation entries, 475 distinct shaders (Global 1910–2384)
(The "40 permutations" in DANI.md was an undercount.) Bits were mapped by feature correlation over all 768 entries and
by single-bit diffs (`features.py`, scratch `corr*.py`):

| Digit (radix) | Stride | Meaning | Evidence |
|---|---|---|---|
| Light shape (3) | 1 | 0 directional, 1 capsule (point/spot), 2 rect | 0 ⇔ no `DLU[3].w` (InvRadius); 2 ⇔ barn-door code |
| bool | 3 | USE_SOURCE_TEXTURE | +1 texture (DeferredLightUniforms res 0) |
| bool | 6 | USE_IES_PROFILE | +1 texture, always |
| bool | 12 | INVERSE_SQUARED_FALLOFF | removes `pow(…, FalloffExponent)` |
| bool | 24 | VISUALIZE_LIGHT_CULLING | no BxDF switch, constant output |
| HairLighting (3) | 48 | USE_HAIR_LIGHTING; **2 = hair strands** (`DISPATCH_NODECOUNT` input, 3 structured buffers) | exact separation |
| bool | 144 | USE_TRANSMISSION (SubsurfaceProfile transmission LUT, §4.5) | +1 texture, used only in case 5 |
| bool | 288 | DI2: no shadow inputs (LightAttenuation + GBufferE removed) | −2 textures |
| bool | 576 | DI2: diffuse-only light (case 1 = Lambert only; transmissions kept) | ~½ the instructions |
| bool | 1152, 2304, 4608 | DI2. On capsule lights each adds in-shader shadow-map filtering (`$Globals` with a shadow matrix; 1 / 4 / 16+ taps). Every directional permutation has 2304 set without `$Globals`, so its meaning there differs. | +`$Globals` cb |
| bool | 9216 | USE_LIGHTING_CHANNELS | +1 uint texture |

The names of the four DI2 bits are inferred from what their code does. **[CPU]**: which lights get which permutation.

### 1.3 Reference permutations (all decompiled)

| Global index / perm | What it is | Used for |
|---|---|---|
| **2075 / p1** | capsule (point/spot), non-inverse-squared, shadowed | main decode (asm line numbers below refer to this file) |
| 2121 / p13 | same, inverse-squared | falloff |
| 2204 / p145 | p1 + USE_TRANSMISSION | SubsurfaceProfile transmission |
| 1998 / p11520 | directional (+ lighting channels, + bit 2304) | sun shadows / contact shadows |
| 1979 / p14 | rect light | LTC path (not decoded, §8) |
| 1919 / p577 | diffuse-only DI2 bit | — |
| 2174 / p16241 (+9 others) | **USE_HAIR_LIGHTING 2**: `t5` node coords (`x | y<<16`), `t4` `FPackedHairSample` (5 u32: depth, ids, tangent+coverage, base colour+roughness, specular+backlit), `t7` `FHairTransmittanceMask` (hair count·1000 \| visibility·255) | groom hair only |

**Equality check.** `casediff.py` on cases 1, 5, 8 and 9 between p1 (point) and p11520 (directional) shows only register
masks and instruction order. Between p1 and p13 (inverse-squared) the only change is the extra `× Falloff`. The BxDF code
is identical across light types; only the light setup (§3) differs.

### 1.4 Other direct-light paths carry the same DI2 BxDFs
`FClusteredShadingPS` (Global 1887) and `FTiledDeferredLightingCS00` (Global 1514) contain the same markers: the
`0.505882 / 2.007843` specular decode, `0.028 / 0.04` F0, the `0.02` SSP lobe floor and the cloth `2.522535` back-scatter.
The tiled **simple-light** path (Global 1515, `FTiledDeferredLightingCS10`) is different; see §5.

### 1.5 Resource map (p1)
`cb0` = View, `cb1` = DeferredLightUniforms (10 float4: 4.27's 9, plus DI2 `[9]`; some permutations add `[10].x`).
SRV t-registers come from SceneTexturesStruct through the resource table: `t1` SceneDepth, `t2` GBufferA, `t3` GBufferB,
`t4` GBufferC, `t5` GBufferD, `t6` GBufferE, `t7` ScreenSpaceAO, `t0` View resource 48 (PreIntegratedBRDF, case 3 only).
Loose: `t8` LightAttenuation (screen shadow mask). With USE_TRANSMISSION, `t9` = SSProfiles texture.

---------------------------------------------------------------------------------------------------------------------

## 2. GBuffer decode (p1 asm 44–205; identical in every permutation)

### 2.1 Layout
| Target | Content |
|---|---|
| A (`t2`) | `N·0.5+0.5` (plain, not octahedral). `.w` = per-object bits (bit 0 tested by DI2 contact shadows, §3.6). |
| B (`t3`) | `.x` "metallic slot" (meaning per model, §2.4), `.y` flag + specular (§2.2), `.z` roughness, `.w` = `(model | flags<<4)/255` |
| C (`t4`) | BaseColor. `.a` is not read by the light pass (GBufferAO = 1). |
| D (`t5`) | CustomData (per model, §2.4) |
| E (`t6`) | precomputed shadow factors |

`k = round(255·B.w)`, `model = k & 15`, `flags = k >> 4`: 16 = skip CustomData (reads as 0), 32 = skip precomputed
shadow (then 64 = zero, else 1). These are stock 4.27. Shading models (exe enum strings, `MSM_*` at 0x5ec1e30): 1 DefaultLit,
2 Subsurface, 3 PreintegratedSkin, 4 ClearCoat, 5 SubsurfaceProfile, 6 TwoSidedFoliage, 7 Hair, 8 Cloth, 9 Eye,
10 SingleLayerWater, 11 ThinTranslucent, **12 SubsurfaceDerived (DI2)**.

### 2.2 Specular byte: what `0.50588 + Specular` means
Material side (every DI2 base-pass PS seen; e.g. DeadIsland 9326 line 563, 3213, 4056):
```
GBufferB.y = sat(129/255 + min(0.5, Specular)) · (1 + FuryHighlight·(View[225].z − 1))
```
`FuryHighlight` = `View[225].y · primitive byte (Primitive[28].z >> 24) / 255`, which is 0 outside Fury.
M_Clothing writes 1.0 (no Specular input). The eye writes 1.0.

Light pass (asm 136–140):
```
flag = B.y >= 0.505882                      (0.505882 = 129/255)
S'   = 0.5 · sat( (B.y − (flag ? 0.505882 : 0)) · 2.007843 )      (2.007843 = 512/255)
```
- With 8-bit storage, `byte = 129 + round(255·min(0.5, S))`, clamped to 255. So **S' = (byte − 129)/254**. For any
  S ≥ 125.5/255 = 0.4922, the byte is 255 and **S' = 0.49606**.
- S' does **not** set F0 (§2.3). It is a **specular intensity**: the light pass multiplies specular by `2·S'`
  (§3.5; max 0.99213), and so does the reflection pass (§6). Eye and hair also use S' inside their BxDF (§4.7, §4.9).
- `flag` is used only in Fury mode: when set, the specular is desaturated to luminance; when clear (a Fury-highlighted
  primitive whose byte was scaled down), it is tinted by DI2's screen gradient (§3.5). Outside Fury the flag is always set
  and has no effect.

**Port formula:**
```
specMul(S) = 2·S' = sat( (min(round(255·min(0.5,S)), 126)) · 512/65025 )       // S = 0.5 → 0.99213
```

### 2.3 F0, metallic and DiffuseColor (asm 141–205)
```
m      = min(B.x, 0.99)
BC'    = cloth ? BC·(1 − m·C) : model12 ? BC·(1 − m) : BC               (C = raw CustomData.a for cloth)
metal  = (model 5 | 9 | 12) ? 0 : cloth ? B.x·(1 − C) : B.x
F0d    = (model 5 | 9) ? 0.028 : 0.04
SpecularColor = F0d + metal · (lerp(BC', lum(BC'), View[225].y) − F0d)    // View[225].y = Fury desaturation, 0 normally
if (model 5 | 9) and View.bSubsurfacePostprocessEnabled (View[156].x):        // stock AdjustBaseColorAndSpecular…
    BC' = 1;  if View.bCheckerboardSubsurfaceProfileRendering (View[203].z):
              BC' = checker;  SpecularColor *= !checker;  S' *= !checker      // checker = (px + py + View[151].x) & 1
DiffuseColor  = BC' · (1 − metal)        then · View[135].w + View[135].xyz (DiffuseOverrideParameter)
SpecularColor = SpecularColor · View[136].w + View[136].xyz                   (SpecularOverrideParameter)
```

### 2.4 The metallic slot and CustomData per model
| Model | GBufferB.x means | CustomData | Material that writes it |
|---|---|---|---|
| 1 DefaultLit | metallic | (in directional contact shadows `D.xyz·2−1` is used as a normal, §3.6) | — |
| 5 SubsurfaceProfile | **lobe mix** (DI2: M_Skin's `sat('Debug Oil Layer' + oil)`) | x = profile id, **y = 0, z = 1** (DI2 constants), w = SSS opacity | M_Skin: 9326 l.562, 12717 l.539, 5740 l.390, Walker 3213 l.782 |
| 8 Cloth | `m = min(0.99, lerp(Metallic, ClothTranslucency, Cloth))` | rgb = **FuzzColor, linear** (not sqrt-encoded), a = Cloth | M_Clothing: 4452 l.488/645, 3410 l.611/769 |
| 7 Hair | Kajiya-Kay scatter amount ("metallic") | xyz = **vertex (card) normal·0.5+0.5** (`TEXCOORD11` = TangentToWorld2), w = 1 | M_Hair: DeadIsland 4056 l.607–610 |
| 9 Eye | IrisDistance | yz = iris normal (oct), w = 1 − IrisMask | M_EyeRefractive (SHADERS_FLESH §14.7) |
| 12 SubsurfaceDerived | subsurface amount | a = opacity (raw) | not traced |

---------------------------------------------------------------------------------------------------------------------

## 3. Light setup, shadows and the output (p1 asm 44–120, 206–270, 1790–1850)

### 3.1 Light mask (radial lights)
```
ToLight = DLU[3].xyz − WorldPos;   Ln = normalize(ToLight)
falloff = INVERSE_SQUARED ? sat(1 − (|ToLight|²·DLU[3].w²)²)²                 // window; 1/d² is applied in the BxDF
                          : (1 − min(1, |ToLight·DLU[3].w|²)) ^ DLU[4].w       // FalloffExponent
L'      = normalize(Ln + dot(Ln, DLU[9].xyz)·DLU[9].xyz)                        // DI2: cone shaping
spot    = sat((dot(L', DLU[5].xyz) − DLU[7].x)·DLU[7].y)²                     // SpotAngles (1 for point lights) **[CPU]**
LightMask = falloff·spot,  forced 0 if DLU[9].w ≠ 0 and dot(ToLight, DLU[5].xyz) < |DLU[9].w|    // DI2 near cut
```
The two DI2 extras are **[CPU]** in meaning: `DLU[9].xyz` stretches the cone along an axis, and `DLU[9].w` is a near
plane along the spot axis. A plain UE point or spot light would have `DLU[9] = 0`.

### 3.2 Shadow terms (`LightAttenuation` is stored square-rooted: `att = t8²`, stock)
Radial lights, with ShadowedBits (`DLU[2].x`) set:
```
Static     = 1 + Σ(ShadowMapChannelMask)·(dot(PrecomputedShadow, ShadowMapChannelMask) − 1)
Surface    = att.z·Static
Trans      = (model 7 | 8) ? Surface : att.w·Static          // DI2: hair and cloth use the surface shadow
Thickness  = att.w                                           // SubsurfaceProfile transmission only
```
Without ShadowedBits: `Surface = SSAO (t7.x)`, `Trans = 1`, `Thickness = 1` (stock).

Directional (p11520): `fade = sat(depth·DLU[1].x + DLU[1].y)²`. Then
`Surface = att.z·min(Static, lerp(att.x, 1, fade))` and `Trans = (hair|cloth) ? Surface : att.z·lerp(att.y, Static, fade)`.
This differs from stock in the min() and the missing `min(…, att.w)`. The pixel is discarded when
`max(att.x, att.y, GBufferE.x) = 0`.

### 3.3 Area-light geometry (stock 4.27 capsule, DI2 tweaks in bold)
```
P0,P1 = ToLight ∓ ½·SourceLength(DLU[7].w)·Tangent(DLU[6].xyz)  − Direction·max(0, DLU[9].w)
DistBiasSqr = (asint(DLU[2].y) == 2) ? 120000 : 1              // DI2 [CPU] (stock: 1)
LineIrradiance / point falloff, SphereHorizonCosWrap with SourceRadius (DLU[6].w), ClosestPointLineToRay, R = max(R, View[223].y)
SphereSinAlpha = sat(SourceRadius·InvDist·(1 − R²)),  SphereSinAlphaSoft = sat(SoftSourceRadius(DLU[7].z)·InvDist)
```
For a directional light, `ToLight = Direction` and the same code runs with the sun's angular radius.

**DI2 near-light un-shadow** (radial only, asm 263–270):
`Surface, Trans = sat(shadow + 1 − sat(|ToLight| − (SourceRadius + SoftSourceRadius + |ContactShadowLength|)))`.

### 3.4 Falloff
Inverse-squared: `Falloff = 1/(DistSqr + DistBiasSqr)` (line light: LineIrradiance), multiplied into every lighting
term (Diffuse, Specular, Transmission). Non-inverse-squared: `Falloff = 1` and the exponent falloff is in LightMask (stock).

### 3.5 Accumulation (asm 1790–1850)
```
Spec      *= SpecularScale(DLU[5].w) · 2·S'
if cloth: k = sat(1 + SSAO − Cloth);  Spec *= k;  Trans *= k                // DI2
if View[225].y > 0 (Fury):  T = flag ? 1 : lerp(lerp(View[226],View[227],v), lerp(View[228],View[229],v), sqrt(sat((depth − View[230].y)/View[230].x)))
                            Spec = lerp(Spec, lum(Spec)·T, View[225].y)        // v = pixel.y / height
LC = LightColor(DLU[4].xyz) · LightMask
Out.rgb = (Diffuse·Surface + Trans·TransShadow)·LC + Spec·Surface·LC
Out.a   = (model 5|9 and not checkerboard) ? lum(Diffuse·Surface·LC) + lum(Trans·TransShadow·LC) : 0     // stock SSS split
Out    *= View.PreExposure (View[134].y)
```

### 3.6 Directional contact shadows (DI2; p11520 asm ~90–330)
An 8-step screen-space ray (UE's ShadowRayCast pattern) runs for directional lights. It is enabled per light by
ShadowedBits > 1, `|ContactShadowLength| > 0` and `DLU[10].x` **[CPU]**. Per-material parameters `(thickness scale, length, normal offset)`:
`(3, 7, 0.1)` for SSP/Eye/Hair/Cloth, `(12, 7, 0.1)` if GBufferA.w bit 0, else `(1, 18, 0.75)`.
The ray starts at `WorldPos + Nsel·(1 − sat(Nsel·L)^0.05)·offset`, where `Nsel = CustomData.xyz·2−1` for models 1, 7, 12
and the GBuffer normal otherwise.

A hit occludes 100%, or 79% if the hit pixel is TwoSidedFoliage or SubsurfaceDerived. A hit pixel with stencil bit 4 does
not occlude. The occlusion also fades near the screen edge.

Result: `Surface *= c`; for foliage `Surface *= min(1, 1 + c − sat(2·dot(Nsel,L)))`; and
`Trans *= min(1, 1 + c − sat(2·dot(Nsel,L)))`. Godot has its own contact shadows, so this is for reference only.

---------------------------------------------------------------------------------------------------------------------

## 4. BxDFs per shading model (p1, `switch` at asm 271)

Common inputs: `NoL` = the saturated (wrapped) NoL from §3.3, `NoV = min(1, |dot(N,V)| + 1e-5)`. `NoH`, `VoH` come from
SphereMaxNoH (with Newton iteration, except Eye). For punctual lights they are the plain H-vector dots.
`R = max(GBuffer roughness, View.MinRoughness View[223].y)`.

Helpers (all stock 4.27 except where marked):
```
D_GGX(a2, NoH)          = a2 / (π·((NoH·a2 − NoH)·NoH + 1)²)
Vis_SJA(a2, NoV, NoL)   = 0.5 / (NoL·(NoV·(1−a)+a) + NoV·(NoL·(1−a)+a)),  a = sqrt(a2)
F_Schlick(F0, VoH)      = sat(50·F0.g)·Fc + (1−Fc)·F0,  Fc = pow5(1 − VoH)
Energy(a2, VoH)         = EnergyNormalization (sphere: New_a2 with sqrtFast; line: tan from LineCosSubtended); 1 for punctual
a2' (soft source)       = sat(a2 + SinAlphaSoft²/(VoH·3.6 + 0.4))   when SinAlphaSoft > 0
```

### 4.1 DefaultLit (cases 1, 10, 11; asm 272–416): stock
```
Diffuse  = NoL·DiffuseColor/π
Specular = NoL·D_GGX(a2', NoH)·Energy·Vis_SJA(a2', NoV, NoL)·F_Schlick(SpecularColor, VoH),   a2 = R⁴
```
The only differences come from §2.3 (F0) and §3.5 (2·S').

### 4.2 Subsurface (2) and DI2 SubsurfaceDerived (12) (asm 417–577)
DefaultLit, plus:
```
SC, Op   = model 2:  CustomData.rgb², CustomData.a          (stock ExtractSubsurfaceColor)
           model 12: sat(m·BaseColor),  raw CustomData.a     (DI2: DiffuseColor = BaseColor·(1−m), metal 0)
InScatter = pow(sat(dot(L, −V)), 12) · lerp(3, 0.1, Op)
Wrap      = pow(sat(dot(N,L)·(2/3) + 1/3), 1.5) · (5/3)                       // UE5's wrapped diffuse, not 4.27's N·H
BackScatter = lerp(1, Wrap, Op) / (2π)                                        // GBufferAO = 1
Transmission = SC · lerp(BackScatter, 1, InScatter)
```

### 4.3 PreintegratedSkin (3; asm 578–724): stock
DefaultLit + `Transmission = SC · PreIntegratedBRDF(sat(dot(N,L)·0.5+0.5), 1 − Op).rgb` (View resource 48, `t0`).

### 4.4 ClearCoat (4; asm 725–962)
Present (236 instructions). Not decoded: no character material uses it.

### 4.5 SubsurfaceProfile (5; asm 963–1159): DI2 dual-lobe skin  ← Dani's hands/arms, every zombie's skin
```
mix = GBufferB.x                     (M_Skin "Oil Layer")
Op  = CustomData.a                   (SSS opacity)
s   = sat(10·Op)
rA  = lerp(1, max(min(R², 1), 0.02), s)          // sharp "oil" lobe: roughness R²
rB  = lerp(1, max(sat(R),   0.02), s)            // base lobe: roughness R
rV  = lerp(rB, rA, mix)                          // visibility roughness
F   = sat(50·F0.g)·Fc + (1 − Fc)·F0.r,  F0 = SpecularColor (= 0.028; × !checker with checkerboard SSS)   // scalar
Diffuse  = NoL · DiffuseColor/π · FdV · FdL                                      // Diffuse_Burley
           FD90 = 0.5 + 2·VoH²·R,  FdV = 1 + (FD90−1)·pow5(1−NoV),  FdL = 1 + (FD90−1)·pow5(1−NoL)
Specular = NoL · F · Vis_SJA(rV⁴, NoV, NoL) · ( mix·D_GGX(rA⁴', NoH)·EnergyA + (1 − F·mix)²·D_GGX(rB⁴', NoH)·EnergyB )
Transmission = 0                     (without USE_TRANSMISSION)
```
Each lobe gets its own soft-source a2' and sphere/line energy. With `R = 0.5` the base lobe has α² = 0.0625 and the oil
lobe α² = 0.0039. The profile's `Roughness0/Roughness1/LobeMix` are not read anywhere (no profile-texture access in
case 5 except the transmission LUT).

**With USE_TRANSMISSION** (p145, case grows 195 → 228 instructions, asm ~1150–1190):
```
id   = round(CustomData.x·255)                 SSProfiles texture t9, row id
g, η = texel(3, id).z, texel(3, id).w          ScatteringDistribution, 1/IOR
col  = (abs(texel(4, id).w) < 0.01 ? 66 : 34)  Burley vs separable transmission table
Profile = t9.SampleLevel(((1 − Thickness)·31 + col + 0.5)/W, (id + 0.5)/H).rgb      // Thickness = att.w²
RefracV = refract(V, −N, η)  (0 if TIR)
Transmission = Profile · 0.5·(1 − g²) / max(1e-5, (1 − g·dot(−L, RefracV))²)         // ApproximateHG, stock
```

### 4.6 TwoSidedFoliage (6; asm 1160–1315)
DefaultLit with **Specular × sat(10·dot(N,V))** (DI2). Plus
`Transmission = SC · sat((0.5 − dot(N,L))/2.25) · D_GGX(0.36, sat(−dot(V,L)))` (stock).

### 4.7 Hair (7; asm 1316–1469): stock UE 4.27 HairShading + DI2 card term
`N` = GBufferA = the hair tangent. `S'` from §2.2. `BC` = BaseColor. `Mt` = GBufferB.x.
`Nc = normalize(CustomData.xyz·2−1)` is the card's vertex normal. `Shadow` = transmission shadow (= surface shadow, §3.2).
Deferred defaults: no backlit, separable R, legacy absorption, no multiple-scattering LUT.
```
r  = clamp(R, 1/255, 1);  sL = dot(N,L);  sV = dot(N,V);  VoL = dot(V,L)
cosD = cos(0.5·|asinFast(sV) − asinFast(sL)|)        acosFast(x) = (−0.156583·|x| + π/2)·sqrt(1−|x|), mirrored for x<0
Lp = L − sL·N;  Vp = V − sV·N;  cosPhi = dot(Lp,Vp)·rsqrt(dot(Lp,Lp)·dot(Vp,Vp) + 1e-4);  cHP = sqrt(sat(0.5 + 0.5·cosPhi))
g(B,θ) = exp(−0.5·θ²/B²)/(sqrt(2π)·B);   Fh(x) = 0.046521 + 0.953479·pow5(1 − x)
R   : shiftR = 2·sa·(ca·cHP·sqrt(1 − sV²) + sa·sV),  sa = sin(−0.07), ca = cos(−0.07)
      S  = g(r²·√2·cHP, sL + sV − shiftR) · 0.25·cHP · Fh(sqrt(sat(0.5 + 0.5·VoL))) · 2·S'
TT  : a = 1/(1.19/cosD + 0.36·cosD);  h = cHP·(1 + a·(0.6 − 0.8·cosPhi));  f = Fh(cosD·sqrt(sat(1 − h²)))
      S += g(0.5·r², sL + sV − 0.035) · exp(−3.65·cosPhi − 3.98) · (1−f)² · pow(BC, 0.5·sqrt(1 − (h·a)²)/cosD)
TRT : f = Fh(0.5·cosD)
      S += g(2·r², sL + sV − 0.14) · exp(17·cosPhi − 16.78) · (1−f)²·f · pow(BC, 0.8/cosD)
KK  : Nf = normalize(V − N·dot(V,N))
      S += sqrt(BC) · (1/π)·lerp(sat((dot(Nf,L) + 1)/4), 1 − |sL|, 0.33)·Mt · pow(BC/lum(BC), 1 − Shadow)
S = max(S, 0)
Transmission = S · (1 − sat(−dot(Nc, L)))⁴        // DI2 (the only change)
Diffuse = Specular = 0
```

### 4.8 Cloth (8; asm 1470–1649): DI2  ← Dani's sleeves/gloves/band and zombie clothing
```
C    = sat(raw CustomData.a),  Fuzz = sat(raw CustomData.rgb)      (linear; M_Clothing writes the sheen colour directly)
m    = min(GBufferB.x, 0.99),  metal = GBufferB.x·(1 − C),  F0 = lerp(0.04, BC', metal)    (§2.3)
DiffuseColor = BC·(1 − m·C)·(1 − metal)
TransColor   = sat(C·m·BC)
Spec1 = NoL·D_GGX(a2', NoH)·Energy·Vis_SJA(a2', NoV, NoL)·F_Schlick(F0, VoH)              (as DefaultLit)
αc    = max(R, 0.08)
Dc    = (2 + 1/αc)·(1 − NoH²)^(0.5/αc) / (2π)                         // Charlie sheen (stock 4.27: D_InvGGX)
Vc    = 1 / (4·(NoL + NoV − NoL·NoV))                                 // = UE's Vis_Cloth
Fz    = min(1, 50·Fuzz.g)·Fc + (1 − Fc)·Fuzz
Specular = lerp(Spec1, NoL·Dc·Vc·Fz, C)
Diffuse  = NoL·DiffuseColor/π · (1 − C·NoL·Vc·Fz)                     // DI2 energy loss
Transmission = TransColor · (1/(2π) + 2.522535·pow(sat(−dot(V,L)), 12)) · (1 − sat(−dot(N,L)))³          // DI2
```
`2.522535 = 3·(1 − 1/(2π))`. This is UE's Subsurface back-scatter `lerp(1/(2π), 1, InScatter)` with `Opacity = 0`, so
`InScatter = 3·VoL¹²`. It is not multiplied by NoL: it lights the cloth fully at grazing angles and fades as the light goes
behind (`(1−sat(−NoL))³`). It is shadowed by the **surface** shadow and scaled by `sat(1 + SSAO − C)` (§3.5).

**Meaning of ClothTranslucency:** where `Cloth = 1`, a fraction `m = ClothTranslucency` (0.25 on Dani) of the base colour
moves from the Lambert diffuse into this wrap/forward-scatter term. Metallic is 0 there.

### 4.9 Eye (9; asm 1650–1784): stock EyeBxDF (non-IRIS_NORMAL)
```
Ni = OctahedronToUnitVector(CustomData.yz·2 − 1);  mask = 1 − CustomData.a;  dist = GBufferB.x
Nc = normalize(lerp(Ni, −N, mask·dist))
F0 = 0.08·S'   (eye writes Specular 1.0 → S' = 0.496 → F0 = 0.0397);   F = Fc + (1 − Fc)·F0     (SphereMaxNoH without Newton)
Specular = NoL·D_GGX(a2', NoH)·Energy·Vis_SJA(a2', NoV, NoL)·F            (× 2·S' in §3.5)
iris = sat(dot(Ni,L));  p = lerp(12, 1, iris);  caustic = 0.8 + 0.2·(p+1)·pow(sat(dot(Nc,L)), p)
Transmission = DiffuseColor/π · lerp(NoL, iris·caustic, mask) · (1 − F)            // F at VoH, not NoV
Diffuse = 0
```

### 4.10 default (model 0, 13–15): no light.

---------------------------------------------------------------------------------------------------------------------

## 5. Simple lights (tiled, FTiledDeferredLightingCS10 Global 1515)
DI2 simple lights (no shadows, no BxDF switch) use: `Diffuse = DiffuseColor/π`.
`Specular = D_GGX(max(R, 0.04)⁴, NoH)·0.25·SpecularColor` (Vis_Implicit, F_None), with `SpecularColor = lerp(0.04, desat(BC), B.x)`.
Both are `× NoL·LightColor·mask·SSAO`. Models 5 and 9 use 0.028 with the checkerboard adjust (asm 732, 1310), but no
model gets the S' multiplier or the custom BxDFs. Used for cheap dynamic lights **[CPU]**.

---------------------------------------------------------------------------------------------------------------------

## 6. Reflection / sky lighting pass (FReflectionEnvironmentSkyLightingPS, 128 permutations, Global 948–1075)
Decoded on p0 (Global 1065, minimal) and p255 (Global 1045, captures + sky). This is the ambient specular only, but it
fixes what Godot's `SPECULAR` output should represent.
- **Same GBuffer decode as §2:** S', `F0 = lerp(0.04 | 0.028, BC', metal)`, checkerboard adjust. Hair (7) and unlit are
  skipped (hair has its own FHairEnvironmentLightingPS).
- `EnvBRDF = SpecularColor·A + sat(50·SpecularColor.g)·B`, with `(A,B) = PreIntegratedGF(|NoV|, R)` (stock).
- **Reflection × 2·S' / (1 + View[225].y·(max(View[225].z, 0) − 1))**: the same intensity multiplier as §3.5, with the
  Fury compensation.
- **SubsurfaceProfile oil lobe** reuses the clear-coat path: `mix = GBufferB.x`,
  `F2 = 0.028·A2 + B2` with `(A2,B2) = PreIntegratedGF(|NoV|, R₂)`, and `EnvBRDF = lerp(EnvBRDF, mix·F2, mix)`.
  In p255 the oil lobe samples the captures and sky a second time at roughness `R₂ = R²` (mip from `R₂`).
  In p0, `R₂ = CustomData.y` (= 0 for M_Skin). Which permutation runs in game is **[CPU]**.
- **Cloth:** `R_env = lerp(R, 0.1, sat((C − 0.9)·10))`, reflection × `(1 − |NoV|·C)`.
- Model 4 (clear coat) keeps a stock-looking coat path (0.04 coat F0, 0.9 / 1.111 / −0.78 base-colour remaps). Not decoded further.

---------------------------------------------------------------------------------------------------------------------

## 7. Subsurface scattering (post-process) set-up

### 7.1 What the light pass hands over
For models 5 and 9 with `View.bSubsurfacePostprocessEnabled`, BaseColor is replaced by 1 before lighting, so SceneColor
holds `diffuse·1 + specular`. With `View.bCheckerboardSubsurfaceProfileRendering`, alternate pixels hold only diffuse
(BaseColor = checker) or only specular (SpecularColor and S' × !checker). Without checkerboarding, SceneColor.a
accumulates `lum(diffuse + transmission)` per light (§3.5). All of this is stock 4.27.

### 7.2 Passes (PostProcessSubsurface.usf, stock structure)
`FSubsurfaceIndirectDispatchSetupCS` (16 perms) classifies tiles. `FSubsurfaceIndirectDispatchCS` (192 perms; Burley and
separable kernels, quality/half-res variants) blurs. `FSubsurfaceRecombinePS` (48 perms) recombines.
Recombine (Global 635, checkerboard variant, read in full):
```
only model 5 | 9 pixels (others copy SceneColor)
BaseColor = §2.3 decode (cloth/12 variants included)
PixelRadius = (SSSScaleX($Globals cb0[27].x)/SceneDepth)·1024 · texel(33, id).w · 3 / (0.5·View[35].z)
Lerp = sat(PixelRadius − 4) · sat(10·CustomData.a)
SSS  = blurred.rgb / max(blurred.a, 1e-5)
(diffuse, specular) = checkerboard reconstruction from the 4-neighbour cross (luminance-gradient pick)
Out  = lerp(diffuse, SSS, texel(0, id).rgb · Lerp) · BaseColor + specular          // texel 0 = profile SubsurfaceColor
```
Stock 4.27 (ComputeFullResLerp + recombine). The blur kernels in the dispatch CS were not diffed against stock.

### 7.3 Profiles used by the characters (asset values; only overridden fields are serialised)
| Profile | Used by | ScatterRadius | SubsurfaceColor | FalloffColor | Burley | MFP distance | WorldUnitScale |
|---|---|---|---|---|---|---|---|
| `SSP_DefaultLightSkin` | zombie M_Skin, Dani band | **1.5** | (0.915, 0.75165, 0.6039) | (1, 0.433, 0.37) | **false** (default) → **separable** | 2.6748 (default) | 0.1 (default) |
| `SSP_DefaultLightSkinFP` | Dani FP hands/arms | 0.3 | same | same | **true** → **Burley** | **0.25** | **0.2** |

**Engine defaults for the unset fields, read from the exe.** 0x143a50db0 builds a default `FSubsurfaceProfileStruct` on
the stack and copies its 0x8c bytes into a profile slot (it looks like `FSubsurfaceProfileTexture::RemoveProfile`). The
struct is 0x8c bytes, laid out in UE 4.27 member order:

| Offset | Field | Default | Source constant |
|---|---|---|---|
| 0x00 | SurfaceAlbedo | (0.91058, 0.338275, 0.2718, 1) | 0x145d9c6b0 |
| 0x10 | MeanFreePathColor | (1, 0.0889637, 0.0720951, 1) | 0x145d9c6a0 |
| 0x20 | MeanFreePathDistance | 2.6748 | 0x145d9c660 |
| 0x24 | WorldUnitScale | 0.1 | 0x144bc3118 |
| 0x28 | **bEnableBurley** | **0 (false)** | immediate `mov byte [rsp+0x28], 0` |
| 0x2c | ScatterRadius | 1.2 | 0x145dfa780 |
| 0x30 | SubsurfaceColor | (0.48, 0.41, 0.28, 1) | 0x145dfa780/790 |
| 0x40 | FalloffColor | (1, 0.37, 0.3, 1) | 0x145dfa790 |
| 0x50 | BoundaryColorBleed | (1, 1, 1, 1) | 0x145800760 |
| 0x60 | ExtinctionScale | 1 | immediate |
| 0x64 | NormalScale | 0.08 | 0x144bcf010 |
| 0x68 | ScatteringDistribution (`g`, §4.5) | 0.93 | 0x145dfa6e0 |
| 0x6c | IOR (`η = 1/1.55`, §4.5) | 1.55 | 0x145dfa7a0 |
| 0x70 / 0x74 / 0x78 | Roughness0 / Roughness1 / LobeMix (**unused by DI2's skin BxDF**, §4.5) | 0.75 / 1.3 / 0.85 | 0x145dfa7a4 |
| 0x7c | TransmissionTintColor | (1, 1, 1, 1) | 0x144bbe880 |

So **zombie skin uses the separable SSS kernel** (ScatterRadius 1.5 cm, FalloffColor (1, 0.433, 0.37)), and **Dani's FP
skin uses Burley** (mean free path 0.25 × MeanFreePathColor (1, 0.0890, 0.0721), WorldUnitScale 0.2, SurfaceAlbedo
default). The kernel construction itself (`ComputeMirroredSSSKernel` / Burley parameter fit, CPU, into the SSProfiles
texture) was not traced.

---------------------------------------------------------------------------------------------------------------------

## 8. Not decoded / open
1. **ClearCoat (4)** BxDF and the **rect-light (LTC) path** (shape 2: `RectGGXApproxLTC` for the specular, Global 1979 p14).
   No character uses clear coat, and Godot has no rect lights.
2. **[CPU]**:
   - `DLU[2].y == 2` (DistBiasSqr 120000), `DLU[9]` (cone shaping, near cut), `DLU[10].x` (contact-shadow gate);
   - which permutation each light gets;
   - which reflection-pass permutation runs (oil lobe roughness R² vs CustomData.y).
3. SubsurfaceDerived (12): which materials use it.
4. The Burley/separable blur kernels (FSubsurfaceIndirectDispatchCS) were not compared with stock 4.27 line by line, and
   the CPU kernel/profile-texture build was not traced (§7.3).

---------------------------------------------------------------------------------------------------------------------

## 9. Port reference: punctual light() snippets (Godot 4.7)
Godot's light() gets `LIGHT_COLOR·ATTENUATION` (π included, shadow included). It multiplies `DIFFUSE_LIGHT` by
`ALBEDO·(1 − METALLIC)` afterwards, and `SPECULAR_AMOUNT` ≈ the light's SpecularScale (recon/DANI.md §4.5). For a punctual
light, Energy = 1 and NoH/VoH come from `H`. `lc = LIGHT_COLOR·ATTENUATION`. These snippets are reference code; the owning
sessions integrate them.
```glsl
float D_GGX(float a2, float NoH) { float d = (NoH * a2 - NoH) * NoH + 1.0; return a2 / (PI * d * d); }
float Vis_SJA(float a2, float NoV, float NoL) { float a = sqrt(a2); return 0.5 / (NoL * (NoV * (1.0 - a) + a) + NoV * (NoL * (1.0 - a) + a)); }
float di2_spec_mul(float S) { return clamp(min(round(255.0 * min(0.5, S)), 126.0) * (512.0 / 65025.0), 0.0, 1.0); }  // 2*S'

// MSM_SubsurfaceProfile (§4.5). oil = GBufferB.x, op = SSS opacity, R = roughness. METALLIC must be 0, F0 = 0.028.
void di2_skin(float R, float oil, float op, float NoL, float NoV, float NoH, float VoH, out float diff, out float spec) {
	float s = clamp(10.0 * op, 0.0, 1.0);
	float rA = mix(1.0, max(min(R * R, 1.0), 0.02), s), rB = mix(1.0, max(clamp(R, 0.0, 1.0), 0.02), s);
	float rV = mix(rB, rA, oil);
	float fc = pow(1.0 - VoH, 5.0), F = fc + (1.0 - fc) * 0.028;               // sat(50*0.028) = 1
	float k = 1.0 - F * oil;
	spec = NoL * F * Vis_SJA(rV * rV * rV * rV, NoV, NoL)
	     * (oil * D_GGX(rA * rA * rA * rA, NoH) + k * k * D_GGX(rB * rB * rB * rB, NoH));
	float fd90 = 0.5 + 2.0 * VoH * VoH * R;
	diff = NoL / PI * (1.0 + (fd90 - 1.0) * pow(1.0 - NoV, 5.0)) * (1.0 + (fd90 - 1.0) * pow(1.0 - NoL, 5.0));
}
// MSM_Cloth (§4.8). Bx = GBufferB.x (min 0.99, lerp(Metallic, ClothTranslucency, C)), C = Cloth, fuzz linear.
// Godot: ALBEDO = BC, METALLIC = Bx*(1-C); the extra diffuse factor (1 - m*C) and the transmission go into DIFFUSE_LIGHT
// divided by (1 - METALLIC) because Godot multiplies by ALBEDO*(1-METALLIC).
void di2_cloth(vec3 BC, float Bx, float C, vec3 fuzz, float R, vec3 N, vec3 V, vec3 L, out vec3 diff, out vec3 spec) {
	float m = min(Bx, 0.99), metal = Bx * (1.0 - C);
	float NoLr = dot(N, L), NoL = clamp(NoLr, 0.0, 1.0), NoV = clamp(abs(dot(N, V)) + 1e-5, 0.0, 1.0);
	vec3 H = normalize(V + L); float NoH = clamp(dot(N, H), 0.0, 1.0), VoH = clamp(dot(V, H), 0.0, 1.0);
	vec3 f0 = mix(vec3(0.04), BC * (1.0 - m * C), metal);
	float fc = pow(1.0 - VoH, 5.0), a2 = R * R * R * R;
	vec3 spec1 = NoL * D_GGX(a2, NoH) * Vis_SJA(a2, NoV, NoL) * (clamp(50.0 * f0.g, 0.0, 1.0) * fc + (1.0 - fc) * f0);
	float ac = max(R, 0.08);
	float Dc = (2.0 + 1.0 / ac) * pow(max(1.0 - NoH * NoH, 0.0), 0.5 / ac) * (0.5 / PI);
	float Vc = 1.0 / (4.0 * (NoL + NoV - NoL * NoV));
	vec3 Fz = min(1.0, 50.0 * fuzz.g) * fc + (1.0 - fc) * fuzz;
	spec = mix(spec1, NoL * Dc * Vc * Fz, C);
	vec3 trans = clamp(C * m * BC, 0.0, 1.0) * (0.159155 + 2.522535 * pow(clamp(-dot(V, L), 0.0, 1.0), 12.0))
	           * pow(1.0 - clamp(-NoLr, 0.0, 1.0), 3.0);
	// DI2 DiffuseColor = BC*(1-m*C)*(1-metal); Godot applies BC*(1-metal):
	diff = NoL / PI * (1.0 - m * C) * (1.0 - C * NoL * Vc * Fz) + trans / max(BC * (1.0 - metal), vec3(1e-4));
}
```
- Multiply `spec` by `di2_spec_mul(S)·SPECULAR_AMOUNT` (cloth: S = 0.5 → 0.992; skin: the material's 0.5·O^pow).
- Cloth also has `sat(1 + SSAO − C)` on specular and transmission. Godot's light() can't read SSAO, so it is 1 when unoccluded.
- **Ambient (fragment):** `SPECULAR` should give Godot's dielectric F0 (0.16·SPECULAR²): **0.41833 for skin (F0 0.028),
  0.5 for cloth/DefaultLit (0.04)**, independent of the material Specular. DI2's `2·S'` ambient multiplier and the skin oil
  lobe (§6) have no direct Godot equivalent. Godot's CLEARCOAT = oil, CLEARCOAT_ROUGHNESS ≈ R² is the closest ambient
  analogue (it does not affect direct light when light() is custom).
