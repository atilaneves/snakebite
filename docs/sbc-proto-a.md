# SBC prototype A

## Scope

This prototype saves the current bytecode VM layout. It does not define a
new VM. It accepts trusted images from the same executable build, on the
same native target. It is not a bytecode verifier or a portable format.

The problem is the repeated frontend and bytecode compile cost. The current
VM uses resolved handler pointers and native constant addresses. These must
not survive in a saved image. The VM's native layout, dispatch handlers,
frame layout, and return-place rules must stay the same. The instruction
comments and role table in `vm.d`, and the existing relocation records,
provide the evidence for these rules. ADR-0009 and ADR-0015's frontend arena
rules stay unchanged. Native dependencies stay native.

The image stores each instruction in its existing 40-byte layout, with a
handler ID in the handler word. Each literal address has a recorded location
and a saved 64-bit value. Its old address word is cleared. Load reads a
function bundle once. It uses slices of the read buffer for instructions,
constants, parameters, and literal values. It patches handler IDs and literal
addresses in place. It does not parse D or run semantic analysis.

Direct guest calls use scalar call records and an argument payload. A call
record names its target by a bundle function ID, not a process address. Save
calls the existing preparation delegates without executing guest functions.
It collects new direct callees until the reachable set is complete. Compiled
function pointers identify shared targets and cycles during this step only.
No delegate, compiler object, or raw call-site structure goes into the file.
Load allocates all function records before it binds calls with
`CallSite.guest`. The loaded calls have no preparation delegates. Direct
calls do not need function-type signatures. Call-window and frame facts use
the existing VM code. Branch addresses use instruction indices in the file.

Handler IDs follow the current handler registration order. The image table
is built on first use, inside the measured save/load phase. It is local to
the current host thread. The normal VM tables are not changed by this step.
This includes the new table's allocation cost in the load measurement.

The extension also saves compiler-recorded scalar data blocks and pointer
edges. Each block has its allocation size and alignment. A reference names a
block ID and a byte offset, or an external linker name and offset. This also
applies to pointers inside slice descriptors and TypeInfo objects.
Save clears each recorded pointer word. Load allocates aligned blocks and
binds every edge. The loaded functions retain all blocks as explicit GC
roots. No pointer-like-word scan supplies these records.

Fixed native calls save the linker symbol, process-resolution context, and
the existing FFI argument and return ABI facts. Load resolves the name with
the existing process resolver and rebuilds the existing call plan from those
facts. It does not classify frontend types or guess names from addresses.
This extension covers process symbols, not dependency-image rebinding.

Closures, exceptions, indirect calls, TLS, classes, and other address targets
remain outside this experiment. No ownership, Dub, dependency-image, or
runtime setup change is included. Normal RAM compilation stays lazy.

TypeInfo allocations use the same recorder and data graph. Compile-time field
types identify pointer slots, including inherited qualifier fields. Copies
of initializer bytes carry the source's recorded pointer slots and alignment.
There is no separate metadata file format or load-time frontend recipe.
Known linked metadata and host vtables use the existing process resolver.
ABI argument types can need metadata before a guest `typeid` expression;
the compiler obtains their binding names from DMD's TypeInfo declaration.
RTInfo values 0 and 1 stay flags. Linked RTInfo addresses retain their known
symbol and offset. The runtime and the explicit loaded-block roots stay the
same, as required by ADR-0008 and the frontend arena ADR-0015.

The TypeInfo fixture covers structs, enums, pointers, static arrays, const,
immutable and shared wrappers, and linked primitive metadata. It checks
shared identity, names, alignment, initializer bytes, and a pointer from an
initializer to its backing string. A second saved root returns the same
metadata object. The compiler-free loader calls its real host `initializer`
and `toString` virtual methods. This also checks the external vtable binding.
The save process compiles both roots, executes no guest code, and exits
before the loader starts. Inputs 7/11 and 5/0 return 91 and 78.

Native, Interpreter, and Bytecode pass this fixture. The full matrix attempt
verified that CTFE does not implement `TypeInfo_Pointer.m_next`; only CTFE
is omitted. These results do not prove every TypeInfo variant. Class and
interface metadata, custom struct hooks/callbacks, dependency-image binding,
and the other exclusions above remain outside the verified scope.

