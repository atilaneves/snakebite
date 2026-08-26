module snakebite.backends.backend;


private:


// What compiled D would have as the inputs to a link: the root modules
// (parsed and semantically analysed by the frontend), the compiled images
// the guest calls into via FFI, and the arguments `main` receives. A dub
// project is not special: a dub-aware driver asks dub for import paths,
// flags and libraries and builds one of these.
public struct Program {
    imported!"dmd.dmodule".Module[] rootModules;
    string[] sharedLibraries;
    string[] args;
}


public interface Backend {
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // "Run on this project": do what compiled D does for the program (module
    // constructors, unittests according to `--DRT-testmode`, `main`) and
    // return the exit status. A `Throwable` that escapes is handled as
    // druntime would handle it: printed, exit status 1.
    //
    // A non-null `entryPoint` runs that one function instead of `main`, e.g.
    // a single unittest. The function is then called directly, so attributes
    // that a custom test runner (unit-threaded's `@ShouldFail` and friends)
    // would interpret are not honoured.
    public int run(Program program, FuncDeclaration entryPoint = null);

    // Execute one synthesised `string`-returning function and return its
    // result. The guest renders the value itself (`std.conv.text`), so the
    // returned string is a natively laid out value like any other; nothing
    // is boxed or marshalled. A `Throwable` that escapes propagates to the
    // caller.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    public string eval(FuncDeclaration function_);
}
