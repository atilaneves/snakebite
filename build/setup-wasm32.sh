#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

dmd_revision=0864cee4e9d091355e86ef8457789142c97bcb10
phobos_revision=0f0bf79d32c2b876e755c01ad1e34a5284caa39d
wasmtime_version=46.0.1
virgil_revision=dc8fca33bbacf5c20aa434d35749902d23a5f814
wizard_revision=672e9cea2ac3f971263d78a7840a5d9a8facf45f
tool_dir="${SNAKEBITE_WASM32_ROOT:-$PWD/.tools/wasm32}"
mkdir -p "$tool_dir"
tool_dir=$(cd "$tool_dir" && pwd)

case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) wasmtime_host=x86_64-linux ;;
    Linux/aarch64) wasmtime_host=aarch64-linux ;;
    *) echo 'The wasm32 setup script requires Linux x86_64 or AArch64.' >&2; exit 1 ;;
esac

for tool in curl tar make dub dmd clang wasm-ld sha256sum; do
    command -v "$tool" >/dev/null || {
        echo "Missing prerequisite: $tool" >&2
        exit 1
    }
done

fetch_source() (
    local repository=$1 revision=$2 destination=$3
    if [[ -f "$destination/.snakebite-revision" ]] &&
       [[ $(cat "$destination/.snakebite-revision") == "$revision" ]]; then
        return
    fi
    if [[ -e "$destination" ]]; then
        echo "Source directory already exists with another revision: $destination" >&2
        exit 1
    fi
    local staging
    staging=$(mktemp -d "$tool_dir/source.XXXXXX")
    trap 'rm -r "$staging"' EXIT
    curl --fail --location --retry 3 \
        "https://codeload.github.com/$repository/tar.gz/$revision" \
        -o "$staging/source.tar.gz"
    mkdir "$staging/source"
    tar -xzf "$staging/source.tar.gz" --strip-components=1 -C "$staging/source"
    printf '%s\n' "$revision" > "$staging/source/.snakebite-revision"
    mv "$staging/source" "$destination"
)

fetch_source dlang/dmd "$dmd_revision" "$tool_dir/dmd"
fetch_source dkorpel/phobos "$phobos_revision" "$tool_dir/phobos"

wasmtime_name="wasmtime-v$wasmtime_version-$wasmtime_host"
if [[ ! -x "$tool_dir/$wasmtime_name/wasmtime" ]]; then
    curl --fail --location --retry 3 \
        "https://github.com/bytecodealliance/wasmtime/releases/download/v$wasmtime_version/$wasmtime_name.tar.xz" \
        -o "$tool_dir/$wasmtime_name.tar.xz"
    tar -xJf "$tool_dir/$wasmtime_name.tar.xz" -C "$tool_dir"
fi

dmd_stamp="$tool_dir/dmd/.snakebite-release-build"
dmd_build_settings="$dmd_revision ENABLE_RELEASE=1 HOST_DMD=$(command -v dmd)"
if [[ ! -f "$dmd_stamp" || $(cat "$dmd_stamp") != "$dmd_build_settings" ]]; then
    make -C "$tool_dir/dmd" clean
fi
make -C "$tool_dir/dmd" -j"${JOBS:-$(nproc)}" \
    HOST_DMD="$(command -v dmd)" ENABLE_RELEASE=1 dmd
printf '%s\n' "$dmd_build_settings" > "$dmd_stamp"

# The two runtime archive rules can fetch the same tarball in parallel.
# Supply the complete, checked archive before starting those rules.
wasi_archive="$tool_dir/dmd/generated/wasm/wasi-sysroot-33.tar.gz"
wasi_sha256=063bc1b56582b9923e08ac9b89e58789618d851763f01530b3ff20b9e5df0ca3
mkdir -p "$(dirname "$wasi_archive")"
if [[ ! -f "$wasi_archive" ]]; then
    curl --fail --location --retry 3 \
        'https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/wasi-sysroot-33.0%2Bm.tar.gz' \
        -o "$wasi_archive.download"
    printf '%s  %s\n' "$wasi_sha256" "$wasi_archive.download" | sha256sum -c -
    mv "$wasi_archive.download" "$wasi_archive"
fi
printf '%s  %s\n' "$wasi_sha256" "$wasi_archive" | sha256sum -c -
make -C "$tool_dir/dmd/druntime" -j"${JOBS:-$(nproc)}" wasm
# ImportC must use the WASI headers, not the host's libc headers.
if [[ ! -d "$tool_dir/wasi-sysroot-33.0+m" ]]; then
    tar -xzf "$tool_dir/dmd/generated/wasm/wasi-sysroot-33.tar.gz" -C "$tool_dir"
fi
make -C "$tool_dir/phobos" -j"${JOBS:-$(nproc)}" wasm \
    WASM_DMD="$tool_dir/dmd/generated/linux/release/64/dmd -cpp=clang -P-E -P--target=wasm32-wasi -P-Wno-deprecated -P--sysroot=$tool_dir/wasi-sysroot-33.0+m"

if [[ "$(uname -m)" == x86_64 ]]; then
    fetch_source titzer/virgil "$virgil_revision" "$tool_dir/virgil"
    make -C "$tool_dir/virgil" -j"${JOBS:-$(nproc)}" bootstrap
    fetch_source titzer/wizard-engine "$wizard_revision" "$tool_dir/wizard"
    (
        cd "$tool_dir/wizard"
        PATH="$tool_dir/virgil/bin:$PATH" ./build.sh --nojit wizeng x86-64-linux
        cp bin/wizeng.x86-64-linux bin/wizeng.pregen.x86-64-linux
        bin/wizeng.x86-64-linux --pregen=bin/wizeng.pregen.x86-64-linux
    )
fi

mkdir -p "$tool_dir/bin"
ln -sfn "../dmd/generated/linux/release/64/dmd" "$tool_dir/bin/dmd"
ln -sfn "../$wasmtime_name/wasmtime" "$tool_dir/bin/wasmtime"
if [[ -x "$tool_dir/wizard/bin/wizeng.pregen.x86-64-linux" ]]; then
    ln -sfn ../wizard/bin/wizeng.pregen.x86-64-linux "$tool_dir/bin/wizeng"
fi
printf 'Wasm32 tools ready in %s\n' "$tool_dir"
"$tool_dir/bin/dmd" --version
"$tool_dir/bin/wasmtime" --version
wasm-ld --version
