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

// An enum whose base type is a static array has the array's own layout -
// indexing it must read through the base type, not stop at the enum's own
// kind. `frontend.storage`'s index resolver used to test the index target's
// raw `.ty` against `Tsarray`, which an enum's own `.ty` (`Tenum`) never
// matches. `frontend.storage` is shared, but `Interpreter`'s and
// `Bytecode`'s own downstream handling of an enum-of-static-array index
// target (`walker.d`/`compiler.d`) is not yet fixed - both crash the host
// process outright, out of this PR's scope.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "crashes: walker.d's own index handling is not yet fixed for an "
            ~ "enum-of-static-array target (issue #441, walker.d part)"),
    Omit!(Bytecode, Because.unconfirmed,
        "crashes: compiler.d's own index handling is not yet fixed for "
            ~ "an enum-of-static-array target (issue #441, compiler.d "
            ~ "part)"),
)) {
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

// An enum whose base type is a dynamic array (here `string`) has the
// array's own two-word layout - `.length` and indexing must read through
// the base type. `frontend.storage`'s `.length` and index resolvers used to
// test the raw `.ty` against `Tarray`, missing an enum base the same way.
// As with the static-array case above, `Interpreter`'s and `Bytecode`'s
// own downstream handling (`walker.d`/`compiler.d`) is not yet fixed and
// crashes the host process, out of this PR's scope.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "crashes: walker.d's own index/length handling is not yet fixed "
            ~ "for an enum-of-dynamic-array target (issue #441, walker.d "
            ~ "part)"),
    Omit!(Bytecode, Because.unconfirmed,
        "crashes: compiler.d's own index/length handling is not yet "
            ~ "fixed for an enum-of-dynamic-array target (issue #441, "
            ~ "compiler.d part)"),
)) {
    @("enumOfDynamicArray.lengthAndIndexing." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Greeting : string {
                a = "xx",
            }

            void main() {
                string raw = "hi";
                Greeting value = cast(Greeting) raw;
                assert(value.length == 2);
                assert(value[0] == 'h');
                assert(value[1] == 'i');
            }
        });
    }
}

// An enum whose base type is a pointer indexes exactly like the pointer
// itself. `frontend.storage`'s index resolver used to test the raw `.ty`
// against `Tpointer`, missing an enum base the same way as the array cases
// above. `Interpreter`'s and `Bytecode`'s own downstream handling
// (`walker.d`/`compiler.d`) is not yet fixed and crashes the host process,
// out of this PR's scope; CTFE cannot take the address of a local variable
// at compile time at all, regardless of enum normalisation.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret the address of a local variable at "
            ~ "compile time"),
    Omit!(Interpreter, Because.unconfirmed,
        "crashes: walker.d's own index handling is not yet fixed for an "
            ~ "enum-of-pointer target (issue #441, walker.d part)"),
    Omit!(Bytecode, Because.unconfirmed,
        "crashes: compiler.d's own index handling is not yet fixed for "
            ~ "an enum-of-pointer target (issue #441, compiler.d part)"),
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

// DMD represents a pointer value built from an integer constant (a
// fabricated, never-dereferenced address, so no backend needs to read
// real memory through it) as a plain `IntegerExp`, the same encoding an
// integral value gets. `nativelayout.storeValue`'s int-to-pointer fast
// path used to run before its own `toBasetype` normalisation, so
// initialising an enum-of-pointer local from one fell through to the
// trailing "no native layout" throw instead. `Bytecode`'s own downstream
// handling (`compiler.d`) is not yet fixed and crashes the host process,
// out of this PR's scope.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "crashes: compiler.d's own handling is not yet fixed for an "
            ~ "enum-of-pointer local initialised from an integer literal "
            ~ "(issue #441, compiler.d part)"),
)) {
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

// An enum whose base type is a struct has the struct's own layout and
// members - calling one of the base struct's methods on it must read and
// write through the base type's own fields, the same way a plain struct
// value would. This is a regression-locking test, not a red/green one: a
// direct method call like this one resolves `expression.f` during
// semantic analysis and never reaches `frontend.dmd.delegates.
// delegateTargetOf`'s own receiver-type check, so it already passed
// before that function's fix. The one guest construct that does reach
// `delegateTargetOf` - taking a bound method's address, `&receiver.
// method` - is itself unsupported by both `Interpreter` and `Bytecode`
// today, regardless of enum normalisation, so that fix has no test of
// its own here; it is still correct by the same reasoning as the other
// sites in this file, and matches `isIndirectDelegateCall`'s own
// idiom (`enumOfDelegate.indirectCall` below).
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

// An enum whose base type is a delegate calls exactly like the delegate
// itself. `backends.calls.isIndirectDelegateCall` and `frontend.dmd.
// functions.typeFunctionOf` both used to test the callee's raw `.ty`
// against `Tdelegate`, missing an enum base the same way. The delegate
// itself is built field by field (`.funcptr`/`.ptr`), the same idiom
// `assignDelegateFieldsBeforeNestedCall` (`delegates.d`) uses - taking a
// bound method's address directly (`&counter.read`) is a separate, already
// unsupported construct on both `Interpreter` and `Bytecode`, nothing to
// do with type normalisation.
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
