# Structural runtime node coverage

This is the first structural slice of #543. It does not complete #433.
The 57 entries in `UnreachableNodes` retain their old status. Their reason
strings are pending audit notes, not reviewed absence proofs. No entry was
added, and no guest refusal was added.

## Gate and scope

`AssertEveryNodeHandled` checks an exact parameter type. A backend's own
method counts. A final method declared by `LoweringVisitor` also counts.
A method inherited from another backend parent, `Visitor`, or
`ParseTimeVisitor` does not count. The root expression and statement
catch-alls never count. Both constructed evaluator types share the
`RuntimeEvaluators` list with their coverage checks. `FunctionCompiler`
has its own check. These checks stay in module function bodies. The normal
module build compiles the member bodies and construction paths for both
modes; matching overload lists alone are not a behavioral proof.

The compiled universe has 164 runtime-family classes, including four
abstract classes. It checks the exports of `dmd.expression` and
`dmd.statement` against all runtime-family `Visitor` parameter types.
The 163 visitor types omit `CTFEExp`: that class has no own `accept` and
inherits `Expression.accept`. It stays visible in the pending audit.
The distinct nested parse-only classes of `ASTBase` are excluded.

`docs/agents/node-source-inventory.json` records the separate
whole-source lexical scan used to establish these two export modules.
That scan examined every pinned frontend `.d` file. It is a bounded
lexical inventory, not a D parser: aliases, mixins, conditional declarations
and alternate syntax need separate review. The compiled inventory is an
independent cross-check. Neither scan establishes semantic reachability.

`frontend-source-hashes.txt` pins the names and SHA-256 hashes of all 271
frontend D files, including files that have no runtime-family class.
`build/check_nodecoverage.py` checks the whole source tree on each Ninja build.
A new module, deleted file, changed field or flag, or changed semantic code
fails with `stale frontend fingerprint`. This is stronger freshness
checking than a class count or field schema alone. It is not evidence that
current fields, flags or type families have correct execution policies.

The check is a mandatory prerequisite of the registry image object, which
every configured executable links. Thus an incremental build also runs it.
This adds a small assembly rebuild and link to an otherwise clean build.
`build/ci.sh` and the GitHub job named “Dub Test” use this Ninja path. Direct
`dub build` and `dub test` are already unsupported: they do not build the
required assembly objects (see `dub.sdl`). An ad hoc D compile can run the
structural templates but does not run the whole-source fingerprint gate.

## Explicit forwarding argument

`ForwardedNodes` permits only named edges. The destination must have an
exact visit in the checked backend, unless that backend has its own exact
leaf visit. Duplicate records and self cycles fail the build. Every edge
must go to a strict ancestor, so a multi-node cycle is also impossible.
The build checks each recorded pair against the actual pinned frontend
visitor body. An arbitrary ancestor is not an allowed substitute.

The dispatch equivalence argument is bounded: D's class upcast preserves
the object, its fields, dynamic type and operation tag. The retained
frontend forwarding method does exactly that upcast and calls the named
visit. The coverage gate requires that exact destination method. It does
not add, replace or copy the dispatch implementation. The edges below
therefore retain the existing runtime path. This is a structural theorem;
its field conditions below still need the full semantic and producer audit.

All frontend anchors below refer to DMD v2.113.0 in
`compiler/src/dmd/` on `github.com/dlang/dmd`.

- `SuperExp -> ThisExp`: `visitor/parsetime.d:210`; declaration at
  `expression.d:866`. The leaf adds no stored field. Receiver evaluation
  retains the `var`, result type and `EXP.super_` tag. DMD `glue/e2ir.d:4185`
  routes the receiver value to `visitThis`; its separate method-dispatch
  logic reads the original tag at line 3489. Both backend receiver adapters
  read the hidden receiver slot. General receiver, static method-dispatch
  and context correctness remain separate semantic audit obligations.
- `DtorExpStatement -> ExpStatement`: `visitor/package.d:35`;
  declaration at `statement.d:414`. DMD `glue/s2ir.d:705` routes execution
  to `visitExp`. Its `var` describes which variable is destroyed; forwarding
  retains that field and the already constructed destructor expression.
  The final shared expression-statement adapter owns full-expression
  execution. Producer and cleanup-path proofs for `var` remain pending.
- `CompoundDeclarationStatement -> CompoundStatement`:
  `visitor/parsetime.d:133`; declaration at `statement.d:557`. The leaf
  adds no field. Forwarding retains the ordered statement array and
  statement kind. The exact compound adapter executes the same array.
  Declaration expansion and preparation-role coverage remain pending.
- `CompoundAsmStatement -> CompoundStatement`:
  `visitor/parsetime.d:134`; declaration at `statement.d:1848`;
  DMD `glue/s2ir.d:730`. Forwarding retains its statement array and `stc`.
  Root inline asm is already excluded by ADR-0012 and
  `frontend/inlineasm.d`; this record adds no exclusion or load check.
  It does not prove the full root/dependency asm producer and entry paths.
- The eleven integral/floating/complex compound-assignment leaves
  `Add`, `Min`, `Mul`, `Div`, `Mod`, `And`, `Or`, `Xor`, `Shl`, `Shr` and
  `Ushr` forward to `BinAssignExp` in `visitor/parsetime.d:263-274`.
  The frontend cast retains `op`, both operands and their types. Bytecode's
  exact parent adapter passes that same object to `compileCompoundAssign`,
  which uses the shared arithmetic and shift plans. Interpreter's exact
  leaf adapters still execute directly. Existing matrix arithmetic tests
  cover these operators, but do not discharge all field/type obligations.
  `PowAssignExp` is deliberately absent from this forwarding registry:
  its old pre-runtime entry requires its own frontend rewrite proof.
  `CatAssignExp` and its leaves use final shared lowering policies.

These arguments establish why these records preserve current dispatch.
They do not establish that every frontend producer obeys every required
condition, or that an existing backend target has complete D semantics.
A source citation and a passing fixture are not substitutes for those
remaining proofs.

## Verification and frontend update procedure

Run `python3 build/check_nodecoverage.py --controls` for the positive compile
and named negative controls. It checks a missing exact leaf, a missing checked
mode adapter, a wrong ancestor target, a cycle, duplicate records, a missing
exact forwarding destination, both universe mismatch directions, and a
class in an added module. It also checks source freshness failure for a
changed file, a new schema member and a new module. The controls use the
production templates and verifier. Negative compiles must fail with the
named node-coverage diagnostic; an unrelated import failure does not pass.
The fixtures are in `tests/nodecoverage/` and are excluded from the normal
unit test build. CI runs these controls after the build. Existing guest
fixtures, followed
by full `bin/ut`, check retained runtime behavior. No new behavior test or
`Omit` was needed for a structural change.

Do not refresh the fingerprint just to permit a frontend update. First
repeat the whole-source runtime-family scan, inspect aliases, mixins and
conditional declarations, compare the compiled universe, inspect every
changed field/flag and producer/escape path, and review each changed
forwarding edge. Then update the source inventory and all source hashes in
one reviewed change. The pending semantic audit must record the new input
version and retain any unresolved rows.

## Remaining obligations

The complete gate still needs reviewed producer and escape-path absence
proofs for all 57 old pre-runtime entries. Executable nodes still need
field, flag, operand/result type and lifetime proofs. Auxiliary collectors
and preparation visitors need their own role contracts. The barrier,
terminal assertion audit (#629), duplicated policy audit (#630), and the
final real-project round remain separate obligations. #614 root compiler
context is deferred. Passing these structural checks or the unit suite
cannot close #433 or the complete node-coverage scope of #543.
