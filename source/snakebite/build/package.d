// The build of a project with ninja (ADR-0021): the `build.ninja` file, the
// commands that ninja starts, and the ninja run. `bin/sb --build=MODE DIR`
// runs ninja (`buildProject`) and loads the program that the build wrote.
module snakebite.build;


private:


// What `--build` selects: no build, one compile of the root package, or one
// compile of each module of the root package and a link of their files.
public enum Build { off, project, module_ }


// The spelling of each mode on the command line.
private immutable string[Build.max + 1] buildNames = ["off", "project", "module"];


// Sets `build` to the mode that `name` spells, or returns false.
public bool parseBuildName(in string name, out Build build) {
    foreach (member, spelling; buildNames)
        if (name == spelling) {
            build = cast(Build) member;
            return true;
        }
    return false;
}


public string buildName(in Build build) {
    return buildNames[build];
}


public enum validBuildNames = "off, project, module";


// The files of the build of one project in one mode, in its project state
// directory.
public struct BuildFiles {
    public string directory;

    public string ninjaFile() const {
        return file("build.ninja");
    }

    // The saved Bytecode program.
    public string program() const {
        return file("project.sbc");
    }

    // The file of the unit of the root file `source`, which is in the project
    // directory `project` or relative to it.
    public string unit(in string project, in string source) const {
        import std.algorithm.iteration: map;
        import std.array: join;
        import std.path: absolutePath, buildNormalizedPath, pathSplitter,
            relativePath;

        // A part `..` of the path would leave the directory of the units.
        const relative = source.absolutePath(project).buildNormalizedPath
            .relativePath(project).pathSplitter
            .map!(part => part == ".." ? "^" : part).join("/");
        return file("units/" ~ relative ~ ".sbu");
    }

    // The root files, one on each line, for the compile of each unit. The
    // compile reads the file to know which of the modules that it imports
    // are in other units. No statement has the file as an input: a compile
    // needs a root file that it does not import no more than a native
    // compile of a module needs the object files of the others.
    public string unitFiles() const {
        return file("units.list");
    }

    // What the dependency image needs from the root code, which the compile
    // writes beside the program.
    public string imageSource() const {
        return file("image.d");
    }

    // The lock of the build: one run at a time changes the files.
    public string lockFile() const {
        return file("lock");
    }

    public string image() const {
        return file("image.so");
    }

    private string file(in string name) const {
        import std.path: buildPath;

        return directory.buildPath(name);
    }
}


// The project directory `directory` is absolute. The build files depend on
// it, on the mode and on the directory that `sb` started in, as the project
// state directory does.
public BuildFiles buildFiles(in string directory, in Build build) {
    import snakebite.project.state: projectStateDirectory;
    import std.path: buildPath;

    return BuildFiles(projectStateDirectory(directory).buildPath("build",
        buildName(build)));
}


public struct NinjaRun {
    import core.time: Duration;

    public int status;
    public Duration duration;
    // The program file that the build wrote, open, when `status` is 0. A
    // later build replaces the file under its name, so the open file keeps
    // the program of this build.
    public imported!"std.stdio".File program;
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


// Runs ninja on the `build.ninja` of the project in the absolute directory
// `directory`, and writes the file first when it does not exist. ninja
// starts the commands that make the program, if they must run. The run holds
// the lock of the build from before it checks `build.ninja` until it has the
// program file open, so no other run changes a build file in between.
public NinjaRun buildProject(in string directory, in Build build) {
    import snakebite.build.ninja: writeBuildFile;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.file: exists, mkdirRecurse;
    import std.process: spawnProcess, wait;
    import std.stdio: File, stderr, stdin, stdout;

    const files = buildFiles(directory, build);
    files.directory.mkdirRecurse;
    scope lock = BuildLock(files.lockFile);
    if (!files.ninjaFile.exists)
        writeBuildFile(directory, build);
    stdout.flush;
    stderr.flush;
    auto stopWatch = StopWatch(AutoStart.yes);
    // ninja makes `build.ninja` again only when it gets its absolute path.
    // ninja writes the output of a command that ran in parallel, and its own
    // messages, to its standard output. They are messages of the frontend,
    // which `bin/sb DIR` writes to the standard error.
    const status = spawnProcess(["ninja", "--quiet", "-f", files.ninjaFile],
        stdin, stderr).wait;
    const duration = stopWatch.peek;
    return NinjaRun(status, duration,
        status == 0 ? File(files.program, "rb") : File.init);
}


// Whether `args` are the command line of a command that ninja starts
// (`runCommand`).
public bool isCommand(in string[] args) {
    import std.algorithm.searching: any, countUntil, startsWith;

    const separator = args.countUntil("--");
    const options = separator < 0 ? args : args[0 .. separator];
    return options.any!(argument => argument == generateOption
        || argument == dubDependenciesOption
        || argument.startsWith("--compile=", "--image=", "--link="));
}


// Runs the command of a build statement that `args` gives.
public int runCommand(string[] args) {
    import snakebite.build.compile: compile;
    import snakebite.build.dependencies: dependencies;
    import snakebite.build.image: image;
    import snakebite.build.link: link;
    import std.algorithm.searching: canFind, startsWith;

    if (args.canFind(generateOption))
        return generate(args);
    if (args.canFind(dubDependenciesOption))
        return dependencies(args);
    if (args.canFind!(argument => argument.startsWith("--compile=")))
        return compile(args);
    if (args.canFind!(argument => argument.startsWith("--link=")))
        return link(args);
    return image(args);
}


private enum generateOption = "--generate";


// The option of the command of the dependencies statement.
public enum dubDependenciesOption = "--dub-dependencies";


// `sb --build=MODE --generate DIR`: writes the `build.ninja` of the mode
// for the project in the absolute directory `DIR` when its text changed.
private int generate(string[] args) {
    import snakebite.build.ninja: writeBuildFile;
    import std.getopt: getopt;

    string name;
    bool generates;
    getopt(args, "build", &name, "generate", &generates);
    Build build;
    if (!parseBuildName(name, build) || build == Build.off || args.length != 2)
        throw new Exception("--generate takes a --build mode and one directory");
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
