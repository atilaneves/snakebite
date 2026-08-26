module bench.report;


import core.time: Duration;


struct BackendReport {
    string name;
    // The exit-status verdict: the only correctness signal most rows have.
    bool passed;
    // A test runner that reports counts (unit-threaded's summary line) gives
    // real numbers; without one the pass cell is just PASS/FAIL.
    bool haveCounts;
    size_t passCount;
    size_t totalCount;
    Duration minimum;
    Duration median;
    double sigmaMilliseconds;
    bool hasCompile; // not every backend has a compile step
    Duration compile;
    long ramBytes;
    // The dmd row: the real workflow, doubling as the correctness oracle
    // the other rows are checked against.
    bool isOracle;
}

void fillTimingStatistics(ref BackendReport report, Duration[] times) {
    import std.algorithm.iteration: map;
    import std.algorithm.sorting: sort;
    import std.array: array;

    auto sorted = times.dup.sort.release;
    report.minimum = sorted[0];
    report.median = (sorted[$ / 2] + sorted[($ - 1) / 2]) / 2;
    report.sigmaMilliseconds =
        standardDeviation(times.map!(time => time.total!"usecs" / 1000.0).array);
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
        ["backend", "pass", "min", "median", "σ", "compile", "RAM"],
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
            milliseconds(report.minimum),
            milliseconds(report.median),
            format!"%.1f"(report.sigmaMilliseconds),
            report.hasCompile ? milliseconds(report.compile) : "-",
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

    return format!"%.1f ms"(duration.total!"usecs" / 1000.0);
}

private string memory(in long bytes) {
    import std.format: format;

    if (bytes >= 1024 * 1024)
        return format!"%.1f MiB"(bytes / (1024.0 * 1024.0));
    if (bytes >= 1024)
        return format!"%.0f KiB"(bytes / 1024.0);
    return format!"%d B"(bytes);
}

private double standardDeviation(in double[] values) {
    import std.algorithm.iteration: map, sum;
    import std.math: sqrt;

    if (values.length < 2)
        return 0;

    const mean = values.sum / values.length;
    const variance =
        values.map!(value => (value - mean) ^^ 2).sum / (values.length - 1);
    return variance.sqrt;
}
