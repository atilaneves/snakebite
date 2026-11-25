#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# Apply generator version changes to existing builds too.
if [[ ! -f build.ninja || "${BASH_SOURCE[0]}" -nt build.ninja ]]; then
    if [[ -n "${REGGAE_BIN:-}" ]]; then
        "$REGGAE_BIN" -b ninja
    else
        # The LDC of the build (reggaefile.d), not `ldc`: install.sh's LDC
        # has no program of that name, so `ldc` is the system LDC.
        dub run "reggae@~>0.18.0" --build=release --compiler="${LDC:-ldc2}" -- -b ninja
    fi
fi
