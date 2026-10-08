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

Updated for the owner's decision on #628 of 2026-10-08: finish support for
hand-written intrinsic declarations and match native DMD. This replaces
the former CTFE-name and whole-module classification rule.

`CallSelection.buildDecision`
(`source/snakebite/backends/calls.d`) finds the compiler intrinsics
among the bodiless declarations. Its shared classifier copies the rows
of `dmd.glue.toir.intrinsic_op` in DMD 2.113.0, which is package-private
and cannot be called here. It checks the module package and identifier,
the function identifier, deprecated status, and the first operand type
where DMD checks it. Aliases are already resolved at the call site. The
rule covers DMD's math, bitop, volatile, and SIMD rows, not every
declaration in those modules. `dmd.builtin.isBuiltin` is a CTFE
classifier, not part of call selection. `eval_builtin` is never called
at run time.

Any other bodiless declaration keeps rule 3's routing: a barrier call, or
an error when the resolver finds no host address.

A declaration that the code generator inlines takes the builtin route
when a wrapper takes its full signature.
This is also a call-site decision. DMD's `e2ir.callfunc` substitutes an
intrinsic only when its callee is `OPvar`. A resolved call with a comma
prefix, such as `(make(), bswap)(value)`, evaluates that prefix before its
arguments and keeps the native route. A declaration-only cache does not
prove that this call can use a wrapper or become a constant.
`source/snakebite/backends/builtins.d` looks up a compiled wrapper by the
declaration's own identifier (`function_.ident`, the same identifier
dmd's own code generator keys on), parameter types, and result type.
The key includes parameter count. Parameters must be plain values, not
`ref`, `out`, or `lazy`; the function must not be variadic or return by
`ref`. Base types determine the wrapper's native-layout widths. A vector
must be 16 bytes. The identifier alone is not a unique key:
`sin(float)` and `sin(double)` need different operand reads, and
`float sin(real)` and `double sin(real)` need different result writes.
The wrapper is a plain compiled snakebite
function. Both backends call it directly, on arguments already in native
layout, the same way they call a resolved native plan.

A missing full-signature entry keeps the ordinary native route. It does
not fail while the call is selected or an unexecuted body is loaded. A
reached call without a host symbol gives the resolver's missing-symbol
diagnostic. The accepted raw-SIMD exception below is distinct from the
supported intrinsic signatures.

### The result is dmd's result

The guest is always analysed as dmd code (`version (DigitalMars)`, with
`D_SIMD`). One guest program must therefore give one result in the
dmd-built `bin/ut` and in the LDC-built `bin/sb` and `bin/at`, and that
result is the one that dmd gives. A wrapper does not call whatever the
host compiler's own `core.math` does. For example `rndtol(2.5)` is 2 with
dmd, which rounds in the current rounding mode, and 3 with LDC, whose
`core.math.rndtol` is `llround`. The wrapper under LDC rounds in the
current rounding mode with an x87 integer store, so the guest gets 2.

`source/snakebite/backends/dmdintrinsics.d` holds the native instruction
definitions that the wrappers call. Floating operations use DMD's
instruction precision. For `fabs` with float or double operands and
results, `xmmabs` clears the operand's sign bit without a numeric result
conversion. A narrower result reads the low bytes; a wider double result
reads the zero-extended float bits. An operation with a real operand or
result uses x87 and stores numerically at the declared result width.
Other floating operations convert once to the declared floating result.
`rndtol` uses an x87 integer store at the declared result width, including
the 16- and 32-bit indefinite result on overflow. Wrappers write only the
declared result width. Volatile access uses the load result or stored
value width; it does not infer the access width from the pointee type.

Constant folding and emitted instructions can differ for hand-written
signatures. DMD's backend constant folder (`evalu8`, `OPbswap`) uses the
operand width, while its emitted byte swap (`cdbswap`) uses the result
width. Thus `ushort bswap(uint)` gives `0x3412` for literal `0x12345678u`
and `0x7856` for a volatile load of that value in a default native build.
The shared call-site rule folds constant byte swaps before argument
execution. Its proof follows the scalar producer families that survive
frontend optimization and become constant backend operations: numeric
literals, nested swaps or population counts, `fabs`, `toPrec`, scalar casts,
arithmetic, comparisons, comma expressions, and constant selection.
Logical and conditional selection examines only the executed branch.
Each inner result keeps its own declared width. For `fabs`, DMD's constant
folder computes at operand width, then labels that storage with the
declared result type, without a numeric conversion. The shared proof reads
the declared result only when all its value bytes have known values. This
includes double to float and real to float or double. `el_una` clears the
node before it sets the child pointer. A double fold replaces the complete
pointer, so a real result reads the double bits with the cleared exponent
bytes. Direct floating calls and nested integer producers use the same
proof.

A float fold with a double or real result also reads the remaining
compiler child-pointer bytes. The proof does not invent those bytes; it
leaves that call on the instruction path. This is a proof limit, not an
owner-approved language exception or a claim that all mixed signatures
have undefined results. Exact parity for these two constant shapes is not
proved.

Scalar folding uses DMD's allocation-free `constfold` operations and
private `UnionExp` values. It does not optimize the guest AST, expand
declarations, or change frontend global flags. Faulting integer division
stays on the execution path. Like `evalu8`, a floating operation that
raises an exception, including an inexact conversion, stays on that path.
The proof uses default rounding and restores the host thread's complete
floating-point environment. Other floating intrinsic operations remain
instructions in `evalu8`, not constant producers. The runtime wrapper
keeps the result-width rule. No CTFE evaluator or guest runtime value is
used to decide whether an operand is constant.

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
with another opcode fall under the exception below.

### Accepted raw-SIMD exception

Direct calls of `core.simd.__simd`, `__simd_ib` and `__simd_sto` from a
guest program, other than the six moves above, are out of scope by the
owner's decision on #433/#627 of 2026-10-07 and 2026-10-08. LDC has no
such raw intrinsics. This is an explicit exception to the load-time
failure rule: an unexecuted call does not fail the load. A backend stops
when it reaches the call, with a clear message that names the call.
A missing wrapper shape uses the native resolver diagnostic; a covered
wrapper shape with another opcode gives an opcode diagnostic naming the
intrinsic. General raw-SIMD support is not an open requirement here.

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

`source/snakebite/backends/builtins.d` holds the covered signatures;
`CallSelection` holds the shared DMD code-generator and call-site rules.
Adding a wrapper does not make a declaration an intrinsic. The bytecode VM
imports only `BuiltinCall` from `builtins.d`, never a dmd frontend
type (CODING.md, "Code organisation").
