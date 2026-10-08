module ut.backends.run.enums;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `with` on an enum type brings its members into scope, so they resolve
// unqualified.
static foreach (backend; Matrix!()) {
    @("withStatementScopesEnumMembers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Mode {
                off = 2,
                on = 5,
            }

            int selectedTotal(int seed) {
                int total = seed;

                with (Mode) {
                    total += cast(int) on;
                    total += cast(int) off;
                }

                return total;
            }

            void main() {
                assert(selectedTotal(3) == 10);
            }
        });
    }
}


// An enum declared inside a function body has no run-time effect of its
// own: semantic analysis has already resolved its members to constants,
// so casting bytes to the enum type and comparing against its members
// exercises only that folding, not the declaration statement.
static foreach (backend; Matrix!()) {
    @("localEnumDeclarationIsANoOp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                enum Direction : ubyte {
                    north = 0,
                    south = 1,
                }

                ubyte[] raw = [0, 1];
                size_t index;

                Direction first = cast(Direction) raw[index++];
                Direction second = cast(Direction) raw[index++];

                assert(first == Direction.north);
                assert(second == Direction.south);
            }
        });
    }
}

// `to!string` on a two-member enum: `toImpl`'s `enumRep` static holds
// only one member name at a time - `off`'s member index is `0`, the
// smallest a `final switch` in `toStr` can pick, unlike the three-member
// enum `toStringOnEnum` (`structs.d`) pins.
static foreach (backend; Matrix!()) {
    @("toStringOnTwoMemberEnum." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.conv: to;

            enum Setting { off, on }

            void main() {
                assert(to!string(Setting.off) == "off");
                assert(to!string(Setting.on) == "on");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfStaticArray.indexing." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Bytes : ubyte[3] {
                a = [9, 9, 9],
            }

            void main() {
                ubyte[3] raw = [1, 2, 3];
                Bytes value = cast(Bytes) raw;
                assert(value[0] == 1);
                assert(value[1] == 2);
                assert(value[2] == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfDynamicArray.lengthAndIndexing." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Greeting : string {
                a = "xx",
            }

            int[] vals() { return [1, 2]; }

            int[] materialize() {
                enum a = vals();
                auto b = a;
                assert(b[1] == 2);
                b[0] = 9;
                auto c = a;
                assert(c[0] == 1);
                return b;
            }

            void main() {
                string raw = "hi";
                Greeting value = cast(Greeting) raw;
                assert(value.length == 2);
                assert(value[0] == 'h');
                assert(value[1] == 'i');

                auto first = materialize();
                auto second = materialize();
                second[1] = 8;
                assert(first[0] == 9 && first[1] == 2);
                enum folded = ([3, 4] ~ [5])[1 .. 3];
                auto copy = folded;
                assert(copy == [4, 5]);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret the address of a local variable at "
            ~ "compile time"),
)) {
    @("enumOfPointer.indexing." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[3] data = [10, 20, 30];
                enum Ptr : int* { z = null }
                Ptr p = cast(Ptr) data.ptr;
                assert(p[0] == 10);
                assert(p[1] == 20);
                assert(p[2] == 30);
            }
        });
    }
}

// dmd encodes a pointer built from an integer constant as an
// `IntegerExp`, the same as an integral value.
static foreach (backend; Matrix!()) {
    @("enumOfPointer.fromIntegerLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (cast(size_t) 8).shouldBeRetOf!(
            backend,
            q{
                size_t identity() {
                    enum EAddr : size_t* { z = null }
                    EAddr value = cast(EAddr) cast(size_t*) 8;
                    return cast(size_t) value;
                }
            },
            "identity",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfStruct.methodCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int value;
                    int read() { return value; }
                    void increment() { value++; }
                }
                enum ECounter : Counter { a = Counter(10) }

                int callMethod() {
                    ECounter c = ECounter.a;
                    c.increment();
                    return c.read();
                }
            },
            "callMethod",
        );
    }
}

