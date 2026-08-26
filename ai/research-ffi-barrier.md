# Research: FFI barrier state of the art for a native-layout,
# non-JIT, statically-typed D interpreter

## Question

Snakebite backends interpret D while guest values already live in
native D/C ABI layout, and full compiler-generated `TypeInfo` is
available at interpret time. There is no JIT: the interpreter is a
tree-walker or bytecode VM, running as ordinary compiled/AOT D. This
note surveys how existing FFI systems bridge an interpreter and native
code in both directions -- guest calls native, and native calls guest
(callbacks) -- to find the dominant patterns, their real measured
costs, and which of them apply to a system that (unlike most of the
prior art) never needs runtime marshalling because guest and native
layout are identical by construction.

Six systems are covered: libffi, dyncall, LuaJIT's interpreter-mode
FFI, Java's Panama/FFM API, Mono's bytecode interpreter P/Invoke path,
and a family of hand-rolled/precompiled-stub approaches (cffi, Node
N-API, and LuaJIT's own call assembly, which doubles as a case study
for point 6). All are read from their own source or specs, not
secondary write-ups, except where flagged "third-party benchmark."

## 1. libffi

### `ffi_prep_cif`: prepare once, call many times

`ffi_prep_cif` builds an `ffi_cif` from runtime `ffi_type` descriptors
(size, alignment, and for aggregates a NULL-terminated `elements`
array of child `ffi_type*` -- itself a runtime layout descriptor, the
"cif" idea directly relevant to snakebite's `TypeInfo`-driven calls):

```c
ffi_status ffi_prep_cif(ffi_cif *cif, ffi_abi abi, unsigned int nargs,
                         ffi_type *rtype, ffi_type **atypes);
void ffi_call(ffi_cif *cif, void (*fn)(void), void *rvalue, void **avalue);
```
(`include/ffi.h.in`,
<https://github.com/libffi/libffi/blob/master/include/ffi.h.in>)

The manual is explicit that this split exists for reuse: "The first
thing you must do is create an `ffi_cif` object that matches the
signature of the function you wish to call. This is a separate step
because it is common to make multiple calls using a single `ffi_cif`."
(`doc/libffi.texi`,
<https://github.com/libffi/libffi/blob/master/doc/libffi.texi>)

Even so, every `ffi_call` still redoes per-call argument placement
(reading `ffi_type` and deciding registers vs. stack) from the `cif`
each time -- `ffi_prep_cif` amortizes signature *parsing*, not
per-call *dispatch*.

### New in 2026: reusable call plans

libffi's `master` branch (as of this research, copyright lines dated
2026) has added a second, faster amortization layer on top of
`ffi_prep_cif`/`ffi_call`: a `ffi_call_plan`, built once per `cif` and
then invoked repeatedly without redoing argument classification:

```c
/* Reusable call plans.
   A plan captures a signature's argument placement once so that
   repeated calls skip the per-call work that ffi_call would
   otherwise redo. ... A plan is immutable once built, so it may be
   shared and invoked concurrently from multiple threads. */
ffi_call_plan *ffi_call_plan_alloc (ffi_cif *cif);
void ffi_call_plan_invoke (ffi_call_plan *plan, void (*fn)(void),
                            void *rvalue, void **avalue);
void ffi_call_plan_free (ffi_call_plan *plan);
size_t ffi_call_plan_size (ffi_call_plan *plan);
```
(`include/ffi.h.in`, master,
<https://github.com/libffi/libffi/blob/master/include/ffi.h.in>,
around line 525)

This is documented and measured on the maintainer's own blog
(Anthony Green, the libffi maintainer): "Performance improvements in
libffi" (<https://atgreen.github.io/repl-yell/posts/libffi-plan-cache/>).
For a three-pointer-argument call the post reports:

| Path              | Time (ns) | vs. direct call |
|-------------------|-----------|------------------|
| Direct C call     | 1.9       | 1x (baseline)    |
| `ffi_call_plan`   | 5.1       | 2.7x             |
| `ffi_call`        | 31.0      | ~16x             |

The plan removes per-call re-classification: "`ffi_call` rebuilds the
placement every time while invoke just runs the prebuilt moves." For
the most common shapes (all-pointer/all-integer args, "around 90% of
the calls" in a GNOME Shell JS-to-C workload the post measured), the
plan degenerates to a hand-written thunk in read-only text that loads
arguments straight into registers, bypassing even the "list of moves"
interpreter. This is effectively libffi re-inventing the
"precompiled-trampoline-per-signature-shape" idea from a different
angle: cache the *decision* once, replay it fast, rather than
generating fresh machine code per signature the way a JIT would.

Numbers should be treated as **maintainer-measured, single-machine
benchmark**, not an ISO-blessed figure -- but they are first-party and
recent (2026), and roughly agree with a 2015 libffi maintainer
statement on plain overhead, discussed next.

### Confirmation from the maintainer, 10 years earlier

GitHub issue #195, "Is there a Call Overhead?"
(<https://github.com/libffi/libffi/issues/195>), closed by the same
maintainer (`atgreen`) in 2016:

> "Yes, it is slower thanks to the dynamic nature of libffi. It has a
> lot more work to do at runtime. Swig/JNI/etc require that you know
> everything at compile time. Libffi frees you from this requirement,
> but at a cost."

Asked whether JIT-compiling call trampolines would help:

> "Some, for sure. One step between current state, and JIT compiling,
> would be to create code templates for the most common call
> signatures, and replicate those."

That is exactly the call-plan feature later shipped, and exactly the
strategy this note's Synthesis recommends for snakebite (minus the
JIT, which snakebite also forgoes).

### Struct passing rules

`ffi_type.type == FFI_TYPE_STRUCT` with an `elements` array describes
aggregate layout field by field (`doc/libffi.texi`, `tm_type`
example). Struct classification into registers-vs-memory is done per
architecture; on x86-64 SysV, `src/x86/ffi64.c`
(<https://github.com/libffi/libffi/blob/master/src/x86/ffi64.c>) has a
`classify_argument` pass implementing the same eightbyte algorithm
covered in section 7 below. This is transparent to the `ffi_call`
caller: one `rvalue` buffer sized to `ffi_type.size` is supplied
regardless of whether the ABI actually returns the struct in
registers or via a hidden-pointer/`sret` slot.

### Closures (`ffi_prep_closure_loc`) and W^X

```c
void *ffi_closure_alloc (size_t size, void **code);
void  ffi_closure_free (void *);
ffi_status ffi_prep_closure_loc (ffi_closure*, ffi_cif*,
                                  void (*fun)(ffi_cif*,void*,void**,void*),
                                  void *user_data, void *codeloc);
```
(`include/ffi.h.in`, lines 383-399)

`ffi_closure_alloc` is explicitly a **dual-mapping** allocator for
W^X-hostile systems: "allocate[s] a chunk of memory holding size
bytes. This returns a pointer to the writable address, and sets *code
to the corresponding executable address." (`src/closures.c`,
<https://github.com/libffi/libffi/blob/master/src/closures.c>)

The source documents three fallback tiers, checked in the
preprocessor logic of `closures.c`:

1. **Single RWX mapping** attempted first on permissive systems.
2. **`mprotect`-based split**, e.g. NetBSD `PROT_MPROTECT`: "Primary
   mapping is RW, but request permission to switch to PROT_EXEC
   later," then `mprotect(codeseg, rounded_size, PROT_READ|PROT_EXEC)`
   once code is written.
3. **True dual mapping via a backing file** (`memfd_create` or a temp
   file on a writable+executable filesystem), mapped twice at
   different virtual addresses -- once writable, once executable --
   when anonymous RWX is refused outright: "Code compiled when this
   option is defined will attempt to map such pages once, but if it
   fails, it falls back to creating a temporary file ... and mapping
   pages from it into separate locations in the virtual memory space,
   one location writable and another executable." (`closures.c`,
   around line 129)

The comment block also flags the two concrete W^X blockers libffi
works around: Linux SELinux policies that audit-log
`PROT_EXEC|PROT_WRITE` mappings, and grsecurity/PaX `MPROTECT`, which
forbids `PROT_EXEC` on a page that was ever `PROT_WRITE`.

## 2. dyncall

### One entry point per return type -- no `ffi_call`-style single path

```c
DCint      dcCallInt      (DCCallVM* vm, DCpointer funcptr);
DClonglong dcCallLongLong (DCCallVM* vm, DCpointer funcptr);
DCdouble   dcCallDouble   (DCCallVM* vm, DCpointer funcptr);
DCpointer  dcCallPointer  (DCCallVM* vm, DCpointer funcptr);
void       dcCallVoid     (DCCallVM* vm, DCpointer funcptr);
```
(`dyncall/dyncall.h`, mirrored at
<https://raw.githubusercontent.com/Snaipe/dyncall/master/dyncall/dyncall.h>,
canonical project at <https://dyncall.org/>)

Arguments are bound one at a time, left to right, via
`dcArgInt`/`dcArgDouble`/etc. before the call. dyncall's own framing
(project front page, <https://dyncall.org/>) is architectural, not a
single "cif": "dyncall comprises three independent components:
'dyncall' for making function calls, 'dyncallback' for writing generic
callback handlers, and 'dynload' for loading code." Each is a
minimal, portable-C-plus-per-arch-assembly "call kernel," not a
runtime-typed descriptor system like libffi's `ffi_type` tree --
dyncall pushes typed values onto its `DCCallVM` one at a time rather
than building a reusable prepared-signature object at all, so there is
no dyncall analog to `ffi_prep_cif`/`ffi_call_plan` amortization to
measure. This is architecturally the *opposite* of what snakebite
wants: snakebite has the whole signature up front (from `TypeInfo`)
and should classify once, not push args incrementally per call.

### `dyncallback`: native-calls-guest direction

```c
DCCallback* dcbNewCallback (const char* signature,
                             DCCallbackHandler* funcptr, void* userdata);
void        dcbInitCallback(DCCallback* pcb, const char* signature,
                             DCCallbackHandler* handler, void* userdata);
void        dcbFreeCallback(DCCallback* pcb);
```
(`dyncallback/dyncall_callback.h`, mirrored at
<https://raw.githubusercontent.com/Snaipe/dyncall/master/dyncallback/dyncall_callback.h>)

The handler signature is uniform regardless of the native call's
actual C signature:

```c
typedef char (DCCallbackHandler)(DCCallback* pcb, DCArgs* args,
                                  DCValue* result, void* userdata);
```

A single generic native-code trampoline (per architecture, hand
written in assembly, analogous to libffi's closure trampoline)
receives the call, and `DCArgs`/`dcbArgInt` etc. let the handler pull
typed arguments back out one at a time -- the mirror image of the
forward-call API. Like the forward-call side, there is no published,
primary-source ns/call number for dyncall; the project does not
publish its own micro-benchmarks. Third-party numbers exist only
indirectly, via wrapper libraries built on top of it (see section 8).

## 3. LuaJIT FFI in pure interpreter mode

LuaJIT's FFI is usually discussed for its JIT trace-compiled fast
path, but the question here is what happens when a call executes in
the bytecode interpreter -- e.g. the call site has not been traced,
or tracing is disabled. That path runs through `lj_ccall_func` in
`src/lj_ccall.c`
(<https://raw.githubusercontent.com/LuaJIT/LuaJIT/master/src/lj_ccall.c>),
which is the C "fast function" backing `ffi.C.foo(...)` from
interpreted bytecode:

```c
int lj_ccall_func(lua_State *L, GCcdata *cd)
{
  ...
  cc.func = (void (*)(void))cdata_getptr(cdataptr(cd), sz);
  gcsteps = ccall_set_args(L, cts, ct, &cc);   /* classify args */
  cts->cb.slot = ~0u;
  lj_vm_ffi_call(&cc);                         /* asm call shim */
  ...
  gcsteps += ccall_get_results(L, cts, ct, &cc, &ret);
  ...
}
```
(`src/lj_ccall.c`, around line 866)

`ccall_set_args` walks the FFI `CType` chain -- the same runtime type
metadata the JIT's inline call-emission code shares -- and buckets
each argument into `cc.gpr[]`/`cc.fpr[]`/`cc.stack[]` slots per the
target ABI's classification macros (`CCALL_HANDLE_STRUCTRET`,
`CCALL_HANDLE_REGARG`, etc., defined per-architecture at the top of
the same file). Once classification is done, `lj_vm_ffi_call(&cc)` is
a single hand-written assembly routine (`src/vm_x64.dasc` for x86-64,
built by DynASM,
<https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/vm_x64.dasc>) that
loads the fixed `CCallState` struct's `gpr`/`fpr`/`stack` arrays into
the real machine registers per the platform's calling convention and
performs the call through a function pointer.

This is precisely "a generic assembly stub that loads an argument
array into registers per the ABI and calls through a function
pointer" (the brief's proposal 6), used identically whether the call
site is interpreted or later gets JIT-traced -- LuaJIT never generates
fresh machine code per call signature for `ffi.C.foo()`; it always
routes through this one assembly shim, driven by a runtime-computed
argument-classification struct. The classification cost
(`ccall_set_args`) is paid on every call in interpreter mode -- there
is no interpreter-mode equivalent of a cached "call plan"; LuaJIT's
only amortization mechanism for that cost is the trace compiler itself
inlining the classified moves into machine code, which by definition
does not apply in pure interpreter mode.

### Callbacks: a fixed pool of pre-generated stub slots

`src/lj_ccallback.c`
(<https://raw.githubusercontent.com/LuaJIT/LuaJIT/master/src/lj_ccallback.c>)
allocates callback trampolines from a **fixed-size pool built once at
initialization**, not per-callback machine-code generation:
`callback_mcode_init()` writes `CALLBACK_MAX_SLOT` worth of tiny stubs
("mov al, slot; jmp group" on x86/x64) into one page-sized region at
startup; each `ffi.cast`-created callback merely claims a free slot
and records its Lua function pointer and signature in a side table
keyed by slot number, rather than emitting new code. `CALLBACK_MAX_SLOT`
is capped by the mcode region size (`LJ_PAGESIZE * LJ_NUM_CBPAGE`), so
LuaJIT has a hard, fixed limit on live FFI callbacks -- overflow fails
allocation rather than growing.  This is the "small pool of
pre-generated closure stubs" strategy named in the brief, and it is
what a real, widely deployed interpreter chose over per-callback
codegen or a libffi/dyncall-style closure-per-object allocator: dispatch
is `slot -> lj_vm_ffi_callback -> callback_conv_args()` (native args
into a Lua-callable form) `-> ` the fixed continuation-marker frame,
run the Lua function, `callback_conv_result()` back. The source is
explicit that a callback firing must not be JIT-traced through: it
sets up a dedicated `LJ_CONT_FFI_CALLBACK` continuation rather than
resuming trace recording across the native/Lua boundary.

## 4. Java Panama / FFM API (JEP 454)

### API shape

```java
interface Linker {
  MethodHandle downcallHandle(MemorySegment address, FunctionDescriptor function);
  MemorySegment upcallStub(MethodHandle target, FunctionDescriptor function, Arena arena);
}
```
(JEP 454, <https://openjdk.org/jeps/454>)

`downcallHandle` takes a foreign function's address plus a
`FunctionDescriptor` (a runtime layout description of the C
signature -- again, the "cif" idea) and returns a `MethodHandle`;
`upcallStub` takes a `MethodHandle` (wrapping ordinary Java code) and
a `FunctionDescriptor` and produces a native function pointer, used
for e.g. supplying a Java comparator to C `qsort` -- JEP 454's own
worked example.

### `Linker.Option.critical()`: the trivial-call fast path

Per the current `java.lang.foreign.Linker.Option` javadoc:

> "A critical function is a function that has an extremely short
> running time in all cases (similar to calling an empty function),
> and does not call back into Java (e.g. using an upcall stub). Using
> this linker option is a hint that some implementations may use to
> apply optimizations that are only valid for critical functions.
> Using this linker option when linking non-critical functions is
> likely to have adverse effects, such as loss of performance or JVM
> crashes."
(<https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/foreign/Linker.Option.html>,
also indexed at
<https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/foreign/class-use/Linker.Option.html>)

Concretely, marking a call `critical` skips the normal
thread-state transition ("Java" -> "native" -> "Java", which a
safepoint-polling GC needs to know about) that every other downcall
pays, on the promise the callee returns almost immediately and never
re-enters the JVM. It can additionally allow passing on-heap array
segments directly as addresses (normally forbidden, since a moving GC
could relocate the backing array mid-call).

### Cost model and published numbers

JEP 454's own performance goal statement: "the performance goal of the
FFM API is to provide access to foreign functions and memory with
overhead comparable to, if not better than, JNI and
`sun.misc.Unsafe`." (<https://openjdk.org/jeps/454>) It further notes
the JIT is expected to do real work here: downcall method handles are
ordinary `MethodHandle`s the JIT can inline and specialize, unlike an
opaque JNI native stub -- i.e. Panama's low-overhead story is
explicitly **JIT-dependent**, not free in an interpreter.

Third-party JMH numbers (not first-party OpenJDK figures, flagged as
such):

- A JMH microbenchmark comparing raw call overhead reports **FFM
  ~49.7 ns/op vs. JNI ~56.6 ns/op** on the call-only path (~12%
  faster), attributed to FFM downcall handles being ordinary
  `MethodHandle`s the JIT can analyze, where JNI stubs are opaque to
  it.
- A separate report: "Panama is 13% faster than JNI by default, and
  using the `Linker.Option.isTrivial()` [now `critical()`] option ...
  can reach 160% of JNI performance" -- i.e. roughly 1.6x JNI
  throughput with the critical/trivial fast path enabled.
- String marshalling: FFM converts a 100-character C string to a Java
  `String` in ~43 ns/op vs. JNI's ~144 ns/op (~3.4x), Java-to-C at the
  same size ~2.2x.
- On JDK 24, "plain function call throughput ... is on par with JNI in
  most benchmarks," attributed to further JIT inlining/specialization
  of downcall stubs added without API changes.

None of these third-party numbers isolate an *interpreter-mode* (C1/
C0 or `-Xint`) cost; every reported figure benefits from JIT
compilation of the `MethodHandle` chain, which is architecturally the
mechanism Panama relies on for speed. This makes Panama the weakest
direct analog for snakebite among the systems surveyed: its whole
cost model assumes a JIT is present to specialize the call chain,
which snakebite by design does not have.

## 5. Mono's bytecode interpreter P/Invoke path

This is the closest prior-art analog to snakebite: Mono's `mini/interp`
is a bytecode interpreter (no JIT compilation of interpreted methods
required), and .NET's blittable value types already match native
memory layout, exactly like snakebite's D values.

### Two-tier dispatch: enumerated icall shapes vs. general P/Invoke

`src/mono/mono/mini/interp/transform.c`
(<https://raw.githubusercontent.com/dotnet/runtime/main/src/mono/mono/mini/interp/transform.c>)
emits one of three different bytecode instructions for a native call
site, decided once when the method is translated to interpreter
bytecode (not on every call):

```c
if (icall_sig != MINT_ICALLSIG_MAX && default_cconv) {
    interp_add_ins (td, MINT_CALLI_NAT_FAST);   /* enumerated shape */
    ...
} else if (native && method->dynamic && csignature->pinvoke) {
    interp_add_ins (td, MINT_CALLI_NAT_DYNAMIC);
} else if (native) {
    interp_add_ins (td, MINT_CALLI_NAT);        /* general pinvoke */
    ...
}
```
(`transform.c`, around line 4155-4185)

**`MINT_CALLI_NAT_FAST`** covers signatures that fit one of a fixed,
enumerated set of shapes (`MintICallSig`, e.g. `V_V`, `V_P`, `P_V`,
`P_P`, `PP_V`, `PP_P`, `PPP_V`, ... up to some arity). Its
implementation, `do_icall` in
`src/mono/mono/mini/interp/interp.c`
(<https://raw.githubusercontent.com/dotnet/runtime/main/src/mono/mono/mini/interp/interp.c>),
is a plain C `switch` over the enumerated shape, each case casting the
raw function pointer to a matching native C function type and calling
it directly -- letting the *host C compiler* generate correct
ABI-compliant call code for that one shape at Mono's own build time:

```c
switch (op) {
case MINT_ICALLSIG_PP_P: {
    typedef gpointer (*T)(gpointer,gpointer);
    T func = (T)ptr;
    ret_sp->data.p = func (sp[0].data.p, sp[1].data.p);
    break;
}
...
}
```
(`interp.c`, `do_icall`, around line 2412-2460)

This is exactly the brief's "switch-on-signature dispatch" strategy
(point 6): rather than building a runtime cif or driving a generic
asm shim, Mono precompiles (via ordinary C compilation of `interp.c`)
one tiny call thunk per common shape and switches on an enum to reach
it. It only applies to the icall subset whose shapes were anticipated
in `MintICallSig`.

**`MINT_CALLI_NAT`** is the fallback for everything else -- arbitrary
P/Invoke signatures, including structs -- and it *is* the generic
runtime-classification-plus-asm-shim design, implemented in
`ves_pinvoke_method` (`interp.c`, around line 1766). Per call site
(cached, not recomputed every call):

```c
gpointer call_info = *cache;
if (!call_info) {
    call_info = mono_arch_get_interp_native_call_info (get_default_mem_manager (), sig);
    mono_memory_barrier ();
    *cache = call_info;
}
CallContext ccontext;
mono_arch_set_native_call_context_args (&ccontext, &frame, sig, call_info);
args = &ccontext;
```
(`interp.c`, `ves_pinvoke_method`, around line 1826-1836)

`mono_arch_get_interp_native_call_info` performs the ABI
classification (SysV eightbyte rules on x86-64) once, and caches the
result in `imethod->data_items` keyed by call site -- the same
"prepare once" idea as `ffi_prep_cif`/`ffi_call_plan`, but owned by
Mono itself rather than an external library. The actual native call is
then made by a **per-architecture, hand-written assembly trampoline**
(`get_interp_to_native_trampoline()`, referenced from
`mono_arch_get_interp_native_call_info`/
`mono_arch_set_native_call_context_args` in the arch-specific
`mini-<arch>.c` files) that reads the generic `CallContext` and loads
registers per the real ABI -- structurally identical to LuaJIT's
`lj_vm_ffi_call(&cc)` shim from section 3, and to the brief's proposal
6.

### GC/stack-walk seam: the LMF chain

Every native transition pushes a `MonoLMFExt` ("Last Managed Frame")
node before leaving interpreted code and pops it on return, explicitly
so the GC/exception stack walker can skip the native frame(s) in
between two interpreted frames:

```c
/* interp_push_lmf:
 * Push an LMF frame on the LMF stack to mark the transition to
 * native code. This is needed for the native code to be able to
 * do stack walks. */
static void interp_push_lmf (MonoLMFExt *ext, InterpFrame *frame) {
    memset (ext, 0, sizeof (MonoLMFExt));
    ext->kind = MONO_LMFEXT_INTERP_EXIT;
    ext->interp_exit_data = frame;
    mono_push_lmf (ext);
}
```
(`interp.c`, around line 584-601)

The LMF is a thread-local intrusive linked list; each node records
enough (here, a pointer back to the `InterpFrame`) that a stack walker
crossing a native gap can jump straight back to the last interpreted
frame instead of trying to unwind through unknown native frames using
DWARF/CFI. This is the general seam pattern relevant to point 7:
native code between two guest frames is invisible to the guest's own
unwinder, so the interpreter must maintain its own out-of-band linked
list of "where was I last in guest code" markers, pushed/popped around
every native call, independent of whatever the OS-level unwinder does
for the native frame itself.

### `gsharedvt`: relevant, but a generics feature, not a P/Invoke feature

`gsharedvt` trampolines
(<https://www.mono-project.com/docs/advanced/runtime/docs/gsharedvt/>)
bridge calls between JIT-compiled code using concrete (fixed-size)
signatures and generic code sharing one specialization across
different value-type instantiations of unknown size at JIT time. They
are *not* the interpreter's native-call mechanism -- they solve a
different problem (generics specialization inside compiled code) that
does not arise for snakebite, since D generics are resolved by the
front end before the interpreter ever sees a call. Included here only
because the brief named it explicitly; it is not a P/Invoke-relevant
pattern for a non-generic-sharing interpreter like snakebite's.

## 6. Hand-rolled alternatives

Three lighter-weight, primary-sourced data points beyond Mono and
LuaJIT (already covered above, and themselves hand-rolled
switch-on-signature/asm-shim systems):

- **cffi's own guidance is "don't dynamically create closures."** The
  docs (<https://cffi.readthedocs.io/en/stable/using.html>) recommend
  declaring `@ffi.callback()` targets at module level -- i.e. a small,
  fixed, load-time-allocated pool of callback trampolines, with
  per-invocation identity threaded through via `ffi.new_handle()`
  context objects -- rather than creating a fresh libffi closure per
  logical callback. The stated reasons are squarely about the W^X
  seam: "On less common architecture, libffi is more likely to crash
  on callbacks;" hardened kernels (PaX/SELinux) "interfere" with the
  RWX mapping; macOS requires an explicit
  `com.apple.security.cs.allow-unsigned-executable-memory` entitlement;
  and systemd's `MemoryDenyWriteExecute=` unit setting can silently
  block closure allocation outright. This is independent, real-world
  confirmation that dynamic RWX/dual-mapping closure allocation is
  fragile enough in practice that a mature FFI binding steers users
  toward a fixed pool instead -- the same conclusion LuaJIT's fixed
  `CALLBACK_MAX_SLOT` pool (section 3) reaches by construction.
- libffi's own trampoline-table implementation
  (`FFI_EXEC_TRAMPOLINE_TABLE`, used on Apple platforms,
  `src/closures.c`) is itself pool-based: "libffi allocates two
  continuous 4k memory regions" per trampoline table and hands out
  fixed-offset code/data pairs from a `free_list`, rather than mapping
  fresh pages per closure -- i.e. even libffi's own most
  security-conscious backend converges on "pool of pre-generated
  stubs," not "mmap RWX per callback."
- **Node.js N-API-based native addons are the precompiled-per-signature
  end of the spectrum**, for comparison: an addon's call glue is
  ordinary C++ compiled ahead of time against a fixed, known
  signature, so there is no runtime type description or dispatch at
  all -- the "trampoline" is just a normal compiled function. This is
  reported (secondary source, no first-party N-API benchmark located)
  as "10-100x" faster than a libffi-based dynamic FFI for
  high-frequency native calls, because it eliminates runtime
  marshalling and dispatch entirely, at the cost of needing a
  signature known and compiled in ahead of time -- exactly the
  trade-off snakebite can also make, since D's static types are known
  to the interpreter before any given call site executes, just not
  known to the D *compiler* building the interpreter binary itself.

## 7. GC/exception seams and struct classification

### Native frame between two guest frames

Mono's LMF chain (section 5) is the general answer: an interpreter
that calls into native code must maintain its own side-channel record
of "the last point I was executing guest code," pushed immediately
before the native call and popped immediately after, so that anything
walking the stack for GC root-scanning or exception unwinding purposes
can skip straight over the native frame(s) using that side channel
instead of trying to interpret unknown native frame layouts. The
comment in `interp_push_lmf` is explicit that this exists specifically
"for the native code to be able to do stack walks" back into
interpreted code -- the native code in between is otherwise opaque to
Mono's own walker.

For an interpreter written in D and running as AOT-compiled D (like
snakebite), the equivalent seam is narrower in one respect
(druntime's own conservative GC can scan the native C stack frame
itself via normal stack scanning, since it's just more D-ABI-adjacent
memory) but not eliminated: druntime's precise-enough stack scanning
still needs *some* way to know which values live in that native
frame's registers/stack slots are live guest GC pointers, if the
native call can trigger a GC (e.g. because it calls back into guest
code, which allocates). AGENTS.md's stated policy -- druntime is
"either interpreted, compiled, or called via FFI," never re-implemented
-- means the safe default is conservative scanning of everything
between two "known guest frame" markers, i.e. a minimal LMF-style
marker pushed/popped around any native call that could re-enter guest
code, even if ordinary leaf native calls need no such bookkeeping.

### SysV AMD64 eightbyte classification

The canonical rules (System V AMD64 ABI psABI; summarized precisely
at <https://c9x.me/compile/doc/abi.html>, matching the official
`x86-64-abi` spec at
<https://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf>):

- Aggregate size is rounded up to a whole number of eightbytes (8-byte
  chunks); "if the size of an object is larger than two eightbytes or
  if [it] contains unaligned fields, it has class MEMORY" -- i.e. it
  is passed on the stack (or via a hidden pointer, for returns),
  skipping register classification entirely.
- Otherwise each eightbyte is classified recursively from its fields:
  `_Bool`/`char`/`short`/`int`/`long`/`long long`/pointers are class
  INTEGER; `float`/`double` are class SSE. When two fields land in the
  same eightbyte, "recursively classify fields and determine the
  class of the two eightbytes using the classes of their components:
  if any is INTEGER the result is INTEGER, otherwise the result is
  SSE" -- INTEGER dominates SSE within a merged eightbyte.
- Register assignment: INTEGER-class eightbytes consume
  `%rdi %rsi %rdx %rcx %r8 %r9` in order; SSE-class eightbytes consume
  `%xmm0`-`%xmm7`. If an aggregate's eightbytes would exhaust the
  remaining registers partway through, "revert the assignment for the
  first eightbytes and pass it on the stack" -- an aggregate is never
  split half-in-registers, half-on-stack.
- Returns: INTEGER-class results use `%rax`/`%rdx`; SSE-class results
  use `%xmm0`/`%xmm1`; MEMORY-class returns are written through a
  hidden pointer passed as an implicit first argument (in `%rdi`),
  which the callee also returns back in `%rax`.

This is exactly the algorithm libffi's `classify_argument`
(`src/x86/ffi64.c`) and Mono's `mono_arch_get_interp_native_call_info`
both implement, and the one snakebite's own SysV-targeting call shim
would need to implement once, driven off D's compile-time-generated
`TypeInfo` for the guest signature (field offsets, sizes, whether each
field is floating point) rather than off a hand-parsed C struct
declaration -- snakebite already has richer, more precise type data
available at the call site than any of libffi/dyncall/Mono do, since
those all reconstruct classification from a runtime type descriptor
that was itself derived from a signature string or `ffi_type` tree
built by a *binding author*, not by the same compiler that laid the
struct out.

## 8. Concrete numbers, collected

All numbers below are per-call cost; direction and methodology are
noted since the sources are not directly comparable (different
machines, different workloads).

| System / path                          | ~ns/call        | Source, caveat |
|-----------------------------------------|-----------------|----------------|
| Direct C call (baseline)                | 1.9              | libffi maintainer blog, single machine, 2026 |
| libffi `ffi_call`                       | 29-31            | Same source; also independently stated by maintainer in 2015 issue #195 as "a lot more work ... at runtime" |
| libffi `ffi_call_plan` (new, 2026)      | ~5.1 (3 ns over direct) | Same source, maintainer-measured |
| Panama FFM downcall (JIT, no critical)  | ~49.7            | Third-party JMH benchmark |
| JNI native call (JIT)                   | ~56.6            | Same third-party benchmark |
| Panama FFM with `critical()`/trivial    | ~160% of JNI throughput (i.e. ~35 ns, derived) | Third-party benchmark, order-of-magnitude only |
| N-API compiled addon vs. libffi-style FFI | "10-100x" faster (no absolute ns given) | Secondary/blog source, unverified methodology |
| Node-ffi vs. hand-written C++ addon     | "20x-40x" overhead (no absolute ns given) | Frequently repeated secondary figure (node-ffi project's own README framing) |

dyncall and Mono interpreter P/Invoke have **no located first-party
ns/call figures** -- neither project publishes its own
microbenchmarks of call overhead in the way libffi's maintainer now
does. Any number attributed to dyncall found during this research
(e.g. cross-language "ffi-overhead" style repos) measures a wrapper
library built on top of dyncall (such as Node's `fastcall`), not
dyncall's own call-VM in isolation, so no dyncall row is included
above rather than reporting a misattributed figure.

## Synthesis: recommended FFI architecture for snakebite

**Guest calls native (the hot path).** Do not adopt libffi's classic
`ffi_call` model (runtime `ffi_type` walk + register/stack placement
decision on every call) -- its own maintainer's 2026 numbers show that
model costs roughly 15-16x a direct call, and the fix libffi itself
just shipped (`ffi_call_plan`) is "compute the placement once, replay
a flat list of moves thereafter," which snakebite can do more cheaply
because it never needs libffi's runtime `ffi_type` parsing step at
all: D's compiler-generated `TypeInfo` already *is* the parsed
signature, known statically at each guest call site's "compile" time
(when the interpreter first sees that call expression/bytecode). The
right architecture is Mono's two-tier split (section 5), adapted:

1. At the point a guest call site is first prepared (AST node visited,
   or bytecode call instruction decoded/cached), classify the
   signature once using the SysV eightbyte algorithm (section 7)
   driven directly off D's `TypeInfo` -- field offsets, sizes, and
   INTEGER-vs-SSE-class per eightbyte are all derivable from
   `TypeInfo` without re-deriving anything at call time. Cache the
   result at the call site (an AST node field, or a bytecode operand
   slot), exactly like Mono's `imethod->data_items` cache keyed per
   call instruction, or libffi's now-explicit `ffi_call_plan`.
2. Dispatch that classified plan through one of two paths, chosen once
   per signature shape rather than per call:
   - **Enumerated-shape fast path**, à la Mono's `MINT_CALLI_NAT_FAST`
     `do_icall` switch: a fixed, D-compiler-compiled table of thunks
     for the handful of shapes that dominate real call traffic (all
     INTEGER-class args up to N, one/two SSE returns, void return,
     etc.), each thunk a literal typed function-pointer cast and call
     that the D compiler itself lowers correctly for that one shape.
     This needs no assembly and no runtime code generation, matching
     druntime's "interpreted, compiled, or FFI, never reimplemented"
     policy -- the ABI compliance work is done once, by dmd/ldc, at
     snakebite's own build time.
   - **Generic classified-args + asm shim fallback** for shapes the
     enumerated table doesn't cover (large/odd structs, high arity,
     variadics): a single, hand-written, per-architecture assembly
     routine that reads a small `CallContext`-style struct (GPR array,
     SSE/XMM array, stack-arg blob, computed once per call-site by
     step 1) and performs the actual call -- structurally identical to
     Mono's `mono_arch_set_native_call_context_args` +
     `get_interp_to_native_trampoline`, and to LuaJIT's
     `ccall_set_args` + `lj_vm_ffi_call`. This is a small, one-time
     investment (one shim per supported target, e.g. x86-64 SysV first)
     rather than an ongoing per-call cost, and avoids taking a libffi
     or dyncall dependency at all for the steady-state hot path.

   Both paths only need to exist for the *shapes snakebite's own guest
   programs actually generate calls for*; unlike libffi/dyncall, which
   must support arbitrary unknown-at-build-time signatures for
   arbitrary binding authors, snakebite is free to keep the enumerated
   table small and let the generic shim carry the long tail, since the
   generic shim's per-call cost (a few extra register moves through a
   struct instead of directly) is still far below `ffi_call`'s
   ~30 ns, which itself is already negligible next to typical
   interpreter dispatch overhead for a tree-walker.

   A pragmatic fallback for correctness-first bring-up: wrap libffi's
   *new* `ffi_call_plan` API behind the same "classify once at
   call-site preparation" seam, and only replace it with a hand-rolled
   shim for shapes that turn out to matter on real benchmarks. This
   keeps struct-classification correctness (SysV eightbyte edge cases)
   on libffi's tested implementation initially, at a small (~5 ns)
   fixed cost per call, while keeping the interface shape snakebite
   would want for its own shim later, and is compatible with the
   `libffi`/`dyncall` license terms already relevant to a D project
   depending on them.

**Native calls guest (callbacks, qsort-style comparators).** Reject
both libffi's and dyncall's default closure-per-callback allocation
model as the primary mechanism: cffi's own documentation (section 6)
and libffi's `closures.c` fallback chain (section 1) both show that
dynamic RWX/dual-mapped closure allocation is the single most
platform-fragile part of either library -- SELinux audit noise, PaX
`MPROTECT` outright refusal, macOS hardened-runtime entitlements, and
`systemd`'s `MemoryDenyWriteExecute=` are all real, independently
documented failure modes, not theoretical W^X purism. Instead, follow
LuaJIT's fixed-pool design (section 3) directly:

- At snakebite startup (or lazily, on first callback need), allocate
  **one** small executable region containing `N` identical,
  pre-generated trampoline stubs (`CALLBACK_MAX_SLOT`-style), each
  differing only by an embedded slot index. This is a single one-time
  W^X-sensitive allocation for the whole process, not one per
  callback, which sidesteps almost all of the fragility catalogued
  above -- there is exactly one RWX-then-mprotect-to-RX (or dual-map)
  operation to get right and test across target platforms, done once
  at startup, not on a hot path.
- Each live guest callback (a D delegate/function pointer being
  handed to native code, e.g. `qsort`'s `compar`) claims a free slot
  and records `(guest function pointer, guest signature/TypeInfo,
  slot)` in a side table, mirroring cffi's recommended pattern of
  fixed, pre-declared callback identities plus a `void*` context
  pointer for the actual per-call identity (`ffi.new_handle()`'s
  role) -- for snakebite this context pointer is simply the address of
  the interpreter's own closure/frame data for that guest function.
- The generic slot dispatcher (the one thing all `N` stub instances
  jump to) converts native argument registers back into guest-typed
  values using the same `TypeInfo`-driven eightbyte classification as
  the forward-call shim (symmetric to `ccall_get_results`/
  `callback_conv_args` in LuaJIT/Mono), then re-enters the
  interpreter to run the guest function body, then classifies and
  writes back the guest return value into the return
  registers/hidden-pointer slot the *native* caller expects.
- Push an LMF-style marker (section 7) around this re-entry, even
  though it is native-calls-guest rather than guest-calls-native: the
  moment guest code runs again inside a callback fired from native
  code, druntime's GC must be able to walk that guest stack region for
  roots the same way it would for any other guest frame, and the
  *native* frames that called into the callback stub are the ones that
  now need to be skippable/opaque to that walk -- the same two-way
  bookkeeping Mono's `MonoLMFExt` provides, just entered from the
  opposite direction.
- Size the fixed pool generously but finitely (LuaJIT ships with a
  page or few of stub slots) and treat overflow as a hard error
  surfaced to the guest program, exactly as LuaJIT does, rather than
  falling back to dynamic per-callback allocation -- that fallback is
  precisely the fragile path this design exists to avoid.

## References

- libffi `ffi.h.in`, master:
  <https://github.com/libffi/libffi/blob/master/include/ffi.h.in>
- libffi `libffi.texi`:
  <https://github.com/libffi/libffi/blob/master/doc/libffi.texi>
- libffi `closures.c`:
  <https://github.com/libffi/libffi/blob/master/src/closures.c>
- libffi `ffi64.c` (SysV struct classification):
  <https://github.com/libffi/libffi/blob/master/src/x86/ffi64.c>
- libffi issue #195, "Is there a Call Overhead?":
  <https://github.com/libffi/libffi/issues/195>
- Anthony Green, "Performance improvements in libffi":
  <https://atgreen.github.io/repl-yell/posts/libffi-plan-cache/>
- dyncall public header (mirror):
  <https://raw.githubusercontent.com/Snaipe/dyncall/master/dyncall/dyncall.h>
- dyncallback public header (mirror):
  <https://raw.githubusercontent.com/Snaipe/dyncall/master/dyncallback/dyncall_callback.h>
- dyncall project home: <https://dyncall.org/>
- LuaJIT `lj_ccall.c`:
  <https://github.com/LuaJIT/LuaJIT/blob/master/src/lj_ccall.c>
- LuaJIT `lj_ccallback.c`:
  <https://github.com/LuaJIT/LuaJIT/blob/master/src/lj_ccallback.c>
- LuaJIT `vm_x64.dasc`:
  <https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/vm_x64.dasc>
- JEP 454, Foreign Function & Memory API:
  <https://openjdk.org/jeps/454>
- `Linker.Option` javadoc (JDK 25):
  <https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/foreign/class-use/Linker.Option.html>
- Mono/`dotnet/runtime` `interp.c`:
  <https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/interp.c>
- Mono/`dotnet/runtime` `transform.c`:
  <https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/transform.c>
- Mono gsharedvt docs:
  <https://www.mono-project.com/docs/advanced/runtime/docs/gsharedvt/>
- cffi callback/closure guidance:
  <https://cffi.readthedocs.io/en/stable/using.html>
- System V AMD64 ABI classification summary:
  <https://c9x.me/compile/doc/abi.html>
- System V AMD64 ABI, official spec:
  <https://refspecs.linuxbase.org/elf/x86_64-abi-0.99.pdf>
- `dyu/ffi-overhead` cross-language benchmark repo (third-party,
  methodology as stated in repo README):
  <https://github.com/dyu/ffi-overhead>
- `node-ffi-napi` overhead framing (secondary, unverified
  methodology): <https://github.com/node-ffi-napi/node-ffi-napi>
