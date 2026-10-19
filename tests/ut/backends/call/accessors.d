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
