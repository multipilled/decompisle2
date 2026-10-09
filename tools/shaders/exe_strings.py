"""Static string dump (ASCII + UTF-16LE) of the DI2 shipping exe, filtered by regex. Reads the file only; never runs it.
Usage: python exe_strings.py <exe> <regex> [min_len]"""
import re, sys
b = open(sys.argv[1], "rb").read()
rx = re.compile(sys.argv[2])
n = int(sys.argv[3]) if len(sys.argv) > 3 else 4
seen = set()
for m in re.finditer(rb"[\x20-\x7e]{%d,}" % n, b):
    s = m.group().decode()
    if rx.search(s) and s not in seen:
        seen.add(s); print(f"A {m.start():#x} {s}")
for m in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % n, b):
    s = m.group().decode("utf-16le")
    if rx.search(s) and s not in seen:
        seen.add(s); print(f"W {m.start():#x} {s}")
