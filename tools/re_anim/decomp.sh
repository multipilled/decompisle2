#!/bin/sh
# Decompile DI2 exe functions with the animation session's own headless Ghidra project (extracted/ghidra_anim/DI2anim,
# imported with -noanalysis; functions are created on demand). Static analysis only: the exe is never run.
# usage: tools/with_cpu.sh anim tools/re_anim/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_anim/<out-name>.c
out="extracted/ghidra_anim/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_anim" DI2anim \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re_anim" \
  -postScript AnimDecompileAt.java "$out" "$@" > "extracted/ghidra_anim/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_anim/last_decomp.log" | head -5
