module ut.backends.concurrency;


import ut;
import snakebite.backends.backend: Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


// Regression test for a race between `snakebite.backends.runtimetypes.
// RuntimeTypes.get`'s narrowed lock and `NativeData.classValue`'s full one,
// both of which can reach `RuntimeTypes.linkedClassInfo` ->
// `RuntimeTypes.linkedInfo` -> `dmd.mangle.mangleToBuffer` for the very
// same host-linked class declaration (`object.Exception`) at once.
//
// `linkedClassInfo` returns `null` (skipping `mangleToBuffer` outright) for
// any root-owned, guest-declared class (`RuntimeTypes.isRootOwned`), so
// only a class the host itself links - `Exception`, here - ever reaches
// `mangleToBuffer`. `mangleToBuffer` walks dmd's own AST (a
// `ClassDeclaration`'s bases, identifiers, parent module) the same way any
// other frontend call does, so it is dmd-touching work like any other and
// needs the frontend lock - but neither `linkedInfo` nor its caller
// `classinfo.classRuntimeInfo` (guarded only by `ClassRuntimeCache`'s own
// per-instance lock, deliberately not the frontend one - its own doc says
// `make` never itself needs the frontend lock, an assumption that held
// only while `linkedClassInfo` was unreachable without it) take it.
//
// `NativeData.classValue` still wraps its whole body, `linkedClassInfo`
// included, in the frontend lock - a compile-time class literal
// (`static immutable failure = new Exception(...)`) reaches
// `mangleToBuffer` safely. `RuntimeTypes.get` no longer does (this
// branch's own narrowing): a `catch (Exception e)` clause's runtime type
// check reaches the very same `mangleToBuffer(Exception's
// ClassDeclaration, ...)` with no lock at all. Two threads hitting these
// two paths for `Exception` at once - one holding the frontend lock via
// `classValue`, the other not, via `RuntimeTypes.get` - can both be
// inside `Mangler::visit` at once, corrupting dmd's own AST/backref state
// for each other (observed as `cd.parent.ident` reading a null `parent`
// in an unrelated thread's `Mangler`, and crashing the whole process).
//
// A fresh `Bytecode`/`Interpreter` instance per thread, like this file's
// sibling `bytecode`/`interpreter` `concurrency.d` tests, keeps every
// thread's own `RuntimeTypes`/`ClassRuntimeCache` a genuine miss for
// `Exception`: dmd resolves `object.Exception` itself once, process-wide,
// but each backend instance still walks `classRuntimeInfo` ->
// `linkedClassInfo` -> `mangleToBuffer` again the first time it, itself,
// needs `Exception`'s linked `TypeInfo_Class` - so this race is live on
// every round, not only the process's first one.
private enum functionCount = 16;
private enum threadCount = 8;
private enum rounds = 6;

// Every function throws a compile-time class literal (`static immutable`,
// dmd's own CTFE folds `new Exception(...)` before any backend thread
// touches it - `NativeData.classValue`'s route, always under the full
// frontend lock), never a runtime `new`: `Evaluator.constructAggregate`'s
// own routing decision (`snakebite.backends.calls.CallSelection.
// buildDecision` -> `outerFunctionOf` -> `Dsymbol.toParent2`) is a
// separate, pre-existing race of its own (reproduces the same way on
// `origin/master`, unrelated to this branch's lock narrowing) that this
// test must not also trip over while isolating the one this branch's
// `RuntimeTypes.get` narrowing introduced.
private enum guestSource = (){
    string source =
        "module ut.backends.concurrency_guest;\n";
    foreach (i; 0 .. functionCount)
        source ~= text(
            "long f", i, "() { ",
            "static immutable failure", i,
            " = new Exception(\"boom", i, "\"); ",
            "try { throw failure", i, "; } ",
            "catch (Exception e) { return e.msg.length + ", i, "; } }\n",
        );
    return source;
}();

// `"boom<i>".length + i`.
private long expectedResult(in size_t index) {
    return text("boom", index).length + index;
}

@("classInfo.concurrentExceptionTypeInfoBuildsAgree")
unittest {
    import core.atomic: atomicLoad, atomicOp, atomicStore;
    import core.thread: Thread;

    auto guestModule = parseSnippet(guestSource);
    auto program = Program([guestModule]);

    foreach (round; 0 .. rounds) {
        shared size_t ready = 0;
        shared bool go = false;
        Throwable[threadCount] failures;

        auto threads = new Thread[threadCount];
        foreach (t; 0 .. threadCount) {
            const threadIndex = t;
            threads[t] = new Thread({
                atomicOp!"+="(ready, 1);
                while (!atomicLoad(go)) {}

                try {
                    // Alternating backend types, each a fresh instance,
                    // maximise the chance that one thread's compile-time
                    // `classValue` path and another's runtime
                    // `RuntimeTypes.get` path reach `mangleToBuffer` for
                    // `Exception` at the same moment.
                    foreach (which; 0 .. 2) {
                        const index =
                            (threadIndex * 2 + which) % functionCount;
                        auto function_ =
                            findFunction(guestModule, text("f", index));
                        long result;

                        if (threadIndex % 2 == 0) {
                            auto backend = new Bytecode(program);
                            backend.call(function_, &result, []);
                        } else {
                            auto backend = new Interpreter(program);
                            backend.call(function_, &result, []);
                        }

                        const expected = expectedResult(index);
                        if (result != expected)
                            throw new Exception(text(
                                "f", index, "() returned ", result,
                                ", expected ", expected,
                            ));
                    }
                } catch (Throwable throwable)
                    failures[threadIndex] = throwable;
            });
            threads[t].start;
        }

        while (atomicLoad(ready) < threadCount) {}
        atomicStore(go, true);

        foreach (t; 0 .. threadCount)
            threads[t].join;

        foreach (t; 0 .. threadCount)
            if (failures[t] !is null)
                throw new UnitTestException(
                    text(
                        "round ", round, ", thread ", t, ": ",
                        failures[t].msg,
                    ),
                    __FILE__, __LINE__,
                );
    }
}
