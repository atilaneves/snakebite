#!/usr/bin/env bash
# The one place that states the compilers that build snakebite. The build
# gets them with the official D installer (https://dlang.org/install.sh),
# which installs a named version below ~/dlang when it is not there yet. A
# compiler on PATH never builds snakebite.
#
#   build/compilers.sh dmd|ldc2|dub  the absolute path of that program
#   build/compilers.sh path          the bin directories of dmd and LDC, as
#                                    a PATH prefix
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# dmd is the version of the dmd frontend library that snakebite links, the
# `dmd` selection in dub.selections.json: the two cannot disagree.
dmd=dmd-$(python3 -c 'import json, sys; print(json.load(sys.stdin)["versions"]["dmd"])' \
    < dub.selections.json)
# LDC's frontend must be the dmd version above, and vendor/ldc-frontend must
# hold the patch of LDC's additions for this LDC version (see reggaefile.d).
ldc=ldc-1.43.0

installer=$HOME/dlang/install.sh
if [[ ! -x $installer ]]; then
    mkdir -p "$(dirname -- "$installer")"
    curl -fsSL https://dlang.org/install.sh -o "$installer.part"
    chmod +x "$installer.part"
    mv "$installer.part" "$installer"
fi

# The path of the program of `compiler` that `install.sh get-path` gives for
# the option `flag`; installs `compiler` first when it is not installed.
program() {
    local compiler=$1 flag=${2:-}
    if ! "$installer" get-path $flag "$compiler" > /dev/null 2>&1; then
        "$installer" install "$compiler" >&2
    fi
    "$installer" get-path $flag "$compiler"
}

case ${1:-} in
    dmd) program "$dmd" ;;
    ldc2) program "$ldc" ;;
    dub) program "$dmd" --dub ;;
    path) echo "$(dirname -- "$(program "$dmd")"):$(dirname -- "$(program "$ldc")")" ;;
    *)
        echo "usage: $0 dmd|ldc2|dub|path" >&2
        exit 2
        ;;
esac
