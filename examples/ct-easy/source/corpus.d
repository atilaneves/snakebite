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
