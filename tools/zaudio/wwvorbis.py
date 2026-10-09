"""Wwise Vorbis (.wem, codec 0xFFFF) -> standard Ogg Vorbis, for DI2's zombie voice files (personal use).

A from-scratch Python port of the algorithm of ww2ogg 0.24 (hcs, BSD licence) for the files DI2 ships (Wwise 2019.2:
fmt chunk 0x42 with the fake 'vorb' block at fmt+0x18, 2-byte packet headers, no granules, "modified" audio packets,
external codebooks), with revorb's job done inline (correct granule positions, last page trimmed to the sample
count). Nothing is executed from outside: the only external input is the packed aoTuV 6.03 codebook library
(a data table, `packed_codebooks_aoTuV_603.bin`), passed with --codebooks.

Wwise strips the Vorbis headers; the identification header is rebuilt from the fmt/vorb fields, the comment header
is written fresh, the setup header is rebuilt from the Wwise setup packet (codebook ids -> full codebooks from the
library, floors/residues/mappings/modes re-expanded to the spec layout), and every audio packet gets back its
packet-type bit and (for long blocks) the previous/next window flags.

usage (library): to_ogg(wem_bytes, codebook_lib) -> (ogg_bytes, info)
       python tools/zaudio/wwvorbis.py --codebooks <bin> in.wem out.ogg
"""
import struct
import sys


# --- bit I/O (Vorbis packs LSB first) -------------------------------------------------------------------------
class BitReader:
    def __init__(self, data: bytes, pos: int = 0):
        self.d = data
        self.bit = pos * 8
        self.start = self.bit

    def read(self, n: int) -> int:
        v = 0
        for i in range(n):
            byte = self.d[self.bit >> 3]
            if (byte >> (self.bit & 7)) & 1:
                v |= 1 << i
            self.bit += 1
        return v

    def bits_read(self) -> int:
        return self.bit - self.start


class BitWriter:
    def __init__(self):
        self.out = bytearray()
        self.cur = 0
        self.n = 0

    def write(self, v: int, n: int) -> None:
        for i in range(n):
            if (v >> i) & 1:
                self.cur |= 1 << self.n
            self.n += 1
            if self.n == 8:
                self.out.append(self.cur)
                self.cur = 0
                self.n = 0

    def write_bytes(self, data: bytes) -> None:
        """Whole bytes at the current (possibly unaligned) bit position."""
        if not data:
            return
        v = (int.from_bytes(data, "little") << self.n) | self.cur
        full = len(data)
        b = v.to_bytes(full + 1, "little")
        self.out += b[:full]
        self.cur = b[full] if self.n else 0

    def bytes(self) -> bytes:
        b = bytearray(self.out)
        if self.n:
            b.append(self.cur)
        return bytes(b)


def ilog(v: int) -> int:
    r = 0
    while v:
        r += 1
        v >>= 1
    return r


