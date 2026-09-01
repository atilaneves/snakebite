module ut.backends.run.associative;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


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

// An index assignment on an associative array with a string key inserts
// or overwrites that key's value, and `foreach` over the array yields
// every key/value pair.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("stringKeyedIndexAssignmentAndForeach." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[string] offsets;
                offsets["magic"] = 0;
                offsets["schema"] = 4;

                int offsetSum;
                int nameLengthSum;
                foreach (name, offset; offsets) {
                    assert(offsets[name] == offset);
                    offsetSum += offset;
                    nameLengthSum += cast(int) name.length;
                }
                assert(offsetSum == 4);
                assert(nameLengthSum == 11);
            }
        });
    }
}

// `.keys` and `.values` each build a new array from the associative
// array's current contents, in whatever order the table itself holds
// them - the pairing between a key and its value is what a test can
// pin, not the order.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("assocArrayKeysAndValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[int] table = [1: 10, 2: 20, 3: 30];
                int keySum;
                int valueSum;

                foreach (key; table.keys)
                    keySum += key;

                foreach (value; table.values)
                    valueSum += value;

                assert(keySum == 6);
                assert(valueSum == 60);
            }
        });
    }
}

// Indexing an associative array whose value is a struct yields a
// reference to that struct's own storage in the table, so a field
// assignment through the index, and a call to one of the struct's own
// methods through the index, both mutate the value already in the
// table rather than a copy of it.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("assocArrayIndexedValueFieldWriteAndMethodCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Span {
                int offset;
                int length;

                int grow() {
                    return length += 1;
                }
            }

            void main() {
                Span[string] spans;
                spans["header"] = Span(0, 4);
                assert(spans["header"].offset == 0);

                spans["header"].offset = 8;
                assert(spans["header"].offset == 8);
                assert(spans["header"].length == 4);

                spans["header"].grow();
                assert(spans["header"].length == 5);
            }
        });
    }
}

// A key whose type holds a dynamic array hashes and compares by the
// array's contents, the same as any other struct key, so two separately
// built arrays with the same elements are the same key.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("arrayKeyedLookupComparesContents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct ArrayKey {
                int[] xs;
            }

            void main() {
                int[ArrayKey] counts;
                counts[ArrayKey([1, 2])] = 1;

                assert((ArrayKey([1, 2]) in counts) !is null);
                assert(counts[ArrayKey([1, 2])] == 1);
            }
        });
    }
}
