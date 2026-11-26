module snakebite.driver.execution;


private:


import std.typecons: Nullable;


public struct ExecutionReport {
    import core.time: Duration;
    import snakebite.backends.statistics: CompilationStatistics;

    public int status;
    // Everything from making the backend to the end of the program. The
    // durations below do not overlap and do not include compilation.
    public Duration latency;
    public Duration constructorDuration;
    public Duration moduleInfoDuration;
    // The unit tests and `main`.
    public Duration programDuration;
    public CompilationStatistics compilation;
}


public struct PreparationReport {
    import core.time: Duration;
    import snakebite.project.loading: Project;

    public Project project;
    // Finding out what to run the frontend on: `dub describe` for a dub
    // project, a directory scan otherwise.
    public Duration discovery;
    // The frontend itself: initialisation, parsing, semantic analysis.
    public Duration duration;
    public Duration imageDuration;
}


// What `PreparationReport.discovery` timed, for reports: dub itself for a
// dub project, a directory scan otherwise.
public string discoveryLabel(in PreparationReport report) {
    import snakebite.project.loading: isDubProject;

    return isDubProject(report.project.directory)
        ? "dub ovrhd"
        : "src scan";
}


// Runs `body` the way `dub test` runs the project: the frontend in the
// project directory, where dub builds, and the guest in the working
// directory of the recipe, or the project directory when it names none.
// Every front end that runs a project's code goes through here, and none
// chooses a directory. The directory is state of the whole process, so only
// a front end, never a function that a test calls on a thread, may set it.
// Paths of the caller become absolute first: they are relative to where the
// caller is. `body` gets the absolute project directory and a function that
// enters the working directory: it calls it before each run of the guest.
// `EndsProcess.yes` leaves the directory in place: the module destructors of
// the program run when the process ends and see the directory that its
// constructors and `main` saw.
public int runProject(
    in string projectDirectory,
    in string[] callerImportPaths,
    in string[] callerStringImportPaths,
    in string[] versions,
    in imported!"snakebite.project.loading".EndsProcess endsProcess,
    in int delegate(
        string,
        imported!"snakebite.project.dub".SourceSet,
        imported!"core.time".Duration,
        void delegate(),
    ) body,
) {
    import snakebite.project.loading: ProjectDirectory, sourceSet;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.path: absolutePath;

    const directory = projectDirectory.absolutePath;
    const importPaths = callerImportPaths.map!(path => path.absolutePath).array;
    const stringImportPaths =
        callerStringImportPaths.map!(path => path.absolutePath).array;
    auto stopWatch = StopWatch(AutoStart.yes);
    auto sources = sourceSet(directory, importPaths, stringImportPaths, versions);
    const discovery = stopWatch.peek;
    scope entered = ProjectDirectory(
        directory,
        sources.runDirectory(directory),
        endsProcess,
    );
    return body(directory, sources, discovery, &entered.enterWorking);
}


// Does not change the working directory: `runProject` does.
public PreparationReport prepareProject(
    in string directory,
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
    in bool nativeDependencies = true,
    in string[] versions = null,
    in imported!"snakebite.image.preparation".Optimise optimise
        = imported!"snakebite.image.preparation".Optimise.yes,
) {
    import snakebite.project.loading: sourceSet;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    // Finding the sources is not frontend work (for a dub project it is the dub
    // library, which starts the compiler too) and once
    // counted as frontend time it inflated that number by up to half.
    auto stopWatch = StopWatch(AutoStart.yes);
    auto sources = sourceSet(directory, importPaths, stringImportPaths, versions);
    return prepareSources(
        directory, sources, stopWatch.peek, nativeDependencies, optimise,
    );
}


public PreparationReport prepareSources(
    in string directory,
    imported!"snakebite.project.dub".SourceSet sources,
    in imported!"core.time".Duration discovery,
    in bool nativeDependencies = true,
    in imported!"snakebite.image.preparation".Optimise optimise
        = imported!"snakebite.image.preparation".Optimise.yes,
) {
    import snakebite.project.dependencies: prepareDependencies;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    auto stopWatch = StopWatch(AutoStart.yes);
    auto project = loadedProject(directory, sources, nativeDependencies);
    const frontendDuration = stopWatch.peek;
    stopWatch.reset;
    if (nativeDependencies)
        project.program.dependencyImage = prepareDependencies(
            project.directory, project.sources, () => project.program,
            optimise,
        );
    return PreparationReport(project, discovery, frontendDuration, stopWatch.peek);
}


// The frontend result of the project that `sources` describe, ready to run as
// a project.
public imported!"snakebite.project.loading".Project loadedProject(
    in string directory,
    imported!"snakebite.project.dub".SourceSet sources,
    in bool nativeDependencies,
) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import snakebite.project.loading: loadProject;

    initialize(Snippets.no);
    return loadProject(directory, sources, nativeDependencies);
}


