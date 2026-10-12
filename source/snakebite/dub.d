module snakebite.dub;

private:

// What `dub describe` says about a project, with the choices that the
// description was made with. A build of the dependencies needs them to ask
// dub for the same targets.
public struct DubDescription {
    import dub.description: ProjectDescription;

    public ProjectDescription project;
    // The configuration as asked for. `unittest` stands for dub's generated
    // test runner configuration, which `project.configuration` names.
    public string requestedConfiguration;
    public string[] versions;
}


// The build settings of the root package, which dub merges from the
// dependencies that the root package is built with.
public imported!"dub.compilers.buildsettings".BuildSettings rootBuildSettings(
    in imported!"dub.description".ProjectDescription project,
) {
    return project.lookupTarget(project.rootPackage).buildSettings.dup;
}


// The search path belongs to the whole process.
private __gshared imported!"core.sync.mutex".Mutex _searchPathLock;

// A package that is on disk is used as it is. The registry is asked only for
// a package that is not there, because `dub fetch` without a version always
// asks the registry for the latest one, over the network, even when the
// package is already on disk. `name@version` names exactly that version: a
// different cached version never stands in for it.
public string fetchProject(
    in string packageName,
    in string rootDirectory = ".",
    in imported!"dub.dub".SkipPackageSuppliers suppliers
        = imported!"dub.dub".SkipPackageSuppliers.none,
) {
    import dub.dependency: PackageName, VersionRange;
    import dub.dub: Dub;
    import std.algorithm.searching: findSplit;

    auto parts = packageName.findSplit("@");
    if (parts[1].length == 0)
        parts = packageName.findSplit("=");
    const name = PackageName(parts[0]);
    const range = parts[1].length == 0 ? VersionRange.Any : VersionRange.fromString(parts[2]);

    silenceDubLog;
    auto dub = new Dub(rootDirectory, null, suppliers);
    auto package_ = dub.packageManager.getBestPackage(name, range);
    if (package_ is null)
        package_ = dub.fetch(name, range);
    return package_.path.toString;
}


public DubDescription dubDescribeProject(
    in string directory, in string[] versions = null,
) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.dubcache: cachedDubDescription;

    return cachedDubDescription(directory, defaultCompiler, versions, {
        auto dub = loadedDub(directory);
        auto settings = platformSettings(dub, versions);
        settings.buildType = "unittest";
        settings.config = "unittest";
        DubDescription description;
        description.versions = versions.dup;
        // dub's test runner configuration needs no `unittest` configuration
        // of the recipe; a project without a target to test has none.
        const testConfiguration = dub.project.addTestRunnerConfiguration(settings);
        if (testConfiguration.length) {
            description.requestedConfiguration = "unittest";
            settings.config = testConfiguration;
        } else {
            settings.buildType = "debug";
            settings.config = dub.project.getDefaultConfiguration(settings.platform);
            description.requestedConfiguration = settings.config;
        }
        description.project = dub.project.describe(settings);
        runPreBuildCommands(dub, settings, description.project);
        return description;
    });
}

private auto loadedDub(in string directory) {
    import dub.dub: Dub, SkipPackageSuppliers;

    silenceDubLog;
    auto dub = new Dub(directory, null, SkipPackageSuppliers.all);
    dub.loadPackage;
    return dub;
}

private void silenceDubLog() {
    import dub.internal.logging: LogLevel, setLogLevel;

    setLogLevel(LogLevel.error);
}

// The platform is what the compiler reports, as in `dub describe`.
private auto platformSettings(imported!"dub.dub".Dub dub, in string[] versions) {
    import dub.compilers.buildsettings: BuildOption;
    import dub.compilers.compiler: getCompiler;
    import dub.generators.generator: GeneratorSettings;
    import dub.internal.vibecompat.inet.path: NativePath;
    import snakebite.dependencyimage: defaultCompiler;

    GeneratorSettings settings;
    settings.compiler = getCompiler(defaultCompiler);
    settings.platform = settings.compiler.determinePlatform(
        settings.buildSettings, defaultCompiler, dub.defaultArchitecture);
    settings.buildSettings.options = BuildOption.none;
    settings.buildSettings.addVersions(versions);
    settings.cache = NativePath(dubCacheDirectory);
    return settings;
}

