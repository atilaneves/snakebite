module ut.backends.run.hostfrontend;


import ut.backends;


// A program for a given compiler may call the intrinsics of that compiler's
// library in a manifest constant. `bswap` and `swapEndian` are intrinsics in
// LDC's druntime, and `format` of a floating value calls `fabs`.
static foreach (backend; Matrix!()) {
    @("hostFrontend.intrinsicsAtCompileTime." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.bitop: bswap, popcnt;
            import std.bitmanip: swapEndian;
            import std.format: format;

            enum swapped = bswap(0x01020304u);
            enum counted = popcnt(0xF0u);
            enum shortSwapped = swapEndian(cast(ushort) 0x0102);
            enum formatted = format("%s|%.2f", 1.5, 2.25);

            static assert(swapped == 0x04030201u);
            static assert(counted == 4);
            static assert(shortSwapped == 0x0201);
            static assert(formatted == "1.5|2.25");

            void main() {}
        });
    }
}

// `__traits(targetCPU)` and `__traits(targetHasFeature)` exist in LDC only,
// so the tests of this part exist in a host built by LDC only.
version (LDC) {
    static foreach (backend; Matrix!()) {
        @("hostFrontend.targetTraits." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            0.shouldBeStatusOf!(backend, q{
                static assert(__traits(targetCPU).length > 0);
                static assert(__traits(targetHasFeature, "sse2"));

                void main() {}
            });
        }
    }

    // LDC's `core.simd` has the 64-byte vector types on any x86-64 CPU; the
    // functions of `ldc.gccbuiltins_x86` take them.
    static foreach (backend; Matrix!()) {
        @("hostFrontend.vector64.sizeofIs64Bytes." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            0.shouldBeStatusOf!(backend, q{
                import core.simd: long8;

                static assert(long8.sizeof == 64);

                void main() {}
            });
        }
    }

    // LDC has 32-byte vector types on any x86-64 CPU. dmd has them only when
    // the CPU has AVX.
    static foreach (backend; Matrix!(
        Omit!(Ctfe, Because.inexpressible,
            "dmd's own CTFE cannot evaluate vector arithmetic"),
    )) {
        @("vector32.arithmeticAndStorage." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            0.shouldBeStatusOf!(backend, q{
                import core.simd: float8;

                float8 twice(float8 value) {
                    return value + value;
                }

                struct Boxed {
                    int before;
                    float8 value;
                    int after;
                }

                void main() {
                    static assert(float8.sizeof == 32);
                    float8 doubled = twice(float8(1.5f));
                    float8[] stored = new float8[3];
                    stored[1] = doubled;
                    assert(stored[1][0] == 3 && stored[1][7] == 3);
                    const boxed = Boxed(1, doubled, 2);
                    const copy = boxed;
                    assert(copy.value[3] == 3 && copy.after == 2);
                }
            });
        }
    }
}


// `__VENDOR__` is the name of the compiler that the program is compiled
// with; the standard library spells the same string. A guest analysed as
// if another compiler had built it sees that compiler's name here.
static foreach (backend; Matrix!()) {
    @("vendor.isTheNameOfTheHostCompiler." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.compiler: name;

            void main() {
                assert(__VENDOR__ == name);
            }
        });
    }
}


// `va_copy` is an intrinsic in LDC's druntime and a function with a body in
// dmd's. A finalizer runs inside a collection, where the copy of a `va_list`
// must not take memory from the garbage-collected heap.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("hostFrontend.vaCopyInFinalizer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(backend, q{
            import core.memory: GC;
            import core.stdc.stdarg: va_arg, va_copy, va_end, va_list, va_start;
            extern(C) int first(int count, ...) {
                va_list args;
                va_start(args, count);
                va_list copy;
                va_copy(copy, args);
                va_arg!int(args);
                const result = va_arg!int(copy);
                va_end(copy);
                va_end(args);
                return result;
            }
            __gshared int finalized;
            class Doomed {
                ~this() {
                    assert(first(2, 7, 9) == 7);
                    finalized++;
                }
            }
            int answer() {
                foreach (i; 0 .. 20000)
                    new Doomed;
                GC.collect();
                return finalized > 0 ? 1 : 0;
            }
        }, "answer");
    }
}
