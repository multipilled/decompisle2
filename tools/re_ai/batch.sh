#!/usr/bin/env bash
# One CPU slot for a whole RE round: strings / refs / callers, then decompile the functions found.
#   tools/with_cpu.sh zombie-ai tools/re_ai/batch.sh <out-name> "<python tools/re_ai/... args>" [extra addrs...]
# Every hex address the python step prints in its 2nd+ columns is decompiled to extracted/ghidra_ai/<out-name>.c.
out="$1"; cmd="$2"; shift 2
cd .
res=$(eval "$cmd")
echo "$res" > "extracted/ghidra_ai/$out.txt"
addrs=$(echo "$res" | awk '{for (i = 2; i <= NF; i++) if ($i ~ /^0x14/) print $i}' | sort -u | head -40)
tools/re_ai/decomp.sh "$out" $addrs "$@"
