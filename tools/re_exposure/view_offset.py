"""Find which View uniform buffer member sits at a byte offset: scan the member-registration code around the known
PreExposure registration (0x143aaf17e) for `mov dword [rsp+..], <offset>` and print the wide string referenced just
before it. Usage: python view_offset.py 0x984 [0x980 ...]"""
import os
import struct
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re"))
from di2exe import Exe

e = Exe()
lo, hi = 0x143a90000, 0x143ad0000
code = e.read(lo, hi - lo)
for arg in sys.argv[1:]:
    want = int(arg, 0)
    pat = struct.pack("<I", want)
    i = 0
    while True:
        i = code.find(pat, i + 1)
        if i < 0:
            break
        if not (code[i - 4] == 0xC7 and code[i - 3] == 0x44):
            continue
        # nearest preceding `lea rXX, [rip+disp]` (48/4C 8D 05/0D/15/...) within 0x30 bytes
        for j in range(i - 6, i - 0x40, -1):
            if code[j] in (0x48, 0x4C) and code[j + 1] == 0x8D and (code[j + 2] & 0xC7) == 0x05:
                tgt = lo + j + 7 + struct.unpack_from("<i", code, j + 3)[0]
                try:
                    raw = e.read(tgt, 96)
                    s = raw.decode("utf-16-le").split("\0")[0]
                except Exception:
                    s = "?"
                print(hex(want), "at", hex(lo + i), "->", s)
                break
