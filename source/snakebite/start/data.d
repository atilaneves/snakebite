module snakebite.start.data;


private:


import std.typecons: Nullable;


// The start data of a guest program: what a backend gives to the runner
// (`snakebite.run`) to start the program, with no frontend data in it. A
// `ModuleStart` holds what one root module contributes: its constructors,
// destructors, unit tests and `main`, and the names of the modules that it
// imports. A backend makes each one from its module alone. `StartData` holds
// them for the root modules of the program, and what follows from them for
// the whole program: which `main` runs, and whether it is the C entry point.
// A backend builds it (`buildStartData`); `GuestModules` and `runMain` run on
// it only. See "Start data" in `CONTEXT.md`.

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
    public Nullable!MainStart main;

    // Calls `visit` with each function handle of the module.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (handles; [independentConstructors, sharedConstructors,
                threadConstructors, sharedDestructors, threadDestructors,
                unitTests, crtConstructors, crtDestructors])
            foreach (handle; handles)
                visit(handle);
        if (!main.isNull)
            visit(main.get.function_);
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
    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it: druntime does not start, so a build with unit tests runs
    // none of them and no module constructor, and the program is only
    // that function.
    public bool cLinkage;
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
    public bool betterC;
    // The `ModuleStart` of each root module, in the order of the root
    // modules. A backend decides where each one lives (see
    // `buildStartData`).
    public ModuleStart*[] modules;
    public const(ModuleInfo*)[] dependencyModules;

    // The `main` of the program. `Program` rejects more than one, so the
    // modules have one at most.
    public Nullable!MainStart main() @safe pure nothrow @nogc {
        foreach (module_; modules)
            if (!module_.main.isNull)
                return module_.main;
        return Nullable!MainStart.init;
    }

    // Whether the `main` of the program is the C entry point (see
    // `MainStart.cLinkage`).
    public bool hasCEntryPoint() @safe pure nothrow @nogc {
        const main_ = main;
        return !main_.isNull && main_.get.cLinkage;
    }

    // Calls `visit` with each function handle of the program.
    public void eachHandle(scope void delegate(FunctionHandle) visit) {
        foreach (module_; modules)
            module_.eachHandle(visit);
    }
}
