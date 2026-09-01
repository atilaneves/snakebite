// A minimal fixture for `sb tests/examples/ct.d`: declarations only, no
// runtime `main`, so loading it produces no stdout or stderr.

uint factorial(uint i) {
    return i == 0 ? 1 : i * factorial(i - 1);
}

unittest {
    assert(factorial(0) == 1);
    assert(factorial(5) == 120);
}
