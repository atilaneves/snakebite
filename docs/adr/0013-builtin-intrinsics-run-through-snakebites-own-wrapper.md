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
(`source/snakebite/backends/calls.d`) finds the compiler intrinsics
among the bodiless declarations. dmd has two lists of them, and the
decision uses both:

- `dmd.builtin.isBuiltin` classifies the ones that its semantic pass and
  its CTFE evaluator know (`fabs`, `sqrt`, `sin`, `cos`, `ldexp`, `yl2x`,
  `yl2xp1`, `bswap`, `_popcnt`). dmd's own CTFE evaluator,
  `dmd.builtin.eval_builtin`, is never called at run time.
- `dmd.glue.toir.intrinsic_op` lists the ones that its code generator
  inlines. It has more, among them `core.math.rint` and `rndtol`, all of
  `core.volatile`, and `core.simd.__prefetch`, `__simd`, `__simd_ib` and
  `__simd_sto`. `isBuiltin` answers `BUILTIN.unimp` for these. The glue
  module is not part of this build, so the decision finds them by module
  (`core.math`, `core.volatile`, `core.simd`) and takes every bodiless
  declaration of those modules.

Any other bodiless declaration keeps rule 3's routing: a barrier call, or
an error when the resolver finds no host address.

A declaration of either list takes the builtin route.
`source/snakebite/backends/builtins.d` looks up a compiled wrapper by the
declaration's own identifier (`function_.ident`, the same identifier
dmd's own `determine_builtin` keys on) and the types of its parameters.
The identifier alone is not a unique key: `sin(float)` and `sin(double)`
both classify as `BUILTIN.sin`. The wrapper is a plain compiled snakebite
function. Both backends call it directly, on arguments already in native
layout, the same way they call a resolved native plan.

A declaration of either list that the wrapper table has no entry for ends
the run at the call's first decision, with a message that names the
intrinsic. It does not go across the barrier, where it would fail at its
first execution with a message about a missing symbol.

### The result is dmd's result

The guest is always analysed as dmd code (`version (DigitalMars)`, with
`D_SIMD`). One guest program must therefore give one result in the
dmd-built `bin/ut` and in the LDC-built `bin/sb` and `bin/at`, and that
result is the one that dmd gives. A wrapper does not call whatever the
host compiler's own `core.math` does. For example `rndtol(2.5)` is 2 with
dmd, which rounds in the current rounding mode, and 3 with LDC, whose
`core.math.rndtol` is `llround`. The wrapper under LDC rounds in the
current rounding mode (`llvm_llrint`), so the guest gets 2.

`source/snakebite/backends/dmdintrinsics.d` holds the definitions that
the wrappers call. Under dmd they are dmd's own `core.math`. Under LDC
they are what dmd emits: the x87 instruction on a `real` that is narrowed
once when the result is not a `real` (`sin`, `cos`, `ldexp`, `yl2x`,
`yl2xp1`), the SSE or x87 square root instruction, and `llvm_llrint`.
The wrapper writes its result at the type that the guest's declaration
returns, never at the type that the host's intrinsic returns: LDC
declares only the `real` overload of `yl2x`.

A test whose `Native` arm is compiled by LDC cannot use `Native` as the
oracle for such a function. It asserts the values of a native dmd run and
omits `Native` under LDC.

### Array operations

dmd lowers `a[] = b[] + c[]` to a call of
`core.internal.array.operations.arrayOp`. The guest has `D_SIMD`, so the
guest body of that template moves 16 bytes with `core.simd.__simd` and
`__simd_sto` (`XMM.LODUPS`, `LODUPD`, `LODDQU`, `STOUPS`, `STOUPD`,
`STODQU`). A run that has a dependency image calls the image's copy of
the template instance instead, compiled by the host compiler, and never
runs the guest body (`bin/sb`). A run that has no image runs the guest
body (the test binaries).

The wrapper table has those six opcodes. The first operand of
`__simd_sto` is the memory that the instruction writes, so the call takes
that parameter by address (`Decision.destinationParameter`). `__simd`
with another opcode or another overload, `__simd_ib`, and `__simd_sto`
with another opcode have no wrapper (see "Open").

### Open

Direct calls of `core.simd.__simd`, `__simd_ib` and `__simd_sto` from a
guest program, other than the six moves above, have no wrapper. dmd needs
a constant opcode for each call (`glue/e2ir.d`), so a complete wrapper
needs one case for each of the about 265 `XMM` members for each operand
shape, and a second implementation for an LDC host, which has no
`__simd`.

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
