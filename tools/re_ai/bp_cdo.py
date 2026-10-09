"""Print the Properties of the class-default object (or any named object) in a json_bp / json dump.

usage: python tools/re_ai/bp_cdo.py <dump.json> [name-substring]   (default: Default__)
"""
import json
import sys

d = json.load(open(sys.argv[1], encoding='utf-8'))
sub = sys.argv[2] if len(sys.argv) > 2 else 'Default__'
for o in d:
    if sub in str(o.get('Name', '')) and o.get('Properties'):
        print('==', o.get('Type'), o.get('Name'))
        print(json.dumps(o['Properties'], indent=1)[:4000])
