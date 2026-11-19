module main;

import core.exception : ArrayIndexError;
import core.math : sqrt;

struct ChannelSpan {
    double base;
    double increment;
    double response;
    double gain;
}

double calibratedTotal(ChannelSpan channel, int count, int skipAt,
        int adjustAt, int divisor)
{
    double value = channel.base;
    double total = 0;
    for (int sample = 0; sample < count; ++sample) {
        double linear;
        double correction;
        if (sample == skipAt)
            goto masked;
        value += channel.increment;
        linear = value * channel.gain;
        goto convert;
    masked:
        total += channel.base;
        goto continueLoop;
    convert:
        correction = sqrt(channel.response) * channel.gain;
        total += linear + correction;
        if (sample == adjustAt)
            total += 63 / divisor;
    continueLoop:
    }
    return total;
}

int labelSamples(ubyte[] samples, ubyte[] labels, bool resume) {
    const last = 300;
    int index = last;
    int count;
    if (resume)
        goto sample;
    assert(samples.length != 0);
    for (index = 1; index <= last; ++index) {
    sample:
        if (!samples[index - 1])
            continue;
        labels[index - 1] = 9;
        ++count;
    }
    return count;
}

int rewriteByte(ubyte[] labels, bool pointsIntoFrame, bool skip) {
    int index = 1;
    if (pointsIntoFrame)
        labels = (cast(ubyte*) &index)[0 .. 1];
    assert(labels.length != 0);
    if (skip)
        return 17;
    for (index = 1; index <= 1; index += 2)
        labels[index - 1] = 0;
    return index;
}

int main() {
    const channel = ChannelSpan(0, 0.5, 4.0, 2.0);
    auto calibrate = &calibratedTotal;
    assert(calibrate(channel, 400, -1, -1, 7) == 81_800);
    assert(calibrate(channel, 400, -1, -1, 7) == 81_800);
    assert(calibrate(channel, 400, 3, 4, 7) == 81_405);
    assert(calibrate(channel, 0, -1, -1, 7) == 0);

    auto samples = new ubyte[300];
    auto labels = new ubyte[300];
    samples[0 .. 2] = 1;
    assert(labelSamples(samples, labels, false) == 2);
    labels[] = 0;
    assert(labelSamples(samples, labels, true) == 0);
    assert(labels[0] == 0);
    assert(labelSamples(samples, labels, false) == 2);
    assert(labels[0 .. 3] == [9, 9, 0]);

    labels[] = 0;
    ArrayIndexError caught;
    try
        labelSamples(samples, labels[0 .. 1], false);
    catch (ArrayIndexError error)
        caught = error;
    assert(caught !is null);
    assert(caught.index == 1 && caught.length == 1);
    assert(labels[0 .. 2] == [9, 0]);

    foreach (_; 0 .. 300)
        assert(rewriteByte(labels, false, false) == 3);
    assert(rewriteByte(labels, true, false) == 2);
    auto wrappedSpan = (cast(ubyte*) (size_t.max - 1))[0 .. 4];
    assert(rewriteByte(wrappedSpan, false, true) == 17);
    return 0;
}
