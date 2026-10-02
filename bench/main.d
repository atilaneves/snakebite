module bench.main;


import bench.benchmark: run;


int main(string[] args) {
    import snakebite.faultsignal: installFaultHandlers;

    installFaultHandlers;
    return run(args);
}
