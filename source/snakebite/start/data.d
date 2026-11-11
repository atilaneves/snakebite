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


// The storage of one gate variable (see `ModuleStart.sharedGates`).
public alias GateStorage = void[];


public struct ModuleStart {
    public string name;
    // Whether druntime orders the module: false when it has nothing to
    // construct or destruct.
    public bool standalone;
    // The positions in `StartData.modules` of the modules this module imports
    // that have a record.
    public size_t[] imports;
    // The names of every module this module imports, for the records of a
    // dependency image. Empty when the program has no dependency image.
    public string[] importNames;
    public FunctionHandle[] independentConstructors;
    public FunctionHandle[] sharedConstructors;
    public FunctionHandle[] threadConstructors;
    public FunctionHandle[] sharedDestructors;
    public FunctionHandle[] threadDestructors;
    public FunctionHandle[] unitTests;
    // dmd's glue layer increments the gate of each destructor of a template
    // instance while it runs the constructors of the module: the destructor
    // body returns early unless it brings the gate back to zero.
    public GateStorage[] sharedGates;
    public GateStorage[] threadGates;

    // Calls `visit` with each function handle of the module.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (handles; [independentConstructors, sharedConstructors,
                threadConstructors, sharedDestructors, threadDestructors,
                unitTests])
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
    // In the order of the modules, which is the order of the constructors.
    public FunctionHandle[] crtConstructors;
    public FunctionHandle[] crtDestructors;
    public const(ModuleInfo*)[] dependencyModules;
    public MainStart main;

    // Calls `visit` with each function handle of the program.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (module_; modules)
            module_.eachHandle(visit);
        foreach (handles; [crtConstructors, crtDestructors])
            foreach (handle; handles)
                visit(handle);
        if (main.present)
            visit(main.function_);
    }
}