## Build and check

From this worktree:

```sh
build/reggae.sh
ninja -j2 bin/ut bin/bench
bin/ut ut.backends.bytecode.imagea \
  ut.backends.bytecode.relocation ut.backends.call.arithmetic
```

Run the fresh-process checks with:

```sh
bash build/imagea-check.sh
```

The Image A run has 31 passing tests. Arithmetic, direct-call, and recursive
fixtures pass on Native, Bytecode, Ctfe, and Interpreter, with no omissions.
The direct fixture has two calls to one deferred callee, which has two calls
to another deferred callee. Save raises the compiled-function count from 1
to 3. The recursive fixture raises it from 1 to 2. Neither save process calls
a guest function. Each save process exits before the load process starts.

The shared-data fixture has one immutable `abcdef\0` backing array, a full
slice of length 6, an interior slice of length 4 at offset 2, and a separate
pointer equal to the interior slice pointer. Native-layout union descriptors
avoid CTFE making separate string literals. Native, Interpreter, and Bytecode
pass. A full matrix attempt verified that CTFE rejects overlapping union
reads, so these fixtures omit CTFE. Runtime indices check all byte pairs and
pointer identity. The image contains the backing bytes once. Changing that
one saved payload changes reads through both slices and the pointer alias.

The native fixture calls the existing C `strlen` on both loaded views. It
checks results 6 and 4 and returns 6499122 for inputs 7 and 11. Save runs no
guest code and exits before load. Missing-symbol and truncated-image checks
fail before execution.

The check builds a loader with no frontend import paths. It checks that the
loader has no frontend, DMD, or bytecode compiler symbols, and that it links
the real FFI execution entry and assembly stub. There are no FFI traps or
`strlen` intercepts. `SbcRuntimeOnly` excludes compiler-only declarations in
the FFI modules; their runtime implementation stays the same. Callback
operations use a frontend-free hook table. `SNAKEBITE_FORWARD_ONLY` builds the
existing assembly forward entries without the unused callback pool.
The loader links shared Phobos and druntime, as required by ADR-0008. This
extends the already-present `build/imagea-check.sh`; it is not integrated
with the repository's `tests/run_cli.py` subprocess checks.

The exact direct-call commands, after building the loader, are:

```sh
bin/ut --image-a-save /tmp/opencode/imagea-direct.sbc direct
/tmp/opencode/imagea-load /tmp/opencode/imagea-direct.sbc \
  7 11 12888667586533101800
```

Build that loader with the same DMD toolchain as `bin/ut`:

```sh
cc -DSNAKEBITE_FORWARD_ONLY -c source/snakebite/ffi/sysv_amd64.S \
  -o /tmp/opencode/imagea-sysv.o
dmd -debug -g -preview=dip1000 -version=SbcRuntimeOnly -i -Isource \
  -defaultlib=libphobos2.so -L--no-as-needed \
  build/imagea-load.d /tmp/opencode/imagea-sysv.o \
  -of=/tmp/opencode/imagea-load
```

The `arithmetic` and `recursive` save fixtures use the same commands and
return 58 and 571, respectively, for inputs 7 and 11. Existing in-process
coverage also checks instruction sizes, bundles, runtime inputs, overflow,
static-address refusal, and a truncated file.

## Reproduce

The function names are `arithmetic`, `arithmetic1`, and so on. The zero-size
fixture is the agreed function:

```d
module arithmetic;
ulong arithmetic(ulong x, ulong y) {
    ulong a = x + y;
    ulong b = a * 3UL;
    ulong c = b - x;
    return c + y;
}
```

For the shared B/C scale fixture, start with `ulong a=x;`, repeat
`a=(a+y)*3UL-x;` N times, then return `a`. The measured sizes are N = 0,
10, 100, 1000, with F = 1 and 10 functions. N = 0 uses the exact function
above, not an empty body. Source files and images are under
`/tmp/opencode/sbc-a/`.

