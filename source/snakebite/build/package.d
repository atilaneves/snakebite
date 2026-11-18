// The build of a project with ninja (ADR-0021): the `build.ninja` file, the
// commands that ninja starts, and the ninja run. `bin/sb --build=project DIR`
// runs ninja (`buildProject`) and loads the program that the build wrote.
module snakebite.build;


private:


// What `--build` selects: no build, or one compile of the root package.
public enum Build { off, project }


// The files of the build of one project, in its project state directory.
public struct BuildFiles {
    public string directory;

    public string ninjaFile() const {
        return file("build.ninja");
    }

    // The saved Bytecode program.
    public string program() const {
        return file("project.sbc");
    }

    // What the dependency image needs from the root code, which the compile
    // writes beside the program.
    public string imageSource() const {
        return file("image.d");
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
// it and on the directory that `sb` started in, as the project state
// directory does.
public BuildFiles buildFiles(in string directory) {
    import snakebite.project.state: projectStateDirectory;
    import std.path: buildPath;

    return BuildFiles(projectStateDirectory(directory).buildPath("build"));
}


public struct NinjaRun {
    import core.time: Duration;

    public int status;
    public Duration duration;
    // The program that the build wrote, when `status` is 0.
    public string program;
}


// Runs ninja on the `build.ninja` of the project in the absolute directory
// `directory`, and writes the file first when it does not exist. ninja
// starts the commands that make the program, if they must run.
public NinjaRun buildProject(in string directory, in bool lowmem) {
    import snakebite.build.ninja: writeBuildFile;
    import std.datetime.stopwatch: AutoStart, StopWatch;
    import std.file: exists;
    import std.process: spawnProcess, wait;
    import std.stdio: stderr, stdout;

    const files = buildFiles(directory);
    if (!files.ninjaFile.exists)
        writeBuildFile(directory, lowmem);
    stdout.flush;
    stderr.flush;
    auto stopWatch = StopWatch(AutoStart.yes);
    // ninja makes `build.ninja` again only when it gets its absolute path.
    const status = spawnProcess(["ninja", "--quiet", "-f", files.ninjaFile])
        .wait;
    return NinjaRun(status, stopWatch.peek, files.program);
}


// Whether `args` are the command line of a command that ninja starts
// (`runCommand`).
public bool isCommand(in string[] args) {
    import std.algorithm.searching: any, countUntil, startsWith;

    const separator = args.countUntil("--");
    const options = separator < 0 ? args : args[0 .. separator];
    return options.any!(argument => argument == generateOption
        || argument.startsWith("--compile=", "--image="));
}


// Runs the command of a build statement that `args` gives.
public int runCommand(string[] args) {
    import snakebite.build.compile: compile;
    import snakebite.build.image: image;
    import std.algorithm.searching: canFind, startsWith;

    if (args.canFind(generateOption))
        return generate(args);
    if (args.canFind!(argument => argument.startsWith("--compile=")))
        return compile(args);
    return image(args);
}


private enum generateOption = "--generate";


// `sb --build=project --generate [--lowmem] DIR`: writes the `build.ninja`
// of the project in the absolute directory `DIR` when its text changed.
private int generate(string[] args) {
    import snakebite.build.ninja: writeBuildFile;
    import std.getopt: getopt;

    Build build;
    bool generates;
    bool lowmem;
    getopt(args, "build", &build, "generate", &generates, "lowmem", &lowmem);
    if (build != Build.project || args.length != 2)
        throw new Exception("--generate takes --build=project and one directory");
    writeBuildFile(args[1], lowmem);
    return 0;
}


// Writes `text` to `path` only when the file does not hold it, so that its
// time changes only with its content. The file is replaced whole.
public void writeChanged(in string path, in string text) {
    import std.file: exists, readText, rename, write;

    if (path.exists && path.readText == text)
        return;
    const partial = path ~ ".partial";
    partial.write(text);
    rename(partial, path);
}
