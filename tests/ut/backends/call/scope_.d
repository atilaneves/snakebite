module ut.backends.call.scope_;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("scope.nestedLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3L.shouldBeRetOf!(
            backend,
            q{
                long three() {
                    {
                        long sum = 3;
                        return sum;
                    }
                }
            },
            "three",
        );
    }
}
