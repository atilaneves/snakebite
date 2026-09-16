#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh
ninja
bin/ut
# `at.ffi.cost.barrier.overhead` carries `@Tags("timing")` and gates a
# ratio, not a pass/fail result. Run it on its own, single-threaded, so
# it never shares a core with the other acceptance tests. Running both
# in one `bin/at` call would put `at.bench.timing`'s compiler processes
# on the same machine as the timing gate, which moves the gate's ratio
# (see `acceptance/at/ffi/cost.d`).
bin/at '~@timing'
bin/at -s '@timing'
build/test-repl.sh
bin/sb -b bytecode examples/rt-simple
build/benches.sh