def _maptype1_quantvals(entries: int, dimensions: int) -> int:
    bits = ilog(entries)
    vals = entries >> ((bits - 1) * (dimensions - 1) // dimensions)
    while True:
        acc = 1
        acc1 = 1
        for _ in range(dimensions):
            acc *= vals
            acc1 *= vals + 1
        if acc <= entries < acc1:
            return vals
        vals = vals - 1 if acc > entries else vals + 1


# --- packed codebook library ------------------------------------------------------------------------------------
class CodebookLibrary:
    def __init__(self, path: str):
        b = open(path, "rb").read()
        off_off = struct.unpack_from("<I", b, len(b) - 4)[0]
        count = (len(b) - off_off) // 4
        self.data = b[:off_off]
        self.offsets = [struct.unpack_from("<I", b, off_off + 4 * i)[0] for i in range(count)]

    def rebuild(self, i: int, w: BitWriter) -> None:
        if i < 0 or i >= len(self.offsets) - 1:
            raise ValueError(f"invalid codebook id {i}")
        a, e = self.offsets[i], self.offsets[i + 1]
        cb = self.data[a:e]
        r = BitReader(cb)
        dimensions = r.read(4)
        entries = r.read(14)
        w.write(0x564342, 24)
        w.write(dimensions, 16)
        w.write(entries, 24)
        ordered = r.read(1)
        w.write(ordered, 1)
        if ordered:
            w.write(r.read(5), 5)
            cur = 0
            while cur < entries:
                nb = ilog(entries - cur)
                num = r.read(nb)
                w.write(num, nb)
                cur += num
            if cur > entries:
                raise ValueError("ordered codebook overrun")
        else:
            cll = r.read(3)
            sparse = r.read(1)
            if cll == 0 or cll > 5:
                raise ValueError("bad codeword length length")
            w.write(sparse, 1)
            for _ in range(entries):
                present = 1
                if sparse:
                    present = r.read(1)
                    w.write(present, 1)
                if present:
                    w.write(r.read(cll), 5)
        lookup = r.read(1)
        w.write(lookup, 4)
        if lookup == 1:
            mn = r.read(32)
            mx = r.read(32)
            vlen = r.read(4)
            seq = r.read(1)
            w.write(mn, 32)
            w.write(mx, 32)
            w.write(vlen, 4)
            w.write(seq, 1)
            for _ in range(_maptype1_quantvals(entries, dimensions)):
                w.write(r.read(vlen + 1), vlen + 1)
        elif lookup != 0:
            raise ValueError("unexpected lookup type")
        if (r.bits_read() // 8) + 1 != len(cb):
            raise ValueError("codebook size mismatch")


# --- Ogg pages ---------------------------------------------------------------------------------------------------
def _crc_table():
    t = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else (r << 1)
            r &= 0xFFFFFFFF
        t.append(r)
    return t


_CRC = _crc_table()


def _crc(b: bytes) -> int:
    c = 0
    for x in b:
        c = ((c << 8) & 0xFFFFFFFF) ^ _CRC[((c >> 24) & 0xFF) ^ x]
    return c


class OggWriter:
    def __init__(self, serial: int = 1):
        self.out = bytearray()
        self.seq = 0
        self.serial = serial

    def page(self, packet: bytes, granule: int, bos=False, eos=False) -> None:
        """One packet per page (split into 255-segment pages when longer, like ww2ogg's flush_page)."""
        segs = []
        n = len(packet)
        while True:
            segs.append(min(n, 255))
            if n < 255:
                break
            n -= 255
        # pages of at most 255 lacing values
        pos = 0
        chunks = [segs[i:i + 255] for i in range(0, len(segs), 255)]
        for ci, lace in enumerate(chunks):
            size = sum(lace)
            body = packet[pos:pos + size]
            pos += size
            last_chunk = ci == len(chunks) - 1
            flags = (1 if ci > 0 else 0) | (2 if bos and ci == 0 else 0) | (4 if eos and last_chunk else 0)
            g = granule if last_chunk else 0xFFFFFFFFFFFFFFFF
            hdr = b"OggS" + struct.pack("<BBqII", 0, flags, g if g != 0xFFFFFFFFFFFFFFFF else -1, self.serial,
                                        self.seq) + b"\0\0\0\0" + bytes([len(lace)]) + bytes(lace)
            pg = bytearray(hdr + body)
            struct.pack_into("<I", pg, 22, _crc(bytes(pg)))
            self.out += pg
            self.seq += 1


# --- wem parsing -------------------------------------------------------------------------------------------------
def _riff_chunks(b: bytes) -> dict:
    if b[:4] != b"RIFF" or b[8:12] != b"WAVE":
        raise ValueError("not a RIFF WAVE")
    o = 12
    out = {}
    while o + 8 <= len(b):
        tag = b[o:o + 4].decode("latin1")
        sz = struct.unpack_from("<I", b, o + 4)[0]
        out[tag] = (o + 8, sz)
        o += 8 + sz + (sz & 1)
    return out


def to_ogg(b: bytes, cbl: CodebookLibrary):
    ch = _riff_chunks(b)
    fo, fs = ch["fmt "]
    codec, channels, rate, avg_bps = struct.unpack_from("<HHII", b, fo)
    if codec != 0xFFFF:
        raise ValueError(f"codec {codec:#x} is not Wwise Vorbis")
    if fs != 0x42:
        raise ValueError(f"fmt size {fs:#x} not handled (DI2 files are 0x42)")
    vo = fo + 0x18                       # fake 'vorb' block
    sample_count = struct.unpack_from("<I", b, vo)[0]
    mod_signal = struct.unpack_from("<I", b, vo + 4)[0]
    mod_packets = mod_signal not in (0x4A, 0x4B, 0x69, 0x70)
    setup_off, first_audio_off = struct.unpack_from("<II", b, vo + 0x10)
    uid = struct.unpack_from("<I", b, vo + 0x24)[0]
    bs0, bs1 = b[vo + 0x28], b[vo + 0x29]
    do, dsz = ch["data"]

    ogg = OggWriter()

    def header(ptype: int) -> BitWriter:
        w = BitWriter()
        w.write(ptype, 8)
        for c in b"vorbis":
            w.write(c, 8)
        return w

    # identification
    w = header(1)
    w.write(0, 32)
    w.write(channels, 8)
    w.write(rate, 32)
    w.write(0, 32)
    w.write(avg_bps * 8, 32)
    w.write(0, 32)
    w.write(bs0, 4)
    w.write(bs1, 4)
    w.write(1, 1)
    ogg.page(w.bytes(), 0, bos=True)

    # comment
    w = header(3)
    vendor = b"DI2 port: Wwise Vorbis rebuilt (ww2ogg algorithm)"
    w.write(len(vendor), 32)
    for c in vendor:
        w.write(c, 8)
    w.write(0, 32)
    w.write(1, 1)
    ogg.page(w.bytes(), 0)

    # setup
    sp = do + setup_off
    setup_size = struct.unpack_from("<H", b, sp)[0]
    r = BitReader(b, sp + 2)
    w = header(5)
    cb_count = r.read(8) + 1
    w.write(cb_count - 1, 8)
    for _ in range(cb_count):
        cbl.rebuild(r.read(10), w)
    w.write(0, 6)                         # time domain transforms: count-1 = 0
    w.write(0, 16)
    floor_count = r.read(6) + 1
    w.write(floor_count - 1, 6)
    for _ in range(floor_count):
        w.write(1, 16)                    # floor type 1
        parts = r.read(5)
        w.write(parts, 5)
        pclass = []
        for _ in range(parts):
            c = r.read(4)
            w.write(c, 4)
            pclass.append(c)
        maxc = max(pclass) if pclass else -1
        cdims = []
        for _ in range(maxc + 1):
            d = r.read(3)
            w.write(d, 3)
            cdims.append(d + 1)
            sub = r.read(2)
            w.write(sub, 2)
            if sub:
                mb = r.read(8)
                w.write(mb, 8)
            for _ in range(1 << sub):
                w.write(r.read(8), 8)
        w.write(r.read(2), 2)             # multiplier - 1
        rb = r.read(4)
        w.write(rb, 4)
        for c in pclass:
            for _ in range(cdims[c]):
                w.write(r.read(rb), rb)
    res_count = r.read(6) + 1
    w.write(res_count - 1, 6)
    for _ in range(res_count):
        rt = r.read(2)
        w.write(rt, 16)
        for nb in (24, 24, 24):
            w.write(r.read(nb), nb)
        ncls = r.read(6) + 1
        w.write(ncls - 1, 6)
        w.write(r.read(8), 8)             # classbook
        casc = []
        for _ in range(ncls):
            lo = r.read(3)
            w.write(lo, 3)
            flag = r.read(1)
            w.write(flag, 1)
            hi = 0
            if flag:
                hi = r.read(5)
                w.write(hi, 5)
            casc.append(hi * 8 + lo)
        for c in casc:
            for k in range(8):
                if c & (1 << k):
                    w.write(r.read(8), 8)
    map_count = r.read(6) + 1
    w.write(map_count - 1, 6)
    for _ in range(map_count):
        w.write(0, 16)
        subflag = r.read(1)
        w.write(subflag, 1)
        submaps = 1
        if subflag:
            s = r.read(4)
            w.write(s, 4)
            submaps = s + 1
        sq = r.read(1)
        w.write(sq, 1)
        if sq:
            steps = r.read(8) + 1
            w.write(steps - 1, 8)
            nb = ilog(channels - 1)
            for _ in range(steps):
                w.write(r.read(nb), nb)
                w.write(r.read(nb), nb)
        res = r.read(2)
        if res:
            raise ValueError("mapping reserved field nonzero")
        w.write(res, 2)
        if submaps > 1:
            for _ in range(channels):
                w.write(r.read(4), 4)
        for _ in range(submaps):
            w.write(r.read(8), 8)
            w.write(r.read(8), 8)
            w.write(r.read(8), 8)
    mode_count = r.read(6) + 1
    w.write(mode_count - 1, 6)
    blockflag = []
    for _ in range(mode_count):
        f = r.read(1)
        w.write(f, 1)
        blockflag.append(bool(f))
        w.write(0, 16)
        w.write(0, 16)
        w.write(r.read(8), 8)
    w.write(1, 1)
    if (r.bits_read() + 7) // 8 != setup_size:
        raise ValueError("setup packet not read exactly")
    if setup_off + 2 + setup_size != first_audio_off:
        raise ValueError("first audio packet does not follow the setup packet")
    ogg.page(w.bytes(), 0)

    # audio
    mode_bits = ilog(mode_count - 1)
    size0, size1 = 1 << bs0, 1 << bs1
    end = do + dsz
    packets = []
    o = do + first_audio_off
    while o < end:
        sz = struct.unpack_from("<H", b, o)[0]
        packets.append((o + 2, sz))
        o += 2 + sz
    if o != end:
        raise ValueError("audio packets overrun the data chunk")

    def mode_of(p):
        return BitReader(b, p[0]).read(mode_bits) if p[1] > 0 else 0

    prev_long = False
    prev_size = None
    granule = 0
    for i, (po, sz) in enumerate(packets):
        w = BitWriter()
        if mod_packets:
            r = BitReader(b, po)
            mode = r.read(mode_bits)
            rem = r.read(8 - mode_bits)
            w.write(0, 1)
            w.write(mode, mode_bits)
            if blockflag[mode]:
                nxt = blockflag[mode_of(packets[i + 1])] if i + 1 < len(packets) else False
                w.write(1 if prev_long else 0, 1)
                w.write(1 if nxt else 0, 1)
            w.write(rem, 8 - mode_bits)
            prev_long = blockflag[mode]
            w.write_bytes(b[po + 1:po + sz])
            cur = size1 if blockflag[mode] else size0
        else:
            raise ValueError("unmodified packets not expected in DI2 files")
        if prev_size is not None:
            granule += (prev_size + cur) // 4
        prev_size = cur
        last = i == len(packets) - 1
        g = min(granule, sample_count) if last else granule
        ogg.page(w.bytes(), g, eos=last)
    info = {"channels": channels, "rate": rate, "samples": sample_count, "uid": uid, "blocksizes": [size0, size1],
            "packets": len(packets), "decoded_samples": granule}
    return bytes(ogg.out), info


if __name__ == "__main__":
    args = sys.argv[1:]
    cb = args[args.index("--codebooks") + 1]
    rest = [a for i, a in enumerate(args) if a != "--codebooks" and (i == 0 or args[i - 1] != "--codebooks")]
    data, info = to_ogg(open(rest[0], "rb").read(), CodebookLibrary(cb))
    open(rest[1], "wb").write(data)
    print(info)
