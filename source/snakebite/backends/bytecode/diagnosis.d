// Investigation-only "keep going" mode for the bytecode compiler. Normal
// compilation stops at the first construct it refuses to compile
// (`compiler.d`'s `rejection`), which only ever shows one gap per bench run.
// With `SNAKEBITE_BYTECODE_DIAGNOSE` set, `rejection` also records the
// refusal here instead of (or in addition to) throwing straight away, so a
// driver that compiles many independent entry points (one per unittest, see
// `bench.benchmark`'s `--diagnose` option) can report every distinct gap it
// hit in one pass.
//
// This module never changes what gets thrown or how the normal path
// behaves: `diagnosisEnabled` is a single cached bool check, and recording
// is additive bookkeeping alongside the existing throw.
module snakebite.backends.bytecode.diagnosis;


private:


// One rejection site in `compiler.d`, identified by its own `throw
// rejection(...)` call (via `__LINE__`, supplied automatically by
// `rejection`'s default arguments - no change needed at any of its call
// sites). `exampleLimit` examples are kept per site; the rest only bump
// `count`.
private struct Site {
    size_t count;
    string[] locations;
    string[] operations;
    string[] functions;
}

private enum exampleLimit = 3;

private __gshared Site[size_t] _sites;
private __gshared bool[string] _enabledCache;


// Whether the "keep going" bookkeeping below should run at all. Cached after
// the first call: an environment lookup on every one of the compiler's many
// thousands of `rejection` calls would be wasteful, and the answer cannot
// change mid-process.
public bool diagnosisEnabled() {
    static bool cached;
    static bool checked;

    if (!checked) {
        import std.process: environment;

        cached = environment.get("SNAKEBITE_BYTECODE_DIAGNOSE") !is null;
        checked = true;
    }

    return cached;
}


// Records one rejection. `line` identifies the `throw rejection(...)` call
// in `compiler.d` that refused `operation`; `location` is where in the
// guest source the refused construct sits, and `function_` names the guest
// function being compiled when it was refused.
public void recordRejection(
    in size_t line,
    in string location,
    in string function_,
    in string operation,
) {
    auto site = line in _sites;
    if (site is null) {
        _sites[line] = Site.init;
        site = line in _sites;
    }

    ++site.count;
    if (site.locations.length < exampleLimit) {
        site.locations ~= location;
        site.operations ~= operation;
        site.functions ~= function_;
    }
}


// Prints every distinct rejection recorded so far, most-hit site first, to
// stdout. Meant for a driver like `bench --diagnose` that compiles many
// independent entry points and wants the full list at the end rather than
// stopping at the first one.
public void printBytecodeDiagnosis() {
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.stdio: writefln, writeln;

    if (_sites.length == 0) {
        writeln("bytecode diagnosis: no rejections recorded");
        return;
    }

    auto lines = _sites.keys;
    lines.sort!((a, b) => _sites[a].count > _sites[b].count);

    writefln("bytecode diagnosis: %s distinct rejection site(s)", lines.length);
    foreach (line; lines) {
        const site = _sites[line];
        writeln;
        writefln("compiler.d:%s - hit %s time(s)", line, site.count);
        foreach (i; 0 .. site.locations.length)
            writefln("  %s: %s in `%s`",
                site.locations[i], site.operations[i], site.functions[i]);
    }
}
