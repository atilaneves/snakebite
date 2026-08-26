## Code Style

### General

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

### Production code (in `source`)

- Use `imported!"module"` for parameter and return types at
  module-scope.  Do not use `imported!"module"` in non-module scopes
  such as inside a function, struct, or class.
- `private:` at top of every module; still annotate each declaration
  explicitly with `public`/`private`.
- Do not use exceptions for control flow.

### Test modules (in `tests`)

- Use module-scope imports to avoid repeating the same import in every
  test block. Unit test modules should not use `imported`.
- Use package modules liberally to avoid imports in test modules - see
  `import ut;` for a good example.

## Code organisation

* Backends must not import each other: nothing in one backend's package
  may import another backend's package, and vice versa. Within a single
  backend package, modules can and should import each other, including
  package-private code.

## Runtime semantics

druntime is not be emulated or reimplemented. It is either interpreted,
compiled, or called via FFI.

All backends use native layout in memory as normal compiled D would.
For instance, dynamic arrays are equivalent to (ptr, length) pairs.
This means there is no need to marshall or unmarshall when doing FFI.

# Do nots

- No classes unless the goal is OOP (virtual dispatch, inheritance). A
  class with no base, no children, and no virtual methods is a struct.
- Do not mention quickbite implementation details in comments attached
  to tests.
- Do not "intercept" D code by name to shortcut implementation.
- Never delete test code to make tests pass.

# Do

- Explain why a unittest block is testing an AST shape by referring to
  language semantics. If necessary, you are allowed to refer to dmd
  internal implementation details.