```sh
flock /tmp/opencode/sbc-prototype-bench.lock bash -c '
  TIMEFORMAT="wall_s=%R"
  stem=/tmp/opencode/sbc-a/n1000-f10
  time bin/bench --sbc-a-baseline "$stem.d" unused 10
  time bin/bench --sbc-a-save "$stem.d" "$stem.sbc" 10
  time bin/bench --sbc-a-load "$stem.sbc" all
'
```

The baseline calls the existing compiler with relocation recording off.
Image compile turns the existing recording on. Both compile times are
reported. The load ratio must use baseline `full_ns`, not the slower image
compile. Save includes deferred callee compilation, conversion, allocation,
copies, and the file write. `--sbc-a-save` now exits without guest execution.
Load includes the file read, allocation, decode, lazy handler table setup,
and all fixups. Execution is separate. It includes construction of the host
VM used by the arithmetic entry helper. It is not a steady-state VM
throughput measurement. `all` executes five input pairs for every function:
`(7,11)`, `(0,1)`, `(123,456)`, `(ulong.max,1)`, and
`(ulong.max,ulong.max)`.

Wall time is reported separately by the shell, with millisecond precision.
The phase times exclude normal executable startup and shutdown. No native
or CTFE compile-time baseline is used.

## Measurement limits

One TypeInfo sample used the existing seven-argument benchmark mode, with
one root, one round, and no callees. The fixture source is
`/tmp/opencode/typeinfo-bench.d`. All three processes held
`/tmp/opencode/sbc-prototype-bench.lock` and ran on CPU 12. A 0.4-second sample
found that core and its sibling idle before the run. No warmup or repeat was
run. These are absolute phase times, not a stable speed comparison:

- Baseline full compile: 14.887 ms; execution: 0.139 ms.
- Image full compile: 11.708 ms; save: 0.818 ms; combined: 12.528 ms.
- Load: 0.825 ms; execution: 0.141 ms; image size: 7,792 bytes.
- Process wall times: baseline 28.248 ms, save 21.956 ms, load 10.241 ms.

Full compile includes runtime/frontend setup, parsing, entry compilation,
and all callee preparation. Save includes graph conversion and file writing.
Load includes reading, allocation, handler registration, symbol resolution,
and fixups. Both execution paths returned checksum 961 for five input pairs.
The image save path executed no guest code. No native guest baseline or
profile was run. `performance-patterns` was loaded; `linux-perf` was not
available. The final focused check ran 1,011 tests with no failures; the
fresh-process script also passed.

### Review fixes: constants and end pointers

Constants now use the shared data graph. The saved block retains the native
allocation's full size and alignment. Pointer records retain the base of a
symbol allocation before an offset is added. A target can name the end of
that allocation, but its pointer storage must remain wholly inside a block.
An adjacent allocation cannot replace the recorded target allocation.

The two regression tests failed before these fixes: the real addition
returned 7 instead of 8, and the three-byte end pointer failed during save.
Both now pass. Float, double, direct images, and pointer-sized backing
storage also have regression coverage. All five source fixtures pass the
full backend matrix without omissions. The focused image and relocation
run passed 64 tests; the fresh-process loader checks also passed.

One timing sample after these fixes used the same TypeInfo source,
`/tmp/opencode/typeinfo-bench.d`, with the existing seven-argument
`bin/bench` mode: root `arithmetic`, one round, no callees. All three
processes held `/tmp/opencode/sbc-prototype-bench.lock` and ran on CPU 12.
A 0.4-second sample before the run found 4.88% busy time on CPU 12 and 0%
on its sibling, CPU 28. No warmup, repeats, or profile were run.

- Baseline full compile: 10.2799 ms; execution: 0.1376 ms.
- Image full compile: 10.8939 ms; save: 0.8042 ms.
- Image compile and save: 11.7013 ms; image size: 7,832 bytes.
- Load: 0.6973 ms; execution: 0.1277 ms.

Both execution paths returned checksum 961. Save executed no guest code.
These are absolute phase times, not evidence of a speed change. The raw
log is `/tmp/opencode/astra-timing.log`. `performance-patterns` was loaded;
`linux-perf` was not available. No benchmark instrumentation was added or
removed for these fixes.

