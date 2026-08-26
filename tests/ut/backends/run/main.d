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
