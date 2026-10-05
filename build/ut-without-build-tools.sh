#!/usr/bin/env bash
# Runs bin/ut under strace and fails when it starts any program other than
# the helpers of the tests: `sh` and `sleep`. A test of what a build gives the
# user belongs in tests/run_*.py, which run the real bin/sb. This is the rule
# that no test in bin/ut starts a compiler, a linker or dub, by any name, any
# path or any environment variable. strace sees each successful execve of the
# process and of every thread and child it makes.
# Arguments are passed on to bin/ut.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

allowed='^(sh|sleep)$'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trace="$work/execve.log"

status=0
strace -f -qq -e trace=execve,execveat -o "$trace" bin/ut "$@" || status=$?

# A line of a successful start is `PID execve("PATH", [...], ...) = 0`. A
# start that failed (`= -1 ENOENT`) is a lookup along PATH, not a start. The
# first start is bin/ut itself.
unexpected=$(grep -E '\) += 0$' "$trace" \
    | sed -E 's/^[^"]*"([^"]*)".*/\1/' \
    | tail -n +2 \
    | awk -v allowed="$allowed" '{ name = $0; sub(".*/", "", name) }
        name !~ allowed { print }' || true)

if [[ -n "$unexpected" ]]; then
    echo "bin/ut started a program that is not a test helper:" >&2
    echo "$unexpected" | sort | uniq -c >&2
    status=1
fi
exit "$status"
