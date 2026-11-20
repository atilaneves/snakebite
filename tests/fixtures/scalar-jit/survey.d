import core.exception: ArrayIndexError;

final class Survey {
    ulong leader = 472;
    union {
        struct {
            long visits;
            int tokens;
        }
        short[10] storage;
    }
    short[] samples;

    void collect(int level) {
        visits += 3;
        tokens -= 2;
        if (level == 2)
            return;
        const prior = level - 1;
        collect(prior);
        for (int i = prior; i >= 2; i -= 1) {
            const old = samples[prior];
            samples[prior] = 11;
            collect(prior);
            samples[i - 2] = old;
        }
    }
}

void checkSurvey() {
    auto survey = new Survey;
    auto collect = &survey.collect;
    const short[7] seed = [41, 17, 3, -8, 19, 27, -4];
    const short[7] result = [11, 11, 11, 11, 11, 27, -4];
    auto samples = new short[seed.length];
    survey.samples = samples[];
    foreach (_; 0 .. 350) {
        samples[] = seed[];
        survey.visits = 0;
        survey.tokens = 0;
        collect(5);
        assert(survey.visits == 123 && survey.tokens == -82);
        assert(samples[] == result[]);
    }

    version (LittleEndian) {
        survey.samples = survey.storage[];
        survey.storage = [0, 0, 0, 0, 0, 0, 13, 17, 19, 23];
        collect(5);
        assert(survey.storage == [-9, 11, 11, 11, -9, -4, 13, 17, 19, 23]);
    }

    survey.samples = samples[0 .. 4];
    samples[] = seed[];
    survey.visits = 0;
    survey.tokens = 0;
    try {
        collect(5);
        assert(false);
    } catch (ArrayIndexError error) {
        assert(error.index == 4 && error.length == 4);
        assert(survey.visits == 33 && survey.tokens == -22);
        assert(samples[] == [11, -8, 11, 11, 19, 27, -4]);
    }

    survey.samples = samples[];
    survey.visits = 0;
    survey.tokens = 0;
    collect(5);
    assert(survey.visits == 123 && survey.tokens == -82);
    assert(samples[] == result[]);
}
