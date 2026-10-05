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

# A line of a successful start is `PID execve("PATH", [...], ...) = 0`. strace
# splits it into an `<unfinished ...>` line and a `<... execve resumed>` line
# when other processes write between them. A start that failed (`= -1 ENOENT`)
# is a lookup along PATH, not a start. The first start is bin/ut itself.
unexpected=$(awk -v allowed="$allowed" '
    /execve(at)?\("/ {
        path = $0
        sub(/^[^"]*"/, "", path)
        sub(/".*/, "", path)
        if ($0 ~ /<unfinished/) { pending[$1] = path; next }
        if ($0 ~ /\) += 0$/) started[++count] = path
        next
    }
    /<\.\.\. execve(at)? resumed>/ {
        if ($0 ~ /\) += 0$/ && ($1 in pending)) started[++count] = pending[$1]
        delete pending[$1]
    }
    END {
        for (i = 2; i <= count; i++) {
            name = started[i]
            sub(".*/", "", name)
            if (name !~ allowed) print started[i]
        }
    }' "$trace")

if [[ -n "$unexpected" ]]; then
    echo "bin/ut started a program that is not a test helper:" >&2
    echo "$unexpected" | sort | uniq -c >&2
    status=1
fi
exit "$status"
