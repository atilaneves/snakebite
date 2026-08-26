#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    # CI only installs the matrix compiler and exports it as $DC; locally
    # there is no $DC and ldc is the default.
    dub run reggae --compiler="${DC:-ldc}" -- -b ninja
fi

ninja bin/ut
bin/ut

# Smoke test: the bench must still build (with ldc, optimised) and run
# against its default fixture with every backend passing. Not a timing
# check, so keep it fast. Output stays visible: when this fails, the
# table and the backends' stderr diagnostics are the explanation.
# Backends are selected explicitly because the interpreter cannot run
# the examples/ct corpus yet: it has no frame stack or locals, so it
# only handles a function body down to its `return`.
build/bench.sh examples/ct -w 0 -r 1 -b ctfe -b dmd

# The unit-threaded fixture only works with the real-workflow row: ctfe
# runs raw `unittest{}` blocks, so `@ShouldFail` reads as a real failure
# (an accepted gap). `-b dmd` selects that row for dub projects too.
build/bench.sh examples/rt -w 0 -r 1 -b dmd

# `bottom-up` loops over a call to `abs`, so the interpreter row here is
# dominated by what an FFI crossing costs it - the loop's own condition,
# increment and accumulation are in the number too, so it bounds that cost
# rather than isolating it. CTFE is left out: it cannot call a function
# whose source it does not have, which is exactly what the loop calls.
build/bench.sh examples/bottom-up -w 0 -r 1 -b dmd -b interpreter
