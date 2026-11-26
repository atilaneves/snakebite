// The build of a project with ninja (ADR-0021): the `build.ninja` file, the
// commands that ninja starts, and the ninja run. `bin/sb --build=MODE DIR`
// runs ninja (`buildProject`) and loads the program files that the build
// wrote.
module snakebite.build;


private:


// What `--build` selects: no build, one compile of the root package, one
// compile of each source file of the root package, or one compile of each
// D package of the root package. `module` and `package` are keywords of D:
// those members have a trailing underscore that the name of the mode does
// not have (`buildName`).
public enum Build { off, project, module_, package_ }


// The name of `build` on the command line.
public string buildName(in Build build) @safe pure {
    import std.conv: text;
    import std.string: chomp;

    return text(build).chomp("_");
}


// Sets `build` to the mode that `name` spells, or returns false.
public bool parseBuildName(in string name, out Build build) {
    import std.traits: EnumMembers;

    foreach (member; EnumMembers!Build)
        if (name == buildName(member)) {
            build = member;
            return true;
        }
    return false;
}


public enum validBuildNames = {
    import std.algorithm.iteration: map;
    import std.array: join;
    import std.traits: EnumMembers;

    return [EnumMembers!Build].map!buildName.join(", ");
}();


// The files of the build of one project in one mode, in its project state
// directory.
public struct BuildFiles {
    public string directory;

    public string ninjaFile() const {
        return fileName("build.ninja");
    }

    // The program file of a build of the whole root package.
    public string projectProgram() const {
        return fileName("project.sbc");
    }

    // The program files that the build writes, one path on each line. The
    // step that reads the recipe writes it, so that a run with no change
    // does not read the recipe.
    public string programListFileName() const {
        return fileName("programs");
    }

    // The lock of the build: one run at a time changes the files.
    public string lockFile() const {
        return fileName("lock");
    }

    public string image() const {
        return fileName("image.so");
    }

    // The directory that the program runs in, which only the dub recipe
    // gives. The step that reads the recipe writes it, so that a run with no
    // change does not read the recipe.
    public string workingDirectoryFileName() const {
        return fileName("working-directory");
    }

    private string fileName(in string name) const {
        import std.path: buildPath;

        return directory.buildPath(name);
    }
}


// The path of the image source (`ImageSource`) of the compile that writes the
// program file `program`: the compile writes it beside the program file.
public string imageSourcePath(in string program) @safe pure nothrow {
    import std.path: setExtension;

    return program.setExtension("image.d");
}


// The project directory `directory` is absolute. The build files depend on
// it and on the directory that `sb` started in, as the project state
// directory does, and on the mode `build`: each mode has a directory.
public BuildFiles buildFiles(in string directory, in Build build) {
    import snakebite.project.state: projectStateDirectory;
    import std.path: buildPath;

    const stateDirectory = projectStateDirectory(directory);
    return BuildFiles(stateDirectory.buildPath("build", buildName(build)));
}


public struct NinjaRun {
    import core.time: Duration;

    public Duration duration;
    // The program files that the build wrote, open. A later build replaces
    // a file under its name, so an open file keeps the program of this
    // build.
    public imported!"std.stdio".File[] programs;
    // The directory that the program runs in.
    public string workingDirectory;
    // The dependency image of the program.
    public string imagePath;
}


// One run at a time changes the build files of a project. The lock file is in
// the build directory; the lock is held while the object lives, and the
// operating system drops it when the process ends.
private struct BuildLock {
    private int descriptor = -1;

    @disable this(this);

    public this(in string path) {
        import core.sys.posix.fcntl:
            F_SETLKW, F_WRLCK, O_CLOEXEC, O_CREAT, O_RDWR, fcntl,
            flock, open;
        import core.stdc.stdio: SEEK_SET;
        import std.exception: errnoEnforce;
        import std.string: toStringz;

        descriptor = open(path.toStringz, O_RDWR | O_CREAT | O_CLOEXEC, 384);
        errnoEnforce(descriptor >= 0, "cannot open the lock file " ~ path);
        // The whole file; the call waits for the run that holds the lock.
        flock whole;
        whole.l_type = F_WRLCK;
        whole.l_whence = SEEK_SET;
        errnoEnforce(fcntl(descriptor, F_SETLKW, &whole) == 0,
            "cannot lock the file " ~ path);
    }

