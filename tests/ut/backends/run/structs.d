module ut.backends.run.structs;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `with` on a struct evaluates the value once, then resolves each unqualified
// member through that same storage. The assignments must update the source
// value, not a copied temporary.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed, "no WithStatement support"),
)) {
    @("struct.withStatementUsesAggregateStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                int first;
                int second;
            }

            void main() {
                Value value = Value(3, 5);

                with (value) {
                    first = 8;
                    second += first;
                }

                assert(value.first == 8);
                assert(value.second == 13);
            }
        });
    }
}


// A field of a non-plain aggregate still has the aggregate's native address.
// The destructor is handled by the DMD-generated cleanup around the local.
static foreach (backend; Matrix!()) {
    @("struct.nonPlainFieldAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                int result;

                ~this() {
                }
            }

            void main() {
                Value value;
                value.result = 42;
                assert(value.result == 42);
            }
        });
    }
}


// A non-plain aggregate can cross a guest call as native bytes. The
// destructor is handled by the DMD-generated cleanup around the local.
static foreach (backend; Matrix!()) {
    @("struct.nonPlainValueParameter.crossesGuestCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                ~this() {
                }
            }

            void consume(Value value) {
            }

            void main() {
                Value value;
                consume(value);
            }
        });
    }
}


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
    Omit!(Ctfe, Because.unconfirmed),
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

// A local struct without an explicit initializer starts with each field's
// declared nonzero default value, not with zero-filled storage.
static foreach (backend; Matrix!(Omit!(Bytecode, Because.unconfirmed))) {
    @("localStructUsesNonzeroFieldDefault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                int number = 42;
            }

            void main() {
                Value value;
                assert(value.number == 42);
            }
        });
    }
}

// `static` changes how the local type is represented during semantic
// analysis, but it does not give an instance static storage. Constructing an
// instance still creates an ordinary local value with native struct layout.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed),
)) {
    @("staticLocalStructConstruction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                static struct Payload {
                    ubyte value;
                }

                auto payload = Payload(42);
                assert(payload.value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE engine aliases a static-array local on `=` " ~
        "instead of copying it, unlike its runtime codegen"),
)) {
    @("packedArrayFieldCopiesByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void check(size_t width)() {
                struct Packed {
                    align(1):
                    ubyte prefix;
                    ubyte[width] value;
                    ubyte suffix;
                }

                Packed source = void;
                source.prefix = 91;
                source.suffix = 92;
                foreach (i; 0 .. width)
                    source.value[i] = cast(ubyte) (i + 1);

                auto copy = source.value;
                foreach (i; 0 .. width)
                    assert(copy[i] == i + 1);
                copy[0] = 99;
                assert(source.value[0] == 1);
                assert(source.prefix == 91);
                assert(source.suffix == 92);
            }

            void main() {
                check!1;
                check!2;
                check!4;
                check!8;
                check!16;
                check!3;
                check!24;
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
// `ref` parameter gets), so a backend must give the temporary a frame
// slot before the inner constructor runs, rather than reject it for
// having no lvalue to take the address of. The scalar argument before it
// checks that binding the temporary does not depend on it being the first
// argument evaluated.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
// own frame slot rather than serve it the outer, still-live one:
// `stamp` is written before the recursive call and checked afterward,
// so an inner activation sharing the outer's slot would clobber `stamp`
// and fail the assert inside the constructor.
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
    Omit!(Bytecode, Because.unconfirmed,
        "the guest crashes the host process (SIGSEGV) instead of " ~
            "returning or throwing - `make`'s recursive call reenters " ~
            "`Whole(2, Part(n))`'s own construction site while the outer " ~
            "activation is still live, and something about that "
            ~ "re-entrant frame layout is unsound here, not merely "
            ~ "unimplemented"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE refuses to read a mutable static variable - `make` is " ~
        "exactly that in the guest, where this snippet is a module and " ~
        "`make` a module-level variable. The trampoline exists so the " ~
        "constructor can call back into a declaration the harness's " ~
        "native arm - which mixes this snippet into a function body, " ~
        "where nested functions cannot forward-reference each other - " ~
        "can still express"),
)) {
    @("structCtorCallReentersItsOwnConstructionSite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(backend, q{
            size_t delegate(size_t) make;

            struct Part {
                size_t stamp;
                size_t count;

                this(size_t n) {
                    stamp = n + 10;
                    count = n == 0 ? 0 : make(n - 1) + 1;
                    assert(stamp == n + 10);
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

// A method called on a constructor-call rvalue, where the method's own
// body makes a further guest call. D keeps the rvalue temporary alive
// until the end of the full expression, so `this` must still hold the
// constructor's writes when the method reads `payload` - even though the
// helper call in between reserves and fills a frame of its own.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorRvalueMethodBodyCallsHelper." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long helper(long a, long b, long c, long d) {
                return a + b + c + d;
            }

            struct Part {
                long payload;

                this(long payload) {
                    this.payload = payload;
                }

                long describe() {
                    // The helper call comes first and `payload` is read
                    // after it returns, so the temporary holding `this`
                    // must survive the helper's own frame coming and
                    // going.
                    return helper(4, 3, 2, 0) + payload;
                }
            }

            void main() {
                assert(Part(3000).describe() == 3009);
            }
        });
    }
}

