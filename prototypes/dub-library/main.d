// Throwaway measurement tool. No cache invalidation is implemented.
module main;

import dub.commandline: runDubCommandLine;
import dub.compilers.compiler: getCompiler;
import dub.description: ProjectDescription;
import dub.dub: Dub;
import dub.generators.generator: GeneratorSettings;
import dub.internal.logging: LogLevel, setLogLevel;
import dub.internal.vibecompat.data.json: serializeToPrettyJson;
import dub.internal.vibecompat.inet.path: NativePath;
import dub.packagemanager: PackageManager;
import std.algorithm: sort;
import std.conv: to;
import std.datetime.stopwatch: StopWatch;
import std.file: thisExePath;
import std.json: JSONValue, parseJSON;
import std.path: absolutePath, buildNormalizedPath, buildPath;
import std.process: execute;
import std.stdio: writefln, writeln;

// Virtual dispatch lets fresh Dub objects share the package manager, as in reggae.
class CachedDub : Dub {
    static PackageManager cached;

    this(string root) { super(root); }

    override PackageManager makePackageManager() {
        if (cached is null) cached = super.makePackageManager();
        return cached;
    }
}

GeneratorSettings settingsFor(Dub dub, string root) {
    GeneratorSettings settings;
    settings.compiler = getCompiler("dmd");
    settings.platform = settings.compiler.determinePlatform(
        settings.buildSettings, "dmd", "");
    settings.buildType = "debug";
    settings.config = dub.project.getDefaultConfiguration(settings.platform);
    settings.cache = NativePath(buildPath(root, ".dub"));
    return settings;
}

void measure(string label, size_t count, void delegate() action) {
    double[] times;
    foreach (_; 0 .. count) {
        auto timer = StopWatch();
        timer.start;
        action();
        timer.stop;
        times ~= timer.peek.total!"nsecs" / 1_000_000.0;
    }
    const first = times[0];
    times.sort;
    writefln("%-26s first=%9.3f median=%9.3f min=%9.3f max=%9.3f ms",
        label, first, times[count / 2], times[0], times[$ - 1]);
}

string[] sourceKeys(JSONValue value) {
    string[] keys;
    foreach (target; value["targets"].array)
        foreach (source; target["buildSettings"]["sourceFiles"].array)
            keys ~= target["rootPackage"].str ~ ":" ~ source.str;
    keys.sort;
    return keys;
}

int main(string[] args) {
    if (args.length > 1 && args[1] == "--cli")
        return runDubCommandLine([args[0]] ~ args[2 .. $]);

    assert(args.length >= 2, "Usage: prototype PROJECT [REPETITIONS]");
    // NativePath needs a directory path for relative dependency selections.
    const root = buildNormalizedPath(args[1].absolutePath) ~ "/";
    const count = args.length > 2 ? args[2].to!size_t : 7;
    assert(count > 0);
    setLogLevel(LogLevel.error);
    size_t packages;
    size_t sourceFiles;
    string[] expectedSources;
    size_t sink;

    void check(ProjectDescription description) {
        auto value = parseJSON(description.serializeToPrettyJson());
        assert(value["packages"].array.length == packages);
        size_t files;
        foreach (target; value["targets"].array)
            files += target["buildSettings"]["sourceFiles"].array.length;
        assert(files == sourceFiles, "Source count differs from the CLI");
        assert(sourceKeys(value) == expectedSources,
            "Target source paths differ from the CLI");
        sink += files;
    }

    writeln("Project: ", root);
    // The CLI and library use the same source, compiler and optimization flags.
    measure("CLI + JSON parse", count, {
        const result = execute([thisExePath(), "--cli", "describe",
            "--root=" ~ root, "--compiler=dmd", "--cache=local"]);
        assert(result.status == 0, result.output);
        auto value = parseJSON(result.output);
        packages = value["packages"].array.length;
        sourceFiles = 0;
        foreach (target; value["targets"].array)
            sourceFiles += target["buildSettings"]["sourceFiles"].array.length;
        expectedSources = sourceKeys(value);
    });

    ProjectDescription result;
    measure("Fresh Dub + description", count, {
        auto dub = new Dub(root);
        dub.loadPackage;
        dub.project.validate;
        result = dub.project.describe(settingsFor(dub, root));
    });
    check(result);

    measure("Shared PM + description", count, {
        auto dub = new CachedDub(root);
        dub.loadPackage;
        dub.project.validate;
        result = dub.project.describe(settingsFor(dub, root));
    });
    check(result);

    auto loaded = new CachedDub(root);
    loaded.loadPackage;
    loaded.project.validate;
    auto settings = settingsFor(loaded, root);
    measure("Loaded project describe", count, {
        result = loaded.project.describe(settings);
    });
    check(result);
    measure("Serialize + parse JSON", count, {
        sink += parseJSON(result.serializeToPrettyJson())["packages"].array.length;
    });
    measure("Read cached source lists", count, {
        foreach (target; result.targets)
            foreach (source; target.buildSettings.sourceFiles)
                sink += source.length;
    });
    writefln("Checked: %s packages, %s target source entries; sink=%s",
        packages, sourceFiles, sink);
    return 0;
}
