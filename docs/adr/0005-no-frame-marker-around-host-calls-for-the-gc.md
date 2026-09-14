---
status: accepted
---

# No frame marker around host calls for the GC

`ai/research-ffi-barrier.md` describes Mono's LMF marker. Mono pushes
it before every native call and pops it after. This lets a stack
walker skip native frames between two guest frames. Umbrella #100,
decision 10, says guest code must look like native code to the GC.
This is a constraint on every backend, not one subsystem's job.

The barrier keeps no side record of the last guest frame. No marker
is pushed around a host call. No marker is pushed around a callback
entry. Druntime's GC scans every registered thread's whole stack by
default. This scan is conservative: it finds a guest pointer held in
a host frame between two guest frames, with no marker needed to guide
it. Guest frame storage is already registered with `GC.addRange`
(`source/snakebite/framestack.d`, #11), so the GC also sees guest
frames directly. A test forces a collection inside a callback entry,
while the host caller holds the only reference to a guest object.
This test checks that the conservative scan finds that reference on
its own.

## Considered options

A Mono-style marker, pushed and popped around each host call.
Rejected. Druntime's GC has no gap for the marker to close: it scans
host frames the same way it scans guest frames. The marker would also
cost two stores on every call, on the hottest path, for no benefit.

## Consequences

Any backend that keeps guest values in memory the GC does not scan
breaks this decision. That memory must be registered with the GC, the
same way the frame stack is.

A thread druntime does not know about must attach to druntime before
it runs guest code. See ADR-0006 for this rule.

Exceptions still unwind through the host's own tables, not through a
guest-maintained chain (ADR-0004). This decision only covers GC
root-scanning, not exception unwinding.
