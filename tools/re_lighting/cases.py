"""Split a decompiled deferred-light .asm into its shading-model switch cases and print, per case, the opcode/literal
signature (register names stripped) so cases can be compared across permutations.
usage: python cases.py <asm> [<asm> ...]   -> per case: number of instructions + hash of the normalised stream"""
import hashlib
import re
import sys


def cases(asm):
    lines = asm.splitlines()
    out, cur, labels = {}, None, []
    depth = 0
    for l in lines:
        s = l.strip()
        if s.startswith("switch"):
            depth += 1
            continue
        if depth == 0:
            continue
        if s.startswith("case") or s.startswith("default"):
            if cur is not None and cur:
                out[tuple(labels)] = cur
                labels, cur = [], None
            labels.append(s)
            cur = cur if cur is not None else []
            continue
        if s.startswith("endswitch"):
            if cur:
                out[tuple(labels)] = cur
            break
        if s.startswith("break"):
            out[tuple(labels)] = cur
            labels, cur = [], None
            continue
        if cur is not None:
            cur.append(s)
    return out


def norm(s):
    s = re.sub(r"\b[rv]\d+\.?[xyzw]*", "R", s)
    s = re.sub(r"\bcb(\d+)\[(\d+)\]", lambda m: "CB[" + m.group(2) + "]", s)
    s = re.sub(r"\bt\d+\.[xyzw]+", "T", s)
    s = re.sub(r"\bs\d+\b", "S", s)
    return s


if __name__ == "__main__":
    for path in sys.argv[1:]:
        c = cases(open(path).read())
        print("==", path.split("\\")[-1].split("/")[-1])
        for k, v in c.items():
            ops = [norm(x) for x in v]
            lits = sorted(set(re.findall(r"l\(([^)]*)\)", " ".join(v))))
            h = hashlib.md5("\n".join(ops).encode()).hexdigest()[:8]
            print(f"  {' '.join(x.split()[-1] for x in k):24s} n={len(v):4d} h={h} lits={len(lits)}")
