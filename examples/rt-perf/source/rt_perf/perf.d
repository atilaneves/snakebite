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
