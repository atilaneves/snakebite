# Goal

Alternative backends for the D programming language that reduce the
edit to unittest feedback cycle. At least a tree walking interpreter
and a bytecode VM.

# Communication guidelines

Use ASD-STE100 - Simplified Technical English in all communication.

# Design

- The owner's requirement is the goal. A brief, a design and a review state
  it in the owner's words and add no goal of their own. "The smallest change
  that passes the test" is not a goal.
- A design starts from the requirement: state it, derive what must be true
  of the structure, then read the code and list where the code differs.
- Before an implementer starts, the agent that accepts the design checks
  each part of it against the requirement. A part that adds a second copy of
  state or of code is rejected.
- The test is the design in executable code form. Tests follow from the
  requirement and the design; a test that does not follow from them is not
  written. Tests then drive the code inside the structure: "only what the
  test needs" is a rule for code, never for structure.
- When a check fails for new code, change the code until the check passes,
  or ask the owner. Do not put the code outside the check, and do not make
  the check narrower.
- An issue comment, a plan or a handoff that an agent wrote is a source of
  facts to verify. It is not a requirement. Only the owner's words are
  requirements.

# Coding Guidelines

## General

* Existing code that breaks a rule is not a model to copy.
* All code is a liability and must justify its existence. Code that
  doesn't exist to make a test pass should probably be deleted.
* A case that the code treats differently from the general case needs a
  stated reason. With no reason, the general path handles it.
* One True Brace Style. For functions with many attributes, `{` on its
  own line is acceptable.
* Use UFCS liberally.
* Always re-read files before editing; another agent or person may have
  changed them in the meantime.
* Trailing commas.
* Maximise attributes: `@safe @nogc nothrow pure const scope`. Do not
  abuse `@trusted` to make functions `@safe`.
* Private functions below their first use, as close as possible.
* Prefer `std.conv.text`; use `text(x)` not `x.to!string`.
* Make parameters `in` if possible.
* Prefer `const`; use `auto` with a comment if `const` fails; explicit
  LHS type only if `auto` fails (comment why). Explicit types are fine
  for uninitialised declarations.
* No `synchronized`.
* Prefer RAII for a resource that an object owns: the destructor of the
  owner releases it and the use site has `scope`. A release call under
  `scope(exit)` is a sign to check if the owner needs a destructor.
  `scope(exit)` is allowed where a new type is not worth it, such as a C
  API, and for locks: `mutex.lock; scope(exit) mutex.unlock;`.
* Omit empty parens: `doStuff;` not `doStuff();`.
* Variables as close to their usage as possible.
* Use `with` in `switch`/`final switch` with enums for more readability.
* private variables start with an underscore, e.g. `_member`.
* D has modules and types within types, do not use C-like naming
  conventions like `Foo` and `FooEnum`, instead place enums inside the
  corresponding class/struct so that one uses `Foo.Enum` instead.
* Do not use "magic literals" like `foo(true, 0, 42, "bar")`. It's
  impossible to know what those values are from the calling context.
  Either name them with a variable or add a comment. A number in a type
  or in an expression that has a meaning, like the `2` in `size_t[2][]` or
  the `+ 1` in a loop bound, gets a name: an `alias`, an `enum` or a
  named value.
* Do not use `__gshared` unless absolutely necessary. Shared code
  should be `immutable` if it can be, `shared` otherwise. All global
  and TLS data is suspect and must have its existence justified.
* Downcasts are a code smell - use virtual dispatch instead unless
  justified.
* Our helpers return D types. A helper returns `string`, not
  `const(char)*`. Convert one time inside the helper, never at each call
  site.
* Do not `idup` a `string`. It is immutable already.
* Use `new` for a GC object, not `GC.calloc` and a cast. If `new` cannot
  work, say why in a comment.
* A parameter list or an argument list that fits on one line stays on one
  line. One that is split over several lines has one parameter or argument
  per line, and the closing parenthesis and the semicolon are on their own
  line. Then a later removal or addition changes one line only.
* A ternary expression that fits on one line stays on one line. One that
  does not fit has the condition, the `?` part and the `:` part each on
  its own line:
  ```
  cond
      ? valIfTrue
      : valIfFalse
  ```
  Give a ternary expression that is part of another expression, such as a
  call argument, a name on its own line first.
* Break a line only when the text does not fit. An operator and its right
  operand stay on the line of the left operand when they fit there.
* Source lines are usually at most 80 columns; the limit is soft, and "fits"
  in the rules above means fits within 80 columns unless a break would read
  worse.
* When a function needs its own mutable copy of a parameter, take the
  parameter by value. A copy in the body that works around the type of the
  parameter is the fault.
* Use Phobos before a hand-written equivalent, for example `std.conv.to`
  for an enum from a string.
