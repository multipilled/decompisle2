#!/bin/sh
# One-time import of DI2's shipping exe into extracted/ghidra_anim/DI2anim (no auto-analysis). Never runs the exe.
"C:/Tools/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat" "extracted\ghidra_anim" DI2anim \
  -import "C:/Program Files (x86)/Steam/steamapps/common\Dead Island 2\DeadIsland\Binaries\Win64\DeadIsland-Win64-Shipping.exe" \
  -noanalysis > "extracted/ghidra_anim/import.log" 2>&1
tail -3 "extracted/ghidra_anim/import.log"
