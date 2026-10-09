#!/bin/sh
# Decompile DI2 exe functions with my own headless Ghidra project (extracted/ghidra_dismember/DI2dis, no analysis).
# usage: tools/re_dismember/decomp.sh <out-name> <addr> [addr ...]   -> extracted/ghidra_dismember/<out-name>.c
out="extracted/ghidra_dismember/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_dismember" DI2dis \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re_dismember" \
  -postScript DismemberDecompileAt.java "$out" "$@" > "extracted/ghidra_dismember/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_dismember/last_decomp.log" | head -5