* A struct with a flag that says if its other fields mean anything is an
  optional value: use `Nullable` or a pointer, not a flag.
  A type that is already nullable needs no `Nullable`: an array (so a
  `string`), a pointer, a function pointer, a delegate, a class and an
  interface. Its null or empty value says "none".
* Do not take a value apart to pass its fields to a function that can take
  the value.
* Do not add a `static assert` that repeats the field names of a struct to
  guard a hand-written walk over its fields. Write the walk with
  compile-time reflection, so that it needs no list.
* Prefer a template parameter for a callback, so that the function's
  attributes are deduced from it.

## Names and comments

* Use the terms of `CONTEXT.md` in names and comments. A word that is not
  in `CONTEXT.md`, and is not a D or dmd term, gets a definition at its
  first use.
* A comment is a sentence that a reader who has not seen the PR can
  understand. When a change makes part of a comment false, rewrite the
  whole comment.
* A comment on a type says what the type is. A parameter of its constructor
  is explained at the constructor or at the function that takes it, and a
  field is explained at the field.
* A name says what the thing is: `fileName`, not `file`, for a string.
  A function that returns the name or path of a file is named for the name
  or path.
* A variable or field that holds how many things there are is named `num`
  and the plural of the thing: `numModules`, not `moduleCount`.
* A name or a comment says what a value is: an address, a length, a
  function. It does not call a pointer-sized value a "word".

## Production code (in `source`)

- Use `imported!"module"` for parameter and return types at
  module-scope.  Do not use `imported!"module"` in non-module scopes
  such as inside a function, struct, or class.
- `private:` at top of every module; still annotate each declaration
  explicitly with `public`/`private`.
- Do not use exceptions for control flow.

## Code organisation

* Backends must not import each other: nothing in one backend's package
  may import another backend's package, and vice versa. Within a single
  backend package, modules can and should import each other, including
  package-private code.
* Only the package `snakebite.frontend` may import dmd modules. Other
  code takes dmd node types, enums and the functions that are on the list of
  `snakebite.frontend.ast`. Call a dmd function that is not on the list
  through `inFrontend`, which takes the frontend lock. The "not reviewed"
  block of that module still lets outside code call about 50 dmd functions
  and read the globals `global`, `target`, `diagnostics` and `Id` with no
  lock: do not add to it, and do not rely on it being safe. The build fails
  on a dmd import outside the package. It does not see a string-mixin import
  or an alias of `imported` (ADR 0015).
* In the bytecode backend, only `snakebite.backends.bytecode.compiler` may
  import frontend modules. The bytecode VM and all project modules that it
  imports must compile without DMD frontend import paths.
* Code goes in the module that owns its concept.
* A PR holds only what its requirement needs. A new option, environment
  variable, field or file that the requirement does not name is a question
  for the owner before it is code.

## Decision records

- A decision record (`docs/adr/`) states what was decided and why, at a
  high level. It has no names of functions, types, fields or files of the
  code, and no description of how the code does a thing.

A rule of behaviour in the code that native code does not have, or that gives
a different result from native code, needs its reason in a decision record
(`docs/adr/`). With no such record it is a defect.

## Shared layer

All runtime AST visitors, including those for new backends, must inherit
`LoweringVisitor`. Its final overrides own lowering dispatch.

Any exception to executing a lowering belongs in `LoweringVisitor` and
applies to all backends. Its compile-time check requires a final shared
policy for each frontend expression type with a `lowering` field.

The shared layer owns every backend-independent decision: what dmd
lowers (a `lowering` field) and what dmd decides instead in its own
glue layer (`e2ir.d`: casts, truth, invariants, closure frames, unwind
order, and so on). Put the decision in one shared module (for example
`language/operators/casts.d`, `language/storage/lifetime.d`,
`language/call/druntimehook.d`); each backend only
executes that plan. A second backend that reimplements the same
decision is a bug, not a parallel feature.

All backends use native layout in memory as normal compiled D would.
For instance, a dynamic array is `struct { size_t length; T* ptr; }`:
length at offset 0, pointer at offset 8 (on 64-bit).
This means there is no need to marshall or unmarshall when doing FFI.

## Do nots

- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.
- Do not mention quickbite implementation details in comments attached
  to tests.
- Do not "intercept" D code by name to shortcut implementation.
- Do not make an object only to give a function an argument. If code
  needs a dummy of a type, the function asks for more than it uses:
  change what the function takes. A parameter that only some
  implementations of one interface use is allowed.
- Never delete test code to make tests pass.
- Do not comment code explaining *what* it does. If it's not clear what
  the code does, rewrite it, don't comment.
- Do not add a rejection site: a run-time throw for a construct the
  backend has not implemented. A construct that compiled D accepts
  must be implemented, not refused at run time. A user-facing error
  for genuinely invalid input (for example, bad CLI arguments) is not
  a rejection site.
