module ut.backends.run.main;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("ret.int.42." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.run!(
             backend,
             q{
                 int main() {
                     return 42;
                 }
             }
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ret.int.77." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        77.run!(
             backend,
             q{
                 int main() {
                     return 77;
                 }
             }
        );
    }
}

// No `main` at all is not an error: the status is 0.
static foreach (backend; Matrix!()) {
    @("noMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.run!(
             backend,
             q{
                 int notMain() {
                     return 42;
                 }
             }
        );
    }
}
