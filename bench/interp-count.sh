#!/usr/bin/env bash
# Usage: interp-count.sh <path to bin/sb> <cpu core> <extra iterations K> [benchmark ...]
#
# Prints user-space instructions per AWFY outer iteration for the
# interpreter, from the D port in ~/coding/d/awfy/benchmarks/D.
# Per-iteration = (count at outer 1+K - count at outer 1) / K, which removes
# start-up and frontend work. first-run = count at outer 1 minus one
# iteration: frontend, start-up and one-time preparation.
#
# The host GC is disabled: with it on, a collection in one run and not in
# another moved counts by up to 1.3 G. One warm-up run comes first, because
# the first run of a new binary also builds the dependency image. Address
# randomisation is off: with it on, runs of the same
# binary differed by up to 50 M (Storage); without it they agree within 100.
set -euo pipefail
sb=$(realpath "$1"); core=$2; k=$3; shift 3
awfy=$HOME/coding/d/awfy/benchmarks/D
declare -A inner=([Json]=100 [Sieve]=150 [Mandelbrot]=500 [Richards]=2 [Storage]=20 [List]=40 [NBody]=250000 [Havlak]=1 [DeltaBlue]=100)
benches=("$@"); [ ${#benches[@]} -eq 0 ] && benches=(Sieve Mandelbrot Richards Storage List)
run() {
    (cd "$awfy" && taskset -c "$core" setarch -R "$@" "$sb" --DRT-gcopt=disable:1 -b interpreter \
        -I src src -- --DRT-testmode=run-main "${args[@]}")
}
# A failing run stops the script: perf stat exits with the guest status, but
# set -e does not reach into $(...), so every status is checked here.
fail() {
    echo "FAILED $1 outer=$2 (status $3); guest output:" >&2
    cat "$tmp/guest" >&2
    exit 1
}
count() {
    args=("$1" "$2" "$3")
    local rc=0
    run perf stat -x, -o "$tmp/perf" -e "$events" >"$tmp/guest" 2>&1 || rc=$?
    [ $rc -eq 0 ] || fail "$1" "$2" $rc
    grep instructions "$tmp/perf" | cut -d, -f1 | awk '/^[0-9]+$/ { s += $1 } END { print s }'
}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# A hybrid CPU has one PMU per core type, and each counts only on its own
# cores; the sum is right on any core.
if [ -d /sys/bus/event_source/devices/cpu_core ]; then
    events=cpu_core/instructions/u,cpu_atom/instructions/u
else
    events=instructions:u
fi
args=(Sieve 1 1); rc=0
run >"$tmp/guest" 2>&1 || rc=$?
[ $rc -eq 0 ] || fail warm-up 1 $rc
printf '%-11s %16s %16s\n' benchmark instr/iteration first-run
for b in "${benches[@]}"; do
    a=$(count "$b" 1 "${inner[$b]}")
    z=$(count "$b" $((1 + k)) "${inner[$b]}")
    it=$(( (z - a) / k ))
    printf '%-11s %16d %16d\n' "$b" "$it" $(( a - it ))
done
