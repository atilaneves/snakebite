---
status: accepted
---

# Host cleanup for a hardware fault lives in a caller frame

Issue #535: `runGuest` in `source/snakebite/faultsignal.d` is the
controlled guest entry. When host code that runs inside it faults, for
example on a load through a null pointer, snakebite raises a
`HardwareFault` (see Guest fault in `CONTEXT.md`). Host cleanup that
sits in a caller frame of the faulting code runs. Host cleanup in the
same frame as the faulting instruction can be lost.

## Decision

Host code must put required cleanup for a hardware fault in a caller
frame of the code that can fault. It must not put that cleanup in the
faulting frame. This means a `catch (HardwareFault)` or a `scope(exit)`
in the same function as the faulting load or divide is not reliable.

The reason: the compiler does not know that a load or a divide can
throw. An optimizing compiler can see that the code in the `try` block
cannot throw, and then remove the `catch` and the `scope(exit)`. The
`HardwareFault` is thrown from a signal handler, so the compiler cannot
see it. A call to another function can throw, so a caller frame keeps
its handler. Snakebite does not change this: it needs a compiler that
treats a faulting instruction as a throwing call.

## Measured

Two probes ran on master, each in a native test process that calls
`runGuest`. In "same-frame catch", the body has `try { fault } catch
(HardwareFault)` in the frame of the fault. In "same-frame scope(exit)",
the body has `scope(exit)` in the frame of the fault, and a `catch` is
outside `runGuest`. A probe passes when the fault is caught or the
cleanup runs.

| Compiler mode | Same-frame catch | Same-frame scope(exit) |
|---|---|---|
| dmd debug | pass | pass |
| dmd optimized | pass | pass |
| LDC debug | pass | pass |
| LDC optimized | fail | fail |
| LDC thin LTO | fail | fail |
| LDC full LTO | fail | fail |

In each failing mode, the fault escapes the same-frame catch and the
process exits with status 1. The same-frame cleanup does not run. The
probes are not in the repository. This record states the limit.

## Examples

Correct. The `scope(exit)` and the `catch` are in a caller frame of the
function that faults:

```d
void faults(int* p) {
    *p = 1;                    // can fault
}

void owner(int* p) {
    scope(exit) release();     // caller frame: runs
    faults(p);
}

void entry(int* p) {
    runGuest({
        try
            owner(p);
        catch (HardwareFault fault) {
            report(fault);
        }
    });
}
```

Incorrect. The cleanup is in the faulting frame:

```d
void owner(int* p) {
    scope(exit) release();     // same frame as the fault: can be removed
    *p = 1;                    // can fault
}
```

## Consequences

An author of host code that can run inside `runGuest` checks every
`scope(exit)`, destructor and `catch` that must run after a fault. Each
one moves to a caller frame of the faulting code. Each `runGuest` entry
owns its own required cleanup outside `body`, as the comment above
`runGuest` says. Debug builds can pass tests that an optimized or LTO
build of the same code fails.
