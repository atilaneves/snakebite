module snakebite.backends.backend;


private:


// The root modules of the guest program, parsed and semantically analysed by
// the frontend, and its entry point. A dub project is not special: a
// dub-aware driver asks dub for import paths and flags and builds one of
// these.
public struct Program {
    // `func` is null when the program has no `main`, which is not an error: a
    // bare directory of `.d` files can be a library.
    struct Main {
        imported!"dmd.func".FuncDeclaration func;
    }

    imported!"dmd.dmodule".Module[] rootModules;
    imported!"dmd.func".FuncDeclaration[] moduleConstructors;
    Main main;

    // The entry point is found the way a compiled build finds it: the first
    // root module declaring a module-level `main`.
    this(imported!"dmd.dmodule".Module[] rootModules) {
        import snakebite.frontend.dmd.functions:
            findFunction,
            findModuleConstructors;

        this.rootModules = rootModules;
        foreach (module_; rootModules)
            moduleConstructors ~= findModuleConstructors(module_);

        foreach (module_; rootModules) {
            auto found = findFunction(module_, "main");
            if (found !is null) {
                main = Main(found);
                break;
            }
        }
    }

    public bool isInterpreted(
        imported!"dmd.func".FuncDeclaration function_,
    ) const {
        if (function_ is null)
            return false;

        const module_ = function_.getModule;
        foreach (rootModule; rootModules)
            if (module_ is rootModule)
                return true;

        return false;
    }
}


// Cumulative work done by a backend's compiler. A backend without a
// compilation phase leaves `hasCompiler` false; this is distinct from a
// compiler whose measured duration is zero.
public struct CompilationStatistics {
    bool hasCompiler;
    size_t cacheMisses;
    imported!"core.time".Duration duration;
}


public abstract class Backend {
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // The program this backend runs. Whether a callee is interpreted or
    // called natively is the program's one decision (`isInterpreted`),
    // so every backend is constructed knowing which program it runs.
    protected const Program _program;

    protected this(const Program program) {
        _program = program;
    }

    // Read-only cumulative statistics. Backends without a compilation phase
    // use the default empty result.
    public CompilationStatistics compilationStatistics() const {
        return CompilationStatistics.init;
    }

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
    if (runModuleConstructors(backend, program.moduleConstructors))
        return 1;

    return runMain(backend, program.main.func);
}

// Constructors that require code from a dependency image cannot run in the
// interpreter until that image exists. Keep running the program, but report
// every skipped constructor loudly so it cannot look like successful startup.
private int runModuleConstructors(
    Backend backend,
    imported!"dmd.func".FuncDeclaration[] constructors,
) {
    import snakebite.exception: SnakebiteException;
    import std.stdio: stderr;

    foreach (constructor; constructors) {
        try
            backend.call(constructor, null, []);
        catch (SnakebiteException exception) {
            stderr.writeln(
                "snakebite: skipping module constructor `",
                constructor.toString,
                "`: ",
                exception.msg,
            );
        }
        catch (Throwable throwable) {
            stderr.writeln(
                "snakebite: module constructor `",
                constructor.toString,
                "` failed: ",
                throwable.msg,
            );
            return 1;
        }
    }

    return 0;
}

// The program's own `main`. `void main` maps to exit status 0, and no `main`
// at all is not an error: the status is 0.
private int runMain(
    Backend backend,
    imported!"dmd.func".FuncDeclaration main_,
) {
    import dmd.astenums: Tvoid;
    import dmd.typesem: nextOf;

    if (main_ is null)
        return 0;

    const isVoid = main_.type.nextOf.ty == Tvoid;
    int status;
    return failing(() {
        backend.call(main_, isVoid ? null : &status, []);
    }) ? 1 : status;
}

// Runs one guest call, reporting an escaping `Throwable` the way druntime
// reports one out of `main`: the message on stderr, and the process fails.
private bool failing(scope void delegate() call) {
    import core.stdc.stdio: fprintf, stderr;
    import std.string: toStringz;

    try
        call();
    catch (Throwable throwable) {
        fprintf(stderr, "%s\nat %s:%llu\n",
            throwable.msg.toStringz,
            throwable.file.toStringz,
            throwable.line,
        );
        return true;
    }

    return false;
}
