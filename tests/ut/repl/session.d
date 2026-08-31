module ut.repl.session;


import ut;
import snakebite.repl: Repl, SubmitResult;
import snakebite.repl.cli: ReplBackendName;


@("submit.evaluatesAnExpression")
unittest {
    auto repl = Repl(ReplBackendName.interpreter);

    const result = repl.submit("1 + 2");

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
        "interpreter: assertion failed: `assert(a == b)`";
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


// The bytecode backend does not implement `eval` yet: the REPL surfaces
// that refusal as an ordinary error rather than crashing, and this also
// exercises `makeBackend`'s bytecode branch.
@("submit.bytecodeBackendSurfacesItsOwnEvalRefusal")
unittest {
    auto repl = Repl(ReplBackendName.bytecode);

    const result = repl.submit("1 + 2");

    result.kind.should == SubmitResult.Kind.error;
    result.text.should == "eval not implemented for the bytecode backend yet";
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