// A guest throw while an outer constructor call is still binding its
// arguments: the inner `Q` temporary exists by the time `mayThrow`
// throws, and the whole expression is abandoned. The temporary must be
// released cleanly on that unwinding path, and a later construction must
// then work as if the failed one never happened.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("structCtorArgumentThrowDuringOuterArgumentBinding." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long mayThrow(long n) {
                if (n == 0)
                    throw new Exception("zero");
                return n;
            }

            struct Q {
                long a;
                long b;

                this(long a, long b) {
                    this.a = a;
                    this.b = b;
                }
            }

            struct W {
                long tag;
                Q q;
                long total;

                this(long tag, Q q) {
                    this.tag = tag;
                    this.q = q;
                    // A guest call after the field writes: its frame must
                    // not land on top of the temporary this constructor
                    // is writing `this` into, so the fields must still be
                    // intact when `total` sums them afterward.
                    this.total = mayThrow(1) + this.tag + this.q.a
                        + this.q.b;
                }
            }

            // One function makes both attempts, so the second call runs
            // the very same construction expression the first call
            // abandoned mid-argument-binding.
            long make(long tag, long a, long b) {
                auto w = W(tag, Q(a, mayThrow(b)));
                return w.tag + w.q.a + w.q.b + w.total;
            }

            void main() {
                bool caught;
                try {
                    make(2, 1, 0);
                } catch (Exception e) {
                    caught = true;
                }
                assert(caught);

                assert(make(3, 4, 5) == 25);
            }
        });
    }
}

// Reading a field straight off a value-returning call, hundreds of
// thousands of times: each iteration materializes a 4KiB temporary for
// the call's result, and D destroys it at the end of that iteration's
// full expression. A temporary that instead survives the statement leaks
// its reservation every iteration and exhausts the frame stack well
// before the loop is done.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed,
        "not run: 300000 CTFE iterations, each copying a 4KiB struct, " ~
        "take longer than a unit test can afford"),
)) {
    @("structValueCallFieldReadsDoNotExhaustFrameStack." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Big {
                long[511] pad;
                long count;
            }

            Big makeBig(long n) {
                Big b;
                b.count = n;
                return b;
            }

            void main() {
                long total;
                foreach (i; 0 .. 300_000)
                    total += makeBig(i).count;
                assert(total == 299_999L * 300_000 / 2);
            }
        });
    }
}

// A postblit runs once on the copy from an lvalue into a fresh variable:
// dmd's semantic pass rewrites `Tracked copy = source;` into a blit of
// `source`'s bytes onto `copy` followed by an explicit call to
// `Tracked.postblit` with `copy` as `this` (`(copy = source).postblit()`),
// so this is an ordinary struct-typed variable declaration and an
// ordinary method call once a struct with a postblit is no longer refused
// outright.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("postblitRunsOnceOnCopyIntoVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Tracked {
                int* postblits;

                this(this) {
                    ++*postblits;
                }
            }

            void main() {
                int postblits = 0;
                Tracked source = Tracked(&postblits);
                Tracked copy = source;
                assert(postblits == 1);
            }
        });
    }
}

// D destroys an rvalue temporary at the end of the full expression that
// created it, even when nothing ever consumes the value: this temporary's
// only use is `.get()`, called on the constructor-call rvalue itself, and
// its destructor still runs once the statement using it is done.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE evaluates the call but never runs the " ~
        "destructor of a struct-typed rvalue temporary that is only " ~
        "consumed by a method call on itself and never bound to a " ~
        "variable - `dtors` stays 0 instead of reaching 1"),
)) {
    @("destructorRunsAtFullExpressionEndForUnconsumedTemporary." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Tracked {
                int* dtors;

                ~this() {
                    ++*dtors;
                }

                int get() {
                    return 42;
                }
            }

            void main() {
                int dtors = 0;
                auto value = Tracked(&dtors).get();
                assert(dtors == 1);
                assert(value == 42);
            }
        });
    }
}

// The `TrackerHolder`/`LifetimeTracker` shape from the ct-full corpus
// (issue #142): a postblit runs exactly once when a field is constructed
// by copying an lvalue, and not at all when the field is constructed
// directly from an rvalue - a struct literal or a function's returned
// value - since there is nothing to copy from in either of those cases.
// The scope-exit destructor calls dmd inserts for `source`/`copied` and
// for `moved`/`constructed` account for every increment of `dtors`.
static foreach (backend; Matrix!()) {
    @("postblitAndDestructorThroughFieldCopyMoveAndDirectConstruction." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct LifetimeTracker {
                int* postblits;
                int* dtors;

                this(this) {
                    ++*postblits;
                }

                ~this() {
                    ++*dtors;
                }
            }

            struct TrackerHolder {
                int tag;
                LifetimeTracker tracker;
            }

            LifetimeTracker makeTracker(int* postblits, int* dtors) {
                return LifetimeTracker(postblits, dtors);
            }

            void main() {
                int postblits = 0;
                int dtors = 0;

                {
                    LifetimeTracker source =
                        LifetimeTracker(&postblits, &dtors);
                    TrackerHolder copied = TrackerHolder(1, source);

                    assert(postblits == 1);
                    assert(dtors == 0);
                }

                assert(dtors == 2);

                postblits = 0;
                dtors = 0;

                {
                    TrackerHolder moved =
                        TrackerHolder(2, makeTracker(&postblits, &dtors));
                    TrackerHolder constructed = TrackerHolder(
                        3, LifetimeTracker(&postblits, &dtors));

                    assert(postblits == 0);
                    assert(dtors == 0);
                }

                assert(dtors == 2);
            }
        });
    }
}

