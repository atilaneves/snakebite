module ut.dub;


import snakebite.dub: DubDescription, dependencyFingerprint, parseDescribeLists;
import snakebite.dubcache: cachedDubDescription;
import snakebite.dependencyimage: defaultCompiler, generatorKey;
import snakebite.project: projectStateDirectory;
import std.json: JSONValue, parseJSON;
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
private JSONValue recordedDescription(in Sandbox sandbox, in string fixture) {
    const directory = buildPath(__FILE__.dirName, "../fixtures/dub-describe", fixture);
    foreach (entry; dirEntries(directory, SpanMode.depth))
        if (entry.isFile && entry.name.baseName != "describe.json"
                && entry.name.baseName != "describe.cmd")
            sandbox.writeFile(entry.name.relativePath(directory), readText(entry.name));
    return parseJSON(readText(buildPath(directory, "describe.json"))
        .replace("@ROOT@", sandbox.sandboxPath.absolutePath));
}

@("cache.reusesDescriptionsAndRefreshesBuildInputs")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-app");
    const recipe = readText(sandbox.inSandboxPath("app/dub.sdl"));
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    JSONValue describe() {
        ++calls;
        const arguments = ["--config=unittest", "--build=unittest"];
        return JSONValue(["value": recorded, "arguments": JSONValue(arguments)]);
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
    JSONValue describe() {
        ++calls;
        return JSONValue(["value": recorded,
            "arguments": JSONValue(["--build=debug"])]);
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
    JSONValue describe() {
        ++calls;
        return JSONValue(["value": recorded,
            "arguments": JSONValue(["--build=debug"])]);
    }
    void load() { cachedDubDescription(directory, defaultCompiler, null, &describe); }

    load;
    load;

    calls.should == 1;
}

// dub prints each kind's lines joined by newlines, the kinds joined by one
// blank line, then a final newline. An empty kind is nothing between two
// blank lines and must keep its place among the others.
@("parseDescribeLists.keepsEmptyKindsInPlace")
unittest {
    const output =
        "a.d\nb.d" ~ "\n\n" ~ "-checkaction=context" ~ "\n\n" ~ "" ~ "\n\n"
        ~ "Have_x" ~ "\n";

    parseDescribeLists(output, 4).should == [
        ["a.d", "b.d"],
        ["-checkaction=context"],
        [],
        ["Have_x"],
    ];
}


// Nothing follows the last blank line when the last kind is empty.
@("parseDescribeLists.trailingEmptyKinds")
unittest {
    parseDescribeLists("a.d\n\n\n", 2).should == [["a.d"], []];
    parseDescribeLists("a.d\n\n\n\n\n", 3).should == [["a.d"], [], []];
}


@("parseDescribeLists.wrongNumberOfListsThrows")
unittest {
    parseDescribeLists("a.d\n", 2).shouldThrowWithMessage(
        "dub describe printed 1 lists, expected 2:\na.d\n",
    );
    parseDescribeLists("a.d\n\n\n\n\n", 2).shouldThrowWithMessage(
        "dub describe printed 3 lists, expected 2:\na.d\n\n\n\n\n",
    );
}


@("parseDescribeLists.missingFinalNewlineThrows")
unittest {
    parseDescribeLists("a.d\n\nb.d", 2).shouldThrowWithMessage(
        "dub describe output does not end in a newline:\na.d\n\nb.d",
    );
}

// The description holds the build arguments that snakebite itself derives,
// so a record is only as good as the snakebite build that made it. Two
// builds that take turns on one project each keep their record.
@("cache.keepsGeneratorsApart")
unittest {
    const sandbox = Sandbox();
    auto recorded = recordedDescription(sandbox, "cached-library");
    sandbox.writeFile("generator-a", "generator a");
    sandbox.writeFile("generator-b", "generator b, a different build");
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    JSONValue describe() {
        ++calls;
        return JSONValue(["value": recorded,
            "arguments": JSONValue(["--build=debug"])]);
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


// `dub build` runs with the derived build arguments, so a change in them
// must rebuild the dependencies even when the description is equal.
@("dependencyFingerprint.dependsOnBuildArguments")
unittest {
    const sandbox = Sandbox();
    const directory = sandbox.inSandboxPath("app");
    const value = parseJSON(`{"rootPackage": "app", "targets": [], "packages": []}`);

    const unittestBuild = dependencyFingerprint(directory,
        DubDescription(value, ["--config=unittest", "--build=unittest"]));
    const debugBuild = dependencyFingerprint(directory,
        DubDescription(value, ["--build=debug"]));

    (unittestBuild != debugBuild).should == true;
}


// Several threads describe at once, as parallel tests do. Each call gets
// its own output and not that of a call that runs at the same time.
@("describe.concurrentCallsKeepTheirOwnOutput")
unittest {
    import core.thread: Thread;
    import snakebite.dub: describeCapturingStdout;
    import std.conv: text;

    enum threadCount = 6;
    string[threadCount] outputs;
    // A function of its own, so that each thread has its own `label`.
    Thread startDescribe(in size_t index) {
        const label = "describe-output-" ~ text(index);
        auto thread = new Thread({
            outputs[index] = describeCapturingStdout(
                ["sh", "-c", "echo " ~ label ~ "; sleep 0.3; echo " ~ label], ".").output;
        });
        thread.start;
        return thread;
    }

    Thread[] threads;
    foreach (index; 0 .. threadCount)
        threads ~= startDescribe(index);
    foreach (thread; threads) thread.join;

    foreach (index; 0 .. threadCount) {
        const label = "describe-output-" ~ text(index);
        outputs[index].should == label ~ "\n" ~ label ~ "\n";
    }
}
