#!/bin/sh
# Decompile DI2 exe functions with the zombie-AI session's own headless Ghidra project (extracted/ghidra_ai/DI2hr,
# a copy of the animation session's -noanalysis import; functions are created on demand). Static analysis only.
# usage: tools/with_cpu.sh zombie-ai tools/re_hitreact/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_ai/<out-name>.c
out="extracted/ghidra_ai/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_ai" DI2hr \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re_anim" \
  -postScript AnimDecompileAt.java "$out" "$@" > "extracted/ghidra_ai/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_ai/last_decomp.log" | head -5
