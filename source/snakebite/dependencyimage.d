module snakebite.dependencyimage;


private:


public struct TestHooks {
    import core.runtime: Runtime;

    private typeof(Runtime.moduleUnitTester) _legacy;
    private typeof(Runtime.extendedModuleUnitTester) _extended;

    public static TestHooks current() {
        return TestHooks(Runtime.moduleUnitTester, Runtime.extendedModuleUnitTester);
    }

    public void install() const {
        Runtime.moduleUnitTester = _legacy;
        Runtime.extendedModuleUnitTester = _extended;
    }

    // Runtime hooks are function pointers, so they need a shared slot.
    // Each nested run must restore the enclosing run's tracking state.
    public struct Watch {
        private TestHooks _hooks;
        private Watch* _previous;
        public bool escaped;

        public void install(in TestHooks hooks) {
            _hooks = hooks;
            _previous = _watch;
            _watch = &this;
            TestHooks(
                hooks._legacy is null ? null : &watchedLegacy,
                hooks._extended is null ? null : &watchedExtended,
            ).install;
        }

        public void restore() {
            _watch = _previous;
        }
    }

    private static bool watchedLegacy() {
        try
            return _watch._hooks._legacy();
        catch (Throwable throwable) {
            _watch.escaped = true;
            throw throwable;
        }
    }

    private static typeof(Runtime.extendedModuleUnitTester()()) watchedExtended() {
        try
            return _watch._hooks._extended();
        catch (Throwable throwable) {
            _watch.escaped = true;
            throw throwable;
        }
    }
}

private __gshared TestHooks.Watch* _watch;


// A project's dependency image stays loaded until the executable exits.
// This value describes the image; its scope does not limit that lifetime.
public struct DependencyImage {
    private void* _handle;
    private string _path;
    public TestHooks testHooks;

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
//
// `cppSource`, when not empty, is one C++ translation unit compiled by
// `cxxCompiler` (the system C++ compiler - `c++` by default, or `$CXX`
// - `defaultCxxCompiler` reads it) into the same shared object as
// `source`: one build, one cache entry, one loader. This is how a test
// C++ library reaches the image (issue #336): the D side declares its
// functions and classes `extern(C++)` and calls them like any other
// resolved symbol. The C++ compiler's own identity and flags join the
// cache key, next to the D compiler's, so a different C++ toolchain or
// flag set never reuses another one's image.
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
    in string cppSource = null,
    in string cxxCompiler = defaultCxxCompiler,
    in string[] cxxCompilerArguments = null,
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
    // Fixed C++ compile flags: same for every build, so this is not a
    // caller parameter the way `cxxCompilerArguments` is - but it still
    // joins the fingerprint (issue #336 review, finding 6), so changing
    // one of these constants later cannot reuse a stale image built with
    // the old flags.
    const cxxCompileFlags = ["-c", "-fPIC", "-O2", "-std=c++17"];
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
    // The C++ compiler is only ever asked for when a caller actually
    // wants C++ code in the image - a build with no `cppSource` probes
    // no C++ toolchain and its fingerprint is byte-for-byte what it was
    // before this parameter existed.
    const hasCppSource = cppSource.length != 0;
    string[] cxxCommand;
    string cxxExecutable;
    if (hasCppSource) {
        cxxCommand = resolveCxxCommand(cxxCompiler);
        cxxExecutable = cxxCommand[0];
    }

    // Everything the content fingerprint below depends on, minus file
    // contents, keys a stamp record. An unchanged compiler, input set and
    // source hits there without a compiler probe or a content hash: the
    // record was written after a successful build, and a compiler whose
    // stamp is unchanged is the one whose version output and binary that
    // build recorded. A CLI run pays this path once per invocation, so it
    // has to cost a few stats, not a 20 ms subprocess and a hash of the
    // whole compiler executable.
    const directory = cacheDirectory.absolutePath;
    const settings = text("snakebite-image-v1\n", executable, "\n",
        __VERSION__, "\n", compileFlags, "\n", linkFlags, "\n", importFlags,
        "\n", dependencyFlags, "\n", linkerArguments, "\n",
        inputs.map!(input => input.absolutePath).array, "\n",
        source.length, ":", source, "\ncxx:", cxxCommand, "\n",
        cxxCompileFlags, "\n", cxxCompilerArguments, "\n",
        cppSource.length, ":", cppSource);
    auto stamps = ProjectImageCache(
        directory.buildPath(sourceDigest(settings) ~ ".json"), settings, null,
        executable);
    DependencyImage image;
    if (stamps.restore(image, () => source))
        return image;

