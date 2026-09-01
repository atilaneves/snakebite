module ut.backends.call.rtPerf;


import ut.backends;


// The real `binarySearch` in `examples/rt-perf` - a `const` dynamic-array
// parameter, `.length`, indexing, and a `while` loop - reproduced here so
// its own logic runs through the shared backend matrix rather than only
// through `bench`'s own driver.
static foreach (backend; Matrix!()) {
    @("rtPerf.binarySearch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11L.shouldBeRetOf!(
            backend,
            q{
                long binarySearch(const(long)[] a, long x) {
                    long lo = 0;
                    long hi = a.length;

                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;

                        if (a[mid] == x)
                            return mid;

                        if (a[mid] < x)
                            lo = mid + 1;
                        else
                            hi = mid;
                    }

                    return -1;
                }

                long found() {
                    const long[] data =
                        [1, 4, 7, 10, 15, 21, 28, 36, 45, 55, 66, 78, 91];
                    return binarySearch(data, 78);
                }
            },
            "found",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("rtPerf.binarySearch.notFound." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-1L).shouldBeRetOf!(
            backend,
            q{
                long binarySearch(const(long)[] a, long x) {
                    long lo = 0;
                    long hi = a.length;

                    while (lo < hi) {
                        const mid = lo + (hi - lo) / 2;

                        if (a[mid] == x)
                            return mid;

                        if (a[mid] < x)
                            lo = mid + 1;
                        else
                            hi = mid;
                    }

                    return -1;
                }

                long notFound() {
                    const long[] data =
                        [1, 4, 7, 10, 15, 21, 28, 36, 45, 55, 66, 78, 91];
                    return binarySearch(data, 42);
                }
            },
            "notFound",
        );
    }
}

// The real `kernel.loop` benchmark in `examples/rt-perf` - a `ref` foreach
// over a runtime-length array to fill it, then a plain-value foreach over
// it repeated inside an integer-range foreach, reproduced here so the
// backend matrix runs the same loop shape `bench`'s own driver measures.
static foreach (backend; Matrix!()) {
    @("rtPerf.kernelLoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (5UL * 4_498_500UL).shouldBeRetOf!(
            backend,
            q{
                ulong kernelLoop() {
                    auto buf = new uint[](3_000);
                    foreach (i, ref b; buf)
                        b = cast(uint) i;

                    ulong sum;
                    foreach (_; 0 .. 5)
                        foreach (b; buf)
                            sum += b;

                    return sum;
                }
            },
            "kernelLoop",
        );
    }
}

// The real `kernel.append` benchmark in `examples/rt-perf` - repeated
// single-element `~=` inside an integer-range foreach, growing well past
// any capacity a first allocation could have reserved.
static foreach (backend; Matrix!()) {
    @("rtPerf.kernelAppend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] bytes;
                foreach (i; 0 .. 1_500)
                    bytes ~= cast(ubyte) i;

                assert(bytes.length == 1_500);
                assert(bytes[1_499] == cast(ubyte) 1_499);
            }
        });
    }
}

// The real `countPrimes` in `examples/rt-perf` - a runtime-length `new
// bool[](n)`, element load/store, and nested `for` loops with `continue`.
static foreach (backend; Matrix!()) {
    @("rtPerf.countPrimes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        25.shouldBeRetOf!(
            backend,
            q{
                int countPrimes(int n) {
                    auto composite = new bool[n + 1];
                    int count;

                    for (int p = 2; p <= n; ++p) {
                        if (composite[p])
                            continue;

                        ++count;

                        if (p <= n / p) {
                            for (int i = p * p; i <= n; i += p)
                                composite[i] = true;
                        }
                    }

                    return count;
                }

                int primesUpTo100() {
                    return countPrimes(100);
                }
            },
            "primesUpTo100",
        );
    }
}

// The real `kernel.structs` bench in `examples/rt-perf` - struct
// construction, an array of structs, and element stores, loads and
// copies - reproduced here with `for` loops rather than the bench's own
// `foreach`, which is not yet in scope for every backend.
static foreach (backend; Matrix!()) {
    @("rtPerf.structs." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0L.shouldBeRetOf!(
            backend,
            q{
                struct KernelPoint {
                    int x;
                    int y;
                }

                long structs() {
                    auto pts = new KernelPoint[](600);
                    for (int i = 0; i < 600; ++i)
                        pts[i] = KernelPoint(i, -i);

                    long acc;
                    for (int rep = 0; rep < 10; ++rep) {
                        for (int i = 0; i < 600; ++i) {
                            const q = pts[i];
                            acc += q.x + q.y;
                        }
                    }
                    return acc;
                }
            },
            "structs",
        );
    }
}