// A guest throw partway through evaluating a call's arguments: the first
// argument's temporary (the constructor-call rvalue `Tracked` bound to
// `.get()`'s hidden `this`) is already fully constructed by the time the
// second argument's call throws, and native D still runs its destructor
// once as the whole expression unwinds - the temporary is not silently
// leaked just because nothing ever consumed its value.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE catches the throw but never runs the " ~
        "destructor of the already-constructed first-argument temporary " ~
        "while unwinding the call expression - `dtors` stays 0 instead " ~
        "of reaching 1"),
)) {
    @("destructorRunsForAlreadyConstructedTemporaryOnThrowMidExpression." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Tracked {
                int* dtors;

                ~this() {
                    ++*dtors;
                }

                int get() {
                    return 42;
                }
            }

            int take(int a, int b) {
                return a + b;
            }

            int throwing() {
                throw new Exception("boom");
            }

            void main() {
                int dtors = 0;
                bool caught;
                try {
                    take(Tracked(&dtors).get(), throwing());
                } catch (Exception e) {
                    caught = true;
                }
                assert(caught);
                assert(dtors == 1);
            }
        });
    }
}

// dmd lowers `foreach (x; Range(...))` to
// `Range __aggr4 = Range(...); try { for (...) { ... } } finally
// { __aggr4.__dtor(); }` - `__aggr4` is `STC.temp` with a non-null
// `edtor`, the same as an `addDtorHook` temporary, but its declaration
// is the whole statement, not a fragment of a larger one, and its
// destructor is already called explicitly by the `finally`. Registering
// it a second time from the declaration would destroy the range twice.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("foreachRangeTemporaryDestroyedOnceByItsOwnFinally." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Range {
                int* dtors;
                int i;

                ~this() {
                    ++*dtors;
                }

                bool empty() {
                    return i >= 3;
                }

                int front() {
                    return i;
                }

                void popFront() {
                    ++i;
                }
            }

            void main() {
                int dtors = 0;
                int sum = 0;
                foreach (x; Range(&dtors, 0))
                    sum += x;
                assert(dtors == 1);
                assert(sum == 3);
            }
        });
    }
}

// dmd lowers `T(&dtors, true).get()`, where `T` has a user-defined
// constructor, to
// `((T __slT6 = T(null);), __slT6).__ctor(&dtors, true).get()`: the
// declaration only default-initializes the temporary, and the real
// construction is a separate, fallible `__ctor` call afterward. When
// that call throws, the temporary was never actually constructed, so
// native D does not run its destructor for it - registering the
// destructor at the declaration, before the constructor call that can
// still fail, would run it anyway.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("temporaryWithThrowingConstructorRunsNoDestructor." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;

                this(int* d, bool doThrow) {
                    dtors = d;
                    if (doThrow) throw new Exception("ctor");
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int get() {
                    return 5;
                }
            }

            void main() {
                int dtors = 0;
                bool caught;
                try
                    T(&dtors, true).get();
                catch (Exception e)
                    caught = true;
                assert(caught);
                assert(dtors == 0);
            }
        });
    }
}

// The result of the temporary's method feeds a declaration
// (`int r = T(&dtors).get();`), so the constructor-call receiver is
// evaluated for its address rather than as a statement of its own. The
// temporary's construction still completes - the `__ctor` call in
// dmd's `((T __slT = T(null);), __slT).__ctor(&dtors)` lowering
// returns normally - so its destructor runs exactly once at the end of
// the full expression, the same as when the result is discarded.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE computes the right value but never runs " ~
        "the destructor of the user-constructor temporary once its " ~
        "value feeds a declaration - `dtors` stays 0 instead of " ~
        "reaching 1"),
)) {
    @("userCtorTemporaryConsumedAsValueRunsDestructorOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;

                this(int* d) {
                    dtors = d;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int get() {
                    return 5;
                }
            }

            void main() {
                int dtors = 0;
                int r = T(&dtors).get();
                assert(dtors == 1);
                assert(r == 5);
            }
        });
    }
}

// The temporary's own `__ctor` call returns normally; the method
// called on it afterward, still inside the same full expression, is
// what throws. Native D destroys every temporary whose construction
// completed when the full expression unwinds, so the destructor runs
// exactly once - construction finishing, not the expression finishing,
// is what commits the destructor.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE catches the throw but never runs the " ~
        "destructor of the user-constructor temporary whose `__ctor` " ~
        "already completed - `dtors` stays 0 instead of reaching 1"),
)) {
    @("userCtorTemporaryDestroyedWhenLaterCallInExpressionThrows." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;

                this(int* d) {
                    dtors = d;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int boom() {
                    throw new Exception("later");
                }
            }

            void main() {
                int dtors = 0;
                bool caught;
                try
                    T(&dtors).boom();
                catch (Exception e)
                    caught = true;
                assert(caught);
                assert(dtors == 1);
            }
        });
    }
}

