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
# the first run of a new binary also builds the dependency image.
set -euo pipefail
sb=$(realpath "$1"); core=$2; k=$3; shift 3
awfy=$HOME/coding/d/awfy/benchmarks/D
declare -A inner=([Sieve]=150 [Mandelbrot]=500 [Richards]=2 [Storage]=20 [List]=40)
benches=("$@"); [ ${#benches[@]} -eq 0 ] && benches=(Sieve Mandelbrot Richards Storage List)
run() {
    (cd "$awfy" && taskset -c "$core" "$@" "$sb" --DRT-gcopt=disable:1 -b interpreter \
        -I src src -- --DRT-testmode=run-main "${args[@]}")
}
count() {
    local out
    args=("$1" "$2" "$3")
    out=$(run perf stat -x, -e instructions:u 2>&1 >/dev/null)
    if ! grep -q instructions <<<"$out"; then echo "FAILED $1 $2: $out" >&2; exit 1; fi
    grep instructions <<<"$out" | cut -d, -f1
}
args=(Sieve 1 1); run >/dev/null 2>&1
printf '%-11s %16s %16s\n' benchmark instr/iteration first-run
for b in "${benches[@]}"; do
    a=$(count "$b" 1 "${inner[$b]}")
    z=$(count "$b" $((1 + k)) "${inner[$b]}")
    it=$(( (z - a) / k ))
    printf '%-11s %16d %16d\n' "$b" "$it" $(( a - it ))
done
