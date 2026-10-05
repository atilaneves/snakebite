#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

uv run --with pytest==8.4.1 python -m pytest -q \
    tests/run_fault_process.py tests/run_previous_fault_handler.py
