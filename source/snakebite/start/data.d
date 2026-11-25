module snakebite.start.data;


private:


// What the start of a guest program needs, with no frontend data in it: the
// modules, their phases and the order of their imports, the gate storage,
// the `crt_constructor` and `crt_destructor` functions, and `main` with the
// way to call it. A backend builds it (`buildStartData`); `GuestModules` and
// `runMain` run on it only.

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
    // The position of the module among the modules of the program, which is
    // the position of its root file. A compile of one unit (ADR-0021) holds
    // some modules of the program, and the link puts the modules in this
    // order, whatever the grouping of the files into units.
    public size_t order;
    // Whether druntime orders the module: false when it has nothing to
    // construct or destruct.
    public bool standalone;
    // The positions in `StartData.modules` of the modules this module imports
    // that have a record.
    public size_t[] imports;
    // The names of every module this module imports, for the records of a
    // dependency image and for the link of units (ADR-0021). Empty when the
    // program has neither.
    public string[] importNames;
    public FunctionHandle[] independentConstructors;
    public FunctionHandle[] sharedConstructors;
    public FunctionHandle[] threadConstructors;
    public FunctionHandle[] sharedDestructors;
    public FunctionHandle[] threadDestructors;
    public FunctionHandle[] unitTests;
    // The `crt_constructor` and `crt_destructor` functions of the module.
    public FunctionHandle[] crtConstructors;
    public FunctionHandle[] crtDestructors;
    // dmd's glue layer increments the gate of each destructor of a template
    // instance while it runs the constructors of the module: the destructor
    // body returns early unless it brings the gate back to zero.
    public GateStorage[] sharedGates;
    public GateStorage[] threadGates;

    // Calls `visit` with each function handle of the module.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (handles; [independentConstructors, sharedConstructors,
                threadConstructors, sharedDestructors, threadDestructors,
                unitTests, crtConstructors, crtDestructors])
            foreach (handle; handles)
                visit(handle);
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
    // Whether the program has a `main`.
    public bool present;
    public bool returnsVoid;
    // The number of parameters `main` declares.
    public size_t parameterCount;
    public FunctionHandle function_;
}


// The modules of the dependency image that a program runs on, or none.
public const(ModuleInfo*)[] dependencyModulesOf(
    in imported!"snakebite.image.dependency".DependencyImage* image,
) {
    return image is null ? null : image.deferredModules;
}


public struct StartData {
    public string programName;
    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it.
    public bool hasCEntryPoint;
    public bool betterC;
    // One record for each root module, in the order of the constructors. A
    // backend decides where each record lives (see `buildStartData`).
    public ModuleStart*[] modules;
    public const(ModuleInfo*)[] dependencyModules;
    public MainStart main;

    // The `crt_constructor` and `crt_destructor` functions of the program, in
    // the order of the modules, which is the order of the constructors.
    public bool hasCrtConstructors() const {
        foreach (module_; modules)
            if (module_.crtConstructors.length)
                return true;
        return false;
    }

    public bool hasCrtDestructors() const {
        foreach (module_; modules)
            if (module_.crtDestructors.length)
                return true;
        return false;
    }

    // The array of the whole program, made once for the phase that runs it.
    public FunctionHandle[] crtConstructors() {
        FunctionHandle[] all;
        foreach (module_; modules)
            all ~= module_.crtConstructors;
        return all;
    }

    // The destructors in the reverse order of `crtConstructors`.
    public FunctionHandle[] crtDestructorsReversed() {
        FunctionHandle[] all;
        foreach_reverse (module_; modules)
            foreach_reverse (function_; module_.crtDestructors)
                all ~= function_;
        return all;
    }

    // Calls `visit` with each function handle of the program.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (module_; modules)
            module_.eachHandle(visit);
        if (main.present)
            visit(main.function_);
    }
}
