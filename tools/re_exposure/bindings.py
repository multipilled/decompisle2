"""Dump a DI2 global shader's FShaderParameterBindings.Parameters (static): each loose parameter's CPU struct byte
offset -> cbuffer byte offset. Item = {u16 BufferIndex, u16 BaseIndex (cbuffer bytes), u16 ByteOffset (struct),
u16 ByteSize}. Usage (py -3.12): bindings.py <type-regex> <permutation>"""
import os
import struct
import sys
sys.path.insert(0, r"tools\shaders")
sys.path.insert(0, r"tools\re_lighting")
import frozen  # noqa: E402
import list_global  # noqa: E402

names, maps, lib = list_global.load()
for r in list_global.rows(sys.argv[1], names, maps, lib):
    if r["perm"] != int(sys.argv[2]):
        continue
    f = maps[r["map"]]["frozen"]
    d, n = frozen.compact(f, r["at"] if "at" in r else r["frozen_at"])
    print(r["type"], "p%d" % r["perm"], "lib", r["lib_index"], "params", n)
    for i in range(n):
        bi, base, off, size = struct.unpack_from("<4H", f, d + 8 * i)
        print("  struct +0x%03x size %3d -> cb%d byte %4d (cb%d[%d].%s)" % (off, size, bi, base, bi, base // 16, "xyzw"[base % 16 // 4]))
