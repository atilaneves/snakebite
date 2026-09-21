#!/usr/bin/env bash
set -euo pipefail
prototype_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dub_source="${DUB_SOURCE:-$HOME/.dub/packages/dub/1.42.0/dub/source}"
ldc2 -O2 -i -I="$dub_source" -d-version=DubUseCurl -L-lcurl \
    "$prototype_dir/main.d" -of="$prototype_dir/prototype"
exec "$prototype_dir/prototype" "$@"
