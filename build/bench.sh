#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

compiler=ldc2
command -v "$compiler" > /dev/null 2>&1 || compiler=ldc

# The backends must be optimised for the numbers to mean anything, so this
# builds with LDC in release mode regardless of how bin/ut was built. It
# goes through reggae/ninja, like build/ci.sh does for bin/ut, rather than
# a plain `dub build`, which recompiles every source file it owns in a
# single invocation on every run - even when nothing changed. reggae
# compiles per-file, with real object caching, so only what actually
# changed gets rebuilt. It uses its own build directory, separate from
# bin/ut's build.ninja, since the two are generated from different dub
# configurations.
builddir=.reggae-bench
if [[ ! -f "$builddir/build.ninja" ]]; then
    mkdir -p "$builddir"
    dub run reggae --compiler="$compiler" -- -b ninja -C "$builddir" \
        --dub-config=bench --dub-build-type=release --dc="$compiler" .
fi

ninja -C "$builddir" bench
mkdir -p bin
cp "$builddir/bench" bin/bench

exec bin/bench "$@"
