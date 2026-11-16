---
status: accepted
---

# The root package is interpreted, dependencies are called

The barrier needs a rule for which functions a backend executes itself
and which functions it calls across the barrier. Issue #41 states the
rule as "what would compiled code do": a dub dependency's archive is
called across the barrier. The root package's own object file is
interpreted. `Program.isRootOwned` in
`source/snakebite/program.d` already tests this rule on
modules.

## Decision

1. Every module of the root package is interpreted. This includes
   every template instantiation that would land in the root object
   file in a real build. Phobos and druntime templates count too,
   when the root package instantiates them. The exception is an
   instance of a dependency template whose body no backend can
   compile or execute. Today that is a body with inline assembler
   (ADR-0012), or a body that calls an operation that only the code
   generator makes and that no wrapper of the backends takes: an LLVM
   intrinsic outside the table of the bytecode VM, LLVM inline IR, or
   LDC's inline assembler. Such an instance is compiled natively into
   the dependency image (ADR-0007) and called across the barrier. Each
   function is judged on its own body: an instance that calls such an
   instance is interpreted, and its call is a native call.
2. Every function from a dependency module is called across the
   barrier. The call resolves through the dependency image
   (ADR-0007) or through the host.
3. A function that is not root-owned, has a body, and the resolver
   finds no host address for it, is interpreted. A declaration
   without a body, when the resolver also finds no host address, is
   an error. A real build reports this same case as an unresolved
   symbol at link time.
4. The `pragma(mangle)` declarations the interpreter currently skips
   use the same entry point as every other call without a body.

## Considered options

Interpret only the modules with unittests, and compile the rest of
the root package into the dependency image. Rejected: a change to
any project module would then need a compile step. Removing that
step is the reason this project exists.

## Consequences

The root-owned predicate is the one question both call dispatch and
type metadata construction ask. A backend must not keep its own
copy of this predicate.

The exception of decision 1 is also one predicate,
`backendExecutes` in `source/snakebite/language/call/selection.d`.
The call selection asks it for each instance, and the dependency
image source asks it to select the instances that it holds. A
backend must not keep its own copy of it either.
