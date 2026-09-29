# Issue #437 verification

Recommendation: close issue #437. PR #448 completes the requested change,
and the current code and tests cover the reported defect.

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

The focused run passed all 9 backend cases. No production or test defect was
found, so no test change was needed.
