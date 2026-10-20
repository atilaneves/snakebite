module ut.backends.call.ref_;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// The simplest `ref` round trip: the callee mutates the parameter twice,
// and both mutations land on the caller's own local, not a copy of it.
static foreach (backend; Matrix!()) {
    @("ref.param.mutatedByCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                void inc(ref int x) {
                    ++x;
                }

                int kindaMain() {
                    int a = 1;
                    inc(a);
                    inc(a);
                    return a;
                }
            },
            "kindaMain",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ref.param.postincrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(backend, q{
            void increment(ref int value) { value++; }
            int kindaMain() {
                int value = 1;
                increment(value);
                return value;
            }
        }, "kindaMain");
    }
}

// An `out` parameter starts as default-initialized caller storage. The
// callee then writes that same storage, rather than a temporary parameter
// slot, so the caller observes the result after the call.
static foreach (backend; Matrix!()) {
    @("out.param.initializesCallerStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            void set(out int value) {
                value = 42;
            }

            int main() {
                int value;
                set(value);
                return value;
            }
        }, "main");
    }
}

// A `lazy` parameter is a delegate in the native ABI. Its expression runs
// in the caller when the callee reads the parameter, not when the call is
// bound.
static foreach (backend; Matrix!()) {
    @("lazy.param.evaluatesAtRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        22.shouldBeRetOf!(backend, q{
            int read(lazy int value, ref int evaluations) {
                ++evaluations;
                return value;
            }

            int kindaMain() {
                int evaluations;
                return read(++evaluations, evaluations) * 10 + evaluations;
            }
        }, "kindaMain");
    }
}

static foreach (backend; Matrix!()) {
    @("lazy.param.evaluatesForEachRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        122.shouldBeRetOf!(backend, q{
            int kindaMain() {
                int evaluations;
                int readTwice(lazy int value) {
                    return value * 10 + value;
                }

                return readTwice(++evaluations) * 10 + evaluations;
            }
        }, "kindaMain");
    }
}

// A `ref` parameter forwarded into a nested call: `bump`'s own `x` is
// itself `ref`, and passing it on to `inc` must reach the same storage as
// the outer local, not a second indirection through `bump`'s frame.
static foreach (backend; Matrix!()) {
    @("ref.param.passesThroughNestedCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                void inc(ref int x) {
                    ++x;
                }

                void bump(ref int x) {
                    inc(x);
                }

                int kindaMain() {
                    int a = 1;
                    bump(a);
                    bump(a);
                    return a;
                }
            },
            "kindaMain",
        );
    }
}

// A `ref` return is an lvalue: assigning through the call itself changes
// whichever of the two arguments it picked, and the caller's own local -
// not a copy the call handed back - is what changed.
static foreach (backend; Matrix!()) {
    @("ref.return.assignableThroughCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                ref int pick(ref int a, ref int b, bool first) {
                    return first ? a : b;
                }

                int kindaMain() {
                    int a = 1;
                    int b = 2;
                    pick(a, b, true) = 5;
                    return a;
                }
            },
            "kindaMain",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ref.return.readAsValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(backend, q{
            ref int pick(ref int value) { return value; }
            int kindaMain() { int value = 2; return pick(value); }
        }, "kindaMain");
    }
}

// `writeln` initializes a scoped `File` temporary from the native
// `trustedStdout` value before it writes. This is the public library path
// used by the rt-simple runner's final summary.
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot write to native stdout"))) {
    @("temporary.nativeAggregateFeedsCommaLvalue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        import std.stdio: writeln;

        void main() {
            size_t total = 23;
            size_t failed;
            writeln(total, " test(s) run, ", failed, " failed.");
        }
        });
    }
}

// Taking the address of a ref-returning call must evaluate the call once and
// keep the returned alias, not a copy of its value.
static foreach (backend; Matrix!(    Omit!(Ctfe, Because.unconfirmed))) {
    @("ref.return.addressEvaluatedOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
    17.shouldBeRetOf!(
        backend,
        q{
            int calls;
            int value;

            ref int cell() {
                ++calls;
                return value;
            }

            int takeAddress() {
                int* address = &cell();
                *address = 7;
                return calls * 10 + value;
            }
        },
        "takeAddress",
    );
    }
}

