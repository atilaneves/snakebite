module ut.backends.run.structs;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A slice assignment copies element by element and runs the postblit for
// each one, rather than blitting the whole slice.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("sliceAssignRunsPostBlitPerElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int copies;

            struct Element {
                int value;

                this(this) {
                    ++copies;
                }
            }

            void main() {
                Element[] source = [Element(3), Element(5)];
                Element[] target = new Element[source.length];

                const before = copies;
                target[] = source[];

                assert(copies == before + 2);
                assert(target[0].value == 3);
                assert(target[1].value == 5);
            }
        });
    }
}

// A struct allocated with `new` runs its constructor in the allocated
// storage. An immutable field is initialized with a construct expression,
// so this also checks that constructor initialization reaches the object
// field rather than being rejected as an assignment.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("struct.new.constructorInitializesImmutableField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            struct Value {
                immutable int value;

                this(int value) {
                    this.value = value;
                }
            }

            int main() {
                auto value = new Value(42);
                return value.value;
            }
        }, "main");
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("struct.new.constructorBindsRefParameter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        43.shouldBeRetOf!(backend, q{
            struct Value {
                int value;

                this(ref int source) {
                    ++source;
                    value = source;
                }
            }

            int main() {
                int source = 42;
                auto value = new Value(source);
                return value.value;
            }
        }, "main");
    }
}

// The members of an anonymous union occupy the same storage, so writing
// through one member changes what is read back through another.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("anonymousUnionMembersShareStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                union {
                    int a;
                    uint b;
                }
            }

            void main() {
                S s;
                s.a = -1;
                assert(s.b == uint.max);
            }
        });
    }
}

// A struct declared inside a function sees that function's locals, so its
// method can call a delegate the function made.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("nestedStructMethodSeesEnclosingDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            auto wrap() {
                int base = 40;
                int delegate() dg = () => base + 2;

                struct Caller {
                    int call() {
                        return dg();
                    }
                }

                return Caller();
            }

            void main() {
                assert(wrap().call() == 42);
            }
        });
    }
}

// `.tupleof` on both sides assigns field by field between the two field
// lists, so it works across struct types that share a field layout even
// though they share no other relationship.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("tupleofAssignsFieldwise." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair {
                int head;
                long tail;
            }

            struct Twin {
                int head;
                long tail;
            }

            void main() {
                auto source = Pair(2, 3L);
                Twin target;
                target.tupleof = source.tupleof;
                assert(target.head == 2);
                assert(target.tail == 3);
            }
        });
    }
}

// A struct literal writes each field at its own native offset, and a
// plain field assignment overwrites only that field's own bytes, leaving
// its siblings untouched.
static foreach (backend; Matrix!()) {
    @("localStructConstructionAndFieldAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                long y;
            }

            void main() {
                auto p = Point(3, 4);
                assert(p.x == 3);
                assert(p.y == 4);

                p.x = 10;
                assert(p.x == 10);
                assert(p.y == 4);
            }
        });
    }
}

// Assigning one struct local to another copies every field's bytes, not a
// reference: mutating the copy leaves the original untouched.
static foreach (backend; Matrix!()) {
    @("structLocalAssignmentCopiesByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                int y;
            }

            void main() {
                auto a = Point(1, 2);
                auto b = a;
                b.x = 99;

                assert(a.x == 1);
                assert(b.x == 99);
            }
        });
    }
}

// A struct passed by value into a function, and returned by value out of
// one, is copied both ways - the callee's own mutation of its parameter
// never reaches the caller's argument.
static foreach (backend; Matrix!()) {
    @("structParametersAndReturnsCopyByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                int y;
            }

            Point make(int a, int b) {
                return Point(a, b);
            }

            int sum(Point p) {
                p.x = -1;
                return p.x + p.y;
            }

            void main() {
                auto p = make(3, 4);
                assert(sum(p) == 3);
                assert(p.x == 3);
            }
        });
    }
}

// A nested struct field is reached through its own enclosing field's
// offset, added to the outer field's.
static foreach (backend; Matrix!()) {
    @("nestedStructFieldAccess." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Inner {
                int value;
            }

            struct Outer {
                Inner inner;
                int tag;
            }

            void main() {
                Outer o;
                o.inner.value = 7;
                o.tag = 2;
                assert(o.inner.value == 7);
                assert(o.tag == 2);
            }
        });
    }
}

// `is` on structs compares raw bytes, so a dynamic array field is
// compared as its length and pointer, not its contents - unlike `==`,
// which walks into the array and compares elements.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("structIdentityComparesArrayFieldByReference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int[] xs;
            }

            void main() {
                auto a = [1, 2, 3];
                auto s1 = S(a);
                auto s2 = S(a.dup);

                assert(s1 == s2);
                assert(!(s1 is s2));
                assert(s1 is s1);
            }
        });
    }
}

