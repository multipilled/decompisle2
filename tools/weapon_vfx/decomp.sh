#!/bin/sh
# Decompile DI2 exe functions for the weapon / world-impact VFX RE with this session's own headless Ghidra project
# (extracted/ghidra_vfx/DI2vfx, a copy of the -noanalysis import; functions are created on demand).
# Static analysis only: the exe is never run.
# usage: tools/with_cpu.sh weapon_vfx tools/weapon_vfx/decomp.sh <out-name> <addr> [addr ...]
#        -> extracted/ghidra_vfx/<out-name>.c
out="extracted/ghidra_vfx/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_vfx" DI2vfx \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\weapon_vfx" \
  -postScript VfxDecompileAt.java "$out" "$@" > "extracted/ghidra_vfx/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_vfx/last_decomp.log" | head -5
