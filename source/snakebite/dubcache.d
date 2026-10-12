module snakebite.dubcache;

private:

private bool decode(in ubyte[] bytes, out imported!"std.json".JSONValue value) {
    import std.json: JSONValue, JSONType;
    import std.digest.sha: sha256Of;
    if (bytes.length < 32 || bytes[0 .. 32] != bytes[32 .. $].sha256Of[]) return false;
    size_t offset = 32;
    bool valid = true;
    ulong number() {
        if (bytes.length - offset < 8) { valid = false; return 0; }
        ulong n;
        foreach (i; 0 .. 8) n |= cast(ulong)bytes[offset++] << (8 * i);
        return n;
    }
    string stringValue() {
        const n = number;
        if (n > bytes.length - offset) { valid = false; return null; }
        const result = cast(string)bytes[offset .. offset + n];
        offset += n;
        return result;
    }
    JSONValue item(size_t depth) {
        if (!valid || offset == bytes.length || depth > 64) { valid = false; return JSONValue(null); }
        const kind = cast(JSONType)bytes[offset++];
        switch (kind) with (JSONType) {
            case null_: return JSONValue(null);
            case true_: return JSONValue(true);
            case false_: return JSONValue(false);
            case integer: return JSONValue(cast(long)number);
            case uinteger: return JSONValue(number);
            case float_:
                const bits = number; return JSONValue(*cast(const(double)*)&bits);
            case string: return JSONValue(stringValue);
            case array:
                const n = number;
                if (n > bytes.length - offset) { valid = false; return JSONValue(null); }
                JSONValue[] items;
                items.length = n;
                foreach (ref child; items) { child = item(depth + 1); if (!valid) break; }
                return JSONValue(items);
            case object:
                const n = number;
                if (n > bytes.length - offset) { valid = false; return JSONValue(null); }
                JSONValue[immutable(char)[]] items;
                foreach (_; 0 .. n) {
                    const key = stringValue; items[key] = item(depth + 1);
                    if (!valid) break;
                }
                return JSONValue(items);
            default: valid = false; return JSONValue(null);
        }
    }
    value = item(0);
    return valid && offset == bytes.length;
}

// A cache miss always delegates semantics and generation to DUB.
public imported!"snakebite.dub".DubDescription cachedDubDescription(
    in string directory, in string compiler, in string[] versions,
    scope imported!"snakebite.dub".DubDescription delegate() describe,
    in string generator = imported!"snakebite.dependencyimage".runningExecutable,
    in string mode = imported!"std.process".environment.get("SNAKEBITE_DUB_CACHE", "on"),
) {
    import std.json: JSONValue, JSONType;
    import std.file: exists, read, write, mkdirRecurse, rename, remove, FileException;
    import std.path: baseName, buildPath, dirName;
    import std.uuid: randomUUID;
    import std.conv: text;
    import snakebite.dependencyimage: generatorKey;
    import snakebite.project: projectStateDirectory;

    if (mode == "off")
        return describe();
    const context = contextKey(directory, compiler, versions);
    const cache = buildPath(projectStateDirectory(directory),
        text("dub-description-", generatorKey(generator), ".bin"));
    string[string] inputStamps;
    // Cache failures must not prevent a normal DUB invocation.
    try {
        if (cache.exists) {
            JSONValue saved;
            if (decode(cast(ubyte[])read(cache), saved)
                    && saved.type == JSONType.object
                    && "context" in saved && saved["context"].type == JSONType.string
                    && saved["context"].str == context && "watches" in saved
                    && saved["watches"].type == JSONType.object) {
                foreach (path, value; saved["watches"].object)
                    inputStamps[path] = stamp(path);
                if (mode != "refresh" && "result" in saved
                        && validWatches(saved["watches"]))
                    return descriptionFromJson(saved["result"]);
            }
        }
    } catch (FileException) {
        // Another process can remove the cache during a read.
    }

    auto result = describe();
    try {
        // Creating the state directory makes `.snakebite` in the start
        // directory, which the watches below can include: create it first
        // or the first record is stale on the next start.
        cache.dirName.mkdirRecurse;
        bool cacheable = true;
        auto watched = collectWatches(directory, compiler, result.project, cacheable);
        // Do not publish an input snapshot taken across a concurrent edit.
        foreach (path, value; watched.object) {
            const generated = path.baseName == "dub.selections.json"
                || path.baseName == "dub_test_root.d";
            if (!generated && path in inputStamps && stamp(path) != inputStamps[path])
                cacheable = false;
        }
        if (cacheable && context == contextKey(directory, compiler, versions)) {
            const record = JSONValue([
                "context": JSONValue(context), "watches": watched,
                "result": toJson(result),
            ]);
            const bytes = encode(record);
            const temporary = text(cache, ".", randomUUID);
            scope(exit) if (temporary.exists) remove(temporary);
            write(temporary, bytes);
            rename(temporary, cache);
        }
    } catch (FileException) {
        // Read-only projects and cache storage still work without caching.
    }
    return result;
}

