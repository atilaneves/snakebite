module snakebite.start.data;


private:


// What the start of a guest program needs, with no frontend data in it: one
// start record for each root module (`ModuleStart`), made from that module
// alone, and what the program takes from the records together (`StartData`):
// which record an import names, the `crt_constructor` and `crt_destructor`
// functions in the order of the records, and `main`. A backend builds the
// records (`buildStartData`); `GuestModules` and `runMain` run on them only.

// What a backend gives out to name a function. It means nothing outside the
// backend that made it, and that backend decides when the function is
// compiled: at the first `call`.
public abstract class FunctionHandle {
    // Calls the function as `Backend.call` does.
    public abstract void call(void* returnPlace, void*[] args);

    // The compiled code that the handle runs, compiled first if need be. Only
    // the backend that made the handle can use the address. Null for a
    // backend that has no compiled code to keep.
    public const(void)* compiledCode() {
        return null;
    }
}


// The storage of one gate variable (see `ModuleStart.sharedGates`) and the
// datum it is, from the place that reserved it.
public alias GateStorage = imported!"snakebite.native.staticstore".Placed;


public struct ModuleStart {
    public string name;
    // Whether druntime orders the module: false when it has nothing to
    // construct or destruct.
    public bool standalone;
    // The names of the modules this module imports, in the order of its
    // imports.
    public string[] importNames;
    public FunctionHandle[] independentConstructors;
    public FunctionHandle[] sharedConstructors;
    public FunctionHandle[] threadConstructors;
    public FunctionHandle[] sharedDestructors;
    public FunctionHandle[] threadDestructors;
    public FunctionHandle[] unitTests;
    public FunctionHandle[] crtConstructors;
    public FunctionHandle[] crtDestructors;
    // dmd's glue layer increments the gate of each destructor of a template
    // instance while it runs the constructors of the module: the destructor
    // body returns early unless it brings the gate back to zero.
    public GateStorage[] sharedGates;
    public GateStorage[] threadGates;
    // The module-level `main` of the module, if it declares one.
    public MainStart main;

    // Calls `visit` with each function handle of the module.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (handles; [independentConstructors, sharedConstructors,
                threadConstructors, sharedDestructors, threadDestructors,
                unitTests, crtConstructors, crtDestructors])
            foreach (handle; handles)
                visit(handle);
        if (main.present)
            visit(main.function_);
    }

    // Whether the module has a constructor or a destructor.
    public bool hasPhaseFunctions() const {
        return independentConstructors.length
            || sharedConstructors.length
            || threadConstructors.length
            || sharedDestructors.length
            || threadDestructors.length;
    }
}


public struct MainStart {
    // Whether the module declares a `main`.
    public bool present;
    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it.
    public bool cLinkage;
    public bool returnsVoid;
    // The number of parameters `main` declares.
    public size_t parameterCount;
    public FunctionHandle function_;

    // Whether the module declares a `main`.
    public bool opCast(T : bool)() const {
        return present;
    }
}


// The rule for the `main` of a program: the one of the first module that
// has one. `mainOf` gives the `main` of a module as a value that is false
// when the module has none. Gives that type's `init` when no module has one.
public auto firstMain(alias mainOf, Modules)(Modules modules) {
    foreach (module_; modules) {
        auto found = mainOf(module_);
        if (found)
            return found;
    }
    return typeof(mainOf(modules[0])).init;
}


// The rule for the C entry point: a C-linkage `main` is the entry of the
// process, as the C runtime calls it. druntime does not start, so a build
// with unit tests runs none of them and no module constructor, and the
// program is only that function.
public bool isCEntryPoint(in bool hasMain, lazy bool cLinkage) {
    return hasMain && cLinkage;
}


// The modules of the dependency image that a program runs on, or none.
public const(ModuleInfo*)[] dependencyModulesOf(
    in imported!"snakebite.image.dependency".DependencyImage* image,
) {
    return image is null ? null : image.deferredModules;
}


public struct StartData {
    public string programName;
    public bool betterC;
    // One record for each root module, in the order of the root modules. A
    // backend decides where each record lives (see `buildStartData`).
    public ModuleStart*[] modules;
    public const(ModuleInfo*)[] dependencyModules;

    // The `main` of the program: the one of the first record that has one.
    public MainStart main() {
        return firstMain!(module_ => module_.main)(modules);
    }

    public bool hasCEntryPoint() {
        const main_ = main;
        return isCEntryPoint(main_.present, main_.cLinkage);
    }

    // In the order of the records, which is the order of the constructors.
    public FunctionHandle[] crtConstructors() {
        FunctionHandle[] handles;
        foreach (module_; modules)
            handles ~= module_.crtConstructors;
        return handles;
    }

    // As `crtConstructors`.
    public FunctionHandle[] crtDestructors() {
        FunctionHandle[] handles;
        foreach (module_; modules)
            handles ~= module_.crtDestructors;
        return handles;
    }

    // For each record, the positions in `modules` of the records that it
    // imports and that druntime orders, in the order of its imports and
    // each one time. An import that names no record, and an import of the
    // module itself, have no position.
    public size_t[][] importPositions() const {
        size_t[string] positionOf;
        foreach (i, module_; modules)
            positionOf[module_.name] = i;

        auto positions = new size_t[][modules.length];
        foreach (i, module_; modules) {
            bool[size_t] seen;
            foreach (name; module_.importNames) {
                const position = name in positionOf;
                if (position is null || *position == i
                        || modules[*position].standalone
                        || *position in seen)
                    continue;

                seen[*position] = true;
                positions[i] ~= *position;
            }
        }
        return positions;
    }

    // Calls `visit` with each function handle of the program.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (module_; modules)
            module_.eachHandle(visit);
    }
}