// dub's own function for this is not public.
private string dubCacheDirectory() {
    import std.path: buildPath;
    import std.process: environment;

    const dpath = environment.get("DPATH", "");
    const home = environment.get("DUB_HOME", dpath.length
        ? buildPath(dpath, "dub") : buildPath(environment.get("HOME", ""), ".dub"));
    return buildPath(home, "cache");
}


// dub runs the pre-build commands of a project when its target is out of
// date, before it compiles. The front end reads the project without dub's
// build, so run the commands here, in the lambda that describes the project:
// the cache of the description keeps its record while its watched inputs are
// unchanged, and then the project is up to date and nothing runs. When the
// cache is stale or off, they run. dub runs the pre-generate commands itself
// when it describes the project, so they are not run here. The description
// and its file list are already read when the commands run: a file they write
// is there for the front end to import, but the description does not list it.
// They run in the root package directory, with the variables that dub gives
// them.
private void runPreBuildCommands(
    imported!"dub.dub".Dub dub,
    in imported!"dub.generators.generator".GeneratorSettings settings,
    in imported!"dub.description".ProjectDescription project,
) {
    import dub.generators.generator: CommandType, makeCommandEnvironmentVariables;
    import dub.project: processVars;
    import snakebite.exception: SnakebiteException;
    import std.conv: text;
    import std.process: Config, environment, executeShell;

    const buildSettings = project.rootBuildSettings;
    if (buildSettings.preBuildCommands.length == 0)
        return;

    const package_ = dub.project.rootPackage;
    const variables = makeCommandEnvironmentVariables(
        CommandType.preBuild, package_, dub.project, settings, buildSettings);
    auto commandEnvironment = environment.toAA;
    foreach (layer; variables)
        foreach (name, value; layer)
            commandEnvironment[name] = value;
    const directory = package_.path.toString;
    foreach (command; processVars(
            dub.project, package_, settings, buildSettings.preBuildCommands,
            false, variables)) {
        const run = executeShell(command, commandEnvironment, Config.none,
            size_t.max, directory);
        if (run.status != 0)
            throw new SnakebiteException(text(
                "Pre-build command failed with exit code ", run.status, ": ",
                command, "\n", run.output));
    }
}


// Let dub decide which targets are stale, including the full dependency
// chain of static-library roots. The shared image needs position-
// independent archives, which both host compilers emit by default on the
// supported platform. The build must not add a PIC flag through `DFLAGS`:
// dub keys its build-cache artifacts by `DFLAGS` too, so a build with an
// environment that the description did not see produces artifacts at paths
// the description does not name.
public void buildDubDependencies(
    in string directory, in string stateDirectory,
    in DubDescription description, in string[] linkerFiles,
) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.exception: SnakebiteException;
    import std.process: environment;
    import std.algorithm: all;
    import std.file: exists, mkdirRecurse, readText, write, remove, rmdir;
    import std.path: buildPath;

    const statePath = buildPath(stateDirectory, "dub-dependencies");
    const fingerprint = dependencyFingerprint(directory, description);
    const before = fileFingerprint(linkerFiles);
    if (linkerFiles.all!exists && statePath.exists
            && statePath.readText == fingerprint ~ before)
        return;

    const wrapperDirectory = rootCompilerWrapper(description, stateDirectory);
    scope(exit) if (wrapperDirectory.length) {
        remove(buildPath(wrapperDirectory, defaultCompiler));
        rmdir(wrapperDirectory);
    }
    auto dub = loadedDub(directory);
    auto settings = platformSettings(dub, description.versions);
    settings.config = description.requestedConfiguration;
    settings.buildType = description.project.buildType;
    settings.buildDeep = true;

    // dub starts the compiler by name, so the wrapper has to be first in the
    // search path of this process while dub builds.
    {
        import core.sync.mutex: Mutex;
        import std.concurrency: initOnce;

        auto searchPathLock = initOnce!_searchPathLock(new Mutex);
        searchPathLock.lock;
        scope(exit) searchPathLock.unlock;
        const searchPath = environment["PATH"];
        if (wrapperDirectory.length)
            environment["PATH"] = wrapperDirectory ~ ":" ~ searchPath;
        scope(exit) environment["PATH"] = searchPath;
        try
            dub.generateProject("build", settings);
        catch (Exception exception)
            throw new SnakebiteException("Dub dependency build failed:\n" ~ exception.msg);
    }
    if (!linkerFiles.all!exists)
        throw new SnakebiteException("Dub build did not produce all dependency libraries");
    stateDirectory.mkdirRecurse;
    statePath.write(fingerprint ~ fileFingerprint(linkerFiles));
}

