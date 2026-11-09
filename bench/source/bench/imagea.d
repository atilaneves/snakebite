module bench.imagea;

import snakebite.backends.bytecode.imagea:
    saveImageBundleA, loadImageBundleA, runImageA;
import std.datetime.stopwatch: StopWatch;
import std.stdio: writeln;
import std.file: readText, write;

public int run(string[] args) {
    if (args.length == 7)
        return compareCalls(args);
    import std.exception: enforce;
    import std.conv: to, text;
    enforce(args.length >= 4,
        "bench --sbc-a-save source.d image [count] | --sbc-a-load image x y");
    import snakebite.gc: selectFrontendMemory;
    selectFrontendMemory(false);
    StopWatch watch;
    watch.start;
    if (args[1] == "--sbc-a-save" || args[1] == "--sbc-a-baseline") {
        import snakebite.frontend.compiler: initialize, Snippets, parseSnippet;
        import snakebite.frontend.dmd.functions: findFunction;
        import snakebite.backends.backend: Program, Owned;
        import snakebite.backends.bytecode.compiler: Bytecode;
        initialize(Snippets.yes);
        auto module_ = parseSnippet(readText(args[2]));
        const frontend = watch.peek.total!"nsecs";
        auto backend = Owned!Bytecode(Program([module_]));
        import snakebite.backends.bytecode.vm: Function;
        const count = args.length > 4 ? args[4].to!size_t : 1;
        const(Function)*[] functions;
        foreach (index; 0 .. count)
            functions ~= backend.compileImageFunction(findFunction(module_,
                index == 0 ? "arithmetic" : text("arithmetic", index)),
                args[1] != "--sbc-a-baseline");
        const compile = watch.peek.total!"nsecs" - frontend;
        const full = watch.peek.total!"nsecs";
        watch.reset;
        if (args[1] == "--sbc-a-save")
            write(args[3], saveImageBundleA(functions));
        const save = watch.peek.total!"nsecs";
        watch.reset;
        ulong checksum;
        if (args[1] == "--sbc-a-baseline")
            foreach (function_; functions)
                foreach (pair; [[7UL, 11UL], [0UL, 1UL], [123UL, 456UL],
                        [ulong.max, 1UL], [ulong.max, ulong.max]])
                    checksum += runImageA(*function_, pair[0], pair[1]);
        writeln("frontend_ns=", frontend, " compile_ns=", compile,
            " full_ns=", full, " save_ns=", save,
            " execution_ns=", watch.peek.total!"nsecs",
            " checksum=", checksum, " functions=", functions.length);
    } else {
        enforce(args[1] == "--sbc-a-load" && args.length >= 4,
            "bench --sbc-a-load image all | image x y");
        const functions = loadImageBundleA(args[2]);
        const load = watch.peek.total!"nsecs";
        watch.reset;
        ulong checksum;
        if (args[3] == "all") {
            foreach (ref function_; functions)
                foreach (pair; [[7UL, 11UL], [0UL, 1UL], [123UL, 456UL],
                        [ulong.max, 1UL], [ulong.max, ulong.max]])
                    checksum += runImageA(function_, pair[0], pair[1]);
        } else {
            enforce(args.length == 5, "bench --sbc-a-load image x y");
            const x = args[3].to!ulong;
            const y = args[4].to!ulong;
            foreach (ref function_; functions)
                checksum += runImageA(function_, x, y);
        }
        writeln("load_ns=", load, " execution_ns=", watch.peek.total!"nsecs",
            " checksum=", checksum, " functions=", functions.length);
    }
    return 0;
}

