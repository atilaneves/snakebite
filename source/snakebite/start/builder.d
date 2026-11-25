module snakebite.start.builder;


private:


import snakebite.frontend.dmd.functions: hasCLinkage;
import snakebite.program: Program;
import snakebite.start.data:
    dependencyModulesOf, FunctionHandle, GateStorage, MainStart, ModuleStart,
    StartData;


// What the builder asks of a backend.
alias CompiledFunction =
    FunctionHandle delegate(imported!"snakebite.frontend.ast".FuncDeclaration);
alias StaticStorage =
    imported!"snakebite.native.staticstore".Placed delegate(imported!"snakebite.frontend.ast".VarDeclaration);
alias ModuleStorage =
    ModuleStart* delegate(imported!"snakebite.frontend.ast".Module);


// Reads the frontend one time and builds the start data of `program`: one
// `ModuleStart` for each root module, each made from its module alone. The
// functions in it are the ones `compiledFunction` names; it compiles them
// when it likes. `staticStorage` gives the bytes of a static variable.
// `moduleStorage` gives the storage of the `ModuleStart` of a root module; the
// builder overwrites it. A failure throws before the caller has a value to
// keep, and can leave `ModuleStart`s half filled.
public StartData buildStartData(
    Program program,
    CompiledFunction compiledFunction,
    StaticStorage staticStorage,
    ModuleStorage moduleStorage,
) {
    StartData data;
    data.programName = program.name;
    data.betterC = program.checks.betterC;
    if (!data.betterC)
        data.dependencyModules = dependencyModulesOf(program.dependencyImage);
    foreach (module_; program.rootModules) {
        // `auto`: the code writes through the pointer, so it cannot be const.
        auto start = moduleStorage(module_);
        *start = startOf(module_, data.betterC, compiledFunction, staticStorage);
        data.modules ~= start;
    }
    return data;
}


// The `ModuleStart` of `module_`, from that module alone. Under `-betterC`
// dmd makes no `ModuleInfo`: it has the name and `main` only.
private ModuleStart startOf(
    imported!"snakebite.frontend.ast".Module module_,
    in bool betterC,
    CompiledFunction compiledFunction,
    StaticStorage staticStorage,
) {
    import snakebite.frontend.dmd.functions:
        findFunction, findModuleFunctions, prettyNameOf;

    ModuleStart start;
    start.name = prettyNameOf(module_);
    if (auto main_ = findFunction(module_, "main"))
        start.main = mainStartOf(main_, compiledFunction);
    if (betterC)
        return start;

    start.standalone = !module_.needmoduleinfo;
    foreach (imported; module_.aimports)
        start.importNames ~= prettyNameOf(imported);

    auto functions = findModuleFunctions(module_);
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
    start.sharedGates = gatesOf(staticStorage, functions.sharedDestructors);
    start.threadGates = gatesOf(staticStorage, functions.threadDestructors);
    start.unitTests = compiled(compiledFunction, functions.unittests);
    start.crtConstructors =
        compiled(compiledFunction, functions.crtConstructors);
    start.crtDestructors =
        compiled(compiledFunction, functions.crtDestructors);
    return start;
}


private MainStart mainStartOf(
    imported!"snakebite.frontend.ast".FuncDeclaration main_,
    CompiledFunction compiledFunction,
) {
    import snakebite.frontend.dmd.functions: typeFunctionOf;
    import snakebite.frontend.ast: nextOf, Tvoid;
    import snakebite.frontend.typefacts: baseType;

    MainStart start;
    start.cLinkage = hasCLinkage(main_);
    start.returnsVoid = main_.type.nextOf.baseType.ty == Tvoid;
    start.parameterCount = typeFunctionOf(main_).parameterList.length;
    start.function_ = compiled(compiledFunction, main_);
    return start;
}


private FunctionHandle[] compiled(
    CompiledFunction compiledFunction,
    imported!"snakebite.frontend.ast".FuncDeclaration[] functions,
) {
    FunctionHandle[] result;
    foreach (function_; functions)
        result ~= compiled(compiledFunction, function_);
    return result;
}


private FunctionHandle compiled(
    CompiledFunction compiledFunction,
    imported!"snakebite.frontend.ast".FuncDeclaration function_,
) {
    return compiledFunction(function_);
}


private GateStorage[] gatesOf(
    StaticStorage staticStorage,
    imported!"snakebite.frontend.ast".FuncDeclaration[] destructors,
) {
    GateStorage[] gates;
    foreach (destructor; destructors)
        if (auto gate = destructor.isStaticDtorDeclaration.vgate)
            if (auto storage = staticStorage(gate))
                if (storage.length)
                    gates ~= storage;
    return gates;
}
