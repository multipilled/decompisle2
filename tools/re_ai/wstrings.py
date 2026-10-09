"""List ASCII and UTF-16 strings in DI2's exe matching a regex, with their VAs.

usage: python tools/re_ai/wstrings.py <regex> [--wide-only]
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "re"))
from di2exe import Exe  # noqa: E402

e = Exe()
pat = re.compile(sys.argv[1])
wide_only = "--wide-only" in sys.argv
data = e.m[:]
if not wide_only:
    for m in re.finditer(rb"[\x20-\x7e]{4,200}\x00", data):
        s = m.group()[:-1].decode()
        if pat.search(s):
            print("a", hex(e.va(m.start())), s)
for m in re.finditer(rb"(?:[\x20-\x7e]\x00){4,200}\x00\x00", data):
    s = m.group()[:-2].decode("utf-16-le")
    if pat.search(s):
        print("w", hex(e.va(m.start())), s)
