// Throwaway Linux prototype: binary DUB descriptions with filesystem validation.
module snapshot;

import std.algorithm: sort;
import std.array: appender;
import std.conv: text;
import std.datetime.stopwatch: AutoStart, StopWatch;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.exception: enforce;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio: writefln;
import std.string: toStringz, startsWith;

ubyte[] encode(JSONValue value) {
    auto output = appender!(ubyte[])();
    void number(ulong n) {
        foreach (i; 0 .. 8) output.put(cast(ubyte)(n >> (i * 8)));
    }
    void stringValue(string s) {
        number(s.length);
        output.put(cast(const(ubyte)[])s);
    }
    void item(JSONValue v) {
        output.put(cast(ubyte)v.type);
        final switch (v.type) {
            case JSONType.null_: case JSONType.true_: case JSONType.false_: break;
            case JSONType.integer: number(cast(ulong)v.integer); break;
            case JSONType.uinteger: number(v.uinteger); break;
            case JSONType.float_: assert(false, "No floating-point DUB fields expected");
            case JSONType.string: stringValue(v.str); break;
            case JSONType.array:
                number(v.array.length);
                foreach (child; v.array) item(child);
                break;
            case JSONType.object:
                number(v.object.length);
                foreach (key, child; v.object) { stringValue(key); item(child); }
                break;
        }
    }
    item(value);
    return output.data;
}

JSONValue decode(const(ubyte)[] bytes) {
    size_t offset;
    ulong number() {
        enforce(bytes.length - offset >= 8);
        ulong n;
        foreach (i; 0 .. 8) n |= cast(ulong)bytes[offset++] << (i * 8);
        return n;
    }
    string stringValue() {
        const length = number();
        enforce(length <= bytes.length - offset);
        const result = cast(string)bytes[offset .. offset + length];
        offset += length;
        return result;
    }
    JSONValue item() {
        enforce(offset < bytes.length);
        const type = cast(JSONType)bytes[offset++];
        switch (type) {
            case JSONType.null_: return JSONValue(null);
            case JSONType.true_: return JSONValue(true);
            case JSONType.false_: return JSONValue(false);
            case JSONType.integer: return JSONValue(cast(long)number());
            case JSONType.uinteger: return JSONValue(number());
            case JSONType.string: return JSONValue(stringValue());
            case JSONType.array:
                JSONValue[] children;
                const length = number();
                enforce(length <= bytes.length - offset);
                children.length = length;
                foreach (ref child; children) child = item();
                return JSONValue(children);
            case JSONType.object:
                JSONValue[string] children;
                const length = number();
                enforce(length <= bytes.length - offset);
                foreach (_; 0 .. length) { const key = stringValue(); children[key] = item(); }
                return JSONValue(children);
            default: assert(false, "Unsupported snapshot type");
        }
    }
    auto value = item();
    enforce(offset == bytes.length);
    return value;
}

string stamp(string path) {
    import core.sys.posix.sys.stat: stat_t, stat;
    import core.stdc.errno: errno, ENOENT, ENOTDIR;
    stat_t s;
    const status = stat(path.toStringz, &s);
    if (status != 0 && (errno == ENOENT || errno == ENOTDIR)) return "missing";
    enforce(status == 0, "Cannot stat " ~ path);
    // Explicit fields avoid padding and retain the previous stamp's checks.
    ulong[6] fields = [s.st_dev, s.st_ino, cast(ulong)s.st_mtim.tv_sec,
        cast(ulong)s.st_mtim.tv_nsec, cast(ulong)s.st_ctim.tv_sec,
        cast(ulong)s.st_ctim.tv_nsec];
    return (cast(const(char)[])fields[]).idup;
}

