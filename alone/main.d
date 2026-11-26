// `bin/alone`: the tests that are correct only when no other test runs in the
// process. They count what the whole process holds, or they measure times.
// They always run on one thread, whatever the arguments are.
import unit_threaded.runner.runner: disableDefaultRunner;

mixin disableDefaultRunner;

int main(string[] args) {
    import snakebite.frontend.compiler: Snippets, initialize;
    import unit_threaded.runner.options: Options;
    import unit_threaded.runner.reflection: allTestData;
    import unit_threaded.runner.runner: runTests;

    initialize(Snippets.yes);

    auto options = Options(args);
    options.numThreads = 1;

    return runTests(options, allTestData!(
        "alone.bench.timing",
        "alone.runtime.registration",
        "alone.runtime.heldregistration",
    ));
}
