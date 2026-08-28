#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

compiler=${LDC:-ldc2}
command -v "$compiler" > /dev/null

# The backends must be optimised for the numbers to mean anything, so this
# builds with LDC in release mode regardless of how bin/ut was built. It
# goes through reggae/ninja, like build/ci.sh does for bin/ut, rather than
# a plain `dub build`, which recompiles every source file it owns in a
# single invocation on every run - even when nothing changed. reggae
# compiles per-file, with real object caching, so only what actually
# changed gets rebuilt. It uses its own build directory, separate from
# bin/ut's build.ninja, since the two are generated from different dub
# configurations.
builddir=bin
if [[ ! -f "$builddir/build.ninja" ]]; then
    mkdir -p "$builddir"
    # Absolute paths: reggae bakes these arguments into the generated
    # regeneration rule, which ninja runs from inside $builddir, where
    # relative paths would no longer resolve.
    dub run reggae --compiler=ldc -- -b ninja -C "$PWD/$builddir" \
        --dub-config=bench --dub-build-type=release --dc="$compiler" "$PWD"
fi

ninja -C "$builddir" bench
printf "\n"
echo "----------------------------------------"
bin/bench "$@"
printf "\n"
