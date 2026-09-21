module ut.project;


import snakebite.dub: DubDescription;
import snakebite.project: dubSourceSetFromDescription,
    projectStateDirectory, sourceSet;
import std.algorithm.searching: any, endsWith;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.file: getcwd;
import std.path: absolutePath, buildNormalizedPath, buildPath, dirName;
import ut;
import ut.backends;


@("stateDirectoryIsCwdScopedAndProjectPartitioned")
unittest {
    const cwd = getcwd;
    const firstProject = "projects/first".absolutePath.buildNormalizedPath;
    const secondProject = "projects/second".absolutePath.buildNormalizedPath;
    const first = projectStateDirectory("projects/first");
    const second = projectStateDirectory("projects/second");

    first.should == buildPath(cwd, ".snakebite",
        firstProject.sha256Of.toHexString.idup);
    second.should == buildPath(cwd, ".snakebite",
        secondProject.sha256Of.toHexString.idup);
    first.should.not == second;
}


@("sourceSet.loadsPackageRecordsWithoutTargets")
unittest {
    import std.json: parseJSON;

    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings").absolutePath;
    auto description = DubDescription(parseJSON(`{
        "rootPackage": "root",
        "configuration": "unittest",
        "targets": [],
        "packages": [
            {
                "name": "root", "configuration": "unittest",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "tests/main.d"}],
                "importPaths": ["source"], "stringImportPaths": [],
                "linkerFiles": [], "dflags": [], "debugVersions": [],
                "options": [], "versions": [], "lflags": [], "libs": []
            },
            {
                "name": "dependency", "configuration": "library",
                "active": true, "path": "` ~ directory ~ `",
                "files": [{"role": "source", "path": "source/package.d"}],
                "importPaths": ["source"], "stringImportPaths": []
            }
        ]
    }`));

    const sources = dubSourceSetFromDescription(directory, description);

    sources.files.length.should == 1;
    sources.files[0].endsWith("tests/main.d").should == true;
    sources.importPaths.length.should == 2;
}


@("sourceSet.loadsDubPackageSettings")
unittest {
    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings");
    const sources = sourceSet(directory, null, null);

    sources.files.any!(path => path.endsWith("tests/main.d")).should == true;
    sources.importPaths.any!(path => path.endsWith("source/")).should == true;
}


// dub compiles a package from its own directory with paths relative to
// it, so a root module's `__FILE__` is that relative path, whether or
// not the file lies under an import path. A project loaded here names
// its root modules the same way, relative to the project directory,
// whatever the current working directory is.
static foreach (backend; Matrix!()) {
    @("rootModuleFileIsRelativeToProjectDirectory." ~ backend.stringof)
    @Serial
    unittest {
        enum moduleName = "file_name_" ~ backend.stringof;
        const relativePath = "sub/" ~ moduleName ~ ".d";
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", dubProjectRecipe("filename",
            "sourcePaths \"sub\"\nimportPaths \"imports\"\n"));
        sandbox.writeFile("app/imports/.keep");
        sandbox.writeFile("app/" ~ relativePath,
            "module " ~ moduleName ~ ";\n"
            ~ "int main() { return __FILE__ == \"" ~ relativePath ~ "\" ? 0 : 1; }\n");
        dubProjectMainShouldSucceed!backend(sandbox.inSandboxPath("app"));
    }
}


// A dub recipe whose unittest configuration is an executable: dub's own
// synthetic unittest configuration would put a generated stub with its
// own `main` first, and a program takes the first root `main` it finds.
private string dubProjectRecipe(in string name, in string settings = "") {
    return "name \"" ~ name ~ "\"\ntargetType \"library\"\n" ~ settings
        ~ "configuration \"unittest\" {\n    targetType \"executable\"\n}\n";
}

// The dub project at `directory` has a `main` that returns 0: run through
// dub itself for the native oracle, or through the backend.
private void dubProjectMainShouldSucceed(backend)(in string directory) {
    import snakebite.backends.backend: run;
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.execution: prepareProject;
    import std.process: Config, execute;

    static if (is(backend == Native)) {
        const result = execute(
            ["dub", "run", "-q", "--config=unittest",
                "--compiler=" ~ defaultCompiler],
            null, Config.none, size_t.max, directory);
        result.status.shouldEqual(0, result.output);
    } else {
        auto project = prepareProject(directory).project;
        scope instance = new backend(project.program);
        run(instance, project.program).should == 0;
    }
}
