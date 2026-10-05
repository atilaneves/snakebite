#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

source build/pytest-workers.sh
uv run tests/run_flags.py