private string contextKey(in string directory, in string compiler, in string[] versions) {
    import std.digest.sha: SHA256;
    import std.digest: toHexString;
    import std.process: environment;
    import std.algorithm: sort;
    import std.conv: text;
    SHA256 digest;
    void add(in string value) {
        ulong[1] length = [value.length];
        digest.put(cast(const(ubyte)[])length[]);
        digest.put(cast(const(ubyte)[])value);
    }
    add(text("snakebite-dub-cache-2:", __VERSION__));
    add(directory);
    add(compiler);
    add(text(versions.length));
    foreach (version_; versions) add(version_);
    const variables = environment.toAA;
    foreach (key; variables.keys.sort)
        if (key != "_" && key != "SHLVL" && key != "SNAKEBITE_DUB_CACHE") {
            add(key);
            add(variables[key]);
        }
    return digest.finish.toHexString.idup;
}

private bool validWatches(in imported!"std.json".JSONValue watched) {
    import std.json: JSONType;
    if (watched.type != JSONType.object) return false;
    foreach (path, value; watched.object) {
        if (value.type != JSONType.string || value.str.length < 2) return false;
        const data = value.str;
        const end = 2 + cast(ubyte)data[1];
        if (end > data.length) return false;
        if (stamp(path) == data[2 .. end]) continue;
        if (data[0] == 'D' && entries(path) == data[end .. $]) continue;
        return false;
    }
    return true;
}

private string stamp(in string path) {
    import core.sys.posix.sys.stat: stat_t, stat;
    import core.stdc.errno: errno, ENOENT, ENOTDIR;
    import std.string: toStringz;
    import std.file: FileException;
    stat_t value;
    if (stat(path.toStringz, &value) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) return "missing";
        throw new FileException(path, "Cannot inspect DUB cache input");
    }
    ulong[7] fields = [value.st_dev, value.st_ino, value.st_mode,
        cast(ulong)value.st_mtim.tv_sec, cast(ulong)value.st_mtim.tv_nsec,
        cast(ulong)value.st_ctim.tv_sec, cast(ulong)value.st_ctim.tv_nsec,
    ];
    return (cast(const(char)[])fields[]).idup;
}

private string entries(in string path) {
    import std.file: exists, isDir, dirEntries, SpanMode;
    import std.path: baseName;
    import std.algorithm: sort;
    import std.conv: text;
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    if (!path.exists || !path.isDir) return "missing";
    string[] names;
    foreach (entry; dirEntries(path, SpanMode.shallow))
        names ~= text(entry.name.baseName, ":", entry.isDir, ":", entry.isSymlink);
    names.sort;
    return text(names).sha256Of.toHexString.idup;
}

