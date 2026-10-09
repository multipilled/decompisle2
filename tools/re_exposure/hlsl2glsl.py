"""Mechanical 3Dmigoto HLSL -> GLSL 450 translation of a decompiled DI2 shader body, so a DI2 shader can run unchanged
(e.g. as a Godot compute pass). Static, offline; used for DI2's LUT blender (Global 2460) by tools/build_test_map.py.

3Dmigoto output is regular: float4 registers r0..rN, `cbN[i].swz` constant arrays, `#define cmp -` comparisons that
yield -1/0 floats, statement-level ternaries, C-style casts, `tN.Sample/Load`. This rewrites exactly those forms:
  - types float/int/uint{2,3,4} -> vec/ivec/uvec; every assignment's RHS is wrapped in the LHS type constructor
    (GLSL has no implicit int<->float conversion on assignment of vectors from mixed expressions);
  - cmp(a OP b) -> _cmpXX(a, b) helpers returning -1.0 / 0.0 per component (HLSL -bool);
  - `x = c ? a : b;` -> _sel(c, a, b) (per-component select on c != 0);
  - (T)operand casts -> T(operand); asint/asuint -> floatBitsTo*; frac/lerp/rsqrt/rcp/saturate/mad helpers;
  - tN.Sample(sM_s, uv) -> texture(tN, uv); tN.Load(v) -> texelFetch(tN, ivec2(v.xy), int(v.w or z)).
The caller supplies the declarations (cb arrays, textures, inputs) and the output store; see translate().
"""
import re

TYPES = {"float": "float", "float2": "vec2", "float3": "vec3", "float4": "vec4", "int": "int", "int2": "ivec2",
         "int3": "ivec3", "int4": "ivec4", "uint": "uint", "uint2": "uvec2", "uint3": "uvec3", "uint4": "uvec4"}
CMP = {"<": "LT", ">": "GT", "<=": "LE", ">=": "GE", "==": "EQ", "!=": "NE"}

HELPERS = r"""
float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec2 saturate(vec2 x) { return clamp(x, 0.0, 1.0); }
vec3 saturate(vec3 x) { return clamp(x, 0.0, 1.0); }
vec4 saturate(vec4 x) { return clamp(x, 0.0, 1.0); }
float rcp(float x) { return 1.0 / x; }
vec2 rcp(vec2 x) { return 1.0 / x; }
vec3 rcp(vec3 x) { return 1.0 / x; }
vec4 rcp(vec4 x) { return 1.0 / x; }
float _b(bool b) { return b ? -1.0 : 0.0; }
vec2 _b(bvec2 b) { return -vec2(b); }
vec3 _b(bvec3 b) { return -vec3(b); }
vec4 _b(bvec4 b) { return -vec4(b); }
float _sel(float c, float a, float b) { return c != 0.0 ? a : b; }
vec2 _sel(vec2 c, vec2 a, vec2 b) { return mix(b, a, notEqual(c, vec2(0.0))); }
vec3 _sel(vec3 c, vec3 a, vec3 b) { return mix(b, a, notEqual(c, vec3(0.0))); }
vec4 _sel(vec4 c, vec4 a, vec4 b) { return mix(b, a, notEqual(c, vec4(0.0))); }
"""
for n in ("", "2", "3", "4"):
    t = "vec" + n if n else "float"
    for k, op in (("LT", "lessThan"), ("GT", "greaterThan"), ("LE", "lessThanEqual"), ("GE", "greaterThanEqual"),
                  ("EQ", "equal"), ("NE", "notEqual")):
        for pre in ("", "i", "u"):
            tt = (pre + t) if n else {"": "float", "i": "int", "u": "uint"}[pre]
            body = "_b(a %s b)" % {"LT": "<", "GT": ">", "LE": "<=", "GE": ">=", "EQ": "==", "NE": "!="}[k] if not n \
                else "_b(%s(a, b))" % op
            HELPERS += "%s _cmp%s(%s a, %s b) { return %s; }\n" % ("vec" + n if n else "float", k, tt, tt, body)


def _match_paren(s, i):
    """Index just past the bracket group starting at s[i] ('(' or '[')."""
    o = s[i]
    c = {"(": ")", "[": "]", "{": "}"}[o]
    d = 0
    for j in range(i, len(s)):
        if s[j] == o:
            d += 1
        elif s[j] == c:
            d -= 1
            if d == 0:
                return j + 1
    raise ValueError("unbalanced: " + s)


def _split_top(s, seps):
    """Split s at top-level occurrences of any string in seps (longest first); returns (parts, found seps)."""
    parts, found, d, i, last = [], [], 0, 0, 0
    seps = sorted(seps, key=len, reverse=True)
    while i < len(s):
        ch = s[i]
        if ch in "([{":
            d += 1
        elif ch in ")]}":
            d -= 1
        elif d == 0:
            for sp in seps:
                if s.startswith(sp, i):
                    parts.append(s[last:i])
                    found.append(sp)
                    i += len(sp)
                    last = i
                    break
            else:
                i += 1
                continue
            continue
        i += 1
    parts.append(s[last:])
    return parts, found


