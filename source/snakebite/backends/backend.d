module snakebite.backends.backend;


private:


// The root modules of the guest program, parsed and semantically analysed by
// the frontend. A dub project is not special: a dub-aware driver asks dub for
// import paths and flags and builds one of these.
public struct Program {
    imported!"dmd.dmodule".Module[] rootModules;
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

    // Whether guest programs run here can rely on druntime being present
    // (module info, its unittest runner, I/O). Presumed true unless a
    // backend overrides this. A backend that answers false cannot run a
    // program whose `main` delegates work to druntime, such as dub's
    // generated test root, which drives unittests through druntime's
    // ModuleInfo runner rather than calling them itself; a driver that needs
    // those unittests to actually run must substitute a program that does
    // not depend on druntime instead.
    public bool hasDruntime() {
        return true;
    }
}

// "Run on this project": run `main` the way compiled D does, implemented
// once on top of `call`, and return the exit status. A test build is not
// special: as with `dub test` or `dmd -unittest`, whatever runs the
// unittests (druntime's runner, unit-threaded's) is itself the program's
// `main`. `void main` maps to exit status 0. A `Throwable` that escapes is
// handled as druntime would handle it: printed, exit status 1. No `main`
// found is not an error: the status is 0.
public int run(Backend backend, Program program) {
    import core.stdc.stdio: fprintf, stderr;
    import dmd.astenums: Tvoid;
    import snakebite.frontend.dmd.functions: findFunction;
    import std.string: toStringz;

    foreach (module_; program.rootModules) {
        auto main_ = findFunction(module_, "main");
        if (main_ is null)
            continue;

        const isVoid = main_.type.nextOf.ty == Tvoid;
        int status;
        try
            backend.call(main_, isVoid ? null : &status, []);
        catch (Exception exception) {
            fprintf(stderr, "%s\n", exception.msg.toStringz);
            return 1;
        }
        return status;
    }

    return 0;
}
