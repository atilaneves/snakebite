# Process collector selection

The existing `sb`, `sb-repl`, and `bench` binaries include symgc 0.0.9.
Set `DGC=symgc` before starting a process to select it:

```sh
DGC=symgc bin/sb --backend=bytecode examples/rt-simple
DGC=symgc bin/sb-repl
DGC=symgc bin/bench <project> -w 0 -r 1
```

An unset or empty `DGC`, or another value, retains druntime's conservative
collector. The choice applies to host and guest allocations. Frontend
allocations still use the arena by default. `--lowmem` retains its usual
meaning. The executable and loaded D images share one druntime and Phobos.

`bench` executes backend rows in its own process, so its backend rows use
the selected collector. The native oracle runs separate compiled D
processes. Ordinary D programs do not use this `DGC` setting.

The choice is experimental. Upstream symgc does not implement
`runFinalizers` or attribute changes through `setAttr` and `clrAttr`.
Its profile statistics are incomplete. SIMD arrays can also lack the
alignment that druntime requires: repeated `new int4[3]` allocations
reproduce a fault in native D with symgc, without Snakebite. A workload
that needs these features can fail. Use the default collector for those
workloads. No performance improvement is claimed by this change.

The startup constructor registers the selected collector's early thread
hook before druntime starts. The GC proxy then creates the selected
collector and forwards later thread hooks. The quiet `sdcq` factory avoids
extra collector messages in command output.

## Bytecode array allocation cache

An optional LDC build includes a conservative collector with a cache for
small array allocations in the bytecode JIT. Use matching LDC 1.43.0
(D 2.113.0) compiler, headers, and shared druntime on x86-64 Linux.
The build checks the installed collector source against a fixed checksum
before it applies its patch. The compiler and druntime must come from
the same LDC installation because the collector uses private runtime
interfaces.

In a fresh worktree, set the path to the installed collector source
before generating the build:

```sh
collector_source=/path/to/core/internal/gc/impl/conservative/gc.d
SNAKEBITE_ARRAY_CACHE_COLLECTOR_SOURCE="$collector_source" build/reggae.sh
ninja bin/sb
DGC=array-cache bin/sb --backend=bytecode path/to/project
```

The cache admits zero-initialized arrays of pointer-sized structs that
contain pointers and have no destructor. It holds spares for one exact
array type per dispatch. The collector uses its existing block
allocation and array metadata code to fill the cache. Cache hits use
the native array layout and charge each allocation to the calling
thread. A dispatch can retain up to 298,592 bytes in spare blocks plus
its cache record of about 16 KiB while it runs or stays suspended.

Druntime continues to collect host and guest memory. Array allocations
in a finalizer follow the usual runtime path. The experimental mode
can change collection pressure. Memory exhaustion behavior has not
been measured.
