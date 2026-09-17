module snakebite.dependencyimage;


private:


// A project's dependency image stays loaded until the executable exits.
// This value describes the image; its scope does not limit that lifetime.
public struct DependencyImage {
    private void* _handle;
    private string _path;

    public string path() @safe @nogc nothrow pure const return scope {
        return _path;
    }

    public void* resolve(in char[] name) const {
        import core.sys.posix.dlfcn: dlerror, dlsym;
        import std.string: toStringz;

        if (_handle is null)
            return null;
        dlerror;
        // const qualifies this description, not the loader's opaque handle.
        const address = dlsym(cast(void*) _handle, name.toStringz);
        return dlerror is null ? cast(void*) address : null;
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
    in string[] importPaths = null,
    in string[] stringImportPaths = null,
    in string[] compilerArguments = null,
    in string[] linkerFiles = null,
    in string[] linkerArguments = null,
) {
    import std.conv: text;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.file: exists, mkdirRecurse, read, rename, rmdirRecurse, write;
    import std.path: absolutePath, buildPath;
    import std.uuid: randomUUID;

    import std.algorithm.iteration: map;
    import std.array: array;

    string imageArgument(string argument) {
        version (LDC) {
            import std.algorithm: startsWith;
            if (argument == "-debug" || argument.startsWith("-version=")
                    || argument.startsWith("-debug="))
                return "-d" ~ argument;
        }
        return argument;
    }
    const importFlags = compilerArguments.map!imageArgument.array
        ~ importPaths.map!(path => "-I" ~ path).array
        ~ stringImportPaths.map!(path => "-J" ~ path).array;
    const executable = compilerPath(compiler);
    const identityOutput = compilerIdentity(executable);
    import std.algorithm: startsWith;
    version (DigitalMars)
        require(identityOutput.startsWith("DMD"), "Image compiler must be DMD");
    else version (LDC)
        require(identityOutput.startsWith("LDC"), "Image compiler must be LDC");

    // The image must emit transitive template bodies too, including runtime
    // helpers introduced by assertion lowering. No guest object supplies them.
    version (DigitalMars) {
        const compileFlags = ["-c", "-fPIC", "-O", "-allinst"];
        const linkFlags = ["-shared", "-defaultlib=libphobos2.so",
            "-L--no-undefined"];
    } else version (LDC) {
        const compileFlags = ["-c", "-relocation-model=pic", "-O", "-allinst"];
        const linkFlags = ["-shared", "-link-defaultlib-shared",
            "-L--no-undefined"];
    } else {
        static assert(false, "Dependency images require DMD or LDC");
    }
    // A linker response file stops DMD from moving archives
    // outside the whole-archive pair. Guest calls do not create undefined
    // symbols in image.o, so ordinary archive extraction loses their code.
    import std.algorithm: endsWith;
    string[] dependencyFlags;
    bool[string] linked;
    foreach (file; linkerFiles) {
        const path = file.absolutePath;
        if (path in linked)
            continue;
        linked[path] = true;
        if (path.endsWith(".a"))
            dependencyFlags ~= ["--whole-archive", path,
                "--no-whole-archive"];
        else
            dependencyFlags ~= path;
    }
    string fingerprint = text("snakebite-image-v1\n", executable, "\n",
        read(executable).sha256Of.toHexString, "\n", identityOutput,
        "\n", __VERSION__, "\n", compileFlags, "\n", linkFlags,
        "\n", importFlags, "\n", dependencyFlags, "\n", linkerArguments,
        "\n", source.length, ":", source);
    foreach (input; inputs ~ linkerFiles)
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
        runCompiler("compilation", [executable] ~ compileFlags ~ importFlags
            ~ [sourcePath, "-of=" ~ objectPath]);
        import std.array: join;
        import std.string: replace;
        const responsePath = staging.buildPath("linker.rsp");
        responsePath.write(dependencyFlags.map!(argument =>
            "\"" ~ argument.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\"")
            .join("\n"));
        runCompiler("linking", [executable] ~ linkFlags ~ linkerArguments
            ~ ["-Xcc=-Wl,@linker.rsp"]
            ~ [objectPath, "-of=" ~ imagePath], staging);
        // Readers must never observe a partially linked image. Concurrent
        // builders publish equivalent complete files with atomic rename.
        rename(imagePath, destination);
    }
    return loadImage(destination);
}


private DependencyImage loadImage(in string path) {
    import core.runtime: Runtime;
    import core.sys.posix.dlfcn:
        dlclose, dlerror, dlopen, RTLD_LAZY, RTLD_NODELETE;
    import std.string: fromStringz, toStringz;
    import std.conv: text;

    DependencyImage image;
    image._path = path;
    image._handle = Runtime.loadLibrary(path);
    if (image._handle is null)
        require(false, text("Cannot load dependency image ", path,
            ": ", dlerror.fromStringz));
    // druntime releases a thread's library references when that thread exits.
    // Symbols must remain valid for the executable after the loading thread ends.
    const pinned = dlopen(path.toStringz, RTLD_LAZY | RTLD_NODELETE);
    if (pinned is null)
        require(false, text("Cannot retain dependency image ", path,
            ": ", dlerror.fromStringz));
    dlclose(cast(void*) pinned);
    return image;
}


