module ut.bench.timing;


import bench.benchmark: benchmark;
import snakebite.backends: backendIdentity, Backends, Program;
import snakebite.frontend.compiler: parseSnippets;
import std.conv: text;
import ut;


@("benchmark.runTime.includesCompilation")
unittest {
    string source = "module benchmarkTiming; void main() { if (false) {";
    foreach (i; 0 .. 1_000)
        source ~= text("int local", i, " = ", i, ";");
    source ~= "}}";

    auto module_ = parseSnippets([source])[0];
    auto program = Program([module_]);

    static foreach (BackendType; Backends) {{
        const report = benchmark(
            BackendType.stringof,
            backendIdentity!BackendType,
            program,
            0,
            1,
        );

        report.passed.should == true;
        if (report.hasCompile)
            (report.runTime.minimum >= report.compileTime.minimum)
                .shouldBeTrue;
    }}
}
