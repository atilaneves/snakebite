module ut.backends.program;


import snakebite.frontend.ast: FuncDeclaration;
import snakebite.program: Program;
import ut.backends: ownedBackend;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.ctfe: Ctfe;
import snakebite.failure.report: SnakebiteException;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions:
    Defined,
    findFunction,
    findModuleConstructors;
import std.algorithm: map;
import ut;


@("isInterpreted.rootModule")
unittest {
    auto modules = parseSnippets([
        q{
            module rootModule;
            int rootFunction() { return 1; }
        },
        q{
            module importedModule;
            int importedFunction() { return 2; }
        },
    ]);
    auto program = Program([modules[0]]);

    program.whereDefined(findFunction(modules[0], "rootFunction"))
        .should == Defined.onlyHere;
}


@("compilationStatistics.noCompiler")
@Tags(Ctfe.stringof)
unittest {
    auto module_ = parseSnippets([
        q{
            module noCompilationStatistics;
        },
    ])[0];
    auto statistics = (new Ctfe(Program([module_]))).compilationStatistics;

    statistics.hasCompiler.shouldBeFalse;
    statistics.cacheMisses.should == 0;
}


@("ctfe.nullDereferenceIsADiagnostic")
@Tags(Ctfe.stringof)
unittest {
    auto module_ = parseSnippets([
        q{
            module diagnosed;
            int fail() { int* pointer; return *pointer; }
        },
    ])[0];
    auto backend = new Ctfe(Program([module_]));
    int result;

    backend.call(module_.findFunction("fail"), &result, [])
        .shouldThrowWithMessage!SnakebiteException(
            "dereference of null pointer `pointer`");
}


// A compiler reports two `main` functions in one program as an error that
// names both (dmd: "only one entry point `main` is allowed").
@("program.twoRootModulesWithMainAreRefused")
unittest {
    auto modules = parseSnippets([
        q{
            module first;
            void main() {}
        },
        q{
            module second;
            void main() {}
        },
    ]);

    Program(modules).shouldThrowWithMessage!SnakebiteException(
        "only one entry point `main` is allowed: found in `first` and `second`");
}


@("bytecode.compilationStatistics.countsLazyCacheMisses")
@Tags(Bytecode.stringof)
unittest {
    auto module_ = parseSnippets([
        q{
            module bytecodeCompilationStatistics;
            int helper() { return 1; }
            int other() { return 2; }
            void main() { helper(); }
        },
    ])[0];
    auto program = Program([module_]);
    auto backend = ownedBackend!Bytecode(program);

    backend.compilationStatistics.hasCompiler.should == true;
    backend.compilationStatistics.cacheMisses.should == 0;

    backend.call(findFunction(module_, "main"), null, []);
    auto afterMain = backend.compilationStatistics;
    afterMain.cacheMisses.should == 2;

    backend.call(findFunction(module_, "main"), null, []);
    backend.compilationStatistics.cacheMisses.should == 2;

    backend.call(findFunction(module_, "other"), null, []);
    backend.compilationStatistics.cacheMisses.should == 3;
    (backend.compilationStatistics.duration >= afterMain.duration)
        .should == true;
}


@("findModuleConstructors.rootModule")
unittest {
    auto module_ = parseSnippets([
        q{
            module constructorsRootModule;
            __gshared int trace;

            static this() { trace = trace * 10 + 3; }
            shared static this() { trace = trace * 10 + 1; }
            shared static this() { trace = trace * 10 + 2; }
        },
    ])[0];

    auto constructors = findModuleConstructors(module_);
    assert(constructors.length == 3);
}


@("findModuleConstructors.insideAggregate")
unittest {
    auto module_ = parseSnippets([
        q{
            module constructorsInsideAggregate;
            __gshared int trace;

            struct StructWithCtor {
                shared static this() { trace = trace * 10 + 1; }
                static this() { trace = trace * 10 + 2; }
            }

            class ClassWithCtor {
                static this() { trace = trace * 10 + 3; }
            }
        },
    ])[0];

    auto constructors = findModuleConstructors(module_);
    constructors.map!(constructorLabel).should == [
        "StructWithCtor.shared static this",
        "StructWithCtor.static this",
        "ClassWithCtor.static this",
    ];
}

// `constructor`'s enclosing scope and kind, such as
// "StructWithCtor.shared static this". A count alone does not tell apart a
// collector that found the right constructors from one that found any
// three; this pins both, without pinning the location-derived identifier
// dmd gives every static and shared static constructor.
private string constructorLabel(FuncDeclaration constructor) {
    import std.conv: text;

    return text(
        constructor.parent.ident.toString,
        ".",
        constructor.isSharedStaticCtorDeclaration
            ? "shared static this" : "static this",
    );
}


@("findModuleConstructors.insideNamespace")
unittest {
    auto module_ = parseSnippets([
        q{
            module constructorsInsideNamespace;
            __gshared int trace;

            extern(C++, ns) {
                shared static this() { trace = trace * 10 + 1; }
                static this() { trace = trace * 10 + 2; }
            }
        },
    ])[0];

    auto constructors = findModuleConstructors(module_);
    constructors.map!(constructorLabel).should == [
        "ns.shared static this",
        "ns.static this",
    ];
}


@("isInterpreted.nonRootModule")
unittest {
    auto modules = parseSnippets([
        q{
            module anotherRootModule;
            int rootFunction() { return 1; }
        },
        q{
            module anotherImportedModule;
            int importedFunction() { return 2; }
        },
    ]);
    auto program = Program([modules[0]]);

    program.whereDefined(findFunction(modules[1], "importedFunction"))
        .should.not == Defined.onlyHere;
}


@("isInterpreted.compilerGeneratedName")
unittest {
    auto module_ = parseSnippets([
        q{
            module generatedNameRootModule;
            int _d_runtimeGenerated() { return 1; }
        },
    ])[0];
    auto program = Program([module_]);

    program.whereDefined(findFunction(module_, "_d_runtimeGenerated"))
        .should == Defined.onlyHere;
}
