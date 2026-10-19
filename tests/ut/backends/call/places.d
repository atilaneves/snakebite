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

// The store goes to the field of the pointer that `p.f` named before the
// value ran. Only dmd differs: it evaluates the value first and then loads
// `p`, so the store lands in `b`; ldc2 agrees with the guests.
private enum pointerChangedByValue = q{
    struct S { int f; }

    int swing(S** where, S* other) {
        *where = other;
        return 5;
    }

    int run() {
        S a = S(1);
        S b = S(2);
        S* p = &a;
        p.f = swing(&p, &b);
        return a.f * 100 + b.f * 10 + (p is &b ? 1 : 0);
    }
};

static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd loads the pointer after the value runs, ldc2 before - pinned below"),
)) {
    @("places.write.pointerChangedByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        521.shouldBeRetOf!(backend, pointerChangedByValue, "run");
    }
}

@("places.write.pointerChangedByValue.Native.diverges")
@Tags("Native")
unittest {
    151.shouldBeRetOf!(Native, pointerChangedByValue, "run");
}

// As above for `+=`: the target is the field of the old pointer, and it is
// read after the value ran.
private enum compoundPointerChangedByValue = q{
    struct S { int f; }

    int swing(S** where, S* other) {
        *where = other;
        return 5;
    }

    int run() {
        S a = S(1);
        S b = S(2);
        S* p = &a;
        p.f += swing(&p, &b);
        return a.f * 100 + b.f * 10 + (p is &b ? 1 : 0);
    }
};

static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd loads the pointer after the value runs, ldc2 before - pinned below"),
)) {
    @("places.write.compoundPointerChangedByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        621.shouldBeRetOf!(backend, compoundPointerChangedByValue, "run");
    }
}

@("places.write.compoundPointerChangedByValue.Native.diverges")
@Tags("Native")
unittest {
    171.shouldBeRetOf!(Native, compoundPointerChangedByValue, "run");
}

// Every kind of write to a field or a dereference, and the value of the
// assignment, compound assignment and post-increment expressions.
static foreach (backend; Matrix!()) {
    @("places.write.fieldOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Inner { int a; long b; }
                struct Outer { int x; Inner inner; double d; Outer* next; }
                class Box { int count; long wide; Box next; }

                long writes(ref Outer r, Outer* p, Box b) {
                    Outer local;
                    local.x = 3;
                    local.inner.a = local.x + 4;
                    r.x = 10;
                    r.inner.b = local.inner.a * 5;
                    p.inner.a = r.x + local.inner.a;
                    (*p).x = p.inner.a;
                    b.count = 7;
                    b.wide = b.count + r.inner.b;
                    b.next = null;
                    p.d = 1.5;
                    p.d += 2.25;
                    b.count += 5;
                    b.wide *= 3;
                    b.wide -= 1;
                    b.wide <<= 1;
                    p.inner.a++;
                    ++p.inner.a;
                    const old = b.count++;
                    const result = (p.x = 20) + (b.wide += 1)
                        + (p.inner.a -= 2);
                    return local.x + local.inner.a + r.x + r.inner.b
                        + p.inner.a + p.x + b.count + b.wide + old + result
                        + cast(long) p.d + (b.next is null ? 1000 : 0);
                }

                bool check() {
                    Outer base;
                    Outer other;
                    other.next = &base;
                    auto b = new Box;
                    b.next = new Box;
                    return writes(other, &base, b) == 1659;
                }
            },
            "check",
        );
    }
}

// The element is the one that `a[i]` named before the value ran, however
// the value changes the index or the slice.
static foreach (backend; Matrix!()) {
    @("places.write.indexChangedByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int reset(size_t* index) {
                    *index = 0;
                    return 1;
                }

                int replace(int[]* slice, int[] other) {
                    *slice = other;
                    return 9;
                }

                bool check() {
                    int[4] array = [10, 20, 30, 40];
                    size_t i = 2;
                    array[i] = reset(&i);
                    int[3] first = [1, 2, 3];
                    int[3] second = [7, 8, 9];
                    int[] slice = first[];
                    slice[1] = replace(&slice, second[]);
                    size_t j = 3;
                    array[j] += reset(&j);
                    int[] other = first[];
                    other[2] += replace(&other, second[]);
                    return array == [10, 20, 1, 41] && i == 0 && j == 0
                        && first == [1, 9, 12] && second == [7, 8, 9]
                        && slice is second[] && other is second[];
                }
            },
            "check",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("places.read.indexOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Row { int[3] cells; int[] more; }

                class Table {
                    Row[] rows;
                    ubyte* bytes;
                }

                long total(int[] numbers, Table table, size_t shift) {
                    int[4] fixed = [5, 6, 7, 8];
                    long sum;
                    for (size_t i = 0; i < numbers.length; ++i)
                        sum += numbers[i] * fixed[i % 4];
                    sum += numbers[$ - 1] + fixed[3] + numbers[0];
                    sum += table.rows[1].cells[2] + table.rows[0].more[$ - 1];
                    sum += table.bytes[0] + table.bytes[shift];
                    if (numbers[1] < fixed[1]) sum += 1000;
                    if (table.rows[1].cells[0] > numbers[2]) sum += 10000;
                    return sum;
                }

                bool check() {
                    auto table = new Table;
                    table.rows = [Row([1, 2, 3], [4, 5]),
                        Row([6, 7, 8], null)];
                    ubyte[3] bytes = [50, 60, 70];
                    table.bytes = bytes.ptr;
                    return total([3, 1, 4, 1, 5], table, 2) == 11231;
                }
            },
            "check",
        );
    }
}

// A call assigned to a local writes the local only when it returns.
static foreach (backend; Matrix!()) {
    @("places.write.callResultToLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                int twice(int value) {
                    return value * 2;
                }

                int refuse(int value) {
                    if (value > 0)
                        throw new Exception("refused");
                    return value;
                }

                bool check() {
                    int x = 3;
                    x = twice(x);
                    int y = 5;
                    try
                        y = refuse(y);
                    catch (Exception) {
                    }
                    return x == 6 && y == 5;
                }
            },
            "check",
        );
    }
}

// D evaluates the operands of an index expression from left to right, so
// `p` is read before `idx` changes it: the element comes from the old array.
// ldc reads the index first and gives 200; dmd follows the specification.
static foreach (backend; Matrix!()) {
    @("places.order.pointerIndexReadsPointerFirst." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                int idx(int** where, int* other) {
                    *where = other;
                    return 1;
                }

                int run() {
                    int[2] first = [1, 2];
                    int[2] second = [100, 200];
                    int* p = &first[0];
                    int* other = &second[0];
                    int** pp = &p;
                    int w = p[idx(pp, other)];
                    return w;
                }
            },
            "run",
        );
    }
}
