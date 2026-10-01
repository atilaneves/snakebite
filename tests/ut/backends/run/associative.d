module ut.backends.run.associative;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A module-scope associative array literal whose keys and values are all
// compile-time constants is its own static initializer: dmd gives it an
// `AssocArrayLiteralExp.lowering` (a call to `object.
// _d_assocarrayliteralTX!(K, V)`) the same as a dynamic one, rather than
// building it at `main`'s first statement. The Ctfe backend cannot read a
// non-manifest static variable while interpreting `main` at all, the same
// restriction real dmd CTFE has.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("moduleScopeAssocArrayLiteralIsAStaticInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[string] table = ["a": 1, "b": 2];

            int main() {
                return table["b"] == 2 && table["a"] == 1
                    && table.length == 2 ? 0 : 1;
            }
        });
    }
}

// An associative array literal evaluates its key expressions and builds
// the table from those run-time values, rather than from anything fixed
// at compile time.
static foreach (backend; Matrix!()) {
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

// An associative array is one pointer-sized handle to its storage, true
// exactly when that handle is non-null - not by `.length`, the same
// `ptr !is null` rule a dynamic array's own condition follows for its
// own pointer word.
static foreach (backend; Matrix!()) {
    @("assocArrayTruthyAfterInsertion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[int] empty;
                assert(!empty);

                int[int] values;
                values[1] = 10;
                assert(values);
            }
        });
    }
}

// Duplicating an associative array preserves its type, including when a
// struct is the key type and the parameter is `const`: `object.d`'s own
// `dup` casts its internal `_aaDup` result from a `const`-qualified AA
// type back to the caller's unqualified one, a qualifier-only cast a
// backend has to compile even though it moves no different bytes.
static foreach (backend; Matrix!()) {
    @("assocArrayDupCopiesStructKeyContents." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair {
                string name;
                int number;
            }

            int[Pair] duplicate(const(int[Pair]) source) {
                return source.dup;
            }

            void main() {
                int[Pair] source;
                source[Pair("a", 1)] = 10;

                auto copy = duplicate(source);
                assert(copy.length == 1);
                assert(copy[Pair("a", 1)] == 10);
            }
        });
    }
}

// A struct key hashes and compares by its contents, so two separately
// built strings with the same characters are the same key.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// A struct literal can initialize an AA-typed field from an AA literal,
// even when the AA's value type is the struct itself - the AA field is
// a plain pointer-sized handle to druntime's own hash table, no
// different from any other field this literal writes.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesAssociativeArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Nested {
                Nested[int] aa;
            }

            void main() {
                auto n = Nested([7: Nested()]);
                assert(n.aa.length == 1);
                assert(7 in n.aa);
            }
        });
    }
}

// `is` on a bare AA compares it against `null` without going through any
// struct field at all.
static foreach (backend; Matrix!()) {
    @("bareAaIsNull." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[int] aa;
                assert(aa is null);
            }
        });
    }
}

// An AA identity comparison reads the AA handle, so an alias compares equal
// while two separately allocated tables do not. Each operand expression is
// evaluated once, including a call that returns an empty AA.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE cannot observe mutable state while checking AA handles"),
)) {
    @("bareAaIdentityHandlesAndEvaluation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int calls;

            int[int] make(bool populated) {
                ++calls;
                int[int] result;
                if (populated)
                    result[1] = 2;
                return result;
            }

            void main() {
                auto first = make(true);
                auto same = first;
                auto second = make(true);

                assert(calls == 2);
                assert(first !is null);
                assert(first is same);
                assert(first !is second);
                assert(make(false) is null);
                assert(calls == 3);
            }
        });
    }
}

