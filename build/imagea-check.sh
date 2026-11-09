#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ ! -f build.ninja ]]; then
    build/reggae.sh
fi
ninja -j2 bin/ut
bin/ut ut.backends.bytecode.imagea

dir=$(mktemp -d /tmp/opencode/imagea-check.XXXXXX)
trap 'rm -f "$dir/loader" "$dir/loader.o" "$dir/sysv.o" "$dir/symbols" "$dir/arithmetic.sbc" "$dir/direct.sbc" "$dir/recursive.sbc" "$dir/data.sbc" "$dir/native.sbc" "$dir/typeinfo.sbc" "$dir/real.sbc" "$dir/float.sbc" "$dir/double.sbc" "$dir/end.sbc" "$dir/adjacentEnd.sbc" "$dir/missing.sbc" "$dir/missing.log"; rmdir "$dir"' EXIT

# No frontend import paths, frontend code, or bytecode compiler are linked.
"${CC:-cc}" -DSNAKEBITE_FORWARD_ONLY -c source/snakebite/ffi/sysv_amd64.S \
    -o "$dir/sysv.o"
"${DMD:-dmd}" -debug -g -preview=dip1000 -version=SbcRuntimeOnly -i -Isource \
    -defaultlib=libphobos2.so -L--no-as-needed \
    build/imagea-load.d "$dir/sysv.o" -of="$dir/loader"
nm -C "$dir/loader" > "$dir/symbols"
if grep -E 'snakebite.*(frontend|bytecode.*compiler)|_D3dmd' "$dir/symbols"; then
    echo 'Image A test loader contains compiler code' >&2
    exit 1
fi
grep -q 'executeCallPlan' "$dir/symbols"
grep -q 'snakebite_ffi_call_sysv_amd64' "$dir/symbols"

# Each save command exits before its corresponding load command starts.
bin/ut --image-a-save "$dir/arithmetic.sbc" arithmetic
"$dir/loader" "$dir/arithmetic.sbc" 7 11 58
bin/ut --image-a-save "$dir/direct.sbc" direct
"$dir/loader" "$dir/direct.sbc" 7 11 12888667586533101800
bin/ut --image-a-save "$dir/recursive.sbc" recursive
"$dir/loader" "$dir/recursive.sbc" 7 11 571
bin/ut --image-a-save "$dir/data.sbc" data
"$dir/loader" "$dir/data.sbc" 7 11 99122
"$dir/loader" "$dir/data.sbc" 5 0 103089
bin/ut --image-a-save "$dir/native.sbc" native
"$dir/loader" "$dir/native.sbc" 7 11 6499122
"$dir/loader" "$dir/native.sbc" 5 0 6503089
bin/ut --image-a-save "$dir/typeinfo.sbc" typeinfo
"$dir/loader" "$dir/typeinfo.sbc" 7 11 91 typeinfo
"$dir/loader" "$dir/typeinfo.sbc" 5 0 78 typeinfo

for fixture in real float double end adjacentEnd; do
    bin/ut --image-a-save "$dir/$fixture.sbc" "$fixture"
    expected=8
    if [[ $fixture == end ]]; then
        expected=3
    fi
    "$dir/loader" "$dir/$fixture.sbc" 7 11 "$expected"
done

python3 - "$dir/native.sbc" "$dir/missing.sbc" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes()
assert b"strlen" in data
Path(sys.argv[2]).write_bytes(data.replace(b"strlen", b"sbnone", 1))
PY
if "$dir/loader" "$dir/missing.sbc" 7 11 6499122 >"$dir/missing.log" 2>&1; then
    echo 'Image A accepted a missing native symbol' >&2
    exit 1
fi
grep -q 'image A cannot resolve process symbol: sbnone' "$dir/missing.log"
