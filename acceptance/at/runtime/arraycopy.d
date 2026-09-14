module at.runtime.arraycopy;

import std.file: mkdir, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: Config, execute, thisProcessID;
import std.conv: text;
import std.file: getcwd;
import unit_threaded;

@("releaseBackendsRejectInvalidCopies")
@Tags("runtime")
unittest {
    const directory = buildPath(
        tempDir, "snakebite-arraycopy-release-" ~ thisProcessID.text,
    );
    directory.mkdir;
    scope(exit) directory.rmdirRecurse;
    const source = buildPath(directory, "probe.d");
    source.write(q{
        module probe;
        void main() {
            int[2] sourceStorage = [1, 2];
            int[3] storage = [3, 4, 5];
            int[] source = sourceStorage[];
            int[] destination = storage[];
            bool caught;
            try destination[] = source[];
            catch (Throwable) caught = true;
            assert(caught);
            assert(storage == [3, 4, 5]);
            int[3] overlap = [1, 2, 3];
            int* overlapPtr = overlap.ptr;
            source = overlapPtr[0 .. 2];
            destination = overlapPtr[1 .. 3];
            caught = false;
            try destination[] = source[];
            catch (Throwable) caught = true;
            assert(caught);
            assert(overlap == [1, 2, 3]);
        }
    });
    const executable = buildPath(getcwd, "bin", "sb");
    foreach (backend; ["interpreter", "bytecode"]) {
        const result = execute(
            [executable, "-b", backend, directory], null, Config.none,
        );
        // `-release` strips `assert`, and `bin/at` is always built with
        // it, so this stays a `fail` call, not an `assert`: without it, a
        // probe that crashed or an unrejected copy would pass silently.
        // `fail` over `should`, to keep `result.output` in the message.
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}
