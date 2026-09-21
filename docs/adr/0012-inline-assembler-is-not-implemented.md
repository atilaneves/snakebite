---
status: accepted
---

# Inline assembler is not implemented

Issue #415: emsi_containers' `containers/simdset.d` guards
`SimdSet.contains` with `version (D_InlineAsm_X86_64)`. No backend
runs DMD-style inline assembler: an `asm` block reads locals by name
and jumps to D labels, so it cannot run against an interpreter frame
or a bytecode frame. Snakebite needs one rule for this, not a
guess-and-crash at run time.

## Decision

Snakebite does not implement DMD-style inline assembler. A root
module is parsed with `D_InlineAsm_X86_64` undefined, so guarded code
compiles out the same way it would under a compiler without this
assembler, such as GDC on an unsupported target. A dependency module
(druntime, phobos, a dub dependency) keeps the identifier defined:
ADR-0009 already has real dmd compile dependency modules and call them
across the barrier, and their own type-checking needs it - for
example `core.internal.atomic`'s x86-64 path has no other branch.

The mechanism is per-module, not global. dmd resolves a
`version (...)` through `IncludeVisitor.visit(VersionCondition)`: once
a condition's `inc` field is no longer `notComputed`, that cached
value wins; `vc.mod`, the module a condition checks itself against
before falling back to `global.versionids`, is fixed at parse time to
the module whose source holds the `version (...)`, and a template body
resolves against its declaring module. So `global.versionids` keeps
`D_InlineAsm_X86_64` defined throughout, and right after a root module
is parsed, a walk (`inlineasm.disableInlineAsmVersion`) sets `inc` to
`Include.no` on every `D_InlineAsm_X86_64` condition in that module's
own syntax tree - at module scope, in an aggregate, in a function
body, and in a template's body, instantiated or not - before the
shared semantic phases run, in the one path they all share
(`driveSharedSemantic`).

Undefining the identifier is not enough on its own: dmd's statement
semantic accepts an unguarded `asm` block without erroring (see
`source/dmd/iasm/package.d`, snakebite's own shim for the dub
`dmd:frontend` package), because druntime ships modules that guard
`asm` and must still pass semantic analysis. So a root-owned function
that still has an unguarded `asm` block fails the load with one
diagnostic, naming the function and the guard that would have
compiled it out. Root ownership is decided per function
(`Dsymbol.getModule`), not by how the walk reached it: root code that
instantiates a dependency template, such as
`core.internal.atomic.atomicFetchAdd`, reaches that dependency's own
`FuncDeclaration` through the instance living in the root module's
scope, and its real `asm` body (compiled in, since dependencies keep
the identifier) must not be reported.

If a real project needs to run `asm`, the path is whole-function
native compilation across the barrier, decided in
`CallSelection.buildDecision` - a block jumps to labels other
statements in its function declare, so it cannot run on its own.

## Considered options

**Remove the identifier globally**, once, from `global.versionids`.
Tried first; rejected: `core.internal.atomic`'s x86-64 path has no
other branch for a DigitalMars-like frontend on this target, so
druntime's own atomic operations broke.

**Push the identifier into each dependency module's own version
list**, keeping `global.versionids` root-only. Rejected: dmd loads
dependencies lazily and evaluates their `version` blocks as reached,
with no shared hook for this without shadowing a large piece of dmd.

**Execute the `asm` block against a mirrored interpreter frame, or an
x86 emulator.** Rejected: a block jumps to labels other statements in
the same function declare, so running it in isolation is not enough;
an emulator is a second execution engine, with its own bugs, for a
construct real projects rarely use.

**A per-module version override.** Rejected in PR #411 as not worth
its complexity, for the same reason there.

**Mark a test that reaches `asm` as skipped instead of failing the
load.** Rejected: needs reachability analysis to know which tests
reach it, and a skip hides the real cause.

**Fail only at run time, when a backend first reaches the block.**
Rejected: a slow test run can reach the failure long after the load
that should have reported it.

## Consequences

A `version (D_InlineAsm_X86_64)` snippet gives a different answer
under `Native` and under every backend, by design; a diverging test
pair in `tests/ut/backends/run/inlineasm.d` pins both sides, with
further pairs pinning the rule inside a function body and inside a
template. emsi_containers' `SimdSet.contains` now compiles out its
`asm` body on the bytecode backend and passes.

Known, accepted gap: a `version (D_InlineAsm_X86_64)` written inside a
string mixin in root code is not covered by the walk, because the
mixin's own source text is only parsed once dmd expands it during
semantic analysis, after the walk has already run. The condition that
expansion builds resolves against `global.versionids`, which still
carries the identifier, so the mixed-in `asm` branch compiles in
rather than out. The load-time diagnostic still catches it, since it
does not care how a root-owned function came to have an unguarded
`asm` block; `inlineasm.versionIdentifier.mixinGapFailsLoad` pins it.
