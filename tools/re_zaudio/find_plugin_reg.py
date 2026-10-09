"""Find Wwise static plugin registrations (AK::PluginRegistration ctor calls in static initialisers) for a given
plugin id by scanning .text for `mov dword [rip+X], imm32` stores of the id with a matching type store nearby.
Static exe reading only. usage: python tools/re_zaudio/find_plugin_reg.py <plugin_id> [type]
"""
import re
import struct
import sys

sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402

pid = int(sys.argv[1], 0)
e = Exe()
_, v, vs, raw, rs = e.sec(".text")
data = e.m[raw:raw + rs]
# C7 05 disp32 imm32 = mov dword [rip+disp], imm32 ; also C7 44 24 xx imm32 (stack) and  BA/B9/41 B8 imm32 (regs)
hits = []
for m in re.finditer(re.escape(b"\xC7\x05") + b"(....)" + re.escape(struct.pack("<I", pid)), data, re.S):
    p = m.start()
    disp = struct.unpack("<i", m.group(1))[0]
    tgt = v + p + 10 + disp
    hits.append((v + p, tgt))
for site, tgt in hits:
    print(f"store {pid:#x} at {site:#x} -> [{tgt:#x}]  func {e.func_of(site)}")
# immediates passed in registers to a ctor: mov r8d/edx/ecx, pid
for pat, reg in ((b"\x41\xB8", "r8d"), (b"\xBA", "edx"), (b"\xB9", "ecx"), (b"\x41\xB9", "r9d")):
    for m in re.finditer(re.escape(pat + struct.pack("<I", pid)), data):
        site = v + m.start()
        ctx = data[max(0, m.start() - 40): m.start() + 40]
        print(f"mov {reg},{pid:#x} at {site:#x} func {e.func_of(site)}")