// Runs `program` with the arguments `hostArguments`, its name first. A
// snippet is a program from the REPL or from a unit test of `sb`, which has
// no native equivalent: it runs its module constructors and `main` directly,
// with no unit tests.
public ExecutionReport executeBackend(
    in imported!"snakebite.backends".BackendName name,
    imported!"snakebite.backends".Program program,
    in string[] hostArguments,
    in bool collectGarbage = true,
    in bool endsProcess = false,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit =
        imported!"snakebite.backends.bytecode.vm".JitSetting.init,
    in bool isSnippet = false,
) {
    import snakebite.backends: makeBackend;
    import snakebite.image.dependency: testHooksOf;
    import std.datetime.stopwatch: AutoStart, StopWatch;

    import std.stdio: stdin, stdout, stderr;

    // Guest runners can replace thread-local streams. Host reports must
    // use the host's streams after execution, including exceptional exits.
    auto savedInput = stdin; // File references must remain mutable.
    auto savedOutput = stdout;
    auto savedError = stderr;
    scope(exit) {
        stdin = savedInput;
        stdout = savedOutput;
        stderr = savedError;
    }

    auto stopWatch = StopWatch(AutoStart.yes);
    auto backend = makeBackend(name, program, jit);
    import snakebite.backends.statistics: ExecutionClock;
    const running = ExecutionClock.start(backend.compilationStatistics);
    auto start = &backend.startData();
    return runStartData(
        *start, backend.compilationStatistics, running, stopWatch,
        program.dependencyImage.testHooksOf, isSnippet, hostArguments,
        collectGarbage, endsProcess);
}

// Compiles all of `program` and writes it to `path`; it runs nothing.
public void saveProgram(
    imported!"snakebite.backends".Program program,
    in string path,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit,
) {
    import snakebite.backends.api: Owned;
    import snakebite.backends.bytecode: Bytecode;

    const recordsAddresses = true;
    auto backend = Owned!Bytecode(new Bytecode(program, jit, recordsAddresses));
    backend.save(path);
}


// Loads the program that the file `path` holds and runs it as
// `executeBackend` runs a compiled one: the same `runStartData`, on a
// `Program` and a `Runner` that the file fills instead of a compiler. The
// program gets `arguments`, its name first, and runs in the working
// directory of the process, as an executable does. The file names the
// dependency image of the program, if it has one.
public ExecutionReport executeLoaded(
    in string path,
    in string[] arguments,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit,
) {
    import std.stdio: File;

    return executeLoaded(File(path, "rb"), arguments, jit, Nullable!string());
}


// As `executeLoaded` with the path, for the open program file `file`. The
// load reads it from its start. `imagePath` is the dependency image that the
// run gives to a file that names none, as a build does (`loadProgramFile`).
public ExecutionReport executeLoaded(
    imported!"std.stdio".File file,
    in string[] arguments,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit,
    in Nullable!string imagePath,
) {
    import snakebite.backends.statistics: CompilationStatistics, ExecutionClock;
    import snakebite.image.dependency: testHooksOf;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.stdio: stdin, stdout, stderr;

    auto stopWatch = StopWatch(AutoStart.yes);
    auto loaded = loadProgramFile(file, jit, imagePath);
    file.close;
    scope(exit) loaded.runner.end;

    auto savedInput = stdin;
    auto savedOutput = stdout;
    auto savedError = stderr;
    scope(exit) {
        stdin = savedInput;
        stdout = savedOutput;
        stderr = savedError;
    }

    CompilationStatistics compilation;
    const running = ExecutionClock.start(compilation);
    const isSnippet = false;
    const collectGarbage = false;
    const endsProcess = true;
    return runStartData(
        loaded.program.startData, compilation, running, stopWatch,
        loaded.image.testHooksOf, isSnippet, arguments, collectGarbage,
        endsProcess);
}


// A program that `loadProgramFile` read, with no compiler. Its owner ends the
// runner (`Runner.end`) when the program has run.
public struct LoadedProgram {
    import snakebite.backends.bytecode.file: Header;
    import snakebite.backends.bytecode.program: Program;
    import snakebite.backends.bytecode.runner: Runner;
    import snakebite.image.dependency: DependencyImage;

    public Header header;
    // Null when the program runs on no dependency image.
    public DependencyImage* image;
    public Program* program;
    public Runner* runner;
}


// Reads the program file `file`, from its start, into a new program wired to
// a new runner with `jit`. It does not change the working directory.
public LoadedProgram loadProgramFile(
    imported!"std.stdio".File file,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit,
    in Nullable!string imagePath,
) {
    import snakebite.failure.report: SnakebiteException;

    // `File.size` gives `ulong.max` for a file that cannot seek, such as a
    // pipe: the load checks each count against the size.
    const size = file.size;
    if (size == ulong.max)
        throw new SnakebiteException(
            "the program file has no size: it is not a file that can seek");
    static if (size_t.sizeof < ulong.sizeof)
        if (size > size_t.max)
            throw new SnakebiteException("the program file is too large");
    // The parts of the file go one after the other through this buffer.
    ubyte[64 * 1024] buffer = void;
    return loadProgramFile(file.byChunk(buffer[]), cast(size_t) size, jit,
        imagePath);
}


