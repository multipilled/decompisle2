"""Animation names in a .glb (its JSON chunk).  usage: python tools/re_ai/glb_anims.py <file.glb> [substring]"""
import json, struct, sys
with open(sys.argv[1], 'rb') as f:
    f.read(12)
    n, _ = struct.unpack('<II', f.read(8))
    j = json.loads(f.read(n))
sub = sys.argv[2] if len(sys.argv) > 2 else ''
names = [a.get('name', '') for a in j.get('animations', [])]
print(len(names), [x for x in names if sub.lower() in x.lower()])
