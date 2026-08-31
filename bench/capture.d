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
        fflush(null);
        enforce(dup2(savedStdout, STDOUT_FILENO) >= 0, "cannot restore stdout");
    }

    capture.rewind;
    string output;
    foreach (line; capture.byLineCopy(Yes.keepTerminator))
        output ~= line;

    return CapturedRun(status, output);
}
