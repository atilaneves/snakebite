module snakebite.repl.main;


private:


public int main(string[] args) {
    import snakebite.repl.cli: run;

    return run(args);
}
