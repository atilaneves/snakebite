module ut.backends.run.associative;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// An associative array literal evaluates its key expressions and builds
// the table from those run-time values, rather than from anything fixed
// at compile time.
static foreach (backend; Matrix!(
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

// Duplicating an associative array preserves its type, including when a
// struct is the key type. An empty table isolates the cast from AA lookup.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("assocArrayDupCopiesStructKeyContents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair {
                string name;
                int number;
            }

            int[Pair] duplicate(int[Pair] source) {
                return source.dup;
            }

            void main() {
                int[Pair] source;

                auto copy = duplicate(source);
                assert(copy.length == 0);
            }
        });
    }
}

// A struct key hashes and compares by its contents, so two separately
// built strings with the same characters are the same key.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "inserting a struct-keyed entry (`ages[Name(a())] = 30`) compiles "
            ~ "druntime's own `_d_aaGetY`, which for a key type with no "
            ~ "already-linked instantiation falls back to compiling "
            ~ "`_aaGetX`'s body - and `_aaGetX` takes `lazy V2 v2`, a "
            ~ "parameter shape this compiler does not build a delegate "
            ~ "for"),
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
    Omit!(Bytecode, Because.unconfirmed,
        "the index assignments and the delegate literal both compile - "
            ~ "`visit(DelegateExp)`/`visit(FuncExp)` build the "
            ~ "`{context, function}` pair the same as for any other "
            ~ "delegate - but `foreach (name, offset; offsets)` lowers to "
            ~ "a native call to druntime's `_d_aaApply2`, passing that "
            ~ "delegate as an ordinary argument for `_d_aaApply2` itself "
            ~ "to call back into: this compiler has no native trampoline "
            ~ "for a general delegate value the way `CallbackBridge`'s "
            ~ "bool-function bridge covers one specific signature, so the "
            ~ "call reaches native code with a function word `_d_aaApply2` "
            ~ "cannot actually invoke"),
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

                assert(offsets.length == 2);
                assert(offsets["magic"] == 0);
                assert(offsets["schema"] == 4);

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

// `foreach` over an associative array keyed by a built-in type (as
// opposed to a struct) also yields every key/value pair.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("intKeyedForeach." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[int] squares;
                squares[2] = 4;
                squares[3] = 9;
                squares[5] = 25;

                int keySum;
                int valueSum;
                foreach (key, value; squares) {
                    assert(squares[key] == value);
                    keySum += key;
                    valueSum += value;
                }
                assert(keySum == 10);
                assert(valueSum == 38);
            }
        });
    }
}

// `.keys` and `.values` each build a new array from the associative
// array's current contents, in whatever order the table itself holds
// them - the pairing between a key and its value is what a test can
// pin, not the order.
static foreach (backend; Matrix!(
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
    Omit!(Bytecode, Because.unconfirmed,
        "inserting `spans[\"header\"] = Span(0, 4)` compiles druntime's "
            ~ "own `_d_aaGetY`, which for a `(string, Span)` pair with no "
            ~ "already-linked instantiation falls back to compiling "
            ~ "`_aaGetX`'s body - and `_aaGetX` takes `lazy V2 v2`, a "
            ~ "parameter shape this compiler does not build a delegate "
            ~ "for"),
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
    Omit!(Bytecode, Because.unconfirmed,
        "inserting `counts[ArrayKey([1, 2])] = 1` compiles druntime's own "
            ~ "`_d_aaGetY`, which for a key type with no already-linked "
            ~ "instantiation falls back to compiling `_aaGetX`'s body - "
            ~ "and `_aaGetX` takes `lazy V2 v2`, a parameter shape this "
            ~ "compiler does not build a delegate for"),
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