// `static` storage lives outside any frame, so a `ref` parameter bound to
// it exercises the one address `slotOf` cannot reach through the frame -
// `FrameLayout.offsetOf` never reserved it a slot to indirect through in
// the first place.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE interpreter refuses to take the address of a " ~
        "thread-local variable at compile time"),
)) {
    @("ref.param.boundToStatic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                void bumpBy(ref int x, int amount) {
                    x += amount;
                }

                int bump() {
                    static int count = 1;
                    bumpBy(count, 4);
                    return count;
                }
            },
            "bump",
        );
    }
}

// A `ref` parameter of a slice type: the callee overwrites both words of
// the caller's slice - its length and its pointer - through the
// reference, not just the bytes the slice currently points at. Built out
// of string literals and a whole-slice assignment, the only slice
// operations the interpreter supports today; `ArrayLiteralExp` and
// `CatAssignExp` are out of scope here.
static foreach (backend; Matrix!()) {
    @("ref.param.wholeSliceThroughReference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                void setGreeting(ref string s, string value) {
                    s = value;
                }

                size_t useSlice() {
                    string greeting = "hi";
                    setGreeting(greeting, "hello");
                    return greeting.length;
                }
            },
            "useSlice",
        );
    }
}

// `Backend.call` is the host entry point, not a guest `CallExp`. A
// `ref`-returning callee hands the host the result's own address, the
// same word compiled D returns in `rax` - not its value - so
// `returnPlace` here is pointer-sized, not `int`-sized. The host writes
// through that address, and a second call proves the write landed on
// the guest's own storage: `probeCell` reads it back changed, not a
// copy of the address it handed out the first time (issue #367).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot give the host the address of guest storage"),
)) {
    @("ref.return.hostCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            static int cell;
            ref int probeCell() {
                return cell;
            }

            int* address = &probeCell();
            *address = 9;
            probeCell().should == 9;
        } else {
            auto module_ = parseSnippet(q{
                ref int probeCell() {
                    static int cell;
                    return cell;
                }
            });
            auto function_ = findFunction(module_, "probeCell");
            auto instance = Owned!backend(Program([module_]));

            int* address;
            instance.call(function_, &address, []);
            *address = 9;

            // The callee's return type never changes between two calls,
            // so the second call hands back an address too, exactly like
            // the first - there is no separate value-returning mode a
            // caller can ask for instead.
            int* secondAddress;
            instance.call(function_, &secondAddress, []);
            (*secondAddress).should == 9;
        }
    }
}

// A call through a function pointer to a function that returns `ref` gives
// the caller's own storage: a write through the call lands there.
static foreach (backend; Matrix!()) {
    @("ref.return.throughFunctionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        14.shouldBeRetOf!(backend, q{
            ref int cell(ref int[2] pair) { return pair[1]; }

            int kindaMain() {
                int[2] pair;
                auto get = &cell;
                get(pair) = 5;
                get(pair) += 2;
                return pair[1] + get(pair);
            }
        }, "kindaMain");
    }
}

// A dynamic array that a call returns by `ref` is read as a value, and is
// the caller's own variable.
static foreach (backend; Matrix!()) {
    @("ref.return.sliceReadAsValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        22.shouldBeRetOf!(backend, q{
            struct Box { int[] items; }

            ref int[] items(ref Box box) { return box.items; }

            int kindaMain() {
                Box box;
                box.items = [1, 2];
                int[] before = items(box);
                items(box) = [3];
                return cast(int) (before.length * 10 + items(box)[0] - 1);
            }
        }, "kindaMain");
    }
}

// A struct that a call returns by `ref` is copied when it is read as a
// value: a later write through the call does not change the copy.
static foreach (backend; Matrix!()) {
    @("ref.return.structCopiedAsValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        39.shouldBeRetOf!(backend, q{
            struct Point { int x; int y; }

            ref Point first(ref Point[2] points) { return points[0]; }

            int kindaMain() {
                Point[2] points;
                points[0] = Point(3, 4);
                Point copy = first(points);
                first(points).x = 9;
                return copy.x * 10 + first(points).x;
            }
        }, "kindaMain");
    }
}

// A delegate that a call returns by `ref` is read, then called.
static foreach (backend; Matrix!()) {
    @("ref.return.delegateCalled." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(backend, q{
            struct Counter {
                int count;
                int next() { return ++count; }
            }

            struct Holder { int delegate() action; }

            ref int delegate() action(ref Holder holder) {
                return holder.action;
            }

            int kindaMain() {
                Counter counter;
                Holder holder;
                holder.action = &counter.next;
                action(holder)();
                action(holder)();
                return action(holder)() * 2;
            }
        }, "kindaMain");
    }
}
