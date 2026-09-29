# Issue #437 verification

`RuntimeTypes.build` returns metadata for class, struct, and enum types
before its exhaustive scalar-type switch. The switch has no null-return
path. The interpreter and bytecode callers use `get` directly; their
remaining null checks guard absent frontend type metadata.

Guest struct metadata now calls the DMD-selected hash, equality,
comparison, string, destructor, and enabled postblit functions through
the backend's callable-address path. It also records native pointer
metadata and ABI argument types. Class metadata records native flags,
depth, name signature, pointer metadata, default constructor, destructor,
and class invariant. These are real callable addresses for guest methods.

Semantic3 sets `AggregateDeclaration.getRTInfo` to DMD's generated
`RTInfoImpl` bitmap for pointer-bearing aggregates. `RuntimeTypes`
mangles that symbol and resolves its real host address. The current DMD
frontend has no guest-source override for this field. Tests compare every
bitmap word with
`__traits(getPointerBitmap, T)` for a nested struct with a static array
of pointer-bearing fields and for a class with a pointer field. When
DMD leaves `getRTInfo` null, metadata uses its pointer-field result to
select the same null or conservative pointer sentinel as DMD's object
writer. The resolver also handles address, integer, and null expression
forms.

The behavior tests cover struct metadata values, custom operations,
nested generated lifetime hooks, disabled postblit, class creation,
abstract classes, and disabled constructors. They run on Native,
Bytecode, and Interpreter. CTFE is omitted where the test reads runtime
TypeInfo. No runtime backend is omitted.

Focused validation passed:

- `ninja bin/ut`
- 27 new struct and class metadata cases across the three runtime
  backends
- 12 existing TypeInfo data, enum, name, and class finalizer cases
- `git diff --check`
