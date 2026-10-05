#!/usr/bin/env bash
# Records `describe.json` of each fixture here from the real `dub describe`.
# Run it again when tests/run_cli.py reports that a recording is stale.
# Each directory holds the project(s) to describe and `describe.cmd`: the
# project subdirectory, then the arguments of `dub describe`. The fixture's
# own path in the output is written as `@ROOT@`, and the artifact path of
# dub's build cache, which depends on the home directory and on a hash of
# the project path, is written as `<machine specific>`.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for fixture in */; do
    fixture=${fixture%/}
    cp -r "$fixture" "$scratch/$fixture"
    read -r project arguments < "$fixture/describe.cmd"
    # shellcheck disable=SC2086
    (cd "$scratch/$fixture/$project" && dub describe $arguments 2>/dev/null) \
        | sed -e "s|$scratch/$fixture|@ROOT@|g" \
            -e 's|"cacheArtifactPath": "[^"]*"|"cacheArtifactPath": "<machine specific>"|' > "$fixture/describe.json"
done
