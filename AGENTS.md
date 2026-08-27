# Goal

Alternative backends for the D programming language that reduce the
edit to unittest feedback cycle. At least a tree walking interpreter
and a bytecode VM.

# Communication guidelines

Use ASD-STE100 - Simplified Technical English in all communication.

# Coding Guidelines

See ai/CODING.md.

## Git worktrees

Do work in a git worktree unless instructed otherwise.

## Testing

Run tests after every edit made to D code.

Prefer to run focussed tests instead of the whole test suite by passing
the relevant test names to `bin/ut`.

To build `/bin/ut`, run `dub run reggae --compiler=ldc -- -b ninja` if
`build.ninja` does not exist, then `ninja bin/ut`. Do not assume you
can run `bin/ut`. It might be stale, and running ninja is either 1)
required anyway or 2) so fast it doesn't matter.

If the sandbox blocks these commands, request escalation for the same
command instead of trying alternate test runners.

Run `build/ci.sh` before creating a PR. It must pass before the PR is
created or merged.

Test behaviours, not implementations.

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

- Label PR comments as from an agent (identify which one).
- Open new PRs in the browser.
- Check for local worktrees before using `gh` to look at diffs etc.
- When you create or update a PR, check to see if it can be merged and
  fix any conflicts, don't wait to be told to do so.
- When you create or update a PR, monitor CI status until the CI run
  completes. If it's red once done, loop spawning fixer subagents
  until it's green.
- Do not add a "test plan" section to a PR description, CI runs tests.