version (DigitalMars)
    public enum defaultCompiler = "dmd";
else version (LDC)
    public enum defaultCompiler = "ldc2";


private void runCompiler(
    in string phase, in string[] command, in string directory = null,
) {
    import std.process: Config, execute;
    import std.conv: text;

    const result = execute(command, null, Config.none, size_t.max, directory);
    if (result.status != 0) {
        import snakebite.exception: SnakebiteException;

        throw new SnakebiteException(text("Dependency image ", phase,
            " failed\nCommand: ", command, "\n", result.output));
    }
}


// The compiler's identity does not change while a process runs (the
// installation at a given path is assumed immutable, see the doc comment
// on prepareImage above), so probe it once per executable, not once per
// image build.
private __gshared string[string] _compilerIdentityCache;
private __gshared Object _compilerIdentityMutex = new Object();

private string compilerIdentity(in string executable) {
    import std.process: execute;

    synchronized (_compilerIdentityMutex) {
        if (auto found = executable in _compilerIdentityCache)
            return *found;
    }
    const identity = execute([executable, "--version"]);
    require(identity.status == 0, "Cannot identify image compiler: " ~ identity.output);
    synchronized (_compilerIdentityMutex) {
        _compilerIdentityCache[executable] = identity.output;
    }
    return identity.output;
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


// Unchanged projects need only metadata checks and a loader reference.
// A root edit can reuse the same image if it requests the same templates.
public struct ProjectImageCache {
    private string _path;
    private string _settings;
    private string[] _roots;

    public this(in string directory, in string settings, in string[] roots) {
        import std.path: buildPath;
        import std.conv: text;

        _path = buildPath(directory, "project.json");
        _settings = sourceDigest(text("snakebite-project-image-v1", __VERSION__, settings));
        _roots = roots.dup;
    }

    public bool restore(ref DependencyImage image, scope string delegate() source) {
        import std.file: exists, readText;
        import std.json: parseJSON;

        if (!_path.exists)
            return false;
        auto record = parseJSON(_path.readText);
        if (record["settings"].str != _settings
                || record["compiler"].str != compilerPath(defaultCompiler))
            return false;
        foreach (path, stamp; record["inputs"].object)
            if (fileStamp(path) != stamp.str)
                return false;
        const roots = fileStamps(_roots);
        const rootChanged = roots != record["roots"];
        if (rootChanged && sourceDigest(source()) != record["source"].str)
            return false;
        image = loadImage(record["image"].str);
        if (rootChanged) {
            record["roots"] = roots;
            publish(record.toString);
        }
        return true;
    }

    private void publish(in string contents) const {
        import std.file: mkdirRecurse, rename, write;
        import std.path: dirName;
        import std.uuid: randomUUID;
        import std.conv: text;

        _path.dirName.mkdirRecurse;
        const temporary = text(_path, ".", randomUUID);
        temporary.write(contents);
        rename(temporary, _path);
    }

    public void save(in string path, in string source, in string[] inputs) const {
        import std.json: JSONValue;

        const compiler = compilerPath(defaultCompiler);
        JSONValue record;
        record["settings"] = _settings;
        record["compiler"] = compiler;
        record["roots"] = fileStamps(_roots);
        record["inputs"] = fileStamps(inputs ~ [compiler, path]);
        record["source"] = sourceDigest(source);
        record["image"] = path;
        publish(record.toString);
    }
}


private string sourceDigest(in string source) @safe pure nothrow {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;

    return source.sha256Of.toHexString.idup;
}


private imported!"std.json".JSONValue fileStamps(in string[] paths) {
    import std.json: JSONValue;
    import std.path: absolutePath;

    // An empty set must remain an object so a reader can iterate its keys.
    string[string] empty;
    auto result = JSONValue(empty);
    foreach (path; paths) {
        const absolute = path.absolutePath;
        result[absolute] = fileStamp(absolute);
    }
    return result;
}


// ctime and inode catch same-size edits with restored mtimes and atomic
// replacements. Access time is excluded because reads must not invalidate us.
private string fileStamp(in string path) {
    import core.sys.posix.sys.stat: stat, stat_t;
    import core.stdc.errno: errno, ENOENT, ENOTDIR;
    import std.exception: errnoEnforce;
    import std.string: toStringz;
    import std.conv: text;

    stat_t info;
    const status = stat(path.toStringz, &info);
    if (status != 0 && (errno == ENOENT || errno == ENOTDIR))
        return "missing";
    errnoEnforce(status == 0, "Cannot inspect image input " ~ path);
    return text(info.st_dev, ":", info.st_ino, ":", info.st_size, ":",
        info.st_mtim.tv_sec, ":", info.st_mtim.tv_nsec, ":",
        info.st_ctim.tv_sec, ":", info.st_ctim.tv_nsec);
}
