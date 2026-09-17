---
status: accepted
---

# The barrier supports every linkage compiled D supports

A dub project can depend on arbitrary D, C, and C++ code. Today the
barrier refuses `extern(C++)` and several parameter shapes. Guest code
must behave like compiled D. The barrier may refuse a call only when a
native link would also refuse it. The platform scope is Linux x86-64
System V for now. The plan that computes a call's shape is ABI-agnostic,
so any other platform fails loudly instead of guessing.

**`extern(C)`**: every shape, including C variadics. The call stub
sets `AL` to the count of SSE registers used, as the System V ABI
requires.

**`extern(D)`**: every shape the barrier itself crosses, including all
three D variadic kinds. Guest-to-guest untyped variadic calls bind the
hidden type information and use a native `va_list` over their overflow
argument storage. They execute druntime's `va_arg` code; neither backend
implements a substitute for it.
Typesafe variadics are a slice, classified and passed exactly like any
other declared parameter - the frontend has already packed the call
site's trailing arguments into it. Untyped variadics pass `_arguments`
ahead of the declared parameters: the frontend inserts a `typeid` of
the call's own extra-argument types as the literal first element of
the call's argument list, whose value at run time is a `TypeInfo_Tuple`
reference, not a `TypeInfo[]` slice itself. What actually reaches the
callee's own hidden `_arguments` argument then depends on the host
compiler's own codegen, not the frontend (`snakebite.ffi.abi.
dVariadicArgumentsIsSlice`): on dmd, one hidden pointer to that
`TypeInfo_Tuple` reference - the callee's own prologue builds the slice
itself, by reading the tuple's `elements` field, before its body ever
runs (verified against dmd's `expressionsem.functionParameters` and
`semantic3`); on LDC, LDC's own codegen reads `elements` at the call
site instead and passes the resulting two-register `TypeInfo[]` slice
directly, so an LDC-built callee's own prologue never has to (verified:
disassembling a real `extern(D) int f(int a, int b, int c, ...)` call
built by ldc2 1.43, frontend 2.113.0, shows a length/pointer pair in
the first two integer registers where dmd passes one pointer). For a
guest-declared function the backend builds that `TypeInfo_Tuple`, and
the `TypeInfo` of each of its own extra arguments, from its own runtime
types; a guest-declared struct's own fabricated `TypeInfo_Struct` also
carries the SysV eightbyte classification (`m_arg1`/`m_arg2`) druntime's
own `core.vararg` needs to read such a struct back out of the register
save area, the same classification this plan already uses to place it
into a register when it is the caller. For a host-declared function it
uses host `TypeInfo`. The variadic arguments themselves classify and
place like C's, in declaration order - unlike an ordinary `extern(D)`
call, a variadic one is never reversed on dmd, on either the declared
parameters or `_arguments` itself, whichever host compiler built this
process (verified: disassembling a real `extern(D) int f(int a, int b,
int c, ...)` call built by dmd shows `_arguments`, `a`, `b` and `c` in
plain declaration order, not reversed) - because the callee's own
`_argptr`/register-save-area machinery has to walk every parameter in
one consistent forward order to find where the register save area and
the stack overflow area begin. `this` still precedes the hidden return
pointer on dmd, and follows it on LDC, exactly as for a non-variadic
call: dmd reverses parameter order and places `this` before the
hidden return pointer. LDC keeps parameter order and places `this`
after the hidden return pointer. The plan computation switches on the
host compiler to pick the layout, which is correct because the host
and the guest use the same compiler family (ADR-0007).

**`extern(C++)`**: free functions and static member functions, using
the Itanium mangling the frontend already produces. Non-virtual member
functions, with `this` as the first argument - except when the method
also returns a MEMORY-class or non-trivially-copyable value, where
`this` follows the hidden return pointer instead, as issue #336 itself
found and `abi.contextPrecedesHiddenReturnPointer` encodes. Virtual
member functions, called through the C++ vtable the frontend models.
Non-trivially-copyable classes, passed by hidden reference, as the
Itanium ABI requires. A C++ exception that crosses the barrier
propagates or terminates the process, exactly as it does for compiled
D (ADR-0004). A C++ template the host library did not instantiate is a
plain error. A native link gives the same error.

## Considered options

**Refuse `extern(C++)` for now.** Rejected. dub projects bind C++
libraries. A refusal is not how compiled D behaves, so it breaks the
requirement above.

**Refuse D untyped variadics.** Rejected, for the same reason. The
shape also turned out to be simple: the C variadic ABI plus one hidden
`_arguments` argument, never reversed even on dmd.

## Consequences

The plan computation needs the Itanium non-trivially-copyable rule, in
addition to System V eightbyte classification. The resolver needs no
change, because mangling already comes from the frontend.
