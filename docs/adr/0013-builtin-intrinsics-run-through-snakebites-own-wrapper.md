---
status: accepted
---

# Builtin intrinsics run through snakebite's own wrapper

PR #422: guest code that calls a bodiless `core.math` intrinsic
(`fabs`, `sqrt`, `sin`, `cos`, `ldexp`, `yl2x`, `yl2xp1`) or a bodiless
`core.bitop` intrinsic (`bswap`, `_popcnt`) failed on the Bytecode and
Interpreter backends. `CallSelection` (ADR-0009 rule 3) sent every
bodiless declaration across the barrier. Compiled D emits each of
these functions inline, so no linker symbol for one exists anywhere in
the host process, and the barrier call always failed to resolve it.

This amends ADR-0009 rule 3. A bodiless declaration is not always a
barrier call, or an error when the resolver finds no host address. When
dmd classifies the declaration as a compiler intrinsic, it takes a
third route instead, the builtin route below.

## Decision

`CallSelection.buildDecision`
(`source/snakebite/backends/calls.d`) asks dmd for a bodiless
declaration's own classification, `dmd.builtin.isBuiltin`. This is the
only question this project asks dmd about a builtin. dmd's own CTFE
evaluator, `dmd.builtin.eval_builtin`, is never called at run time.

When `isBuiltin` answers `BUILTIN.unimp`, the declaration keeps rule
3's routing: a barrier call, or an error when the resolver also finds
no host address.

When `isBuiltin` names a real classification, the call takes the
builtin route instead. `source/snakebite/backends/builtins.d` looks up
a compiled wrapper by the declaration's own identifier
(`function_.ident`, the same identifier dmd's own `determine_builtin`
keys on) and its first parameter's type. The identifier alone is not a
unique key: `sin(float)` and `sin(double)` both classify as
`BUILTIN.sin`. The wrapper is a plain compiled snakebite function that
calls the host compiler's own intrinsic for that name and type, for
example `float fabs(float x) { return core.math.fabs(x); }`. Both
backends call the wrapper directly, on arguments already in native
layout, the same way they call a resolved native plan. Calling the
host compiler's own intrinsic, rather than computing the result
another way, is what keeps a builtin call's result identical to what
compiled D would produce.

A declaration `isBuiltin` classifies, but the wrapper table has no
entry for, is an error at decision time, not at the call's first
execution.

Known gap: issue #423. dmd's own `BUILTIN` enum has no member for
`core.math.rndtol` or `core.math.rint`. `isBuiltin` answers
`BUILTIN.unimp` for both, so they keep rule 3's routing and still need
a host symbol FFI cannot supply, on every backend but `Native`.

## Considered options

**Call dmd's own CTFE evaluator, `eval_builtin`, at run time.**
Rejected. `eval_builtin` takes and returns dmd frontend `Expression`
objects, so every call would need the compiler lock, on the
interpreter's and the bytecode VM's hot path alike - the path ADR-0006
keeps lock-free. `eval_builtin` also computes at `real` precision
throughout and then converts, which does not always match the result
the host compiler's own instruction gives for a narrower type.

**Add a native-target table inside the FFI plan, listing a host
address for each builtin.** Rejected. `core.math.fabs` and the other
builtins compile to an inline instruction, not a call; no linker
symbol for one ever exists in the host process, so there is no address
such a table could hold. This option would make the FFI layer pretend
a builtin is an ordinary host symbol, one it can never actually
resolve.

## Consequences

A bodiless declaration now has three possible outcomes, not two: guest
body, barrier call, or builtin wrapper. `CONTEXT.md`'s "Call selection"
entry names all three.

`source/snakebite/backends/builtins.d` is the one place that keeps
snakebite's own list of covered intrinsics. Adding one means adding an
entry there, not a special case in `CallSelection`. The bytecode VM
imports only `BuiltinCall` from `builtins.d`, never a dmd frontend
type (CODING.md, "Code organisation").
