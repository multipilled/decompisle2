"""Reflected property offsets (UE 4.27 FPropertyParams) for the given names. usage: python tools/particles/props.py N1 N2 ..."""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
for n in sys.argv[1:]:
    rs = e.props_named(n)
    print(n, [(r.get("offset"), r.get("kind"), r.get("setbit")) for r in rs][:10], flush=True)
