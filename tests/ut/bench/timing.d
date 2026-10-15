module ut.bench.timing;


import bench.benchmark: benchmark;
import snakebite.backends: backendIdentity, Backends, Program;
import snakebite.frontend.compiler: parseSnippets;
import std.conv: text;
import ut;
import ut.backends: Because, Ctfe, Matrix, Native, Omit;


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


// `main` fails unless it gets the program arguments.
static foreach (BackendType; Matrix!(
    Omit!(Native, Because.inexpressible, "the benchmark times a backend, " ~
        "and the native oracle is none"),
    Omit!(Ctfe, Because.unconfirmed, "the CTFE backend takes no host " ~
        "arguments"),
)) {
    @("benchmark.passesProgramArguments." ~ BackendType.stringof)
    unittest {
        auto module_ = parseSnippets([
            "module benchmarkArguments;
            int main(string[] args) {
                return args.length == 3 && args[1] == `a` && args[2] == `-b`
                    ? 0 : 1;
            }",
        ])[0];
        auto program = Program([module_]);

        const report = benchmark(
            BackendType.stringof,
            backendIdentity!BackendType,
            program,
            0,
            1,
            null,
            ["a", "-b"],
        );

        report.passed.should == true;
    }
}
