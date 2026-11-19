import core.exception : ArrayIndexError;

private enum sampleDepth = 5;
private enum staging = 8;
private enum report = 5;

private final class RouteBuffer(T) {
    ulong header;
    long visits;
    int tokens;
    T[] samples;

    void collect(int level, int route) {
        visits += 3;
        tokens -= 2;
        if (level == 2)
            return;
        const prior = level - 1;
        collect(prior, route);
        for (int i = prior; i >= 2; --i) {
            const old = samples[prior];
            const saved = samples[staging];
            samples[staging] = 36;
            samples[prior] = 11;
            static if (is(T == int)) {
                const reading = samples[old];
            } else {
                samples[report] = samples[route];
            }
            collect(prior, route);
            samples[i - 2] = old;
            static if (is(T == int))
                samples[report] = reading;
            samples[staging] = saved;
        }
    }

    void reset(const(T)[] seed) {
        visits = 0;
        tokens = 0;
        samples[] = seed;
    }
}

void checkRouteCopy()() {
    const short[12] seed = [41, 17, 3, 1, 2, 27, -4, 0, 1, 2, 3, 4];
    const short[12] expected = [11, 11, 11, 11, 11, 27, -4, 0, 1, 2, 3, 4];
    auto buffer = new RouteBuffer!short;
    buffer.samples = seed[].dup;
    foreach (_; 0 .. 350) {
        buffer.reset(seed[]);
        buffer.collect(sampleDepth, report);
        assert(buffer.visits == 123 && buffer.tokens == -82);
        assert(buffer.samples == expected[]);
    }

    buffer.reset(seed[]);
    buffer.collect(sampleDepth, 2);
    assert(buffer.visits == 123 && buffer.tokens == -82);
    assert(buffer.samples == [11, 11, 11, 11, 11, 11, -4, 0, 1, 2, 3, 4]);

    foreach (route; [-1, cast(int) seed.length]) {
        buffer.reset(seed[]);
        try {
            buffer.collect(sampleDepth, route);
            assert(false);
        } catch (ArrayIndexError error) {
            assert(error.index == cast(size_t) route && error.length == seed.length);
        }
        assert(buffer.visits == 12 && buffer.tokens == -8);
        assert(buffer.samples == [41, 17, 11, 1, 2, 27, -4, 0, 36, 2, 3, 4]);
    }

    buffer.reset(seed[]);
    buffer.collect(sampleDepth, report);
    assert(buffer.visits == 123 && buffer.tokens == -82);
    assert(buffer.samples == expected[]);
}

void checkStoredRoute()() {
    const int[12] seed = [41, 17, 3, 1, 2, 27, -4, 0, 1, 2, 3, 4];
    const int[12] expected = [11, 11, 11, 11, 11, 4, -4, 0, 1, 2, 3, 4];
    auto buffer = new RouteBuffer!int;
    buffer.samples = seed[].dup;
    foreach (_; 0 .. 350) {
        buffer.reset(seed[]);
        buffer.collect(sampleDepth, report);
        assert(buffer.visits == 123 && buffer.tokens == -82);
        assert(buffer.samples == expected[]);
    }

    buffer.reset(seed[]);
    buffer.samples[2] = -1;
    try {
        buffer.collect(sampleDepth, report);
        assert(false);
    } catch (ArrayIndexError error) {
        assert(error.index == size_t.max && error.length == seed.length);
    }
    assert(buffer.visits == 12 && buffer.tokens == -8);
    assert(buffer.samples == [41, 17, 11, 1, 2, 27, -4, 0, 36, 2, 3, 4]);

    buffer.reset(seed[]);
    buffer.collect(sampleDepth, report);
    assert(buffer.visits == 123 && buffer.tokens == -82);
    assert(buffer.samples == expected[]);
}
