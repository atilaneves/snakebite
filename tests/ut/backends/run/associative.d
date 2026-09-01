module ut.backends.run.associative;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("newStructWithStringField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(backend, q{
            struct Value {
                string text;
            }

            int main() {
                auto value = new Value("hello");
                return cast(int) value.text.length;
            }
        }, "main");
    }
}


// An associative array literal evaluates its key expressions and builds
// the table from those run-time values, rather than from anything fixed
// at compile time.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("assocArrayLiteralWithRuntimeKeys." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int key(int value) {
                return value;
            }

            void main() {
                int first = key(10);
                int second = key(first + 1);
                int[int] values = [first: first + 30, second: second + 30];

                assert(values.length == 2);
                assert(values[first] == 40);
                assert(values[second] == 41);
            }
        });
    }
}

// A struct key hashes and compares by its contents, so two separately
// built strings with the same characters are the same key.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("structKeyedLookupComparesContents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Name {
                string text;
            }

            string a() {
                return "Al" ~ "ice";
            }

            string b() {
                char[] buf;
                buf ~= "Alice";
                return buf.idup;
            }

            void main() {
                int[Name] ages;
                ages[Name(a())] = 30;

                Name key = Name(b());
                ages[key] = 31;
                assert(ages.length == 1);
                assert(ages[Name("Alice")] == 31);
                assert((Name("Bob") in ages) is null);

                int sum;
                foreach (k, v; ages) {
                    sum += v;
                    assert(k.text == "Alice");
                }
                assert(sum == 31);

                assert(ages.remove(Name("Alice")));
                assert(ages.length == 0);
            }
        });
    }
}
