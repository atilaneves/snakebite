module ut.backends.call.pointers;


import ut.backends;


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
