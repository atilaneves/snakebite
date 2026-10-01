#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh
ninja
# Local full-suite measurements favour one worker (52s with the default
# worker count, 43s with one worker).
bin/ut -j 1
# The tests tagged `@Tags("timing")` gate on measured times. Run them
# on their own, single-threaded, so they never share the machine with
# the other acceptance tests.
bin/at '~@timing'
bin/at -s '@timing'
build/test-repl.sh
build/test-cli.sh
build/test-flags.sh
bin/sb -b bytecode examples/rt-simple
build/benches.sh
