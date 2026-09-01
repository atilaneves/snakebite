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
