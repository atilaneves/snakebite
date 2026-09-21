module snakebite.dubcache;

private:

// A cache miss always delegates semantics and generation to DUB.
public imported!"std.json".JSONValue cachedDubDescription(
    in string directory, in string compiler, in string[] versions,
    scope imported!"std.json".JSONValue delegate() describe,
) {
    import std.json: JSONValue, JSONType;
    import std.file: exists, read, write, mkdirRecurse, rename, FileException;
    import std.path: buildPath, dirName;
    import std.process: environment;
    import std.uuid: randomUUID;
    import std.conv: text;
    import snakebite.project: projectStateDirectory;

    const mode = environment.get("SNAKEBITE_DUB_CACHE", "on");
    if (mode == "off")
        return describe();
    const context = contextKey(directory, compiler, versions);
    const cache = buildPath(projectStateDirectory(directory), "dub-description.bin");
    // Cache failures must not prevent a normal DUB invocation.
    try {
        if (mode != "refresh" && cache.exists) {
            JSONValue saved;
            if (decode(cast(ubyte[])read(cache), saved)
                    && saved.type == JSONType.object
                    && "context" in saved && saved["context"].type == JSONType.string
                    && saved["context"].str == context && "result" in saved
                    && "watches" in saved && validWatches(saved["watches"]))
                return saved["result"];
        }
    } catch (FileException) {
        // Another process can remove the cache during a read.
    }

    import std.datetime.systime: Clock;
    const started = Clock.currTime;
    auto result = describe(); // The cache record stores mutable JSON values.
    try {
        bool cacheable = true;
        auto watched = collectWatches(directory, compiler, result["value"], cacheable); // JSON stores mutable values.
        // Do not publish an input snapshot taken across a concurrent edit.
        foreach (path, value; watched.object) {
            import std.file: timeLastModified;
            if (path.exists && timeLastModified(path) > started) cacheable = false;
        }
        if (cacheable && context == contextKey(directory, compiler, versions)) {
            const record = JSONValue([
                "context": JSONValue(context), "watches": watched, "result": result,
            ]);
            const bytes = encode(record);
            cache.dirName.mkdirRecurse;
            const temporary = text(cache, ".", randomUUID);
            import std.file: remove;
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
        cast(ulong)value.st_ctim.tv_sec, cast(ulong)value.st_ctim.tv_nsec];
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

private imported!"std.json".JSONValue collectWatches(
    in string root, in string compiler,
    in imported!"std.json".JSONValue description, ref bool cacheable,
) {
    import std.json: JSONValue;
    import std.file: exists, isDir, isSymlink, dirEntries, SpanMode, readText, getcwd;
    import std.path: buildPath, baseName, dirName, absolutePath, buildNormalizedPath;
    import std.process: environment;
    import std.string: split;
    import std.algorithm: canFind;
    import snakebite.project: projectStateDirectory;

    string[string] watched;
    foreach (package_; description["packages"].array)
        foreach (key; ["preGenerateCommands", "postGenerateCommands"])
            if (package_["active"].boolean && package_[key].array.length) {
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
                if (recipe.canFind("..") || recipe.canFind("$")
                        || recipe.canFind("\"/") || recipe.canFind("\"~")
                        || recipe.canFind("\\") || recipe.canFind("`")
                        || recipe.canFind(".dub") || recipe.canFind(".git")
                        || recipe.canFind(".snakebite"))
                    cacheable = false;
            }
        }
    }
    foreach (package_; description["packages"].array) {
        const path = package_["path"].str;
        directory(path);
        foreach (name; ["dub.json", "dub.sdl", "package.json", "dub.selections.json"])
            file(buildPath(path, name));
        foreach (key; ["importPaths", "stringImportPaths"])
            foreach (item; package_[key].array) directory(buildPath(path, item.str));
        foreach (item; package_["files"].array) {
            const source = buildPath(path, item["path"].str);
            directory(source.dirName);
            // Generated runner contents are an input even when their name stays.
            if (source.canFind("/.dub/") || source.canFind("/.dub/cache/")) file(source);
            // DUB reads module declarations when it generates its test runner.
            if (package_["name"].str == description["rootPackage"].str
                    && package_["mainSourceFile"].str.canFind("dub_test_root.d"))
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
                "packages/local-overrides.json"])
            file(buildPath(path, name));
    foreach (binary; ["dub", compiler]) {
        string resolved;
        foreach (path; environment.get("PATH", "").split(":")) {
            const candidate = buildPath(path, binary).absolutePath;
            file(candidate);
            if (candidate.exists) { resolved = candidate; break; }
        }
        if (resolved.length) {
            import std.path: absolutePath;
            import std.file: readLink;
            // Compiler installations commonly expose binaries through links.
            while (resolved.isSymlink) {
                resolved = readLink(resolved).absolutePath(resolved.dirName).buildNormalizedPath;
                file(resolved);
            }
            if (binary == "dub")
                settings(buildPath(resolved.dirName, "../etc/dub/settings.json").buildNormalizedPath);
            foreach (name; ["dmd.conf", "ldc2.conf"])
                foreach (path; [root, getcwd, environment.get("HOME", ""), resolved.dirName,
                        buildPath(resolved.dirName, "../etc"), "/etc"]) {
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
        final switch (v.type) {
            case JSONType.null_: case JSONType.true_: case JSONType.false_: break;
            case JSONType.integer: number(cast(ulong)v.integer); break;
            case JSONType.uinteger: number(v.uinteger); break;
            case JSONType.float_:
                const d = v.floating;
                number(*cast(const(ulong)*)&d);
                break;
            case JSONType.string: stringValue(v.str); break;
            case JSONType.array:
                number(v.array.length); foreach (child; v.array) item(child); break;
            case JSONType.object:
                number(v.object.length);
                foreach (key, child; v.object) { stringValue(key); item(child); }
                break;
        }
    }
    item(value);
    return cast(ubyte[])output.data.sha256Of[] ~ output.data;
}

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
        const n = number();
        if (n > bytes.length - offset) { valid = false; return null; }
        const result = cast(string)bytes[offset .. offset + n];
        offset += n;
        return result;
    }
    JSONValue item(size_t depth) {
        if (!valid || offset == bytes.length || depth > 64) { valid = false; return JSONValue(null); }
        const kind = cast(JSONType)bytes[offset++];
        switch (kind) {
            case JSONType.null_: return JSONValue(null);
            case JSONType.true_: return JSONValue(true);
            case JSONType.false_: return JSONValue(false);
            case JSONType.integer: return JSONValue(cast(long)number());
            case JSONType.uinteger: return JSONValue(number());
            case JSONType.float_:
                const bits = number(); return JSONValue(*cast(const(double)*)&bits);
            case JSONType.string: return JSONValue(stringValue());
            case JSONType.array:
                const n = number();
                if (n > bytes.length - offset) { valid = false; return JSONValue(null); }
                JSONValue[] items;
                items.length = n;
                foreach (ref child; items) { child = item(depth + 1); if (!valid) break; }
                return JSONValue(items);
            case JSONType.object:
                const n = number();
                if (n > bytes.length - offset) { valid = false; return JSONValue(null); }
                JSONValue[string] items;
                foreach (_; 0 .. n) {
                    const key = stringValue(); items[key] = item(depth + 1);
                    if (!valid) break;
                }
                return JSONValue(items);
            default: valid = false; return JSONValue(null);
        }
    }
    value = item(0);
    return valid && offset == bytes.length;
}
