#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# Apply generator version changes to existing builds too.
if [[ ! -f build.ninja || "${BASH_SOURCE[0]}" -nt build.ninja ]]; then
    if [[ -n "${REGGAE_BIN:-}" ]]; then
        "$REGGAE_BIN" -b ninja
    else
        dub run "reggae@~>0.17.0" --compiler=ldc -- -b ninja
    fi
fi
