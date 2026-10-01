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
    const status = capture(argv[], text);
    if (status != 0) {
        error(loc, "C preprocess command %.*s failed for file %s, exit status %d",
            cast(int) cpp.length, cpp.ptr, csrcfile.toChars, status);
        return DArray!ubyte();
    }
    return text;
}

// Runs `argv` and collects its standard output. Returns the exit status,
// 1 when the child could not run.
private int capture(
    const(const(char)*)[] argv,
    out imported!"dmd.astenums".DArray!ubyte text,
) {
    import core.stdc.errno: EINTR, errno;
    import core.sys.posix.sys.wait: WEXITSTATUS, WIFEXITED, waitpid;
    import core.sys.posix.unistd:
        STDOUT_FILENO, _exit, close, dup2, execvp, fork, pipe, read;
    import dmd.astenums: DArray;
    import dmd.common.outbuffer: OutBuffer;

    int[2] pipeEnds;
    if (pipe(pipeEnds) == -1)
        return 1;

    const child = fork();
    if (child == -1)
        return 1;
    if (child == 0) {
        close(pipeEnds[0]);
        dup2(pipeEnds[1], STDOUT_FILENO);
        execvp(argv[0], argv.ptr);
        _exit(-1);
    }

    close(pipeEnds[1]);
    OutBuffer buffer;
    ubyte[1024] chunk = void;
    for (;;) {
        const count = read(pipeEnds[0], chunk.ptr, chunk.length);
        if (count > 0)
            buffer.write(chunk[0 .. count]);
        else if (count == 0)
            break;
        else if (errno != EINTR)
            break;
    }
    close(pipeEnds[0]);

    int status;
    waitpid(child, &status, 0);
    if (!WIFEXITED(status))
        return 1;

    text = DArray!ubyte(cast(ubyte[]) buffer.extractSlice(true));
    return WEXITSTATUS(status);
}
