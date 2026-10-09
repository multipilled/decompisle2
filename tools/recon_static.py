"""Static recon of a Dead Island 2 install. Reads files only; never launches or patches the game.

Outputs (in recon\\):
  utoc_headers.csv   - IoStore container header fields (encryption, compression, entry counts)
  exe_strings.txt    - reflection-style identifiers from the shipping exe matching gore/zombie keywords
"""
import csv
import re
import struct
import sys
from collections import defaultdict
from pathlib import Path

GAME = Path(r"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2")
PAKS = GAME / "DeadIsland" / "Content" / "Paks"
EXE = GAME / "DeadIsland" / "Binaries" / "Win64" / "DeadIsland-Win64-Shipping.exe"
OUT = Path(r"recon")

KEYWORDS = [
    "flesh", "gore", "dismember", "wound", "gib", "sever", "limb", "decap", "maim", "cripple",
    "bleed", "blood", "evisc", "slice", "sliced", "cut", "zombie", "infected", "walker", "crawler",
    "runner", "shambler", "damagezone", "hitzone", "bodypart", "bone", "skull", "organ", "intestin",
    "muscle", "skin", "fat", "melt", "caustic", "burn", "shock", "electr", "dmgtype", "damagetype",
]
KW_RE = re.compile("|".join(KEYWORDS), re.IGNORECASE)
IDENT = rb"[A-Za-z_][A-Za-z0-9_]{5,80}"


def utoc_headers():
    rows = []
    for f in sorted(PAKS.glob("*.utoc")):
        with f.open("rb") as fh:
            h = fh.read(0x90)
        (version,) = struct.unpack_from("<B", h, 0x10)
        header_size, entry_count, cblock_count, cblock_size = struct.unpack_from("<4I", h, 0x14)
        cm_count, cm_len, cblock_bytes, dir_index_size, partition_count = struct.unpack_from("<5I", h, 0x24)
        (container_id,) = struct.unpack_from("<Q", h, 0x38)
        key_guid = h[0x40:0x50].hex()
        flags = h[0x50]
        rows.append({
            "file": f.name,
            "version": version,
            "entries": entry_count,
            "compressed_blocks": cblock_count,
            "block_size": cblock_bytes,
            "dir_index_bytes": dir_index_size,
            "partitions": partition_count,
            "container_id": f"{container_id:016x}",
            "key_guid": key_guid,
            "flags": flags,
            "compressed": bool(flags & 1),
            "encrypted": bool(flags & 2),
            "signed": bool(flags & 4),
            "indexed": bool(flags & 8),
        })
    with (OUT / "utoc_headers.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return rows


def exe_strings():
    data = EXE.read_bytes()
    hits = defaultdict(set)
    for m in re.finditer(IDENT, data):
        s = m.group().decode("ascii")
        if KW_RE.search(s):
            hits["ascii"].add(s)
    utf16 = rb"(?:[A-Za-z_]\x00)(?:[A-Za-z0-9_/.:]\x00){5,100}"
    for m in re.finditer(utf16, data):
        s = m.group().decode("utf-16le")
        if KW_RE.search(s):
            hits["utf16"].add(s)
    return data, hits


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rows = utoc_headers()
    enc = sum(r["encrypted"] for r in rows)
    print(f"utoc containers: {len(rows)}  encrypted: {enc}  versions: {sorted({r['version'] for r in rows})}")
    print(f"distinct key guids: {sorted({r['key_guid'] for r in rows})}")

    data, hits = exe_strings()
    print(f"exe size: {len(data)/1e6:.1f} MB")
    for marker in (b"++UE4+Release-4.", b"++UE5+Release-5.", "++UE4+Release-4.".encode("utf-16le")):
        i = data.find(marker)
        if i >= 0:
            chunk = data[i:i + 80]
            txt = chunk.decode("utf-16le", "ignore") if b"\x00" in chunk[:4] else chunk.decode("ascii", "ignore")
            print("engine branch:", txt.split("\x00")[0])
    with (OUT / "exe_strings.txt").open("w", encoding="utf-8") as fh:
        for kind in ("utf16", "ascii"):
            fh.write(f"## {kind} ({len(hits[kind])})\n")
            for s in sorted(hits[kind], key=str.lower):
                fh.write(s + "\n")
    print(f"keyword hits: utf16={len(hits['utf16'])} ascii={len(hits['ascii'])}")


if __name__ == "__main__":
    sys.exit(main())
