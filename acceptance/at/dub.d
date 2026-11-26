module at.dub;

import dub.dub: SkipPackageSuppliers;
import ut;
import snakebite.project.dub: dubDescribeProject, fetchProject;
import std.conv: text;
import std.path: buildPath, absolutePath;
import std.typecons: nullable;

// These tests call the dub library, which starts the compiler and git, so
// they are not unit tests.


// Several threads describe at once, as parallel tests do. dub keeps its
// compilers in thread-local storage, so each thread needs its own.
@("describe.concurrentCallsEachHaveCompilers")
unittest {
    import core.thread: Thread;

    const sandbox = Sandbox();
    sandbox.writeFile("app/dub.sdl", "name \"app\"\ntargetType \"library\"\n");
    sandbox.writeFile("app/source/app.d", "module app;\n");
    const directory = sandbox.inSandboxPath("app");

    enum threadCount = 4;
    string[threadCount] roots;
    // A function of its own, so that each thread has its own `index`.
    Thread startDescribe(in size_t index) {
        auto thread = new Thread({
            roots[index] = dubDescribeProject(directory, [text("Thread", index)])
                .project.rootPackage;
        });
        thread.start;
        return thread;
    }

    Thread[] threads;
    foreach (index; 0 .. threadCount)
        threads ~= startDescribe(index);
    foreach (thread; threads) thread.join;

    foreach (root; roots)
        root.should == "app";
}


// dub starts the compiler of the root package through a wrapper. Building
// must not change the environment of the process, which other threads read:
// a pre-build command of the dependency prints the search path that it gets.
@("buildDubDependencies.keepsTheSearchPathOfTheProcess")
unittest {
    import snakebite.project.dub: dubSources;
    import std.file: readText;
    import std.process: environment;
    import std.string: strip;

    const sandbox = Sandbox();
    const searchPath = sandbox.inSandboxPath("search-path.txt");
    sandbox.writeFile("dependency/dub.sdl", text(
        "name \"dependency\"\ntargetType \"library\"\n",
        "preBuildCommands \"printenv PATH > ", searchPath, "\"\n"));
    sandbox.writeFile("dependency/source/dependency.d", "module dependency;\n");
    sandbox.writeFile("app/dub.json", `{
        "name": "app", "targetType": "library",
        "dependencies": {"dependency": {"path": "../dependency"}},
        "dflags": ["-check=in=off"]
    }`);
    sandbox.writeFile("app/source/app.d", "module app;\n");
    const directory = sandbox.inSandboxPath("app");

    const sources = dubSources(directory);
    sources.dependencies.build;

    readText(searchPath).strip.should == environment["PATH"];
}


@("fetchProject.usesAPackageThatIsOnDisk")
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile(".dub/packages/package/1.0.0/package/dub.sdl",
        "name \"package\"\nversion \"1.0.0\"\n");

    fetchProject("package", sandbox.sandboxPath.absolutePath, nullable(SkipPackageSuppliers.all))
        .should == buildPath(sandbox.sandboxPath.absolutePath,
            ".dub/packages/package/1.0.0/package/");
}


// A pinned version is the one used, also when another version is on disk:
// the cached 1.0.0 answers a plain `package`, but `package@2.0.0` is only
// known after a fetch.
@("fetchProject.pinnedVersionIsFetchedWhenAnotherIsOnDisk")
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile(".dub/packages/package/1.0.0/package/dub.sdl",
        "name \"package\"\nversion \"1.0.0\"\n");

    fetchProject("package@2.0.0", sandbox.sandboxPath.absolutePath, nullable(SkipPackageSuppliers.all))
        .shouldThrowWithMessage(
            "No package package was found matching the dependency 2.0.0");
}
