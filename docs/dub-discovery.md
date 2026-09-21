# DUB discovery cache

Normal Snakebite project execution caches the result of `dub describe`.
No separate command or prototype is needed. The cache is stored in
`.snakebite/<project-key>/dub-description.bin`, under the current directory.

On a cache miss, Snakebite runs DUB as before. On a hit, it checks the saved
inputs and uses the saved description and build arguments. It does not
start DUB or the compiler for discovery. The frontend still reads the
current source files.

The cache tracks package recipes, selections, directory contents, DUB and
compiler binaries, compiler configuration, and local package registrations.
Version identifiers requested by the caller and environment changes also
invalidate it. The shell bookkeeping variables `_` and `SHLVL` are ignored.
Files added, removed, or renamed cause discovery to run again. An atomic
save with the same directory entries does not by itself invalidate the
description.

Source edits normally reuse discovery. When DUB generates a test runner,
it reads source module declarations. In that case, source edits also
invalidate discovery. Generated files are tracked as inputs.

The cache is conservative. Active generation hooks always run through DUB.
Custom DUB settings, source-tree symbolic links, and recipes with parent,
absolute, home-relative, or variable paths bypass caching. These cases
need more input tracking before they can be cached safely. A cache read or
write failure falls back to DUB. A checksum rejects damaged cache files.
Writes use a temporary file and an atomic rename.

To run fresh discovery and replace the cache:

```sh
SNAKEBITE_DUB_CACHE=refresh bin/sb -b bytecode examples/rt-simple
```

To disable cache reads and writes:

```sh
SNAKEBITE_DUB_CACHE=off bin/sb -b bytecode examples/rt-simple
```

Deleting the project's `dub-description.bin` also forces fresh discovery.
Do this if a tool changes package inputs without changing their filesystem
metadata. Do not edit project inputs during discovery.

## Measured result

Local release builds on `examples/rt-simple` reduced the `dub ovrhd` value
from about 13 ms with caching disabled to 0.3 ms on warm cache hits. All 22
guest tests passed in both cases. These are discovery times, not total
command times. Cold discovery still pays the DUB cost and records inputs.
Other projects can have different costs or use a cache bypass path.