JSONValue watches(JSONValue description) {
    JSONValue[string] watched;
    void directory(string path) {
        if (path in watched) return;
        watched[path] = JSONValue(watchValue(stamp(path), entries(path)));
        if (!path.exists || !path.isDir) return;
        foreach (entry; dirEntries(path, SpanMode.shallow)) {
            if (entry.name.baseName == ".git" || entry.name.baseName == ".dub"
                || entry.name.baseName == ".snakebite") continue;
            if (entry.isDir && !entry.isSymlink) directory(entry.name);
        }
    }
    foreach (pack; description["packages"].array) {
        const path = pack["path"].str.buildNormalizedPath;
        directory(path);
        foreach (file; ["dub.json", "dub.sdl", "dub.selections.json"])
            watched[buildPath(path, file)] = JSONValue(watchValue(stamp(buildPath(path, file))));
        foreach (key; ["importPaths", "stringImportPaths"])
            foreach (entry; pack[key].array)
                directory(buildPath(path, entry.str).buildNormalizedPath);
    }
    return JSONValue(watched);
}

string watchValue(string stampValue, string entryValue = null) {
    return (entryValue.length ? "D" : "F") ~ cast(char)stampValue.length
        ~ stampValue ~ entryValue;
}

string entries(string path) {
    if (!path.exists || !path.isDir) return "missing";
    string[] names;
    foreach (entry; dirEntries(path, SpanMode.shallow))
        names ~= text(entry.name.baseName, ":", entry.isDir, ":", entry.isSymlink);
    names.sort;
    return text(names).sha256Of.toHexString.idup;
}

int main(string[] args) {
    if (args.length == 2 && args[1] == "--test") return testCache();
    enforce(args.length >= 3, "snapshot PROJECT CACHE [--freeze-hooks|--refresh]");
    const root = args[1].absolutePath.buildNormalizedPath;
    const cache = args[2].absolutePath;
    bool freezeHooks;
    bool refresh;
    bool timings;
    foreach (option; args[3 .. $]) {
        if (option == "--freeze-hooks") freezeHooks = true;
        else if (option == "--refresh") refresh = true;
        else if (option == "--timings") timings = true;
        else enforce(false, "Unknown option " ~ option);
    }
    auto timer = StopWatch(AutoStart.yes);
    import std.digest.sha: SHA256;
    SHA256 digest;
    void hashString(const(char)[] value) {
        ulong[1] length = [value.length];
        digest.put(cast(const(ubyte)[])length[]);
        digest.put(cast(const(ubyte)[])value);
    }
    hashString(root);
    hashString("snapshot-flat-v1");
    import core.sys.posix.unistd: environ;
    import std.string: fromStringz;
    // The prototype is single-threaded. Borrow the environment during hashing.
    // A different entry order causes only a conservative cache miss.
    for (size_t i; environ[i] !is null; ++i) {
        const entry = environ[i].fromStringz;
        if (!entry.startsWith("_=") && !entry.startsWith("SHLVL="))
            hashString(entry);
    }
    const context = digest.finish.toHexString.idup;
    const contextTime = timer.peek;
    import core.time: Duration;
    Duration decodeTime;
    Duration checkTime;
    JSONValue record;
    bool hit;
    bool restamped;
    string reason = refresh ? "refresh" : "no cache";
    if (!refresh && cache.exists) {
        record = decode(cast(ubyte[])read(cache));
        decodeTime = timer.peek - contextTime;
        hit = record["context"].str == context;
        if (!hit) reason = "environment";
        if (hit) foreach (path, ref saved; record["watches"].object) {
            const current = stamp(path);
            const data = saved.str;
            enforce(data.length >= 2);
            const stampEnd = 2 + cast(ubyte)data[1];
            enforce(stampEnd <= data.length);
            if (current == data[2 .. stampEnd]) continue;
            if (data[0] == 'D') {
                if (entries(path) == data[stampEnd .. $]) {
                    saved = watchValue(current, data[stampEnd .. $]);
                    restamped = true;
                    continue;
                }
            }
            hit = false;
            reason = path;
            break;
        }
        if (record["hooks"].boolean && !freezeHooks) {
            hit = false;
            reason = "generation hooks";
        }
        checkTime = timer.peek - contextTime - decodeTime;
    }
    if (!hit) {
        const result = execute(["dub", "describe", "--root=" ~ root,
            "--config=unittest", "--build=unittest", "--compiler=ldc"]);
        enforce(result.status == 0, result.output);
        auto description = parseJSON(result.output);
        // The full DUB document is only needed when native dependencies rebuild.
        // Preserve it separately; the edit loop needs the root's resolved inputs.
        record = JSONValue(["context": JSONValue(context)]);
        foreach (target; description["targets"].array)
            if (target["rootPackage"].str == description["rootPackage"].str) {
                JSONValue[string] inputs;
                foreach (key; ["sourceFiles", "importPaths", "stringImportPaths",
                    "dflags", "versions", "debugVersions", "options", "lflags",
                    "libs", "linkerFiles"])
                    inputs[key] = target["buildSettings"][key];
                record["inputs"] = JSONValue(inputs);
            }
        enforce("inputs" in record, "No root target in description");
        record["packageCount"] = description["packages"].array.length;
        record["descriptionDigest"] = result.output.sha256Of.toHexString.idup;
        write(cache ~ ".description.json", result.output);
        record["context"] = context;
        record["watches"] = watches(description);
        bool hooks;
        foreach (pack; description["packages"].array)
            if (pack["active"].boolean)
                foreach (key; ["preGenerateCommands", "postGenerateCommands"])
                    hooks = hooks || pack[key].array.length != 0;
        record["hooks"] = hooks;
        const bytes = encode(record);
        assert(decode(bytes) == record, "Binary round trip changed the description");
        write(cache, bytes);
    }
    if (hit && restamped) write(cache, encode(record));
    const elapsed = timer.peek.total!"nsecs" / 1_000_000.0;
    writefln("%s %.3f ms; %s watched paths; hooks=%s; %s packages; %s bytes",
        hit ? "HIT" : "MISS", elapsed, record["watches"].object.length,
        record["hooks"].boolean, record["packageCount"].uinteger,
        getSize(cache));
    if (!hit) writefln("Reason: %s", reason);
    if (timings) writefln("context=%s us read+decode=%s us checks=%s us",
        contextTime.total!"usecs", decodeTime.total!"usecs", checkTime.total!"usecs");
    return 0;
}

