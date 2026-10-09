"""Annotate a decompiled material shader with DI2 names (local analysis aid).

  python annotate.py <material json from shadermaps.exe> <resource index (0 Low,1 High,2 Medium)> <lib> <shader index>
      [<master material json (di2x json) for ReferencedTextures>]
  -> extracted/shaders/annotated/<lib>_<index>.hlsl + .slots.txt

Names: t-registers via the shader's resource table (decompile.srt) and the material's UniformTextureParameters
(unnamed entries -> master ReferencedTextures[TextureIndex]); Material cbuffer slots via the uniform expression set:
VectorExpressions[i] = UniformVectorPreshaders[i], ScalarExpressions[k] = UniformScalarPreshaders[k] packed 4 per
float4 after the vector expressions; DI2 puts the VT uniforms before both (see run()). Preshader programs are decoded with the opcode table below, which is inferred
from DI2's data (argument sizes and stack balance), NOT from engine source: 2 Constant(float4), 3 ScalarParameter(u16),
4 VectorParameter(u16), 35 ComponentSwizzle(u8 n, u8 x4), 36 AppendVector(u8), 41 RVT uniform (24 bytes);
binary 5 Add 6 Sub 7 Mul 8 Div; unary 20 Sqrt? 22 Length? 24 Saturate? (names for the unary ones unverified).
"""
import base64, json, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decompile

ROOT = decompile.ROOT
OPS = {5: "+", 6: "-", 7: "*", 8: "/"}
UN = {20: "op20_sqrt?", 22: "op22_length?", 24: "op24_saturate?"}


def preshader(seg, sp, vp):
    st, p = [], 0
    while p < len(seg):
        op = seg[p]; p += 1
        if op == 2:
            v = struct.unpack_from("<4f", seg, p); p += 16
            st.append("(" + ",".join("%g" % x for x in v) + ")")
        elif op == 3:
            i = struct.unpack_from("<H", seg, p)[0]; p += 2
            st.append("S'%s'" % sp[i])
        elif op == 4:
            i = struct.unpack_from("<H", seg, p)[0]; p += 2
            st.append("V'%s'" % vp[i])
        elif op == 35:
            n = seg[p]; c = seg[p + 1:p + 5]; p += 5
            st.append(st.pop() + "." + "".join("xyzw"[k] for k in c[:n]))
        elif op == 36:
            n = seg[p]; p += 1
            b = st.pop(); a = st.pop(); st.append("append(%s,%s)" % (a, b))
        elif op == 41:
            p += 24; st.append("RVTUniform")
        elif op in OPS:
            b = st.pop(); a = st.pop(); st.append("(%s %s %s)" % (a, OPS[op], b))
        elif op in UN:
            st.append("%s(%s)" % (UN[op], st.pop()))
        else:
            st.append("op%d(%s)" % (op, st.pop() if st else ""))
    return " ; ".join(st)


MPC = {"DF8AB2E2-4D459C16-2DE80E9B-51C88CA5": "DIShared/Core/Materials/MPC_CharacterGameWideParams",
       "F2930FDF-4897E6BB-D3AD1E9D-9455DAB1": "DIShared/Core/Materials/MPC_GameWideParams"}


