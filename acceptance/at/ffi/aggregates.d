module at.ffi.aggregates;


import ut.backends;


private struct Owned {
    long value;
    ~this() {}
}

private alias OwnedCallback = extern(C) long function(Owned);


public extern(C) long snakebite_at_owned_roundtrip(
    long a, long b, long c, long d, long e, long f,
    Owned value, OwnedCallback callback,
) {
    return a + b + c + d + e + f + callback(value);
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("nonPod.spilledArgumentAndCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                long number;
                ~this() {}
            }
            alias Callback = extern(C) long function(Value);
            pragma(mangle, "snakebite_at_owned_roundtrip")
            extern(C) long snakebite_at_owned_roundtrip(
                long, long, long, long, long, long,
                Value, Callback,
            );
            extern(C) long read(Value value) {
                return value.number * 2;
            }
            void main() {
                assert(snakebite_at_owned_roundtrip(
                    1, 2, 3, 4, 5, 6, Value(42), &read,
                ) == 105);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot open native files"),
)) {
    @("fileAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.stdio: File;

            void main() {
                auto first = File.tmpfile;
                auto second = File.tmpfile;
                first = second;
                assert(first.fileno == second.fileno);
            }
        });
    }
}
