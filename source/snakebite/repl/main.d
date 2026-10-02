module snakebite.repl.main;


private:


public int main(string[] args) {
    import snakebite.faultsignal: installFaultHandlers;
    import snakebite.repl.cli: run;

    installFaultHandlers;
    return run(args);
}
