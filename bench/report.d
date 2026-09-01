module bench.report;


import core.time: Duration;


struct TimingStatistics {
    Duration minimum;
    Duration median;
    Duration sigma;
}

struct BackendReport {
    string name;
    // The exit-status verdict: the only correctness signal most rows have.
    bool passed;
    // A test runner that reports counts (unit-threaded's summary line) gives
    // real numbers; without one the pass cell is just PASS/FAIL.
    bool haveCounts;
    size_t passCount;
    size_t totalCount;
    TimingStatistics runTime;
    bool hasCompile; // not every backend has a compile step
    TimingStatistics compileTime;
    long ramBytes;
    // The dmd row: the real workflow, doubling as the correctness oracle
    // the other rows are checked against.
    bool isOracle;
}

void updateTestCounts(ref BackendReport report, in string output) {
    import std.conv: to;
    import std.regex: matchFirst, regex;

    static summaryPattern = regex(`(\d+) test\(s\) run, (\d+) failed`);
    const match = output.matchFirst(summaryPattern);
    if (match.empty)
        return;

    const total = match[1].to!size_t;
    const failed = match[2].to!size_t;
    report.haveCounts = true;
    report.passCount = total - failed;
    report.totalCount = total;
}

TimingStatistics timingStatistics(Duration[] times) {
    import core.time: dur;
    import std.algorithm.iteration: map;
    import std.algorithm.sorting: sort;
    import std.array: array;
    import std.math: round;

    auto sorted = times.dup.sort.release;
    TimingStatistics result;
    result.minimum = sorted[0];
    result.median = (sorted[$ / 2] + sorted[($ - 1) / 2]) / 2;
    result.sigma = dur!"hnsecs"(cast(long) round(
        standardDeviation(times.map!(time => time.total!"hnsecs").array),
    ));
    return result;
}

void printTable(in BackendReport[] reports) {
    import std.algorithm.comparison: max;
    import std.algorithm.searching: find;
    import std.array: replicate;
    import std.format: format;
    import std.range: empty, front, walkLength;
    import std.stdio: writeln;

    const oracle = reports.find!(report => report.isOracle);
    // Absent (e.g. `-b ctfe` excludes it) means nothing to cross-check
    // against, not a failure.
    const oracleFailed = !oracle.empty && !clean(oracle.front);

    string[][] rows = [
        [
            "backend", "pass", "run min", "run med", "run σ",
            "cmp min", "cmp med", "cmp σ", "RAM",
        ],
    ];
    foreach (report; reports) {
        string passCell = passCellText(report);
        // A backend claiming a clean run while the oracle itself failed is
        // unverified, not confirmed correct.
        if (oracleFailed && !report.isOracle && clean(report))
            passCell ~= " *";

        rows ~= [
            report.name,
            passCell,
            milliseconds(report.runTime.minimum),
            milliseconds(report.runTime.median),
            milliseconds(report.runTime.sigma),
            report.hasCompile ? milliseconds(report.compileTime.minimum) : "-",
            report.hasCompile ? milliseconds(report.compileTime.median) : "-",
            report.hasCompile
                ? milliseconds(report.compileTime.sigma)
                : "-",
            memory(report.ramBytes),
        ];
    }

    size_t[] widths = new size_t[rows[0].length];
    foreach (row; rows)
        foreach (i, cell; row)
            widths[i] = max(widths[i], cell.walkLength);

    foreach (row; rows) {
        string line;
        foreach (i, cell; row) {
            const padding = " ".replicate(widths[i] - cell.walkLength);
            line ~= i == 0 ? cell ~ padding : "  " ~ padding ~ cell;
        }
        writeln(line);
    }

    if (oracleFailed)
        writeln("\n* dmd oracle failed this run; pass columns unverified");
}

private bool clean(in BackendReport report) {
    return report.haveCounts
        ? report.passCount == report.totalCount
        : report.passed;
}

private string passCellText(in BackendReport report) {
    import std.conv: text;

    return report.haveCounts
        ? text(report.passCount, "/", report.totalCount)
        : (report.passed ? "PASS" : "FAIL");
}

string milliseconds(in Duration duration) {
    import std.format: format;

    const hundredNanoseconds = duration.total!"hnsecs";
    const milliseconds = hundredNanoseconds / 10_000.0;
    if (hundredNanoseconds > 0 && milliseconds < 0.05) {
        const microseconds = hundredNanoseconds / 10.0;
        if (microseconds >= 0.05)
            return format!"%.1f us"(microseconds);
        return format!"%.1f ns"(hundredNanoseconds * 100.0);
    }

    return format!"%.1f ms"(milliseconds);
}

private string memory(in long bytes) {
    import std.format: format;

    if (bytes >= 1024 * 1024)
        return format!"%.1f MiB"(bytes / (1024.0 * 1024.0));
    if (bytes >= 1024)
        return format!"%.0f KiB"(bytes / 1024.0);
    return format!"%d B"(bytes);
}

private double standardDeviation(Value)(in Value[] values) {
    import std.algorithm.iteration: map, sum;
    import std.math: sqrt;

    if (values.length < 2)
        return 0;

    const mean = values.sum / cast(double) values.length;
    const variance =
        values.map!(value => (value - mean) ^^ 2).sum / (values.length - 1);
    return variance.sqrt;
}
