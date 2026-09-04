#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if [[ ! -f build.ninja ]]; then
    if [[ -n "${REGGAE_BIN:-}" ]]; then
        "$REGGAE_BIN" -b ninja
    else
        dub run "reggae@~>0.16.0" --compiler=ldc -- -b ninja
    fi
fi
