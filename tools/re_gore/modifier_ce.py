"""Where DI2 reads UImpactRequestModifierDataDriven.OnImpactModifiedCosmeticEffect (static read of the exe).
usage: python tools/re_gore/modifier_ce.py"""
import sys
sys.path.insert(0, r"tools\re")
from di2exe import Exe, struct_members

e = Exe()
recs = e.props_named("OnImpactModifiedCosmeticEffect")
print("prop", recs)
for r in recs:
    if "offset" in r:
        for m in struct_members(e, int(r["at"], 16)):
            print("  member", m.get("name"), m.get("kind"), m.get("offset", m.get("setbit")))
for cls in ("ImpactRequestModifierDataDriven", "ImpactRequestModifier"):
    for sva in e.string_vas(cls, wide=True):
        for ref in e.rip_refs(sva):
            print(cls, "wide string", hex(sva), "ref", hex(ref), "func", [hex(x) for x in (e.func_of(ref) or ())])
