#!/usr/bin/env bash
# Wrapper: local .NET 10 + no MSYS path mangling of regex arguments that start with '/'.
export DOTNET_ROOT='tools\dotnet10' MSYS_NO_PATHCONV=1
exec tools/di2x/bin/out/di2x.exe "$@" 2> >(grep -v 'strange mount' >&2)