// The delegate is built field by field: taking a bound method's
// address (`&counter.read`) is a separate construct.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("enumOfDelegate.indirectCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int value;
                    int read() { return value; }
                }
                enum ECallback : int delegate() { z = null }

                int callThroughEnumDelegate() {
                    Counter counter = Counter(42);
                    int delegate() plain;
                    plain.funcptr = &Counter.read;
                    plain.ptr = &counter;
                    ECallback cb = cast(ECallback) plain;
                    return cb();
                }
            },
            "callThroughEnumDelegate",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret the address of a local variable at "
            ~ "compile time"),
)) {
    @("enumOfPointer.dereference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair { int x; int y; }
            enum P : int* { z = null }
            enum PairP : Pair* { z = null }

            void main() {
                int[3] data = [10, 20, 30];
                P p = cast(P) data.ptr;
                assert(*p == 10);
                *p = 11;
                assert(data[0] == 11);

                Pair pair = Pair(1, 2);
                PairP pp = cast(PairP) &pair;
                assert((*pp).y == 2);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret the address of a local variable at "
            ~ "compile time"),
)) {
    @("enumOfPointer.arithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum P : int* { z = null }

            void main() {
                int[4] data = [10, 20, 30, 40];
                P p = cast(P) data.ptr;
                P q = cast(P) (p + 2);
                assert(*q == 30);
                assert(q - p == 2);
                assert(*(q - 1) == 20);
                assert(p < q);
                p += 3;
                assert(*p == 40);
                p -= 2;
                assert(*p == 20);
            }
        });
    }
}

// `++`/`--` on an enum of a pointer, prefix or postfix, move by the
// pointee size, the same as a plain pointer - `enum P : int*` moves by
// `int.sizeof`. dmd's own AST scales a prefix step (rewritten as `p +=
// 1`/`p -= 1`) but not a postfix one, so `dmd -run` moves a postfix step
// by one byte instead; that is a dmd bug, not D semantics (`ldc2 -run`
// scales it). The sibling test below pins dmd's actual, unscaled result.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret the address of a local variable at "
            ~ "compile time"),
    Omit!(Native, Because.diverges,
        "dmd does not scale ++/-- on an enum of a pointer; ldc does"),
)) {
    @("enumOfPointer.incrementDecrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum P : int* { z = null }

            void main() {
                int[4] data = [10, 20, 30, 40];
                P p = cast(P) data.ptr;
                P before = p++;
                assert(before == data.ptr);
                assert(cast(size_t) p - cast(size_t) data.ptr
                    == int.sizeof);
                --p;
                assert(cast(size_t) p == cast(size_t) data.ptr);
                P after = p--;
                assert(after == data.ptr);
                assert(cast(size_t) data.ptr - cast(size_t) p
                    == int.sizeof);
                ++p;
                assert(cast(size_t) p == cast(size_t) data.ptr);
            }
        });
    }
}

// Sibling pinning the divergence above: `dmd -run` itself, real
// compiled D, moves a postfix `++`/`--` on an enum of a pointer by one
// byte, because its AST never scales that step for an enum.
@("enumOfPointer.incrementDecrement.Native")
@Tags(Native.stringof)
unittest {
    0.shouldBeStatusOf!(Native, q{
        enum P : int* { z = null }

        void main() {
            int[4] data = [10, 20, 30, 40];
            P p = cast(P) data.ptr;
            P before = p++;
            assert(before == data.ptr);
            assert(cast(size_t) p - cast(size_t) data.ptr == 1);
            --p;
            assert(cast(size_t) data.ptr - cast(size_t) p == 3);
        }
    });
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret the address of a local variable at "
            ~ "compile time"),
)) {
    @("enumOfPointer.slicing." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum P : int* { z = null }

            void main() {
                int[4] data = [10, 20, 30, 40];
                P p = cast(P) data.ptr;
                int[] middle = p[1 .. 3];
                assert(middle.length == 2);
                assert(middle[0] == 20);
                assert(middle[1] == 30);
            }
        });
    }
}

