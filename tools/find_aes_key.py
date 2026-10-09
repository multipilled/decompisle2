"""Find the pak AES-256 key inside the user's own DI2 shipping exe, then prove it by decrypting
an IoStore directory index (it must start with FString MountPoint "../../../").

Static only: the exe is read from disk, never run. Strategies, cheapest first:
  1. xmm: two RIP-relative 16-byte constant loads (movups/movaps/movdqu) stored to [reg] and [reg+10h]
  2. imm: runs of mov [reg+disp], imm32 / imm8 covering 32 contiguous bytes (any order)
  3. rdata: every 4-byte-aligned 32-byte window of .rdata/.data
"""
import re
import struct
import sys
from pathlib import Path

from Crypto.Cipher import AES

GAME = Path(r"C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2")
EXE = GAME / "DeadIsland" / "Binaries" / "Win64" / "DeadIsland-Win64-Shipping.exe"
PAKS = GAME / "DeadIsland" / "Content" / "Paks"
OUT = Path(r"recon\aes_key.txt")


def dir_index_probe(utoc: Path) -> bytes:
    """Return the first 16 encrypted bytes of the directory index of a v3 (4.27) utoc."""
    b = utoc.read_bytes()
    hdr_size, entries, cblocks, cblock_sz = struct.unpack_from("<4I", b, 0x14)
    cm_count, cm_len, _, dir_size, _ = struct.unpack_from("<5I", b, 0x24)
    flags = b[0x50]
    assert flags & 2 and flags & 8 and dir_size, f"{utoc.name} not encrypted+indexed"
    off = hdr_size + entries * 22 + cblocks * cblock_sz + cm_count * cm_len
    if flags & 4:  # signed: hash size, toc sig, block sig, per-block SHA1
        (hash_size,) = struct.unpack_from("<i", b, off)
        off += 4 + 2 * hash_size + cblocks * 20
    return b[off:off + 16]


class PE:
    def __init__(self, data: bytes):
        self.data = data
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        opt = struct.unpack_from("<H", data, pe + 20)[0]
        self.sections = {}
        for i in range(nsec):
            name, vsz, va, rsz, raw = struct.unpack_from("<8sIIII", data, pe + 24 + opt + i * 40)
            self.sections[name.rstrip(b"\0").decode()] = (va, vsz, raw, rsz)

    def rva_to_off(self, rva):
        for va, vsz, raw, rsz in self.sections.values():
            if va <= rva < va + rsz:
                return raw + rva - va
        return None


def xmm_candidates(pe: PE):
    """movups/movaps/movdqu/movdqa xmmN, [rip+disp32] -> 16-byte constants; pair nearby loads."""
    va, _, raw, rsz = pe.sections[".text"]
    text = pe.data[raw:raw + rsz]
    load = re.compile(rb"(?:\x66|\xF3)?(?:[\x40-\x4F])?\x0F(?:\x10|\x28|\x6F)([\x05\x0D\x15\x1D\x25\x2D\x35\x3D])(....)", re.S)
    loads = []
    for m in load.finditer(text):
        disp = struct.unpack("<i", m.group(2))[0]
        target = va + m.end() + disp
        off = pe.rva_to_off(target)
        if off is not None:
            loads.append((m.start(), pe.data[off:off + 16]))
    for i, (pos, a) in enumerate(loads):
        for pos2, b in loads[i + 1:i + 4]:
            if pos2 - pos > 96:
                break
            yield a + b
            yield b + a


def imm_candidates(pe: PE):
    """mov [base+disp], imm32 (C7 /0) or imm8 (C6 /0), grouped into nearby runs per base register."""
    va, _, raw, rsz = pe.sections[".text"]
    text = pe.data[raw:raw + rsz]
    ins = re.compile(rb"([\x40-\x47])?([\xC6\xC7])([\x40-\x47\x80-\x87])(\x24)?", re.S)
    run, last_end = {}, -1

    def flush():
        for base, cover in run.items():
            if len(cover) < 32:
                continue
            for d in sorted(cover):
                if all((d + k) in cover for k in range(32)):
                    yield bytes(cover[d + k] for k in range(32))

    for m in ins.finditer(text):
        rex, opc, modrm, sib = m.group(1), m.group(2)[0], m.group(3)[0], m.group(4)
        rm = modrm & 7
        if (rm == 4) != (sib is not None):
            continue
        p = m.end()
        if modrm >= 0x80:
            disp, p = struct.unpack_from("<i", text, p)[0], p + 4
        else:
            disp, p = struct.unpack_from("<b", text, p)[0], p + 1
        width = 4 if opc == 0xC7 else 1
        imm = text[p:p + width]
        if m.start() - last_end > 48:
            yield from flush()
            run = {}
        base = (rex[0] if rex else 0, rm)
        cover = run.setdefault(base, {})
        for k in range(width):
            cover[disp + k] = imm[k]
        last_end = p + width
    yield from flush()


def rdata_candidates(pe: PE):
    for name in (".rdata", ".data"):
        va, _, raw, rsz = pe.sections[name]
        blob = pe.data[raw:raw + rsz]
        for o in range(0, len(blob) - 32, 4):
            yield blob[o:o + 32]


def main():
    probe_file = min((p for p in PAKS.glob("*.utoc") if (p.read_bytes()[0x50] & 10) == 10), key=lambda p: p.stat().st_size)
    probe = dir_index_probe(probe_file)
    print(f"probe container: {probe_file.name}  cipher[0:16]={probe.hex()}", flush=True)
    pe = PE(EXE.read_bytes())
    for name, gen in (("xmm", xmm_candidates), ("imm", imm_candidates), ("rdata", rdata_candidates)):
        seen = 0
        for key in gen(pe):
            seen += 1
            plain = AES.new(key, AES.MODE_ECB).decrypt(probe)
            (n,) = struct.unpack_from("<i", plain, 0)
            if 0 < n < 512 and plain[4:13] == b"../../../":
                hexkey = "0x" + key.hex().upper()
                print(f"FOUND via {name} after {seen} candidates")
                print("decrypted mount point prefix:", plain[4:])
                OUT.write_text(hexkey + "\n")
                print(f"key written to {OUT}")
                return 0
        print(f"{name}: no key in {seen} candidates", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
