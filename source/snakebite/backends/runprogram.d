module snakebite.backends.runprogram;


private:


import snakebite.backends.api: Backend;
import snakebite.start.data: StartData;


// "Run on this project": do what a compiled build of it does, implemented
// once on top of the start data, and return the exit status. A `Throwable`
// that escapes `main` is handled as druntime would handle it: printed, exit
// status 1. The module constructors and destructors belong to druntime
// (`GuestModules`): it orders them, runs them on each thread, and prints
// what a destructor throws.
public int run(
    Backend backend,
    in string[] hostArguments = null,
) {
    import snakebite.backends.guestmodules: GuestModules;

    // A C `main` starts no druntime: no module constructor or destructor
    // of a D module runs.
    auto start = &backend.startData();
    if (start.hasCEntryPoint || start.betterC)
        return runMain(backend, *start, hostArguments);

    auto modules = GuestModules.start(
        backend, GuestModules.Tests.no, GuestModules.Ends.program);
    if (modules.failed)
        return 1;

    const status = runMain(backend, *start, hostArguments);
    const destructorStatus = modules.finish;
    return status != 0 ? status : destructorStatus;
}

// The program's own `main`. `void main` maps to exit status 0, and no `main`
// at all is not an error: the status is 0.
package(snakebite) int runMain(
    Backend backend,
    StartData start,
    in string[] hostArguments,
) {
    if (!start.main.present)
        return 0;

    int status;
    string[] arguments;
    void*[] mainArguments;
    CArguments cArguments;
    if (start.hasCEntryPoint) {
        arguments = hostArguments.length
            ? hostArguments.dup : [start.programName];
        cArguments = CArguments(arguments);
        mainArguments = cArguments.of(start.main.parameterCount);
    } else if (start.main.parameterCount != 0) {
        arguments = hostArguments.length
            ? hostArguments.dup
            : [start.programName];
        mainArguments = [cast(void*) &arguments];
    }
    return failing(() {
        start.main.function_.call(
            start.main.returnsVoid ? null : &status, mainArguments);
    }) ? 1 : status;
}

// The values a C `main` takes, in the order the C runtime passes them:
// `argc`, `argv` and the environment.
private struct CArguments {
    private int _argc;
    private char*[] _storage;
    private char** _argv;
    private char** _environment;

    this(in string[] arguments) {
        import core.sys.posix.unistd: environ;
        import std.algorithm.iteration: map;
        import std.array: array;
        import std.string: toStringz;

        _argc = cast(int) arguments.length;
        _storage = arguments.map!(argument => cast(char*) argument.toStringz)
            .array ~ null;
        _argv = _storage.ptr;
        _environment = cast(char**) environ;
    }

    // The address of each of the first `count` arguments.
    void*[] of(in size_t count) {
        void*[3] all = [
            cast(void*) &_argc, cast(void*) &_argv, cast(void*) &_environment,
        ];
        return all[0 .. count].dup;
    }
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
