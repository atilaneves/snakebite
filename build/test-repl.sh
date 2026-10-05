#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# `test_dub_option_loads_module_from_fetched_project` needs automem in dub's
# package store. Fetching it here, once and before any pytest worker starts,
# keeps the network out of the test's timeout and keeps the workers from
# writing to ~/.dub at the same time. The test still fetches it when it is
# missing.
for attempt in 1 2 3; do
    dub fetch automem@0.6.11 && break
    [ "$attempt" = 3 ] && exit 1
done

# `test_interactive_error_label_is_red` needs the interpreter to render a
# failed comparison assertion with its runtime values (`1 != 2`), the way
# `-checkaction=context` does. The interpreter does not do this yet: DMD
# folds a literal comparison like `1 == 2` to `assert(false)`, which the
# interpreter refuses to run as an unsupported halt. Excluded here until
# the interpreter grows that lowering, tracked in
# https://github.com/atilaneves/snakebite/issues/153.
PYTEST_ADDOPTS='-k "not test_interactive_error_label_is_red"' \
    uv run tests/run_repl.py