def _operand_end(s, i):
    """End of the primary operand starting at s[i] (after a cast): optional unary '-', then a name / number / call /
    parenthesised group, with any [index] and .swizzle suffixes."""
    j = i
    if s[j] == "-":
        j += 1
    if s[j] == "(":
        j = _match_paren(s, j)
    else:
        m = re.match(r"[A-Za-z_][A-Za-z_0-9]*|[0-9.]+(?:e[-+]?[0-9]+)?", s[j:])
        j += m.end()
        if j < len(s) and s[j] == "(":
            j = _match_paren(s, j)
    while j < len(s) and s[j] in "[.":
        if s[j] == "[":
            j = _match_paren(s, j)
        else:
            m = re.match(r"\.[xyzwrgba]+", s[j:])
            j += m.end()
    return j


def expr(s):
    s = s.strip()
    # cmp(...) -> _cmpXX(a, b)
    while True:
        m = re.search(r"\bcmp\(", s)
        if not m:
            break
        a = m.end() - 1
        b = _match_paren(s, a)
        inner = s[a + 1:b - 1]
        parts, ops = _split_top(inner, list(CMP))
        if len(parts) != 2:
            raise ValueError("cmp: " + inner)
        s = s[:m.start()] + "_cmp%s(%s, %s)" % (CMP[ops[0]], expr(parts[0]), expr(parts[1])) + s[b:]
    # C casts (T)x -> T(x)
    while True:
        m = re.search(r"\((u?int[234]?|float[234]?)\)\s*", s)
        if not m:
            break
        e = _operand_end(s, m.end())
        s = s[:m.start()] + "%s(%s)" % (TYPES[m.group(1)], s[m.end():e]) + s[e:]
    # texture ops
    s = re.sub(r"\b(t\d+)\.Sample\((s\d+_s),\s*", r"texture(\1, ", s)
    s = re.sub(r"\b(t\d+)\.SampleLevel\((s\d+_s),\s*", r"_samplelevel(\1, ", s)
    while True:
        m = re.search(r"\b(t\d+)\.Load\(", s)
        if not m:
            break
        a = m.end() - 1
        b = _match_paren(s, a)
        s = s[:m.start()] + "_load_%s(%s)" % (m.group(1), expr(s[a + 1:b - 1])) + s[b:]
    # constructors / intrinsics
    s = re.sub(r"\b(float[234]|u?int[234])\(", lambda mm: TYPES[mm.group(1)] + "(", s)
    s = re.sub(r"\bfrac\(", "fract(", s)
    s = re.sub(r"\blerp\(", "mix(", s)
    s = re.sub(r"\brsqrt\(", "inversesqrt(", s)
    s = re.sub(r"\basint\(", "floatBitsToInt(", s)
    s = re.sub(r"\basuint\(", "floatBitsToUint(", s)
    s = re.sub(r"\bmad\(", "_mad(", s)
    # icb dynamic indices
    s = re.sub(r"\bicb\[([^\]]+)\]", lambda mm: "icb[int(%s)]" % mm.group(1), s)
    return s


def _lhs_type(lhs):
    m = re.match(r"(o\d+|r\d+)\.([xyzw]+)$", lhs)
    n = len(m.group(2)) if m else 1
    return "float" if n == 1 else "vec%d" % n


def _floatlit(s):
    s = s.strip()
    return s + ".0" if re.fullmatch(r"-?\d+", s) else s


def statement(line):
    st = line.strip()
    if not st or st.startswith("//"):
        return line
    m = re.match(r"([A-Za-z_0-9]+(?:\.[xyzw]+)?)\s*=\s*(.+);$", st)
    if not m:
        # if (...) {, while (true) {, } else {, break;, return;
        m2 = re.match(r"(if|while)\s*\((.*)\)\s*\{$", st)
        if m2:
            return line[:len(line) - len(line.lstrip())] + "%s (%s) {" % (m2.group(1), expr(m2.group(2)))
        return line
    lhs, rhs = m.group(1), m.group(2)
    t = _lhs_type(lhs)
    ind = line[:len(line) - len(line.lstrip())]
    parts, ops = _split_top(rhs, ["?", ":"])
    if ops == ["?", ":"]:
        c, a, b = (expr(_floatlit(p)) for p in parts)
        return ind + "%s = _sel(%s(%s), %s(%s), %s(%s));" % (lhs, t, c, t, a, t, b)
    return ind + "%s = %s(%s);" % (lhs, t, expr(rhs))


def translate(src):
    """Body of main() (between the register declarations and the final closing brace) -> GLSL lines, plus the icb
    constant array if any. Returns (icb_decl or '', body)."""
    icb = ""
    m = re.search(r"const float4 icb\[\] = \{(.*?)\};", src, re.S)
    if m:
        rows = re.findall(r"\{([^{}]*)\}", m.group(1))
        icb = "const vec4 icb[%d] = vec4[](%s);" % (len(rows), ", ".join("vec4(%s)" % r for r in rows))
        src = src[:m.start()] + src[m.end():]
    body = src[src.index("{", src.index("void main")) + 1:src.rindex("}")]
    out = []
    for line in body.splitlines():
        s = line.strip()
        if re.match(r"(float4|uint4) (r\d+|bitmask|fDest)", s) or s.startswith("uint4 bitmask") or s.startswith("float4 fDest"):
            if s.startswith("float4 r0"):
                out.append("  vec4 " + ", ".join(r + " = vec4(0.0)" for r in s[len("float4 "):-1].split(",")) + ";")
            continue
        out.append(statement(line))
    return icb, "\n".join(out)
