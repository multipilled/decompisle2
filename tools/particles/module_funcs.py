"""Per Cascade module class: constructor, vtable, module flag byte from the ctor, and its Spawn (vtable +0x240) /
Update (+0x248) overrides in DI2's exe. Slots found by diffing vtables (UParticleModule stubs = 0x140784e40).
usage: python tools/particles/module_funcs.py <class list file>  -> extracted/particles_build/module_funcs.json"""
import json
import sys
sys.path.insert(0, r"tools\particles")
import uclass_vtable as U  # noqa: E402

STUB = 0x140784e40
out = {}
for c in [l.strip() for l in open(sys.argv[1]) if l.strip()]:
    r = U.info(c)
    vt = r["vtable"]
    rec = {k: (hex(v) if isinstance(v, int) else v) for k, v in r.items()}
    if vt:
        sp, up, fu = U.e.q(vt + 0x240), U.e.q(vt + 0x248), U.e.q(vt + 0x250)
        rec["spawn"] = hex(sp) if sp != STUB else None
        rec["update"] = hex(up) if up != STUB else None
        rec["final_update"] = hex(fu) if fu != STUB else None
    out[c] = rec
    print(c, rec.get("ctor"), rec.get("spawn"), rec.get("update"))
json.dump(out, open(r"extracted\particles_build\module_funcs.json", "w"), indent=1)
