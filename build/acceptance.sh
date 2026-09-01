#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

compiler=${LDC:-ldc2}
command -v "$compiler" > /dev/null

builddir=bin/acceptance
if [[ ! -f "$builddir/build.ninja" ]]; then
    mkdir -p "$builddir"
    # No --dub-config: the project's reggaefile.d (root) drives this
    # build and references configs other than acceptance-test (ut, sb),
    # so all dub configs must be probed or reggae crashes looking up a
    # config the restricted set doesn't contain.
    dub run "reggae@~>0.14.0" --compiler=ldc -- -b ninja -C "$PWD/$builddir" \
        --dub-build-type=unittest \
        --dc="$compiler" "$PWD"
fi

ninja -C "$builddir" at
install -m 755 "$builddir/at" bin/at
bin/at "$@"
