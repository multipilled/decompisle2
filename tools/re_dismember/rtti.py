"""Find MSVC x64 vtables of a class by RTTI name (.?AV<name>@@). usage: python rtti.py UVisceraComponent [slot_hex ...]"""
import struct
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
name = sys.argv[1]
slots = [int(x, 16) for x in sys.argv[2:]]
td_name = f".?AV{name}@@".encode()
for off in e.find_all(td_name):
    td = e.va(off) - 0x10  # TypeDescriptor: pVFTable, spare, name
    td_rva = td - e.base
    # COL: signature(4)=1, offset(4), cdOffset(4), pTypeDescriptor rva(4), pClassHierarchy rva(4), pSelf rva(4)
    needle = struct.pack("<I", td_rva)
    for o2 in e.find_all(needle):
        col = e.va(o2) - 12
        if col is None or e.read(col, 4) != b"\x01\x00\x00\x00":
            continue
        objoff = struct.unpack("<I", e.read(col + 4, 4))[0]
        for p in e.pointers_to(col):
            vt = p + 8
            print(f"{name}: COL {col:#x} offset {objoff:#x} vtable {vt:#x}")
            for s in slots:
                print(f"   slot {s:#x}: {e.q(vt + s):#x}")
