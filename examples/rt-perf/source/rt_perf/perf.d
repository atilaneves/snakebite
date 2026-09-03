module rt_perf.perf;


uint factorial(uint i) {
    return i == 0 ? 1 : i * factorial(i - 1);
}

unittest {
    assert(factorial(5) == 120);
    assert(factorial(12) == 479_001_600);
}

uint fibonacci(uint i) {
    if(i == 0) return 0;
    if(i == 1) return 1;
    return fibonacci(i - 1) + fibonacci(i - 2);
}

unittest {
    assert(fibonacci(1) == 1);
    assert(fibonacci(2) == 1);
    assert(fibonacci(3) == 2);
    assert(fibonacci(4) == 3);
    assert(fibonacci(5) == 5);
    assert(fibonacci(6) == 8);
    assert(fibonacci(21) == 10_946);
    assert(fibonacci(22) == 17_711);
    assert(fibonacci(23) == 28_657);
    assert(fibonacci(25) == 75_025);
}

int tak(int x, int y, int z) {
    if (x <= y)
        return y;

    return tak(
        tak(x - 1, y, z),
        tak(y - 1, z, x),
        tak(z - 1, x, y)
    );
}

unittest {
    assert(tak(15, 10, 5) == 15);
    assert(tak(16, 11, 6) == 16);
}

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

unittest {
    const long[] data = [1, 4, 7, 10, 15, 21, 28, 36, 45, 55, 66, 78, 91];
    assert(binarySearch(data, 78) == 11);
    assert(binarySearch(data, 15) == 4);
    assert(binarySearch(data, 42) == -1);
}

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

unittest {
    assert(countPrimes(100) == 25);
    assert(countPrimes(1_000) == 168);
    assert(countPrimes(10_000) == 1_229);
    assert(countPrimes(50_000) == 5_133);
}

// Loop-heavy over a buffer: 15k element reads and adds, no allocation.
@("kernel.loop") unittest {
    auto buf = new uint[](3_000);
    foreach (i, ref b; buf) b = cast(uint) i;
    ulong sum;
    foreach (_; 0 .. 5)
        foreach (b; buf) sum += b;
    assert(sum == 5UL * 4_498_500UL);
}

// Allocation-heavy: 1.5k appends through druntime.
@("kernel.append") unittest {
    ubyte[] bytes;
    foreach (i; 0 .. 1_500) bytes ~= cast(ubyte) i;
    assert(bytes.length == 1_500);
    assert(bytes[1_499] == cast(ubyte) 1_499);
}

// Struct copies through a slice: 6k element struct stores and loads.
@("kernel.structs") unittest {
    struct KernelPoint { int x; int y; }
    auto pts = new KernelPoint[](600);
    foreach (i, ref p; pts)
        p = KernelPoint(cast(int) i, cast(int) -i);
    long acc;
    foreach (_; 0 .. 10) {
        foreach (p; pts) {
            const q = p; acc += q.x + q.y;
        }
    }
    assert(acc == 0);
}
