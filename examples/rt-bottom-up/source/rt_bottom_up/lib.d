module rt_bottom_up.lib;

// The sum only exists to keep the calls: `abs` is `pure`, so a bare
// `abs(i);` statement does not compile. Nothing reads the total.
unittest {
    import core.stdc.stdlib: abs;

    int sum = 0;
    for (int i = 0; i < 1_000_000; ++i)
        sum += abs(i);
}
