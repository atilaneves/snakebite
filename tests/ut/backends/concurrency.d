module ut.backends.concurrency;


import ut.backends;
import snakebite.program: Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


// Regression test for a race between `snakebite.language.statics.typeinfo.
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
// `classinfo.classRuntimeInfo` (then guarded only by `ClassRuntimeCache`'s
// own per-instance lock, deliberately not the frontend one - its own doc
// said `make` never itself needs the frontend lock, an assumption that
// held only while `linkedClassInfo` was unreachable without it) take it.
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

// Keep both compile-time class literals and runtime construction. Runtime
// construction also selects a constructor through shared parent metadata
// while other threads can force frontend semantic work.
private enum guestSource = (){
    string source =
        "module ut.backends.concurrency_guest;\n";
    foreach (i; 0 .. functionCount)
        source ~= text(
            "long f", i, "() { ",
            i % 2 == 0 ? "static immutable failure" : "auto failure", i,
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
                            auto backend = ownedBackend!Bytecode(program);
                            backend.call(function_, &result, []);
                        } else {
                            auto backend = Owned!Interpreter(program);
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


// A `catch` clause with a qualified class type takes the class's
// `TypeInfo_Class` from the unqualified type. To remove the qualifier is
// frontend work: dmd can make a new type, merge it and mangle it. While
// one thread does that, another thread parses, and so merges and mangles
// under the frontend lock. Each round declares new classes, so that each
// thread asks dmd for a type that it did not make before.
private enum qualifiedCatchRounds = 32;
private enum qualifiedCatchClasses = 16;
private enum qualifiedCatchThreads = 8;
private enum busyFrontendParses = 4;

private string qualifiedCatchSource(in size_t round) {
    string source = text("module ut.backends.qualified_catch_", round, ";\n");
    foreach (i; 0 .. qualifiedCatchClasses) {
        const name = text("Failure", round, "_", i);
        const qualifier = i % 2 == 0 ? "immutable" : "shared const";
        source ~= text(
            "class ", name, " : Exception { this() { super(\"boom\"); } }\n",
            "long f", i, "() { try { throw new ", name, "; } ",
            "catch (", qualifier, " ", name, " e) { return ", i, "; } }\n",
        );
    }
    return source;
}

// Frontend work while the guests run: each parse has new declarations, so
// dmd makes, merges and mangles new types. A parse holds the frontend
// lock, so only a few parses run in each round: the guests then do not
// wait for the lock most of the time.
private string busyFrontendSource(in size_t round, in size_t index) {
    return text(
        "module ut.backends.busy_frontend_", round, "_", index, ";\n",
        "struct S", index, " { int[] values; }\n",
        "immutable(S", index, ")[] f() { return null; }\n",
        "shared(const(S", index, ")*)[string] g() { return null; }\n",
    );
}

static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the race is between a backend and the frontend in one process"),
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE does not catch with a qualified `catch` type"),
)) {
    @("qualifiedCatchWhileFrontendWorks." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.atomic: atomicLoad, atomicOp, atomicStore;
        import core.thread: Thread;

        foreach (round; 0 .. qualifiedCatchRounds) {
            auto guestModule = parseSnippet(qualifiedCatchSource(round));
            auto program = Program([guestModule]);

            shared size_t ready = 0;
            shared bool go = false;
            shared bool stop = false;
            Throwable[qualifiedCatchThreads] failures;
            Throwable frontendFailure;

            auto frontend = new Thread({
                atomicOp!"+="(ready, 1);
                while (!atomicLoad(go)) {}
                try {
                    foreach (index; 0 .. busyFrontendParses) {
                        if (atomicLoad(stop))
                            break;
                        parseSnippet(busyFrontendSource(round, index));
                    }
                } catch (Throwable throwable)
                    frontendFailure = throwable;
            });
            frontend.start;

            auto threads = new Thread[qualifiedCatchThreads];
            foreach (t; 0 .. qualifiedCatchThreads) {
                const threadIndex = t;
                threads[t] = new Thread({
                    atomicOp!"+="(ready, 1);
                    while (!atomicLoad(go)) {}
                    try {
                        foreach (i; 0 .. qualifiedCatchClasses) {
                            const index =
                                (threadIndex + i) % qualifiedCatchClasses;
                            auto function_ =
                                findFunction(guestModule, text("f", index));
                            auto guest = ownedBackend!backend(program);
                            long result;
                            guest.call(function_, &result, []);
                            if (result != index)
                                throw new Exception(text(
                                    "f", index, "() returned ", result));
                        }
                    } catch (Throwable throwable)
                        failures[threadIndex] = throwable;
                });
                threads[t].start;
            }

            while (atomicLoad(ready) < qualifiedCatchThreads + 1) {}
            atomicStore(go, true);

            foreach (thread; threads)
                thread.join;
            atomicStore(stop, true);
            frontend.join;

            if (frontendFailure !is null)
                throw new UnitTestException(
                    text("round ", round, ", frontend: ", frontendFailure.msg),
                    __FILE__, __LINE__);
            foreach (t; 0 .. qualifiedCatchThreads)
                if (failures[t] !is null)
                    throw new UnitTestException(
                        text("round ", round, ", thread ", t, ": ",
                            failures[t].msg),
                        __FILE__, __LINE__);
        }
    }
}
