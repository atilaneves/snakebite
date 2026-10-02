int main(string[] args) {
    import at.runner: run;
    import snakebite.faultsignal: installFaultHandlers;

    installFaultHandlers;
    return run(args);
}
