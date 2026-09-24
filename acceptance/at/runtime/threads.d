module at.runtime.threads;


import ut.backends;
import std.conv: text;
import std.file: getcwd, readText, rmdirRecurse, tempDir;
import std.json: parseJSON;
import std.path: buildPath;
import std.process: Config, environment, execute, thisProcessID;


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
// tried and abandoned). The package is copied out of that cache first:
// both `dub test` and `bin/sb` write build artifacts next to a
// project's own sources, and the cache is shared with every other build
// that uses the same package, including a concurrent one.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot start a real OS thread"),
)) {
    @("guestThreadOutlivesDependencyImage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const directory = buildPath(tempDir, text(
            "snakebite-runtime-threads-", thisProcessID, "-", backend.stringof));
        scope(exit) directory.rmdirRecurse;
        const copy = execute(["cp", "-r", unitThreadedPackagePath, directory]);
        copy.output.should == "";
        copy.status.should == 0;

        static if (is(backend == Native))
            const result = execute(["dub", "test", "--compiler=dmd"],
                null, Config.none, size_t.max, directory);
        else {
            import snakebite.backends: backendIdentity;

            // The image built here is thrown away once the test ends: only
            // the guest run's behaviour (a clean exit, never a segfault)
            // is checked, never its speed. Skipping optimisation keeps
            // this test's own build fast without weakening what it proves.
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
