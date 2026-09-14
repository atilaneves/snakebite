---
status: accepted
---

# Host calls write their result into the guest frame

A host call returns a value across the barrier. This value needs a
place to go. Research on native return values
(`ai/research-native-return-values.md`) found that every call system
studied uses storage that the caller picks, sized by a layout
descriptor. Research on fast interpreter calls
(`ai/research-fast-interpreter-calls.md`) recommends a return slot in
the guest frame, picked by the caller, for guest-to-guest calls.
Neither note says if a host call should use that same slot, or a
separate scratch buffer copied into the frame after the call.

A host call writes its result straight into the guest frame's return
slot. For an INTEGER or SSE class return, the call stub (ADR-0001)
stores the result registers into the slot. For a MEMORY class return,
the call passes the slot's address as the hidden return pointer, so
the host writes into the slot in place. There is no scratch buffer
and no copy step.

The slot is at least register width (8 bytes), even for a narrower
integral type. The System V ABI does not define the upper bits of a
narrow return in a register. A struct return is classified with the
real eightbyte algorithm, not by size alone. The slot's size and
alignment come from the plan, which is built from the frontend's
`Type`.

## Considered options

A separate scratch buffer for host calls, copied into the frame after
the call. Rejected: this adds one copy on the hottest path, for no
benefit, since guest values already use native layout.

## Consequences

Every backend must be able to address a call's return slot before the
call runs. The frame layout already reserves this slot.
