#!/usr/bin/env bash
# Run a GPU-heavy job (engine runs, renders) politely.
#   tools/with_gpu.sh [--exclusive] <job-name> <command...>
# If the machine has a shared GPU-slot script at ~/.claude/bin/with_gpu.sh, the job waits for one of its slots there.
# Otherwise it runs directly at low priority.
# Replace this file only by writing a new copy and mv-ing it over: bash reads running scripts lazily.
shared="$HOME/.claude/bin/with_gpu.sh"
[ -f "$shared" ] && exec bash "$shared" "$@"
[ "$1" = "--exclusive" ] && shift
[ $# -ge 2 ] || { echo "usage: with_gpu.sh [--exclusive] <job-name> <command...>" >&2; exit 2; }
shift
exec nice -n 10 "$@"
