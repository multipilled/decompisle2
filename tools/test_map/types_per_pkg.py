"""Top export types per level package (glob over extracted/json): a first look before writing the inventory."""
import collections, glob, json, sys
for f in sorted(glob.glob(sys.argv[1])):
    d = json.load(open(f, encoding="utf-8"))
    c = collections.Counter(e.get("Type") for e in d)
    print(f.split("\\")[-1].split("/")[-1], len(d), c.most_common(int(sys.argv[2]) if len(sys.argv) > 2 else 25))
