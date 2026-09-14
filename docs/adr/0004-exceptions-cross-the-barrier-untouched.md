---
status: accepted
---

# Exceptions cross the barrier untouched in both directions

Umbrella issue #100 makes exception propagation across the barrier a
pass or fail gate in both directions. A host to guest call already
passes a `Throwable` through unwrapped. A guest callback can also
throw while host frames sit on the stack. Guest code must behave like
compiled D. The backends run guest code on the host stack. On x86-64,
gcc and clang emit `.eh_frame` unwind tables by default, so a D
exception unwinds through C frames such as `qsort`. A C++ exception
cannot be caught by compiled D either.

A `Throwable` raised in guest code, and called back from the host,
propagates through the host frames untouched. This matches a compiled
D callback exactly. Nothing catches it and rethrows it. Nothing
translates it. A C++ exception that reaches guest code propagates
onward, or terminates the process, as it would in compiled D.

Every hand-written assembly frame on the barrier carries call frame
information: the call stub and the callback entries (ADR-0001,
ADR-0003). Each frame has `.cfi_startproc`, `.cfi_endproc`, and offset
directives for everything it pushes. No personality routine is
needed, because these frames have no cleanup to run. This is why the
assembly lives in a `.S` file, not in compiler inline assembly.
Compiler inline assembly emits no call frame information.

## Considered options

**Catch and rethrow at the callback entry.** Rejected. It changes
observable behaviour compared with compiled D. For example, a host
`scope(exit)` would run before the guest handler runs, instead of
during unwinding. This platform does not need it.

**Forbid throwing from callbacks.** Rejected. Compiled D allows a
callback to throw, so snakebite must allow it too.

## Consequences

A host frame without unwind tables terminates the process. Compiled D
has the same consequence.
