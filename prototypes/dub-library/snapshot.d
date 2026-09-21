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
    return text(s.st_dev, ":", s.st_ino, ":", s.st_mtim.tv_sec, ":",
        s.st_mtim.tv_nsec, ":", s.st_ctim.tv_sec, ":", s.st_ctim.tv_nsec);
}

JSONValue watches(JSONValue description) {
    JSONValue[string] watched;
    void directory(string path) {
        if (path in watched) return;
        watched[path] = JSONValue(["stamp": stamp(path), "entries": entries(path)]);
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
            watched[buildPath(path, file)] = JSONValue(stamp(buildPath(path, file)));
        foreach (key; ["importPaths", "stringImportPaths"])
            foreach (entry; pack[key].array)
                directory(buildPath(path, entry.str).buildNormalizedPath);
    }
    return JSONValue(watched);
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
    foreach (option; args[3 .. $]) {
        if (option == "--freeze-hooks") freezeHooks = true;
        else if (option == "--refresh") refresh = true;
        else enforce(false, "Unknown option " ~ option);
    }
    auto timer = StopWatch(AutoStart.yes);
    string[] variables;
    foreach (key, value; environment.toAA)
        if (key != "_" && key != "SHLVL")
            variables ~= text(key.length, ":", key, value.length, ":", value);
    variables.sort;
    const context = text(root, variables).sha256Of.toHexString.idup;
    JSONValue record;
    bool hit;
    bool restamped;
    string reason = refresh ? "refresh" : "no cache";
    if (!refresh && cache.exists) {
        record = decode(cast(ubyte[])read(cache));
        hit = record["context"].str == context;
        if (!hit) reason = "environment";
        foreach (path, ref saved; record["watches"].object) {
            const current = stamp(path);
            if (saved.type == JSONType.object) {
                if (current == saved["stamp"].str) continue;
                if (entries(path) == saved["entries"].str) {
                    saved["stamp"] = current;
                    restamped = true;
                    continue;
                }
            } else if (current == saved.str) continue;
            hit = false;
            reason = path;
            break;
        }
        if (record["hooks"].boolean && !freezeHooks) {
            hit = false;
            reason = "generation hooks";
        }
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
    write(recipe, recipeText ~ "preGenerateCommands \"true\"\n");
    expect("MISS");
    expect("MISS");
    expect("HIT", ["--freeze-hooks"]);
    writefln("%s cache behavior checks passed", checks);
    return 0;
}
