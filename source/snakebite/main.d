module snakebite.main;


private:


public int main(string[] args) {
    import snakebite.cli: run;
    import snakebite.faultsignal: installFaultHandlers;

    installFaultHandlers;
    return run(args);
}
