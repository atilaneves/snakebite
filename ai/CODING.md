# Code Style

## General

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
* Only `snakebite.backends.bytecode.compiler` may import DMD frontend
  modules. The bytecode VM and all project modules that it imports must
  compile without DMD frontend import paths.

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
`casts.d`, `aggregateinit.d`, `druntimehooks.d`); each backend only
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
  `snakebite.internalfailure.internalFailure(message)`. It prints the
  message and the call site's source location, then ends the process with
  a normal failure status. It works in `pure`, `nothrow`, and `@nogc` code,
  including release builds with assertions disabled.
- Use this shared function in catch-all visits. Include the node kind in
  the message. A terminal report does not prove that a node is unreachable
  and does not permit a new refusal of valid guest code.
- Keep `static assert` for compile-time checks. Guest assertions and the
  trapping instruction for a guest halt keep their guest semantics.

A new rejection site, `unsupported` member, throwing catch-all, or
per-backend copy of a decision that belongs in the shared layer is a
review must-fix.

# Do

- Explain why a unittest block is testing an AST shape by referring to
  language semantics. If necessary, you are allowed to refer to dmd
  internal implementation details.
- Code comments are for *why*.
- Dispatch on a closed set with `final switch` over the full enum,
  after `toBasetype`. A missing case then fails the build instead of
  hiding behind a `default`.
- Call `toBasetype` before any `.ty` test, not only before a
  `switch`. A `.ty ==` check in an `if` on an un-normalised type
  misses enums and typedef-like base types.
- Fix the full concept: cover every case the same reasoning applies
  to, not only the case that made a project fail.

# Tests
- Use `shouldThrowWithMessage`, not `shouldThrow`.
- Use `.should ==`, not `.shouldEqual`.
- Use `"...".should.be in foo`, not `.canFind("...").should == true`.
- The `ut` binary should be the first safety net; its dual mandate is
  to be fast and catch *most* things. It can't catch everything, and
  that's what the other tests are for.
