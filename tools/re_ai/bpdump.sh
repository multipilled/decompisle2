#!/usr/bin/env bash
# bpdump (Kismet bytecode dumps -> extracted/json_bp) with the local .NET 10. usage: tools/with_cpu.sh zombie-ai tools/re_ai/bpdump.sh <regex>
export DOTNET_ROOT='tools\dotnet10' MSYS_NO_PATHCONV=1
exec tools/bpdump/bin/out/bpdump.exe "$@" 2> >(grep -v 'strange mount' >&2)
