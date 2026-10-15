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
