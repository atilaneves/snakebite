int main(string[] args) {
    import snakebite.faultsignal: installFaultHandlers;
    import ut.runner: run;

    // A test runs this binary again to see how a process dies of a fault:
    // the scenario installs the handlers itself.
    version (linux) version (X86_64) {
        import std.process: environment;
        import ut.faultsignal: faultChildVariable, runFaultChild;

        if (const scenario = environment.get(faultChildVariable))
            return runFaultChild(scenario);
    }

    installFaultHandlers;
    return run(args);
}
