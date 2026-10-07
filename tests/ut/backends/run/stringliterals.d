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
    @("string.plainSourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                assert(after("abc") == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.emptySourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                assert(after("") == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.hexSourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                assert(after(x"41 42") == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.tokenStringSourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                assert(after(q{a b}) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.fileNameSourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            char after(string text) { return text.ptr[text.length]; }

            void main() {
                assert(after(__FILE__) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.wideSourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            short after(wstring text) { return text.ptr[text.length]; }

            void main() {
                assert(after("abc"w) == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(NoCtfe)) {
    @("string.doubleWideSourceLiteralIsFollowedByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int after(dstring text) { return text.ptr[text.length]; }

            void main() {
                assert(after("abc"d) == 0);
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

// A manifest constant has one address in compiled D: dmd makes a new
// literal for each use, and the object file keeps one copy of equal text.
static foreach (backend; Matrix!()) {
    @("string.enumUsedTwiceKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum string name = "enum text";

            void main() {
                string first = name;
                string second = name;
                assert(first is second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("string.enumUsedInTwoFunctionsKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum string name = "enum text";

            string first() { return name; }
            string second() { return name; }

            void main() {
                assert(first is second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("string.foldedEnumUsedTwiceKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum string name = "fol" ~ "ded";

            void main() {
                string first = name;
                string second = name;
                assert(first is second);
            }
        });
    }
}

// Each instance of a template has its own copy of the body, but the
// literal in it is one object in compiled D.
static foreach (backend; Matrix!()) {
    @("string.literalInTwoTemplateInstancesKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string name(T)() { return "template text"; }

            void main() {
                assert(name!int is name!long);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("string.literalInTwoMixinTemplatesKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            mixin template Named() {
                string name() { return "mixin text"; }
            }

            struct First { mixin Named; }
            struct Second { mixin Named; }

            void main() {
                assert(First().name is Second().name);
            }
        });
    }
}

// dmd copies the default argument into each call that omits it.
static foreach (backend; Matrix!()) {
    @("string.defaultArgumentLiteralKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string name(string text = "default text") { return text; }

            void main() {
                string first = name;
                string second = name;
                assert(first is second);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("string.fileNameUsedTwiceKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                string first = __FILE__;
                string second = __FILE__;
                assert(first is second);
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.equalLiteralsInOneFunctionKeepOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                string first = "equal text";
                string second = "equal text";
                assert(first is second);
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.equalLiteralsInTwoFunctionsKeepOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string first() { return "equal text"; }
            string second() { return "equal text"; }

            void main() {
                assert(first is second);
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.equalLiteralsCompareIdentical." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                assert("abc" is "abc");
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.enumAndLiteralOfEqualTextKeepOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum string name = "equal text";

            void main() {
                string literal = "equal text";
                assert(name is literal);
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.foldedAndSourceLiteralOfEqualTextKeepOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                string folded = "equal" ~ " text";
                string source = "equal text";
                assert(folded is source);
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.wideLiteralUsedTwiceKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                wstring first = "abc"w;
                wstring second = "abc"w;
                assert(first is second);
            }
        });
    }
}

// Equal text in different literals has one address: the object file keeps
// one copy of it.
static foreach (backend; Matrix!()) {
    @("string.typeNameUsedTwiceKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                string first = int.stringof;
                string second = int.stringof;
                assert(first is second);
            }
        });
    }
}

// The code unit width is part of the text: these two have the same bytes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE rejects a cast between pointer types of different width"),
)) {
    @("string.narrowAndWideLiteralOfEqualBytesDiffer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                string narrow = "ab\0";
                wstring wide = "\u6261"w;
                assert(narrow.ptr !is cast(const(char)*) wide.ptr);
            }
        });
    }
}

// A literal is read-only data in compiled D, which the GC does not own.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot ask the GC about a pointer"),
)) {
    @("string.literalIsOutsideTheGcHeap." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;

            void main() {
                string folded = "fol" ~ "ded";
                assert(GC.addrOf(folded.ptr) is null);
            }
        });
    }
}

// Threads that evaluate one literal for the first time at the same moment
// must all get the one address, as in compiled D.
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible, "CTFE cannot start a thread"))) {
    @("string.literalKeepsOneAddressAcrossThreads." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.thread: Thread;

            enum literals = 300;
            enum threads = 8;

            __gshared bool start;

            void collect(const(char)*[] pointers) {
                static foreach (i; 0 .. literals)
                    pointers[i] = (i.stringof ~ "-literal").ptr;
            }

            Thread collector(const(char)*[] pointers) {
                return new Thread({
                    while (!start)
                        Thread.yield;
                    collect(pointers);
                });
            }

            void main() {
                auto pointers = new const(char)*[][threads];
                Thread[] collectors;
                foreach (ref mine; pointers) {
                    mine = new const(char)*[literals];
                    collectors ~= collector(mine);
                }
                foreach (thread; collectors)
                    thread.start;
                start = true;
                foreach (thread; collectors)
                    thread.join;
                foreach (mine; pointers[1 .. $])
                    assert(mine == pointers[0]);
            }
        });
    }
}


// A host C function reads a plain literal through its `.ptr`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call a host C function that has no source code"),
)) {
    @("string.literalPtrPassedToHostFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: strlen;

            void main() {
                auto n = strlen("hi".ptr);
                assert(n == 2);
            }
        });
    }
}

// A literal as the argument of a `const(char)*` parameter of a host
// function.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call a host C function that has no source code"),
)) {
    @("string.literalToConstCharPointerParameter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: strlen;

            void main() {
                assert(strlen("x") == 1);
            }
        });
    }
}
