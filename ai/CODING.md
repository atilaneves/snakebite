# Code Style

## General

* All code is a liability and must justify its existence. Code that
  doesn't exist to make a test pass should probably be deleted.
* One True Brace Style. For functions with many attributes, `{` on its
  own line is acceptable.
* Use UFCS liberally.
* Always re-read files before editing; another agent or person may have
  changed them in the meantime.
* Trailing commas.
* Maximise attributes: `@safe @nogc nothrow pure const scope`. Do not
  abuse `@trusted` to make functions `@safe`.
* Private functions below their first use, as close as possible.
* Prefer `std.conv.text`; use `text(x)` not `x.to!string`.
* Make parameters `in` if possible.
* Prefer `const`; use `auto` with a comment if `const` fails; explicit
  LHS type only if `auto` fails (comment why). Explicit types are fine
  for uninitialised declarations.
* No `synchronized`.
* Prefer RAII for a resource that an object owns: the destructor of the
  owner releases it and the use site has `scope`. A release call under
  `scope(exit)` is a sign to check if the owner needs a destructor.
  `scope(exit)` is allowed where a new type is not worth it, such as a C
  API, and for locks: `mutex.lock; scope(exit) mutex.unlock;`.
* Omit empty parens: `doStuff;` not `doStuff();`.
* Variables as close to their usage as possible.
* Use `with` in `switch`/`final switch` with enums for more readability.
* private variables start with an underscore, e.g. `_member`.
* D has modules and types within types, do not use C-like naming
  conventions like `Foo` and `FooEnum`, instead place enums inside the
  corresponding class/struct so that one uses `Foo.Enum` instead.
* Do not use "magic literals" like `foo(true, 0, 42, "bar")`. It's
  impossible to know what those values are from the calling context.
  Either name them with a variable or add a comment.
* Do not use `__gshared` unless absolutely necessary. Shared code
  should be `immutable` if it can be, `shared` otherwise. All global
  and TLS data is suspect and must have its existence justified. Mutable
  global state includes the state of the process: the working directory
  (`chdir`) and the environment.
* Downcasts are a code smell - use virtual dispatch instead unless
  justified.
* Our helpers return D types. A helper returns `string`, not
  `const(char)*`. Convert one time inside the helper, never at each call
  site.
* Do not `idup` a `string`. It is immutable already.
* Use `new` for a GC object, not `GC.calloc` and a cast. If `new` cannot
  work, say why in a comment.
* A parameter list or an argument list that fits on one line stays on one
  line. One that is split over several lines has one parameter or argument
  per line. Then a later removal or addition changes one line only: "The
  diff is bigger than it should have been because `"snakebite"` wasn't on
  its own line." Existing code that breaks this rule is not a model to
  copy.
* Do not split a ternary expression over lines inside another expression,
  such as a call argument: "don't break up ternary expressions like this,
  it's ugly." Give it a name on its own line.
* When a function needs its own mutable copy of a parameter, take the
  parameter by value. Do not make a copy in the body to work around the
  type of the parameter: "What's with the explicit type declaration on the
  lhs?"
* Use Phobos before a hand-written equivalent, for example `std.conv.to`
  for an enum from a string.
* A struct with a flag that says if its other fields mean anything is an
  optional value: use `Nullable` or a pointer, not a flag.
  This does not apply to a `string`: "A `string` is already nullable: the
  empty string." Do not use `Nullable!string`; the empty string says
  "none".
* Do not take a value apart to pass its fields to a function that can take
  the value.
* Do not add a `static assert` that repeats the field names of a struct to
  guard a hand-written walk over its fields. Write the walk with
  compile-time reflection, so that it needs no list.
* Prefer a template parameter for a callback, so that the function's
  attributes are deduced from it.

## Names and comments

* Use the terms of `CONTEXT.md` in names and comments. A word that is not
  in `CONTEXT.md`, and is not a D or dmd term, gets a definition at its
  first use.
* A comment is a sentence that a reader who has not seen the PR can
  understand. When a change makes part of a comment false, rewrite the
  whole comment.
* A name says what the thing is: "`file` is not a string, `fileName` is."
  A function that returns the name or path of a file is not named as if it
  returned a file.

## Production code (in `source`)

- Use `imported!"module"` for parameter and return types at
  module-scope.  Do not use `imported!"module"` in non-module scopes
  such as inside a function, struct, or class.
- `private:` at top of every module; still annotate each declaration
  explicitly with `public`/`private`.
- Do not use exceptions for control flow.

## Test modules (in `tests`)

- Use module-scope imports to avoid repeating the same import in every
  test block. Unit test modules should not use `imported`.
- Use package modules liberally to avoid imports in test modules - see
  `import ut;` for a good example.

# Code organisation

* Backends must not import each other: nothing in one backend's package
  may import another backend's package, and vice versa. Within a single
  backend package, modules can and should import each other, including
  package-private code.
* Only the package `snakebite.frontend` may import dmd modules. Other
  code takes dmd node types, enums and the functions that are on the list of
  `snakebite.frontend.ast`. Call a dmd function that is not on the list
  through `inFrontend`, which takes the frontend lock. The "not reviewed"
  block of that module still lets outside code call about 50 dmd functions
  and read the globals `global`, `target`, `diagnostics` and `Id` with no
  lock: do not add to it, and do not rely on it being safe. The build fails
  on a dmd import outside the package. It does not see a string-mixin import
  or an alias of `imported` (ADR 0015).
