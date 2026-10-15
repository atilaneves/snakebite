# Goal

Alternative backends for the D programming language that reduce the
edit to unittest feedback cycle. At least a tree walking interpreter
and a bytecode VM.

# Communication guidelines

Use ASD-STE100 - Simplified Technical English in all communication.

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

To build `/bin/ut`, run `build/reggae.sh` if `build.ninja` does not
exist, then `ninja bin/ut`. Do not assume you can run `bin/ut`. It
might be stale, and running ninja is either 1) required anyway or 2)
so fast it doesn't matter.

If the sandbox blocks these commands, request escalation for the same
command instead of trying alternate test runners.

Run `build/ci.sh` before creating a PR. It must pass before the PR is
created or merged.

Test behaviours, not implementations.

Find if an existing test with `Omit` exists for the backend in question
instead of writing a new test.

A new test should always be attempted on the full matrix of backends
and only have `Omit` for the ones verified to fail.

## Performance work

Measure with the existing tools. Do not write a new benchmark harness.

- `bin/bench <project directory or dub package> -w 0 -r 1` times the
  backends and the native `dub test` edit cycle (`bench/source/bench/oracle.d`).
- `build/bench-corpus.sh` lists the corpus projects. They are already in
  `~/.dub/packages`.
- The native baseline is: edit a project source file, then plain
  `dub test`. Use dub's default compiler and no `--force`.
- Before any profiling or optimisation, load the `linux-perf` and
  `performance-patterns` skills and follow them. Apply them to `bin/sb`,
  never to natively compiled guest code.
- Profile a `bin/sb` built with the release flags plus
  `--frame-pointer=all -g`, and record with `perf record --call-graph fp`.
  Use the plain release build only for timings.
- See the "Native baseline" section of issue #718 before any native
  comparison.
- `bin/sb-count` is `bin/sb` built with `-version=BytecodeCount`. At exit
  it prints `BCOUNT <count> <handler name>` to stderr, one line for each
  handler that ran. Counts are not atomic, so a guest with several threads
  gives approximate counts. To count bytecodes for a loop body, run the
  guest with two iteration counts and divide the difference of the totals
  by the difference of the iterations. The counts of one run include
  start-up work; the difference removes it.

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
