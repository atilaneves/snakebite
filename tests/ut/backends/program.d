module ut.backends.program;


import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;


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
