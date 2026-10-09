"""Diff one shading-model case (normalised, registers stripped) between two deferred-light .asm files.
usage: python casediff.py <a.asm> <b.asm> <case label e.g. 5>"""
import difflib
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cases import cases, norm  # noqa: E402

a, b, lab = sys.argv[1], sys.argv[2], sys.argv[3]


def pick(path):
    for k, v in cases(open(path).read()).items():
        if any(x.split()[-1] in (f"l({lab})", lab) for x in k):
            return v
    return []


A, B = pick(a), pick(b)
for l in difflib.unified_diff([norm(x) for x in A], [norm(x) for x in B], lineterm="", n=1):
    print(l)
