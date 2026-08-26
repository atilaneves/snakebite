module snakebite.backends.backend;


private:


// The root modules of the guest program, parsed and semantically analysed by
// the frontend, and its entry point. A dub project is not special: a
// dub-aware driver asks dub for import paths and flags and builds one of
// these.
public struct Program {
    // The program's entry point, and who wrote it. `func` is null when the
    // program has no `main` at all, which is not an error: a bare directory
    // of `.d` files can be a library.
    struct Main {
        // What a backend may do with this `main`.
        //
        // A `main` a human wrote is the program. Running anything else
        // instead changes what the program does, so no backend may
        // substitute it: it runs, or the backend fails.
        //
        // dub's generated test root is not the program. dub writes it
        // outside the project - into its own cache, so the module is in no
        // source tree the user has - purely as scaffolding whose contract is
        // "run every unittest". Any driver that runs every unittest honours
        // that contract, so a backend may stand in for it; `run` does, for
        // every backend.
        enum Kind {
            program,
            dubTestRunner,
        }

        imported!"dmd.func".FuncDeclaration func;
        Kind kind;
    }

    imported!"dmd.dmodule".Module[] rootModules;
    Main main;

    // The entry point is found the way a compiled build finds it: the first
    // root module declaring a module-level `main`. The module that declares
    // it also says which kind it is - dub names its generated test root
    // `dub_test_root`, and nothing else may claim that name, since dub owns
    // it in every project it generates one for.
    this(imported!"dmd.dmodule".Module[] rootModules) {
        import snakebite.frontend.dmd.functions: findFunction;

        this.rootModules = rootModules;

        foreach (module_; rootModules) {
            auto found = findFunction(module_, "main");
            if (found !is null) {
                main = Main(
                    found,
                    module_.ident.toString == "dub_test_root"
                        ? Main.Kind.dubTestRunner
                        : Main.Kind.program,
                );
                break;
            }
        }
    }
}


public abstract class Backend {
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // Invoke one guest function. `args` and the value written to
    // `returnPlace` are in native layout, exactly as compiled D would lay
    // them out; `returnPlace` must be exactly the return type's size, and
    // `null` means the result is discarded (e.g. a `void` function, or a
    // caller that does not need the value). Type information travels only
    // through `function_`'s dmd type, not through the untyped `void*[]`.
    //
    // A guest failure (a failed assert, an uncaught guest exception) throws
    // a host exception, the same as `eval`.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    public abstract void call(
        FuncDeclaration function_, void* returnPlace, void*[] args,
    );

    // Execute one synthesised `string`-returning function and return its
    // result. The guest renders the value itself (`std.conv.text`), so the
    // returned string is a natively laid out value like any other; nothing
    // is boxed or marshalled. A `Throwable` that escapes propagates to the
    // caller.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    //
    // Collapses into `call` once `call` can return a native `string`.
    public abstract string eval(FuncDeclaration function_);
}

// "Run on this project": do what a compiled build of it does, implemented
// once on top of `call`, and return the exit status. A `Throwable` that
// escapes is handled as druntime would handle it: printed, exit status 1.
public int run(Backend backend, Program program) {
    alias Kind = Program.Main.Kind;

    final switch (program.main.kind) {
        case Kind.program:
            return runMain(backend, program.main.func);
        case Kind.dubTestRunner:
            return runUnittests(backend, program.rootModules);
    }
}

// The program's own `main`. `void main` maps to exit status 0, and no `main`
// at all is not an error: the status is 0.
private int runMain(
    Backend backend,
    imported!"dmd.func".FuncDeclaration main_,
) {
    import dmd.astenums: Tvoid;

    if (main_ is null)
        return 0;

    const isVoid = main_.type.nextOf.ty == Tvoid;
    int status;
    return failing(() {
        backend.call(main_, isVoid ? null : &status, []);
    }) ? 1 : status;
}

// Stand in for dub's generated test root by doing what it stands on:
// druntime's own default runner. `_d_run_main` calls `runModuleUnitTests`
// (rt.dmain2) before `main` is ever entered, and that walks `ModuleInfo`
// calling each module's generated `__modtest`, which runs every unittest in
// the module - nested ones included, not just the module-level ones dub's
// `-betterC` branch reaches through `__traits(getUnitTests)`. The order is
// druntime's: module by module, declaration by declaration.
//
// A failing unittest stops the run and fails the process, as druntime does.
// Nothing is printed on success: that message belongs to dub's `main`, not
// to the runner, and printing it would need I/O no backend has to have.
private int runUnittests(
    Backend backend,
    imported!"dmd.dmodule".Module[] rootModules,
) {
    import snakebite.frontend.dmd.functions: findUnittests;

    foreach (module_; rootModules)
        foreach (unittest_; findUnittests(module_))
            if (failing(() { backend.call(unittest_, null, []); }))
                return 1;

    return 0;
}

// Runs one guest call, reporting an escaping `Throwable` the way druntime
// reports one out of `main`: the message on stderr, and the process fails.
private bool failing(scope void delegate() call) {
    import core.stdc.stdio: fprintf, stderr;
    import std.string: toStringz;

    try
        call();
    catch (Throwable throwable) {
        fprintf(stderr, "%s\n", throwable.msg.toStringz);
        return true;
    }

    return false;
}
