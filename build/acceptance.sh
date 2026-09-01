#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

compiler=${LDC:-ldc2}
command -v "$compiler" > /dev/null

builddir=bin/acceptance
if [[ ! -f "$builddir/build.ninja" ]]; then
    mkdir -p "$builddir"
    dub run "reggae@~>0.14.0" --compiler=ldc -- -b ninja -C "$PWD/$builddir" \
        --dub-config=acceptance-test --dub-build-type=unittest \
        --dc="$compiler" "$PWD"
fi

ninja -C "$builddir" at
install -m 755 "$builddir/at" bin/at
bin/at "$@"
