module ut.backends.run.stringliterals;


// D puts a zero code unit after every string literal, so a literal converts
// to a C string. Each guest has many literals of different lengths: a
// missing terminator then shows as data that is not zero, and not only as
// a lucky zero.


import ut.backends;

// CTFE cannot read the zero code unit after the last one of a literal.
private alias NoCtfe = Omit!(
    Ctfe, Because.inexpressible,
    "CTFE rejects a read through a pointer past the last code unit",
);

// dmd folds `"a" ~ "b"` to one literal that it did not read from source.
static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedLiteralHasCStringLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: strlen;

            size_t length(const(char)* text) { return strlen(text); }

            void main() {
                static foreach (i; 0 .. 100) {{
                    enum text = i.stringof ~ " alias c=c/b"
                        ~ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"[0 .. i % 40];
                    assert(length(text.ptr) == text.length);
                }}
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                static foreach (i; 0 .. 100) {{
                    enum text = i.stringof ~ "ab"
                        ~ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"[0 .. i % 40];
                    assert(after(text) == 0);
                }}
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedWideLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            wchar after(wstring text) { return text.ptr[text.length]; }

            void main() {
                static foreach (i; 0 .. 100) {{
                    enum text = "ab"w ~ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"w[0 .. i % 40];
                    assert(after(text) == 0);
                }}
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedDoubleWideLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            dchar after(dstring text) { return text.ptr[text.length]; }

            void main() {
                static foreach (i; 0 .. 100) {{
                    enum text = "ab"d ~ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"d[0 .. i % 40];
                    assert(after(text) == 0);
                }}
            }
        });
    }
}

// An empty literal still points to a zero code unit that is not null.
static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedEmptyLiteralPointsToZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            const(char)* pointer(string text) { return text.ptr; }

            void main() {
                const p = pointer("" ~ "");
                assert(p !is null);
                assert(*p == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedLiteralInStaticImmutableIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            static immutable first = "a" ~ "bcd";
            static immutable second = "ef" ~ "ghijklmnopqrstu";
            static immutable third = "v" ~ "wxyzabcdefghijklmnopqrstuvwxyzabcdefghij";

            void main() {
                assert(after(first) == 0);
                assert(after(second) == 0);
                assert(after(third) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedLiteralInStructFieldIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Name {
                string text;
                const(char)* pointer;
            }

            static immutable name = Name("a" ~ "bc", "d" ~ "efghijklmnopqrstuvwxyz");

            void main() {
                assert(name.text.ptr[name.text.length] == 0);
                assert(name.pointer[23] == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedLiteralsInArrayLiteralAreFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                const names = ["a" ~ "b", "cd" ~ "efghijklmnopq", "r" ~ "stuvwxyzabcdefghijklmnopqrstu"];
                foreach (name; names)
                    assert(after(name) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.foldedLiteralAsDefaultArgumentIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text = "d" ~ "efghijklmnopqrstuvwxyzabcdefghijklmnopq") {
                return text.ptr[text.length];
            }

            void main() {
                assert(after == 0);
            }
        });
    }
}

// A literal that the lexer read is followed by zero in compiled D too.
static foreach (backend; Matrix!(NoCtfe)) {
    @("string.sourceLiteralsAreFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }
            short afterWide(wstring text) { return text.ptr[text.length]; }
            int afterDouble(dstring text) { return text.ptr[text.length]; }

            void main() {
                assert(after("abc") == 0);
                assert(after("") == 0);
                assert(after(x"41 42") == 0);
                assert(after(q{a b}) == 0);
                assert(after(__FILE__) == 0);
                assert(afterWide("abc"w) == 0);
                assert(afterDouble("abc"d) == 0);
            }
        });
    }
}

// The same folded literal gives the same address each time it is evaluated.
static foreach (backend; Matrix!()) {
    @("string.foldedLiteralKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            const(char)* pointer(string text) { return text.ptr; }

            void main() {
                const(char)* first;
                foreach (i; 0 .. 3) {
                    const p = pointer("ab" ~ "cd");
                    if (i == 0)
                        first = p;
                    else
                        assert(p is first);
                }
            }
        });
    }
}
