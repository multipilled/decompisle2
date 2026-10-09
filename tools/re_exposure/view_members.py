"""Name the members of DI2's View uniform buffer (FViewUniformShaderParameters) from the exe's static
FShaderParametersMetadata member registration: each member's name string (wide) is referenced next to its byte
offset immediate. Prints name refs with nearby `mov` immediates. Usage: python view_members.py Name [Name...]"""
import struct
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "re"))
from di2exe import Exe

e = Exe()
for name in sys.argv[1:]:
    for wide in (True, False):
        for s in e.string_vas(name, wide=wide):
            # exact match only (terminated)
            raw = e.read(s, (len(name) + 1) * (2 if wide else 1))
            if raw[-(2 if wide else 1):] != (b"\0\0" if wide else b"\0"):
                continue
            for r in e.rip_refs(s):
                code = e.read(r - 0x40, 0x80)
                imms = []
                for i in range(len(code) - 8):
                    # mov dword [rsp/rbp+disp8], imm32 : C7 44 24 xx imm32 / C7 45 xx imm32
                    if code[i] == 0xC7 and code[i + 1] in (0x44, 0x45, 0x84, 0x85):
                        k = i + (4 if code[i + 1] == 0x44 else 3) if code[i + 1] in (0x44, 0x45) else None
                        if k and k + 4 <= len(code):
                            imms.append((r - 0x40 + i - r, struct.unpack_from("<I", code, k)[0]))
                    # mov r32, imm32 : B8+r imm32 / 41 B8+r imm32
                    if 0xB8 <= code[i] <= 0xBF and i + 5 <= len(code):
                        imms.append((r - 0x40 + i - r, struct.unpack_from("<I", code, i + 1)[0]))
                print("%s %s str %x ref %x imms %s" % (name, "W" if wide else "A", s, r,
                      [(d, hex(v)) for d, v in imms if v < 0x4000]))
