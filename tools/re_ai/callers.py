"""Root functions that call each given function VA (direct call/jmp rel32). usage: python tools/re_ai/callers.py <va>..."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "re"))
from di2exe import Exe, calls_to, root_function  # noqa: E402

e = Exe()
for a in sys.argv[1:]:
    fs = sorted({root_function(e, s) or 0 for s, _ in calls_to(e, int(a, 16))})
    print(a, " ".join(hex(f) for f in fs))
