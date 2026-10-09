"""List members of a reflected USTRUCT given its Z_Construct function (which calls the struct registrar with the
FStructParams address). usage: python structparams.py 0x141ba6e40 [...]"""
import struct
import sys
import capstone
sys.path.insert(0, r"tools\re")
from di2exe import Exe  # noqa: E402
e = Exe()
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True
for a in sys.argv[1:]:
    fn = int(a, 16)
    params = None
    for ins in md.disasm(e.read(fn, 0x60), fn):
        if ins.mnemonic == "lea" and ins.operands[1].type == capstone.x86.X86_OP_MEM and ins.operands[1].mem.base == capstone.x86.X86_REG_RIP:
            tgt = ins.address + ins.size + ins.operands[1].mem.disp
            if ins.operands[0].reg == capstone.x86.X86_REG_RDX:
                params = tgt
    if params is None:
        print(a, "no FStructParams"); continue
    vals = [e.q(params + 8 * i) for i in range(8)]
    name = e.cstr(vals[3]); size = vals[4]
    arr = vals[6]; n = struct.unpack("<i", e.read(params + 0x38, 4))[0]
    print(f"{a}: F{name} size {size:#x} ({n} props) params {params:#x}")
    for i in range(n):
        r = e.prop_params(e.q(arr + 8 * i))
        print(f"   {r['name']:36s} {r['kind']:10s} {r.get('offset', '')}")
