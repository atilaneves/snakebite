module ut.repl.session;


import ut;
import snakebite.backends: BackendName;
import snakebite.repl: Repl, SubmitResult;
import std.traits: EnumMembers;


alias ReplBackendName = BackendName;


static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.importWithoutSemicolon." ~ backend.stringof)
    unittest {
        foreach (source; [
            "import std.math",
            "import std.math\n",
            "import std.math // absolute value",
            "import std.math /+ absolute value +/",
            "import std.math : abs",
            "import std.math, std.conv",
        ]) {
            auto repl = Repl(backend);

            repl.submit(source).kind.should == SubmitResult.Kind.none;
            repl.submit("abs(-42)").text.should == "42";
            repl.submit(":q").kind.should == SubmitResult.Kind.quit;
        }
    }

    @("submit.qualifiedImportWithoutSemicolon." ~ backend.stringof)
    unittest {
        foreach (source; ["static import std.math", "import math = std.math"]) {
            auto repl = Repl(backend);
            const expression = source == "static import std.math"
                ? "std.math.abs(-42)"
                : "math.abs(-42)";

            repl.submit(source).kind.should == SubmitResult.Kind.none;
            repl.submit(expression).text.should == "42";
        }
    }

    @("submit.canRepeatImportAfterOmittedSemicolon." ~ backend.stringof)
    unittest {
        auto repl = Repl(backend);

        repl.submit("import std.math").kind.should == SubmitResult.Kind.none;
        repl.submit("import std.math;").kind.should == SubmitResult.Kind.none;
        repl.submit("abs(-42)").text.should == "42";
    }

    @("submit.recoversFromFailedImportWithoutSemicolon." ~ backend.stringof)
    unittest {
        auto repl = Repl(backend);

        const result = repl.submit("import no_such_module_xyz");
        result.kind.should == SubmitResult.Kind.error;
        result.text.should == "unable to read module `no_such_module_xyz`";
        repl.submit("import std.math;").kind.should == SubmitResult.Kind.none;
        repl.submit("abs(-42)").text.should == "42";
    }

    @("submit.accumulatesIncompleteImportAcrossLines." ~ backend.stringof)
    unittest {
        auto repl = Repl(backend);

        repl.submit("import std.math :").kind.should == SubmitResult.Kind.none;
        repl.submit("abs").kind.should == SubmitResult.Kind.none;
        repl.submit("abs(-42)").text.should == "42";
    }

    // Compiled D analyses every module of a project with the project's
    // versions, however the module is reached: through a package's
    // `package.d` and `public import`, an import in a function body, or an
    // import in a `version` block. Another session does not see them.
    @("submit.projectVersionsReachEveryImportedModule." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;
        import std.conv: text;
        import std.file: mkdirRecurse, rmdirRecurse, write;
        import std.path: buildPath;
        import std.process: thisProcessID;

        const name = text("versioned_", backend);
        const directory = buildPath(
            tempDirectory, text("repl_session_", name, "_", thisProcessID),
        );
        mkdirRecurse(buildPath(directory, name));
        scope(exit) rmdirRecurse(directory);

        write(
            buildPath(directory, name, "package.d"),
            text("module ", name, ";\npublic import ", name, ".foo;\n"),
        );
        write(
            buildPath(directory, name, "foo.d"),
            text(
                "module ", name, ".foo;\n",
                "version (ProjV) import ", name, ".conditional;\n",
                "int answer() { version (ProjV) return 42; else return 0; }\n",
                "int local() { import ", name, ".inner; return inner(); }\n",
                "int viaVersion() { return conditional(); }\n",
            ),
        );
        write(
            buildPath(directory, name, "inner.d"),
            text(
                "module ", name, ".inner;\n",
                "int inner() { version (ProjV) return 43; else return 0; }\n",
            ),
        );
        write(
            buildPath(directory, name, "conditional.d"),
            text(
                "module ", name, ".conditional;\n",
                "int conditional() { version (ProjV) return 44; else return 0; }\n",
            ),
        );

        auto repl = Repl(
            backend, [directory], [], FrontendFlags(["-version=ProjV"]),
        );
        repl.submit(text("import ", name, ";")).kind.should
            == SubmitResult.Kind.none;
        repl.submit("answer()").text.should == "42";
        repl.submit("local()").text.should == "43";
        repl.submit("viaVersion()").text.should == "44";

        auto plain = Repl(backend);
        plain.submit("version (ProjV) enum projV = 1; else enum projV = 0;")
            .kind.should == SubmitResult.Kind.none;
        plain.submit("projV").text.should == "0";
    }
}


