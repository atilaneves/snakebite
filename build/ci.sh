#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh
ninja
# Local full-suite measurements favour one worker (@TIMES@).
build/ut-without-build-tools.sh -j 1
# The tests tagged `@Tags("alone")` need a process in which no other
# test runs: they gate on measured times, or they count what the process
# holds while no other thread starts. Run them on their own,
# single-threaded, so they never share the process with other tests.
bin/at '~@alone'
bin/at -s '@alone'
build/test-repl.sh
build/test-cli.sh
build/test-flags.sh
build/test-fault-process.sh
bin/sb -b bytecode examples/rt-simple
build/benches.sh
