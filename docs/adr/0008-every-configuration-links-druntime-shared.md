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

`--export-dynamic` stays: it is what lets `dlsym` reach a symbol
`bin/sb`/`bin/ut`/`bin/at` itself defines, the executable-only tier
below. CI, and any packaging step, must ship or locate the
`libdruntime` and `libphobos2` shared objects.

A guest-declared symbol resolves in this order: the dependency
image (ADR-0007), then every shared object the process already has
loaded (`dlsym(RTLD_NEXT, ...)` - valid because the resolver itself
is linked into the executable, never into a shared object, so
"next" means every already-loaded library and nothing in the
executable), and only as a last resort the executable itself
(`dlsym` on the handle from `dlopen(null, RTLD_NOLOAD)`). The
executable goes last because snakebite instantiates plenty of the
same templates a guest program also calls - `dirEntries` in
`snakebite.project` among them - and `--export-dynamic` exports that
instance's symbol from `bin/sb` too, with whichever closure layout
the host compiler happened to give its nested functions; a guest
backend that bound to it would read that closure with its own layout
instead. Searching every already-loaded library before the
executable keeps a guest call away from a host-side instantiation
whenever a genuine, independent native copy - the image, druntime,
phobos, a dependency's own C library - already answers the same
name.

That order does not, by itself, save a root-owned template
instantiation that has no independent native copy anywhere: a
dependency-less project's own call to `dirEntries` instantiates it
only inside `bin/sb`, so the executable-only tier still answers for
it, and `CallSelection.buildDecision`
(`source/snakebite/backends/calls.d`) still reuses that answer for
the root-owned call, by design, for any template a native symbol
resolves for. Telling that answer apart from a genuine independent
copy is a call-routing question, not a symbol-resolution order
one, and is not solved here.
