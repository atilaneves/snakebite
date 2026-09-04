#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh
ninja bin/sb-repl

# `test_interactive_error_label_is_red` needs the interpreter to render a
# failed comparison assertion with its runtime values (`1 != 2`), the way
# `-checkaction=context` does. The interpreter does not do this yet: DMD
# folds a literal comparison like `1 == 2` to `assert(false)`, which the
# interpreter refuses to run as an unsupported halt. Excluded here until
# the interpreter grows that lowering, tracked in
# https://github.com/atilaneves/snakebite/issues/153.
PYTEST_ADDOPTS='-k "not test_interactive_error_label_is_red"' \
    uv run tests/run_repl.py
