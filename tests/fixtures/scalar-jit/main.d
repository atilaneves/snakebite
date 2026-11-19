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

enum byteCount = 600;
enum ubyte replacement = 0xA5;

int copyReadings(ubyte[] readings, ubyte[] destination, bool replaceLast) {
    int position = byteCount - 2;
    auto reading = replacement;
    if (replaceLast)
        goto writeReading;
    assert(readings.length != 0);
    for (position = 0; position < byteCount; position += 2) {
        reading = readings[position];
        if (reading == 0)
            continue;
    writeReading:
        destination[position] = reading;
    }
    return position;
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

    auto readings = new ubyte[byteCount];
    auto destination = new ubyte[byteCount];
    readings[0] = 12;
    readings[2] = 43;
    readings[$ - 2] = 18;
    assert(copyReadings(readings, destination, false) == byteCount);
    assert(destination[0 .. 3] == [12, 0, 43]);
    assert(destination[$ - 2] == 18);

    destination[] = 0;
    assert(copyReadings(readings, destination, true) == byteCount);
    assert(destination[0] == 0 && destination[$ - 2] == replacement);

    ArrayIndexError caught;
    try
        copyReadings(readings, destination[0 .. 1], false);
    catch (ArrayIndexError error)
        caught = error;
    assert(caught !is null);
    assert(caught.index == 2 && caught.length == 1);
    assert(destination[0 .. 3] == [12, 0, 0]);

    auto overlapping = new ubyte[byteCount + 2];
    overlapping[0] = 25;
    assert(copyReadings(overlapping[0 .. byteCount], overlapping[2 .. $],
        false) == byteCount);
    foreach (position, value; overlapping)
        assert(value == (position % 2 == 0 ? 25 : 0));

    foreach (_; 0 .. 300)
        assert(rewriteByte(destination, false, false) == 3);
    assert(rewriteByte(destination, true, false) == 2);
    auto wrappedSpan = (cast(ubyte*) (size_t.max - 1))[0 .. 4];
    assert(rewriteByte(wrappedSpan, false, true) == 17);
    return 0;
}
