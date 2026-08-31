int main(string[] args) {
    import unit_threaded;
    import snakebite.frontend.compiler: Snippets, initialize;

    initialize(Snippets.yes);

    return args.runTests!(
        "ut.backends.run.main",
        "ut.backends.run.arrays",
        "ut.backends.run.associative",
        "ut.backends.run.classes",
        "ut.backends.run.control",
        "ut.backends.run.declarations",
        "ut.backends.run.delegates",
        "ut.backends.run.enums",
        "ut.backends.run.exceptions",
        "ut.backends.run.operators",
        "ut.backends.run.structs",
        "ut.backends.run.templates",
        "ut.backends.call.func",
        "ut.backends.call.locals",
        "ut.backends.call.scope_",
        "ut.backends.call.loop",
        "ut.backends.call.compare",
        "ut.backends.call.arithmetic",
        "ut.backends.call.assign",
        "ut.backends.call.cast_",
        "ut.backends.call.pointers",
        "ut.backends.call.ref_",
        "ut.backends.call.wrap",
        "ut.backends.call.ffi",
        "ut.backends.call.routing",
        "ut.backends.call.arrays",
        "ut.backends.call.control_flow",
        "ut.backends.call.exceptions",
        "ut.backends.eval.expressions.arithmetic",
        "ut.backends.interpreter.cost",
        "ut.backends.interpreter.framelayout",
        "ut.backends.program",
        "ut.ffi.plan",
        "ut.ffi.cost",
        "ut.framestack",
    );
}
