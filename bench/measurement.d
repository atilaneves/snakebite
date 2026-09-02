module bench.measurement;


import bench.report: BackendReport, timingStatistics, updateTestCounts;
import core.time: Duration, MonoTime;
import snakebite.backends.backend: CompilationStatistics;


struct BackendRound {
    int status;
    string output;
}


BackendReport measureBackend(
    scope MonoTime delegate() clock,
    scope void delegate() construct,
    scope CompilationStatistics delegate() compilationStatistics,
    scope BackendRound delegate() run,
    scope void delegate(in string) output,
    in string name,
    in uint warmup,
    in uint runs,
) {
    import bench.report: updateTestCounts;

    BackendReport report;
    report.name = name;
    report.passed = true;

    Duration[] times;
    Duration[] compileTimes;
    foreach (index; 0 .. warmup + runs) {
        const before = clock();
        construct();
        const compilationBefore = compilationStatistics();
        const result = run();
        const elapsed = clock() - before;
        const compilationAfter = compilationStatistics();
        if (index >= warmup) {
            output(result.output);
            report.passed = report.passed && result.status == 0;
            report.hasCompile =
                report.hasCompile || compilationAfter.hasCompiler;
            if (report.hasCompile)
                compileTimes ~=
                    compilationAfter.duration - compilationBefore.duration;
            times ~= elapsed;
            report.updateTestCounts(result.output);
        }
    }

    report.runTime = timingStatistics(times);
    if (report.hasCompile)
        report.compileTime = timingStatistics(compileTimes);

    return report;
}
