"""Per archetype: the AttackDefinition montages its decks reach (zombie_ai.json, transitive '@' refs from its
controller contexts) and whether its body plays each: by_clip (a named clip), seg (all segments resolve, e.g. the
attacks2 'x:<seq>' clips) or none.  Usage: python tools/re_ai/attack_coverage.py [Arch] [-v]"""
import json, sys
ai = json.load(open('game/data/zombie_ai.json', encoding='utf-8'))
mz = json.load(open('game/data/montages_zombie.json', encoding='utf-8'))
A = ai['assets']
BODY = {'Walker': 'walker', 'Runner': 'runner', 'Shambler': 'shambler', 'Thug': 'thug', 'Screamer': 'screamer',
        'Slobber': 'slobber', 'Butcher': 'butcher', 'Suicider': 'suicider'}


def refs(v, out):
    if isinstance(v, dict):
        for x in v.values(): refs(x, out)
    elif isinstance(v, list):
        for x in v: refs(x, out)
    elif isinstance(v, str) and v.startswith('@'):
        out.append(v[1:])


args = [a for a in sys.argv[1:] if a != '-v']
for arch in (args or BODY):
    body = BODY[arch]
    have = set(mz['by_clip'].get(body, {}).values())
    todo = [d for d in ai['controllers'][arch]['contexts'].values() if d]
    seen, mons = set(), {}
    while todo:
        n = todo.pop()
        if n in seen or n not in A: continue
        seen.add(n)
        a = A[n]
        if isinstance(a, dict) and 'WindUps' in a:
            for w in a['WindUps']:
                for at in w.get('Attacks', []):
                    am = str(at.get('Montage', '')).lstrip('@')
                    if am: mons.setdefault(am, n)
        r = []; refs(a, r); todo += r
    cnt = {'by_clip': [], 'seg': [], 'none': []}
    for am in mons:
        segs = mz['montages'].get(am, {}).get('segments', {}).get(body, [])
        k = 'by_clip' if am in have else ('seg' if segs and all(s[0] for s in segs) else 'none')
        cnt[k].append(am)
    print(arch, {k: len(v) for k, v in cnt.items()})
    if '-v' in sys.argv:
        for k in ('seg', 'none'):
            for am in sorted(cnt[k]): print('  ', k, am, '<-', mons[am])
