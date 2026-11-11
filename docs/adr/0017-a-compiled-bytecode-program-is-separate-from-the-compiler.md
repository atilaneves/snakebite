---
status: accepted
---

# A compiled bytecode program is separate from the compiler

The bytecode backend has three parts. Each part has one job:

- The compiler, `Bytecode` in `backends/bytecode/compiler.d`. It reads the
  frontend and fills the compiled program on demand. It is the only part
  that imports the frontend.
- The compiled program, `Program` and `Module` in
  `backends/bytecode/program.d`. It holds the compiled code and data. It
  imports no frontend module.
- The machinery that executes, `Runner` in `backends/bytecode/runner.d`,
  with the VM in `vm.d`. It runs the compiled functions. It imports no
  frontend module.

The reason for the separation is two uses of the same compiled program. In
the owner's words: "Compile bytecode -> execute compiled bytecode from RAM,
possibly JITing. Load previously compiled bytecode -> execute bytecode that
is now in RAM, possibly JITing." The two uses differ in how the bytecode got
into RAM. They must not differ in what executes it. The backend is the
compiled program plus a compiler that fills it on demand.

No save or load of a compiled program exists yet. This record describes the
split that makes both possible.

## Decision

### The check

The first step of `build/ci.sh` compiles `vm.d`, `runner.d` and `program.d`
with `dmd -o- -i -Isource` and no frontend import path. A frontend import in
any of them, or in what they import, fails that step.

### A Module owns what its D module defines

A `Program` holds a list of `Module`s. A `Module` is the compiled code and
data that one D module defines. It owns:

- its compiled functions (`_functions`),
- its static data blocks (`blocks`): the variables of the D module and their
  initial bytes, the constants that its functions refer to, and the initial
  bytes of its fields,
- its start record (`start`, a `ModuleStart`): the name, the imports, and
  the constructors, destructors and unit tests as function handles.

The rule: a `Module` owns what its D module defines. A note or an index of
things that live elsewhere is not permitted in a `Module`. The owner of a
template instance is the module that declares the template. This fits the
present model, where a whole dub package is compiled at once. A later
`.sbc` file is a list of modules.

The compiler makes a `Module` at the first function or datum of its D
module, and `buildStartData` makes the `Module` of each root module, so that
every root module has one. `StartData.modules` is a list of pointers to the
`ModuleStart` records, and the `Module` holds each record by value. The
interpreter and the ctfe backend have no `Module`; they give a record on
the heap to `buildStartData`.

A `Module` is a heap block that the `Program` keeps. Its address does not
change: instructions point into its blocks, call sites point to its
functions, and `StartData.modules` points to its record.

### What stays in the Program

Some data have no one D module as owner. They are shared by the whole
process, and `Program` holds them:

- String literals are shared by text. Two literals with equal text have one
  copy, whichever D module they are in.
- The `.init` image of a type is shared by type.
- A struct literal and a class object are shared by the source node that
  makes them, so that aliases and cycles of compile-time values stay the
  same value.
- The thread-local variables have one table of slots (`TlsSlots`) for each
  thread. A slot is for a variable, and a thread has one table, not one per
  D module.
- The signatures (`SignatureTable`) are interned by layout. A `Signature*`
  is only meaningful with others of the same `Program`.
- The call plans, their symbol resolver and the callback bridge are in
  `CallPlanStore`.
- The start data (`StartData`): the program name, `main`, the
  `crt_constructor` and `crt_destructor` functions, and the list of module
  records.

The storage of the shared data is `StaticStore` in `Program.store`. The
tables that find it (by text, by type, by source node) are in the
compiler's `NativeData`, which keys them with frontend types.

### What is not yet in a Module

These are not yet owned by the `Module` of the D module that defines them:

- The TLS descriptor records. `NativeData` holds them in a table keyed by
  the variable declaration (`_tlsDescriptors`,
  `language/statics/data.d:70`). An instruction holds a pointer to one.
  The initial bytes that a descriptor points to are in the blocks of the
  `Module`, but the descriptor is not.
- The type data: the `TypeInfo_Class` of a guest class, and the class
  runtime data around it. The compiler holds them (`_runtimeTypes` at
  `backends/bytecode/compiler.d:107`, `_classRuntime` at
  `backends/bytecode/compiler.d:113`). The class info is a GC object
  (`language/statics/classinfo.d:137`).
- The constants on the GC heap. A class object constant is a GC block
  (`language/statics/data.d:123`). The data of an array literal is a GC
  block (`language/statics/data.d:773`), and so are the keys and values of
  an associative array literal (`language/statics/data.d:887` and `:889`).

A constant with a place in the blocks of a `Module` is only one that goes
through `NativeData.value` with an owner.

## Consequences

- The code that executes does not depend on the compiler. A test or a tool
  can build the machinery that executes with no frontend.
- A `Program` that came from a file needs only the parts of the list above
  to be in the file. The parts that are not yet in a `Module` must move
  there, or have a stable form, before a `.sbc` file can hold a module.
- The start record of a D module is in its `Module`, so a loaded module
  carries its constructors, destructors and unit tests with it.
- No cost is added to an instruction or a call. Reading the module records
  at start takes one more pointer step for each module.
