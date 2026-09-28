module at.runtime.threads;


import ut.backends;
import snakebite.backends: backendIdentity;
import core.sys.linux.sys.file: LOCK_EX, LOCK_UN, flock;
import core.sys.posix.fcntl: O_CLOEXEC, O_CREAT, O_RDWR, open;
import core.sys.posix.unistd: close, getuid;
import std.algorithm: any, sort;
import std.conv: text;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.exception: enforce;
import std.file: dirEntries, exists, getcwd, isDir, mkdirRecurse, read,
    readText, rename, rmdirRecurse, SpanMode, tempDir;
import std.json: parseJSON;
import std.path: buildPath, relativePath;
import std.process: Config, environment, execute;
import std.string: split, toStringz;
import std.uuid: randomUUID;


// `loadImage` (source/snakebite/dependencyimage.d) used to pin every
// dependency image with an extra `dlopen(RTLD_NODELETE)` but never
// release the `Runtime.loadLibrary` reference it took first. That left
// the loading thread with a permanent explicit-load duty on the image,
// one any guest thread it started inherited too. `unit-threaded`'s own
// test suite runs its module unittests on a dedicated, non-daemon
// `std.parallelism.TaskPool` that it tells to finish without waiting
// (`unit_threaded.runner.testsuite.doRun`), so some worker threads are
// still alive when the guest run returns. A worker still alive at real
// process exit inherits nothing to reach its own `dlclose` with once the
// fix is in; before it, the loader had already freed the dependency
// image's DSO record by then - a dependency image's finalizer runs
// before the executable's own dependencies', druntime and libphobos
// included - so that worker's `dlclose` read freed memory and the
// loader segfaulted `bin/sb` (exit status 139).
//
// `unit-threaded` is already a `dub.selections.json` dependency of this
// project's own `bin/ut`/`bin/at`, so the pinned version is already
// fetched into the local dub package cache before this test ever runs -
// no network access, and no smaller, hand-written fixture reproduced
// the race reliably (a handful of guest threads over a trivial
// dependency almost never overlaps the loader's own teardown window;
// tried and abandoned). A content-keyed copy lives in the user's cache,
// so DUB and dependency-image build outputs survive between runs. One
// advisory lock protects the shared package while any backend uses it:
// unit-threaded deletes `tmp/unit-threaded` relative to its working
// directory, and DUB also writes build outputs beside the package.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot start a real OS thread"),
)) {
    @("guestThreadOutlivesDependencyImage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const packagePath = unitThreadedPackagePath;
        const cacheRoot = buildPath(tempDir,
            text("snakebite-runtime-threads-", getuid), "v1");
        cacheRoot.mkdirRecurse;
        const key = unitThreadedPackageKey(packagePath);
        buildPath(cacheRoot, key).mkdirRecurse;
        const directory = buildPath(cacheRoot, key, "unit-threaded");
        auto lock = CacheLock(buildPath(cacheRoot, key ~ ".lock"));
        if (!directory.exists) {
            const staging = buildPath(cacheRoot, text(
                key, ".stage-", backend.stringof, "-", uniqueToken));
            scope(exit) if (staging.exists) staging.rmdirRecurse;
            const copy = execute(["cp", "-r", packagePath, staging]);
            copy.output.should == "";
            copy.status.should == 0;
            rename(staging, directory);
        }

        static if (is(backend == Native))
            const result = execute(["dub", "test", "--compiler=dmd"],
                null, Config.none, size_t.max, directory);
        else {
            // This test checks a clean exit, never image speed. Skipping
            // optimisation keeps a cold image build fast without changing
            // the thread and loader teardown it exercises.
            //
            // The Native branch above runs `dub test` with `directory` as
            // its working directory, so the guest branch must match: the
            // copied `unit-threaded` package under test runs its own
            // suite, and that suite's `unit_threaded.integration` module
            // constructor does `rmdirRecurse("tmp/unit-threaded")`
            // relative to the child's cwd. Leaving the cwd at this
            // process's own repo root would point that at the very
            // sandbox root this test binary uses for its own concurrent
            // tests, deleting it out from under them.
            const result = execute([
                buildPath(getcwd, "bin", "sb"), "-b",
                backendIdentity!backend.text, "--no-optimise-image", directory,
            ], null, Config.none, size_t.max, directory);
        }
        // A backend may still disagree with `dub test` on a few of
        // `unit-threaded`'s own tests, unrelated to this bug. What every
        // backend must agree on is that the run ends normally: a pass, or
        // a test failure reported and exited from with status 1 - never a
        // segfault (status 139, or any other signal).
        static if (is(backend == Native))
            result.status.should == 0;
        else
            result.status.shouldBeIn([0, 1]);
    }
}


private string unitThreadedPackageKey(in string packagePath) {
    string[] files;
    foreach (entry; dirEntries(packagePath, SpanMode.depth)) {
        const relative = entry.name.relativePath(packagePath);
        const parts = relative.split("/");
        if (parts.any!(part => part == ".dub" || part == ".snakebite"
                || part == "tmp"))
            continue;
        if (!entry.isDir)
            files ~= entry.name;
    }
    files.sort;

    string contents;
    foreach (filePath; files) {
        const relative = filePath.relativePath(packagePath);
        const bytes = read(filePath);
        contents ~= text(relative.length, ":", relative, bytes.length, ":");
        contents ~= cast(string)bytes;
    }
    return contents.sha256Of.toHexString.idup;
}


private struct CacheLock {
    private int _descriptor = -1;

    @disable this(this);

    this(in string path) {
        _descriptor = open(path.toStringz,
            O_CLOEXEC | O_CREAT | O_RDWR, 0x180);
        enforce(_descriptor >= 0, "Cannot open unit-threaded cache lock");
        scope(failure) {
            close(_descriptor);
            _descriptor = -1;
        }
        enforce(flock(_descriptor, LOCK_EX) == 0,
            "Cannot lock unit-threaded cache");
    }

    ~this() {
        if (_descriptor >= 0) {
            flock(_descriptor, LOCK_UN);
            close(_descriptor);
        }
    }
}


private string uniqueToken() {
    return randomUUID.toString;
}


// Where dub already fetched the exact `unit-threaded` version this
// project itself depends on (`dub.selections.json`), so this test reuses
// that fetch instead of pinning its own copy of the version string.
private string unitThreadedPackagePath() {
    const selections = parseJSON(
        readText(buildPath(getcwd, "dub.selections.json")));
    const version_ = selections["versions"]["unit-threaded"].str;
    return buildPath(
        environment["HOME"], ".dub", "packages", "unit-threaded", version_,
        "unit-threaded");
}
