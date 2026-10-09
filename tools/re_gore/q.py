"""Print qwords at VAs (static read of the exe). usage: python tools/re_gore/q.py <va hex> <count>"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe
e = Exe()
va = int(sys.argv[1], 16)
for k in range(int(sys.argv[2])):
    print(hex(va + 8 * k), hex(e.q(va + 8 * k)))
