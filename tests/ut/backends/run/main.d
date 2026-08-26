module ut.backends.run.main;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("ret.int.42." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        run!(
             backend,
             q{
                 int main() {
                     return 42;
                 }
             }
        ).should == 42;
    }
}

static foreach (backend; Matrix!()) {
    @("ret.int.77." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        run!(
             backend,
             q{
                 int main() {
                     return 77;
                 }
             }
        ).should == 77;
    }
}