- Do not add `unsupported` (or similarly named) to a plan enum. Every
  member must be a real outcome, or a `final switch` over it proves
  nothing.
- Report host internal failures with
  `snakebite.failure.report.internalFailure(message)`. It prints the
  message and the call site's source location, then ends the process with
  a normal failure status. It works in `pure`, `nothrow`, and `@nogc` code,
  including release builds with assertions disabled.
- Use this shared function in catch-all visits. Include the node kind in
  the message. A terminal report does not prove that a node is unreachable
  and does not permit a new refusal of valid guest code.
- Keep `static assert` for compile-time checks. Guest assertions and the
  trapping instruction for a guest halt keep their guest semantics.
- Do not use ` __traits(getMember)` to read private members. All tests
  must go through the public API.

A new rejection site, `unsupported` member, throwing catch-all, or
per-backend copy of a decision that belongs in the shared layer is a
review must-fix.

## Do

- Explain why a unittest block is testing an AST shape by referring to
  language semantics. If necessary, you are allowed to refer to dmd
  internal implementation details.
- Code comments are for *why*.
- Dispatch on a closed set with `final switch` over the full enum,
  after `baseType` (`toBasetype` in the frontend package). A missing
  case then fails the build instead of hiding behind a `default`.
- Call `baseType` before any `.ty` test, not only before a
  `switch`. A `.ty ==` check in an `if` on an un-normalised type
  misses enums and typedef-like base types.
- Fix the full concept: cover every case the same reasoning applies
  to, not only the case that made a project fail.

## Git worktrees

Do work in a git worktree in .worktrees unless instructed otherwise.

## Testing

Build and run the focussed tests when a change is complete, before a commit or
a report. Do not build and test after each edit. For a set of small edits,
make all the edits first, then build and test one time. Run only the focussed
tests for the code that changed, while you work and when the change is
complete: pass the relevant test names to `bin/ut`.

When a change is complete, build all the default targets with plain `ninja`,
so that each binary compiles. A focussed test run does not show a binary that
nobody built.

By default, write unit tests, put them in `bin/ut`, and run them in
parallel. The separate `bin/arena` validates ownership across the shared
frontend arena. Its scans need stable process state and hold the frontend
lock. See `docs/adr/0015-frontend-memory-uses-an-arena.md` before adding
checks to that runner.

To build `bin/ut`, run `build/reggae.sh` if `build.ninja` does not
exist, then `ninja bin/ut`. Do not assume you can run `bin/ut`. It
might be stale, and running ninja is either 1) required anyway or 2)
so fast it doesn't matter.

If the sandbox blocks these commands, request escalation for the same
command instead of trying alternate test runners.

Do not run the full test suite or `build/ci.sh` on your machine: they take
too long. CI runs them. A PR is merged only when its CI run passes.

Test behaviours, not implementations.

One exception: speed is a behaviour that a test of the result cannot see.
A program gives the same result when the JIT does not start, so a test can
check one yes or no for each function, "it was JIT-compiled"
(`shouldBeStatusOfWithJitCode`). A test checks no more of the JIT than that.

Find if an existing test with `Omit` exists for the backend in question
instead of writing a new test.

A new test should always be attempted on the full matrix of backends
and only have `Omit` for the ones verified to fail.

- Use `shouldThrowWithMessage`, not `shouldThrow`.
- Use `.should ==`, not `.shouldEqual`.
- Use `"...".should.be in foo`, not `.canFind("...").should == true`.
- State an expectation with the assertion library of the test framework
  (unit-threaded), on the values themselves: `x.should == y`,
  `x.should.be in y`, `shouldThrowWithMessage`. Do not use plain `assert`,
  and do not hand-write a check and wrap it in `.should == true`. Write
  `name[0 .. expected.length].should == expected;`, not
  `(name[0 .. expected.length] == expected).should == true;`, and
  `"only one entry point `main` is allowed".should.be in thrown.msg;`, not
  `assert(thrown.msg.canFind("..."))`.
- A test does not import types of the dmd frontend and does not call an
  internal helper. It states a behaviour through what the tests of that
  area already use to compile and run a guest program. If a behaviour
  cannot be reached that way, the test is at the wrong level.
- The `ut` binary should be the first safety net; its dual mandate is
  to be fast and catch *most* things. It can't catch everything, and
  that's what the other tests are for.
- Tests must have positive ROI. Tests are not free, even merely
  existing has a cost, as well as the actual cost of running them.

- Use module-scope imports to avoid repeating the same import in every
  test block. Unit test modules should not use `imported`.
- Use package modules liberally to avoid imports in test modules - see
  `import ut;` for a good example.

## Performance work

Measure with the existing tools. Do not write a new benchmark harness.

### Closing a performance gap

When the goal is to catch a faster backend, choose experiments from evidence
of why that backend is faster. A tiny prototype limits implementation scope;
it does not limit the size of the cause to investigate.

