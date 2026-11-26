// `bin/alone`: the tests that are correct only when no other test runs in the
// process. They count what the whole process holds, or they measure times.
// They always run on one thread, whatever the arguments are.
int main(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import unit_threaded: runTests;

    initialize(Snippets.yes);

    return (args ~ "--single").runTests!(
        "alone.bench.timing",
        "alone.runtime.registration",
        "alone.runtime.faultregistration",
    );
}
