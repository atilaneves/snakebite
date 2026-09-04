module ut.backends.call.pointers;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.ffi: boolFunctionEntryCount;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;


private alias BoolCallback = extern(D) bool function();


public extern(C) bool snakebite_ut_call_bool_callback(
    BoolCallback callback,
) {
    return callback();
}


public extern(C) bool snakebite_ut_same_bool_callback(
    BoolCallback first,
    BoolCallback second,
) {
    return first == second;
}


public extern(C) bool snakebite_ut_is_null_object(Object object_)
{
    return object_ is null;
}


public extern(C) bool snakebite_ut_collect_then_call_bool_callback(
    BoolCallback callback,
) {
    import core.memory: GC;

    GC.collect;
    return callback();
}


public extern(C) string snakebite_ut_call_bool_callback_on_thread(
    BoolCallback callback,
) {
    import core.thread: Thread;

    string message;
    auto thread = new Thread({
        try
            callback();
        catch (Throwable throwable)
            message = throwable.msg;
    });
    thread.start;
    thread.join;
    return message;
}


private enum hostCallbackDeclarations = q{
    module ut.backends.call.pointers;

    alias BoolCallback = extern(D) bool function();

    extern(C) bool snakebite_ut_call_bool_callback(BoolCallback);
    extern(C) bool snakebite_ut_same_bool_callback(
        BoolCallback, BoolCallback,
    );
    extern(C) bool snakebite_ut_collect_then_call_bool_callback(
        BoolCallback,
    );
    extern(C) string snakebite_ut_call_bool_callback_on_thread(
        BoolCallback,
    );
};


private enum boolCallbackCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_call_bool_callback,
        snakebite_ut_collect_then_call_bool_callback,
        snakebite_ut_same_bool_callback;

    static bool yes() {
        return true;
    }

    static bool no() {
        return false;
    }

    int answer() {
        assert(snakebite_ut_call_bool_callback(&yes));
        assert(!snakebite_ut_call_bool_callback(&no));
        assert(snakebite_ut_call_bool_callback(() => true));
        assert(snakebite_ut_same_bool_callback(&yes, &yes));
        assert(!snakebite_ut_same_bool_callback(&yes, &no));

        int[] values = [17, 31, 47];
        assert(snakebite_ut_collect_then_call_bool_callback(&yes));
        return values[0] + values[1] + values[2];
    }
};


private enum boolCallbackExceptionCode = q{
    import ut.backends.call.pointers: snakebite_ut_call_bool_callback;

    static int zero() {
        return 0;
    }

    static bool fail() {
        assert(zero());
        return false;
    }

    int answer() {
        snakebite_ut_call_bool_callback(&fail);
        return 0;
    }
};


// `&b` is dmd's `SymOffExp`, not a general `&expression`: taking a local's
// address and reading back through it is the simplest lvalue-to-pointer
// round trip there is.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("pointers.addressOf.read." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int deref() {
                    int b = 3;
                    int* p = &b;
                    return *p;
                }
            },
            "deref",
        );
    }
}


// Subtracting pointers gives the distance in elements, not bytes.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "bytecode cannot evaluate pointer subtraction"),
)) {
    @("pointers.dynamicArray.pointerDifference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2L.shouldBeRetOf!(
            backend,
            q{
                long distance() {
                    ubyte[] arr = [1, 2, 3];
                    auto start = arr.ptr;
                    auto end = start + 2;
                    return end - start;
                }
            },
            "distance",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
    Omit!(Interpreter, Because.unconfirmed,
        "pragma(mangle) native declarations are not routed through FFI"),
)) {
    @("pointers.null.classArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_is_null_object")
                extern(C) bool nativeIsNullObject(Object);

                int isNull() {
                    return nativeIsNullObject(null);
                }
            },
            "isNull",
        );
    }
}


// A plain function pointer has no context word. When host code calls it, its
// code address alone must select the right guest function. Calling two
// functions proves the address does not select one process-global target;
// comparing a repeated conversion proves one guest function keeps one native
// identity. The collection happens while the outer guest frame holds the only
// remaining pointer to `values`, so reading the array afterward also proves
// that re-entry does not hide that frame from the collector.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.functionPointer.boolCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native))
            95.shouldBeRetOf!(backend, boolCallbackCode, "answer");
        else {
            auto modules = parseSnippets([
                "module bool_callback_root;\n" ~ boolCallbackCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == 95;
        }
    }
}


// A guest throw remains a guest throw while it crosses the compiled helper's
// frame. `Backend.call` sees the original `AssertError`, not an FFI error or
// an interpreter implementation exception.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.functionPointer.boolCallback.exception." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.exception: AssertError;

        AssertError caught;
        static if (is(backend == Native)) {
            mixin(boolCallbackExceptionCode);
            try
                answer();
            catch (AssertError error)
                caught = error;
        } else {
            auto modules = parseSnippets([
                "module bool_callback_exception_root;\n"
                    ~ boolCallbackExceptionCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            try
                backend_.call(function_, &result, []);
            catch (AssertError error)
                caught = error;
        }

        (caught !is null).should == true;
    }
}


