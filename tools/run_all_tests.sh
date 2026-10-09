#!/usr/bin/env bash
# Every Godot autotest, one after another, each in the background runner (tools/run_test.sh: unfocusable,
# off-screen window) under the game lock. Results: game/test_out/<suite>/ plus a summary on stdout.
#   tools/run_all_tests.sh [suite ...]      suites: flesh autotest combat weapon (default: all)
# Run it as a background task; it never takes focus.
# Environment: the flesh suite (captures, looks) runs on the DI2 level --map=nh04_street by default (recon/TEST_MAP.md);
# TEST_MAP=arena keeps the procedural arena (perf_check comparisons: the map costs ~40 fps of GPU draw count),
# TEST_MAP=<name> picks another built level. The other suites stay on the arena.
# Optional: TEST_EXTRA_ARGS = extra user args for every suite (set, even empty, it replaces the map default),
# TEST_OUT = results root instead of game/test_out (keep map runs apart from the default ones).
set -u
ROOT=.
OUT=${TEST_OUT:-$ROOT/game/test_out}
suites=("$@")
[ ${#suites[@]} -eq 0 ] && suites=(flesh autotest combat weapon)
declare -A ARG=([flesh]="--fleshtest=$OUT/flesh" [autotest]="--autotest=$OUT" [combat]="--combattest=$OUT/combat"
                [weapon]="--weapontest=$OUT/weapon")
declare -A LIMIT=([flesh]=420 [autotest]=600 [combat]=600 [weapon]=1800)
summary=()
for s in "${suites[@]}"; do
  [ -n "${ARG[$s]:-}" ] || { echo "run_all_tests: unknown suite $s"; continue; }
  mkdir -p "$OUT/logs"
  log="$OUT/logs/$s.log"
  start=$(date +%s)
  extra=${TEST_EXTRA_ARGS-__unset__}
  if [ "$extra" = "__unset__" ]; then
    extra=""
    [ "$s" = flesh ] && [ "${TEST_MAP:-nh04_street}" != arena ] && extra="--map=${TEST_MAP:-nh04_street}"
  fi
  RUN_TEST_LIMIT=${LIMIT[$s]} "$ROOT/tools/with_cpu.sh" "tests-$s" "$ROOT/tools/with_lock.sh" "tests-$s" "$ROOT/tools/run_test.sh" ${ARG[$s]} $extra > "$log" 2>&1
  code=$?
  errs=$(grep -cE "SCRIPT ERROR|SHADER ERROR|panicked|\[panic" "$log")
  summary+=("$s: exit $code, $errs script/shader errors, $(( $(date +%s) - start ))s, log $log")
done
printf '%s\n' "${summary[@]}"
