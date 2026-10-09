"""Print the UTF-16 (or ascii with -a) string at each VA. usage: python wstr.py [-a] 0x144c49df0 ..."""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
asc = "-a" in sys.argv
for a in [x for x in sys.argv[1:] if x != "-a"]:
    b = e.read(int(a, 16), 400)
    if asc:
        print(a, b.split(b"\0")[0].decode("latin1"))
    else:
        s = b.decode("utf-16le", "replace").split("\0")[0]
        print(a, s)
