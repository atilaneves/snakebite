module ut.backends.call.accessors;


import ut.backends;


// A method that only reads or only writes one field of its receiver is a
// call like any other: the receiver and the argument run in call order, and
// the field has the width of its type, so a store never touches the fields
// next to it. The fields are set from the last to the first for that reason.
static foreach (backend; Matrix!()) {
    @("accessors.scalarFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Fields {
                    int i;
                    long l;
                    double d;
                    float f;
                    short s;
                    ubyte u;
                    int getI() { return i; }
                    long getL() { return l; }
                    double getD() { return d; }
                    float getF() { return f; }
                    short getS() { return s; }
                    ubyte getU() { return u; }
                    void setI(int p) { i = p; }
                    void setL(long p) { l = p; }
                    void setD(double p) { d = p; }
                    void setF(float p) { f = p; }
                    void setS(short p) { s = p; }
                    void setU(ubyte p) { u = p; }
                }

                class Boxed {
                    int i;
                    long l;
                    double d;
                    float f;
                    int getI() { return i; }
                    long getL() { return l; }
                    double getD() { return d; }
                    float getF() { return f; }
                    void setI(int p) { i = p; }
                    void setL(long p) { l = p; }
                    void setD(double p) { d = p; }
                    void setF(float p) { f = p; }
                    final int finalI() { return i; }
                }

                int answer() {
                    Fields s;
                    s.setU(200);
                    s.setS(-300);
                    s.setF(1.5f);
                    s.setD(2.25);
                    s.setL(-(1L << 40));
                    s.setI(-5);
                    if (s.getI() != -5 || s.getL() != -(1L << 40)
                            || s.getD() != 2.25 || s.getF() != 1.5f
                            || s.getS() != -300 || s.getU() != 200)
                        return 1;
                    Fields* pointer = &s;
                    pointer.setI(9);
                    if (pointer.getI() != 9 || s.i != 9 || s.l != -(1L << 40))
                        return 2;
                    auto boxed = new Boxed;
                    boxed.setF(0.5f);
                    boxed.setD(-8.75);
                    boxed.setL(1L << 41);
                    boxed.setI(-7);
                    if (boxed.getI() != -7 || boxed.getL() != (1L << 41)
                            || boxed.getD() != -8.75 || boxed.getF() != 0.5f
                            || boxed.finalI() != -7)
                        return 3;
                    return 42;
                }
            },
            "answer",
        );
    }
}


// One call site meets classes that read the field it names, one that reads
// another field and one that does not read a field at all: the site follows
// the vtable of each receiver.
static foreach (backend; Matrix!()) {
    @("accessors.virtualSite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                class Base {
                    int f = 1;
                    int get() { return f; }
                }

                class Sibling : Base {
                    int g = 20;
                    override int get() { return g; }
                }

                class Computing : Base {
                    override int get() { return f + 300; }
                }

                int read(Base b) {
                    return b.get();
                }

                int answer() {
                    Base[4] all = [
                        new Base, new Sibling, new Computing, new Base,
                    ];
                    int sum;
                    foreach (round; 0 .. 3)
                        foreach (b; all)
                            sum += read(b);
                    return sum == 3 * (1 + 20 + 301 + 1) ? 42 : sum;
                }
            },
            "answer",
        );
    }
}


// The receiver runs before the argument, each once, for a setter and for a
// getter, on a struct and on a class.
static foreach (backend; Matrix!()) {
    @("accessors.effectsRunInCallOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct S {
                    int f;
                    void set(int p) { f = p; }
                    int get() { return f; }
                }

                class C {
                    int f;
                    void set(int p) { f = p; }
                    int get() { return f; }
                }

                S* pickS(S* s, ref int trace) {
                    trace = trace * 10 + 1;
                    return s;
                }

                C pickC(C c, ref int trace) {
                    trace = trace * 10 + 1;
                    return c;
                }

                int argument(int v, ref int trace) {
                    trace = trace * 10 + 2;
                    return v;
                }

                int answer() {
                    S s;
                    auto c = new C;
                    int trace;
                    pickS(&s, trace).set(argument(5, trace));
                    if (trace != 12 || s.f != 5)
                        return 1;
                    trace = 0;
                    pickC(c, trace).set(argument(6, trace));
                    if (trace != 12 || c.f != 6)
                        return 2;
                    trace = 0;
                    const read = pickS(&s, trace).get() + argument(0, trace);
                    if (trace != 12 || read != 5)
                        return 3;
                    trace = 0;
                    const readClass = pickC(c, trace).get() + argument(0, trace);
                    if (trace != 12 || readClass != 6)
                        return 4;
                    return 42;
                }
            },
            "answer",
        );
    }
}


