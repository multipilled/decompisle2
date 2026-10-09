"""Annotate a decompiled DI2 particle-material shader (local analysis aid for tools/build_particles.py / recon/PARTICLES.md).

Thin wrapper over tools/shaders/annotate.py (flesh-shaders session, used read-only): same output
(extracted/shaders/annotated/<lib>_<index>_<label>.hlsl + .slots.txt), but a preshader program with an opcode the
shared decoder doesn't know is written as raw hex instead of aborting the whole file.

  python tools/particles/annotate_p.py <material json (shadermaps.exe)> <resource index> <lib> <shader index> [<master json>]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "shaders"))
import annotate  # noqa: E402

_orig = annotate.preshader


def tolerant(seg, sp, vp):
    try:
        return _orig(seg, sp, vp)
    except (struct.error, IndexError):
        return "RAW[" + seg.hex() + "]"


annotate.preshader = tolerant

if __name__ == "__main__":
    print(annotate.run(sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5] if len(sys.argv) > 5 else None))