The tables below are historical arithmetic-only results from the original
format. They do not measure the deferred-call, shared-data, or native-call
extensions, or the new format's size. Only the single TypeInfo sample above
measures the current format. No commit was made during this extension.
Save-time preparation is in `saveImageBundleA`; data and symbol rebinding is
in load. The historical results do not establish their current costs.

The final run used the lazy handler table. These are medians of five fresh
process runs after one warmup. All 144 processes, including warmups and
baseline/save/load runs, returned the independently calculated checksum.
The measured load phase was below 10% of the existing compiler's full
frontend-plus-bytecode phase in all eight cases. This is an observed result
under contention, not proof of the target under controlled conditions.

| N | F | Instructions | Bytes | Baseline ms | Load ms | Load/base |
| -: | -: | -: | -: | -: | -: | -: |
| 0 | 1 | 5 | 336 | 20.919 | 1.358 | 6.49% |
| 0 | 10 | 50 | 3288 | 20.111 | 0.924 | 4.60% |
| 10 | 1 | 32 | 1632 | 13.894 | 0.928 | 6.68% |
| 10 | 10 | 320 | 16248 | 15.354 | 0.908 | 5.91% |
| 100 | 1 | 302 | 14592 | 15.860 | 1.260 | 7.94% |
| 100 | 10 | 3020 | 145848 | 20.244 | 0.966 | 4.77% |
| 1000 | 1 | 3002 | 144192 | 19.671 | 0.943 | 4.79% |
| 1000 | 10 | 30020 | 1441848 | 83.682 | 1.519 | 1.82% |

All times below are milliseconds. BC base is the existing compiler with
recording off. BC image has recording on. Save includes the new handler
table setup. Execute is the loaded path with five calls per function.

| N | F | BC base | BC image | Save | Execute |
| -: | -: | -: | -: | -: | -: |
| 0 | 1 | 0.141 | 0.137 | 1.360 | 0.229 |
| 0 | 10 | 0.389 | 0.287 | 1.011 | 1.239 |
| 10 | 1 | 0.150 | 0.178 | 0.980 | 0.179 |
| 10 | 10 | 0.556 | 0.627 | 0.963 | 1.052 |
| 100 | 1 | 0.383 | 0.361 | 1.015 | 0.179 |
| 100 | 10 | 2.682 | 2.723 | 1.384 | 1.107 |
| 1000 | 1 | 2.192 | 2.348 | 1.337 | 0.219 |
| 1000 | 10 | 27.719 | 28.603 | 3.221 | 1.684 |

At the largest size, recording adds about 3.2% to bytecode compile time.
The ratio above uses the baseline compile, not the image compile.
Small-case differences are noisy; no compiler speedup is claimed.

| N | F | Baseline wall ms | Save wall ms | Load wall ms |
| -: | -: | -: | -: | -: |
| 0 | 1 | 35 | 36 | 15 |
| 0 | 10 | 36 | 28 | 13 |
| 10 | 1 | 24 | 26 | 11 |
| 10 | 10 | 27 | 27 | 12 |
| 100 | 1 | 28 | 25 | 12 |
| 100 | 10 | 31 | 32 | 12 |
| 1000 | 1 | 30 | 31 | 11 |
| 1000 | 10 | 95 | 104 | 13 |

The raw log is `/tmp/opencode/sbc-a/measurements.log`. The numeric summary
is `/tmp/opencode/sbc-a/summary.json`. Build-process snapshots are in the
same directory as `contention-before.log` and `contention-after.log`.
They show active LDC builds for B, C, and unrelated JIT work. Thus the
shared measurement lock did not provide a quiet host. Repeat these runs
after those builds end before making a cross-prototype performance claim.

Results use a warm filesystem cache: one unreported warmup and five measured
runs, each in a fresh process. The common file lock serializes prototype
measurements. Builds and unrelated host activity do not take that lock.
These are not controlled-contention measurements. No cold-cache result is
claimed. The requested `linux-perf` skill was not available. The available
`performance-patterns` skill was loaded. No profile result is claimed.

The loader requires trusted same-build input. Length, count, ID, and literal
location checks detect some damaged files, but operand bounds and semantics
come from the existing compiler. A changed compiler or handler registration
order requires a new image. The format does not contain a build fingerprint.
