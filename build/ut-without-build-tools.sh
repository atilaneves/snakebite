#!/usr/bin/env bash
# Runs bin/ut with a stub of each compiler, linker and dub first on PATH.
# A test that starts one of them makes the stub write its name to a log and
# exit with a failure, and the run fails. The tests of what a build gives
# the user belong in tests/run_*.py, which run the real bin/sb.
# Arguments are passed on to bin/ut.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

stubs=$(mktemp -d)
trap 'rm -rf "$stubs"' EXIT
log="$stubs/started"
touch "$log"
mkdir "$stubs/bin"
for tool in dmd ldc2 ldmd2 gdc gcc g++ cc c++ cpp clang clang++ ld ld.bfd \
        ld.gold ld.lld mold collect2 dub; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 97\n' "$tool" "$log" \
        > "$stubs/bin/$tool"
    chmod +x "$stubs/bin/$tool"
done

status=0
PATH="$stubs/bin:$PATH" bin/ut "$@" || status=$?
if [[ -s "$log" ]]; then
    echo "bin/ut started a build tool:" >&2
    cat "$log" >&2
    status=1
fi
exit "$status"
