module ut.backends.call.cast_;


import ut.backends;


// `5_000_000_000` needs 33 bits, so its low 32 bits - what `cast(int)`
// keeps - differ from the value itself. An implementation that clamps or
// saturates instead of truncating fails this.
static foreach (backend; Matrix!()) {
    @("cast.narrowing.truncates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        705_032_704.shouldBeRetOf!(
            backend,
            q{
                long big() {
                    return 5_000_000_000L;
                }

                int narrowed() {
                    return cast(int) big();
                }
            },
            "narrowed",
        );
    }
}

// Widening a signed operand copies its sign bit into the new high bits, so
// `cast(long)` of a negative `int` stays negative. An implementation that
// zero-extends instead answers a large positive value.
static foreach (backend; Matrix!()) {
    @("cast.widening.signed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-5L).shouldBeRetOf!(
            backend,
            q{
                int negative() {
                    return -5;
                }

                long widened() {
                    return cast(long) negative();
                }
            },
            "widened",
        );
    }
}

// Widening an unsigned operand fills the new high bits with zero, so
// `cast(long)` of `uint.max` is the same positive value, not -1. An
// implementation that sign-extends instead answers -1.
static foreach (backend; Matrix!()) {
    @("cast.widening.unsigned." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4_294_967_295L.shouldBeRetOf!(
            backend,
            q{
                uint top() {
                    return uint.max;
                }

                long widened() {
                    return cast(long) top();
                }
            },
            "widened",
        );
    }
}

// The shape the array code needs: a `size_t` (the array's own length,
// 8 bytes) narrowed to an `int` (4 bytes). The string literal isolates the
// cast from array support, which is exercised on its own elsewhere.
static foreach (backend; Matrix!()) {
    @("cast.narrowLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                string greeting() {
                    return "hello";
                }

                int length_() {
                    return cast(int) greeting().length;
                }
            },
            "length_",
        );
    }
}

// `cast(void[])` of a `T[]` scales the length by `T.sizeof`, the same
// conversion `core.internal.array.appending` applies before calling
// `gc_expandArrayUsed`/`gc_shrinkArrayUsed`, both of which take `void[]`.
// `int.sizeof` (4) isolates the scaling from a verbatim `{length, ptr}`
// copy: a 1-byte element would leave the length unchanged and the two
// implementations indistinguishable.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE keeps a `cast(void[])` array's length as an " ~
        "element count, not a byte count - pinned below"),
)) {
    @("cast.arrayToVoid.scalesLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(12).shouldBeRetOf!(
            backend,
            q{
                int[] ints() {
                    return [1, 2, 3];
                }

                size_t voidLength() {
                    void[] bytes = cast(void[]) ints();
                    return bytes.length;
                }
            },
            "voidLength",
        );
    }
}

// dmd's own CTFE does not scale the length through a `cast(void[])` the
// way runtime D does - pins the divergence; the native side (checked
// above for every other backend) scales it.
@("cast.arrayToVoid.scalesLength.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    size_t(3).shouldBeRetOf!(
        Ctfe,
        q{
            int[] ints() {
                return [1, 2, 3];
            }

            size_t voidLength() {
                void[] bytes = cast(void[]) ints();
                return bytes.length;
            }
        },
        "voidLength",
    );
}

// dmd classifies `bool` as `integral | unsigned`, so a naive integral
// narrowing takes the operand's low byte instead of comparing it against
// zero. `256`'s low byte is `0`, which a truncating implementation would
// store as `false` - D specifies `cast(bool) 256` as `true`.
static foreach (backend; Matrix!()) {
    @("cast.bool.nonZeroIsTrue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int wide() {
                    return 256;
                }

                bool truthy() {
                    return cast(bool) wide();
                }
            },
            "truthy",
        );
    }
}
