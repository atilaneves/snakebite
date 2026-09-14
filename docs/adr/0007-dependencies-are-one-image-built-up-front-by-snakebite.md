---
status: accepted
---

# Dependencies are one image, built up front by snakebite

The resolver calls `dlsym` on the running process. It can only reach
symbols linked into the snakebite binary. A dub project's
dependencies, for example unit-threaded's nine archives for
`examples/rt`, are unreachable today. Issue #36 proposed relinking
dub's archives into one shared object, loaded on first dependency
symbol request. Umbrella #100 decision 4 requires guest native code to
come from the same compiler family as the host. dmd and LDC order
`extern(D)` parameters differently. They also order `this` and the
hidden return pointer differently. The classifier in
`source/snakebite/ffi/abi.d` switches on the host compiler. `bin/ut`
is built with dmd, `bin/sb` is built with LDC, and a user's dub
defaults to dmd.

snakebite builds one shared object, the dependency image, from a
project's dub dependency archives. It builds this image itself,
before any guest code runs, the same way `dub test` builds
dependencies up front. This matches Umbrella #100 decision 4: the
image always comes from the same compiler family as the host, never
from the user's dub compiler setting. The user never sees the image.

snakebite caches the image. It rebuilds the image only when its
inputs change: the dependency set from `dub describe`, the compiler,
and the build settings. A second run costs nothing. snakebite never
builds the image lazily, on first dependency symbol request.

The image links against the same shared druntime as the host
(ADR-0008). Image build time gets its own row in the bench table. It
is neither frontend time nor run time.

## Considered options

**`dlopen` an arbitrary library the user supplies.** Rejected. A D
library built with its own static druntime brings a second GC and a
second set of `TypeInfo`. Two of each break identity checks across
the barrier.

**Require the user's dub compiler to match the host compiler.**
Rejected. A compiled test binary runs without the user configuring
anything. snakebite must do the same.

**Compile the project's own modules into the image.** Rejected. This
reintroduces the compile step snakebite exists to remove.

## Consequences

Each compiler family needs its own dependency build on disk.
`snakebite.project` must ask `dub describe` for `linker-files`.
Module constructors of dependencies run when druntime loads the
image, not when snakebite decides to run them.

## Supersedes

The "built lazily on first dependency symbol request" plan in #36.