// Worker-thread execution is owned by issue #40. The callback rejects the
// worker before it reads or writes the evaluator that its creator thread
// owns, so an unsupported call is a diagnostic instead of a data race.
@("pointers.functionPointer.boolCallback.wrongThread.Interpreter")
@Tags("Interpreter")
unittest {
    auto modules = parseSnippets([
        q{
            module bool_callback_thread_root;
            import ut.backends.call.pointers:
                snakebite_ut_call_bool_callback_on_thread;

            static bool yes() {
                return true;
            }

            bool rejected() {
                return snakebite_ut_call_bool_callback_on_thread(&yes) ==
                    "interpreter callback called on a thread that does not "
                    ~ "own its evaluator (see issue #40)";
            }
        },
        hostCallbackDeclarations,
    ]);
    auto function_ = findFunction(modules[0], "rejected");
    auto interpreter = new Interpreter(Program([modules[0]]));

    bool result;
    interpreter.call(function_, &result, []);

    result.should == true;
}


// Capacity belongs to the process, so the child runs without callback entries
// held by other parallel tests. Each evaluator reserves one entry. The 65th
// evaluator must fail clearly, then succeed after one owner is destroyed.
@("pointers.functionPointer.boolCallback.poolCapacity.Interpreter")
@Tags("Interpreter")
unittest {
    import std.file: thisExePath;
    import std.process: environment, execute;

    enum marker = "SNAKEBITE_CALLBACK_POOL_CAPACITY_CHILD";
    enum testName = "ut.backends.call.pointers.pointers.functionPointer."
        ~ "boolCallback.poolCapacity.Interpreter";
    if (environment.get(marker) is null) {
        auto childEnvironment = environment.toAA;
        childEnvironment[marker] = "1";
        const child = execute([thisExePath, testName], childEnvironment);
        assert(child.status == 0, child.output);
        return;
    }

    auto modules = parseSnippets([
        q{
            module bool_callback_capacity_root;
            import ut.backends.call.pointers:
                snakebite_ut_call_bool_callback;

            static bool yes() {
                return true;
            }

            bool call() {
                return snakebite_ut_call_bool_callback(&yes);
            }
        },
        hostCallbackDeclarations,
    ]);
    auto function_ = findFunction(modules[0], "call");
    auto program = Program([modules[0]]);
    Interpreter[boolFunctionEntryCount] interpreters;
    Interpreter overflow = new Interpreter(program);
    scope(exit) {
        foreach (instance; interpreters)
            if (instance !is null)
                destroy(instance);
        if (overflow !is null)
            destroy(overflow);
    }

    foreach (ref instance; interpreters) {
        instance = new Interpreter(program);
        bool result;
        instance.call(function_, &result, []);
        result.should == true;
    }

    bool result;
    const exhausted = overflow.call(function_, &result, []).shouldThrow;
    exhausted.msg.should == "ffi bool function callback pool is exhausted";

    destroy(interpreters[0]);
    interpreters[0] = null;
    overflow.call(function_, &result, []);
    result.should == true;
}


// Writing through the pointer changes the variable it points at, not a
// copy of it: `p` and `b` name the same storage.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("pointers.write.throughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int write() {
                    int b = 3;
                    int* p = &b;
                    *p = 7;
                    return b;
                }
            },
            "write",
        );
    }
}

// A pointer argument carries the address a `&local` evaluated to, not a
// copy of the pointee: the callee writes through it and the caller's own
// local changes.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("pointers.pass.writesCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                void set(int* p) {
                    *p = 9;
                }

                int write() {
                    int b = 3;
                    set(&b);
                    return b;
                }
            },
            "write",
        );
    }
}

// A pointer argument also lets the callee hand a value back without a
// `return`, the read side of the same address the write tests exercise.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("pointers.pass.readsCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4.shouldBeRetOf!(
            backend,
            q{
                int read(int* p) {
                    return *p + 1;
                }

                int call() {
                    int b = 3;
                    return read(&b);
                }
            },
            "call",
        );
    }
}

// `static` storage lives outside any frame - `&count` still answers the one
// address every call shares, so a write through the pointer is visible to
// a later read of `count` itself.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE interpreter refuses to take the address of a " ~
        "thread-local variable at compile time"),
)) {
    @("pointers.addressOf.static_." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int bump() {
                    static int count = 1;
                    int* p = &count;
                    *p = *p + 4;
                    return count;
                }
            },
            "bump",
        );
    }
}

