import unit_threaded;
import snakebite.frontend.compiler: Snippets, initialize;


int main(string[] args) {
    initialize(Snippets.yes);

    return args.runTests!(
        "ut.backends.expressions.arithmetic",
    );
}
