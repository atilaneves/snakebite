#!/usr/bin/env bash
# The method of CLAUDE.md for the bytecodes of a loop body: run the guest
# with two iteration counts under bin/sb-count and divide the difference of
# the totals by the difference of the iterations. The body of `work` has a
# few bytecodes, so the answer must not be 0. Needs `ninja bin/sb-count`.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

project=$(mktemp -d)
trap 'rm -rf "$project"' EXIT
mkdir -p "$project/source"
echo 'name "sbcountloop"' > "$project/dub.sdl"
cat > "$project/source/app.d" <<'GUEST'
import std.conv: to;
long work(long n) {
    long sum;
    foreach (i; 0 .. n)
        sum += i ^ 3;
    return sum;
}
int main(string[] args) {
    return work(args[1].to!long) == 42 ? 1 : 0;
}
GUEST

total() {
    bin/sb-count "$project" -- "$1" 2>&1 \
        | awk '/^BCOUNT/ { sum += $2 } END { print sum }'
}

small=$(total 1000)
large=$(total 2000)
perIteration=$(( (large - small) / 1000 ))
echo "bytecodes per iteration: $perIteration (totals $small and $large)"
[ "$perIteration" -gt 0 ]