// A function whose body is one `return` is called again while its caller
// still evaluates the arguments of the same call, and many levels deep.
static foreach (backend; Matrix!()) {
    @("accessors.recursionThroughOneReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int ack(int m, int n) {
                    return m == 0 ? n + 1
                        : n == 0 ? ack(m - 1, 1)
                        : ack(m - 1, ack(m, n - 1));
                }

                double half(double x, int n) {
                    return n == 0 ? x : half(x / 2, n - 1);
                }

                int depth(int n) {
                    return n == 0 ? 0 : 1 + depth(n - 1);
                }

                int answer() {
                    if (ack(2, 3) != 9)
                        return 1;
                    if (half(1024.0, 3) != 128.0)
                        return 2;
                    if (depth(400) != 400)
                        return 3;
                    return 42;
                }
            },
            "answer",
        );
    }
}


// An exception thrown inside a function whose body is one `return` leaves
// no frame behind: the calls after the catch give the right values, and a
// destructor of the caller runs once.
static foreach (backend; Matrix!()) {
    @("accessors.exceptionThroughOneReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int* destroyed;
                    ~this() {
                        ++*destroyed;
                    }
                }

                int fail() {
                    throw new Exception("negative");
                }

                int pick(int v) {
                    return v > 0 ? v : fail();
                }

                int outer(int v) {
                    return pick(v) + 1;
                }

                int answer() {
                    int destroyed;
                    int caught;
                    foreach (round; 0 .. 3) {
                        try {
                            auto counter = Counter(&destroyed);
                            outer(3);
                            outer(-round);
                        } catch (Exception e) {
                            ++caught;
                        }
                    }
                    if (caught != 3 || destroyed != 3)
                        return 1;
                    if (outer(5) != 6 || pick(7) != 7)
                        return 2;
                    return 42;
                }
            },
            "answer",
        );
    }
}


// A getter of a pointer or of a class reference gives the field as an
// unsigned word, and a setter stores one: the values keep their address.
static foreach (backend; Matrix!()) {
    @("accessors.pointerAndReferenceFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                class Target {
                    int value;
                }

                struct Holder {
                    int* pointer;
                    Target target;
                    int* getPointer() { return pointer; }
                    Target getTarget() { return target; }
                    void setPointer(int* p) { pointer = p; }
                    void setTarget(Target t) { target = t; }
                }

                class Owner {
                    int* pointer;
                    Target target;
                    int* getPointer() { return pointer; }
                    Target getTarget() { return target; }
                }

                int answer() {
                    int number = 7;
                    auto target = new Target;
                    target.value = 35;
                    Holder holder;
                    holder.setPointer(&number);
                    holder.setTarget(target);
                    if (holder.getPointer() !is &number || *holder.getPointer() != 7)
                        return 1;
                    if (holder.getTarget() !is target || holder.getTarget().value != 35)
                        return 2;
                    auto owner = new Owner;
                    owner.pointer = &number;
                    owner.target = target;
                    if (owner.getPointer() !is &number || owner.getTarget() !is target)
                        return 3;
                    Holder empty;
                    if (empty.getPointer() !is null || empty.getTarget() !is null)
                        return 4;
                    return *holder.getPointer() + holder.getTarget().value;
                }
            },
            "answer",
        );
    }
}


