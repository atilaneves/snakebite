module bench.capture;


struct CapturedRun {
    int status;
    string output;
}

CapturedRun captureStdout(scope int delegate() run) {
    import core.stdc.stdio: fflush;
    import core.sys.posix.unistd: close, dup, dup2, STDOUT_FILENO;
    import std.exception: enforce;
    import std.stdio: File, stdout;
    import std.typecons: Yes;

    auto capture = File.tmpfile;
    auto originalStdout = stdout;
    stdout.flush;
    fflush(null);

    const savedStdout = dup(STDOUT_FILENO);
    enforce(savedStdout >= 0, "cannot save stdout");
    scope(exit)
        close(savedStdout);

    enforce(dup2(capture.fileno, STDOUT_FILENO) >= 0, "cannot capture stdout");
    int status;
    try
        status = run();
    finally {
        stdout.flush;
        stdout = originalStdout;
        stdout.flush;
        fflush(null);
        enforce(dup2(savedStdout, STDOUT_FILENO) >= 0, "cannot restore stdout");
    }

    capture.rewind;
    string output;
    foreach (line; capture.byLineCopy(Yes.keepTerminator))
        output ~= line;

    return CapturedRun(status, output);
}

struct ProcessResult {
    int status;
    string stdout_;
    string stderr_;
    long ramBytes;
}

// The two streams stay separate: the test runner's summary is parsed from
// stdout, while stderr carries the diagnostics worth showing on failure.
// Temp files rather than pipes, so a chatty child can never deadlock on a
// full pipe buffer.
//
// The command runs under `/usr/bin/time -f %M`, its own report going to a
// third file so it never mixes into the command's real output; `time`
// propagates the command's own exit status. This process (holding a parsed
// frontend, possibly a whole `Program`) can be memory-heavy itself, and
// `getrusage(RUSAGE_CHILDREN)` measured directly from it is unusable: a
// forked child inherits the parent's resident pages copy-on-write, and that
// briefly-shared memory counts toward the child's reported peak too - a
// small `dmd` invocation read back as using a gigabyte. `time` is a
// lightweight process with nothing of its own to inherit, so what it
// reports for its child is the child's actual usage.
ProcessResult captureProcess(in string[] command, in string workDir = null) {
    import std.conv: text, to;
    import std.file: readText, remove, tempDir;
    import std.path: buildPath;
    import std.process: Config, spawnProcess, thisProcessID, wait;
    import std.string: strip;
    import std.stdio: File, stdin;

    const prefix = buildPath(
        tempDir, "snakebite-bench-capture-" ~ thisProcessID.text,
    );
    const stdoutPath = prefix ~ ".out";
    const stderrPath = prefix ~ ".err";
    const timePath = prefix ~ ".time";
    scope(exit) {
        stdoutPath.remove;
        stderrPath.remove;
        timePath.remove;
    }

    auto stdoutFile = File(stdoutPath, "w");
    auto stderrFile = File(stderrPath, "w");
    auto pid = spawnProcess(
        ["/usr/bin/time", "-q", "-f", "%M", "-o", timePath] ~ command,
        stdin, stdoutFile, stderrFile, null,
        Config.none, workDir,
    );
    const status = wait(pid);
    stdoutFile.close;
    stderrFile.close;

    const ramBytes = timePath.readText.strip.to!long * 1024;

    return ProcessResult(status, readText(stdoutPath), readText(stderrPath), ramBytes);
}
