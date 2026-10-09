#!/bin/sh
# Decompile DI2 exe functions with the gore session's own headless Ghidra project (extracted/ghidra_gore/DI2, a copy
# of extracted/ghidra's -noanalysis import; functions are created on demand). Static analysis only.
# usage: tools/with_cpu.sh gore-gaps tools/re_gore/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_gore/<out-name>.c
out="extracted/ghidra_gore/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_gore" DI2 \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re" \
  -postScript DecompileAt.java "$out" "$@" > "extracted/ghidra_gore/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_gore/last_decomp.log" | head -5
