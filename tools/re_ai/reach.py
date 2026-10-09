"""Which cards, actions, sequence-unit classes and generator classes an archetype's decks can reach (zombie_ai.json).

usage: python tools/re_ai/reach.py <Archetype> [context ...]   (default contexts: Master and everything it includes)
"""
import json
import os
import sys
from collections import Counter

D = json.load(open(os.path.join(os.path.dirname(__file__), "..", "..", "game", "data", "zombie_ai.json"),
                   encoding="utf-8"))
A = D["assets"]
ctl = D["controllers"][sys.argv[1]]
todo = list(sys.argv[2:] or ["Master"])
gens, cards, actions, units, seen = Counter(), Counter(), Counter(), Counter(), set()


def walk(v):
    if isinstance(v, dict):
        t = v.get("$t", "")
        if "CardGenerator" in t:
            gens[t] += 1
            if t == "CardGenerator_IncludeDeck":
                todo.append(v.get("DeckContextToInclude"))
        for x in v.values():
            walk(x)
    elif isinstance(v, list):
        for x in v:
            walk(x)
    elif isinstance(v, str) and v.startswith("@DA_Card_"):
        card(v[1:])


def card(n):
    if n in seen:
        return
    seen.add(n)
    cards[n] += 1
    c = A.get(n, {})
    actions[c.get("Action")] += 1
    seq = (c.get("Parameters") or {}).get("AttackSequence")
    if seq:
        for u in A.get(seq[1:], {}).get("Units", []):
            units[u.get("$t")] += 1


while todo:
    ctx = todo.pop()
    if ctx in seen:
        continue
    seen.add(ctx)
    deck = ctl["contexts"].get(ctx)
    print("context", ctx, "->", deck)
    if deck:
        walk(A.get(deck, {}))
print("generators", dict(gens))
print("actions", dict(actions))
print("units", dict(units))
print("cards", sorted(cards))
