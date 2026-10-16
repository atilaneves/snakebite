module ut.backends.call.window;


import ut.backends;


// A direct call to a compiled function writes each argument straight into the
// parameter slot of the callee, with no copy when the call runs. These tests
// pin the rules that make that safe. Callees are long enough that they are
// never copied into the caller.

// Values the callee frames of one call must not overwrite: the temporaries
// of an expression that are live across the calls.
static foreach (backend; Matrix!()) {
    @("window.callee.doesNotOverwriteTemporariesOfCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long wide(long a, long b, long c) {
                long p0 = a + 1; long p1 = b + 2; long p2 = c + 3;
                long p3 = p0 * p1; long p4 = p1 * p2; long p5 = p2 * p0;
                long p6 = p3 + p4; long p7 = p4 + p5; long p8 = p5 + p3;
                return p6 + p7 + p8 + p0 + p1 + p2;
            }

            void main() {
                long t1 = 11, t2 = 22;
                const result = (t1 * 3 + t2 * 5) * wide(t1, t2, 3)
                    + (t1 - t2) * wide(1, 2, 3)
                    + (t1 + 100) * (t2 + 200);
                assert(result == 173692);
            }
        });
    }
}


// The receiver goes to the `this` slot of the callee like any argument: it
// can be a local, the result of another call, an element or the receiver
// of the caller itself.
static foreach (backend; Matrix!()) {
    @("window.receiver.reachesCalleeFromEveryKindOfSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                long total;
                long step;
                long add(long a, long b) {
                    long x = a * step; long y = b * step; long z = x + y;
                    total += z; long w = total * 2; long v = w - z;
                    return v + z + total;
                }
            }
            class Box {
                long value;
                this(long v) { value = v; }
                long scaled(long by, long plus) {
                    long a = value * by; long b = a + plus; long c = b * 2;
                    long d = c - a; long e = d + by;
                    return e + value;
                }
                Box next() { return new Box(value + 1); }
            }
            Counter makeCounter(long step) {
                Counter c;
                c.step = step;
                c.total = 1;
                return c;
            }
            Box makeBox(long v) { return new Box(v); }

            void main() {
                auto c = makeCounter(3);
                assert(c.add(1, 2) == 30);
                assert(c.total == 10);
                assert(makeBox(5).scaled(3, 4) == 31);
                assert(makeBox(2).next().scaled(2, 1) == 13);
                assert(makeBox(1).next().next().next()
                    .scaled(makeBox(2).value, 9) == 32);
                Box[3] boxes = [new Box(1), new Box(2), new Box(3)];
                assert(boxes[2].scaled(boxes[1].scaled(1, 1),
                    boxes[0].scaled(2, 2)) == 49);
                assert(makeCounter(2).add(makeCounter(3).add(1, 1), 5) == 159);
            }
        });
    }
}


// A call among the arguments of a call runs while the earlier arguments of
// the outer call are already in place, and must not overwrite them.
static foreach (backend; Matrix!()) {
    @("window.arguments.nestedCallsKeepEarlierArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long weigh(long a, long b, long c, long d) {
                long p = a * 1 + b * 10; long q = c * 100 + d * 1000;
                long r = p + q; long s = r * 3; long t = s - p; long u = t + q;
                return u + a;
            }
            long g1(long x) {
                long a = x * 2; long b = a + 1; long c = b * 3;
                long d = c - x; long e = d + a;
                return e + 1;
            }
            long g2(long x, long y) {
                long a = x * 5; long b = y * 7; long c = a + b;
                long d = c * 2; long e = d - x;
                return e + y;
            }
            long g3(long x) {
                long a = x + 11; long b = a * 2; long c = b + a;
                long d = c - 3; long e = d * 2;
                return e;
            }

            void main() {
                assert(weigh(1, g1(2), g2(3, g3(4)), g2(g1(5), g3(g1(6))))
                    == 22079163);
                assert(weigh(g1(g1(g1(1))), g2(g2(1, 2), g2(3, 4)), 5,
                    g3(g2(g3(1), g1(2)))) == 21012833);
            }
        });
    }
}


