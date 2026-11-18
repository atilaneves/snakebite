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

See ai/CODING.md.

## Git worktrees

Do work in a git worktree in .worktrees unless instructed otherwise.

## Testing

Run tests after every edit made to D code.

By default, write unit tests, put them in `bin/ut`, and run them in
parallel. The separate `bin/arena` validates ownership across the shared
frontend arena. Its scans need stable process state and hold the frontend
lock. See `docs/adr/0015-frontend-memory-uses-an-arena.md` before adding
checks to that runner.

Prefer to run focussed tests instead of the whole test suite by passing
the relevant test names to `bin/ut`.

To build `bin/ut`, run `build/reggae.sh` if `build.ninja` does not
exist, then `ninja bin/ut`. Do not assume you can run `bin/ut`. It
might be stale, and running ninja is either 1) required anyway or 2)
so fast it doesn't matter.

If the sandbox blocks these commands, request escalation for the same
command instead of trying alternate test runners.

Run `build/ci.sh` before creating a PR. It must pass before the PR is
created or merged.

Test behaviours, not implementations.

One exception: speed is a behaviour that a test of the result cannot see.
A program gives the same result when the JIT does not start, so a test can
check one yes or no for each function, "it was JIT-compiled"
(`shouldBeStatusOfWithJitCode`). A test checks no more of the JIT than that.

Find if an existing test with `Omit` exists for the backend in question
instead of writing a new test.

A new test should always be attempted on the full matrix of backends
and only have `Omit` for the ones verified to fail.

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