// A constructor whose body builds another temporary of its own type
// re-enters the same lowered `((T __slT = T(null);), __slT).__ctor`
// nodes while an outer activation of them is still live. Each
// activation owns its own temporary: the two inner recursion levels
// destroy theirs when their enclosing statement inside the constructor
// body ends, and the outermost temporary is destroyed at the end of
// the full expression that created it - three destructor runs in
// total, never a shared or clobbered slot.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE computes the right return value but " ~
        "never runs the destructor of any of the three reentrant " ~
        "user-constructor temporaries - `dtors` stays 0 instead of " ~
        "reaching 3"),
)) {
    @("userCtorTemporaryReentrantConstructionDestroysEachActivation." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;
                int depth;

                this(int* d, int dep) {
                    dtors = d;
                    depth = dep;
                    if (dep > 0)
                        T(d, dep - 1).id();
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int id() {
                    return depth;
                }
            }

            void main() {
                int dtors = 0;
                int r = T(&dtors, 2).id();
                assert(dtors == 3);
                assert(r == 2);
            }
        });
    }
}

// A callee reached mid-expression runs its own full expressions, each
// with a constructor-called temporary of its own. The callee's
// temporary is destroyed when the callee's statement ends, inside the
// caller's still-evaluating expression; the caller's own temporary is
// destroyed when the outer full expression ends. Two temporaries, two
// destructor runs, each owned by its own full expression.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE computes the right return value but " ~
        "never runs the destructor of either user-constructor " ~
        "temporary - `dtors` stays 0 instead of reaching 2"),
)) {
    @("userCtorTemporaryInCalleeAndCallerDestroyedByTheirOwnExpressions." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;

                this(int* d) {
                    dtors = d;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int get() {
                    return 3;
                }
            }

            int helper(int* dtors) {
                return T(dtors).get();
            }

            void main() {
                int dtors = 0;
                int r = helper(&dtors) + T(&dtors).get();
                assert(dtors == 2);
                assert(r == 6);
            }
        });
    }
}

// The user-defined-constructor variant of the `foreach` range shape:
// dmd declares the range temporary as its own whole statement
// (`Range __aggr = Range(...);`, the constructor called directly on
// the named variable) and destroys it in the explicit `finally` it
// wraps the loop in. The constructor call returning must not commit a
// second destructor run for a variable whose destruction that
// `finally` already owns.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("foreachRangeWithUserCtorDestroyedOnceByItsOwnFinally." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Range {
                int* dtors;
                int i;
                int n;

                this(int* d, int limit) {
                    dtors = d;
                    i = 0;
                    n = limit;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                bool empty() {
                    return i >= n;
                }

                int front() {
                    return i;
                }

                void popFront() {
                    ++i;
                }
            }

            void main() {
                int dtors = 0;
                int sum = 0;
                foreach (x; Range(&dtors, 3))
                    sum += x;
                assert(dtors == 1);
                assert(sum == 3);
            }
        });
    }
}

// A temporary of a user-constructor type initialized from an already
// completed value: dmd lowers `make(&dtors).get()` to
// `((T __tmpfordtor5 = make(&dtors);) , __tmpfordtor5).get()` - the
// declaration's initializer is the function's returned value, whole,
// with no follow-up `__ctor` call anywhere. Whether construction is
// still pending is a property of the initializer, not of the type
// having a constructor: this temporary is fully constructed at its
// declaration, and its destructor runs once at the end of the full
// expression.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE computes the right return value but " ~
        "never runs the destructor of the temporary initialized from " ~
        "`make(&dtors)`'s returned value - `dtors` stays 0 instead of " ~
        "reaching 1"),
)) {
    @("userCtorTypeTemporaryFromReturnedValueRunsDestructorOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;
                int v;

                this(int* d, int value) {
                    dtors = d;
                    v = value;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int get() {
                    return v;
                }
            }

            T make(int* d) {
                return T(d, 6);
            }

            void main() {
                int dtors = 0;
                int r = make(&dtors).get();
                assert(dtors == 1);
                assert(r == 6);
            }
        });
    }
}

// A ternary between two constructor-called temporaries: dmd hoists the
// condition into its own temporary and declares one `__slT` per
// branch, each with a destructor guarded by that condition, since only
// the branch taken ever constructs its temporary. The taken branch's
// destructor runs exactly once, at the end of the full expression,
// while the condition temporary's frame slot is still live - never
// later, against a frame that is already gone.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "confirmed: dmd's CTFE computes the right return value but " ~
        "never runs the destructor of the taken ternary branch's " ~
        "user-constructor temporary - `dtors` stays 0 instead of " ~
        "reaching 1"),
)) {
    @("ternaryBetweenUserCtorTemporariesDestroysTakenBranchOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int* dtors;
                int v;

                this(int* d, int value) {
                    dtors = d;
                    v = value;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }

                int get() {
                    return v;
                }
            }

            void main() {
                int dtors = 0;
                bool c = true;
                int r = (c ? T(&dtors, 1) : T(&dtors, 2)).get();
                assert(dtors == 1);
                assert(r == 1);
            }
        });
    }
}

