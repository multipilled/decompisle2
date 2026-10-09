#!/bin/sh
# Decompile DI2 exe functions with the hit-react session's own headless Ghidra project (extracted/ghidra_hitreact/DI2hr,
# a copy of the animation session's -noanalysis import; functions are created on demand). Static analysis only.
# usage: tools/with_cpu.sh hitsel tools/re_hitreact/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_hitreact/<out-name>.c
out="extracted/ghidra_hitreact/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_hitreact" DI2hr \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re_anim" \
  -postScript AnimDecompileAt.java "$out" "$@" > "extracted/ghidra_hitreact/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_hitreact/last_decomp.log" | head -5