private int compareCalls(string[] args) {
    import std.conv: to;
    import std.string: split;
    import std.exception: enforce;
    import snakebite.backends.bytecode.vm: Function;
    import snakebite.backends.bytecode.relocation: recordRelocs;
    const mode = args[6];
    enforce(mode == "baseline" || mode == "save" || mode == "load",
        "comparison mode must be baseline, save, or load");
    const rounds = args[5].to!size_t;
    enforce(rounds > 0, "comparison rounds must be positive");
    const groups = args[4].split(";");
    const names = groups[0].split(",");
    const callees = groups.length > 1 ? groups[1].split(",") : null;
    const previous = recordRelocs;
    recordRelocs = mode == "save";
    scope(exit) recordRelocs = previous;
    StopWatch watch;
    watch.start;
    const(Function)*[] roots;
    Function[] loaded;
    long setup, frontend, entryCompile, preparation, full, saving, load;
    long diagnosticBundleNs, diagnosticWriteNs;
    size_t bodies, bytes;
    if (mode == "load") {
        loaded = loadImageBundleA(args[3]);
        enforce(loaded.length == names.length, "wrong root count");
        foreach (ref function_; loaded)
            roots ~= &function_;
        load = watch.peek.total!"nsecs";
    } else {
        import snakebite.frontend.compiler: initialize, Snippets, parseSnippet;
        import snakebite.frontend.dmd.functions: findFunction;
        import snakebite.backends.backend: Program, Owned;
        import snakebite.backends.bytecode.compiler: Bytecode;
        import snakebite.gc: selectFrontendMemory;
        selectFrontendMemory(false);
        initialize(Snippets.yes);
        setup = watch.peek.total!"nsecs";
        auto module_ = parseSnippet(readText(args[2]));
        frontend = watch.peek.total!"nsecs" - setup;
        auto backend = Owned!Bytecode(Program([module_]));
        foreach (name; names)
            roots ~= backend.compileImageFunction(findFunction(module_, name),
                mode == "save");
        const entryEnd = watch.peek.total!"nsecs";
        entryCompile = entryEnd - setup - frontend;
        foreach (name; callees)
            backend.compileImageFunction(findFunction(module_, name), mode == "save");
        bodies = names.length + callees.length;
        full = watch.peek.total!"nsecs";
        preparation = full - entryEnd;
        const saveStart = full;
        if (mode == "save") {
            const misses = backend.compilationStatistics.cacheMisses;
            StopWatch diagnosticTimer;
            diagnosticTimer.start;
            const image = saveImageBundleA(roots);
            diagnosticBundleNs = diagnosticTimer.peek.total!"nsecs";
            enforce(backend.compilationStatistics.cacheMisses == misses,
                "comparison callee list missed a compiled body");
            enforce(image.length >= 16
                && *cast(const(size_t)*) image.ptr == bodies,
                "comparison callee list has the wrong body count");
            bytes = image.length;
            diagnosticTimer.reset;
            write(args[3], image);
            diagnosticWriteNs = diagnosticTimer.peek.total!"nsecs";
        }
        saving = watch.peek.total!"nsecs" - saveStart;
    }
    const compileSave = mode == "load" ? 0 : watch.peek.total!"nsecs";
    watch.reset;
    ulong checksum;
    if (mode != "save") {
        foreach (_; 0 .. rounds)
            foreach (function_; roots)
                foreach (pair; [[7UL, 11UL], [0UL, 1UL], [123UL, 456UL],
                        [ulong.max, 1UL], [ulong.max, ulong.max]]) {
                    checksum += runImageA(*function_, pair[0], pair[1]);
                }
    }
    const execution = watch.peek.total!"nsecs";
    writeln("setup_ns=", setup, " frontend_ns=", frontend,
        " entry_compile_ns=", entryCompile, " preparation_ns=", preparation,
        " full_compile_ns=", full, " save_ns=", saving,
        " compile_save_ns=", compileSave, " load_ns=", load,
        " execution_ns=", execution, " checksum=", checksum,
        " roots=", roots.length, " bodies=", bodies,
        " bytes=", bytes, " rounds=", rounds);
    import snakebite.backends.bytecode.imagea: diagnosticPhases;
    import snakebite.backends.bytecode.vm: diagnosticImageHandlerNs;
    writeln("diagnostic_handler_ns=", diagnosticImageHandlerNs,
        " bundle_ns=", diagnosticBundleNs, " write_ns=", diagnosticWriteNs,
        " phases=", diagnosticPhases);
    return 0;
}
