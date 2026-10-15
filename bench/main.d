module bench.main;


import bench.benchmark: run;


int main(string[] args) {
    // The memory sample uses the same executable and the normal CLI
    // lifecycle, without the repeated timing loop.
    if (args.length > 1 && args[1] == "--memory-run") {
        import snakebite.cli: runProgram = run;
        return runProgram(args[0 .. 1] ~ args[2 .. $]);
    }
    return run(args);
}
