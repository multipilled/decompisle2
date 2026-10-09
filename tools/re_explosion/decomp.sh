#!/bin/sh
# Decompile DI2 exe functions (explosion RE) with the headless Ghidra project extracted/ghidra (DI2, no analysis).
# usage: tools/re_explosion/decomp.sh <out-name> <addr> [addr ...]   -> extracted/ghidra/explosion_<out-name>.c
out="extracted/ghidra/explosion_$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra" DI2 \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re" \
  -postScript DecompileAt.java "$out" "$@" > "extracted/ghidra/explosion_last.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra/explosion_last.log" | head -5
