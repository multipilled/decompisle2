"""Compact view of a CUE4Parse JSON dump (tools/di2x.sh json): one line per leaf property.

usage: python tools/re_ai/ue_flat.py <dump.json | asset name> [grep-regex]
Object references print as their short name; a bare asset name is looked up under extracted/json.
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "extracted", "json")


def find(name):
    if os.path.exists(name):
        return name
    for d, _, fs in os.walk(ROOT):
        if name + ".json" in fs:
            return os.path.join(d, name + ".json")
    raise SystemExit("not found: " + name)


def short(v):
    if isinstance(v, dict) and set(v) >= {"ObjectName"} and set(v) <= {"ObjectName", "ObjectPath"}:
        n = v["ObjectName"]
        m = re.match(r"\w+'(.*)'", n)
        return "@" + (m.group(1) if m else n)
    return None


def walk(v, path, out):
    s = short(v)
    if s is not None:
        out.append((path, s))
    elif isinstance(v, dict):
        for k, x in v.items():
            walk(x, f"{path}.{k}" if path else k, out)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            walk(x, f"{path}[{i}]", out)
    else:
        out.append((path, v))


def main():
    f = find(sys.argv[1])
    pat = re.compile(sys.argv[2]) if len(sys.argv) > 2 else None
    for e in json.load(open(f, encoding="utf-8")):
        lines = []
        walk(e.get("Properties", {}), "", lines)
        head = f"== {e.get('Type')} {e.get('Name')}" + (f" outer={e['Outer']}" if e.get("Outer") else "")
        sel = [(p, v) for p, v in lines if not pat or pat.search(f"{p}={v}")]
        if sel or not pat:
            print(head)
            for p, v in sel:
                print(f"  {p} = {v}")


if __name__ == "__main__":
    main()
