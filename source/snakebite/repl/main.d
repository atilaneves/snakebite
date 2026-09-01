module snakebite.repl.main;


private:


public int main(string[] args) {
    import snakebite.frontend.compiler: initialize, Snippets;
    import snakebite.repl: Repl;
    import snakebite.repl.cli: parseReplArgs;
    import std.stdio: stderr, writeln;

    // The REPL evaluates single snippets, so it is the snippet world.
    initialize(Snippets.yes);

    const parsed = parseReplArgs(args);
    if (parsed.status != 0) {
        stderr.writeln(parsed.diagnostic);
        return parsed.status;
    }

    if (parsed.options.showHelp) {
        writeln(parsed.diagnostic);
        return 0;
    }

    auto repl = Repl(parsed.options.backend, parsed.options.importPaths);

    foreach (file; parsed.options.files) {
        try
            repl.loadModuleFile(file);
        catch (Exception exception) {
            writeln(errorDiagnostic(exception.msg));
            return 1;
        }
    }

    if (parsed.options.hasCommand)
        return runOneShotCommand(repl, parsed.options.command);

    if (parsed.options.files.length != 0 && !parsed.options.liveAfterFiles)
        return 0;

    if (stdinIsTerminal) {
        writeln("Snakebite REPL");
        return runInteractiveRepl(repl);
    }

    return runPipedRepl(repl);
}


private bool stdinIsTerminal() {
    import core.sys.posix.unistd: isatty;
    import std.stdio: stdin;

    return stdin.isOpen && isatty(stdin.fileno) != 0;
}


private bool stdoutIsTerminal() {
    import core.sys.posix.unistd: isatty;
    import std.stdio: stdout;

    return stdout.isOpen && isatty(stdout.fileno) != 0;
}


private int runPipedRepl(ref imported!"snakebite.repl".Repl repl) {
    import std.stdio: stdin;

    foreach (line; stdin.byLineCopy) {
        if (repl.shouldQuit(line))
            break;

        if (!submit(repl, line))
            return 1;
    }

    return 0;
}


private int runInteractiveRepl(ref imported!"snakebite.repl".Repl repl) {
    import gnu.readline: readline, rl_free;
    import std.datetime.stopwatch: Duration;
    import std.string: fromStringz, toStringz;

    const historyPath = historyFilePath;
    loadHistory(historyPath);
    scope(exit)
        saveHistory(historyPath);

    Duration lastElapsed;
    while (true) {
        const prompt = replPrompt(lastElapsed);
        auto rawLine = readline(prompt.toStringz);
        if (rawLine is null)
            return 0;

        scope(exit)
            rl_free(rawLine);

        const line = rawLine.fromStringz.idup;
        if (repl.shouldQuit(line))
            return 0;

        if (line.length != 0)
            add_history(rawLine);

        const result = submitTimed(repl, line);
        lastElapsed = result.elapsed;
        if (!result.keepGoing)
            return 1;
    }
}


extern(C) private void add_history(const(char)* line);
extern(C) private void using_history();
extern(C) private void stifle_history(int max);
extern(C) private int read_history(const(char)* filename);
extern(C) private int write_history(const(char)* filename);
extern(C) private int history_truncate_file(const(char)* filename, int lines);


// Cap on both the in-memory history list and the on-disk file.
private enum maxHistoryEntries = 1000;


// Where REPL history lives across sessions. SNAKEBITE_HISTORY overrides it
// (handy for tests); otherwise it follows the XDG state directory.
private string historyFilePath() {
    import std.path: buildPath;
    import std.process: environment;

    const override_ = environment.get("SNAKEBITE_HISTORY", "");
    if (override_.length != 0)
        return override_;

    const stateHome = environment.get("XDG_STATE_HOME", "");
    const base = stateHome.length != 0
        ? stateHome
        : buildPath(environment.get("HOME", ""), ".local", "state");
    return buildPath(base, "snakebite", "history");
}


private void loadHistory(in string path) {
    import std.string: toStringz;

    using_history;
    stifle_history(maxHistoryEntries);
    read_history(path.toStringz);
}


private void saveHistory(in string path) {
    import std.file: mkdirRecurse;
    import std.path: dirName;
    import std.string: toStringz;

    try
        mkdirRecurse(path.dirName);
    catch (Exception)
        return;

    const cPath = path.toStringz;
    write_history(cPath);
    history_truncate_file(cPath, maxHistoryEntries);
}


private bool submit(ref imported!"snakebite.repl".Repl repl, in string line) {
    return submitTimed(repl, line).keepGoing;
}


// `-c`'s exit status is not the loop-continuation question `keepGoing`
// answers (that treats `:q` as the one case that stops looping); it is
// whether the command failed. Success and `:q` both exit 0, an error
// exits 1, matching what a caller scripting `sb -c` expects to test.
private int runOneShotCommand(
    ref imported!"snakebite.repl".Repl repl,
    in string command,
) {
    import snakebite.repl: SubmitResult;

    const result = repl.submit(command);
    renderResult(result);
    return result.kind == SubmitResult.Kind.error ? 1 : 0;
}


private struct SubmitOutcome {
    public bool keepGoing;
    public imported!"std.datetime.stopwatch".Duration elapsed;
}


private SubmitOutcome submitTimed(
    ref imported!"snakebite.repl".Repl repl,
    in string line,
) {
    import snakebite.repl: SubmitResult;
    import std.datetime.stopwatch: StopWatch;

    StopWatch stopwatch;
    stopwatch.start;
    const result = repl.submit(line);
    const elapsed = stopwatch.peek;

    renderResult(result);

    return SubmitOutcome(result.kind != SubmitResult.Kind.quit, elapsed);
}


private void renderResult(in imported!"snakebite.repl".SubmitResult result) {
    import snakebite.repl: SubmitResult;
    import std.stdio: writeln;

    final switch (result.kind) with (SubmitResult.Kind) {
        case none:
        case quit:
            break;
        case value:
            writeln(result.text);
            break;
        case error:
            writeln(errorDiagnostic(result.text));
            break;
    }
}


private string replPrompt(in imported!"std.datetime.stopwatch".Duration elapsed) {
    import std.format: format;

    return "[%6.1f ms] > ".format(elapsed.total!"hnsecs" / 10_000.0);
}


private string errorDiagnostic(in string message) {
    return errorLabel ~ " " ~ message;
}


private string errorLabel() {
    return stdoutIsTerminal ? "\x1b[31mError:\x1b[0m" : "Error:";
}
