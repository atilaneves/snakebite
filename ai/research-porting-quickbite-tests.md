# Porting guest snippets from quickbite

quickbite states a guest program as a `q{...}` module of `unittest` blocks
and runs them all. snakebite runs a `main` and checks the exit status, so a
port renames the blocks. `build/port/` holds the scripts that do it.

## The decision

`tests/ut/backends/run/` holds 45 ported tests, on the native backend only.
They state what compiled D does with each construct. Other backends join a
test when they agree.

45 is not a compromise between coverage and cost. 45 snippets reach every
AST node class that all 1344 reach, so the other 1265 add no construct.

## How the set is chosen

`extract-snippets.py` reads the `q{...}` bodies out of a test tree, with the
call-site text after each one, which carries the assertion.

`astcover.d` says which AST node classes a snippet reaches. Drop it into
`tests/ut/`, add it to `tests/main.d`, and build. It overrides every `visit`
overload of dmd's `SemanticTimeTransitiveVisitor` and records
`astTypeName` for each node the walk reaches.

`cover-set.py` then repeatedly takes whichever snippet reaches the most
classes that nothing taken so far reaches. Set cover is NP-hard, so this is
the greedy approximation, and the result is small rather than smallest.

Each test is named for the class it was taken for, and filed by that class
as well. Filing a test by what its guest happens to contain is what put a
`real` literal test under arrays: a guest needs an array to have something
to concatenate, so what it contains says less than why it was chosen.

The expected exit status is measured, not derived: `cover-set.py` runs each
guest through `dmd -run`. An earlier version read the status from the
quickbite assertion the extractor kept, which was wrong twice. One guest
asserts `dg.ptr is null` for a delegate to a nested function, which is
false in compiled D. Another was paired with the message "`dg.funcptr`
cannot be evaluated at compile time", which states what a backend refused,
not what D does.

## What the numbers were

Measured against quickbite's 1344 snippets and snakebite's own 63:

- snakebite reached 37 AST node classes, quickbite 151, of the 292 dmd's
  visitor knows.
- 45 snippets reach all 151. 4 reach half of them.
- 45 snippets are 985 lines. All 1344 are 23084.

Greedy cover, by how many snippets it takes:

| snippets | classes | of 151 |
|---|---|---|
| 5 | 90 | 60% |
| 10 | 109 | 72% |
| 20 | 126 | 83% |
| 30 | 136 | 90% |
| 45 | 151 | 100% |

Reaching each class more than once costs more snippets: twice needs 79,
three times 110, five times 154. A set that reaches each class once leaves
each construct stated by one guest, so one wrong value in a backend can
still pass. This is the strongest argument for a larger set, and it is why
the depth is worth revisiting once a backend runs the current set.

Mutating one asserted integer per snippet killed 32 of 33 in the cover set
and 77 of 78 in a random sample. One survivor each: the samples do not
tell the two apart, and neither shows whether the tail pins anything the
cover set does not.

## Cover against `examples/ct`

`examples/ct/source/corpus.d` reaches 118 AST node classes. The quickbite
corpus reaches 115 of them, and 24 snippets are enough.

The 3 it misses are `StaticIfCondition`, `StaticForeachStatement` and
`ConditionalStatement`. Of 1344 snippets, 1 uses `static if`, none use
`static foreach`, and none use `version`. ct's `encode` and `decode` are
built out of all three, so these tests have to be written rather than
ported.

`ctfe` already runs ct. `interpreter` stops at the first `blit`.

## Cost

The whole suite runs in 663 ms, of which the 45 tests are 309 us. The
native backend is compiled into `bin/ut`, so it pays for its link once for
the binary rather than once a test.

Backends that interpret cost about 1.5 ms a test, measured over a larger
set on `ctfe` and `interpreter` together. A backend that links per test
costs far more: quickbite's suite takes about 30 minutes for 1394 tests,
about 1.3 seconds each, which is a `dmd -shared` and a system linker every
time. Corpus size becomes wall-clock time as soon as such a backend
exists, which is the second reason to keep the set small.

## What does not port

The native oracle mixes a guest into `struct Guest { static: mixin(code); }`
at function scope. Three consequences, all compile or link errors rather
than wrong answers:

- UFCS does not find a function the guest itself declared.
- A guest function passing a closure to a template cannot be instantiated.
- `main` must take no arguments.

Only a real module fixes the first two, which would cost the inline
`q{...}` the tests are written in. `cover-set.py` rejects these before it
chooses, so the cover takes another snippet for those classes instead of
losing them.

A guest also runs in the test runner's own process, so a guest that faults
- a null dereference, `int.min % -1` - takes `bin/ut` down with it instead
of failing.

## Porting the whole corpus

`port-snippet.py` ports everything rather than a cover set. 1320 of 1344
snippets emit, and 17 more fail to build, link or run for the reasons
above. The remaining 1303 run in 235 ms on the native backend and take
3.5 s to rebuild. `--nodes` files them by construct and `--max-per-module`
splits a large topic, since quickbite put 497 of its 1344 into one 16629
line `expressions.d`.

This is measured, not recommended. 1303 tests reach no more constructs
than 45, and every one of them is a file to read past.
