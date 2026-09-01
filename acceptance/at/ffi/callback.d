module at.ffi.callback;


import unit_threaded;
import snakebite.backends.backend: Program;
import snakebite.backends.interpreter: Interpreter;
import snakebite.ffi: LibffiCallback;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


private alias Native = extern(C) int function(int);


private extern(C) int invoke(Native callback, int value) {
    return callback(value);
}


@("nativeToInterpreted.callbackRace")
@Flaky(5)
@Tags("timing", "ffi")
unittest {
    import std.algorithm: sort;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.stdio: writefln;

    auto module_ = parseSnippet(q{
        int increment(int value) {
            return value + 1;
        }
    });
    auto function_ = findFunction(module_, "increment");
    auto backend = new Interpreter(Program([module_]));
    auto fixedCallback = backend.callback(function_);
    auto libffiCallback = LibffiCallback(backend.callbackTarget(function_));
    auto fixed = cast(Native) fixedCallback.functionPointer;
    auto libffi = cast(Native) libffiCallback.functionPointer;

    enum calls = 100_000;
    foreach (_; 0 .. 1_000) {
        invoke(fixed, 41);
        invoke(libffi, 41);
    }

    double[5] fixedTimes;
    double[5] libffiTimes;
    int result;
    size_t sink;
    foreach (sample; 0 .. fixedTimes.length) {
        auto fixedWatch = StopWatch(AutoStart.no);
        auto libffiWatch = StopWatch(AutoStart.no);

        fixedWatch.start;
        foreach (_; 0 .. calls)
            result = invoke(fixed, 41);
        fixedWatch.stop;

        libffiWatch.start;
        foreach (_; 0 .. calls)
            result = invoke(libffi, 41);
        libffiWatch.stop;

        fixedTimes[sample] = fixedWatch.peek.total!"nsecs"
            / cast(double) calls;
        libffiTimes[sample] = libffiWatch.peek.total!"nsecs"
            / cast(double) calls;
        sink += cast(size_t) result;
    }
    sort(fixedTimes[]);
    sort(libffiTimes[]);

    writefln(
        "  fixed trampoline %5.2f ns, libffi closure %5.2f ns, ratio %4.1fx",
        fixedTimes[2], libffiTimes[2], libffiTimes[2] / fixedTimes[2],
    );
    result.should == 42;
    assert(sink != 0);
}