// A temporary initialized from a compile-time struct value: dmd
// lowers `g.get()`, `g` an enum of a user-constructor type, to
// `((G __slG4 = G(5);) , __slG4).get()` - the same
// declaration-of-a-literal shape its deferred-`__ctor` lowering uses,
// but with no `__ctor` call following, since the literal already is
// the whole value. The destructor still runs once: a constructor call
// that never arrives must not be what the destructor waits for.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "confirmed: dmd's CTFE refuses `gdtors` with \"static variable " ~
        "`gdtors` cannot be read at compile time\" - the enum's " ~
        "construction runs in the compiler's own CTFE session while " ~
        "compiling the snippet, and `main()`'s later, separate " ~
        "`ctfeInterpret` call cannot read a static mutated by a prior " ~
        "session, not even after replacing `__gshared` with a plain " ~
        "static (same error either way)"),
)) {
    @("userCtorTypeTemporaryFromEnumLiteralRunsDestructorOnce." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int gdtors;

            struct G {
                int x;

                this(int y) {
                    x = y;
                }

                ~this() {
                    ++gdtors;
                }

                int get() {
                    return x;
                }
            }

            enum g = G(5);

            void main() {
                int r = g.get();
                assert(gdtors == 1);
                assert(r == 5);
            }
        });
    }
}

// An inner temporary fully constructed, then moved into an outer
// constructor's by-value parameter: dmd's `valueNoDtor` transfers
// ownership to the callee (the argument is not copied, so the caller
// must not also destroy it), and the callee destroys its parameter
// exactly once - here while unwinding its own throw. The outer
// temporary's constructor never returns, so its destructor never runs
// at all.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("temporaryMovedIntoThrowingOuterCtorDestroyedOnceByCallee." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Inner {
                int* dtors;

                this(int* d) {
                    dtors = d;
                }

                ~this() {
                    if (dtors) ++*dtors;
                }
            }

            struct Outer {
                int* dtors;

                this(Inner i, int* d) {
                    dtors = d;
                    throw new Exception("outer");
                }

                ~this() {
                    if (dtors) *dtors += 10;
                }
            }

            void main() {
                int innerDtors = 0;
                int outerDtors = 0;
                bool caught;
                try
                    Outer(Inner(&innerDtors), &outerDtors);
                catch (Exception e)
                    caught = true;
                assert(caught);
                assert(outerDtors == 0);
                assert(innerDtors == 1);
            }
        });
    }
}

// A lambda inside a struct method that reads a field with no explicit
// `this.` reaches it through the enclosing method's own hidden `this` -
// dmd resolves the bare identifier to `this.field` (`hasThis` finds the
// method, not the lambda itself, since the lambda has no `this` of its
// own) and treats that `this` as a variable the lambda captures, the same
// as any other local of the enclosing method.
static foreach (backend; Matrix!()) {
    @("structLambdaReadsFieldThroughEnclosingThis." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Cursor {
                size_t offset;

                size_t readOffset() {
                    auto nested = () => offset;
                    return nested();
                }
            }

            void main() {
                auto cursor = Cursor(7);
                assert(cursor.readOffset() == 7);
            }
        });
    }
}

// As above, for a nested function (not a lambda) that writes a field
// through the same implicit `this` rather than only reading one.
static foreach (backend; Matrix!()) {
    @("structNestedFunctionWritesFieldThroughEnclosingThis." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int total;

                void addTwice(int amount) {
                    void bump() {
                        total += amount;
                    }

                    bump();
                    bump();
                }
            }

            void main() {
                auto counter = Counter(1);
                counter.addTwice(4);
                assert(counter.total == 9);
            }
        });
    }
}

// `new S(a, b)` with no declared constructor writes each argument
// straight into its own field's offset. `a` and `b` are both bitfields
// packed into the same storage byte, so a field-wide write for `b`
// would clobber the bits `a` already wrote there instead of only setting
// `b`'s own bits. `compileNew`'s no-constructor branch now runs the same
// `isSupportedStructLiteral` guard `visit(StructLiteralExp)` already
// uses, so the bytecode compiler refuses this `new` outright rather than
// compile it to that wrong answer. Read back through a raw `ubyte*` on
// the backends that still run it - a bitfield's own read is refused
// elsewhere in every backend, so this checks the packed byte directly
// instead - the two nibbles must both still hold `a`'s 3 and `b`'s 5,
// packed as `0x53` the same way native layout packs them.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "`compileNew` refuses a struct with a bitfield field: " ~
            "`isSupportedStructLiteral` rejects it before the " ~
            "positional-field-init loop can write field-wide over a " ~
            "sibling bitfield's bits"),
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE cannot reinterpret cast `S*` to `ubyte*`"),
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter's own `initializeStructArguments` has the same " ~
            "gap - out of scope here, tracked separately"),
)) {
    @("newStructWithBitfieldSiblingsSurvive." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                ubyte a : 4;
                ubyte b : 4;
            }

            void main() {
                auto s = new S(3, 5);
                ubyte* raw = cast(ubyte*) s;
                assert(*raw == 0x53);
            }
        });
    }
}

