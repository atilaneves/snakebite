module snakebite.dependencyimage;


private:


// A prepared image owns its loader reference. Keep it alive until all
// backends, callbacks and values that use its code have been destroyed.
// Build before constructing a backend: symbol misses are cached.
public struct DependencyImage {
    private void* _handle;
    private string _path;

    @disable this(this);

    public string path() @safe @nogc nothrow pure const return scope {
        return _path;
    }

    public void* resolve(in char[] name) const {
        import core.sys.posix.dlfcn: dlerror, dlsym;
        import std.string: toStringz;

        if (_handle is null)
            return null;
        dlerror;
        // const qualifies the owner, not the loader's opaque handle.
        const address = dlsym(cast(void*) _handle, name.toStringz);
        return dlerror is null ? cast(void*) address : null;
    }

    ~this() {
        import core.runtime: Runtime;

        if (_handle !is null)
            Runtime.unloadLibrary(_handle);
    }
}


// The compiler must be from the host's installation. Inputs lists every
// imported source or other file supplied by the caller, so edits invalidate
// the cache. The compiler installation is assumed immutable at a given
// path and version. No shell interprets source paths or compiler arguments.
public DependencyImage prepareImage(
    in string source,
    in string cacheDirectory,
    in string compiler = defaultCompiler,
    in string[] inputs = null,
) {
    import core.runtime: Runtime;
    import core.sys.posix.dlfcn: dlerror;
    import std.conv: text;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.file: exists, mkdirRecurse, read, rename, rmdirRecurse, write;
    import std.path: absolutePath, buildPath;
    import std.process: execute;
    import std.string: fromStringz;
    import std.uuid: randomUUID;

    const executable = compilerPath(compiler);
    const identity = execute([executable, "--version"]);
    require(identity.status == 0, "Cannot identify image compiler: " ~ identity.output);
    import std.algorithm: startsWith;
    version (DigitalMars)
        require(identity.output.startsWith("DMD"), "Image compiler must be DMD");
    else version (LDC)
        require(identity.output.startsWith("LDC"), "Image compiler must be LDC");

    version (DigitalMars) {
        const compileFlags = ["-c", "-fPIC", "-O"];
        const linkFlags = ["-shared", "-defaultlib=libphobos2.so",
            "-L--no-undefined"];
    } else version (LDC) {
        const compileFlags = ["-c", "-relocation-model=pic", "-O"];
        const linkFlags = ["-shared", "-link-defaultlib-shared",
            "-L--no-undefined"];
    } else {
        static assert(false, "Dependency images require DMD or LDC");
    }
    string fingerprint = text("snakebite-image-v1\n", executable, "\n",
        read(executable).sha256Of.toHexString, "\n", identity.output,
        "\n", __VERSION__, "\n", compileFlags, "\n", linkFlags,
        "\n", source.length, ":", source);
    foreach (input; inputs)
        fingerprint ~= text("\n", input.absolutePath.length, ":",
            input.absolutePath, ":", read(input).sha256Of.toHexString);
    const directory = cacheDirectory.absolutePath;
    directory.mkdirRecurse;
    const destination = directory.buildPath(fingerprint.sha256Of.toHexString ~ ".so");
    if (!destination.exists) {
        const staging = directory.buildPath(text("build-", randomUUID));
        staging.mkdirRecurse;
        scope(exit) staging.rmdirRecurse;
        const sourcePath = staging.buildPath("image.d");
        const objectPath = staging.buildPath("image.o");
        const imagePath = staging.buildPath("image.so");
        sourcePath.write(source ~ text("\nstatic assert(__VERSION__ == ",
            __VERSION__, ", \"Image compiler must match the host compiler version\");\n"));
        runCompiler("compilation", [executable] ~ compileFlags
            ~ [sourcePath, "-of=" ~ objectPath]);
        runCompiler("linking", [executable] ~ linkFlags
            ~ [objectPath, "-of=" ~ imagePath]);
        // Readers must never observe a partially linked image. Concurrent
        // builders publish equivalent complete files with atomic rename.
        rename(imagePath, destination);
    }
    DependencyImage image;
    image._path = destination;
    image._handle = Runtime.loadLibrary(destination);
    if (image._handle is null)
        require(false, text("Cannot load dependency image ", destination,
            ": ", dlerror.fromStringz));
    return image;
}


version (DigitalMars)
    public enum defaultCompiler = "dmd";
else version (LDC)
    public enum defaultCompiler = "ldc2";


private void runCompiler(in string phase, in string[] command) {
    import std.process: execute;
    import std.conv: text;

    const result = execute(command);
    if (result.status != 0) {
        import snakebite.exception: SnakebiteException;

        auto error = new SnakebiteException(
            text("Dependency image ", phase, " failed"));
        error.next = new Exception(text("Command: ", command, "\n", result.output));
        throw error;
    }
}


private string compilerPath(in string compiler) {
    import std.file: exists;
    import std.path: absolutePath, buildPath;
    import std.process: environment;
    import std.string: split;
    import std.algorithm: canFind;

    if (compiler.canFind('/')) {
        require(compiler.exists, "Image compiler does not exist: " ~ compiler);
        return compiler.absolutePath;
    }
    foreach (directory; environment.get("PATH", "").split(":")) {
        const candidate = buildPath(directory, compiler);
        if (candidate.exists)
            return candidate.absolutePath;
    }
    require(false, "Image compiler not found on PATH: " ~ compiler);
    assert(0);
}


private void require(in bool condition, in string message) {
    import snakebite.exception: SnakebiteException;

    if (!condition)
        throw new SnakebiteException(message);
}
