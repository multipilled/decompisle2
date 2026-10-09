"""Print a UClass's InternalConstructor disassembly (static; exe never run). usage: python ctor.py UClass [...]"""
import sys
sys.path.insert(0, r"tools\particles")
import uclass_vtable as U  # noqa: E402
for cls in sys.argv[1:]:
    r = U.ctor_of(cls)
    print("==", cls, [hex(x) if isinstance(x, int) else x for x in (r or [])])
    if r and r[1]:
        for i in U.disasm(r[1], 0x80, stop_ret=False)[:40]:
            print("   %x: %s %s" % (i.address, i.mnemonic, i.op_str))
