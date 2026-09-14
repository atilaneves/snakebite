---
status: accepted
---

# Every configuration links druntime and phobos shared

No snakebite configuration links druntime shared today. `dub.sdl` and
`reggaefile.d` link it statically, with `--export-dynamic` so `dlsym`
finds the host's symbols. The dependency image (ADR-0007) is a D
shared object loaded into the process. Two facts force every
configuration to link druntime and phobos shared instead.

One process holds one GC, one set of `TypeInfo`, and one `Throwable`
hierarchy. If the image links its own copy of druntime, an image
`Throwable` does not match a host `catch`. druntime also registers a
loaded D shared object, runs its module constructors, and adds its
data and TLS ranges to the GC, through its DSO registry, only when
druntime itself is the shared library.

Every snakebite configuration (`unittest`, `acceptance-test`, `sb`,
`sb-repl`, `bench`) links druntime and phobos shared: LDC uses
`-link-defaultlib-shared`, dmd uses `-defaultlib=libphobos2.so`. The
image links against the same shared libraries. The resulting binary
needs the compiler's shared libraries when it runs.

## Considered options

**Keep the host static, and link the image with unresolved druntime
references bound to the host's exported copy.** Rejected. The DSO
registry does not run, so the image's module constructors never run,
and the image's globals stay invisible to the GC. Phobos objects the
host did not link stay missing. Where both sides carry a copy, phobos
globals duplicate.

## Consequences

`--export-dynamic` stays. Root-owned template instantiations may
still resolve host symbols this way. CI, and any packaging step, must
ship or locate the `libdruntime` and `libphobos2` shared objects.
