module ut.loaded;


import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.bytecode.inspection: functionAt;
import snakebite.backends.bytecode.vm: Function, JitSetting;
import snakebite.backends.statistics: CompilationStatistics;
import snakebite.driver.execution: imagePathOf, LoadedProgram, loadProgramFile;
import snakebite.frontend.ast: FuncDeclaration;
import snakebite.program: Program;
import snakebite.start.data: StartData;
import std.conv: text;


// The saved form of a program: the bytes of the file that a save writes, and
// where in the saved program each function that the compile made is. A save
// and a load keep the modules of a program and the functions of each module
// in their order, so a position in the compiled program is the position in
// every program that a load makes from the bytes. The file has no name of a
// function unless the perf map is on, so the position is how a test finds the
// loaded form of a `FuncDeclaration`.
public struct SavedFile {
    public const(ubyte)[] bytes;
    // The JIT setting that the file was saved for.
    public JitSetting jit;
    // The module of the program and the function in the module.
    public alias Position = size_t[2];
    public Position[FuncDeclaration] positions;
}


// The saved form of `program`. The compiler is destroyed before this returns.
public SavedFile saveProgram(const Program program, in JitSetting jit) {
    import snakebite.backends.api: Owned;
    import snakebite.backends.bytecode.inspection: eachCompiledPosition;
    import std.file: getcwd, read, remove;

    const path = temporaryPath;
    scope(exit) {
        import std.file: exists;

        if (path.exists)
            path.remove;
    }
    SavedFile saved;
    saved.jit = jit;
    const recordsAddresses = true;
    auto compiler = new Bytecode(program, jit, recordsAddresses);
    {
        auto owned = Owned!Bytecode(compiler);
        owned.save(path, getcwd, imagePathOf(cast() program));
        eachCompiledPosition(compiler, (declaration, module_, index) {
            saved.positions[declaration] = [module_, index];
        });
    }
    destroy(compiler);
    saved.bytes = cast(const(ubyte)[]) read(path);
    return saved;
}


// The owner of a `LoadedBytecode`, as `Owned` is of a backend: it makes the
// handle, and ends its runner when it ends. Each owner loads the bytes of
// `saved` into a program of its own.
public struct LoadedOwner {
    @disable this(this);

    private LoadedBytecode _backend;

    public this(const(SavedFile)* saved) {
        _backend = LoadedBytecode(
            loadProgramFile(saved.bytes, saved.jit), saved);
    }

    ~this() {
        if (_backend._loaded.runner !is null)
            _backend._loaded.runner.end;
    }

    public LoadedBytecode backend() {
        return _backend;
    }

    alias backend this;
}


// The `Bytecode` backend after a save and a load, as a test arm. A save of
// the program with `Bytecode.save` writes a file, the compiler is destroyed,
// and `loadProgramFile` reads the file into a program that has no compiler,
// all in this process. The loaded program has the bytes of the file and
// nothing else of the compile. The arm checks (#958) that a load is
// equivalent to a compile to RAM. A copy refers to the same program.
public struct LoadedBytecode {
    private LoadedProgram _loaded;
    private const(SavedFile)* _saved;
    // A load compiles nothing.
    private CompilationStatistics _compilation;

    private this(LoadedProgram loaded, const(SavedFile)* saved) {
        _loaded = loaded;
        _saved = saved;
    }

    // Calls the saved form of `function_`, as `Backend.call` does.
    public void call(
        FuncDeclaration function_, void* returnPlace, void*[] args,
    ) {
        _loaded.runner.call(loadedFunction(function_), returnPlace, args);
    }

    // As `Backend.eval`.
    public string eval(FuncDeclaration function_) {
        string result;
        call(function_, &result, []);
        return result;
    }

    // The start data that the file holds.
    public ref StartData startData() {
        return _loaded.program.startData;
    }

    public ref const(CompilationStatistics) compilationStatistics() const {
        return _compilation;
    }

    public size_t executionStatesOfThisThread() {
        return _loaded.runner.executionStatesOfThisThread;
    }

    // How many chunks of callback entries the bridge of the program has.
    public size_t callbackChunkCount() {
        return _loaded.program.plans.callbacks is null
            ? 0 : _loaded.program.plans.callbacks.chunkCount;
    }

    // The function of the loaded program that is the saved form of
    // `function_`.
    public const(Function)* loadedFunction(FuncDeclaration function_) {
        const position = function_ in _saved.positions;
        if (position is null)
            throw new Exception(text("`", function_.ident.toString,
                "` is not in the saved program"));
        return functionAt(*_loaded.program, (*position)[0], (*position)[1]);
    }

    // Each function of the loaded program whose own name is `identifier`.
    public void eachLoaded(
        in string identifier, scope void delegate(const(Function)*) visit,
    ) {
        foreach (declaration, position; _saved.positions)
            if (declaration.ident.toString == identifier)
                visit(functionAt(
                    *_loaded.program, position[0], position[1]));
    }
}


private string temporaryPath() {
    import core.atomic: atomicOp;
    import std.file: tempDir;
    import std.path: buildPath;
    import std.process: thisProcessID;

    static shared size_t count;
    const index = atomicOp!"+="(count, 1);
    return buildPath(tempDir,
        text("snakebite-ut-", thisProcessID, "-", index, ".sbp"));
}
