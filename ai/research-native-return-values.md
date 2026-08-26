# Research: getting runtime-typed return values back in native layout

## Question

Snakebite's backends must call functions whose return type is only known
at runtime (the interpreter reads it off the AST or a compile-time type
descriptor) and must receive the result in native memory layout, with no
boxing and no marshalling step. This note surveys how six existing
systems solve the general problem of "call an arbitrary function and
get its return value back," to find the dominant pattern and its
caveats.

## 1. libffi

`ffi_call` is the single call entry point, for every return type:

```c
void ffi_call(ffi_cif *cif, void *fn, void *rvalue, void **avalues);
```

(`include/ffi.h.in`,
<https://github.com/libffi/libffi/blob/master/include/ffi.h.in>)

- **What the caller passes in**: a prepared `ffi_cif *cif`, the function
  pointer, a caller-allocated `rvalue` buffer, and an `avalues` array of
  `void *` pointing at the argument storage.
- **Who allocates return storage**: the caller. `rvalue` is plain,
  untyped memory (`void *`); libffi never allocates or returns storage
  of its own for a "by value" result. If `rvalue` is `NULL` the result
  is discarded (this includes struct-by-value returns; libffi supplies
  internal scratch space for the callee itself in that case).
- **The `sizeof(ffi_arg)` minimum-size rule** (`doc/libffi.texi`,
  <https://github.com/libffi/libffi/blob/master/doc/libffi.texi>,
  around the `ffi_call` `@defun`):

  > `rvalue` is a pointer to a chunk of memory that will hold the
  > result of the function call. This must be large enough to hold
  > the result, no smaller than the system register size (generally
  > 32 or 64 bits), and must be suitably aligned; it is the caller's
  > responsibility to ensure this. ... for integral (not struct)
  > types that are narrower than the system register size, the
  > return value will be widened by libffi. libffi provides a type,
  > `ffi_arg`, that can be used as the return type.

  This exists because many ABIs return small integers in a full
  register (e.g. x86-64 SysV zero/sign-extends into RAX), so libffi's
  assembly stubs write a full register width regardless of the
  declared C type; asking the caller to always reserve at least
  `sizeof(ffi_arg)` bytes avoids a buffer overflow on every platform.
  Struct/float returns are the exception — those are written at their
  natural size, not widened.
- **How type info travels**: `ffi_prep_cif` builds the `ffi_cif` from
  runtime-supplied `ffi_type` descriptors:

  ```c
  typedef struct _ffi_type {
    size_t size;
    unsigned short alignment;
    unsigned short type;
    struct _ffi_type **elements;
  } ffi_type;

  typedef struct {
    ffi_abi abi;
    unsigned nargs;
    ffi_type **arg_types;
    ffi_type *rtype;
    unsigned bytes;
    unsigned flags;
  } ffi_cif;

  ffi_status ffi_prep_cif(ffi_cif *cif, ffi_abi abi, unsigned int nargs,
                           ffi_type *rtype, ffi_type **atypes);
  ```

  (`include/ffi.h.in`, same URL as above). `ffi_type` is itself a
  runtime value — size, alignment and (for aggregates) an `elements`
  array of child `ffi_type*` pointers, NULL-terminated. This is a
  first-class runtime layout descriptor, exactly the "cif" idea named
  in the research prompt.
- **Struct/large returns**: represented by `ffi_type.type ==
  FFI_TYPE_STRUCT` with `elements` describing the fields (documented
  with worked examples in `doc/libffi.texi`, e.g. the `tm_type`
  example building an `ffi_type` for `struct tm`). At the ABI-lowering
  level (`src/x86/ffi64.c`,
  <https://github.com/libffi/libffi/blob/master/src/x86/ffi64.c>) a
  `classify_argument` pass decides per-eightbyte whether a struct is
  returned in registers or via the SysV hidden-pointer/`sret`
  convention (memory class); this is transparent to the `ffi_call`
  caller, who still just supplies one `rvalue` buffer sized to the
  struct's `ffi_type.size` — libffi's per-arch code handles whether
  that buffer's address is secretly passed to the callee as a hidden
  first argument or is filled by the caller from return registers on
  return.

## 2. dyncall

dyncall's call-vm API is the sharpest **counter-example** to a single
untyped return path: it has one entry point per return type.

```c
DC_API DCint      dcCallInt      (DCCallVM* vm, DCpointer funcptr);
DC_API DClonglong dcCallLongLong (DCCallVM* vm, DCpointer funcptr);
DC_API DCdouble   dcCallDouble   (DCCallVM* vm, DCpointer funcptr);
DC_API DCpointer  dcCallPointer  (DCCallVM* vm, DCpointer funcptr);
DC_API void       dcCallVoid     (DCCallVM* vm, DCpointer funcptr);
```

(`dyncall/dyncall.h`; mirrored at
<https://github.com/Snaipe/dyncall/blob/master/dyncall/dyncall.h>,
canonical source at <https://dyncall.org/>)

- **What the caller passes in**: a `DCCallVM*` that has already had
  arguments bound via `dcArgInt`/`dcArgDouble`/etc (in left-to-right
  order), plus the raw function pointer. The *caller of the C API*
  must pick the one `dcCall<Type>` function matching the callee's
  actual return type — dyncall gives the value back as an ordinary C
  return value of that type, not through a buffer, for every scalar
  type.
- **Who allocates return storage**: for scalars, none is needed — the
  value comes back in the C return-value register(s), and the
  `dcCall<Type>` wrapper's own C ABI takes care of that. There is no
  "call with type read from a runtime tag" scalar entry point.
- **Struct/aggregate returns break this pattern** and fall back to a
  caller-allocated buffer, exactly like libffi:

  ```c
  DC_API void dcCallStruct(DCCallVM* vm, DCpointer funcptr,
                            DCstruct* s, DCpointer returnValue);
  ```

  and, in the newer aggregate API, `dcBeginCallAggr()` /
  `dcCallAggr(DCCallVM*, DCpointer funcptr, DCaggr* ag, DCpointer
  ret)`, where `ret` is caller-supplied memory "large enough to hold
  the to-be-returned aggregate," and the aggregate's field layout is
  described by a `DCaggr*` built at runtime via `dcNewAggr(maxFields,
  size)` / `dcAggrField(...)` (dyncall manual, "Calling Conventions",
  <https://dyncall.org/docs/manual/manualse11.html>, and the dyncall.3
  man page, <https://www.dyncall.org/docs/dyncall.3.html>).
- **How type info travels**: for scalars, purely through which C
  function symbol the embedding code calls — i.e. compile-time choice
  at the call site. For aggregates, through a `DCaggr` descriptor built
  at runtime (size + per-field type/offset), the same shape as
  libffi's `ffi_type.elements`.
- **Takeaway**: dyncall confirms the prompt's premise directly. Its
  typed-entry-point design only works because whoever calls
  `dcCallInt` vs `dcCallDouble` already knows the type at their own
  call site (compile time for that C code). The moment the return type
  itself is a runtime value (struct/aggregate case), dyncall abandons
  the per-type-function idea and falls back to a caller-allocated
  buffer plus a runtime-built layout descriptor — precisely the
  libffi/ctypes/Miri shape.

## 3. JNI

JNI's `Call<Type>Method` family is per-return-type, in three variants
(varargs, `va_list`, and an array of `jvalue`):

```c
jint    CallIntMethod   (JNIEnv *env, jobject obj, jmethodID methodID, ...);
jint    CallIntMethodA  (JNIEnv *env, jobject obj, jmethodID methodID,
                          const jvalue *args);
jint    CallIntMethodV  (JNIEnv *env, jobject obj, jmethodID methodID,
                          va_list args);
jobject CallObjectMethod(JNIEnv *env, jobject obj, jmethodID methodID, ...);
void    CallVoidMethod  (JNIEnv *env, jobject obj, jmethodID methodID, ...);
jint    CallStaticIntMethodA(JNIEnv *env, jclass clazz, jmethodID methodID,
                              jvalue *args);
```

(JNI Functions spec, e.g.
<https://docs.oracle.com/en/java/javase/21/docs/specs/jni/functions.html>)

```c
typedef union jvalue {
    jboolean z; jbyte b; jchar c; jshort s;
    jint i; jlong j; jfloat f; jdouble d; jobject l;
} jvalue;
```

- **What the caller passes in**: the receiver, a `jmethodID` (opaque,
  resolved ahead of time via `GetMethodID`, itself carrying the method's
  signature), and arguments either as varargs, a `va_list`, or a
  `jvalue*` array (used only for **arguments**, never as an out
  parameter for the return value).
- **Who allocates return storage / how type travels**: there is no
  generic "call and get result into an opaque buffer" JNI entry
  point. **The C/C++ programmer calling into JNI must already know the
  Java return type at their own source line** and pick the matching
  `Call<Type>Method`; JNI does not offer a way to defer that choice to
  runtime data the C caller reads dynamically. (An embedder that itself
  wants runtime dispatch — e.g. a scripting-language binding layer —
  has to build its own `switch` on a type tag obtained from
  reflection, and call the correspondingly named function; JNI supplies
  the type tag machinery, via `Method.getReturnType()`
  /`GetObjectClass`-style reflection, but not a return path that is
  itself untyped.)
- **Struct/aggregate returns**: not applicable — the JVM has no
  by-value aggregate return; every non-primitive return is a
  `jobject` reference.
- **Takeaway**: JNI is the clean illustration of the "typed wrapper"
  end of the spectrum, and of its precondition: it works only because
  the *native* code author is expected to know the Java signature being
  called at the point they write the C call. There is no route in JNI
  itself for "the return type is a value I only have at runtime, please
  hand me raw bytes."

## 4. Rust Miri / rustc const-eval interpreter

This is the closest analogue to snakebite's CTFE-style interpreter: it
executes MIR (a typed, ABI-aware IR) and needs to hand a computed value
back to a caller frame with no boxing.

Every interpreter stack frame stores a `return_place`
(`compiler/rustc_const_eval/src/interpret/stack.rs`,
<https://github.com/rust-lang/rust/blob/master/compiler/rustc_const_eval/src/interpret/stack.rs>):

```rust
/// The location where the result of the current stack frame should be
/// written to, and its layout in the caller. This place is to be
/// interpreted relative to the *caller's* stack frame. We use a
/// `PlaceTy` instead of an `MPlaceTy` since this avoids having to
/// move *all* return places into Miri's memory.
return_place: PlaceTy<'tcx, Prov>,
```

`init_stack_frame`, the entry point used when the interpreter is about
to call another function
(`compiler/rustc_const_eval/src/interpret/call.rs`,
<https://github.com/rust-lang/rust/blob/master/compiler/rustc_const_eval/src/interpret/call.rs>),
takes the destination place from its caller and threads it straight
into the new frame:

```rust
pub fn init_stack_frame(
    &mut self,
    instance: Instance<'tcx>,
    body: &'tcx mir::Body<'tcx>,
    caller_fn_abi: &FnAbi<'tcx, Ty<'tcx>>,
    args: &[FnArg<'tcx, M::Provenance>],
    with_caller_location: bool,
    destination: &PlaceTy<'tcx, M::Provenance>,
    mut cont: ReturnContinuation,
) -> InterpResult<'tcx> {
    ...
    // *Before* pushing the new frame, determine whether the return
    // destination is in memory. Need to use `place_to_op` to be
    // *sure* we get the mplace if there is one.
    let destination_mplace = self.place_to_op(destination)?.as_mplace_or_imm().left();

    // Push the "raw" frame -- this leaves locals uninitialized.
    self.push_stack_frame_raw(instance, body, destination, cont)?;
    ...
```

and when the callee later executes `return`, the interpreter copies
the value straight into that place:

```rust
self.copy_op_allow_transmute(&return_op, frame.return_place())?;
```

(`call.rs`, same file, near the `pop_stack_frame` logic).

- **What the caller passes in**: a `PlaceTy<'tcx, Prov>` — an abstract
  "memory location plus type/layout" handle, not a concrete pointer.
  It may resolve to an actual memory allocation (`MPlaceTy`) or, for
  values that fit in a register/immediate, stay unmaterialized until
  something forces it into memory (`force_allocation`, in
  `projection.rs`). This is the interpreter's own moral equivalent of
  "caller-allocated return buffer," except deferred/lazy rather than
  eagerly `alloca`'d.
- **Who allocates return storage**: the *caller* frame decides where
  the result goes (its own local slot, a temporary, etc.); the callee
  frame never allocates its own return storage, it just writes into
  whatever `PlaceTy` it was handed.
- **How type info travels**: the `PlaceTy`'s type/layout comes from
  `FnAbi<'tcx, Ty<'tcx>>` — rustc's own runtime-computed ABI/layout
  descriptor for the function being called (field offsets, size,
  alignment, and how the value is classified for the target ABI:
  register(s), indirect/sret, etc). `FnAbi` is computed from MIR/type
  information that is available to the interpreter only at
  "interpret time," i.e. it plays exactly the role of libffi's
  `ffi_cif`/`ffi_type` or dyncall's `DCaggr`, but built directly from
  the compiler's own type system rather than a hand-rolled descriptor.
- **Struct/large returns**: handled uniformly by the same `PlaceTy`
  mechanism — `FnAbi`'s classification of the return already encodes
  whether the aggregate is returned by-value in a place or indirectly;
  the interpreter does not special-case aggregates versus scalars at
  the `return_place`/`copy_op_allow_transmute` level. The ABI-level
  indirection (sret-equivalent) is resolved by `FnAbi`, mirroring how
  libffi's per-arch code hides the SysV memory-class decision behind
  a single `rvalue` buffer.

## 5. Wasm runtimes (Wasmtime)

Wasmtime's Rust embedding API offers both ends of the spectrum
side by side, which makes the trade-off explicit.

Untyped, `Val`-based call (`Func::call`,
<https://docs.rs/wasmtime/latest/wasmtime/struct.Func.html>):

```rust
pub fn call(
    &self,
    store: impl AsContextMut,
    params: &[Val],
    results: &mut [Val],
) -> Result<()>
```

`Val` is a tagged-union enum covering every Wasm value type (`I32`,
`I64`, `F32`, `F64`, `V128`, `FuncRef`, `ExternRef`, ...). The caller
must pre-size `results` to the callee's declared arity (mismatches
cause an error), but need not know the concrete types at compile time
— they are checked at the call boundary against the runtime function
signature obtained from the module.

Typed wrapper (`Func::typed`, `TypedFunc::call`,
<https://docs.rs/wasmtime/latest/wasmtime/struct.TypedFunc.html>):

```rust
pub fn typed<Params, Results>(&self, store: impl AsContext)
    -> Result<TypedFunc<Params, Results>>
where Params: WasmParams, Results: WasmResults;

pub fn call(&self, store: impl AsContextMut, params: Params) -> Result<Results>
```

`Func::typed` performs one runtime check (that the module's actual
signature matches the `Params`/`Results` chosen by the embedder's Rust
source) and thereafter every call skips both the tagged-union
representation and the repeated signature check.

- **What the caller passes in**: untyped path — a `&[Val]` and a
  pre-allocated `&mut [Val]` slab of the right length (caller-owned
  storage, but "boxed" per-element as a tagged union rather than raw
  bytes); typed path — a native Rust value of a compile-time-known
  `Params` type, getting back a native `Results` type directly, with
  no tagged union at the FFI boundary.
- **Who allocates return storage**: caller, in both cases — the
  untyped path literally requires the caller to allocate `results`
  ahead of the call, matching the general "caller-allocated storage"
  pattern, just with `Val`-sized (not raw-byte) slots.
- **How type info travels**: untyped — the module's own signature,
  read at call time and checked against `results.len()`/each `Val`
  variant; typed — encoded entirely in the Rust generic parameters,
  verified once at `Func::typed()` against the module signature, after
  which the Rust compiler's own knowledge of `Params`/`Results`
  replaces any runtime tag.
- **Struct/large aggregate returns**: core Wasm has no by-value
  aggregate return type (only scalars, and as of the multi-value
  proposal, multiple scalar results) — `results: &mut [Val]` already
  generalizes to that. Aggregate ABI concerns (e.g. `wasm-bindgen`
  passing structs through linear memory) live above this layer, not
  in `Func::call` itself.

## 6. CPython ctypes (`_ctypes`)

CPython's `ctypes` module is libffi's most direct downstream consumer
and demonstrates the full loop from "runtime Python type object" to
"raw libffi call" to "native/boxed Python result," in
`Modules/_ctypes/callproc.c`
(<https://github.com/python/cpython/blob/main/Modules/_ctypes/callproc.c>).

Return buffer allocation, directly mirroring the libffi minimum-size
rule (`_call_function_pointer` / `_ctypes_callproc`, around
`callproc.c:1277`):

```c
void *resbuf;
...
rtype = _ctypes_get_ffi_type(st, restype);
...
resbuf = alloca(max(rtype->size, sizeof(ffi_arg)));
...
if (-1 == _call_function_pointer(st, flags, pProc, avalues, atypes,
                                  rtype, resbuf,
                                  argcount, argtype_count))
    goto cleanup;
```

and inside `_call_function_pointer` (`callproc.c:947`):

```c
ffi_call(&cif, (void *)pProc, resmem, avalues);
```

Conversion back to a Python object, `GetResult` (`callproc.c:993`):

```c
static PyObject *GetResult(ctypes_state *st,
                            PyObject *restype, void *result,
                            PyObject *checker)
{
    ...
    StgInfo *info;
    if (PyStgInfo_FromType(st, restype, &info) < 0) { ... }
    if (info->getfunc && !_ctypes_simple_instance(st, restype)) {
        retval = info->getfunc(result, info->size);
        ...
    } else {
        retval = PyCData_FromBaseObj(st, restype, NULL, 0, result);
    }
    ...
}
```

- **What the caller passes in**: at the Python level, a `CFUNCTYPE`
  wrapper with a `restype` attribute (a ctypes type object, chosen by
  the Python programmer, but read by `_ctypes` purely as *data* at
  call time — the C code in `callproc.c` never knows at its own
  compile time what `restype` will be).
- **Who allocates return storage**: `_ctypes_callproc`, in C, via
  `alloca`, i.e. the same "caller-allocated raw buffer" pattern as
  libffi itself, plumbed straight through.
- **How type info travels**: `restype` (a runtime Python object) is
  turned into an `ffi_type *rtype` via `_ctypes_get_ffi_type`, which
  is exactly libffi's runtime type descriptor; `resbuf` is sized from
  `rtype->size`, floored at `sizeof(ffi_arg)` — CPython re-derives the
  same minimum-size rule libffi's docs specify, rather than libffi
  enforcing it internally, confirming it really is the caller's
  responsibility.
- **Struct/large returns**: same buffer/`ffi_type.elements`
  mechanism as libffi directly; `GetResult` converts the raw bytes in
  `resbuf` back into a Python object via each ctypes type's `getfunc`
  (a per-type "read raw bytes at this address into a Python value"
  function pointer, resolved from `restype`'s `StgInfo` at the same
  runtime-dispatch point) or, for compound types, wraps the same raw
  memory in a `PyCData` instance directly (no copy/marshalling, the
  Python object's backing buffer *is* the native bytes).
- **Note (lower priority, not verified against source in this pass)**:
  LuaJIT's FFI is reported (in its own documentation, not verified
  here against source) to follow the same shape — a `cdata` return
  value's raw memory is filled directly per its `CType` at the FFI
  call boundary, typed via LuaJIT's own runtime `ctype` table, with no
  intermediate boxing. Confirm against LuaJIT source before relying on
  this if it matters to snakebite's design.

## Synthesis

**Hypothesis under test**: for a runtime-dispatch caller with no
possibility of using templates/generics (compile-time types), the
dominant pattern is a caller-allocated, untyped/opaque return buffer,
sized and aligned from a runtime-built type/layout descriptor (a
"cif"), and typed convenience wrappers exist only where the return
type genuinely is known at the *call site's own compile time*.

**The evidence supports the hypothesis, with no real counterexample in
snakebite's actual situation.** Concretely:

- libffi (`rvalue` + `ffi_cif`/`ffi_type`), CPython ctypes (`resbuf` +
  `ffi_type` derived from a runtime Python type object), and Miri/rustc
  (`return_place: PlaceTy` sized via `FnAbi`) are the same pattern
  three times over: caller-allocated (or caller-designated) storage,
  raw/native layout, sized and aligned by a descriptor that is itself
  built from runtime data. Miri is notable for making the "place" a
  first-class lazy/abstract handle rather than an eager `alloca`, but
  the shape — caller decides destination and layout before the call —
  is identical.
- dyncall and JNI look at first glance like counterexamples (they
  offer typed convenience functions, no untyped path), but neither
  actually contradicts the hypothesis: both require the type to be
  known **at the call site's own compile time** (a human wrote
  `dcCallInt` or `CallIntMethod` because they knew the signature when
  they wrote that C code). Both retreat to a caller-allocated buffer
  plus a runtime layout descriptor (`DCaggr`, and — for JNI — simply
  "not supported, no aggregates exist") the moment the type stops
  being compile-time-known, which is exactly snakebite's situation for
  *every* call, not just the aggregate case.
- Wasmtime shows the trade-off explicit and intentional within one
  library: `Func::call` (untyped, `Val` tagged union, runtime type
  check) versus `TypedFunc::call` (compile-time `Params`/`Results`,
  checked once). Snakebite's interpreter backends are, in Wasmtime's
  own terms, permanently in the `Func::call` position — they cannot
  ever reach for `TypedFunc` because there is no Rust/D generic
  parameter available at the point the call is issued.

**Caveats snakebite's own design should account for**:

1. **Minimum return-buffer size for register-returned scalars.**
   libffi's `rvalue`-must-be->=`sizeof(ffi_arg)` rule, and CPython
   ctypes' independent re-implementation of the same
   `max(rtype->size, sizeof(ffi_arg))` floor, both exist because many
   ABIs return small integers zero/sign-extended to a full register.
   If snakebite ever calls through libffi (or hand-rolls equivalent
   platform call stubs) it needs the same floor on any return buffer
   for integral types smaller than a register, even though D's own
   type is e.g. `byte` or `bool`. This is a call-mechanism detail, not
   a language-visible one — the interpreter would still expose the
   correctly-*sized* D value to its own code, but the physical scratch
   buffer used during the raw call needs the wider floor.
2. **Struct/aggregate returns need explicit ABI classification, not
   just "reserve `sizeof(the struct)` bytes."** Every system surveyed
   that supports aggregate returns (libffi, dyncall's `DCaggr`,
   Miri's `FnAbi`) computes, per platform ABI, whether the aggregate
   comes back by value in registers or via a hidden-pointer/`sret`
   convention, and hides that decision from the immediate caller
   behind a single flat buffer. Snakebite's own "cif"-equivalent
   (whatever runtime layout descriptor it builds for a callee) needs
   to encode this classification per target, not assume a struct
   return is always either "in registers" or always "via hidden
   pointer."
3. **Alignment, not just size, is the caller's responsibility.**
   libffi's doc text calls out "must be suitably aligned" for
   `rvalue` explicitly as something libffi does not check. Any
   snakebite equivalent (e.g. a `alloca`'d or GC-allocated scratch
   buffer for a raw call) needs to size/align from the same runtime
   layout descriptor it uses for everything else (presumably
   `TypeInfo`-equivalent), not assume natural alignment of some
   generic byte buffer is enough.
4. **The "layout descriptor built at runtime" is the load-bearing
   object across every system.** `ffi_type`/`ffi_cif`, `DCaggr`,
   `FnAbi`/`Layout`, ctypes' `StgInfo`, and Wasm's function-type
   section entry are all runtime, not compile-time, values, and all
   of them are what makes "one generic call path, no boxing" possible.
   Snakebite already needs a runtime type-layout representation for
   D's own type system (sizes/alignment/field offsets); the same
   representation is the natural "cif" to reuse for the call-and-get-
   return-value-back mechanism, rather than inventing a second one
   specific to FFI/call boundaries.

## References

- libffi header:
  <https://github.com/libffi/libffi/blob/master/include/ffi.h.in>
- libffi manual (`ffi_call`, struct `ffi_type` examples):
  <https://github.com/libffi/libffi/blob/master/doc/libffi.texi>
- libffi x86-64 ABI classification:
  <https://github.com/libffi/libffi/blob/master/src/x86/ffi64.c>
- dyncall header (`dcCallInt` et al., mirror):
  <https://github.com/Snaipe/dyncall/blob/master/dyncall/dyncall.h>
- dyncall manual, calling conventions / aggregate returns:
  <https://dyncall.org/docs/manual/manualse11.html>
- dyncall.3 man page:
  <https://www.dyncall.org/docs/dyncall.3.html>
- JNI Functions specification (Java SE 21):
  <https://docs.oracle.com/en/java/javase/21/docs/specs/jni/functions.html>
- rustc const-eval interpreter, `Frame`/`return_place`:
  <https://github.com/rust-lang/rust/blob/master/compiler/rustc_const_eval/src/interpret/stack.rs>
- rustc const-eval interpreter, `init_stack_frame`/`destination`:
  <https://github.com/rust-lang/rust/blob/master/compiler/rustc_const_eval/src/interpret/call.rs>
- Wasmtime `Func` (untyped call):
  <https://docs.rs/wasmtime/latest/wasmtime/struct.Func.html>
- Wasmtime `TypedFunc` (typed call):
  <https://docs.rs/wasmtime/latest/wasmtime/struct.TypedFunc.html>
- CPython `_ctypes` call implementation:
  <https://github.com/python/cpython/blob/main/Modules/_ctypes/callproc.c>