Before assigning or starting an implementation, record in the relevant issue:

1. The owner's goal and ONE benchmark selected from the available measurements.
   State the measured gap, versions, conditions, and comparison limits.
2. The hot code actually executed by both backends. An emitted code listing
   alone does not establish execution. Record missing evidence as unresolved;
   the next task then gathers that evidence before implementation.
3. The specific difference that could explain the gap, the evidence for its
   cost, and the guarantees a transfer must preserve. Separate observations
   from hypotheses. Use the relevant ADRs to identify those guarantees.
4. One small experiment that tests that cause, its predicted code change, and
   the result that would reject the hypothesis. Rank causes by evidence and
   potential contribution to the gap, rather than ease of implementation.
5. The existing measurement command and correctness checks. Measure execution,
   compilation, and whole-process time separately. State which compilation
   work each reported timer includes and excludes.

The coordinating agent checks this record before dispatching an implementer.
Give the implementer the evidence and hypothesis, not only a proposed edit.
After each result, revise the causal explanation and select the next experiment
from it. Keep untested ideas as a backlog, not an automatic execution queue.

Report local speedups separately from progress against the competitor gap.
Claim gap reduction only from a comparable measurement; do not combine an old
competitor result with a new prototype result as if measured together.

| Rule | Enforcement |
| --- | --- |
| Causal experiment selection | Coordinator checks the issue before coding. |

This is a judgment check, not an automated guarantee.

### Measurement tools

- `bin/bench <project directory or dub package> -w 0 -r 1` times the
  backends and the native `dub test` edit cycle (`bench/source/bench/oracle.d`).
- `build/bench-corpus.sh` lists the corpus projects. `bin/bench`, `bin/sb`
  and `dub` fetch a project that is not yet in `~/.dub/packages`.
- The native baseline is: edit a project source file, then plain
  `dub test`. Use dub's default compiler and no `--force`.
- Before any profiling or optimisation, load the `linux-perf` and
  `performance-patterns` skills and follow them. Apply them to `bin/sb`,
  never to natively compiled guest code.
- Profile `bin/sb-prof` (`ninja bin/sb-prof`; the release `bin/sb` plus
  `--frame-pointer=all -gline-tables-only`; not in the default targets),
  and record with `perf record -e cycles:u --call-graph fp --user-callchains`
  (with `perf_event_paranoid=2`, plain `--call-graph fp` is refused).
  Use the plain release build only for timings.
- See the "Native baseline" section of issue #718 before any native
  comparison.

## Runtime semantics

druntime is not be emulated or reimplemented. It is either interpreted,
compiled, or called via FFI.

All backends use native layout in memory as normal compiled D would.
For instance, a dynamic array is `struct { size_t length; T* ptr; }`:
length at offset 0, pointer at offset 8 (on 64-bit).
This means there is no need to marshall or unmarshall when doing FFI.

`bin/sb` does what native code does: the compiler, the linker and the D
runtime decide the behaviour.

Before a fix for a difference between two ways of running a program, find
what native code and the D specification do in that case. That decides which
one is wrong.

# Do

- Wrap markdown files at 80 columns.

## Github

- Use `gh` to create PRs.
- Label PR comments as from an agent (identify which one).
- Open new PRs in the browser with `xdg-open`.
- Check for local worktrees before using `gh` to look at diffs etc.
- When you create or update a PR, check to see if it can be merged and
  fix any conflicts, don't wait to be told to do so.
- When you create or update a PR, monitor CI status until the CI run
  completes. If it's red once done, loop spawning fixer subagents
  until it's green.
- Do not add a "test plan" section to a PR description, CI runs tests.
- When work on an issue ends, *something* should happen. A non-exhaustive list
  of what could/should happen next:
  * Create a PR.
  * Close the issue since there is nothing left to do.
  * Comment on the issue.
  * Ask what should happen.


## Code Reviews

Review subagents get either the branch or PR number and nothing else.
Do not bias them by giving them more information; the point of a
separate subagent to do code review is a fresh context window.

A review subagent runs the `code-review` skill on the branch or PR that
it gets. The coding standards that the skill checks are the "Coding Guidelines"
section of this file.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues. See
`docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical triage label vocabulary. See
`docs/agents/triage-labels.md`.

### Domain docs

Use the single-context domain-document layout. See
`docs/agents/domain.md`.

Before diagnosing performance or proposing changes to an existing
mechanism, read the relevant ADRs. If no record explains the decision,
trace the introducing commit, linked issues, and source comments. Before
recommending a change, state the original problem, the guarantees that
must remain true, and the evidence for both. State any gaps in the
evidence. Identify which measured costs can be reduced while preserving
those guarantees.

For frontend allocation, GC boundaries, or arena checks, read
`docs/adr/0015-frontend-memory-uses-an-arena.md`.
