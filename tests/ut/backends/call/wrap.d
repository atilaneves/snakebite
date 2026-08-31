module ut.backends.call.wrap;

import ut.backends;

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("wrap.addAssignWrapsAtTargetWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (int.min).shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int overflow() {
                    int sum = int.max;
                    sum += one();
                    return sum;
                }
            },
            "overflow",
        );
    }
}
