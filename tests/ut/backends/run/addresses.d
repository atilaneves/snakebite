module ut.backends.run.addresses;


// The expected exit status of each guest is what `dmd -run` gives it.
// An address that two reads of the same declaration take must be the same
// address, and a write through it must reach the declaration.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot take address of thread-local variable"),
)) {
    @("address.moduleVariableOfEachStorageClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int plain = 1;
            __gshared int shared_ = 2;
            immutable int fixed = 3;

            int main() {
                *(&plain) += 10;
                *(&shared_) += 10;
                const p = &fixed;
                return plain == 11 && shared_ == 12 && *p == 3
                    && &plain is &plain ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: static variable cannot be read at compile time"),
)) {
    @("address.threadLocalIsPerThread." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.thread: Thread;

            int local;
            __gshared size_t seen;

            int main() {
                local = 7;
                auto thread = new Thread({
                    local = 9;
                    seen = cast(size_t) &local;
                });
                thread.start;
                thread.join;
                return local == 7 && seen != 0 && seen != cast(size_t) &local
                    ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: static variable cannot be read at compile time"),
)) {
    @("address.staticLocalKeepsOneAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int* counter() {
                static int count;
                ++count;
                return &count;
            }

            int main() {
                auto first = counter;
                auto second = counter;
                return first is second && *first == 2 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot take address of thread-local variable"),
)) {
    @("address.variableInTemplateInstance." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int* slot(int n)() {
                static int value = n;
                return &value;
            }

            int main() {
                *slot!1 += 5;
                return *slot!1 == 6 && *slot!2 == 2
                    && slot!1 !is slot!2 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take the address of an extern(C) variable"),
)) {
    @("address.externCVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C) __gshared int shared_ = 5;

            int main() {
                *(&shared_) += 1;
                return shared_ == 6 ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: static variable cannot be read at compile time"),
)) {
    @("address.offsetIntoAggregateAndStaticArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int a; int b; }
            __gshared S s;
            __gshared int[5] array;

            int main() {
                *(&s.b) = 3;
                *(&array[3]) = 4;
                return s.b == 3 && array[3] == 4
                    && cast(size_t) &s.b == cast(size_t) &s + 4
                    && cast(size_t) &array[3] == cast(size_t) &array + 12
                    ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("address.functionsAndNestedFunctions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int twice(int x) { return 2 * x; }

            int main() {
                int base = 1;
                int add(int x) { return x + base; }
                int function(int) f = &twice;
                int delegate(int) d = &add;
                base = 10;
                return f(3) == 6 && d(3) == 13 && f is &twice ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("address.typeInfoAndClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {}

            int main() {
                const info = typeid(int);
                const classInfo = typeid(C);
                auto c = new C;
                return info is typeid(int) && classInfo is typeid(C)
                    && typeid(c) is classInfo ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE: cannot determine the address of the initializer symbol"),
)) {
    @("address.initializerSymbolIsReadAsASlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int a = 7; int b = 9; }

            int main() {
                const bytes = __traits(initSymbol, S);
                const asPointer = cast(const(int)*) bytes.ptr;
                return bytes.length == S.sizeof && asPointer[0] == 7
                    && asPointer[1] == 9 ? 0 : 1;
            }
        });
    }
}


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
