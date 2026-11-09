module bench.main;


import bench.benchmark: run;


int main(string[] args) {
    if (args.length > 1 && (args[1] == "--sbc-a-save"
            || args[1] == "--sbc-a-load" || args[1] == "--sbc-a-baseline")) {
        import bench.imagea: runImage = run;
        return runImage(args);
    }
    // The memory sample uses the same executable and the normal CLI
    // lifecycle, without the repeated timing loop.
    if (args.length > 1 && args[1] == "--memory-run") {
        import snakebite.cli: runProgram = run;
        return runProgram(args[0 .. 1] ~ args[2 .. $]);
    }
    return run(args);
}
