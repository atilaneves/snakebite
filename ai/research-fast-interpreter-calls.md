# Research: fast function calls and frames in non-JIT interpreters

## Question

Snakebite is a JIT-less interpreter for D used as a CTFE/scripting-style
backend. A full D frontend runs first, so every type's size, alignment
and field layout is known at guest-compile time, and values are stored
in native memory layout (no boxing, no tagged unions, no NaN-boxing).
The speed target is beating a full compile+link+run cycle, not beating a
JIT. Function calls are the usual hot path and the biggest overhead
source in naive interpreters, so this note surveys how existing
interpreters represent frames, pass arguments, and dispatch calls — and
why the slow ones (Miri, DMD CTFE) are slow despite native-ish value
layout.

Caveat on sourcing: findings below were gathered from the cited primary
sources (repo files, implementer blog posts, papers). Where a quote or
name could only be confirmed through a summarizing fetch rather than a
raw file read, or not confirmed at all, that is flagged inline.

## 1. Mono interpreter (mono/mini interp)

Mono's interpreter (shipped in dotnet/runtime under
`src/mono/mono/mini/interp/`, used on iOS/wasm and other AOT-only
platforms) is the clearest production example of the "transform once,
run a flat instruction stream, share one big stack" design.

- **Frames are tiny structs chained by pointer**, defined in
  `src/mono/mono/mini/interp/interp-internals.h`
  (<https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/interp-internals.h>):

  ```c
  struct InterpFrame {
      InterpFrame  *parent;
      InterpMethod *imethod;
      stackval     *retval;   /* points into the parent's stack */
      stackval     *stack;    /* this frame's base in the shared stack */
      InterpFrame  *next_free;
      InterpState   state;    /* saved ip, for re-entrancy */
  };
  ```

  Note `retval`: the return destination is a pointer into the *caller's*
  stack area, fixed before the call — the same caller-designated
  return-place pattern documented in
  `ai/research-native-return-values.md` for libffi/Miri. Frames are
  pooled via `next_free`, not malloc'd per call. The same layout, with
  byte offsets, is mirrored in a comment in
  `src/mono/browser/runtime/jiterpreter.ts`, confirming it is
  load-bearing ABI.

- **One contiguous per-thread stack, valloc'd up front.** In
  `src/mono/mono/mini/interp/interp.c` the per-thread `ThreadContext`
  does `context->stack_start = mono_valloc_aligned(INTERP_STACK_SIZE,
  MINT_STACK_ALIGNMENT, ...)`; every `InterpFrame->stack` is just a
  pointer into this arena, bumped per call. `interp-internals.h`
  documents the context's `stack_pointer` as "the highest stack memory
  that can be used by the current frame... needed when re-entering
  interp... and also needed for the GC to be able to scan the stack."
  A `FrameDataAllocator` (`FrameDataFragment`) layers `localloc`
  regions on top of the same scheme.

- **IL is transformed once per method into an internal opcode stream
  ("MINT"), cached on the method.** `InterpMethod` (same header) holds
  `unsigned short *code` (the transformed stream), plus — crucially for
  snakebite — *precomputed byte offsets*: `guint32 *local_offsets`,
  `arg_offsets`, and `locals_size`/`alloca_size`, all computed by the
  transform pass in `src/mono/mono/mini/interp/transform.c`
  (`mono_interp_transform_method`). Caching is a plain
  `int transformed; // boolean` field checked at call sites. The
  transform pass also does inlining, constant propagation, basic-block
  optimization and superinstruction fusion — `driver.c` defines
  `INTERP_OPT_SUPER_INSTRUCTIONS` alongside `INTERP_OPT_INLINE`,
  `INTERP_OPT_CPROP`, `INTERP_OPT_BBLOCKS`, and `mintops.h` has fused
  compare+branch opcodes (`MINT_BRFALSE_I4_SP` ..
  `MINT_BLT_UN_I8_IMM_SP`, covered by `MINT_IS_SUPER_BRANCH`). There is
  even interpreter-level tiering: `tiering.c`'s `tier_up_method`
  re-transforms a hot method at a higher optimization level
  (`InterpMethod` has `entry_count` and `optimized_imethod` fields).