    public ~this() {
        import core.sys.posix.unistd: close;

        if (descriptor >= 0)
            close(descriptor);
    }
}


// Runs ninja on the `build.ninja` of mode `build` of the project in the
// absolute directory `directory`, and writes the file first when it does not
// exist. ninja starts the commands that make the program files, if they must
// run. The run holds the lock of the build from before it checks
// `build.ninja` until it has the program files open, so no other run changes
// a build file in between. The result is null when ninja fails.
public imported!"std.typecons".Nullable!NinjaRun buildProject(
    in string directory,
    in Build build,
) {
    import snakebite.build.ninja: writeBuildFile;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.file: exists, mkdirRecurse, readText;
    import std.process: spawnProcess, wait;
    import std.stdio: File, stderr, stdout;
    import std.string: splitLines;
    import std.typecons: Nullable, nullable;

    const files = buildFiles(directory, build);
    files.directory.mkdirRecurse;
    scope lock = BuildLock(files.lockFile);
    if (!files.ninjaFile.exists)
        writeBuildFile(directory, build);
    stdout.flush;
    stderr.flush;
    auto stopWatch = StopWatch(AutoStart.yes);
    // ninja makes `build.ninja` again only when it gets its absolute path.
    const status = spawnProcess(["ninja", "--quiet", "-f", files.ninjaFile])
        .wait;
    const duration = stopWatch.peek;
    if (status != 0)
        return Nullable!NinjaRun();
    const programNames = files.programListFileName.readText.splitLines;
    // `auto`: `NinjaRun` holds the files as mutable.
    auto programs = programNames.map!(program => File(program, "rb")).array;
    return nullable(NinjaRun(
        duration,
        programs,
        files.workingDirectoryFileName.readText,
        files.image,
    ));
}


// Whether `args` are the command line of a command that ninja starts
// (`runCommand`).
public bool isCommand(in string[] args) {
    import std.algorithm.searching: any, countUntil, startsWith;

    const separator = args.countUntil("--");
    const options = separator < 0 ? args : args[0 .. separator];
    return options.any!(argument => argument == generateOption
        || argument == dubDependenciesOption
        || argument.startsWith("--compile=", "--image="));
}


// Runs the command of a build statement that `args` gives.
public int runCommand(string[] args) {
    import snakebite.build.compile: compile;
    import snakebite.build.dependencies: dependencies;
    import snakebite.build.image: image;
    import std.algorithm.searching: canFind, startsWith;

    if (args.canFind(generateOption))
        return generate(args);
    if (args.canFind(dubDependenciesOption))
        return dependencies(args);
    if (args.canFind!(argument => argument.startsWith("--compile=")))
        return compile(args);
    return image(args);
}


private enum generateOption = "--generate";


// The option of the command of the dependencies statement.
public enum dubDependenciesOption = "--dub-dependencies";


// `sb --build=MODE --generate DIR`: writes the `build.ninja` of mode MODE
// of the project in the absolute directory `DIR` when its text changed.
private int generate(string[] args) {
    import snakebite.build.ninja: writeBuildFile;
    import std.getopt: getopt;

    string name;
    bool generates;
    getopt(args, "build", &name, "generate", &generates);
    Build build;
    if (!parseBuildName(name, build) || build == Build.off || args.length != 2)
        throw new Exception(
            "--generate takes a --build mode other than off and one directory",
        );
    writeBuildFile(args[1], build);
    return 0;
}


// Writes `text` to `path` only when the file does not hold it, so that its
// time changes only with its content. The file is replaced whole.
// Returns whether it wrote the file.
public bool writeChanged(in string path, in string text) {
    import std.file: exists, readText, rename, write;

    if (path.exists && path.readText == text)
        return false;
    const partial = path ~ ".partial";
    partial.write(text);
    rename(partial, path);
    return true;
}
