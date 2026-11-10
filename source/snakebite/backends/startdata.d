module snakebite.backends.startdata;


private:


// What the start of a guest program needs, with no frontend data in it: the
// modules, their phases and the order of their imports, the gate storage,
// the `crt_constructor` and `crt_destructor` functions, and `main` with the
// way to call it. A backend builds it (`buildStartData`); `GuestModules` and
// `runMain` run on it only.

// What a backend gives out to name a function. It means nothing outside the
// backend that made it, and that backend decides when the function is
// compiled.
public abstract class FunctionHandle {
}


// A function as the backend that built the start data names it.
public struct CompiledFunction {
    import snakebite.backends.backend: Backend;

    public FunctionHandle handle;

    public void call(
        Backend backend, void* returnPlace, void*[] args,
    ) const {
        backend.callCompiled(cast() handle, returnPlace, args);
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
    public CompiledFunction[] independentConstructors;
    public CompiledFunction[] sharedConstructors;
    public CompiledFunction[] threadConstructors;
    public CompiledFunction[] sharedDestructors;
    public CompiledFunction[] threadDestructors;
    public CompiledFunction[] unitTests;
    // dmd's glue layer increments the gate of each destructor of a template
    // instance while it runs the constructors of the module: the destructor
    // body returns early unless it brings the gate back to zero.
    public GateStorage[] sharedGates;
    public GateStorage[] threadGates;

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
    public CompiledFunction function_;
}


public struct StartData {
    public string programName;
    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it.
    public bool hasCEntryPoint;
    public bool betterC;
    public ModuleStart[] modules;
    // In the order of the modules, which is the order of the constructors.
    public CompiledFunction[] crtConstructors;
    public CompiledFunction[] crtDestructors;
    public const(ModuleInfo*)[] dependencyModules;
    public MainStart main;
}
