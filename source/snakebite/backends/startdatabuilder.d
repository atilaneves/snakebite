module snakebite.backends.startdatabuilder;


private:


import snakebite.program: Program;
import snakebite.backends.startdata:
    FunctionHandle, GateStorage, ModuleStart, StartData;


// What the builder asks of a backend.
alias CompiledFunction =
    FunctionHandle delegate(imported!"dmd.func".FuncDeclaration);
alias StaticStorage =
    void[] delegate(imported!"dmd.declaration".VarDeclaration);


// Reads the frontend one time and builds the start data of `program`. The
// functions in it are the ones `compiledFunction` names; it compiles them when
// it likes. `staticStorage` gives the bytes of a static variable. A failure
// throws before the caller has a value to keep.
public StartData buildStartData(
    Program program,
    CompiledFunction compiledFunction,
    StaticStorage staticStorage,
) {
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import dmd.astenums: Tvoid;
    import dmd.typesem: nextOf;

    StartData data;
    data.programName = program.name;
    data.hasCEntryPoint = program.hasCEntryPoint;
    data.betterC = program.checks.betterC;
    if (auto main_ = program.main.func) {
        data.main.present = true;
        data.main.returnsVoid = main_.type.nextOf.ty == Tvoid;
        data.main.parameterCount = typeFunctionOf(main_).parameterList.length;
        data.main.function_ = compiled(compiledFunction, main_);
    }

    if (data.betterC)
        return data;

    data.dependencyModules = program.dependencyImage is null
        ? null : program.dependencyImage.deferredModules;
    addModules(data, compiledFunction, staticStorage, program);
    return data;
}


private void addModules(
    ref StartData data,
    CompiledFunction compiledFunction,
    StaticStorage staticStorage,
    Program program,
) {
    import dmd.dmodule: Module;
    import snakebite.frontend.dmd.functions:
        findModuleFunctions, prettyNameOf;
    import std.string: fromStringz;

    size_t[Module] indexOf;
    foreach (i, module_; program.rootModules)
        indexOf[module_] = i;

    foreach (i, module_; program.rootModules) {
        auto functions = findModuleFunctions(module_);
        ModuleStart start;
        start.name = prettyNameOf(module_).fromStringz.idup;
        start.standalone = !module_.needmoduleinfo;
        bool[size_t] seen;
        foreach (imported; module_.aimports) {
            if (data.dependencyModules.length != 0)
                start.importNames ~= prettyNameOf(imported).fromStringz.idup;
            if (!imported.needmoduleinfo || imported is module_)
                continue;

            if (auto index = imported in indexOf)
                if (*index !in seen) {
                    seen[*index] = true;
                    start.imports ~= *index;
                }
        }

        start.independentConstructors =
            compiled(compiledFunction, functions.independentConstructors);
        start.sharedConstructors =
            compiled(compiledFunction, functions.sharedConstructors);
        start.threadConstructors =
            compiled(compiledFunction, functions.threadConstructors);
        start.sharedDestructors =
            compiled(compiledFunction, functions.sharedDestructors);
        start.threadDestructors =
            compiled(compiledFunction, functions.threadDestructors);
        start.sharedGates =
            gatesOf(staticStorage, functions.sharedDestructors);
        start.threadGates =
            gatesOf(staticStorage, functions.threadDestructors);
        start.unitTests = compiled(compiledFunction, functions.unittests);

        data.crtConstructors ~=
            compiled(compiledFunction, functions.crtConstructors);
        data.crtDestructors ~=
            compiled(compiledFunction, functions.crtDestructors);
        data.modules ~= start;
    }
}


private FunctionHandle[] compiled(
    CompiledFunction compiledFunction,
    imported!"dmd.func".FuncDeclaration[] functions,
) {
    FunctionHandle[] result;
    foreach (function_; functions)
        result ~= compiled(compiledFunction, function_);
    return result;
}


private FunctionHandle compiled(
    CompiledFunction compiledFunction,
    imported!"dmd.func".FuncDeclaration function_,
) {
    return compiledFunction(function_);
}


private GateStorage[] gatesOf(
    StaticStorage staticStorage,
    imported!"dmd.func".FuncDeclaration[] destructors,
) {
    GateStorage[] gates;
    foreach (destructor; destructors)
        if (auto gate = destructor.isStaticDtorDeclaration.vgate)
            if (auto storage = staticStorage(gate))
                if (storage.length)
                    gates ~= storage;
    return gates;
}
