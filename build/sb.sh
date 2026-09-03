#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

compiler=${LDC:-ldc2}
command -v "$compiler" > /dev/null

builddir=bin/sb-build
if [[ ! -f "$builddir/build.ninja" ]]; then
    mkdir -p "$builddir"
    dub run "reggae@~>0.14.0" --compiler=ldc -- -b ninja -C "$PWD/$builddir" \
        --dub-config=sb --dub-build-type=release --dc="$compiler" "$PWD"
fi

ninja -C "$builddir" sb
install -m 755 "$builddir/sb" bin/sb
printf "\n"
bin/sb "$@"
