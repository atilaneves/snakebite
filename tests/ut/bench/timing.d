module ut.bench.timing;


import bench.benchmark: benchmark;
import bench.capture: captureStdout;
import snakebite.backends: backendIdentity, Backends, Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippets;
import std.conv: text;
import std.meta: AliasSeq;
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


@("benchmark.suppressesProgramStdout")
unittest {
    enum marker = "benchmark program output";
    auto module_ = parseSnippets([
        "module benchmarkOutput; import std.stdio; void main() { writeln(\""
        ~ marker ~ "\"); }",
    ])[0];
    auto program = Program([module_]);

    static foreach (BackendType; AliasSeq!(Bytecode, Interpreter)) {{
        const result = captureStdout({
            const report = benchmark(
                BackendType.stringof,
                backendIdentity!BackendType,
                program,
                0,
                1,
            );
            report.passed.should == true;
            return 0;
        });

        result.output.should == "";
    }}
}
