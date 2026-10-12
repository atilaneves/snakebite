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


// A package that is on disk is used as it is. The registry is asked only for
// a package that is not there, because `dub fetch` without a version always
// asks the registry for the latest one, over the network, even when the
// package is already on disk. `name@version` names exactly that version: a
// different cached version never stands in for it.
public string fetchProject(
    in string packageName,
    in string rootDirectory = ".",
    in imported!"std.typecons".Nullable!(imported!"dub.dub".SkipPackageSuppliers) suppliers
        = imported!"std.typecons".Nullable!(imported!"dub.dub".SkipPackageSuppliers).init,
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
        const binary = compilerBinary(directory, versions);
        ensureCompilerWrapper(binary);
        auto settings = platformSettings(dub, binary, versions);
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

// A dependency that is not on disk is fetched, as `dub test` does. When all
// dependencies are on disk, dub asks no package supplier.
private auto loadedDub(in string directory) {
    import dub.dub: Dub, UpgradeOptions;

    silenceDubLog;
    auto dub = new Dub(directory);
    dub.loadPackage;
    if (!dub.project.hasAllDependencies)
        dub.upgrade(UpgradeOptions.select);
    return dub;
}

private void silenceDubLog() {
    import dub.internal.logging: LogLevel, setLogLevel;

    setLogLevel(LogLevel.error);
}

// The platform is what the compiler reports, as in `dub describe`.
private auto platformSettings(
    imported!"dub.dub".Dub dub, in string compilerBinary, in string[] versions,
) {
    import dub.compilers.buildsettings: BuildOption;
    import dub.compilers.compiler: getCompiler;
    import dub.generators.generator: GeneratorSettings;
    import dub.internal.vibecompat.inet.path: NativePath;
    import snakebite.dependencyimage: defaultCompiler;

    GeneratorSettings settings;
    settings.compiler = getCompiler(defaultCompiler);
    settings.platform = settings.compiler.determinePlatform(
        settings.buildSettings, compilerBinary, dub.defaultArchitecture);
    settings.buildSettings.options = BuildOption.none;
    settings.buildSettings.addVersions(versions);
    settings.cache = NativePath(dubCacheDirectory);
    return settings;
}

// The directory that dub keeps its settings, packages and build cache in.
// dub's own function for this is not public, so this is its rule for the
// environment. The `dubHome` setting of a settings file is not read.
public string dubHomeDirectory() {
    import std.path: buildPath;
    import std.process: environment;

    const dpath = environment.get("DPATH", "");
    return environment.get("DUB_HOME", dpath.length
        ? buildPath(dpath, "dub") : buildPath(environment.get("HOME", ""), ".dub"));
}

private string dubCacheDirectory() {
    import std.path: buildPath;

    return buildPath(dubHomeDirectory, "cache");
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

    if (project.rootPackage !in project.targetLookup)
        return;
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
// the description does not name. For the same reason the build gets the
// compiler binary of the description.
public void buildDubDependencies(
    in string directory, in string stateDirectory,
    in DubDescription description, in string[] linkerFiles,
) {
    import snakebite.exception: SnakebiteException;
    import std.algorithm: all;
    import std.conv: text;
    import std.file: exists, mkdirRecurse, readText, write;
    import std.path: buildPath;

    const statePath = buildPath(stateDirectory, "dub-dependencies");
    const fingerprint = dependencyFingerprint(directory, description);
    const before = fileFingerprint(linkerFiles);
    if (linkerFiles.all!exists && statePath.exists
            && statePath.readText == fingerprint ~ before)
        return;

    const binary = compilerBinary(directory, description.versions);
    installCompilerWrapper(binary, description);
    auto dub = loadedDub(directory);
    auto settings = platformSettings(dub, binary, description.versions);
    settings.config = description.requestedConfiguration;
    settings.buildType = description.project.buildType;
    settings.buildDeep = true;

    // The compiler writes to the standard output and error of this process,
    // so only the project is named here.
    try
        dub.generateProject("build", settings);
    catch (Exception exception)
        throw new SnakebiteException(text(
            "Dub dependency build failed for ", description.project.rootPackage,
            " (the compiler output is above): ", exception.msg));
    if (!linkerFiles.all!exists)
        throw new SnakebiteException("Dub build did not produce all dependency libraries");
    stateDirectory.mkdirRecurse;
    statePath.write(fingerprint ~ fileFingerprint(linkerFiles));
}

// dub keeps the compiler binary in the build identity of every target, so the
// description and the build have to name the same one. With ldc2 it is a
// script in the state directory of the project, at a place that depends only
// on what the description is made from. The script of a description is
// written when the build knows the description.
private string compilerBinary(in string directory, in string[] versions) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.project: projectStateDirectory;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.path: absolutePath, buildPath;
    import std.conv: text;

    if (defaultCompiler != "ldc2")
        return defaultCompiler;
    const key = text(versions.length, versions).sha256Of.toHexString.idup;
    return buildPath(projectStateDirectory(directory).absolutePath,
        "dub-compiler-" ~ key[0 .. 16], defaultCompiler);
}

// The description starts the compiler to learn its platform.
private void ensureCompilerWrapper(in string binary) {
    import std.file: exists;

    if (!binary.exists)
        installCompilerWrapper(binary, DubDescription.init);
}

// Only the ldc2 binary is a script; dmd runs as it is.
private void installCompilerWrapper(in string binary, in DubDescription description) {
    import core.sys.posix.fcntl: O_CLOEXEC, O_CREAT, O_TRUNC, O_WRONLY, open;
    import core.sys.posix.unistd: close, write;
    import std.conv: octal;
    import std.exception: errnoEnforce;
    import std.file: mkdirRecurse, rename;
    import std.path: dirName, isAbsolute;
    import std.string: toStringz;
    import std.uuid: randomUUID;

    if (!binary.isAbsolute)
        return;
    const script = compilerWrapperScript(binary, description);
    binary.dirName.mkdirRecurse;
    // The file is closed before it gets its name, and no child process keeps
    // it open: a file that is open for writing cannot be started.
    const temporary = binary ~ "." ~ randomUUID.toString;
    const descriptor = open(temporary.toStringz,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, octal!700);
    errnoEnforce(descriptor >= 0, temporary);
    const written = write(descriptor, script.ptr, script.length);
    const closed = close(descriptor);
    errnoEnforce(written == script.length && closed == 0, temporary);
    temporary.rename(binary);
}

// Keep dub's compiler identity and dependency cache paths. Only the root
// output gets translated flags; dependencies retain their own checks.
// A real build lets dub run its hooks and report every build failure. A
// script that has nothing to translate starts the compiler as it is.
private string compilerWrapperScript(in string binary, in DubDescription description) {
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.frontend.checks: isCheckFlag, ldcArguments;
    import std.algorithm: canFind, startsWith;
    import std.json: JSONValue;
    import std.path: buildPath, dirName;
    import std.process: escapeShellCommand;
    import std.string: replace;

    enum passthrough = "#!/bin/bash\nexec " ~ defaultCompiler ~ " \"$@\"\n";
    const project = description.project;
    if (project.rootPackage !in project.targetLookup)
        return passthrough;
    const target = project.lookupTarget(project.rootPackage);
    const flags = target.buildSettings.dflags.dup;
    const translatedFlags = ldcArguments(flags);
    if (flags == translatedFlags)
        return passthrough;
    const output = target.cacheArtifactPath;
    string responseArgument(in string argument) {
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
    const directory = binary.dirName;
    return "#!/bin/bash\n"
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