int testCache() {
    import std.uuid: randomUUID;
    const base = buildPath(tempDir, "snakebite-snapshot-test-" ~ randomUUID.toString);
    const project = buildPath(base, "project");
    const source = buildPath(project, "source");
    source.mkdirRecurse;
    scope(exit) rmdirRecurse(base);
    const recipe = buildPath(project, "dub.sdl");
    const moduleFile = buildPath(source, "app.d");
    const cache = buildPath(base, "cache.bin");
    const recipeText = "name \"snapshot-test\"\ntargetType \"library\"\n";
    write(recipe, recipeText);
    write(moduleFile, "module app; unittest { assert(true); }\n");
    size_t checks;
    void expect(string prefix, string[] options = null) {
        const result = execute([thisExePath, project, cache] ~ options);
        enforce(result.status == 0 && result.output.startsWith(prefix), result.output);
        ++checks;
    }
    expect("MISS");
    expect("HIT");
    write(moduleFile, "module app; unittest { assert(1 == 1); }\n");
    expect("HIT");
    const replacement = buildPath(source, "replacement.tmp");
    write(replacement, "module app; unittest { assert(2 == 2); }\n");
    rename(replacement, moduleFile);
    expect("HIT");
    const added = buildPath(source, "added.d");
    write(added, "module added;\n");
    expect("MISS");
    expect("HIT");
    remove(added);
    expect("MISS");
    const nested = buildPath(source, "nested");
    nested.mkdir;
    expect("MISS");
    write(buildPath(nested, "newfile.d"), "module nested.newfile;\n");
    expect("MISS");
    write(recipe, recipeText ~ "versions \"Changed\"\n");
    expect("MISS");
    expect("HIT");
    expect("MISS", ["--refresh"]);
    const variable = "SNAKEBITE_SNAPSHOT_TEST_CONTEXT";
    const previous = environment.get(variable, "");
    const existed = variable in environment;
    environment[variable] = previous ~ "changed";
    expect("MISS");
    expect("HIT");
    if (existed) environment[variable] = previous;
    else environment.remove(variable);
    expect("MISS");
    expect("HIT");
    write(recipe, recipeText ~ "preGenerateCommands \"true\"\n");
    expect("MISS");
    expect("MISS");
    expect("HIT", ["--freeze-hooks"]);
    writefln("%s cache behavior checks passed", checks);
    return 0;
}