// `field.offset` in `visit(DotVarExp)` is read as a whole-byte offset. A
// bitfield is also a `VarDeclaration`, but its storage is a sub-byte
// slice of that byte - a plain `memcpy` from it reads the whole packed
// byte instead of masking and shifting out just the bitfield, so a
// memcpy-based read of `b` below would answer the packed byte `0x53`
// truncated to `ubyte` rather than `b`'s own 4-bit value, 5. Refused
// rather than run to that wrong answer. Field assignment through a
// struct variable is not an lvalue `addressOf` handles yet, so the
// packed byte is built by hand - `a` (3) in the low nibble, `b` (5) in
// the high one, the same layout `S` itself packs `a`/`b` into - and read
// back through a `S*` a pointer cast produces.
@("pointers.dotVar.bitfield.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        struct S {
            ubyte a : 4;
            ubyte b : 4;
        }

        ubyte readB() {
            ubyte raw = 0x53;
            S* p = cast(S*) &raw;
            return p.b;
        }
    });
    auto function_ = findFunction(module_, "readB");

    ubyte result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot evaluate `(*p).b`: reading a bitfield is " ~
                "not supported");
}

// `&factorial` on a module-level function is dmd's `SymOffExp` too, the
// same node a local's address takes above - the difference is `var` names
// a `FuncDeclaration`, not a `VarDeclaration`, so there is no frame slot to
// find. The value it takes the address of is a plain function pointer (no
// context word), unlike `&nested` on a nested function, which dmd instead
// lowers to a `DelegateExp`. `factorial` is declared alongside `main`
// rather than nested inside it, the same way `shouldBeStatusOf` renders any
// top-level declaration, so its address is a plain function pointer both
// natively and in the guest.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("pointers.functionPointer.moduleLevel.call." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            uint factorial(uint n) {
                return n <= 1 ? 1 : n * factorial(n - 1);
            }

            int main() {
                uint function(uint) fn = &factorial;
                assert(fn(5) == 120);
                return 0;
            }
        });
    }
}

// A function pointer is an ordinary value once taken: passing it into
// another function and calling it there reaches the same guest function as
// calling it directly would.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("pointers.functionPointer.moduleLevel.passAsArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            uint answer() {
                return 42;
            }

            uint invoke(uint function() fn) {
                return fn();
            }

            int main() {
                assert(invoke(&answer) == 42);
                return 0;
            }
        });
    }
}

// A guest function pointer travels as `visit(SymOffExp)`'s stand-in - the
// `FuncDeclaration` itself, since this backend has no machine code of its
// own for an interpreted function (see the comment there). That stand-in
// is only ever resolved back by this evaluator's own `calleeOf`, on a call
// this evaluator itself makes. Handed instead to genuinely native code
// through the FFI seam - `qsort`'s comparator argument here - the bits
// leave as an ordinary function pointer value and native code jumps to
// them directly.
//
// Native compiles `compare` to real machine code, so the same program runs
// correctly there: `qsort` calls it back and the array comes out sorted.
// The interpreter has no machine code to jump to, so it cannot let this
// reach `qsort` at all; that is pinned separately below, in
// `pointers.functionPointer.nativeCallback.refused.Interpreter`, since
// `shouldBeRetOf` cannot express "throws on this backend, succeeds on
// that one" in a single assertion.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.diverges,
        "pinned in " ~
        "pointers.functionPointer.nativeCallback.refused.Interpreter: " ~
        "the callback's extern(C) int signature is outside the " ~
        "extern(D) bool signature supported by issue #168"),
)) {
    @("pointers.functionPointer.nativeCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                extern(C) int compare(scope const void* a, scope const void* b) {
                    return *cast(const int*) a - *cast(const int*) b;
                }

                int answer() {
                    import core.stdc.stdlib: qsort;

                    int[3] xs = [3, 1, 2];
                    qsort(xs.ptr, xs.length, int.sizeof, &compare);
                    return xs[0];
                }
            },
            "answer",
        );
    }
}

// The sibling of the Matrix test above, for the one backend it could not
// express: the interpreter refuses to hand `qsort` a callback whose
// signature is not supported, with a message naming the signature and the
// remaining issue #9 work instead of letting the host call a declaration.
@("pointers.functionPointer.nativeCallback.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        extern(C) int compare(scope const void* a, scope const void* b) {
            return *cast(const int*) a - *cast(const int*) b;
        }

        int answer() {
            import core.stdc.stdlib: qsort;

            int[3] xs = [3, 1, 2];
            qsort(xs.ptr, xs.length, int.sizeof, &compare);
            return xs[0];
        }
    });
    auto function_ = findFunction(module_, "answer");

    int result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot call `qsort` with `compare` as a function " ~
                "pointer argument: callback signature `extern (C) " ~
                "int(scope const(void*) a, scope const(void*) b)` is not " ~
                "supported (see issue #9)");
}
