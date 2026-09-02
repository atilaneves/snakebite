module ut.backends.run.main;


import dmd.func: FuncDeclaration;
import snakebite.backends.backend: Backend, Program, run;
import snakebite.exception: SnakebiteException;
import snakebite.frontend.compiler: parseSnippets;
import ut.backends;


static foreach (backend; Matrix!()) {
    @("ret.int.42." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
             backend,
             q{
                 int main() {
                     return 42;
                 }
             }
        );
    }
}

// A backend may continue to a custom main after refusing a constructor, but
// the program did not start completely, so its status must still fail.
@("skippedModuleConstructorFailsRunAfterMain.")
unittest {
    auto fixture = ConstructorFixture(
        q{
            module skippedConstructor;
            static this() {}
            void main() {}
        },
        ConstructorBackend.Outcome.skip,
    );

    run(fixture.backend, fixture.program).shouldEqual(1);
    fixture.backend.mainCalled.shouldBeTrue;
}

@("failedModuleConstructorStopsRunBeforeMain.")
unittest {
    auto fixture = ConstructorFixture(
        q{
            module failedConstructor;
            static this() {}
            void main() {}
        },
        ConstructorBackend.Outcome.fail,
    );

    run(fixture.backend, fixture.program).shouldEqual(1);
    fixture.backend.mainCalled.shouldBeFalse;
}

@("successfulModuleConstructorRunsMain.")
unittest {
    auto fixture = ConstructorFixture(
        q{
            module successfulConstructor;
            static this() {}
            int main() {
                return 23;
            }
        },
        ConstructorBackend.Outcome.succeed,
    );

    run(fixture.backend, fixture.program).shouldEqual(23);
    fixture.backend.mainCalled.shouldBeTrue;
}

private final class ConstructorBackend: Backend {
    private enum Outcome {
        succeed,
        skip,
        fail,
    }

    private Outcome _constructorOutcome;
    private bool _constructorCall = true;
    public bool mainCalled;

    this(const Program program, Outcome constructorOutcome) {
        super(program);
        _constructorOutcome = constructorOutcome;
    }

    public override void call(
        FuncDeclaration, void* returnPlace, void*[],
    ) {
        if (_constructorCall) {
            _constructorCall = false;
            final switch (_constructorOutcome) with (Outcome) {
                case succeed:
                    return;
                case skip:
                    throw new SnakebiteException("unsupported constructor");
                case fail:
                    throw new Exception("constructor failed");
            }
        }

        mainCalled = true;
        if (returnPlace !is null)
            *cast(int*) returnPlace = 23;
    }

    public override string eval(FuncDeclaration) {
        return null;
    }
}

private struct ConstructorFixture {
    public Program program;
    public ConstructorBackend backend;

    this(string source, ConstructorBackend.Outcome outcome) {
        auto module_ = parseSnippets([source])[0];
        program = Program([module_]);
        backend = new ConstructorBackend(program, outcome);
    }
}

static foreach (backend; Matrix!()) {
    @("ret.int.77." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        77.shouldBeStatusOf!(
             backend,
             q{
                 int main() {
                     return 77;
                 }
             }
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ret.void." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
             backend,
             q{
                 void main() {
                 }
             }
        );
    }
}

// `version (D_BetterC)` is not predefined by the frontend, so a real build
// picks the `else` branch's `main`, same as `dmd -unittest` would for dub's
// generated `dub_test_root.d` (its D_BetterC branch is dead code here). This
// pins that `findFunction` resolves the condition instead of always
// descending into a version declaration's syntactic first branch.
static foreach (backend; Matrix!()) {
    @("ret.int.betterCBranchNotTaken." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
             backend,
             q{
                 version (D_BetterC) {
                     int main() {
                         return 1;
                     }
                 } else {
                     int main() {
                         return 42;
                     }
                 }
             }
        );
    }
}

// A failed assertion leaves `main` as a `Throwable` and the process fails,
// which is the contract `run` reports as a status.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("failedAssertExitsNonZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                assert(1 == 2);
            }
        });
    }
}

// No `main` at all is not an error: the status is 0.
static foreach (backend; Matrix!()) {
    @("noMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
             backend,
             q{
                 int notMain() {
                     return 42;
                 }
             }
        );
    }
}