private imported!"std.json".JSONValue collectWatches(
    in string root, in string compiler,
    in imported!"dub.description".ProjectDescription description,
    ref bool cacheable,
) {
    import std.json: JSONValue;
    import std.file: exists, isDir, isSymlink, dirEntries, SpanMode, readText, getcwd, readLink;
    import std.path: buildPath, baseName, dirName, absolutePath, buildNormalizedPath;
    import std.process: environment;
    import std.string: split;
    import std.algorithm: canFind;
    import snakebite.project: projectStateDirectory;

    string[string] watched;
    foreach (package_; description.packages)
        if (package_.active && (package_.preGenerateCommands.length
                || package_.postGenerateCommands.length)) {
            cacheable = false;
            return JSONValue(watched);
        }
    const state = projectStateDirectory(root).dirName;
    void file(in string path) {
        const value = stamp(path);
        watched[path] = "F" ~ cast(char)value.length ~ value;
    }
    void directory(in string input) {
        const path = input.absolutePath.buildNormalizedPath;
        if (path == state || path in watched) return;
        const value = stamp(path);
        watched[path] = "D" ~ cast(char)value.length ~ value ~ entries(path);
        if (!path.exists || !path.isDir) return;
        if (path.isSymlink) { cacheable = false; return; }
        foreach (entry; dirEntries(path, SpanMode.shallow)) {
            const name = entry.name.baseName;
            if (entry.isSymlink) { cacheable = false; continue; }
            if (entry.isDir) {
                if (name != ".git" && name != ".dub") directory(entry.name);
            } else if (name == "dub.json" || name == "dub.sdl" || name == "package.json") {
                file(entry.name);
                const recipe = readText(entry.name);
                // Unresolved external or variable paths cannot be inferred from
                // the description when their directories do not yet exist.
                if (recipe.canFind("$") || recipe.canFind("\"/")
                        || recipe.canFind("\"~\"")
                        || recipe.canFind("\"~/")
                        || recipe.canFind("\\") || recipe.canFind("`")
                        || recipe.canFind(".dub") || recipe.canFind(".git")
                        || recipe.canFind(".snakebite"))
                    cacheable = false;
            }
        }
    }
    foreach (package_; description.packages) {
        const path = package_.path;
        directory(path);
        foreach (name; ["dub.json", "dub.sdl", "package.json", "dub.selections.json"])
            file(buildPath(path, name));
        foreach (item; package_.importPaths ~ package_.stringImportPaths)
            directory(buildPath(path, item));
        foreach (item; package_.files) {
            const source = buildPath(path, item.path);
            directory(source.dirName);
            // Generated runner contents are an input even when their name stays.
            if (source.canFind("/.dub/")) file(source);
            // DUB reads module declarations when it generates its test runner.
            if (package_.name == description.rootPackage
                    && package_.mainSourceFile.canFind("dub_test_root.d"))
                file(source);
        }
    }
    const dpath = environment.get("DPATH", "");
    const dubHome = environment.get("DUB_HOME", dpath.length
        ? buildPath(dpath, "dub") : buildPath(environment.get("HOME", ""), ".dub"));
    void settings(in string path) {
        file(path);
        // Settings can redirect package storage and add package suppliers.
        // Let DUB handle these configurations until their inputs are tracked.
        if (path.exists) cacheable = false;
    }
    settings(buildPath(root, "dub.settings.json"));
    foreach (path; [dubHome, "/var/lib/dub", "/etc/dub"])
        settings(buildPath(path, "settings.json"));
    foreach (path; [dubHome, buildPath(root, ".dub"), "/var/lib/dub"])
        foreach (name; ["packages/local-packages.json",
                "packages/local-overrides.json",
            ])
            file(buildPath(path, name));
    foreach (binary; ["dub", compiler]) {
        string resolved;
        foreach (path; environment.get("PATH", "").split(":")) {
            const candidate = buildPath(path, binary).absolutePath;
            file(candidate);
            if (candidate.exists) { resolved = candidate; break; }
        }
        if (resolved.length) {
            // Compiler installations commonly expose binaries through links.
            while (resolved.isSymlink) {
                resolved = readLink(resolved).absolutePath(resolved.dirName).buildNormalizedPath;
                file(resolved);
            }
            if (binary == "dub")
                settings(buildPath(resolved.dirName, "../etc/dub/settings.json").buildNormalizedPath);
            foreach (name; ["dmd.conf", "ldc2.conf"])
                foreach (path; [root, getcwd, environment.get("HOME", ""), resolved.dirName,
                        buildPath(resolved.dirName, "../etc"), "/etc",
                        buildPath(environment.get("HOME", ""), ".ldc"), "/etc/ldc",
                    ]) {
                    const config = buildPath(path, name).absolutePath.buildNormalizedPath;
                    file(config);
                    if (config.exists && config.isDir) {
                        directory(config);
                        foreach (entry; dirEntries(config, SpanMode.depth))
                            file(entry.name);
                    }
                }
        }
    }
    return JSONValue(watched);
}

private ubyte[] encode(in imported!"std.json".JSONValue value) {
    import std.json: JSONValue, JSONType;
    import std.array: appender;
    import std.digest.sha: sha256Of;
    auto output = appender!(ubyte[])();
    void number(ulong n) { foreach (i; 0 .. 8) output.put(cast(ubyte)(n >> (8 * i))); }
    void stringValue(in string text) { number(text.length); output.put(cast(const(ubyte)[])text); }
    void item(in JSONValue v) {
        output.put(cast(ubyte)v.type);
        final switch (v.type) with (JSONType) {
            case null_: case true_: case false_: break;
            case integer: number(cast(ulong)v.integer); break;
            case uinteger: number(v.uinteger); break;
            case float_:
                const d = v.floating;
                number(*cast(const(ulong)*)&d);
                break;
            case string: stringValue(v.str); break;
            case array:
                number(v.array.length); foreach (child; v.array) item(child); break;
            case object:
                number(v.object.length);
                foreach (key, child; v.object) { stringValue(key); item(child); }
                break;
        }
    }
    item(value);
    return cast(ubyte[])output.data.sha256Of[] ~ output.data;
}

