module ut.loaded;


import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.bytecode.inspection: eachNamedFunction;
import snakebite.backends.bytecode.vm: Function, JitSetting;
import snakebite.backends.statistics: CompilationStatistics;
import snakebite.driver.execution: LoadedProgram, loadProgramFile;
import snakebite.frontend.ast: FuncDeclaration;
import snakebite.frontend.dmd.mangle: mangledNameOf;
import snakebite.program: Program;
import snakebite.start.data: StartData;
import std.conv: text;


// The owner of a `LoadedBytecode`, as `Owned` is of a backend: it makes the
// handle, and ends its runner when it ends.
public struct LoadedOwner {
    @disable this(this);

    private LoadedBytecode _backend;

    public this(const Program program, in JitSetting jit) {
        _backend = LoadedBytecode(
            loadProgramFile(savedFile(program, jit), jit));
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
    // A load compiles nothing.
    private CompilationStatistics _compilation;

    private this(LoadedProgram loaded) {
        _loaded = loaded;
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
        const name = function_.mangledNameOf;
        const(Function)* found;
        eachNamedFunction(*_loaded.program, (mangledName, loaded) {
            if (found is null && mangledName == name)
                found = loaded;
        });
        if (found is null)
            throw new Exception(
                text("`", name, "` is not in the saved program"));
        return found;
    }

    // Each function of the loaded program whose own name, the last part of
    // its qualified name, is `identifier`.
    public void eachLoaded(
        in string identifier, scope void delegate(const(Function)*) visit,
    ) {
        eachNamedFunction(*_loaded.program, (mangledName, loaded) {
            if (identifierOf(mangledName) == identifier)
                visit(loaded);
        });
    }
}


// The own name of the function whose mangled name is `mangledName`: in
// `long m.C.add(long) pure`, `add`. The D `main` has the mangled name
// `_Dmain`.
private const(char)[] identifierOf(const(char)[] mangledName) {
    import core.demangle: demangle;
    import std.string: lastIndexOf;

    if (mangledName == "_Dmain")
        return "main";
    const demangled = demangle(mangledName);
    const close = demangled.lastIndexOf(')');
    if (close < 0)
        return null;
    size_t depth;
    ptrdiff_t open = close;
    for (; open >= 0; --open) {
        if (demangled[open] == ')')
            ++depth;
        else if (demangled[open] == '(' && --depth == 0)
            break;
    }
    if (open <= 0)
        return null;
    ptrdiff_t start = open;
    while (start > 0 && demangled[start - 1] != '.'
            && demangled[start - 1] != ' ')
        --start;
    return demangled[start .. open];
}


// The bytes of the file that a save of `program` writes. The compiler is
// destroyed before this returns.
private const(ubyte)[] savedFile(const Program program, in JitSetting jit) {
    import snakebite.backends.api: Owned;
    import std.file: getcwd, read, remove;

    const path = temporaryPath;
    scope(exit) {
        import std.file: exists;

        if (path.exists)
            path.remove;
    }
    const recordsAddresses = true;
    auto compiler = new Bytecode(program, jit, recordsAddresses);
    {
        auto owned = Owned!Bytecode(compiler);
        owned.save(path, getcwd);
    }
    destroy(compiler);
    return cast(const(ubyte)[]) read(path);
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