// `==` on structs walks into each field and compares it the way `==`
// compares that field's own type on its own - a float field follows IEEE
// 754, where `-0.0` equals `0.0` and `double.nan` never equals itself,
// unlike a raw byte compare.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("structEqualityComparesFloatFieldByIeeeRules." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                double value;
            }

            void main() {
                assert(S(0.0) == S(-0.0));
                assert(!(S(double.nan) == S(double.nan)));
            }
        });
    }
}

// `new S(args)` with no declared constructor initializes the fields
// positionally, in declaration order, from the constructor arguments -
// the same as a struct literal `S(args)` would.
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

// A whole struct element is stored and loaded through the array's own
// indirection - `opStoreIndirect`/`opLoadIndirect` moving `struct.sizeof`
// bytes at once, the same as a scalar element's own single word - and
// reading it out into a local copies its bytes rather than aliasing the
// array's own storage.
static foreach (backend; Matrix!()) {
    @("arrayOfStructsElementStoreLoadAndCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                int y;
            }

            void main() {
                auto points = new Point[](3);
                points[0] = Point(1, 2);
                points[1] = Point(3, 4);
                points[2] = Point(5, 6);

                auto copy = points[1];
                copy.x = -1;

                assert(points[1].x == 3);
                assert(copy.x == -1);
                assert(points[0].x + points[2].x == 6);
                assert(points[0].y + points[2].y == 8);
            }
        });
    }
}

// A non-trivial constructor call passed straight as an argument is an
// rvalue with no variable of its own. dmd's field-wise constructor for the
// outer struct still takes this argument by address (the same lowering a
// `ref` parameter gets), so the interpreter must give the temporary a
// frame slot before the inner constructor runs, rather than reject it for
// having no lvalue to take the address of. The scalar argument before it
// checks that binding the temporary does not depend on it being the first
// argument evaluated.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorCallArgumentAfterScalarArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Part {
                size_t count;
                ubyte first;

                this(ubyte[] bytes) {
                    count = bytes.length;
                    first = bytes[0];
                }
            }

            struct Whole {
                ubyte tag;
                Part part;
            }

            void main() {
                ubyte[] payload = [9, 7, 6];
                auto whole = Whole(2, Part(payload));

                assert(whole.tag == 2);
                assert(whole.part.count == 3);
                assert(whole.part.first == 9);
            }
        });
    }
}

// As above, with the temporary constructor call before the scalar
// argument - the outer struct's field order should not matter to how the
// temporary's storage is found.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorCallArgumentBeforeScalarArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Part {
                size_t count;
                ubyte first;

                this(ubyte[] bytes) {
                    count = bytes.length;
                    first = bytes[0];
                }
            }

            struct Whole {
                Part part;
                ubyte tag;
            }

            void main() {
                ubyte[] payload = [9, 7, 6];
                auto whole = Whole(Part(payload), 2);

                assert(whole.part.count == 3);
                assert(whole.part.first == 9);
                assert(whole.tag == 2);
            }
        });
    }
}

// A constructor-call temporary nested inside another constructor-call
// temporary: the outer struct's own field-wise constructor takes its
// `Middle` argument by address the same way, and `Middle`'s in turn takes
// `Part` by address, so both levels of temporary need a frame slot before
// their constructor runs.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("nestedStructCtorCallArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Part {
                size_t count;
                ubyte first;

                this(ubyte[] bytes) {
                    count = bytes.length;
                    first = bytes[0];
                }
            }

            struct Middle {
                Part part;
            }

            struct Outer {
                ubyte tag;
                Middle middle;
            }

            void main() {
                ubyte[] payload = [9, 7, 6];
                auto whole = Outer(2, Middle(Part(payload)));

                assert(whole.middle.part.count == 3);
                assert(whole.middle.part.first == 9);
            }
        });
    }
}

// A function call that itself returns a struct by value, used as a
// constructor argument: the call has no lvalue either, and the interpreter
// must materialize its return value into a frame slot to hand its address
// to the outer constructor.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("functionReturningStructAsCtorCallArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Part {
                size_t count;
                ubyte first;

                this(ubyte[] bytes) {
                    count = bytes.length;
                    first = bytes[0];
                }
            }

            struct Whole {
                ubyte tag;
                Part part;
            }

            Part makePart(ubyte[] bytes) {
                return Part(bytes);
            }

            void main() {
                ubyte[] payload = [9, 7, 6];
                auto whole = Whole(2, makePart(payload));

                assert(whole.part.count == 3);
                assert(whole.part.first == 9);
            }
        });
    }
}