def mpc_slots(guid):
    """MaterialParameterCollection buffer: scalars 4 per float4 in ScalarParameters order, then one float4 per vector."""
    path = os.path.join(ROOT, "extracted", "json", "DeadIsland", "Content", MPC[guid] + ".json")
    p = json.load(open(path))[0]["Properties"]
    sc, vc = p.get("ScalarParameters", []), p.get("VectorParameters", [])
    out = {}
    for i, x in enumerate(sc):
        out[(i // 4, "xyzw"[i % 4])] = "%s=%g" % (x["ParameterName"], x.get("DefaultValue", 0.0))
    base = (len(sc) + 3) // 4
    for i, x in enumerate(vc):
        v = x.get("DefaultValue", {})
        out[(base + i, None)] = "%s=(%g,%g,%g,%g)" % (x["ParameterName"], v.get("R", 0), v.get("G", 0), v.get("B", 0), v.get("A", 0))
    return MPC[guid].split("/")[-1], out


def run(mat_json, ri, lib, idx, master_json=None):
    d = json.load(open(mat_json))
    sm = d["resources"][ri]["LoadedShaderMap"]
    ues = sm["Content"]["MaterialCompilationOutput"]["UniformExpressionSet"]
    data = base64.b64decode(ues["UniformPreshaderData"]["Data"])
    sp = [x["ParameterName"] for x in ues["UniformScalarParameters"]]
    vp = [x["ParameterName"] for x in ues["UniformVectorParameters"]]
    ref = []
    if master_json:
        for e in json.load(open(master_json)):
            if e.get("Type") == "Material":
                ref = [(t or {}).get("ObjectName", "None") for t in e["Properties"]["CachedExpressionData"]["ReferencedTextures"]]
    tex = []
    for t in ues["UniformTextureParameters"][0]:
        nm = t["ParameterName"]
        dflt = ref[t["TextureIndex"]] if t["TextureIndex"] < len(ref) else "tex#%d" % t["TextureIndex"]
        tex.append((nm or "const") + " [" + dflt.replace("Texture2D'", "").rstrip("'") + "]")
    nvec = len(ues["UniformVectorPreshaders"])
    nsc = (len(ues["UniformScalarPreshaders"]) + 3) // 4
    # DI2's Material uniform buffer puts the virtual-texture uniforms (VTPackedPageTableUniform/VTPackedUniform)
    # first: numeric size = first resource offset / 16 = vt + vectors + scalars (checked against shader usage:
    # noise speeds x View time, Detail Tiling x UV).
    lay = ues["UniformBufferLayoutInitializer"]
    first_res = min(r["MemberOffset"] for r in lay["Resources"]) if lay.get("Resources") else lay["ConstantBufferSize"]
    vt = first_res // 16 - nvec - nsc
    slots = {}
    for i, p in enumerate(ues["UniformVectorPreshaders"]):
        slots[(vt + i, None)] = "V%d=%s" % (i, preshader(data[p["OpcodeOffset"]:p["OpcodeOffset"] + p["OpcodeSize"]], sp, vp))
    for k, p in enumerate(ues["UniformScalarPreshaders"]):
        slots[(vt + nvec + k // 4, "xyzw"[k % 4])] = "S%d=%s" % (k, preshader(data[p["OpcodeOffset"]:p["OpcodeOffset"] + p["OpcodeSize"]], sp, vp))
    for i in range(vt):
        slots[(i, None)] = "VT uniform %d" % i
    code = open(os.path.join(ROOT, "extracted", "shaders", lib, f"{idx:06d}.bin"), "rb").read()
    rt = decompile.srt(code)
    _, meta = decompile.split(code)
    ubs = meta.get("uniform_buffers", {})
    matcb = [k for k, v in ubs.items() if v == "Material"]
    matcb = int(matcb[0][2:]) if matcb else -1
    tnames, snames = {}, {}
    for k in ("texture", "srv"):
        for e in rt[k]:
            ub = ubs.get("cb%d" % e["ub"], str(e["ub"]))
            if ub == "Material" and e["resource"] // 2 < len(tex) and e["resource"] % 2 == 0:
                tnames[e["bind"]] = "Texture2D_%d %s" % (e["resource"] // 2, tex[e["resource"] // 2])
            else:
                tnames[e["bind"]] = "%s.res%d" % (ub, e["resource"])
    for e in rt["sampler"]:
        ub = ubs.get("cb%d" % e["ub"], str(e["ub"]))
        snames[e["bind"]] = "%s.res%d" % (ub, e["resource"]) + (" (Texture2D_%dSampler)" % (e["resource"] // 2) if ub == "Material" else "")
    stems = [f for f in os.listdir(os.path.join(ROOT, "extracted", "shaders", "dis")) if f.startswith(f"{lib}_{idx:06d}") and f.endswith(".hlsl")]
    src = open(os.path.join(ROOT, "extracted", "shaders", "dis", stems[0])).read()

    def sub(m):
        i = int(m.group(1)); sw = m.group(2) or ""
        names = []
        if (i, None) in slots:
            names.append(slots[(i, None)])
        else:
            for c in dict.fromkeys(sw or "xyzw"):
                if (i, c) in slots:
                    names.append(c + ":" + slots[(i, c)])
        return m.group(0) + ("/*" + " | ".join(names) + "*/" if names else "")
    out = re.sub(r"cb%d\[(\d+)\](?:\.([xyzw]+))?" % matcb, sub, src)
    mpcs = []
    for n, guid in enumerate(ues.get("ParameterCollections") or []):
        cbk = [k for k, v in ubs.items() if v == "MaterialCollection%d" % n]
        if not cbk or guid not in MPC:
            continue
        name, ms = mpc_slots(guid)
        mpcs.append((cbk[0], name, ms))

        def msub(m, ms=ms, name=name):
            i = int(m.group(1)); sw = m.group(2) or ""
            if (i, None) in ms:
                return m.group(0) + "/*%s.%s*/" % (name, ms[(i, None)])
            nm = [c + ":" + ms[(i, c)] for c in dict.fromkeys(sw or "xyzw") if (i, c) in ms]
            return m.group(0) + ("/*" + " | ".join(nm) + "*/" if nm else "")
        out = re.sub(r"%s\[(\d+)\](?:\.([xyzw]+))?" % cbk[0], msub, out)
    out = re.sub(r"\bt(\d+)\.(Sample\w*|Load|GetDimensions)", lambda m: "t%s/*%s*/.%s" % (m.group(1), tnames.get(int(m.group(1)), "?"), m.group(2)), out)
    od = os.path.join(ROOT, "extracted", "shaders", "annotated")
    os.makedirs(od, exist_ok=True)
    base = os.path.join(od, stems[0][:-5])
    open(base + ".hlsl", "w").write(out)
    with open(base + ".slots.txt", "w") as f:
        f.write("uniform buffers: %s\n" % json.dumps(ubs))
        for b in sorted(tnames): f.write("t%d = %s\n" % (b, tnames[b]))
        for b in sorted(snames): f.write("s%d = %s\n" % (b, snames[b]))
        for (i, c), v in sorted(slots.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
            f.write("cb%d[%d]%s = %s\n" % (matcb, i, "." + c if c else "", v))
        for cbk, name, ms in mpcs:
            for (i, c), v in sorted(ms.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
                f.write("%s[%d]%s = %s.%s\n" % (cbk, i, "." + c if c else "", name, v))
    return base


if __name__ == "__main__":
    print(run(sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5] if len(sys.argv) > 5 else None))
