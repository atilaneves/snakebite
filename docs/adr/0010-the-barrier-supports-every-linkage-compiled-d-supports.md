---
status: accepted
---

# The barrier supports every linkage compiled D supports

A dub project can depend on arbitrary D, C, and C++ code. Today the
barrier refuses C variadics, `extern(C++)`, and several parameter
shapes. Guest code must behave like compiled D. The barrier may refuse
a call only when a native link would also refuse it. The platform
scope is Linux x86-64 System V for now. The plan that computes a call's
shape is ABI-agnostic, so any other platform fails loudly instead of
guessing.

**`extern(C)`**: every shape, including C variadics. The call stub
sets `AL` to the count of SSE registers used, as the System V ABI
requires.

**`extern(D)`**: every shape, including all three D variadic kinds.
Typesafe variadics are a slice. Untyped variadics pass `_arguments` as
an ordinary slice parameter in first position, pass the variadic
arguments in registers first like C, and set `AL` like C. For a
guest-declared function the backend builds the `TypeInfo[]` from its
own runtime types. For a host-declared function it uses host
`TypeInfo`. dmd reverses parameter order and places `this` before the
hidden return pointer. LDC keeps parameter order and places `this`
after the hidden return pointer. The plan computation switches on the
host compiler to pick the layout, which is correct because the host
and the guest use the same compiler family (ADR-0007).

**`extern(C++)`**: free functions and static member functions, using
the Itanium mangling the frontend already produces. Non-virtual member
functions, with `this` as the first argument. Virtual member
functions, called through the C++ vtable the frontend models.
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
shape also turned out to be simple: the C variadic ABI plus one slice
parameter.

## Consequences

The plan computation needs the Itanium non-trivially-copyable rule, in
addition to System V eightbyte classification. The resolver needs no
change, because mangling already comes from the frontend.
