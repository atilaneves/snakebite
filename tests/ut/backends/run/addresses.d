module ut.backends.run.addresses;


// The expected exit status of each guest is what `dmd -run` gives it.
// The initializer symbol of an aggregate names bytes that have no variable.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: static variable cannot be read at compile time"),
)) {
    @("address.pointerOfAnUnnamedSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[] four() {
                static int[4] storage = [1, 2, 3, 4];
                return storage[];
            }

            int main() {
                const literal = "abc".ptr;
                const call = four.ptr;
                const sliced = four[1 .. 3].ptr;
                const condition = (literal !is null ? four : null).ptr;
                return literal[1] == 'b' && call[3] == 4 && sliced[0] == 2
                    && sliced is call + 1 && condition is call ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot determine the address of the initializer symbol"),
)) {
    @("address.pointerOfAnInitializerSymbol." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int a = 7; int b = 9; }

            int main() {
                const pointer = cast(const(int)*) __traits(initSymbol, S).ptr;
                return pointer[0] == 7 && pointer[1] == 9 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot determine the address of the initializer symbol"),
)) {
    @("address.pointerOfAClassInitializerSymbol." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int a = 7; int b = 9; }

            int main() {
                const bytes = __traits(initSymbol, C);
                const pointer = cast(const(int)*) bytes.ptr;
                return bytes.length == __traits(classInstanceSize, C)
                    && pointer[4] == 7 && pointer[5] == 9
                    && bytes.ptr is typeid(C).initializer.ptr ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot determine the address of the initializer symbol"),
)) {
    @("address.copyFromAnInitializerSymbol." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: memcpy;

            struct S { int a = 7; int b = 9; }

            int main() {
                S copy = void;
                memcpy(&copy, __traits(initSymbol, S).ptr, S.sizeof);
                return copy.a == 7 && copy.b == 9 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot determine the address of the initializer symbol"),
)) {
    @("address.zeroInitializedStructInitializerSymbolHasNoPointer."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Z { int a; long b; }

            int main() {
                const bytes = __traits(initSymbol, Z);
                return bytes.ptr is null && bytes.length == Z.sizeof
                    && bytes is typeid(Z).initializer ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot determine the address of the initializer symbol"),
)) {
    @("address.structInitializerSymbolIsTheTypeInfoInitializer."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int a = 7; int b = 9; }

            int main() {
                return __traits(initSymbol, S).ptr
                    is typeid(S).initializer.ptr ? 0 : 1;
            }
        });
    }
}

// `&p[3]` of a null `int*` is address 12 and reads nothing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot index through null pointer `p`"),
)) {
    @("nullPointerAddress.indexConstant." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() { int* p; auto q = &p[3]; assert(cast(size_t) q == 12); }
        });
    }
}
