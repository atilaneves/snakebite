module at.bench.timing;


import bench.benchmark: benchmark;
import snakebite.backends: Backends, Program;
import snakebite.frontend.compiler: parseSnippets;
import std.conv: text;
import unit_threaded;


@("runTime.isConsistentAcrossRunCounts")
@Tags("timing")
unittest {
    string source = "module benchmarkTimingConsistency; int main() { ";
    source ~= "int sum; for (int i; i < 10_000; ++i) sum += i; ";
    source ~= "return sum == 49_995_000 ? 0 : 1; } ";
    source ~= "void unused() { if (false) {";
    foreach (i; 0 .. 1_000)
        source ~= text("int local", i, " = ", i, ";");
    source ~= "}}";

    auto module_ = parseSnippets([source])[0];
    auto program = Program([module_]);

    static foreach (BackendType; Backends) {{
        const singleRun = benchmark!BackendType(
            BackendType.stringof,
            program,
            0,
            1,
        );
        const repeatedRuns = benchmark!BackendType(
            BackendType.stringof,
            program,
            2,
            10,
        );

        const singleMedian = singleRun.runTime.median.total!"hnsecs";
        const repeatedMedian = repeatedRuns.runTime.median.total!"hnsecs";
        enum tolerance = 5;
        singleMedian.shouldBeGreaterThan(repeatedMedian / tolerance);
        repeatedMedian.shouldBeGreaterThan(singleMedian / tolerance);
    }}
}