    const identityOutput = compilerIdentity([executable]);
    import std.algorithm: startsWith;
    version (DigitalMars)
        require(identityOutput.startsWith("DMD"), "Image compiler must be DMD");
    else version (LDC)
        require(identityOutput.startsWith("LDC"), "Image compiler must be LDC");

    string fingerprint = text("snakebite-image-v1\n", executable, "\n",
        read(executable).sha256Of.toHexString, "\n", identityOutput,
        "\n", __VERSION__, "\n", compileFlags, "\n", linkFlags,
        "\n", importFlags, "\n", dependencyFlags, "\n", linkerArguments,
        "\n", source.length, ":", source);
    foreach (input; inputs ~ linkerFiles)
        fingerprint ~= text("\n", input.absolutePath.length, ":",
            input.absolutePath, ":", read(input).sha256Of.toHexString);

    string cxxRuntimeLibrary;
    if (hasCppSource) {
        const cxxIdentity = compilerIdentity(cxxCommand);
        // The C++ runtime library this pulls in is what gives the image
        // `operator new`/`delete`, RTTI and the exception personality
        // routine a thrown C++ exception (issue #336 step 5) needs. Which
        // one a given `$CXX` links is not decided by the compiler's name:
        // on Linux, clang defaults to `libstdc++` unless it was itself
        // built with `CLANG_DEFAULT_CXX_STDLIB=libc++`, so guessing from
        // "clang" in `--version` breaks a plain `CXX=clang++` on such a
        // system. Asking the driver instead - see `probeCxxRuntimeLibrary`
        // - is right for any compiler and configuration.
        cxxRuntimeLibrary = probeCxxRuntimeLibrary(cxxCommand);
        fingerprint ~= text("\ncxx:", cxxCommand, "\n",
            read(cxxExecutable).sha256Of.toHexString, "\n", cxxIdentity,
            "\n", cxxCompileFlags, "\n", cxxCompilerArguments,
            "\n", cxxRuntimeLibrary, "\n", cppSource.length, ":", cppSource);
    }

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

        string[] objectPaths = [objectPath];
        string[] extraLinkFlags;
        if (hasCppSource) {
            const cppSourcePath = staging.buildPath("image.cpp");
            const cppObjectPath = staging.buildPath("image_cpp.o");
            cppSourcePath.write(cppSource);
            runCompiler("C++ compilation", cxxCommand ~ cxxCompileFlags
                ~ cxxCompilerArguments ~ [cppSourcePath, "-o", cppObjectPath]);
            objectPaths ~= cppObjectPath;
            // A library flag must trail every object file that needs
            // symbols from it, or a traditional linker's one-pass symbol
            // search misses them - so this joins the response file's own
            // dependency archives, not `linkFlags`, which comes first.
            extraLinkFlags ~= "-L-l" ~ cxxRuntimeLibrary;
        }

        import std.array: join;
        import std.string: replace;
        const responsePath = staging.buildPath("linker.rsp");
        responsePath.write(dependencyFlags.map!(argument =>
            "\"" ~ argument.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\"")
            .join("\n"));
        runCompiler("linking", [executable] ~ linkFlags ~ linkerArguments
            ~ ["-Xcc=-Wl,@linker.rsp"]
            ~ objectPaths ~ extraLinkFlags ~ ["-of=" ~ imagePath], staging);
        // Readers must never observe a partially linked image. Concurrent
        // builders publish equivalent complete files with atomic rename.
        rename(imagePath, destination);
    }
    image = loadImage(destination);
    stamps.save(destination, source,
        inputs ~ linkerFiles ~ (hasCppSource ? [cxxExecutable] : null));
    return image;
}