// The callee reads the old value of the destination of its own result, by a
// pointer or a reference, until it returns. The result lands in the
// destination after that and only then.
static foreach (backend; Matrix!()) {
    @("window.result.waitsForCalleeToFinishReadingDestination." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long readTwice(long* cell, long n) {
                long a = *cell * 2; long b = a + n; *cell = 7;
                long c = *cell + b; long d = c * 2; long e = d - a;
                return e + *cell;
            }
            long bump(long* p, long by) {
                long before = *p; long a = before + by; *p = a;
                long b = *p + before; long c = b * 2; long d = c - a;
                return d + *p;
            }
            struct Pair { long a; long b; }
            Pair swapped(ref Pair p, long x) {
                Pair r = Pair(p.b + x, p.a + x);
                p.a = 100; p.b = 200;
                long y = r.a + r.b;
                r.a = y;
                return r;
            }

            void main() {
                long cell = 3;
                cell = readTwice(&cell, 10);
                assert(cell == 47);
                long x = 5;
                x = bump(&x, 5);
                assert(x == 30);
                Pair p = Pair(1, 2);
                p = swapped(p, 10);
                assert(p.a == 23 && p.b == 11);
                x = 1;
                bump(&x, 1);
                bump(&x, 2);
                assert(x == 4);
            }
        });
    }
}


// A throw from a callee, after the arguments of a nested call were in place,
// leaves the caller with the values it had.
static foreach (backend; Matrix!()) {
    @("window.exception.fromCalleeKeepsValuesOfCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long inner(long a, long b) {
                long x = a * 3; long y = b * 5; long z = x + y;
                if (z > 0)
                    throw new Exception("inner");
                return z;
            }
            long outer(long a, long b) {
                long x = a + 1; long y = inner(b, x + 2) + x;
                return y;
            }
            long after(long a, long b, long c) {
                long x = a * 2; long y = b * 3; long z = c * 4;
                long u = x + y; long v = y + z; long w = u + v;
                return w;
            }

            // Called by pointer, so its frame is reserved the generic way,
            // above whatever the throw gave back.
            long spread(long a, long b, long c) {
                long[8] cells;
                foreach (i, ref cell; cells)
                    cell = a * i + b - c;
                long sum;
                foreach (cell; cells)
                    sum += cell;
                return sum;
            }

            void main() {
                long kept = 41;
                long local = 7;
                long caught;
                try
                    kept += outer(kept, 2) + after(1, 2, 3);
                catch (Exception thrown)
                    caught = thrown.msg.length;
                auto indirect = &spread;
                assert(indirect(1, 2, 3) == 28 + 8 * (2 - 3));
                assert(kept == 41);
                assert(local == 7);
                assert(caught == 5);
                assert(after(1, 2, 3) == 26);
            }
        });
    }
}


// A throw from a callee gives its frame back: a loop of throws does not grow
// the frame stack until it overflows.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE has no frame stack to grow, and copies each 1 MB frame array"),
)) {
    @("window.exception.loopOfThrowsDoesNotGrowFrameStack." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long grow(long n) {
                ubyte[1 << 20] frame = void;
                frame[0] = cast(ubyte) n;
                frame[$ - 1] = cast(ubyte) (n + 1);
                if (n >= 1)
                    throw new Exception("deep");
                return frame[0] + grow(n + 1) + frame[$ - 1];
            }

            void main() {
                long caught;
                foreach (i; 0 .. 700) {
                    try
                        grow(0);
                    catch (Exception thrown)
                        caught += thrown.msg.length;
                }
                assert(caught == 700 * 4);
            }
        });
    }
}


// Each level of a deep recursion has its own arguments, in memory that
// grows as the recursion goes deeper.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE stops a recursion that is 30000 calls deep"),
)) {
    @("window.recursion.deepCallsKeepTheirArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long sum(long n, long accumulated) {
                if (n == 0)
                    return accumulated;
                return sum(n - 1, accumulated + n);
            }
            long upAndDown(long n, long a, long b) {
                if (n == 0)
                    return a * 1000 + b;
                const below = upAndDown(n - 1, a + 1, b + 2);
                return below + n - a * 0;
            }

            void main() {
                assert(sum(30_000, 0) == 30_000L * 30_001 / 2);
                assert(upAndDown(10_000, 0, 0) == 10_000 * 1000 + 20_000
                    + 10_000L * 10_001 / 2);
            }
        });
    }
}