// A struct literal can initialize a class-reference field directly from
// a `new` expression - the field is a plain pointer-sized handle to the
// object's own instance, no different from any other field this literal
// writes.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesClassReferenceField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Inner {
                ushort s;
                ubyte b;
                this(ushort s, ubyte b) {
                    this.s = s;
                    this.b = b;
                }
            }

            struct Outer {
                ushort s;
                Inner inner;
                ubyte b;
            }

            void main() {
                auto outer = Outer(2, new Inner(3, 5), 8);
                assert(outer.s == 2);
                assert(outer.inner.s == 3);
                assert(outer.inner.b == 5);
                assert(outer.b == 8);
            }
        });
    }
}

// A struct literal can initialize a `double` field, and a plain field-wide
// copy of the whole struct carries that field's bytes along unchanged - a
// floating-point field needs no postblit, destructor or captured context,
// so it is native bytes exactly like an integral field.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesFloatingField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                double x = 0;
                int tag;
            }

            void main() {
                auto original = Point(3.5, 7);
                auto copy = original;
                assert(copy.x == 3.5);
                assert(copy.tag == 7);
            }
        });
    }
}

// A struct literal can initialize an enum-typed field, and copying the
// struct carries the member's own underlying value along unchanged - an
// enum needs no postblit, destructor or captured context any more than
// its base type does.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesEnumField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Color { red, green, blue }

            struct Paint {
                Color color;
                int tag;
            }

            void main() {
                auto original = Paint(Color.green, 9);
                auto copy = original;
                assert(copy.color == Color.green);
                assert(copy.tag == 9);
            }
        });
    }
}

// A struct literal can initialize a static-array field element by element,
// and copying the struct carries every element's own bytes along
// unchanged - a static array of a plain element type needs no postblit,
// destructor or captured context any more than the element type itself
// does.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesStaticArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Triple {
                int[3] values;
                int tag;
            }

            void main() {
                auto original = Triple([1, 2, 3], 4);
                auto copy = original;
                assert(copy.values == [1, 2, 3]);
                assert(copy.tag == 4);
            }
        });
    }
}

// A struct literal can initialize a delegate-typed field directly from a
// closure, and copying the struct carries the delegate's own `{context,
// function}` pair along unchanged - a delegate needs no postblit,
// destructor or captured context of its own to copy, only to call.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesDelegateField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int delegate() dg;
                int tag;
            }

            void main() {
                int base = 40;
                auto original = Holder(() => base + 2, 5);
                auto copy = original;
                assert(copy.dg() == 42);
                assert(copy.tag == 5);
            }
        });
    }
}

// A struct literal can initialize a function-pointer-typed field directly
// from a module-level function's address, and copying the struct carries
// that address along unchanged - a function pointer is a plain machine
// word with no hook of its own to run.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesFunctionPointerField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int addOne(int value) {
                return value + 1;
            }

            struct Holder {
                int function(int) fn;
                int tag;
            }

            void main() {
                auto original = Holder(&addOne, 6);
                auto copy = original;
                assert(copy.fn(41) == 42);
                assert(copy.tag == 6);
            }
        });
    }
}

// A struct literal can initialize a `real` field, and copying the struct
// carries it along unchanged - a `real` is 16 bytes wide and 16-byte
// aligned on x86-64, so `R`'s layout has padding after `tag` that a plain
// bytewise copy must carry too, unlike any 8-byte-or-narrower field.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesRealField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct R {
                real r = 0;
                int tag;
            }

            void main() {
                auto original = R(3.5L, 7);
                auto copy = original;
                assert(copy.r == 3.5L);
                assert(copy.tag == 7);
                copy.r = 2.25L;
                assert(copy.r == 2.25L);
                assert(original.r == 3.5L);
                R[2] pair = [R(1.0L, 1), R(2.0L, 2)];
                assert(pair[1].r == 2.0L);
                assert(pair[1].tag == 2);
            }
        });
    }
}

// A struct literal can initialize an interface-reference field from a class
// reference - the implicit conversion is a `CastExp` to the interface's own
// vtable slot inside the object, and the field itself is a plain
// pointer-sized handle a bytewise copy shares, exactly like a class
// reference.
static foreach (backend; Matrix!()) {
    @("structLiteralInitializesInterfaceReferenceField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Getter { int get(); }

            class Box: Getter {
                int value;
                this(int value) { this.value = value; }
                int get() { return value; }
            }

            struct Holder {
                Getter getter;
                int tag;
            }

            void main() {
                auto original = Holder(new Box(41), 1);
                auto copy = original;
                assert(copy.getter.get() == 41);
                assert(copy.tag == 1);
            }
        });
    }
}

// A struct wider than one machine word but no wider than two - the same
// `{ pointer, size_t, uint }` shape druntime's own `BlkInfo_` has, padded
// to 24 bytes - can be returned by value from a named function. The call
// destination slot is sized from the return type's own `TypeFacts`, not
// a fixed-width scratch buffer, so the width of the struct does not
// matter.
static foreach (backend; Matrix!()) {
    @("structWithPointerFieldReturnedByValueFromNamedFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                void* base;
                size_t size;
                uint tag;
            }

            Wide makeWide(ref int payload) {
                return Wide(&payload, 3, 4);
            }

            void main() {
                int payload = 7;
                auto w = makeWide(payload);
                assert(*cast(int*) w.base == 7);
                assert(w.size == 3);
                assert(w.tag == 4);
            }
        });
    }
}

