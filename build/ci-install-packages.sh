#!/usr/bin/env bash
# Installs what the CI build needs, and checks it is there.
# The apt mirror of the runners is sometimes unreachable. A failed
# install does not end the script: what the machine already has can be enough.
#   strace, patch: commands on the PATH.
#   libreadline.so: the link name of -lreadline (the D bindings declare
#     their own prototypes, so no C header is used).

libdir=${LIBDIR:-/usr/lib/x86_64-linux-gnu}

if [ -z "$SKIP_APT" ]; then
    sudo apt-get update || echo "apt-get update failed"
    sudo apt-get install -y -o Acquire::Retries=5 libreadline-dev strace patch ||
        echo "apt-get install failed"
fi

has_readline_so() {
    ldconfig -p | grep -q '[[:space:]]libreadline\.so[[:space:]]' || [ -e "$libdir/libreadline.so" ]
}

if ! has_readline_so; then
    runtime=$(ls "$libdir"/libreadline.so.8* 2>/dev/null | head -n 1)
    if [ -n "$runtime" ]; then
        sudo ln -s "$runtime" "$libdir/libreadline.so"
        echo "libreadline-dev was not installed: made $libdir/libreadline.so by hand, pointing to $runtime"
    fi
fi

missing=
for cmd in strace patch; do
    command -v "$cmd" > /dev/null || missing="$missing $cmd"
done
has_readline_so || missing="$missing libreadline.so"

if [ -n "$missing" ]; then
    echo "error: missing after install:$missing"
    exit 1
fi
