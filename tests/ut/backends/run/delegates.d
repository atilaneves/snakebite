module ut.backends.run.delegates;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A delegate to a nested function is a (context, function) pair whose
// context is the enclosing frame, so calling it reaches the same locals.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("nestedFunctionDelegateCarriesItsFrame." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            void main() {
                int captured = runtimeSeed(3);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;

                assert(dg.ptr !is null);
                assert(dg.funcptr !is null);

                assert(dg() == 6);
                assert(captured == 6);
            }
        });
    }
}