- **Call dispatch is direct-pointer for static calls, plain vtable
  lookup for virtual calls.** Non-virtual callees are resolved at
  transform time and stored in the method's `data_items` constant pool
  (e.g. `cmethod = (InterpMethod*)frame->imethod->data_items[ip[3]]` in
  `interp.c`). Virtual dispatch is an indexed vtable load
  (`m_class_get_vtable(vtable->klass)[slot]`) each time; no evidence of
  inline caching was found in the interpreter's dispatch code (negative
  finding, not an exhaustive read of the 8000+-line `interp.c`).

- **Structs by value are byte copies, not boxes.** Per
  `interp-internals.h`, "Value types are represented on the eval stack
  as pointers to the actual storage" (with a documented 16 MB cap);
  copies go through `stackval_from_data`/`stackval_to_data`-style
  helpers (function names surfaced via a summarizing fetch of
  `interp.c`, not re-verified line-by-line).

- **Performance numbers:** mono's own announcement, "Mono's New .NET
  Interpreter" (<https://www.mono-project.com/news/2017/11/13/mono-interpreter/>),
  gives no benchmarks, only the qualitative claim that "certain
  programs can run faster by being interpreted than being executed
  with the JIT engine" (startup-dominated workloads — directly
  relevant to snakebite's beat-the-compiler target). The only numeric
  data found is for the wasm "jiterpreter" tier layered on top
  (.NET 8 Preview 2 blog,
  <https://devblogs.microsoft.com/dotnet/asp-net-core-updates-in-dotnet-8-preview-2/>):
  46.7%/86.9% faster micro-benchmarks, 40.8% faster JSON — numbers for
  the JIT-assist, not the pure interpreter.

## 2. wasm3 and wazero (interpreter mode)

### wasm3

wasm3's own `docs/Interpreter.md`
(<https://github.com/wasm3/wasm3/blob/main/docs/Interpreter.md>)
describes the "M3" (MetaMachine) model:

- Wasm bytecode is **translated in a compilation pass into
  "operations"** — "pages of meta-machine code". Each operation is a C
  function with one fixed signature, approximately
  `void * Operation_Whatever (pc_t pc, u64 * sp, u8 * mem, reg_t r0,
  f64 fp0)`; "the operations themselves drive execution forward" — each
  op tail-calls the next op's function pointer rather than returning to
  a central switch loop. The doc notes the fixed signature makes "the
  M3 'virtual' machine registers end up mapping directly to real CPU
  registers" (pc/sp/mem/r0/fp0 stay pinned in argument registers on
  x86-64 across the whole tail-call chain), and traces the lineage to
  "threaded code" from 1970s interpreter design, made practical by
  modern tail-call optimization.
- **Values live in fixed-width 64-bit slots** (`m3slot_t` in
  `source/m3_exec.h`,
  <https://github.com/wasm3/wasm3/blob/main/source/m3_exec.h>), indexed
  by pointer arithmetic off `_sp`; the compile pass decides per opcode
  whether an operand stays in the r0/fp0 "register" argument or lives
  in a stack slot (encoded in opcode-name suffixes like `_rs`/`_sr` —
  naming convention paraphrased from the source, exact comment wording
  not re-verified). Argument/return passing between functions is slot
  copies (`RETURNSLOTS`/`NUMARGSLOTS` macros with `memmove` over
  `m3slot_t` arrays).
- **Measured numbers** (`docs/Performance.md`,
  <https://github.com/wasm3/wasm3/blob/main/docs/Performance.md>),
  CoreMark 1.0 on an i5-8250U: wasm3 1627.9 vs Wasmer-singlepass 4065.6
  (2.5x), wasmtime-optimized 6453.5 (4.0x), native 19144.9 — i.e.
  **wasm3 is ~11.8x slower than native**, which is the realistic
  ceiling for a state-of-the-art threaded-code interpreter on
  compute-bound code. fib(40): wasm3 3.83 s vs native C 0.23 s
  (~17x) — and vs Lua 5.1's interpreter at 16.65 s, i.e. ~4x faster
  than a classic switch-loop dynamic-language interpreter on a
  call-heavy benchmark. Footprint claim (README): "~64Kb for code and
  ~10Kb RAM."

### wazero (interpreter engine)

wazero's interpreter
(`internal/engine/interpreter/interpreter.go`,
<https://github.com/tetratelabs/wazero/blob/main/internal/engine/interpreter/interpreter.go>)
is a plainer design, self-described in its godoc as "a naive
interpreter-based implementation," chosen for portability:

- **One contiguous `stack []uint64`** on the `callEngine` holds all
  operand values (every wasm type bit-cast into a uint64 slot), plus a
  `frames []*callFrame` call stack where `callFrame` is just
  `{pc uint64; f *function; base int}` — `base` being the frame's
  window into the shared value stack.
- **Bytecode is lowered ahead of execution**: `CompileModule` runs an
  IR compiler (`irCompiler.Next()` + `lowerIR()`) producing a
  `compiledFunction{body []unionOperation, ...}` per function — it does
  not interpret raw wasm opcodes.
- **Performance:** wazero's docs (<https://wazero.io/docs/>) say only
  that the compiler engine "is faster than Interpreter, often by order
  of magnitude (10x) or more". No absolute interpreter numbers found.

## 3. Rust Miri / rustc const-eval: why native-ish layout is not enough

Miri and rustc CTFE share the `rustc_const_eval::interpret` engine, and
despite storing values in real target layout they are extremely slow.
The authoritative primary source is the Miri paper — Jung, Kimock,
Poveda, Sánchez Muñoz, Scherer, Wang, "Miri: Practical Undefined
Behavior Detection for Rust", POPL 2026
(<https://research.ralfj.de/papers/2026-popl-miri.pdf>), which the Miri
README cites as "this paper describes Miri itself".

- **Measured slowdown: 3000x–7000x vs native** (§6.2): "For the lowest
  n, Miri is about 3000x slower than the native code; for the highest
  n, the ratio is about 7000x." For comparison the same paper notes
  sanitizers are <10x and Valgrind 20x–50x. The commonly repeated
  "tens of times slower" figure does not come from the Miri team.
- **Why, despite native layout — the overhead is bookkeeping, not
  boxing:**
  - Every memory allocation is an `Allocation` object
    (`compiler/rustc_middle/src/mir/interpret/allocation.rs`,
    <https://github.com/rust-lang/rust/blob/main/compiler/rustc_middle/src/mir/interpret/allocation.rs>)
    carrying, besides `bytes`, a `provenance: ProvenanceMap` (per-byte
    pointer-provenance tracking), an `init_mask: InitMask` (bitvector
    of which bytes are initialized), `align`, `mutability`, and a
    machine `extra` field (Stacked/Tree Borrows state in Miri).
  - The paper is explicit that the naive architecture — "every single
    local variable is represented by a Pointer to memory" — was
    "prohibitively slow"; the shipped engine (§5.1) keeps scalar
    locals as `Operand`s directly in the `Frame` and only materializes
    an `Allocation` when a local's address is taken. I.e. even Miri
    had to adopt "locals live in the frame, not in per-value
    allocations" to be usable at all.
  - The operand type `Scalar`
    (`compiler/rustc_middle/src/mir/interpret/value.rs`) is
    `Int(ScalarInt) | Ptr(Pointer<Prov>, u8)` — 24 bytes per scalar,
    with provenance on the pointer variant; at the memory level any
    byte can carry provenance (`Byte ≜ Uninit | Init(val, prov)` in the
    paper's model), because integer-typed copies can smuggle pointer
    provenance.
  - Per-access checks: validity invariants, alignment, Stacked/Tree
    Borrows aliasing, data races — each has a `-Zmiri-disable-*` flag
    documented in the README
    (<https://github.com/rust-lang/miri/blob/master/README.md>) as
    existing partly to "make Miri run faster". Miri also "turns off
    all MIR optimizations as those may remove UB".
- **Design-goal caveat**: Miri's purpose is finding "all de-facto
  Undefined Behavior"; the paper's own future-work section says that
  drastically improving performance will likely require fundamentally
  altering its architecture. Plain rustc CTFE shares the
  `Allocation`/provenance/init-mask machinery (paper footnote 3) but
  not the Miri-only borrow/data-race checks. The lesson for snakebite
  is precise: native layout buys nothing if every load/store also
  updates provenance maps, init masks and validity checks. A fast
  CTFE interpreter that trusts its frontend can skip all of it and
  just read/write raw memory.

## 4. DMD's CTFE interpreter and newCTFE

- **The existing engine is an AST interpreter that allocates AST nodes
  as values.** Lineage per Walter Bright ("Ruminations on D", D Blog,
  2016-08-30,
  <https://blog.dlang.org/archive/2016/08/30/ruminations-on-d-an-interview-with-walter-bright/>):
  the engine grew out of DMD's constant folder; "Don Clugston took it
  much further, but at its heart it's still a modified dwarf." (No
  standalone Clugston-authored design doc was found; that gap is
  flagged rather than papered over.)
- Stefan Koch's D Blog posts are the sharpest primary description of
  the failure mode ("Project Highlight: The New CTFE Engine",
  2016-11-18,
  <https://blog.dlang.org/archive/2016/11/18/project-highlight-the-new-ctfe-engine/>;
  "The New CTFE Engine", 2017-04-10,
  <https://blog.dlang.org/archive/2017/04/10/the-new-ctfe-engine/>):

  > "It's an AST interpreter, which means that it interprets the AST
  > while traversing it. To represent the result of interpreted
  > expressions, it uses DMD's AST node classes." ... "every expression
  > encountered will allocate one or more AST nodes. Within a tight
  > loop, the interpreter can easily generate over 100_000_000 nodes
  > and eat a few gigabytes of RAM."

  Concrete pathologies cited: issue 12844 (std.regex CTFE >16 GB RAM
  for one pattern) and issue 6498 (a 0..10_000_000 loop exhausting
  memory). Freeing is impractical because "developers don't know which
  nodes to free and enabling the garbage collector makes the whole
  compiler brutally slow." So DMD CTFE's slowness is dominated by
  per-operation heap allocation of `Expression` values plus AST-walk
  dispatch — the exact two things snakebite's native-layout +
  precompiled design eliminates by construction.
- **newCTFE** replaced this with a compile-once bytecode VM: "The
  front end walks the AST and issues calls to the back end. And the
  back end transforms those calls into actual bytecode" targeting a
  "virtual ISA", behind a pluggable codegen API (DConf 2017 abstract,
  <https://dconf.org/2017/talks/koch.html>). The only quantitative
  primary claims are in that abstract: a **10x performance improvement
  demonstrated live with the bytecode interpreter**, and 50x
  *projected* (not measured) for a pseudo-JIT. No reproducible
  benchmark table was ever published; newCTFE was never merged into
  DMD (secondary, unverified against a primary source).

## 5. Tree-walking vs bytecode: the call-path literature

### Crafting Interpreters (Nystrom)

- The one direct jlox-vs-clox number in the book, from the "Calls and
  Functions" chapter
  (<https://craftinginterpreters.com/calls-and-functions.html>),
  benchmarking naive recursive fib(35): "On my machine, running this in
  clox is about five times faster than in jlox." Informal ("on my
  machine"), but it isolates exactly the call-heavy case. Internal clox
  numbers from the "Optimization" chapter
  (<https://craftinginterpreters.com/optimization.html>): hash-table
  load-factor tuning ~2x on a table-heavy microbenchmark; NaN boxing
  "roughly 10% faster across the board" — note the value-representation
  change is worth 10%, while compile-time slot resolution and the
  shared stack (below) are where the 5x lives.

### The four standard fixes, with sources

(a) **Slot resolution at compile time, not name lookup at run time.**
    "Local Variables" chapter
    (<https://craftinginterpreters.com/local-variables.html>): "Since
    the compiler knows exactly which local variables are in scope at
    any point in time, it can effectively simulate the stack during
    compilation and note where in the stack each variable lives";
    access becomes "an indexed array lookup" versus jlox's chain of
    environment HashMaps. "Closures"
    (<https://craftinginterpreters.com/closures.html>) extends this to
    captured variables and states the cost discipline: "It would suck
    to make all of those slower for the benefit of the rare local that
    is captured."

(b) **One contiguous value stack shared by all frames.** clox's
    `CallFrame` holds only a `Value* slots` window into the single VM
    stack ("Calls and Functions" chapter). The production-scale
    confirmation is CPython 3.11: Mark Shannon's proposal
    (<https://github.com/faster-cpython/ideas/issues/31>) — "Allocating
    frames on the heap, 'zombie' frames, and the excessive copying of
    arguments are all slow and unnecessary. ... Most languages use a
    continuous stack for calls because it is much more efficient" — and
    the shipped result
    (<https://docs.python.org/3/whatsnew/3.11.html>): frame objects
    materialized only for debuggers, "We measured a 3-7% speedup in
    pyperformance", plus "Inlined Python function calls" giving "a
    1.7x speedup" on fibonacci/factorial-style recursion. Mono (§1)
    and wazero (§2) implement the same shape.

(c) **Static callee resolution.** clox itself still switches on the
    callee's runtime type in `callValue()`, so it is a weak example;
    mono is the strong one — non-virtual callees resolved at transform
    time into `data_items` (§1). No dedicated literature source found
    for this beyond working systems; flagged as engineering practice
    rather than a paper result. Inline caching (Truffle, below) is the
    dynamic-language approximation of it; snakebite, with a full
    typed frontend, gets it statically for every non-virtual call.

(d) **Arguments written directly into the callee's slots.** "Calls and
    Functions" chapter: "The bottom of the callee's stack overlaps so
    that the parameter slots exactly line up with where the argument
    values already live. ... We don't need to do any work to 'bind an
    argument to a parameter' ... The arguments are already exactly
    where they need to be." Mono's `arg_offsets` and wasm3's arg-slot
    `memmove` are the same idea; CPython 3.11's proposal explicitly
    names "excessive copying of arguments" as a target.

### Truffle/Graal AST specialization — mostly does NOT transfer

Würthinger, Wöß, Stadler et al., "Self-Optimizing AST Interpreters"
(DLS '12,
<http://lafo.ssw.uni-linz.ac.at/papers/2012_DLS_SelfOptimizingASTInterpreters.pdf>
— PDF fetch failed in this research pass; characterization below is
via Oracle's GraalVM docs
(<https://docs.oracle.com/en/graalvm/jdk/17/docs/graalvm-as-a-platform/language-implementation-framework/Optimizing/>)
and secondary explainers, so treat paper-specific numbers as
unverified). Nodes start uninitialized and rewrite themselves into
type-specialized variants — per-node inline caches. The headline
Truffle speedups come from Graal *partially evaluating the specialized
AST into machine code*; no source found isolates a
specialization-only, interpreted-only speedup. For snakebite the
verdict is:

- Speculative type specialization/node rewriting exists to recover
  type information a dynamic language lacks. Snakebite's frontend
  already has exact static types, so the technique's *goal* is met at
  guest-compile time for free; the *mechanism* (self-modifying nodes,
  deoptimization) buys nothing without a JIT and adds complexity.
- The one Truffle-adjacent idea that does transfer JIT-lessly is
  superinstruction-style fusion of common node/opcode sequences —
  which mono implements in a pure interpreter
  (`INTERP_OPT_SUPER_INSTRUCTIONS`, §1).

## 6. Collected numbers

| Number | What it measures | Source |
|---|---|---|
| ~11.8x slower than native | wasm3 (threaded-code interp), CoreMark | wasm3 docs/Performance.md |
| ~17x slower than native | wasm3, fib(40) (call-heavy) | wasm3 docs/Performance.md |
| ~4.3x faster than Lua 5.1 | wasm3 vs switch-loop interp, fib(40) | wasm3 docs/Performance.md |
| 2.5x–4x slower than JIT | wasm3 vs Wasmer/wasmtime, CoreMark | wasm3 docs/Performance.md |
| ~10x+ slower than its JIT | wazero interpreter vs compiler engine | wazero.io/docs |
| 3000x–7000x vs native | Miri (full UB checking) | Miri POPL 2026 paper §6.2 |
| 10x measured, 50x projected | newCTFE bytecode VM vs DMD AST CTFE | DConf 2017 abstract |
| ~5x | clox (bytecode+slots) vs jlox (tree+hashmaps), fib(35) | Crafting Interpreters, "Calls and Functions" |
| 1.7x on recursive calls | CPython 3.11 frame/call inlining | Python 3.11 whatsnew |
| ~10% | clox NaN-boxing value representation | Crafting Interpreters, "Optimization" |

Reading of the spread: a well-engineered non-JIT interpreter lands
roughly 10x–20x off native on compute/call-heavy code (wasm3, and
newCTFE's 10x over an AST-walker points the same way). The 100x–1000x+
territory is occupied by designs that either heap-allocate per
operation (DMD CTFE) or do per-access safety bookkeeping (Miri) —
both avoidable by construction here. 10x–20x off native is far inside
the budget for beating compile+link+run on test workloads, where the
competing baseline pays seconds of compiler/linker time before the
first instruction runs.

## Synthesis: recommended calling convention

Every fast system surveyed — mono, wasm3, wazero, clox, CPython 3.11,
even Miri's own §5.1 rescue optimization — converges on the same frame
shape, and snakebite's constraints (static types, native layout, no
JIT) make it strictly easier to adopt than in any of them:

1. **One contiguous bump-allocated interpreter stack per execution
   context**, allocated once up front (mono: `mono_valloc_aligned` of
   `INTERP_STACK_SIZE`; wazero: `stack []uint64`; clox: `vm.stack`).
   Never heap-allocate per call, per frame, or — the DMD CTFE lesson —
   per computed value. Because snakebite stores native layout, the
   stack is a raw byte arena (not uint64 slots): each function's frame
   is a byte range, and locals are placed at byte offsets with D's
   real sizes and alignments. Guard with a red zone / explicit depth
   check (mono keeps `stack_end` short of `stack_real_end` by
   `INTERP_REDZONE_SIZE`).

2. **Compute every offset at guest-compile time.** Mirror mono's
   `InterpMethod`: for each function, a one-time lowering pass produces
   a per-function descriptor holding the instruction stream (or
   pre-resolved tree), `frame_size` (with alignment padding), and
   per-local/per-parameter byte offsets — mono's `local_offsets` /
   `arg_offsets` / `alloca_size`, but derived from the D frontend's
   actual layout answers. At run time a variable access is
   `frame_base + constant_offset`, never a name or hashtable lookup
   (Nystrom's (a); the single biggest jlox-to-clox win). Cache the
   descriptor per function the way mono caches `transformed`.

3. **Overlap argument slots with the callee's parameter slots.** Lay
   out each call site so argument expressions evaluate directly into
   `[caller_frame_top + param_offset_i]`, i.e. into what becomes the
   callee's frame base — clox's "the arguments are already exactly
   where they need to be", mono's `arg_offsets`, wasm3's arg slots.
   No argument array, no tuple, no per-argument copy step. Since D's
   layout is known, structs passed by value are placed inline at
   their natural offset (one memcpy from the argument's location at
   worst, zero-copy when the argument is constructed in place).

4. **Caller designates the return location before the call.** Give
   each frame a return pointer into the caller's frame — mono's
   `InterpFrame.retval`, Miri's `return_place`, and the pattern
   already documented in `ai/research-native-return-values.md`. The
   callee writes its result (any size, including structs — native
   layout, no boxing) straight to that address; returning is "write
   through retval, pop frame-top pointer". This composes with (3):
   for `f(g(x))`, `g`'s retval pointer is `f`'s argument slot.

5. **Frame metadata stays tiny and separate from data.** An
   `InterpFrame`-equivalent of a few words — parent pointer, function
   descriptor pointer, retval pointer, frame base, saved ip/node —
   either in a parallel array or pooled (mono's `next_free`). Do not
   store types in the frame at run time; type/layout knowledge lives
   entirely in the guest-compile-time descriptor.

6. **Resolve callees at guest-compile time wherever D's semantics
   allow.** Non-virtual calls (the overwhelming majority in
   test/CTFE-style code) should carry a direct pointer to the callee's
   function descriptor in the instruction/node, as mono stores
   resolved `InterpMethod*` in `data_items`. Virtual/interface calls
   fall back to an indexed vtable load (mono does exactly this, with
   no inline cache, and is still the fastest interpreter .NET ships);
   delegates/function pointers dispatch through the descriptor pointer
   they carry. Inline caching is not needed when the frontend already
   resolves overloads and most targets statically.

7. **Do none of the Miri bookkeeping.** No provenance maps, init
   masks, per-access validity/alignment/aliasing checks — Miri's
   3000x–7000x is the price of UB *detection*, which is a different
   product. Snakebite trusts its frontend the way compiled D trusts
   its compiler; a load is a load. (Optional debug-mode checks can be
   a separately lowered instruction stream, mono-tiering style, so
   the fast path never branches on a "checks enabled?" flag.)

What does *not* transfer from the survey:

- **Truffle-style speculative specialization and node rewriting**:
  its payoff is realized by Graal's partial evaluation into machine
  code, and its purpose (recovering types) is moot when the frontend
  supplies exact static types. Skip it.
- **NaN-boxing / tagged value representations**: worth ~10% even in
  clox, and incompatible with the native-layout constraint anyway.
- **wasm3's tail-call threaded dispatch** transfers only partially:
  it is the state of the art for a *linear bytecode* stream in C-like
  languages with guaranteed tail calls, and is what "10-20x off
  native" looks like. It is worth considering if snakebite lowers to
  a flat instruction stream, but it constrains the implementation
  language/compiler (musttail or computed gotos) and is an
  optimization of opcode dispatch, orthogonal to the frame/call
  design above — which is where the survey says the
  order-of-magnitude wins are. Mono's superinstruction fusion of hot
  opcode pairs is a cheaper, portable second step.

The headline conclusion: with items 1–6 (all pure interpreter
techniques, no JIT anywhere in the evidence chain), the surveyed
systems land ~10x–20x off native. Against a baseline that must run a
full compile+link before executing anything, that is a winning
position for the test/build workloads snakebite targets, provided the
per-call path is exactly "bump frame pointer, args already in place,
jump to resolved callee, write result through retval".

## References

- Mono interpreter internals (`InterpFrame`, `InterpMethod`,
  `local_offsets`, stack context):
  <https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/interp-internals.h>
- Mono interpreter main loop / thread stack allocation:
  <https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/interp.c>
- Mono IL-to-MINT transform pass:
  <https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/transform.c>
- Mono interpreter tiering:
  <https://github.com/dotnet/runtime/blob/main/src/mono/mono/mini/interp/tiering.c>
- "Mono's New .NET Interpreter" (mono blog, 2017):
  <https://www.mono-project.com/news/2017/11/13/mono-interpreter/>
- .NET 8 Preview 2 jiterpreter numbers:
  <https://devblogs.microsoft.com/dotnet/asp-net-core-updates-in-dotnet-8-preview-2/>
- wasm3 interpreter design doc:
  <https://github.com/wasm3/wasm3/blob/main/docs/Interpreter.md>
- wasm3 performance data:
  <https://github.com/wasm3/wasm3/blob/main/docs/Performance.md>
- wasm3 slot/exec machinery:
  <https://github.com/wasm3/wasm3/blob/main/source/m3_exec.h>
- wazero interpreter engine:
  <https://github.com/tetratelabs/wazero/blob/main/internal/engine/interpreter/interpreter.go>
- wazero docs (compiler vs interpreter):
  <https://wazero.io/docs/>
- Jung et al., "Miri: Practical Undefined Behavior Detection for
  Rust", POPL 2026:
  <https://research.ralfj.de/papers/2026-popl-miri.pdf>
- Miri README (check-disabling flags):
  <https://github.com/rust-lang/miri/blob/master/README.md>
- rustc `Allocation`:
  <https://github.com/rust-lang/rust/blob/main/compiler/rustc_middle/src/mir/interpret/allocation.rs>
- rustc `Scalar`:
  <https://github.com/rust-lang/rust/blob/main/compiler/rustc_middle/src/mir/interpret/value.rs>
- "Ruminations on D: An Interview with Walter Bright" (D Blog):
  <https://blog.dlang.org/archive/2016/08/30/ruminations-on-d-an-interview-with-walter-bright/>
- "Project Highlight: The New CTFE Engine" (D Blog, Koch):
  <https://blog.dlang.org/archive/2016/11/18/project-highlight-the-new-ctfe-engine/>
- "The New CTFE Engine" (D Blog, Koch):
  <https://blog.dlang.org/archive/2017/04/10/the-new-ctfe-engine/>
- Koch, DConf 2017 talk abstract (10x/50x claims):
  <https://dconf.org/2017/talks/koch.html>
- Crafting Interpreters, "Local Variables":
  <https://craftinginterpreters.com/local-variables.html>
- Crafting Interpreters, "Calls and Functions" (5x number, frame
  overlap):
  <https://craftinginterpreters.com/calls-and-functions.html>
- Crafting Interpreters, "Closures":
  <https://craftinginterpreters.com/closures.html>
- Crafting Interpreters, "Optimization":
  <https://craftinginterpreters.com/optimization.html>
- Mark Shannon, CPython frame/call redesign proposal:
  <https://github.com/faster-cpython/ideas/issues/31>
- Python 3.11 "What's New" (frame + call inlining numbers):
  <https://docs.python.org/3/whatsnew/3.11.html>
- Würthinger, Wöß, Stadler et al., "Self-Optimizing AST
  Interpreters", DLS '12:
  <http://lafo.ssw.uni-linz.ac.at/papers/2012_DLS_SelfOptimizingASTInterpreters.pdf>
- GraalVM Truffle "Optimizing Truffle Interpreters" docs:
  <https://docs.oracle.com/en/graalvm/jdk/17/docs/graalvm-as-a-platform/language-implementation-framework/Optimizing/>
