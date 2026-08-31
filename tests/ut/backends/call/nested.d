module ut.backends.call.nested;


import ut.backends;


// The non-escaping case: `bump` is called while `main`'s own frame is
// still on the interpreter's frame stack, so reading and then writing
// `counter` through the static chain `bindFrame` set up reaches the same
// storage a compiled `bump` would - both directions go through the one
// `slotOf` path this exercises.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("nested.staticChain.readsAndWritesOuterLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int counter = 40;
                int bump() {
                    counter += 2;
                    return counter;
                }

                assert(bump() == 42);
                assert(counter == 42);
            }
        });
    }
}

// `middle`'s own nested function, `captureIt`, has its address taken and
// handed to a delegate variable - dmd's conservative `needsClosure()`
// rule (`FuncDeclaration.tookAddressOf`) marks `middle` as needing to
// heap-allocate its own frame for exactly this reason, regardless of
// `dg` never leaving `middle`'s own scope. The interpreter's frame stack
// has no such allocation, so calling `middle` refuses loudly rather than
// handing `captureIt` a static link into a frame this interpreter cannot
// keep alive the way a real closure would.
@("nested.staticChain.escapingCaptureIsRefused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int outer() {
            int middle() {
                int x = 5;
                int captureIt() { return x; }
                int delegate() dg = &captureIt;
                return dg();
            }
            return middle();
        }
    });
    auto function_ = findFunction(module_, "outer");

    int result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot call `middle`: it captures an outer " ~
                "variable that must outlive the enclosing call, which " ~
                "the interpreter's frame stack does not support");
}
