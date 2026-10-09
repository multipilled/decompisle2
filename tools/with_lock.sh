#!/usr/bin/env bash
# Hold the repo's game lock while a command runs (anything that runs the game or rebuilds a shared artifact such as
# the Rust gore_godot library), so two jobs never fight over it.
#   tools/with_lock.sh <job-name> <command...>      LOCK_NAME=<name> picks a different lock (default game)
# The lock lives next to the main checkout's .git, so every worktree shares it. If the machine has a shared lock script
# at ~/.claude/bin/with_lock.sh it is used; otherwise a simple mkdir lock with a PID stale check below.
# Replace this file only by writing a new copy and mv-ing it over: bash reads running scripts lazily.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$here/../.git")
root="$(dirname "$common")"
shared="$HOME/.claude/bin/with_lock.sh"
[ -f "$shared" ] && WITH_LOCK_ROOT="$root" exec bash "$shared" "$@"
[ $# -ge 2 ] || { echo "usage: with_lock.sh <job-name> <command...>" >&2; exit 2; }
who="$1"; shift
lock="$root/.git/${LOCK_NAME:-game}.lock"
[ -d "$root/.git" ] || lock="$common/${LOCK_NAME:-game}.lock"
while ! mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  sleep 2
done
echo $$ > "$lock/pid"; echo "$who" > "$lock/owner"
trap 'rm -rf "$lock"' EXIT
"$@"
