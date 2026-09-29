# Issue #437 verification

Recommendation: keep issue #437 open. The first verification checked too
few behaviors. Dispatch is exhaustive, but guest struct TypeInfo does not
match native D for five tested operations.

The issue asks `RuntimeTypes.build` to return compiled-D-compatible type
information for every type kind, including structs, classes, and enums. It
also asks callers to stop handling a null result.

`source/snakebite/backends/runtimetypes.d` now selects class, struct, and enum
metadata before its exhaustive `final switch` over scalar `TY` values. The
switch asserts for kinds handled by the preceding branches and for frontend
types that semantic analysis rejects. `build` has no null return path. The
interpreter and bytecode callers use `get` directly; their remaining null
checks guard absent frontend type metadata before calling `get`.

The existing backend tests exercise the synthesized data:

- `runtimeTypeInfoBuildsDataMetadata` checks struct and enum initial bytes,
  pointer TypeInfo identity, and const/shared wrapper relationships.
- `runtimeTypeInfoEnumBaseOfEveryType` checks enum base TypeInfo for every
  accepted base kind covered by the test.
- `runtimeTypeInfoNamesGuestAggregates` checks that guest struct, class, and
  enum TypeInfo names are present.

These tests run on Native, Bytecode, and Interpreter. CTFE is omitted because
it cannot inspect runtime TypeInfo. No Interpreter or Bytecode omission exists.

Validation passed:

- `ninja bin/ut`
- `bin/ut ut.backends.run.structs.runtimeTypeInfoBuildsDataMetadata
  ut.backends.run.structs.runtimeTypeInfoEnumBaseOfEveryType
  ut.backends.run.structs.runtimeTypeInfoNamesGuestAggregates`

The initial focused run passed all 9 backend cases. This establishes only
the selected metadata fields, not full native behavior.

## Follow-up: struct operations

Five new behavior tests call the public TypeInfo operations. They use
custom struct methods whose results differ from the default byte-based
operations, and counters for lifetime operations.

| Operation | Native | Interpreter | Bytecode |
| --- | --- | --- | --- |
| `getHash` with custom `toHash` | Pass | Fail | Fail |
| `equals` with custom `opEquals` | Pass | Fail | Fail |
| `compare` with custom `opCmp` | Pass | Fail | Fail |
| `destroy` with a destructor | Pass | Fail | Fail |
| `postblit` with a postblit method | Pass | Fail | Fail |

Each test was first attempted on all four backends. CTFE failed because it
cannot read runtime TypeInfo; only that verified limitation is omitted.
No Interpreter or Bytecode omission was added.

Reproduce from this worktree:

```sh
ninja bin/ut
bin/ut ut.backends.run.structs.runtimeTypeInfoCallsStruct
```

The build passes. The final test run has 15 cases: five Native passes and
ten runtime backend failures. The earlier run gave the same failures.
The tests remain failing proof cases on this local verification branch.
There is no production fix in this branch.

## Cause and remaining work

Both backends obtain this metadata through `RuntimeTypes.get`. For a
root-owned struct, `build` bypasses linked host metadata and calls
`structInfo`. That function creates `TypeInfo_Struct` and sets layout,
initializer, pointer flags, and ABI argument information. It does not set
`xtoHash`, `xopEquals`, `xopCmp`, `xdtor`, or `xpostblit`.

Druntime's TypeInfo methods use those hooks. Without them, hash, equality,
and comparison use default data operations; destroy and postblit do
nothing. This matches the five observed failures. The construction path
does not install callback addresses, so callback execution is not reached.

The fix must fill the shared metadata with callable entries for the
frontend-selected struct functions, using the existing callback mechanism
for guest functions. Preserve native layout and call the real druntime
methods; do not implement replacements for them. Cover generated hooks
for nested fields and disabled operations as well as explicit methods.

Other TypeInfo fields and class behavior still need review before closure.
In particular, a nonempty class name is not proof of complete metadata.