// Reads the program file whose bytes are `contents` into a new program wired
// to a new runner with `jit`. It does not change the working directory.
public LoadedProgram loadProgramFile(
    const(ubyte)[] contents,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit,
) {
    import std.range: only;

    return loadProgramFile(only(contents), contents.length, jit,
        Nullable!string());
}


// Reads the program file of `size` bytes that the input range `parts` gives,
// part after part, into a new program wired to a new runner with `jit`. A
// part stays valid until the range is advanced. The program runs on the
// dependency image that the file names (`--save` writes it, as an executable
// names its libraries), or on `imagePath`, which a run gives to a file that
// names none (a build does), or on none when neither is set. A file that
// names an image and a run that gives another are a conflict.
public LoadedProgram loadProgramFile(Parts)(
    Parts parts, in size_t size,
    in imported!"snakebite.backends.bytecode.vm".JitSetting jit,
    in Nullable!string imagePath,
) {
    import core.memory: GC;
    import snakebite.backends.bytecode.file: ProgramReader;
    import snakebite.backends.bytecode.program: Program;
    import snakebite.backends.bytecode.runner: Runner, wire;
    import snakebite.failure.report: SnakebiteException;
    import snakebite.image.dependency: DependencyImage, loadImage;
    import snakebite.image.preparation: generatorKey;

    // The part that `next` gave stays valid until the next call.
    static struct Source {
        Parts parts;
        bool started;

        const(ubyte)[] next() {
            if (started)
                parts.popFront;
            started = true;
            return parts.empty ? null : parts.front;
        }
    }

    // A load starts no GC collection. The file gives the size of the memory
    // of the program, and the program keeps what the load takes, so a
    // collection would give back almost nothing. The GC collects when it
    // needs a new pool until its first collection has set its thresholds.
    GC.disable;
    scope(exit) GC.enable;
    auto source = Source(parts);
    auto reader = ProgramReader(&source.next, size);
    LoadedProgram loaded;
    loaded.header = reader.header;
    if (loaded.header.buildKey != generatorKey)
        throw new SnakebiteException(
            "the program file was written by another build of snakebite");

    // On the GC heap, as the image of a compile is: the program and its call
    // plans and tables of thread-local variables refer to it until the
    // module destructors have run, after a run returns.
    if (!loaded.header.imagePath.isNull && !imagePath.isNull)
        throw new SnakebiteException(
            "the program file names a dependency image and the run gives one");
    const image = loaded.header.imagePath.isNull
        ? imagePath : loaded.header.imagePath;
    if (!image.isNull) {
        loaded.image = new DependencyImage;
        *loaded.image = loadImage(image.get);
    }

    // On the GC heap, as the backend of a compile is: the module destructors
    // run when the process ends, after a run returns, and callback entries
    // reach the program and the runner until then.
    loaded.program = new Program(loaded.image);
    loaded.runner = cast(Runner*) GC.calloc(Runner.sizeof);
    wire(*loaded.program, *loaded.runner, jit);
    scope(failure) loaded.runner.end;
    reader.load(*loaded.program, *loaded.runner, loaded.image);
    return loaded;
}


// Runs the program of `start` and reports on it. `running` began before the
// backend made `start`, and `latency` before the backend was made. It takes
// no backend: whatever made `start` and `compilation`, compiled or loaded,
// can call it. A program that is not a snippet runs its unit tests under the
// runner that `testHooks` hold. The function holds the
// `GuestModules.Entry` of `start` until it returns, as the runtime of a
// program with a C entry point ends with it.
ExecutionReport runStartData(
    ref imported!"snakebite.start.data".StartData start,
    ref const imported!"snakebite.backends.statistics".CompilationStatistics
        compilation,
    in imported!"snakebite.backends.statistics".ExecutionClock running,
    ref imported!"std.datetime.stopwatch".StopWatch latency,
    in imported!"snakebite.image.dependency".TestHooks testHooks,
    in bool isSnippet,
    in string[] hostArguments,
    in bool collectGarbage,
    in bool endsProcess,
) {
    import core.memory: GC;
    import snakebite.run.modules: GuestModules;
    import snakebite.run.program: run, StartupReport, runDruntimeMain;

    const entry = GuestModules.Entry(start, compilation);
    StartupReport startup;
    int status;
    // A program with a C `main` runs no unit tests either.
    if (isSnippet || start.hasCEntryPoint || start.betterC)
        status = run(start, compilation, hostArguments);
    else {
        startup = runDruntimeMain(
            start, compilation, testHooks, hostArguments, endsProcess);
        status = startup.status;
    }
    const programDuration = running.peek
        - startup.constructorDuration - startup.moduleInfoDuration;
    // Native objects can hold callback entries for guest destructors. Run
    // their finalizers while the backend and the frontend declarations that
    // those entries name are still alive.
    if (collectGarbage)
        GC.collect;
    return ExecutionReport(
        status,
        latency.peek,
        startup.constructorDuration,
        startup.moduleInfoDuration,
        programDuration,
        compilation,
    );
}