// A ternary between two constructor calls, used as a constructor argument:
// only the branch actually taken ever runs, so only its temporary needs a
// frame slot - the other branch's temporary is never constructed.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("ternaryBetweenStructCtorCallsAsCtorCallArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Part {
                size_t count;
                ubyte first;

                this(ubyte[] bytes) {
                    count = bytes.length;
                    first = bytes[0];
                }
            }

            struct Whole {
                ubyte tag;
                Part part;
            }

            void main() {
                ubyte[] longer = [9, 7, 6];
                ubyte[] shorter = [1, 2];
                bool pickLonger = longer.length > shorter.length;
                auto whole = Whole(
                    2, pickLonger ? Part(longer) : Part(shorter),
                );

                assert(whole.part.count == 3);
                assert(whole.part.first == 9);
            }
        });
    }
}

// A constructor call as the return expression of an `auto ref` lambda: the
// lambda's own return place is the temporary's eventual home, but the
// constructor's hidden `this` is bound before that return place is filled,
// so this exercises the same rvalue-materialization path with no
// surrounding struct constructor at all.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorCallReturnedFromAutoRefLambda." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Reading {
                int amount;

                this(int amount) {
                    this.amount = amount;
                }
            }

            auto wrapReading(V)(auto ref V value) {
                return () { return Reading(value); }();
            }

            void main() {
                int measured = 5;
                auto reading = wrapReading(measured);

                assert(reading.amount == measured);
            }
        });
    }
}

// A constructor call nested inside another constructor call's argument,
// where the inner constructor's own body calls an ordinary function
// before it is done. The interpreter reserves the inner temporary's
// frame slot before that ordinary call runs, and the slot must still be
// there - not reused for the ordinary call's own frame - when the
// constructor resumes writing to it afterward.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorCallBodyCallsAnotherFunctionBeforeFinishing." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            size_t helper(size_t n) {
                return n + 100;
            }

            struct Part {
                size_t count;
                size_t extra;

                this(size_t n) {
                    count = n;
                    extra = helper(99);
                }
            }

            struct Whole {
                ubyte tag;
                Part part;
            }

            void main() {
                auto whole = Whole(2, Part(7));

                assert(whole.part.count == 7);
                assert(whole.part.extra == 199);
                assert(whole.tag == 2);
            }
        });
    }
}

// A constructor that throws partway through, caught by its caller: the
// temporary frame slot the interpreter reserved for the hidden `this`
// must still be released, or it leaks for the rest of the run. A later,
// unrelated recursive call is run afterward to disturb the frame stack
// where that leaked slot would have been, and the same construction is
// then repeated to check its zero-initialization was not skipped by a
// stale cache entry from the failed attempt.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorCallThrowDoesNotLeakItsSlot." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Part {
                size_t count;
                size_t sometimes;

                this(size_t n) {
                    if (n == 0)
                        throw new Exception("zero");
                    count = n;
                    if (n > 100)
                        sometimes = n;
                }
            }

            struct Whole {
                ubyte tag;
                Part part;
            }

            size_t make(size_t n) {
                auto w = Whole(2, Part(n));
                return w.part.sometimes;
            }

            size_t scribble(
                size_t a, size_t b, size_t c, size_t d, size_t depth,
            ) {
                if (depth == 0)
                    return a;
                return scribble(a, b, c, d, depth - 1);
            }

            void main() {
                try {
                    make(0);
                    assert(false);
                } catch (Exception e) {}

                scribble(0xDEAD, 0xDEAD, 0xDEAD, 0xDEAD, 20);

                assert(make(5) == 0);
            }
        });
    }
}

// A constructor's own body recursively calls back into the very same
// call site that is mid-construction of it - the same
// `Whole(2, Part(n))` syntax node, revisited before its outer activation
// is done with it. The interpreter must give the inner activation its
// own frame slot rather than serve it the outer, still-live one.
//
// `make` is a delegate variable, assigned only after `Part` and `Whole`
// are declared, rather than an ordinary function declared below them:
// `shouldBeRetOf`'s own native comparison mixes this snippet into a
// function body to run it as compiled D, and a nested function cannot
// forward-reference another nested function the way two module-level
// declarations can. Referring to an already-visible variable sidesteps
// that, without changing what the interpreter is being asked to do -
// call back into the same construction site while it is still running.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a closure's captured variable at compile " ~
        "time - `make` is exactly that, the trampoline this test uses " ~
        "so two nested declarations can refer to each other despite " ~
        "`shouldBeRetOf`'s own native comparison mixing this snippet " ~
        "into a function body, where a nested declaration cannot " ~
        "forward-reference another one the way two module-level " ~
        "declarations can"),
)) {
    @("structCtorCallReentersItsOwnConstructionSite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(backend, q{
            size_t delegate(size_t) make;

            struct Part {
                size_t count;

                this(size_t n) {
                    count = n == 0 ? 0 : make(n - 1) + 1;
                }
            }

            struct Whole {
                ubyte tag;
                Part part;
            }

            int main() {
                make = (size_t n) {
                    auto w = Whole(2, Part(n));
                    return w.part.count;
                };

                return cast(int) make(3);
            }
        }, "main");
    }
}
