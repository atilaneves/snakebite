final class Gauge {
    ulong header;
    long weight;
    int tickets;

    void enter(int level) {
        if (level > 2) {
            const child = level - 1;
            for (int j = 2; j < level; j += 1) {
                tickets += 9;
                enter(child);
                weight += 3;
            }
        } else {
            weight += 13;
            tickets -= 4;
        }
    }
}

void checkGauge() {
    auto gauge = new Gauge;
    auto enter = &gauge.enter;
    foreach (_; 0 .. 350) {
        gauge.weight = 0;
        gauge.tickets = 0;
        enter(6);
        assert(gauge.weight == 504 && gauge.tickets == 480);
    }
    gauge.weight = 0;
    gauge.tickets = 0;
    enter(4);
    assert(gauge.weight == 38 && gauge.tickets == 28);
    gauge.weight = 0;
    gauge.tickets = 0;
    enter(2);
    assert(gauge.weight == 13 && gauge.tickets == -4);
}
