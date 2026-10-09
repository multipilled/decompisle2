"""Disassemble / decompile one shader dumped by shader_archive.py.

  python decompile.py <lib: Global|DeadIsland> <shader index> [label]
     -> extracted/shaders/dis/<lib>_<index>[_<label>].{dxbc,asm,hlsl,meta.json}

UE4.27 D3D11 shader code = UE resource-table header, the DXBC container, then optional data
{u8 key, u32 size, data}... + trailing u32 total size. Keys: 'p' FShaderCodePackedResourceCounts
{bGlobalUniformBufferUsed, NumSamplers, NumSRVs, NumCBs, NumUAVs}, 'u' TArray<FString> uniform buffer name per
constant-buffer slot ("" = loose $Globals / unnamed).
Disassembly: Windows SDK fxc /dumpbin. HLSL: 3Dmigoto cmd_Decompiler (tools/shaders/bin). Reflection is
stripped in DI2's shipping shaders, so constant buffers read as cbN[i]; names come from the 'u' table and the
frozen shader bindings (frozen.py).
"""
import json, os, struct, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FXC = r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\fxc.exe"
DEC = os.path.join(ROOT, "tools", "shaders", "bin", "cmd_Decompiler", "cmd_Decompiler.exe")


def split(code):
    k = code.find(b"DXBC")
    total = struct.unpack_from("<I", code, k + 24)[0]
    dxbc = code[k:k + total]
    tail = code[k + total:]
    opt = {}
    if len(tail) >= 4:
        size = struct.unpack_from("<I", tail, len(tail) - 4)[0]
        p = 0
        body = tail[:-4]
        while p + 5 <= len(body):
            key = chr(body[p]); n = struct.unpack_from("<I", body, p + 1)[0]
            opt[key] = body[p + 5:p + 5 + n]; p += 5 + n
    meta = {"header_bytes": k}
    if "p" in opt:
        g, ns, nsrv, ncb, nuav = opt["p"][:5]
        meta["packed"] = dict(global_ub=g, samplers=ns, srvs=nsrv, cbs=ncb, uavs=nuav)
    if "u" in opt:
        b = opt["u"]; n = struct.unpack_from("<i", b, 0)[0]; p = 4; names = []
        for _ in range(n):
            ln = struct.unpack_from("<i", b, p)[0]; p += 4
            names.append(b[p:p + ln].rstrip(b"\0").decode("latin1") if ln > 0 else ""); p += max(ln, 0)
        meta["uniform_buffers"] = {f"cb{i}": s for i, s in enumerate(names)}
    meta["optional_keys"] = sorted(opt)
    return dxbc, meta


def run(lib, idx, label=""):
    code = open(os.path.join(ROOT, "extracted", "shaders", lib, f"{idx:06d}.bin"), "rb").read()
    dxbc, meta = split(code)
    out = os.path.join(ROOT, "extracted", "shaders", "dis")
    os.makedirs(out, exist_ok=True)
    stem = os.path.join(out, f"{lib}_{idx:06d}" + (f"_{label}" if label else ""))
    open(stem + ".dxbc", "wb").write(dxbc)
    json.dump(meta, open(stem + ".meta.json", "w"), indent=1)
    subprocess.run([FXC, "/nologo", "/dumpbin", "/Fc", stem + ".asm", stem + ".dxbc"], capture_output=True)
    # cmd_Decompiler -D writes <file>.hlsl next to the input (stripped reflection -> cbN[] names).
    r = subprocess.run([DEC, "-D", stem + ".dxbc"], capture_output=True, text=True)
    if not os.path.exists(stem + ".hlsl"):
        print("decompiler:", r.stdout[-400:], r.stderr[-400:])
    return stem, meta


if __name__ == "__main__":
    stem, meta = run(sys.argv[1], int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "")
    print(stem, json.dumps(meta))


def srt(code):
    """UE4.27 FBaseShaderResourceTable + D3D11 TextureMap from the code header:
    u32 ResourceTableBits, TArray<u32> ShaderResourceViewMap, SamplerMap, UnorderedAccessViewMap,
    ResourceTableLayoutHashes, TextureMap. Map entries = UB << 24 | resource index << 8 | bind slot,
    token stream = per-UB start offsets, entries, 0xffffffff end."""
    p = 0
    bits = struct.unpack_from("<I", code, p)[0]; p += 4
    out = {"resource_table_bits": bits}
    for name in ("srv", "sampler", "uav", "layout_hashes", "texture"):
        n = struct.unpack_from("<i", code, p)[0]; p += 4
        vals = list(struct.unpack_from("<%dI" % n, code, p)); p += 4 * n
        if name == "layout_hashes":
            out[name] = vals
            continue
        ents = []
        for v in vals:
            if v == 0xffffffff or v < 0x100:  # end token / per-UB offset table
                continue
            ents.append({"ub": v >> 24, "resource": (v >> 8) & 0xffff, "bind": v & 0xff})
        out[name] = ents
    return out
