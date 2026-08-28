module rt_perf.lib;

unittest {
    import core.stdc.stdlib: abs;

    int sum = 0;
    for (int i = 0; i < 1_000_000; ++i)
        sum += abs(i);
    assert(sum == 1_783_293_664);
}
