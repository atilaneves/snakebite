int main(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import unit_threaded;

    initialize(Snippets.yes);

    return args.runTests!("at.ffi.cost", "at.ffi.callback");
}
