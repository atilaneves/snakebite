module snakebite.backends.startdatabuilder;


private:


import snakebite.backends.backend: Backend, Program;
import snakebite.backends.startdata:
    CompiledFunction, GateStorage, ModuleStart, StartData;


// Reads the frontend one time and builds the start data of `program`. The
// functions in it are the ones `backend` compiles. `unitTests` says whether
// the modules also list their unit tests, which a backend then compiles too.
public StartData buildStartData(
    Backend backend,
    Program program,
    in bool unitTests,
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
        data.main.function_ = compiled(backend, main_);
    }

    if (data.betterC)
        return data;

    data.dependencyModules = program.dependencyImage is null
        ? null : program.dependencyImage.deferredModules;
    addModules(data, backend, program, unitTests);
    return data;
}


private void addModules(
    ref StartData data,
    Backend backend,
    Program program,
    in bool unitTests,
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
            compiled(backend, functions.independentConstructors);
        start.sharedConstructors =
            compiled(backend, functions.sharedConstructors);
        start.threadConstructors =
            compiled(backend, functions.threadConstructors);
        start.sharedDestructors =
            compiled(backend, functions.sharedDestructors);
        start.threadDestructors =
            compiled(backend, functions.threadDestructors);
        start.sharedGates = gatesOf(backend, functions.sharedDestructors);
        start.threadGates = gatesOf(backend, functions.threadDestructors);
        if (unitTests)
            start.unitTests = compiled(backend, functions.unittests);

        data.crtConstructors ~= compiled(backend, functions.crtConstructors);
        data.crtDestructors ~= compiled(backend, functions.crtDestructors);
        data.modules ~= start;
    }
}


private CompiledFunction[] compiled(
    Backend backend,
    imported!"dmd.func".FuncDeclaration[] functions,
) {
    CompiledFunction[] result;
    foreach (function_; functions)
        result ~= compiled(backend, function_);
    return result;
}


// A function that fails to compile fails when it is called, where an
// uncompiled function fails.
private CompiledFunction compiled(
    Backend backend,
    imported!"dmd.func".FuncDeclaration function_,
) {
    import snakebite.exception: SnakebiteException;

    try
        return CompiledFunction(backend.compiledFunction(function_));
    catch (SnakebiteException failure)
        return CompiledFunction(null, failure);
}


private GateStorage[] gatesOf(
    Backend backend,
    imported!"dmd.func".FuncDeclaration[] destructors,
) {
    GateStorage[] gates;
    foreach (destructor; destructors)
        if (auto gate = destructor.isStaticDtorDeclaration.vgate)
            if (auto storage = backend.staticStorage(gate))
                if (storage.length)
                    gates ~= storage;
    return gates;
}