* In the bytecode backend, only `snakebite.backends.bytecode.compiler` may
  import frontend modules. The bytecode VM and all project modules that it
  imports must compile without DMD frontend import paths.
* Code goes in the module that owns its concept.
* A PR holds only what its requirement needs. A new option, environment
  variable, field or file that the requirement does not name is a question
  for the owner before it is code.

# Decision records

- A decision record (`docs/adr/`) states what was decided and why, at a
  high level. It has no names of functions, types, fields or files of the
  code, and no description of how the code does a thing.

# Runtime semantics

druntime is not be emulated or reimplemented. It is either interpreted,
compiled, or called via FFI.

# Shared layer

All runtime AST visitors, including those for new backends, must inherit
`LoweringVisitor`. Its final overrides own lowering dispatch.

Any exception to executing a lowering belongs in `LoweringVisitor` and
applies to all backends. Its compile-time check requires a final shared
policy for each frontend expression type with a `lowering` field.

The shared layer owns every backend-independent decision: what dmd
lowers (a `lowering` field) and what dmd decides instead in its own
glue layer (`e2ir.d`: casts, truth, invariants, closure frames, unwind
order, and so on). Put the decision in one shared module (for example
`language/operators/casts.d`, `language/storage/lifetime.d`,
`language/call/druntimehook.d`); each backend only
executes that plan. A second backend that reimplements the same
decision is a bug, not a parallel feature.

All backends use native layout in memory as normal compiled D would.
For instance, a dynamic array is `struct { size_t length; T* ptr; }`:
length at offset 0, pointer at offset 8 (on 64-bit).
This means there is no need to marshall or unmarshall when doing FFI.

# Do nots

- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.
- Do not mention quickbite implementation details in comments attached
  to tests.
- Do not "intercept" D code by name to shortcut implementation.
- Do not make an object only to give a function an argument. If code
  needs a dummy of a type, the function asks for more than it uses:
  change what the function takes. A parameter that only some
  implementations of one interface use is allowed.
- Never delete test code to make tests pass.
- Do not comment code explaining *what* it does. If it's not clear what
  the code does, rewrite it, don't comment.
- Do not add a rejection site: a run-time throw for a construct the
  backend has not implemented. A construct that compiled D accepts
  must be implemented, not refused at run time. A user-facing error
  for genuinely invalid input (for example, bad CLI arguments) is not
  a rejection site.
- Do not add `unsupported` (or similarly named) to a plan enum. Every
  member must be a real outcome, or a `final switch` over it proves
  nothing.
- Report host internal failures with
  `snakebite.failure.report.internalFailure(message)`. It prints the
  message and the call site's source location, then ends the process with
  a normal failure status. It works in `pure`, `nothrow`, and `@nogc` code,
  including release builds with assertions disabled.
- Use this shared function in catch-all visits. Include the node kind in
  the message. A terminal report does not prove that a node is unreachable
  and does not permit a new refusal of valid guest code.
- Keep `static assert` for compile-time checks. Guest assertions and the
  trapping instruction for a guest halt keep their guest semantics.
- Do not use ` __traits(getMember)` to read private members. All tests
  must go through the public API.

A new rejection site, `unsupported` member, throwing catch-all, or
per-backend copy of a decision that belongs in the shared layer is a
review must-fix.

# Do

- Explain why a unittest block is testing an AST shape by referring to
  language semantics. If necessary, you are allowed to refer to dmd
  internal implementation details.
- Code comments are for *why*.
- Dispatch on a closed set with `final switch` over the full enum,
  after `baseType` (`toBasetype` in the frontend package). A missing
  case then fails the build instead of hiding behind a `default`.
- Call `baseType` before any `.ty` test, not only before a
  `switch`. A `.ty ==` check in an `if` on an un-normalised type
  misses enums and typedef-like base types.
- Fix the full concept: cover every case the same reasoning applies
  to, not only the case that made a project fail.

# Tests
- Use `shouldThrowWithMessage`, not `shouldThrow`.
- Use `.should ==`, not `.shouldEqual`.
- Use `"...".should.be in foo`, not `.canFind("...").should == true`.
- State an expectation with the assertion library of the test framework
  (unit-threaded), on the values themselves: `x.should == y`,
  `x.should.be in y`, `shouldThrowWithMessage`. Do not use plain `assert`,
  and do not hand-write a check and wrap it in `.should == true`. Write
  `name[0 .. expected.length].should == expected;`, not
  `(name[0 .. expected.length] == expected).should == true;`, and
  `"only one entry point `main` is allowed".should.be in thrown.msg;`, not
  `assert(thrown.msg.canFind("..."))`.
- A test does not import types of the dmd frontend and does not call an
  internal helper. It states a behaviour through what the tests of that
  area already use to compile and run a guest program. If a behaviour
  cannot be reached that way, the test is at the wrong level.
- The `ut` binary should be the first safety net; its dual mandate is
  to be fast and catch *most* things. It can't catch everything, and
  that's what the other tests are for.
- Tests must have positive ROI. Tests are not free, even merely
  existing has a cost, as well as the actual cost of running them.