private DependencyImage loadImage(in string path) {
    import core.sys.posix.dlfcn:
        dlerror, dlopen, RTLD_LAZY, RTLD_NODELETE;
    import std.string: fromStringz, toStringz;
    import std.conv: text;

    // Hooks belong to the process, so concurrent image loads must not
    // capture or restore another image's constructor changes.
    _imageLoadLock.lock;
    scope(exit) _imageLoadLock.unlock;
    const savedHooks = TestHooks.current;
    scope(exit) savedHooks.install;
    TestHooks.init.install;

    DependencyImage image;
    image._path = path;
    // A plain `dlopen`, not `Runtime.loadLibrary`. Both register the
    // image with druntime on this thread (`_d_dso_registry` runs from
    // the image's own constructor): the GC scans its TLS, its module and
    // TLS constructors run, and the record lives until the loader's own
    // teardown at process exit finds and frees it. `Runtime.loadLibrary`
    // additionally marks the record as an *explicit* load this thread
    // must `dlclose` itself, and every thread this one starts inherits
    // that duty (`core.thread`'s `pinLoadedLibraries` and druntime's
    // `cleanupLoadedLibraries`). A guest thread still alive at process
    // exit then reads the record after the loader freed it - a dependency
    // image's finalizer runs before druntime's and libphobos's - and
    // segfaults inside `dlclose`. Releasing that explicit reference is no
    // answer either: druntime drops the whole record with it, so the
    // GC stops scanning the image's TLS and the loader warns at exit.
    // `RTLD_NODELETE` keeps the one loader reference taken here for the
    // whole process, so symbols stay valid after this call returns and
    // nothing ever closes the image.
    image._handle = dlopen(path.toStringz, RTLD_LAZY | RTLD_NODELETE);
    if (image._handle is null)
        require(false, text("Cannot load dependency image ", path,
            ": ", dlerror.fromStringz));
    // Shared constructors run only on the first load. Retain their hooks
    // even if later preparation fails, since the loaded image stays open.
    if (auto hooks = image._handle in _imageTestHooks)
        image.testHooks = *hooks;
    else {
        image.testHooks = TestHooks.current;
        _imageTestHooks[image._handle] = image.testHooks;
    }
    return image;
}


private __gshared TestHooks[void*] _imageTestHooks;
private __gshared imported!"core.sync.mutex".Mutex _imageLoadLock;


shared static this() {
    import core.sync.mutex: Mutex;

    _imageLoadLock = new Mutex;
}


version (DigitalMars)
    public enum defaultCompiler = "dmd";
else version (LDC)
    public enum defaultCompiler = "ldc2";


// The system C++ compiler: `$CXX` when set, `c++` otherwise - the same
// rule a Makefile uses.
public string defaultCxxCompiler() {
    import std.process: environment;

    return environment.get("CXX", "c++");
}


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


// `command` is the whole invocation - a wrapper such as `ccache` ahead of
// the real compiler counts, since it can change what actually runs. This
// runs only when an image's stamp record misses, so the stamp record is
// what keeps it to one probe per compiler, across processes as well.
private string compilerIdentity(in string[] command) {
    import std.process: execute;

    const identity = execute(command ~ ["--version"]);
    require(identity.status == 0, "Cannot identify image compiler: " ~ identity.output);
    return identity.output;
}


// Which runtime library `cxxCommand` links a C++ shared object against -
// `stdc++` or `c++` - read from the driver itself instead of guessed from
// the compiler's name (issue #336 review, finding 1). `-###` asks the
// driver to print, not run, the subprocess commands it would use to link
// a trivial C++ shared library: the same commands, whichever runtime it
// defaults to, for gcc, for clang built either way
// (`CLANG_DEFAULT_CXX_STDLIB`), and for any wrapper ahead of either. One
// of the printed, quoted linker arguments is always `"-lstdc++"` or
// `"-lc++"` (verified on this machine: gcc 16 and a clang 22 built to
// clang's own upstream default both print `"-lstdc++"`, matching finding
// 1's report that Linux clang defaults to libstdc++ unless reconfigured).
private string probeCxxRuntimeLibrary(in string[] cxxCommand) {
    import std.algorithm: canFind;
    import std.conv: text;
    import std.file: exists, remove, tempDir, write;
    import std.path: buildPath;
    import std.process: execute;
    import std.uuid: randomUUID;

    const probeSource = buildPath(
        tempDir(), text("snakebite-cxx-probe-", randomUUID, ".cpp"));
    probeSource.write("int snakebite_cxx_runtime_probe() { return 0; }\n");
    scope(exit) if (probeSource.exists) probeSource.remove();
    // `-###` never runs the commands it prints, so this path is never
    // written - naming it is only what tells the driver what a real
    // link's output path would be.
    const probeOutput = buildPath(
        tempDir(), text("snakebite-cxx-probe-", randomUUID, ".so"));

    const probe = execute(cxxCommand ~ ["-###", "-shared", "-fPIC",
        probeSource, "-o", probeOutput]);
    string library;
    if (probe.output.canFind(`"-lc++"`))
        library = "c++";
    else if (probe.output.canFind(`"-lstdc++"`))
        library = "stdc++";
    else
        require(false, text("Cannot tell which C++ runtime library `",
            cxxCommand, "` links: ", probe.output));
    return library;
}


