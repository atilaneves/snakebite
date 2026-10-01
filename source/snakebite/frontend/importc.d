module snakebite.frontend.importc;


private:


// dmd's `Module.read` runs this hook on a `.c` or `.h` file before it
// parses the file, but only `dmd`'s own `main` installs one, so a frontend
// used as a library parses unpreprocessed C text: an `#include` or a macro
// use is then a syntax error. This does what `dmd.cpreprocess.preprocess`
// and `dmd.link.runPreprocessor` do on Posix, which the `dmd:frontend`
// package leaves out (`link.d`), with one change: `importc.h` is searched
// on the import paths this process added (`global.path`), because
// `global.importPaths`, the list `dmd` searches, only `dmd`'s `main` fills.
// `-dD` leaves the `#define` lines in the text, where the C parser reads
// them, so `defines` stays empty.
public extern(C++) imported!"dmd.astenums".DArray!ubyte preprocessCFile(
    imported!"dmd.root.filename".FileName csrcfile,
    imported!"dmd.location".Loc loc,
    ref imported!"dmd.common.outbuffer".OutBuffer defines,
) {
    import core.stdc.stdlib: getenv;
    import core.stdc.string: strerror;
    import dmd.astenums: DArray;
    import dmd.root.filename: FileName;
    import dmd.errors: error;
    import dmd.globals: global;
    import dmd.root.array: Array;
    import dmd.root.string: toDString;

    const(char)* importcPath;
    foreach (ref info; global.path[]) {
        const candidate = FileName.combine(info.path, "importc.h");
        if (FileName.exists(candidate) == 1) {
            importcPath = FileName.toAbsolute(candidate);
            break;
        }
    }
    if (importcPath is null) {
        error(loc, "cannot find \"importc.h\" along import path");
        return DArray!ubyte();
    }

    const cppEnvironment = getenv("CPPCMD");
    const cpp = cppEnvironment is null ? "cpp" : cppEnvironment.toDString;

    Array!(const(char)*) argv;
    argv.push(cpp.ptr);
    argv.push("-std=c11");
    foreach (option; global.params.cppswitches[])
        if (option && option[0])
            argv.push(option);
    argv.push(size_t.sizeof == 8 ? "-m64" : "-m32");
    argv.push("-dD");
    argv.push("-Wno-builtin-macro-redefined");
    argv.push(csrcfile.toChars);
    argv.push("-include");
    argv.push(importcPath);
    argv.push(null);

    DArray!ubyte text;
    const(char)[] diagnostics;
    const result = capture(argv[], text, diagnostics);
    if (result.executionError != 0)
        error(loc, "cannot run the C preprocessor `%.*s` for file %s: %s",
            cast(int) cpp.length, cpp.ptr, csrcfile.toChars,
            strerror(result.executionError));
    else if (result.status != 0)
        error(loc, "C preprocess command %.*s failed for file %s, exit status %d\n%.*s",
            cast(int) cpp.length, cpp.ptr, csrcfile.toChars, result.status,
            cast(int) diagnostics.length, diagnostics.ptr);
    else
        return text;

    // The text of an empty file, not no text: dmd reports a file with no
    // text as one it cannot find, and tries to read it again at each import.
    return emptyText;
}

private imported!"dmd.astenums".DArray!ubyte emptyText() {
    import dmd.astenums: DArray;
    import dmd.common.outbuffer: OutBuffer;

    OutBuffer buffer;
    buffer.writeByte('\n');
    return DArray!ubyte(cast(ubyte[]) buffer.extractSlice(true));
}

private struct Captured {
    // The exit status of the child, 1 when a signal ended it.
    int status;
    // The `errno` of a failed `execvp`, 0 when the child ran.
    int executionError;
}

// Runs `argv` and collects its standard output, and what it writes to the
// standard error stream, which dmd would leave on the terminal but a frontend
// that captures its own diagnostics would lose.
private Captured capture(
    const(const(char)*)[] argv,
    out imported!"dmd.astenums".DArray!ubyte text,
    out const(char)[] diagnostics,
) {
    import core.stdc.errno: EINTR, errno;
    import core.sys.posix.fcntl: O_CLOEXEC;
    import core.sys.posix.poll: POLLIN, poll, pollfd;
    import core.sys.posix.sys.wait: WEXITSTATUS, WIFEXITED, waitpid;
    import core.sys.posix.unistd:
        STDERR_FILENO, STDOUT_FILENO, _exit, close, dup2, execvp, fork, pipe, read, write;
    import dmd.astenums: DArray;
    import dmd.common.outbuffer: OutBuffer;

    // `pipe2` closes the last pair on a successful `exec`, so the parent
    // reads nothing from it when the program ran, and the `errno` of the
    // failed `exec` when it did not.
    int[2] outputEnds;
    int[2] diagnosticEnds;
    int[2] errorEnds;
    if (pipe(outputEnds) == -1)
        return Captured(1);
    if (pipe(diagnosticEnds) == -1) {
        foreach (end; outputEnds)
            close(end);
        return Captured(1);
    }
    if (pipe2(errorEnds, O_CLOEXEC) == -1) {
        foreach (end; outputEnds ~ diagnosticEnds)
            close(end);
        return Captured(1);
    }

    const child = fork();
    if (child == -1) {
        foreach (end; outputEnds ~ diagnosticEnds ~ errorEnds)
            close(end);
        return Captured(1);
    }
    if (child == 0) {
        close(outputEnds[0]);
        close(diagnosticEnds[0]);
        dup2(outputEnds[1], STDOUT_FILENO);
        dup2(diagnosticEnds[1], STDERR_FILENO);
        execvp(argv[0], argv.ptr);
        const failure = errno;
        write(errorEnds[1], &failure, failure.sizeof);
        _exit(255);
    }

    close(outputEnds[1]);
    close(diagnosticEnds[1]);
    close(errorEnds[1]);
    OutBuffer output;
    OutBuffer errors;
    pollfd[2] watched = [
        pollfd(outputEnds[0], POLLIN), pollfd(diagnosticEnds[0], POLLIN),
    ];
    ubyte[1024] chunk = void;
    // Both pipes are read together: a child that fills one while the parent
    // waits on the other would block for ever.
    while (watched[0].fd != -1 || watched[1].fd != -1) {
        if (poll(watched.ptr, watched.length, -1) == -1) {
            if (errno == EINTR)
                continue;
            break;
        }
        foreach (i, ref entry; watched) {
            if (entry.fd == -1 || entry.revents == 0)
                continue;
            const count = read(entry.fd, chunk.ptr, chunk.length);
            if (count > 0)
                (i == 0 ? output : errors).write(chunk[0 .. count]);
            else if (count == 0 || errno != EINTR)
                entry.fd = -1;
        }
    }
    close(outputEnds[0]);
    close(diagnosticEnds[0]);
    diagnostics = cast(const(char)[]) errors.extractSlice(true);

    int executionError;
    ptrdiff_t count;
    do
        count = read(errorEnds[0], &executionError, executionError.sizeof);
    while (count == -1 && errno == EINTR);
    close(errorEnds[0]);

    int status;
    while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
    if (count == executionError.sizeof)
        return Captured(255, executionError);
    if (!WIFEXITED(status))
        return Captured(1);

    text = DArray!ubyte(cast(ubyte[]) output.extractSlice(true));
    return Captured(WEXITSTATUS(status));
}

private extern(C) int pipe2(ref int[2] ends, int flags) nothrow @nogc;
