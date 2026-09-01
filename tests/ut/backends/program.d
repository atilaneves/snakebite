module ut.backends.program;


import snakebite.backends.backend: Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.ctfe: Ctfe;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions:
    findFunction,
    findModuleConstructors;
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

    assert(program.isInterpreted(findFunction(modules[0], "rootFunction")));
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
    statistics.cacheMisses.shouldEqual(0);
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
    auto backend = new Bytecode(program);

    backend.compilationStatistics.hasCompiler.shouldBeTrue;
    backend.compilationStatistics.cacheMisses.shouldEqual(0);

    backend.call(findFunction(module_, "main"), null, []);
    auto afterMain = backend.compilationStatistics;
    afterMain.cacheMisses.shouldEqual(2);

    backend.call(findFunction(module_, "main"), null, []);
    backend.compilationStatistics.cacheMisses.shouldEqual(2);

    backend.call(findFunction(module_, "other"), null, []);
    backend.compilationStatistics.cacheMisses.shouldEqual(3);
    (backend.compilationStatistics.duration >= afterMain.duration)
        .shouldBeTrue;
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

    assert(!program.isInterpreted(
        findFunction(modules[1], "importedFunction"),
    ));
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

    assert(program.isInterpreted(
        findFunction(module_, "_d_runtimeGenerated"),
    ));
}
