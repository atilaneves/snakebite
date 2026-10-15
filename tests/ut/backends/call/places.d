module ut.backends.call.places;


import ut.backends;


// A field, a dereference and an array length are read where they are, as
// operands of the instruction that uses them. Each operand differs from
// the others, so reading the wrong object or offset gives another sum.
static foreach (backend; Matrix!()) {
    @("places.read.fieldOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Inner { int a; long b; }
                struct Outer { int x; Inner inner; Outer* next; }
                class Box { int count; long wide; Box next; }

                long operands(ref Outer r, Outer* p, Box b) {
                    Outer local = Outer(3, Inner(4, 5), null);
                    long sum = local.x + local.inner.a;
                    sum += r.x * 2 + r.inner.b;
                    sum += p.inner.a + (*p).x;
                    sum += b.count + b.next.count * 10 + b.wide;
                    if (local.inner.b < r.inner.b) sum += 1000;
                    if (b.next !is null && b.next.next is null) sum += 10000;
                    return sum;
                }

                bool check() {
                    Outer base = Outer(10, Inner(20, 30), null);
                    Outer other = Outer(7, Inner(8, 9), &base);
                    auto b = new Box;
                    b.count = 1;
                    b.wide = 2;
                    b.next = new Box;
                    b.next.count = 3;
                    return operands(other, &base, b) == 11093;
                }
            },
            "check",
        );
    }
}

// `p.x` is read before `change` replaces `p`, as D evaluates the operands of
// `+` from left to right.
static foreach (backend; Matrix!()) {
    @("places.read.pointerChangedByLaterCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1012.shouldBeRetOf!(
            backend,
            q{
                struct Outer { int x; }

                int change(Outer** where, Outer* other) {
                    *where = other;
                    return 100;
                }

                int run() {
                    Outer a = Outer(1);
                    Outer b = Outer(2);
                    Outer* p = &a;
                    const first = p.x + change(&p, &b);
                    const second = p.x;
                    return first * 10 + second;
                }
            },
            "run",
        );
    }
}

// `n = n.next` reads the field before it writes `n`.
static foreach (backend; Matrix!()) {
    @("places.read.walkList." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int count;
                    Counter* next;

                    int total() {
                        int sum = count;
                        for (auto n = next; n !is null; n = n.next)
                            sum += n.count;
                        return sum + (*next).count;
                    }
                }

                class Cell {
                    int count = 5;
                    Cell next;

                    int walk() {
                        int steps;
                        for (Cell c = this; c !is null; c = c.next)
                            steps += c.count + count;
                        return steps;
                    }
                }

                bool check() {
                    Counter c3 = Counter(3, null);
                    Counter c2 = Counter(2, &c3);
                    Counter c1 = Counter(1, &c2);
                    auto cell = new Cell;
                    cell.next = new Cell;
                    cell.next.count = 9;
                    return c1.total() == 8 && cell.walk() == 24;
                }
            },
            "check",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("places.read.arrayLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Holder { int[] list; }

                int operands(int[] items, ref int[] other) {
                    Holder h = Holder([1, 2, 3, 4]);
                    int sum;
                    for (int i = 0; i < items.length; ++i)
                        sum += i;
                    if (h.list.length > items.length) sum += 100;
                    if (other.length == 2) sum += 1000;
                    return sum + cast(int) (items.length + h.list.length * 7);
                }

                bool check() {
                    int[] other = [5, 6];
                    return operands([7, 8, 9], other) == 1134;
                }
            },
            "check",
        );
    }
}