// Arithmetic on an enum of a floating type has the enum type itself.
static foreach (backend; Matrix!()) {
    @("enumOfFloating.arithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum F : double { a = 1.5, b = 2.0 }
            enum G : float { a = 0.25f, b = 4.0f }

            void main() {
                F f = F.a;
                F sum = f + F.b;
                assert(cast(double) sum == 3.5);
                F negated = -f;
                assert(cast(double) negated == -1.5);
                G product = G.a * G.b;
                assert(cast(float) product == 1.0f);
                G negatedFloat = -G.b;
                assert(cast(float) negatedFloat == -4.0f);
                assert(F.a < F.b);
                assert(!(F.b < F.a));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfFloating.assignmentOperators." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum F : double { a = 1.5, b = 2.0 }
            enum G : float { a = 0.25f }

            void main() {
                F f = F.a;
                f += F.b;
                assert(cast(double) f == 3.5);
                f *= 2;
                assert(cast(double) f == 7.0);
                f++;
                assert(cast(double) f == 8.0);
                --f;
                assert(cast(double) f == 7.0);
                G g = G.a;
                g++;
                assert(cast(float) g == 1.25f);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a class reference to an enum of that class"),
)) {
    @("enumOfClass.fieldsAndMethods." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Counter {
                int value = 7;
                int read() { return value; }
            }
            class Doubling : Counter {
                override int read() { return 2 * value; }
            }
            enum ECounter : Counter { z = null }

            void main() {
                ECounter doubling = cast(ECounter) new Doubling;
                assert(doubling.read() == 14);

                ECounter counter = cast(ECounter) new Counter;
                assert(counter.value == 7);
                counter.value = 8;
                assert(counter.read() == 8);
                assert(counter);
                Object upcast = counter;
                assert((cast(Counter) upcast).value == 8);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a class reference to an enum of that class"),
)) {
    @("enumOfClass.typeidIsDynamic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {}
            class Derived : Base {}
            enum EBase : Base { z = null }

            void main() {
                EBase value = cast(EBase) new Derived;
                assert(typeid(value) is typeid(Derived));
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not match a catch of an enum of a class, and "
            ~ "casts a class reference to an enum of it to null"),
)) {
    @("enumOfClass.throwAndCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Failure : Exception {
                this() { super("failure"); }
            }
            enum EFailure : Failure { z = null }

            void main() {
                bool caught;
                try
                    throw cast(EFailure) new Failure;
                catch (Failure failure)
                    caught = failure.msg == "failure";
                assert(caught);

                bool caughtAsEnum;
                try
                    throw new Failure;
                catch (EFailure failure)
                    caughtAsEnum = failure.msg == "failure";
                assert(caughtAsEnum);
            }
        });
    }
}

