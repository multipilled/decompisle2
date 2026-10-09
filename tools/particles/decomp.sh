#!/bin/sh
# Decompile DI2 exe functions with this session's own headless Ghidra project (extracted/ghidra_particles/DI2part,
# a copy of the -noanalysis import; functions are created on demand). Static analysis only: the exe is never run.
# usage: tools/with_cpu.sh particles tools/particles/decomp.sh <out-name> <addr> [addr ...] -> extracted/ghidra_particles/<out-name>.c
out="extracted/ghidra_particles/$1.c"; shift
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_particles" DI2part \
  -process DeadIsland-Win64-Shipping.exe -noanalysis -scriptPath "tools\particles" \
  -postScript ParticlesDecompileAt.java "$out" "$@" > "extracted/ghidra_particles/last_decomp.log" 2>&1
grep -c "^// =====" "$out" 2>/dev/null; grep -E "ERROR|Exception" "extracted/ghidra_particles/last_decomp.log" | head -5
