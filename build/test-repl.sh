#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

source build/pytest-workers.sh

# `test_dub_option_loads_module_from_fetched_project` needs automem and its
# dependencies in dub's package store. Run here, before pytest starts, the
# two commands that `sb --dub` runs: fetch, then describe. Describe is the
# step that downloads the dependencies, so the test needs no network.
# One bounded attempt: a retry with no event to wait for does not help
# against a network that is down. If it fails, the test fails with the
# message of `sb` and the other tests still run.
if ! timeout 120 dub fetch automem@0.6.11 \
    || ! timeout 120 dub describe automem@0.6.11 \
        --data=working-directory --data-list > /dev/null; then
    echo "warning: could not prepare automem@0.6.11;" \
        "test_dub_option_loads_module_from_fetched_project will fail" >&2
fi

uv run tests/run_repl.py
