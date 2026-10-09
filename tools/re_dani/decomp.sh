#!/bin/sh
# Decompile DI2 exe functions with the Dani session's own headless Ghidra project (extracted/ghidra_dani/DI2dani,
# imported with -noanalysis; functions are created on demand). Static analysis only: the exe is never run.
# usage: tools/with_cpu.sh dani tools/re_dani/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_dani/<out-name>.c
out="extracted/ghidra_dani/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_dani" DI2dani \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re_dani" \
  -postScript DaniDecompileAt.java "$out" "$@" > "extracted/ghidra_dani/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_dani/last_decomp.log" | head -5