// Compiled `-checkaction=halt` code stops at the failed check: no
// `finally` block runs. A halted cell must stop in the same way.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.haltedCellDoesNotRunFinally." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;
        import std.process: environment;

        enum ran = "SNAKEBITE_HALT_FINALLY_" ~ backend.stringof;
        auto repl = Repl(
            backend, [], [], FrontendFlags(["-checkaction=halt"]),
        );
        repl.submit(
            "int check(int v) {"
            ~ " import core.sys.posix.stdlib: setenv;"
            ~ " try assert(v == 2);"
            ~ " finally setenv(\"" ~ ran ~ "\", \"1\", 1);"
            ~ " return v; }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("check(1)").kind.should == SubmitResult.Kind.error;
        environment.get(ran, "did not run").should == "did not run";
    }
}


// As above, for `scope(exit)`.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.haltedCellDoesNotRunScopeExit." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;
        import std.process: environment;

        enum ran = "SNAKEBITE_HALT_SCOPE_EXIT_" ~ backend.stringof;
        auto repl = Repl(
            backend, [], [], FrontendFlags(["-checkaction=halt"]),
        );
        repl.submit(
            "int check(int v) {"
            ~ " import core.sys.posix.stdlib: setenv;"
            ~ " scope(exit) setenv(\"" ~ ran ~ "\", \"1\", 1);"
            ~ " assert(v == 2);"
            ~ " return v; }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("check(1)").kind.should == SubmitResult.Kind.error;
        environment.get(ran, "did not run").should == "did not run";
    }
}


// As above, for the destructor of a local variable.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.haltedCellDoesNotRunDestructors." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;
        import std.process: environment;

        enum ran = "SNAKEBITE_HALT_DESTRUCTOR_" ~ backend.stringof;
        auto repl = Repl(
            backend, [], [], FrontendFlags(["-checkaction=halt"]),
        );
        repl.submit(
            "struct Guard { ~this() {"
            ~ " import core.sys.posix.stdlib: setenv;"
            ~ " setenv(\"" ~ ran ~ "\", \"1\", 1); } }",
        ).kind.should == SubmitResult.Kind.none;
        repl.submit(
            "int check(int v) { Guard guard; assert(v == 2); return v; }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("check(1)").kind.should == SubmitResult.Kind.error;
        environment.get(ran, "did not run").should == "did not run";
    }
}


// As above, for the destructor of a temporary that an expression makes.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.haltedCellDoesNotRunTemporaryDestructors." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;
        import std.process: environment;

        enum ran = "SNAKEBITE_HALT_TEMPORARY_" ~ backend.stringof;
        auto repl = Repl(
            backend, [], [], FrontendFlags(["-checkaction=halt"]),
        );
        repl.submit(
            "struct Guard { int v; ~this() {"
            ~ " import core.sys.posix.stdlib: setenv;"
            ~ " setenv(\"" ~ ran ~ "\", \"1\", 1); } }",
        ).kind.should == SubmitResult.Kind.none;
        repl.submit(
            "Guard make() { return Guard(1); }",
        ).kind.should == SubmitResult.Kind.none;
        repl.submit(
            "int boom(int v) { assert(v == 2); return v; }",
        ).kind.should == SubmitResult.Kind.none;
        repl.submit(
            "int check(int v) { return make().v + boom(v); }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("check(1)").kind.should == SubmitResult.Kind.error;
        environment.get(ran, "did not run").should == "did not run";
    }
}


// A guest fault is a halt that no guest code sees, and the cell fails with
// the message of the fault.
static foreach (backend; [BackendName.interpreter, BackendName.bytecode]) {
    @("submit.faultedCellFailsWithTheMessage." ~ backend.stringof)
    unittest {
        auto repl = Repl(backend);
        repl.submit("int load(int* p) { return *p; }")
            .kind.should == SubmitResult.Kind.none;

        const result = repl.submit("load(null)");

        result.kind.should == SubmitResult.Kind.error;
        "fatal: null pointer dereference".should.be in result.text;
        repl.submit("1 + 2").text.should == "3";
    }
}


