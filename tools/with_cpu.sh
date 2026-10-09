#!/usr/bin/env bash
# Run a heavy job (build, engine run, exporter, big scan) politely.
#   tools/with_cpu.sh <job-name> <command...>
# If the machine has a shared job-slot script at ~/.claude/bin/with_cpu.sh (several projects sharing one PC), the job
# waits for one of its slots there. Otherwise it runs directly at low priority.
# Never pass a script on stdin (`with_cpu.sh me python - <<EOF`): the job may run in the background. Write a file.
# Replace this file only by writing a new copy and mv-ing it over: bash reads running scripts lazily.
shared="$HOME/.claude/bin/with_cpu.sh"
[ -f "$shared" ] && exec bash "$shared" "$@"
[ $# -ge 2 ] || { echo "usage: with_cpu.sh <job-name> <command...>" >&2; exit 2; }
shift
for a in "$@"; do [ "$a" = "-" ] && { echo "with_cpu: refusing a script on stdin; write it to a file" >&2; exit 2; }; done
exec nice -n 10 "$@"