// `compiler` may be a bare executable, or, like a Makefile's `$CXX`, a
// command line - a wrapper such as `ccache` ahead of the real compiler,
// space-separated (issue #336 review, finding 7). Only the first word is
// looked up on `PATH`; the rest travel as leading arguments ahead of
// every other argument this module ever passes.
private string[] resolveCxxCommand(in string compiler) {
    import std.algorithm: filter;
    import std.array: array;
    import std.string: split, strip;

    const words = compiler.strip.split.filter!(w => w.length != 0).array;
    require(words.length != 0, "C++ compiler must not be empty");
    return [compilerPath(words[0], "C++ compiler")] ~ words[1 .. $];
}


private string compilerPath(
    in string compiler, in string label = "Image compiler",
) {
    import std.file: exists;
    import std.path: absolutePath, buildPath;
    import std.process: environment;
    import std.string: split;
    import std.algorithm: canFind;

    if (compiler.canFind('/')) {
        require(compiler.exists, label ~ " does not exist: " ~ compiler);
        return compiler.absolutePath;
    }
    foreach (directory; environment.get("PATH", "").split(":")) {
        const candidate = buildPath(directory, compiler);
        if (candidate.exists)
            return candidate.absolutePath;
    }
    require(false, label ~ " not found on PATH: " ~ compiler);
    assert(0);
}


private void require(in bool condition, in string message) {
    import snakebite.exception: SnakebiteException;

    if (!condition)
        throw new SnakebiteException(message);
}


// An unchanged image needs only metadata checks and a loader reference:
// file stamps for the compiler and every input stand in for their contents.
// A root edit can reuse the same image if it requests the same templates.
public struct ProjectImageCache {
    private string _path;
    private string _settings;
    private string[] _roots;
    private string _compiler;

    public this(
        in string recordPath,
        in string settings,
        in string[] roots,
        in string compiler = defaultCompiler,
    ) {
        import std.conv: text;

        _path = recordPath;
        _settings = sourceDigest(text("snakebite-project-image-v2", __VERSION__, settings));
        _roots = roots.dup;
        _compiler = compilerPath(compiler);
    }

    public bool prepare(
        ref DependencyImage image,
        scope string delegate() source,
        scope void delegate() buildDependencies,
        scope DependencyImage delegate(in string) buildImage,
        in bool hasLinkerFiles,
        scope string[] delegate() inputs,
    ) {
        string generated;
        bool generatedOnce;
        string generateSource() {
            if (!generatedOnce) {
                generated = source();
                generatedOnce = true;
            }
            return generated;
        }
        if (restore(image, &generateSource))
            return true;

        buildDependencies();
        const generatedSource = generateSource();
        if (!generatedSource.length && !hasLinkerFiles)
            return false;
        image = buildImage(generatedSource.length
            ? generatedSource : "module snakebite_dependency_image;\n");
        save(image.path, generatedSource, inputs());
        return true;
    }

    private bool restore(ref DependencyImage image, scope string delegate() source) {
        import std.file: exists, readText;
        import std.json: parseJSON;

        if (!_path.exists)
            return false;
        auto record = parseJSON(_path.readText);
        if (record["settings"].str != _settings
                || record["compiler"].str != _compiler)
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

    private void save(in string path, in string source, in string[] inputs) const {
        import std.json: JSONValue;

        JSONValue record;
        record["settings"] = _settings;
        record["compiler"] = _compiler;
        record["roots"] = fileStamps(_roots);
        record["inputs"] = fileStamps(inputs ~ [_compiler, path]);
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
