"""Functions that reference (RIP-relative lea/mov) each given VA in DI2's exe.

usage: python tools/re_ai/refs.py <va> [va ...]   -> "<va> <ref site> <function start>"
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "re"))
from di2exe import Exe, root_function  # noqa: E402

e = Exe()
for a in sys.argv[1:]:
    va = int(a, 16)
    for site in e.rip_refs(va):
        f = root_function(e, site)
        print(a, hex(site), hex(f) if f else "?")
