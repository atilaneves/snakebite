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

float decodeLevels(T)(T value, int resolution, int count) {
    float total = 0;
    for (int sample = 0; sample < count; ++sample) {
        auto level = value;
        static if (is(T == short)) {
            level >>= resolution;
            level >>= 1;
        } else {
            level >>>= resolution;
            level >>>= 2;
        }
        total += 2.0f * cast(float) level;
    }
    return total;
}

double decodeSequences(uint sequence, int resolution, int count) {
    double total = 0;
    for (int sample = 0; sample < count; ++sample) {
        const decoded = sequence >>> resolution;
        const coarse = sequence >> 2;
        total += cast(double) decoded + 2.0 * cast(double) coarse;
    }
    return total;
}

float calibrationResidual(short level, ushort offset, int count) {
    float total = 0;
    for (int sample = 0; sample < count; ++sample)
        total += cast(float) level * 2.0f + cast(float) offset;
    return total;
}

void accumulateReadings(ref double total, ref int reading, int replacement,
        int count) {
    double scale = 2.0;
    for (int sample = 0; sample < count; ++sample) {
        total += scale * cast(double) reading;
        reading = replacement;
    }
}

float lastSequenceLevel(uint sequence, int count) {
    float level = 0;
    for (int sample = 0; sample < count; ++sample) {
        level = cast(float) sequence;
        sequence += 2;
    }
    return level;
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

double recordScore(double score) {
    assert(score >= 0);
    return score;
}

double reconcileChannels(int slots, int gain, int shift, int pivot,
        double bias, int request) {
    const ticket = request ^ 45;
    double score = 0;
    for (; slots > 0; --slots) {
        const sample = slots + gain;
        int count = shift;
        if (slots > pivot)
            count += 2;
        const shifted = sample << count;
        const corrected = shifted ^ sample;
        score += 2.0 * cast(double) corrected + bias;
    }
    return recordScore(score) + ticket;
}

long weighReadings(ref long weight, long adjustment, int count) {
    long total;
    for (int sample; sample < count; ++sample) {
        total += adjustment * weight;
        weight += 3;
    }
    return total;
}

long advanceCounter(long current, long stride, int count) {
    for (int sample; sample < count; ++sample)
        current = current * 3 + stride;
    return current;
}

long retainUpdate(ref long current, const(long)* offset, int count) {
    for (int step; step < count; ++step)
        current += *offset;
    return current;
}

long retainScaling(ref long current, const(long)* factor, int count) {
    for (int step; step < count; ++step)
        current *= *factor;
    return current;
}

int sumMaskedReadings(int reading, int firstBit, int count, int adjustment) {
    int total;
    for (int sample = 0; sample < count; ++sample) {
        const marker = 1 << (firstBit + (sample & 3));
        total += (reading ^ marker) + adjustment;
    }
    return total;
}

int main() {
    const channel = ChannelSpan(0, 0.5, 4.0, 2.0);
    auto calibrate = &calibratedTotal;
    assert(calibrate(channel, 400, -1, -1, 7) == 81_800);
    assert(calibrate(channel, 400, -1, -1, 7) == 81_800);
    assert(calibrate(channel, 400, 3, 4, 7) == 81_405);
    assert(calibrate(channel, 0, -1, -1, 7) == 0);

    auto decodeDeltas = &decodeLevels!short;
    auto decodeMagnitudes = &decodeLevels!ushort;
    auto decodeSequenceNumbers = &decodeSequences;
    auto calibrateLevel = &calibrationResidual;
    auto convertSequence = &lastSequenceLevel;
    auto accumulate = &accumulateReadings;
    assert(decodeDeltas(-513, 3, 300) == -19_800.0f);
    assert(decodeDeltas(-513, 0, 1) == -514.0f);
    assert(decodeMagnitudes(0x9002, 3, 300) == 691_200.0f);
    assert(decodeMagnitudes(0x9002, 0, 1) == 18_432.0f);
    assert(decodeSequenceNumbers(uint.max, 3, 300) == 805_306_367_100.0);
    assert(decodeSequenceNumbers(uint.max, 0, 1) == 6_442_450_941.0);
    assert(calibrateLevel(short.min, ushort.max, 300) == -300.0f);
    assert(convertSequence(16_777_217, 300) == 16_777_816.0f);
    assert(convertSequence(16_777_215, 1) == 16_777_215.0f);

    int reading = -19;
    double total = 0;
    accumulate(total, reading, 13, 305);
    assert(total == 7_866.0);
    assert(reading == 13);

    reading = int.min;
    total = 0;
    accumulate(total, reading, int.max, 2);
    assert(total == -2.0);
    assert(reading == int.max);

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

    auto reconcile = &reconcileChannels;
    foreach (_; 0 .. 3) {
        assert(reconcile(512, -18, 4, 193, -2, 19) == 14_198_814);
        assert(reconcile(513, 6, 8, 281, 3, 19) == 213_121_615);
        assert(reconcile(0, -8, 1, 0, -3, 19) == 62);
        assert(reconcile(1, -8, 1, 0, -3, 19) == 157);
    }

    auto weigh = &weighReadings;
    auto advance = &advanceCounter;
    long weight = -10;
    assert(weigh(weight, 7, 300) == 920_850);
    assert(weight == 890);
    assert(weigh(weight, -2, 1) == -1_780);
    assert(weight == 893);
    assert(weigh(weight, 0, 0) == 0);
    assert(weight == 893);

    ulong expected = 7;
    foreach (_; 0 .. 300)
        expected = expected * 3 + 2;
    assert(advance(7, 2, 300) == cast(long) expected);
    assert(advance(-7, 2, 0) == -7);
    assert(advance(-7, 2, 1) == -19);

    auto retain = &retainUpdate;
    auto scale = &retainScaling;
    long current = 7;
    long offset = -13;
    assert(retain(current, &offset, 300) == -3_893);
    assert(current == -3_893);
    current = -2;
    assert(retain(current, &current, 5) == -64);
    assert(current == -64);
    current = -7;
    long factor = -1;
    assert(scale(current, &factor, 301) == 7);
    assert(current == 7);
    current = 2;
    assert(scale(current, &current, 3) == 256);
    assert(current == 256);

    auto sumMasked = &sumMaskedReadings;
    assert(sumMasked(171, 5, 301, 3) == 64_342);
    assert(sumMasked(9_216, 6, 305, -17) == 2_878_719);
    assert(sumMasked(171, 5, 0, 3) == 0);
    assert(sumMasked(-128, 4, 1, -5) == -117);

    return 0;
}