// As above, returned from a lambda's own call rather than a named
// function - the same return-width limit applies to every guest callee,
// not just one declared with `function`/`ref`/... syntax.
static foreach (backend; Matrix!()) {
    @("structWithPointerFieldReturnedByValueFromLambda." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                void* base;
                size_t size;
                uint tag;
            }

            void main() {
                int payload = 7;
                auto makeWide = () => Wide(&payload, 3, 4);
                auto w = makeWide();
                assert(*cast(int*) w.base == 7);
                assert(w.size == 3);
                assert(w.tag == 4);
            }
        });
    }
}

// A struct with a class-reference field - one pointer-sized handle, no
// different from any other field a bytewise copy carries - can be
// returned by value the same way a struct with a plain pointer field can.
static foreach (backend; Matrix!()) {
    @("structWithClassFieldReturnedByValueFromNamedFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Inner {
                int value;
                this(int value) { this.value = value; }
            }

            struct Outer {
                ushort tag;
                Inner inner;
                ubyte flag;
            }

            Outer makeOuter() {
                return Outer(2, new Inner(3), 8);
            }

            void main() {
                auto o = makeOuter();
                assert(o.tag == 2);
                assert(o.inner.value == 3);
                assert(o.flag == 8);
            }
        });
    }
}

// A struct literal with a pointer field, written directly as a call
// argument - the callee's own parameter slot holds the same native bytes
// the literal wrote, no different from any other struct-typed argument.
static foreach (backend; Matrix!()) {
    @("structLiteralWithPointerFieldAsCallArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Outer {
                ushort tag;
                int* inner;
                ubyte flag;
            }

            void takesOuter(Outer o) {
                assert(o.tag == 9);
                assert(*o.inner == 1);
                assert(o.flag == 2);
            }

            void main() {
                int value = 1;
                takesOuter(Outer(9, &value, 2));
            }
        });
    }
}

// As above, with a class-reference field instead of a plain pointer.
static foreach (backend; Matrix!()) {
    @("structLiteralWithClassFieldAsCallArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Inner {
                int value;
                this(int value) { this.value = value; }
            }

            struct Outer {
                ushort tag;
                Inner inner;
                ubyte flag;
            }

            void takesOuter(Outer o) {
                assert(o.tag == 9);
                assert(o.inner.value == 1);
                assert(o.flag == 2);
            }

            void main() {
                takesOuter(Outer(9, new Inner(1), 2));
            }
        });
    }
}

// A struct literal with a pointer field, assigned into an already-declared
// local - the assignment's own source is the literal's native bytes, the
// same as any other struct-typed assignment.
static foreach (backend; Matrix!()) {
    @("structLiteralWithPointerFieldAsAssignmentSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Outer {
                ushort tag;
                int* inner;
                ubyte flag;
            }

            void main() {
                int value = 5;
                Outer o;
                o = Outer(3, &value, 7);
                assert(o.tag == 3);
                assert(*o.inner == 5);
                assert(o.flag == 7);
            }
        });
    }
}

// As above, with a class-reference field instead of a plain pointer.
static foreach (backend; Matrix!()) {
    @("structLiteralWithClassFieldAsAssignmentSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Inner {
                int value;
                this(int value) { this.value = value; }
            }

            struct Outer {
                ushort tag;
                Inner inner;
                ubyte flag;
            }

            void main() {
                Outer o;
                o = Outer(3, new Inner(5), 7);
                assert(o.tag == 3);
                assert(o.inner.value == 5);
                assert(o.flag == 7);
            }
        });
    }
}

// A storage-class attribute wrapping a non-variable local declaration
// (`static struct S { ... }`) parses as an `AttribDeclaration` holding the
// `StructDeclaration`, not as a flag on the declaration itself the way
// `static int x;` sets `STC.static_` directly on its own `VarDeclaration`.
// This local struct has no runtime action of its own - the same as one
// declared without `static` - so declaring it must not stop the
// surrounding function from compiling.
static foreach (backend; Matrix!()) {
    @("staticLocalStructDeclarationHasNoRuntimeAction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int useLocalStruct() {
                static struct Holder {
                    int value;
                }

                Holder h = Holder(42);
                return h.value;
            }

            void main() {
                assert(useLocalStruct() == 42);
            }
        });
    }
}

// A struct return is copied straight into the caller's own frame slot,
// which the compiler sizes from the return type, so a struct wider than
// two machine words returns by value the same way a narrower one does.
static foreach (backend; Matrix!()) {
    @("fourWordStructReturnedByValueFromNamedFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                long a;
                long b;
                long c;
                long d;
            }

            Wide makeWide() {
                return Wide(1, 2, 3, 4);
            }

            void main() {
                auto w = makeWide();
                assert(w.a == 1);
                assert(w.b == 2);
                assert(w.c == 3);
                assert(w.d == 4);
            }
        });
    }
}

