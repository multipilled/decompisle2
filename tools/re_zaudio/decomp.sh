#!/bin/sh
# Decompile DI2 exe functions with the zombie-audio session's own headless Ghidra project
# (extracted/ghidra_zaudio/DI2zaudio, a copy of the -noanalysis import; functions are created on demand).
# Static analysis only: the exe is never run.
# usage: tools/with_cpu.sh zaudio tools/re_zaudio/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_zaudio/<out-name>.c
out="extracted/ghidra_zaudio/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_zaudio" DI2zaudio \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\re_zaudio" \
  -postScript ZAudioDecompileAt.java "$out" "$@" > "extracted/ghidra_zaudio/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_zaudio/last_decomp.log" | head -5