// A function of several statements, or with no result, is called with each
// kind of result: an integer, a floating point value, a dynamic array and
// none. The call runs again inside its own arguments and through a virtual
// site that meets two classes, and an exception leaves no frame behind.
static foreach (backend; Matrix!()) {
    @("accessors.plainCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int twice(int v) {
                    const doubled = v * 2;
                    return doubled;
                }

                double scaled(double x, int n) {
                    double r = x;
                    foreach (i; 0 .. n)
                        r *= 2;
                    return r;
                }

                int[] firstTwo(int[] values) {
                    const n = values.length < 2 ? values.length : 2;
                    return values[0 .. n];
                }

                void accumulate(ref int total, int v) {
                    const doubled = v * 2;
                    total += doubled;
                }

                int accumulated(ref int total, int v) {
                    accumulate(total, v);
                    return v;
                }

                int nested(int v) {
                    const inner = v > 0 ? nested(v - 1) : 0;
                    return inner + v;
                }

                int boom(int v) {
                    if (v > 2)
                        throw new Exception("big");
                    return v;
                }

                struct Pair {
                    int a, b;
                    void swap() {
                        const t = a;
                        a = b;
                        b = t;
                    }
                    int sum() {
                        const s = a + b;
                        return s;
                    }
                }

                class Base {
                    int base = 1;
                    int get() {
                        const r = base;
                        return r;
                    }
                }

                class Derived : Base {
                    override int get() {
                        const r = base + 10;
                        return r;
                    }
                }

                int viaBase(Base b) {
                    return b.get();
                }

                int answer() {
                    if (twice(twice(3)) != 12)
                        return 1;
                    if (scaled(scaled(1.5, 1), 2) != 12.0)
                        return 2;
                    auto data = [1, 2, 3];
                    if (firstTwo(firstTwo(data)).length != 2
                            || firstTwo(data)[1] != 2)
                        return 3;
                    int total;
                    accumulate(total, accumulated(total, 4));
                    if (total != 8 + 8)
                        return 4;
                    if (nested(5) != 15)
                        return 5;
                    int caught;
                    foreach (v; 0 .. 5) {
                        try {
                            boom(v);
                        } catch (Exception) {
                            ++caught;
                        }
                    }
                    if (caught != 2 || boom(1) != 1)
                        return 6;
                    auto pair = Pair(1, 2);
                    pair.swap();
                    if (pair.a != 2 || pair.b != 1 || pair.sum() != 3)
                        return 7;
                    Base[2] both = [new Base, new Derived];
                    int sum;
                    foreach (round; 0 .. 2)
                        foreach (b; both)
                            sum += viaBase(b);
                    if (sum != 2 * (1 + 11))
                        return 8;
                    return 26 + total;
                }
            },
            "answer",
        );
    }
}


// The one callee of an accessor site is known when the site is built: the
// site runs again inside its own receiver and its own argument, and the
// accessors of a final class method and of a struct reached by pointer or by
// value give the same results.
static foreach (backend; Matrix!()) {
    @("accessors.reenteredSite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Link {
                    Link* next;
                    int value;
                    Link* getNext() { return next; }
                    int getValue() { return value; }
                    void setValue(int v) { value = v; }
                }

                final class Cell {
                    int value;
                    final int getValue() { return value; }
                    final void setValue(int v) { value = v; }
                }

                int sum(Link* link) {
                    return link is null ? 0
                        : link.getValue() + sum(link.getNext());
                }

                int viaReceiver(Link* link, int depth) {
                    return (depth == 0 ? link : link.getNext()).getValue()
                        + (depth == 0 ? 0 : viaReceiver(link.getNext(), depth - 1));
                }

                int viaArgument(Link* link, int depth) {
                    link.setValue(depth == 0 ? 1 : viaArgument(link, depth - 1) + 1);
                    return link.getValue();
                }

                int answer() {
                    Link[3] links;
                    foreach (i; 0 .. 3) {
                        links[i].setValue(i + 1);
                        if (i < 2)
                            links[i].next = &links[i + 1];
                    }
                    if (sum(&links[0]) != 6)
                        return 1;
                    if (viaReceiver(&links[0], 2) != 2 + 3 + 3)
                        return 2;
                    if (viaArgument(&links[0], 4) != 5 || links[0].value != 5)
                        return 3;
                    auto cell = new Cell;
                    cell.setValue(cell.getValue() + 20);
                    cell.setValue(cell.getValue() + 17);
                    return cell.getValue() + (links[2].getValue() == 3 ? 5 : 0);
                }
            },
            "answer",
        );
    }
}
