module snakebite.backends.startdatabuilder;


private:


import snakebite.backends.backend: Backend, Program;
import snakebite.backends.startdata:
    FunctionHandle, GateStorage, ModuleStart, StartData;


// Reads the frontend one time and builds the start data of `program`. The
// functions in it are the ones `backend` names; it compiles them when it
// likes. A failure throws before the caller has a value to keep.
public StartData buildStartData(Backend backend, Program program) {
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
    addModules(data, backend, program);
    return data;
}


private void addModules(
    ref StartData data,
    Backend backend,
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
        start.unitTests = compiled(backend, functions.unittests);

        data.crtConstructors ~= compiled(backend, functions.crtConstructors);
        data.crtDestructors ~= compiled(backend, functions.crtDestructors);
        data.modules ~= start;
    }
}


private FunctionHandle[] compiled(
    Backend backend,
    imported!"dmd.func".FuncDeclaration[] functions,
) {
    FunctionHandle[] result;
    foreach (function_; functions)
        result ~= compiled(backend, function_);
    return result;
}


private FunctionHandle compiled(
    Backend backend,
    imported!"dmd.func".FuncDeclaration function_,
) {
    return backend.compiledFunction(function_);
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
