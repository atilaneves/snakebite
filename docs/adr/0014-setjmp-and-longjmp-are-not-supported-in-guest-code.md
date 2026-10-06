---
status: accepted
---

# setjmp and longjmp are not supported in guest code

Issue #521: a guest that calls C `setjmp` and `longjmp` cannot work
in general. In the Interpreter, a guest call is a chain of host stack
frames of the tree walk. `longjmp` skips those frames. Without a rule,
the result depends on the backend. For a guest that calls `setjmp`,
then `longjmp`, then returns 7, measured on master with `bin/sb`:

| Backend | Result |
|---|---|
| Interpreter | exit code 139 (SIGSEGV) |
| Bytecode VM | exit code 0, "1 modules passed unittests" |
| Ctfe | exit code 1, "cannot be interpreted at compile time" |

The same program with `sigsetjmp` and `siglongjmp` gives exit code 139
on the Interpreter and on the Bytecode VM. So the Bytecode VM passes
one program and crashes on another, with no message in both cases.
Snakebite needs one rule for this, as ADR-0012 gives one for inline
assembler.

## Decision

Snakebite does not support a call to `setjmp` or `longjmp` from guest
code. A root module that refers to one of these functions fails the
load with one error at the source location of the reference:

```
`longjmp` is not supported in guest code: a backend cannot jump back
to a stack frame it has already left
```

The check uses the seam of ADR-0012. `InlineAsmCollector` already
walks the root modules after semantic analysis, in
`driveSharedSemantic`, and reports through dmd `error`. It now also
visits each symbol expression in a root-owned function body and in the
initializer of a root-owned variable or field. So the failure comes
before any backend runs, and it is the same on every backend that runs
guest code.

The check looks at the resolved declaration, not at the spelling at
the call site. A function is a target when it has no body, its linkage
is C and its link name is `_setjmp`, `setjmp`, `__sigsetjmp`,
`sigsetjmp`, `longjmp`, `_longjmp` or `siglongjmp`. A `pragma(mangle)`
name has priority over the D name. The error names the libc function,
so `setjmp` and `sigsetjmp`, not `_setjmp` and `__sigsetjmp`. A
template reports one error for each use, not for each instance. These
cases are covered:

- A direct call.
- A call through an `alias`, because the symbol expression holds the
  function itself.
- Taking the address, such as `&longjmp`. This also covers a call
  through the function pointer that results, because the check sees the
  address-of expression.
- A guest redeclaration of the function with C linkage and no body.
- A function pointer to the function in a module-scope or aggregate
  field initializer. The load fails there, because a function can call
  through the pointer later.

These cases are not covered:

- A symbol that a guest gets at run time, for example with `dlsym`.
- A name that `pragma(mangle)` gives to a function with a different
  D name, when the linkage is not C.
- A guest function with a body, even with C linkage and the name
  `setjmp`. It is guest code that each backend runs, and it saves no
  stack context.
- A guest function that only reaches `setjmp` through a dependency
  module. Dependency code is called across the barrier (ADR-0009) and
  runs natively, where `setjmp` is valid.

A dependency module is not checked, and a native C library keeps its
own use of `setjmp` and `longjmp`. The jump stays inside native frames,
which the backends never skip. A guest call into such a library works
on every backend that can call native code.

## Considered options

**Support the jump in each backend.** Rejected. The Interpreter would
need to unwind its host frames by hand, and the bytecode VM would need
to save and restore its own frames next to the host context. This is a
second control-flow mechanism for a construct that D code seldom
uses. D has exceptions for non-local exit.

**Detect the call by its spelling at the call site.** Rejected. An
alias or a function pointer gives the same function under another
name.

**Fail at run time, when a backend reaches the call.** Rejected, for
the reason ADR-0012 gives: the failure then comes long after the load
that must report it, and on master it is a signal or no message.

**Reject the declaration of the functions.** Rejected. A guest module
can import `core.sys.posix.setjmp` and never call it, and druntime
itself declares the functions.

## Consequences

A guest that calls `setjmp` or `longjmp` does not load. Compiled D
accepts the same program, so `Native` diverges by design. The tests in
`tests/ut/backends/run/inlineasm.d` pin the diagnostic for a direct
call, a function pointer, a module-scope initializer, a `pragma(mangle)`
name, a template with two instances and the reported file and line. Two
tests pin that a guest definition and a D-linkage function with these
names still load.

If a real project needs a jump back to a saved frame, the path is
whole-function native compilation across the barrier, as for inline
assembler.