// The JSON of a description follows `dub describe`: a field `version_` is
// `version`, an enum is its member name and a set of flags is the list of the
// names that are set. A value of a type that this does not name is left out.
public imported!"std.json".JSONValue toJson(T)(in T value) {
    import dub.compilers.buildsettings: Flags;
    import dub.dependency: Version;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.conv: text;
    import std.json: JSONValue;
    import std.range.primitives: ElementType;
    import std.traits: EnumMembers, FieldNameTuple, isArray, isSomeString;

    static if (isSomeString!T || is(T == bool))
        return JSONValue(value);
    else static if (is(T == enum))
        return JSONValue(text(value));
    else static if (is(T == Version))
        return JSONValue(value.toString);
    else static if (is(T : const(string)[string]))
        return JSONValue(cast(string[string]) value);
    else static if (is(T == Flags!E, E)) {
        string[] names;
        static foreach (member; EnumMembers!E)
            static if (member != 0)
                if (value.values & member)
                    names ~= text(member);
        return JSONValue(names);
    } else static if (isArray!T)
        return JSONValue(value.map!(item => toJson(item)).array);
    else static if (is(T == struct)) {
        JSONValue[string] fields;
        static foreach (name; FieldNameTuple!T)
            static if (isStored!(typeof(__traits(getMember, T, name))))
                fields[jsonName(name)] = toJson(__traits(getMember, value, name));
        return JSONValue(fields);
    } else
        static assert(false, "no JSON for " ~ T.stringof);
}

public T fromJson(T)(in imported!"std.json".JSONValue value) {
    import dub.compilers.buildsettings: Flags;
    import dub.dependency: Version;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.conv: text;
    import std.json: JSONType;
    import std.range.primitives: ElementType;
    import std.traits: EnumMembers, FieldNameTuple, isArray, isSomeString;

    static if (isSomeString!T)
        return value.type == JSONType.string ? value.str : T.init;
    else static if (is(T == bool))
        return value.type == JSONType.true_;
    else static if (is(T == enum)) {
        T result;
        if (value.type == JSONType.string)
            static foreach (member; EnumMembers!T)
                if (value.str == text(member) || value.str ~ "_" == text(member))
                    result = member;
        return result;
    } else static if (is(T == Version))
        return value.type == JSONType.string && value.str.length ? Version(value.str) : T.init;
    else static if (is(T == string[string])) {
        string[string] result;
        if (value.type == JSONType.object)
            foreach (name, item; value.object)
                result[name] = item.str;
        return result;
    } else static if (is(T == Flags!E, E)) {
        T result;
        if (value.type == JSONType.array)
            foreach (item; value.array)
                static foreach (member; EnumMembers!E)
                    static if (member != 0)
                        if (item.str == text(member))
                            result.values |= member;
        return result;
    } else static if (isArray!T) {
        if (value.type != JSONType.array)
            return T.init;
        return value.array.map!(item => fromJson!(ElementType!T)(item)).array;
    } else static if (is(T == struct)) {
        T result;
        if (value.type == JSONType.object)
            static foreach (name; FieldNameTuple!T)
                static if (isStored!(typeof(__traits(getMember, T, name))))
                    if (auto item = jsonName(name) in value.object)
                        __traits(getMember, result, name) = fromJson!(typeof(__traits(getMember, T, name)))(*item);
        return result;
    } else
        static assert(false, "no JSON for " ~ T.stringof);
}

// dub does not describe the lookup of targets, so it is made here.
public imported!"dub.description".ProjectDescription projectDescriptionFromJson(
    in imported!"std.json".JSONValue value,
) {
    import dub.description: ProjectDescription;

    return withTargetLookup(fromJson!ProjectDescription(value));
}

private imported!"snakebite.dub".DubDescription descriptionFromJson(
    in imported!"std.json".JSONValue value,
) {
    import snakebite.dub: DubDescription;

    auto description = fromJson!DubDescription(value);
    description.project = withTargetLookup(description.project);
    return description;
}

private imported!"dub.description".ProjectDescription withTargetLookup(
    imported!"dub.description".ProjectDescription description,
) {
    foreach (index, target; description.targets)
        description.targetLookup[target.rootPackage] = index;
    return description;
}

private enum isStored(T) = !is(T == V[K], V, K) || is(T : const(string)[string]);

private string jsonName(in string field) {
    return field.length && field[$ - 1] == '_' ? field[0 .. $ - 1] : field;
}