// Keep dub's compiler identity and dependency cache paths. Only the root
// output gets translated flags; dependencies retain their own checks.
// A real build lets dub run its hooks and report every build failure.
private string rootCompilerWrapper(
    in DubDescription description, in string stateDirectory,
) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.frontend.checks: isCheckFlag, ldcArguments;
    import std.algorithm: startsWith;
    import std.conv: octal;
    import std.json: JSONValue;
    import std.file: mkdirRecurse, setAttributes, write;
    import std.path: absolutePath, buildPath;
    import std.process: environment, escapeShellCommand;
    import std.uuid: randomUUID;

    if (defaultCompiler != "ldc2")
        return null;
    if (description.project.rootPackage !in description.project.targetLookup)
        return null;
    {
        const target = description.project.lookupTarget(description.project.rootPackage);
        const flags = target.buildSettings.dflags.dup;
        const translatedFlags = ldcArguments(flags);
        if (flags == translatedFlags)
            return null;
        const output = target.cacheArtifactPath;
        string responseArgument(in string argument) {
            import std.algorithm: canFind;
            import std.string: replace;

            return argument.canFind(' ') || argument.canFind('\t') || argument.canFind('"')
                ? "\"" ~ argument.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\""
                : argument;
        }
        string rewrite = "BEGIN {\n";
        foreach (flag; flags)
            rewrite ~= "remove[" ~ JSONValue(responseArgument(flag)).toString ~ "] = 1;\n";
        rewrite ~= "}\n!($0 in remove) { print }\nEND {\n";
        foreach (flag; translatedFlags)
            rewrite ~= "print " ~ JSONValue(responseArgument(flag)).toString ~ ";\n";
        rewrite ~= "}\n";
        string[] outputArguments;
        foreach (suffix; ["", ".o"])
            foreach (prefix; ["-of", "-of=", "--of="])
                outputArguments ~= ["-e", responseArgument(prefix ~ output ~ suffix)];
        string[] checkArguments;
        foreach (flag; flags)
            if (isCheckFlag(flag) || flag.startsWith("@"))
                checkArguments ~= ["-e", responseArgument(flag)];
        const directory = buildPath(stateDirectory,
            "dub-compiler-" ~ randomUUID.toString).absolutePath;
        directory.mkdirRecurse;
        const script = "#!/bin/bash\nPATH="
            ~ escapeShellCommand([environment["PATH"]]) ~ "\nexport PATH\n"
            // dub serializes one argument per line in its compiler response
            // file. Replace those records, not the response-file grammar.
            ~ "for arg in \"$@\"; do\ncase \"$arg\" in @*)\nfile=${arg:1}\n"
            ~ "if grep -Fxq " ~ escapeShellCommand(outputArguments) ~ " -- \"$file\""
            ~ " && grep -Fxq " ~ escapeShellCommand(checkArguments) ~ " -- \"$file\"; then\n"
            ~ "temporary=$(mktemp " ~ escapeShellCommand([buildPath(directory, "arguments.XXXXXX")]) ~ ") || exit 1\n"
            ~ "trap 'rm -f -- \"$temporary\"' EXIT\nawk " ~ escapeShellCommand([rewrite])
            ~ " \"$file\" > \"$temporary\" || exit 1\n"
            ~ "args=()\nfor original in \"$@\"; do\n"
            ~ "if [[ $original == \"$arg\" ]]; then args+=(\"@$temporary\"); else args+=(\"$original\"); fi\ndone\n"
            ~ "ldc2 \"${args[@]}\"\nexit $?\nfi\n;;\nesac\ndone\n"
            ~ "root=false\nfor arg in \"$@\"; do\ncase \"$arg\" in\n"
            ~ escapeShellCommand(["-of" ~ output]) ~ "|"
            ~ escapeShellCommand(["-of=" ~ output]) ~ "|"
            ~ escapeShellCommand(["--of=" ~ output]) ~ "|"
            ~ escapeShellCommand(["-of" ~ output ~ ".o"]) ~ "|"
            ~ escapeShellCommand(["-of=" ~ output ~ ".o"]) ~ "|"
            ~ escapeShellCommand(["--of=" ~ output ~ ".o"])
            ~ ") root=true;;\nesac\ndone\n"
            ~ "if $root; then\nargs=(\"$@\")\nflags=(" ~ escapeShellCommand(flags) ~ ")\n"
            ~ "for ((i=0; i<=${#args[@]}-${#flags[@]}; ++i)); do\nmatch=true\n"
            ~ "for ((j=0; j<${#flags[@]}; ++j)); do\n"
            ~ "if [[ ${args[i+j]} != \"${flags[j]}\" ]]; then match=false; break; fi\ndone\n"
            ~ "if $match; then\nexec ldc2 \"${args[@]:0:i}\" "
            ~ escapeShellCommand(translatedFlags)
            ~ " \"${args[@]:i+${#flags[@]}}\"\nfi\ndone\nfi\nexec ldc2 \"$@\"\n";
        const path = buildPath(directory, defaultCompiler);
        path.write(script);
        path.setAttributes(octal!700);
        return directory;
    }
}


