module ut.dub;


import snakebite.dub: DubDescription, dependencyFingerprint;
import snakebite.dubcache: cachedDubDescription, projectDescriptionFromJson;
import snakebite.dependencyimage: defaultCompiler, generatorKey;
import snakebite.project: projectStateDirectory;
import dub.description: ProjectDescription;
import std.json: parseJSON;
import std.file: write, remove, rename, readText, dirEntries, SpanMode;
import std.path: absolutePath, baseName, buildPath, dirName, relativePath;
import std.string: replace;
import ut;


// The cache decides from the files that a description names, and the
// description is made by a delegate, so these tests give it a recording of
// what dub says for the same project (tests/fixtures/dub-describe) and do
// not start dub. `tests/run_cli.py` checks the recordings against the real
// dub. The project of the fixture is written into the sandbox, and `@ROOT@`
// in the recording stands for the sandbox.
private ProjectDescription recordedDescription(in Sandbox sandbox, in string fixture) {
    const directory = buildPath(__FILE__.dirName, "../fixtures/dub-describe", fixture);
    foreach (entry; dirEntries(directory, SpanMode.depth))
        if (entry.isFile && entry.name.baseName != "describe.json"
                && entry.name.baseName != "describe.cmd")
            sandbox.writeFile(entry.name.relativePath(directory), readText(entry.name));
    return projectDescriptionFromJson(parseJSON(readText(buildPath(directory, "describe.json"))
        .replace("@ROOT@", sandbox.sandboxPath.absolutePath)));
}

@("cache.reusesDescriptionsAndRefreshesBuildInputs")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-app");
    const recipe = readText(sandbox.inSandboxPath("app/dub.sdl"));
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    DubDescription describe() {
        ++calls;
        return DubDescription(recorded, "unittest");
    }
    void load() { cachedDubDescription(directory, defaultCompiler, null, &describe); }
    load;
    load;
    calls.should == 1;
    write(buildPath(directory, "source/main.d"), "module main; void main() { int x; }\n");
    load;
    calls.should == 1;
    sandbox.writeFile("app/source/replacement.tmp", "module main; void main() {}\n");
    rename(buildPath(directory, "source/replacement.tmp"), buildPath(directory, "source/main.d"));
    load;
    calls.should == 1;
    sandbox.writeFile("app/source/extra.d", "module extra;\n");
    load;
    calls.should == 2;
    remove(buildPath(directory, "source/extra.d"));
    load;
    calls.should == 3;
    write(buildPath(directory, "dub.sdl"), recipe ~ "versions \"Changed\"\n");
    load;
    calls.should == 4;
    cachedDubDescription(directory, defaultCompiler, ["Extra"], &describe);
    calls.should == 5;
    load;
    calls.should == 6;
    write(buildPath(projectStateDirectory(directory),
        "dub-description-" ~ generatorKey ~ ".bin"), "truncated");
    load;
    calls.should == 7;
    load;
    calls.should == 7;
    sandbox.writeFile("app/source/nested/extra.d", "module nested.extra;\n");
    load;
    calls.should == 8;

    void loadWithMode(in string mode) {
        cachedDubDescription(
            directory, defaultCompiler, null, &describe, mode: mode);
    }
    loadWithMode("off");
    calls.should == 9;
    loadWithMode("refresh");
    calls.should == 10;
    loadWithMode("on");
    calls.should == 10;
    sandbox.writeFile("app/dub.settings.json", "{}\n");
    load;
    load;
    calls.should == 12;
}

@("cache.reusesLibraryDescriptions")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-library");
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    DubDescription describe() {
        ++calls;
        return DubDescription(recorded, "library");
    }
    void load() { cachedDubDescription(directory, defaultCompiler, null, &describe); }

    load;
    load;

    calls.should == 1;
}

@("cache.reusesDependencyDescriptions")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-app-with-dependency");
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    DubDescription describe() {
        ++calls;
        return DubDescription(recorded, "library");
    }
    void load() { cachedDubDescription(directory, defaultCompiler, null, &describe); }

    load;
    load;

    calls.should == 1;
}

// dub runs the pre-generate commands when it describes a project, so a record
// of such a project could be out of date with no input that the cache sees.
@("cache.skipsProjectsWithGenerateCommands")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-library");
    recorded.packages[0].preGenerateCommands = ["generate"];
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    DubDescription describe() {
        ++calls;
        return DubDescription(recorded, "library");
    }
    void load() { cachedDubDescription(directory, defaultCompiler, null, &describe); }

    load;
    load;

    calls.should == 2;
}

// The description is made by the library that is linked into snakebite, so a
// record is only as good as the snakebite build that made it. Two builds that
// take turns on one project each keep their record.
@("cache.keepsGeneratorsApart")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-library");
    sandbox.writeFile("generator-a", "generator a");
    sandbox.writeFile("generator-b", "generator b, a different build");
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    DubDescription describe() {
        ++calls;
        return DubDescription(recorded, "library");
    }
    void load(in string generator) {
        cachedDubDescription(directory, defaultCompiler, null, &describe,
            sandbox.inSandboxPath(generator));
    }

    load("generator-a");
    calls.should == 1;
    load("generator-b");
    calls.should == 2;
    load("generator-a");
    load("generator-b");
    calls.should == 2;
}


// The build of the dependencies asks dub for the configuration and build
// type of the description, so a change in them must rebuild the dependencies.
@("dependencyFingerprint.dependsOnBuildType")
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.inSandboxPath("app");
    ProjectDescription project;
    project.rootPackage = "app";

    auto unittestBuild = DubDescription(project, "unittest");
    unittestBuild.project.buildType = "unittest";
    auto debugBuild = DubDescription(project, "library");
    debugBuild.project.buildType = "debug";

    (dependencyFingerprint(directory, unittestBuild)
        != dependencyFingerprint(directory, debugBuild)).should == true;
}


// A dependency is built from its sources, which the description of the root
// lists; the sources of the root are not an input of that build.
@("dependencyFingerprint.followsDependencySourcesOnly")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-app-with-dependency");
    const directory = sandbox.inSandboxPath("app");
    const description = DubDescription(recorded, "library");
    const before = dependencyFingerprint(directory, description);

    sandbox.writeFile("app/source/app.d", "module app; void other() {}\n");
    dependencyFingerprint(directory, description).should == before;

    sandbox.writeFile("dependency/source/dependency.d", "module dependency; void other() {}\n");
    (dependencyFingerprint(directory, description) != before).should == true;
}


@("description.readsEnvironmentsOfTheTarget")
unittest {
    const project = projectDescriptionFromJson(parseJSON(`{
        "rootPackage": "app",
        "targets": [{"rootPackage": "app", "buildSettings": {
            "environments": {"NAME": "value"}
        }}]
    }`));

    project.lookupTarget("app").buildSettings.environments.should == ["NAME": "value"];
}


@("description.ignoresValuesOfTheWrongShape")
unittest {
    const project = projectDescriptionFromJson(parseJSON(
        `{"rootPackage": "app", "packages": "none", "targets": {}}`));

    project.rootPackage.should == "app";
    project.packages.length.should == 0;
    project.targets.length.should == 0;
}