// As a halt: no `finally` block runs for a fault.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.faultedCellDoesNotRunFinally." ~ backend.stringof)
    unittest {
        import std.process: environment;

        enum ran = "SNAKEBITE_FAULT_FINALLY_" ~ backend.stringof;
        auto repl = Repl(backend);
        repl.submit(
            "int load(int* p) {"
            ~ " import core.sys.posix.stdlib: setenv;"
            ~ " try return *p;"
            ~ " finally setenv(\"" ~ ran ~ "\", \"1\", 1); }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("load(null)").kind.should == SubmitResult.Kind.error;
        environment.get(ran, "did not run").should == "did not run";
    }
}


// As a halt: the destructor of a temporary is guest code, and does not run
// for a fault.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.faultedCellDoesNotRunTemporaryDestructors." ~ backend.stringof)
    unittest {
        import std.process: environment;

        enum ran = "SNAKEBITE_FAULT_TEMPORARY_" ~ backend.stringof;
        auto repl = Repl(backend);
        repl.submit(
            "struct Guard { int v; ~this() {"
            ~ " import core.sys.posix.stdlib: setenv;"
            ~ " setenv(\"" ~ ran ~ "\", \"1\", 1); } }",
        ).kind.should == SubmitResult.Kind.none;
        repl.submit("Guard make() { return Guard(1); }")
            .kind.should == SubmitResult.Kind.none;
        repl.submit("int load(int* p) { return make().v + *p; }")
            .kind.should == SubmitResult.Kind.none;

        repl.submit("load(null)").kind.should == SubmitResult.Kind.error;
        environment.get(ran, "did not run").should == "did not run";
    }
}


// A `foreach` over a string with a `dchar` variable calls druntime's
// compiled `_aApplycd1` with the loop body as a delegate, so the halt
// goes through a native frame before it reaches the `catch`. A halt is
// not an error that guest code handles.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.guestCatchDoesNotSeeAHaltFromACallback." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;

        auto repl = Repl(
            backend, [], [], FrontendFlags(["-checkaction=halt"]),
        );
        repl.submit(
            "int check(int v) {"
            ~ " try foreach (dchar c; \"ab\") assert(v == 2);"
            ~ " catch (Throwable t) return 7;"
            ~ " return v; }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("check(1)").kind.should == SubmitResult.Kind.error;
        repl.submit("check(2)").text.should == "2";
    }
}


// `destroy` calls druntime's compiled `rt_finalize2`, which catches each
// `Exception` from a class destructor and throws a `FinalizeError`
// instead. A halt in the destructor must not become an error that the
// guest `catch` handles.
static foreach (backend; EnumMembers!ReplBackendName) {
    @("submit.guestCatchDoesNotSeeAHaltFromAClassDestructor." ~ backend.stringof)
    unittest {
        import snakebite.frontend.compiler: FrontendFlags;

        auto repl = Repl(
            backend, [], [], FrontendFlags(["-checkaction=halt"]),
        );
        repl.submit(
            "class Checked { int v; ~this() { assert(v == 2); } }",
        ).kind.should == SubmitResult.Kind.none;
        repl.submit(
            "int check() {"
            ~ " auto checked = new Checked;"
            ~ " try destroy(checked);"
            ~ " catch (Throwable t) return 7;"
            ~ " return 1; }",
        ).kind.should == SubmitResult.Kind.none;

        repl.submit("check()").kind.should == SubmitResult.Kind.error;
    }
}


@("submit.evaluatesAnExpression")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    const result = repl.submit("1 + 2");

    result.kind.should == SubmitResult.Kind.value;
    result.text.should == "3";
}


@("submit.evaluatesAnExpressionWithTerminatingSemicolon")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    const result = repl.submit("1 + 2;");

    result.kind.should == SubmitResult.Kind.value;
    result.text.should == "3";
}


@("submit.blankLineIsANoopWithNoOutput")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    const result = repl.submit("");

    result.kind.should == SubmitResult.Kind.none;
}


@("submit.accumulatesADeclarationAcrossLines")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    // An unclosed brace stays pending until the closing line arrives.
    repl.submit("int answer() {").kind.should == SubmitResult.Kind.none;
    repl.submit("return 42;").kind.should == SubmitResult.Kind.none;
    repl.submit("}").kind.should == SubmitResult.Kind.none;

    const result = repl.submit("answer()");
    result.kind.should == SubmitResult.Kind.value;
    result.text.should == "42";
}


@("submit.reportsAnUndefinedIdentifier")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    const result = repl.submit("bad_var");

    result.kind.should == SubmitResult.Kind.error;
    result.text.should == "undefined identifier `bad_var`";
}


