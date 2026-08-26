// Calls `abs` a million times, so a backend's time here is dominated by
// what it costs that backend to reach an already-compiled function and
// come back. The sum is there only to keep the calls: `abs` is `pure`, so
// a bare `abs(i);` statement does not compile. Nothing reads the total.
unittest {
    import core.stdc.stdlib: abs;

    int sum = 0;
    for (int i = 0; i < 1_000_000; ++i)
        sum += abs(i);
}