// A cast to an enum of the class repaints the `new` expression's own
// type; the constructor still runs.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a class reference to an enum of that class"),
)) {
    @("enumOfClass.newRunsTheConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Failure : Exception {
                this() { super("failure"); }
            }
            enum EFailure : Failure { z = null }

            void main() {
                EFailure failure = cast(EFailure) new Failure;
                assert(failure.msg == "failure");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("newOfEnum." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair { int x = 4; int y = 5; }
            enum EPair : Pair { a = Pair(1, 2) }
            enum Small : int { a = 3 }
            enum P : int* { z = null }

            void main() {
                EPair* built = new EPair(3, 4);
                assert(built.x == 3);
                assert(built.y == 4);
                EPair* defaulted = new EPair;
                assert(defaulted.x == 4);
                assert(defaulted.y == 5);
                Small* small = new Small(Small.a);
                assert(*small == Small.a);
                P pointer = cast(P) new int(9);
                assert(*pointer == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfStaticArray.valueSemantics." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Triple : int[3] { a = [1, 2, 3] }
            int one() { return 1; }
            int two() { return 2; }
            enum Functions : int function()[2] { a = [&one, &two] }

            Triple make() { return Triple.a; }
            int sum(Triple value) {
                int total;
                foreach (element; value)
                    total += element;
                return total;
            }

            void main() {
                Triple value = make();
                assert(value[2] == 3);
                assert(sum(value) == 6);
                assert(value == Triple.a);
                int[] head = value[0 .. 2];
                assert(head.length == 2);
                assert(head[1] == 2);
                Functions functions = Functions.a;
                assert(functions[1]() == 2);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine asserts on a slice assignment to an enum of "
            ~ "a static array"),
)) {
    @("enumOfStaticArray.sliceAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Triple : int[3] { a = [1, 2, 3] }

            void main() {
                Triple value = Triple.a;
                value[] = 5;
                assert(value[0] == 5);
                assert(value[2] == 5);
                int[3] source = [7, 8, 9];
                value[] = source[];
                assert(value[1] == 8);
                value[1 .. 3] = 4;
                assert(value[0] == 7);
                assert(value[2] == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfStruct.literalWithAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int one() { return 1; }
            struct Callback { int function() get; double weight; }
            enum ECallback : Callback { a = Callback(&one, 2.0) }

            void main() {
                ECallback callback = ECallback.a;
                assert(callback.get() == 1);
                assert(callback.weight == 2.0);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfFunctionPointer.literalAndAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Getter : int function() { a = () => 7 }
            int eight() { return 8; }

            void main() {
                Getter literal = Getter.a;
                assert(literal() == 7);
                Getter named = cast(Getter) &eight;
                assert(named() == 8);
                assert(named);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("enumOfDelegate.literal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Getter : int delegate() { a = delegate() => 9 }

            void main() {
                Getter literal = Getter.a;
                assert(literal() == 9);
            }
        });
    }
}

// dmd compares an enum of `double` with a `double` literal as `creal`.
static foreach (backend; Matrix!()) {
    @("enumOfFloating.equalityPromotesToComplex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum F : double { a = 1.5 }

            void main() {
                F f = F.a;
                assert(-f == -1.5);
                assert(f != 2.5);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot compare vectors"),
)) {
    @("enumOfVector.comparison." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.simd: int4;
            enum Lanes : int4 { z = int4.init }

            void main() {
                int4 raw = [1, 2, 3, 4];
                Lanes lanes = cast(Lanes) raw;
                int4 other = [1, 0, 3, 0];
                int4 equal = lanes == other;
                assert(equal.array == [-1, 0, -1, 0]);
            }
        });
    }
}


// An enum is its base type everywhere a value is read: a pointer-based
// enum dereferences, indexes and binds a `ref` parameter through `*p`
// like the pointer itself.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take the address of a local variable"),
)) {
    @("enumOfPointer.dereferencedAndBoundToRefParameter."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum P : int* { none = null }

            void setNine(ref int x) { x = 9; }
            int read(P p) { return *p; }

            void main() {
                int x = 4;
                P p = cast(P) &x;
                assert(read(p) == 4);
                setNine(*p);
                assert(p[0] == 9);
                *p = 11;
                assert(x == 11);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take the address of a local variable"),
)) {
    @("enumOfPointer.passedByRefAndOut." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum P : int* { none = null }

            void reset(ref P p) { p = P.none; }
            void clear(out P p) {}

            void main() {
                int x = 4;
                P p = cast(P) &x;
                reset(p);
                assert(p is P.none);
                p = cast(P) &x;
                clear(p);
                assert(p is P.none);
            }
        });
    }
}

// A function pointer or delegate behind an enum is called through its
// base type.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call a function that has no D source"),
)) {
    @("enumOfFunctionPointer.calledThroughEnum." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdlib: abs;
            alias F = int function(int);
            enum EF : F { none = null }

            void main() {
                EF e = cast(EF) cast(F) &abs;
                assert(e(-3) == 3);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take a delegate to a method of a native class"),
)) {
    @("enumOfDelegate.calledThroughEnum." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            alias D = string delegate();
            enum ED : D { none = null }

            void main() {
                Object o = new Object;
                D dg = &o.toString;
                ED e = cast(ED) dg;
                assert(e() == "object.Object");
            }
        });
    }
}