// As above, from a lambda: the same width rule applies to every guest
// callee whatever syntax declared it.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed), // segfaults
)) {
    @("fourWordStructReturnedByValueFromLambda." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                long a;
                long b;
                long c;
                long d;
            }

            void main() {
                auto make = () => Wide(1, 2, 3, 4);
                auto w = make();
                assert(w.a + w.b + w.c + w.d == 10);
            }
        });
    }
}

// A five-word struct with pointer and class-reference fields returned
// from a method and handed straight to another call as its argument: the
// returned bytes land in the temporary the call site reserved for that
// argument, however wide the struct is.
static foreach (backend; Matrix!()) {
    @("fiveWordStructReturnedFromMethodPassedAsArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Inner {
                int value;
                this(int value) { this.value = value; }
            }

            struct Wide {
                int* p;
                Inner inner;
                long a;
                long b;
                long c;
            }

            struct Factory {
                int payload;
                Wide make() {
                    return Wide(&payload, new Inner(9), 1, 2, 3);
                }
            }

            long sum(Wide w) {
                return *w.p + w.inner.value + w.a + w.b + w.c;
            }

            void main() {
                Factory f = Factory(100);
                assert(sum(f.make()) == 115);
            }
        });
    }
}

// A user attribute and a storage class on one local struct (`@("tag")
// static struct S`) nest one attribute declaration inside another (a
// storage class alone merges into a single one, `@safe static` included);
// the struct underneath still has no runtime action.
static foreach (backend; Matrix!(
    // the interpreter recurses through one attribute wrapper, not two
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("userAttributeOnStaticLocalStructDeclarationHasNoRuntimeAction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int f() {
                @("tag") static struct S { int v; }
                return S(3).v;
            }
            void main() { assert(f() == 3); }
        });
    }
}

// A local of a templated struct type with no initializer of its own reads
// `T.init` (dmd's `TypeStruct.defaultInit`, `typesem.d`), a `VarExp` on a
// `SymbolDeclaration` naming the struct rather than any storage of its
// own. `Widget`'s fields default to non-zero bytes (a non-empty string, a
// non-first enum member, `true`, a non-`'\0'` `char`) - std.format.spec's
// `FormatSpec` has the same shape, whose default read reaches this
// through `to!string`'s own use of it. `isSupportedStructLiteral` (the
// same predicate `visit(StructLiteralExp)` uses for `Widget(a, b)`)
// governs this too, since `defaultInit`'s `VarExp` resolves to the exact
// `StructLiteralExp` dmd would have built from `Widget`'s own field
// defaults.
static foreach (backend; Matrix!()) {
    @("defaultInitializedTemplatedStructReadsAndMutatesNonZeroFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Mode { off, on }

            struct Widget(T) {
                string name = "default";
                Mode mode = Mode.on;
                bool active = true;
                char tag = 'x';
                T value;

                void activate() { active = true; }
            }

            void main() {
                Widget!int widget;
                assert(widget.name == "default");
                assert(widget.mode == Mode.on);
                assert(widget.active == true);
                assert(widget.tag == 'x');
                assert(widget.value == 0);

                widget.tag = 'y';
                widget.mode = Mode.off;
                assert(widget.tag == 'y');
                assert(widget.mode == Mode.off);
            }
        });
    }
}

// Pins `to!string` on a plain `int`, so a future change to either it or
// `FormatSpec!char`'s own default read (this module's
// `defaultInitializedTemplated...` test above) has a direct regression
// test for the common case `std.conv.to` exists for.
static foreach (backend; Matrix!()) {
    @("toStringOnInt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.conv: to;

            void main() {
                assert(to!string(42) == "42");
            }
        });
    }
}

// A local with no initializer of a struct whose `.init` is not all zero
// bytes and which has a static-array field: dmd's `defaultInitLiteral`
// (`typesem.d`) builds the struct's `StructLiteralExp` with, for the
// `int[3]` field, a *sparse* `ArrayLiteralExp` - every entry `null`, the
// one shared fill value held in `basis` (`TypeSArray.defaultInitLiteral`).
// The language semantics are just `Outer.init`: `xs` all zero, `b == 7`.
static foreach (backend; Matrix!()) {
    @("defaultInitializedNonZeroInitStructWithStaticArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Outer { int[3] xs; int b = 7; }

            void main() {
                Outer d;
                assert(d.xs[0] == 0);
                assert(d.xs[2] == 0);
                assert(d.b == 7);
            }
        });
    }
}

// A struct literal that leaves out a static-array field whose element
// struct has a non-zero `.init`: every element of `inners` is
// `Inner.init`, so `x == 5` in all three. dmd's `fill` (`expressionsem.d`,
// issue 12509) supplies the *element* type's literal `Inner(5)` for the
// whole `Inner[3]` field, one value that every element takes, rather than
// an array literal of three.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("structLiteralOmitsStaticArrayOfNonZeroInitStructField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Inner { int x = 5; }
            struct Outer { int a; Inner[3] inners; }

            void main() {
                auto o = Outer(1);
                assert(o.a == 1);
                assert(o.inners[0].x == 5);
                assert(o.inners[1].x == 5);
                assert(o.inners[2].x == 5);
            }
        });
    }
}