// The full description provides dependency sources that the root's flat
// import-files list does not contain. Root source contents are excluded:
// editing a guest module must not cause another native build.
public string dependencyFingerprint(in string directory, in DubDescription description) {
    import snakebite.dubcache: toJson;
    import std.conv: text;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.process: environment;
    import snakebite.dependencyimage: defaultCompiler;

    return text("snakebite-dub-v3", defaultCompiler, __VERSION__,
        environment.get("DFLAGS", ""), environment.get("LFLAGS", ""),
        toJson(description).toString,
        fileFingerprint(dubInputs(directory, description))).sha256Of.toHexString.idup;
}


public string[] dubInputs(in string directory, in DubDescription description) {
    import dub.description: SourceFileRole;
    import std.path: buildPath;

    const project = description.project;
    string[] files = [buildPath(directory, "dub.selections.json")];
    foreach (package_; project.packages) {
        if (!package_.active)
            continue;
        files ~= [buildPath(package_.path, "dub.json"), buildPath(package_.path, "dub.sdl"),
            buildPath(package_.path, "dub.selections.json")];
        if (package_.name == project.rootPackage)
            continue;
        foreach (file; package_.files)
            with (SourceFileRole)
                if (file.role == source || file.role == import_
                        || file.role == stringImport)
                    files ~= buildPath(package_.path, file.path);
    }
    foreach (target; project.targets)
        files ~= target.buildSettings.extraDependencyFiles;
    return files;
}


private string fileFingerprint(in string[] files) {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.file: exists, isFile, read;
    import std.conv: text;

    string result;
    foreach (file; files)
        result ~= text(file.length, ":", file, ":",
            file.exists && file.isFile ? read(file).sha256Of.toHexString.idup : "missing");
    return result.sha256Of.toHexString.idup;
}