// Inserting into an associative array whose value type's own `.init` is
// not all zero bits (`Value`'s own defaults are `1.5` and `'x'`, neither
// zero) reaches `core/internal/newaa.d`'s own `allocEntry`, which zeroes
// the freshly carved-out entry by hand - `(cast(ubyte*)&entry.value)[0
// .. V.sizeof] = 0` - since a fresh `malloc`'d bucket is not already
// zeroed the way `int[int]`'s own zero-init value type (see this
// module's other AA tests) never needs that fill at all.
static foreach (backend; Matrix!(
)) {
    @("assocArrayInsertWithNonZeroInitValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                float f = 1.5;
                char c = 'x';
            }

            void main() {
                Value[int] table;
                table[1] = Value(2.5, 'y');
                assert(table[1].f == 2.5);
                assert(table[1].c == 'y');
            }
        });
    }
}

// A module-scope `static immutable` associative array initialised by a call
// is built while the frontend evaluates the call, and the program reads the
// finished table.
static foreach (backend; Matrix!()) {
    @("staticImmutableAssocArrayFromCtfeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[string] makeTable() {
                return ["a": 1, "b": 2];
            }

            static immutable table = makeTable();

            int main() {
                return table["b"] == 2 && table["a"] == 1
                    && table.length == 2 ? 0 : 1;
            }
        });
    }
}

// A module-scope `immutable` associative array literal is a static
// initialiser.
static foreach (backend; Matrix!()) {
    @("moduleScopeImmutableAssocArrayLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            immutable int[string] table = ["a": 1, "b": 2];

            int main() {
                return table["b"] == 2 && table["a"] == 1
                    && table.length == 2 ? 0 : 1;
            }
        });
    }
}

// A function-level `static` associative array starts as its literal and
// accepts inserts.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("functionStaticAssocArrayLiteralIsMutable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                static int[string] table = ["a": 1];
                table["b"] = 2;
                return table["a"] == 1 && table["b"] == 2
                    && table.length == 2 ? 0 : 1;
            }
        });
    }
}

// A static associative array can hold struct values.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("staticAssocArrayOfStructValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                int y;
            }

            int main() {
                static Point[string] points =
                    ["a": Point(1, 2), "b": Point(3, 4)];
                return points["b"].y == 4 && points["a"].x == 1 ? 0 : 1;
            }
        });
    }
}

// A static associative array can hold class references.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("staticAssocArrayWithClassValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Animal {
                int legs;

                this(int legs) {
                    this.legs = legs;
                }
            }

            int main() {
                static Animal[string] animals;
                animals["dog"] = new Animal(4);
                return animals["dog"].legs == 4 ? 0 : 1;
            }
        });
    }
}

// A static associative array can have struct keys that hold strings.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("staticAssocArrayWithStructKeys." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Key {
                string name;
                int number;
            }

            int main() {
                static int[Key] table = [Key("a", 1): 10, Key("b", 2): 20];
                return table[Key("b", 2)] == 20 ? 0 : 1;
            }
        });
    }
}

// A static associative array of associative arrays.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("staticNestedAssocArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                static int[string][string] table =
                    ["x": ["a": 1], "y": ["b": 2]];
                return table["y"]["b"] == 2 && table["x"]["a"] == 1
                    && table.length == 2 ? 0 : 1;
            }
        });
    }
}

// An associative array literal initialises a struct field.
static foreach (backend; Matrix!()) {
    @("structFieldAssocArrayInitialiser." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int[string] m = ["a": 1];
            }

            int main() {
                S s;
                return s.m["a"] == 1 ? 0 : 1;
            }
        });
    }
}

// An associative array literal initialises a class field.
static foreach (backend; Matrix!()) {
    @("classFieldAssocArrayInitialiser." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                int[string] m = ["a": 1];
            }

            int main() {
                auto c = new C;
                return c.m["a"] == 1 ? 0 : 1;
            }
        });
    }
}

// A `__gshared` associative array is a static initialiser.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("gsharedAssocArrayLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int[string] table = ["a": 1];

            int main() {
                table["b"] = 2;
                return table["a"] == 1 && table["b"] == 2 ? 0 : 1;
            }
        });
    }
}

// A thread-local associative array is a static initialiser.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("threadLocalStaticAssocArrayLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[string] table = ["a": 1];

            int main() {
                table["b"] = 2;
                return table["a"] == 1 && table["b"] == 2 ? 0 : 1;
            }
        });
    }
}
