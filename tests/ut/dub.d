module ut.dub;


import snakebite.dub: parseDescribeLists, dubDescribeProject;
import snakebite.dubcache: cachedDubDescription;
import snakebite.dependencyimage: defaultCompiler;
import snakebite.project: projectStateDirectory, sourceSet;
import std.json: JSONValue, parseJSON;
import std.file: write, remove, rename, readText;
import std.path: buildPath;
import std.process: execute, Config, environment;
import std.algorithm: any, endsWith, canFind;
import ut;

@("cache.reusesDescriptionsAndRefreshesBuildInputs")
@Serial
unittest {
    const sandbox = Sandbox();
    const recipe = `name "cached-app"
configuration "unittest" {
    targetType "executable"
    mainSourceFile "source/main.d"
}
`;
    sandbox.writeFile("app/dub.sdl", recipe);
    sandbox.writeFile("app/source/main.d", "module main; void main() {}\n");
    const directory = sandbox.inSandboxPath("app");
    size_t calls;
    JSONValue describe() {
        ++calls;
        const arguments = ["--config=unittest", "--build=unittest"];
        const output = execute(["dub", "describe", "--compiler=" ~ defaultCompiler]
            ~ arguments, null, Config.none, size_t.max, directory);
        output.status.should == 0;
        return JSONValue(["value": parseJSON(output.output), "arguments": JSONValue(arguments)]);
    }
    void load() { cachedDubDescription(directory, defaultCompiler, null, &describe); }
    load();
    load();
    calls.should == 1;
    write(buildPath(directory, "source/main.d"), "module main; void main() { int x; }\n");
    load();
    calls.should == 1;
    sandbox.writeFile("app/source/replacement.tmp", "module main; void main() {}\n");
    rename(buildPath(directory, "source/replacement.tmp"), buildPath(directory, "source/main.d"));
    load();
    calls.should == 1;
    sandbox.writeFile("app/source/extra.d", "module extra;\n");
    load();
    calls.should == 2;
    sourceSet(directory, null, null).files.any!(f => f.endsWith("extra.d")).should == true;
    remove(buildPath(directory, "source/extra.d"));
    load();
    calls.should == 3;
    write(buildPath(directory, "dub.sdl"), recipe ~ "versions \"Changed\"\n");
    load();
    calls.should == 4;
    sourceSet(directory, null, null).flags.compilerArguments.any!(f => f == "-version=Changed").should == true;
    cachedDubDescription(directory, defaultCompiler, ["Extra"], &describe);
    calls.should == 5;
    load();
    calls.should == 6;
    write(buildPath(projectStateDirectory(directory), "dub-description.bin"), "truncated");
    load();
    calls.should == 7;
    load();
    calls.should == 7;
    sandbox.writeFile("app/source/nested/extra.d", "module nested.extra;\n");
    load();
    calls.should == 8;
    sourceSet(directory, null, null).files.any!(f => f.endsWith("nested/extra.d")).should == true;

    const oldMode = environment.get("SNAKEBITE_DUB_CACHE", "on");
    scope(exit) environment["SNAKEBITE_DUB_CACHE"] = oldMode;
    environment["SNAKEBITE_DUB_CACHE"] = "off";
    load();
    calls.should == 9;
    environment["SNAKEBITE_DUB_CACHE"] = "refresh";
    load();
    calls.should == 10;
    environment["SNAKEBITE_DUB_CACHE"] = "on";
    load();
    calls.should == 10;
    sandbox.writeFile("app/dub.settings.json", "{}\n");
    load();
    load();
    calls.should == 12;
}

@("cache.generationHooksAreNotSkipped")
@Serial
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("app/dub.sdl", `name "hook-app"
targetType "library"
preGenerateCommands "echo hook >> hooks.log"
`);
    sandbox.writeFile("app/source/app.d", "module app;\n");
    const directory = sandbox.inSandboxPath("app");
    dubDescribeProject(directory);
    const before = readText(sandbox.inSandboxPath("app/hooks.log"));
    dubDescribeProject(directory);
    (readText(sandbox.inSandboxPath("app/hooks.log")).length > before.length).should == true;
}

@("cache.refreshesGeneratedRunnerAfterModuleRename")
@Serial
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("app/dub.sdl", "name \"renamed-app\"\ntargetType \"library\"\n");
    sandbox.writeFile("app/source/app.d", "module original_name; unittest {}\n");
    const directory = sandbox.inSandboxPath("app");
    dubDescribeProject(directory);
    dubDescribeProject(directory);
    sandbox.writeFile("app/source/app.d", "module changed_name; unittest {}\n");
    const updated = dubDescribeProject(directory);
    bool checked;
    foreach (package_; updated.value["packages"].array)
        foreach (file; package_["files"].array)
            if (file["path"].str.endsWith("dub_test_root.d")) {
                const runner = readText(buildPath(package_["path"].str, file["path"].str));
                runner.canFind("changed_name").should == true;
                runner.canFind("original_name").should == false;
                checked = true;
            }
    checked.should == true;
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
