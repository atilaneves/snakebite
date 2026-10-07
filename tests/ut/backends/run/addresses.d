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

// `&p[i]` with a run-time index of a null pointer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot index through null pointer `p`"),
)) {
    @("nullPointerAddress.indexRuntime." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            pragma(inline, false) size_t three() { return 3; }
            void main() { int* p; auto q = &p[three]; assert(cast(size_t) q == 12); }
        });
    }
}

// `&p.b` of a null struct pointer is the field offset.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: dereference of null pointer `p`"),
)) {
    @("nullPointerAddress.field." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int a; int b; }
            void main() { S* p; auto q = &p.b; assert(cast(size_t) q == 4); }
        });
    }
}

// `&(*p)` of a null pointer is null.
static foreach (backend; Matrix!()) {
    @("nullPointerAddress.dereference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() { int* p; auto q = &(*p); assert(q is null); }
        });
    }
}

// `&arr.ptr[3]` of an empty slice has a null pointer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot index through null pointer `cast(int*)arr`"),
)) {
    @("nullPointerAddress.emptySlicePointerIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() { int[] arr; auto q = &arr.ptr[3]; assert(cast(size_t) q == 12); }
        });
    }
}

// A `ref` parameter bound to `p[3]` of a null pointer reads nothing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot index through null pointer `p`"),
)) {
    @("nullPointerAddress.refParameterNotRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            size_t address;
            void f(ref int x) { address = cast(size_t) &x; }
            void main() { int* p; f(p[3]); assert(address == 12); }
        });
    }
}

// `p + 3` of a null `int*`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot perform pointer arithmetic on non-arrays at compile time"),
)) {
    @("nullPointerAddress.pointerArithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() { int* p; auto q = p + 3; assert(cast(size_t) q == 12); }
        });
    }
}

// The address of `p[i]` in a loop condition of a null `int*` reads nothing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot cast `&null` to `ulong` at compile time"),
)) {
    @("nullPointerAddress.indexInLoopCondition." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int* p;
                size_t i;
                size_t last;
                for (; cast(size_t) &p[i] < 12; ++i) last = cast(size_t) &p[i];
                assert(i == 3 && last == 8);
            }
        });
    }
}

// A `ref` return of `p[3]` of a null `int*` that the caller only takes the address of.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops with: cannot index through null pointer `p`"),
)) {
    @("nullPointerAddress.refReturnAddressOnly." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ref int at(int* p) { return p[3]; }
            void main() { assert(cast(size_t) &at(null) == 12); }
        });
    }
}