@("submit.quitCommandIsRejectedWhileInputIsPending")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    repl.submit("int answer() {").kind.should == SubmitResult.Kind.none;

    const result = repl.submit(":q");
    result.kind.should == SubmitResult.Kind.error;
    result.text.should ==
        "cannot run REPL command `:q` while input is pending";

    // The pending input survives the rejected command.
    repl.submit("return 42; }").kind.should == SubmitResult.Kind.none;
    repl.submit("answer()").text.should == "42";
}


@("submit.quitCommandQuitsWhenNothingIsPending")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    repl.submit(":q").kind.should == SubmitResult.Kind.quit;
}


@("shouldQuit.trueForQuitCommandsWithNoPendingInput")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    repl.shouldQuit(":q").should == true;
    repl.shouldQuit(":quit").should == true;
    repl.shouldQuit("1 + 2").should == false;
}


@("shouldQuit.falseWhileInputIsPending")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    repl.submit("int answer() {");

    repl.shouldQuit(":q").should == false;
}


@("runLoadedTests.rerunsEveryAccumulatedUnittest")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    // A unittest whose condition is provably true at compile time still
    // exercises the `:t` path end to end (find it, call it, report no
    // failure) without depending on the interpreter's own diagnostic
    // rendering for a failing assertion.
    repl.submit("unittest { assert(1 + 1 == 2); }")
        .kind.should == SubmitResult.Kind.none;

    repl.submit(":t").kind.should == SubmitResult.Kind.none;
}


@("runLoadedTests.withNothingLoadedIsANoop")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    repl.submit(":t").kind.should == SubmitResult.Kind.none;
}


@("runLoadedTests.reportsALocatedFailure")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    // Runtime-shaped operands (not literals) so DMD cannot fold the
    // comparison at compile time: the assertion fails at run time, the
    // ordinary path a failing `unittest` takes.
    repl.submit(
        "unittest { int a = 1; int b = 2; assert(a == b); }",
    ).kind.should == SubmitResult.Kind.none;

    const result = repl.submit(":t");

    result.kind.should == SubmitResult.Kind.error;
    result.text.should == "unittest at <repl cell 1>(1) failed: " ~
        "unittest failure";
}


@("submit.dedupesADuplicatedFailedImportDiagnostic")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    const result = repl.submit("import no_such_module_xyz;");

    result.kind.should == SubmitResult.Kind.error;
    result.text.should == "unable to read module `no_such_module_xyz`";
}


@("submit.callsIntoAModuleImportedFromAnImportPath")
unittest {
    import std.file: mkdirRecurse, remove, rmdirRecurse, write;
    import std.path: buildPath;
    import std.process: thisProcessID;
    import std.conv: text;

    const directory = buildPath(
        tempDirectory, text("repl_session_import_", thisProcessID),
    );
    mkdirRecurse(directory);
    scope(exit) rmdirRecurse(directory);

    const importedPath = buildPath(directory, "repl_session_imported.d");
    write(
        importedPath,
        "module repl_session_imported;\n"
        ~ "int importedValue() { return 41; }\n",
    );

    auto repl = Repl(ReplBackendName.interpreter, [directory]);
    repl.submit("import repl_session_imported;")
        .kind.should == SubmitResult.Kind.none;

    repl.submit("importedValue() + 1").text.should == "42";
}


@("submit.evaluatesAnExpressionWithBytecode")
unittest {
    auto repl = Repl(ReplBackendName.bytecode);

    const result = repl.submit("1 + 2");

    result.kind.should == SubmitResult.Kind.value;
    result.text.should == "3";
}


@("submit.ctfeBackendEvaluatesAnExpression")
unittest {
    auto repl = Repl(ReplBackendName.ctfe);

    repl.submit("1 + 2").text.should == "3";
}


@("loadModuleFile.acceptsDeclarationsSilently")
unittest {
    import std.file: remove, write;
    import std.path: buildPath;
    import std.process: thisProcessID;
    import std.conv: text;

    const path = buildPath(
        tempDirectory, text("repl_session_", thisProcessID, ".d"),
    );
    write(path, "int answer() { return 42; }\n");
    scope(exit) remove(path);

    auto repl = Repl(ReplBackendName.interpreter);
    repl.loadModuleFile(path);

    repl.submit("answer()").text.should == "42";
}


@("loadModuleFile.missingFileThrows")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    repl.loadModuleFile("/no/such/file.d").shouldThrow;
}


private string tempDirectory() {
    import std.file: tempDir;

    return tempDir;
}
