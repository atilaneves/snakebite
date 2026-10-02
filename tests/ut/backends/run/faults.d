module ut.backends.run.faults;


import ut.backends;

import snakebite.backends.guestfault: GuestFault;


// Guest code that compiled D kills with a signal - a null dereference, an
// integer division the hardware traps - is a guest fault. A backend reports
// it to the host that runs it, and the host owns what happens next: `bin/sb`
// ends the process, a REPL cell or a test here fails and the session goes
// on. These tests are in-process, so the fault comes back as an exception
// that no guest `catch` sees. Compiled D itself dies of SIGSEGV or SIGFPE,
// and so no in-process test can run it: the matrix of a fault test omits
// `Native`. Tests that need a real process (exit status, the order of
// output) are in `tests/run_cli.py` and `tests/run_repl.py`.
private alias FaultBackends = Matrix!(
    Omit!(Native, Because.diverges,
        "compiled D dies of SIGSEGV or SIGFPE, and no in-process test " ~
        "survives a signal"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a null dereference and a division by zero as errors " ~
        "of the program that it evaluates"),
);

// A null dereference is a fault at the load or the store through the
// address, not where an address is formed: native code forms `&p.field`,
// passes `*p` as a `ref` argument and calls a method through a null `p`
// without a signal.

static foreach (backend; FaultBackends) {
    @("fault.nullPointerRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    int x = *p;
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    *p = 3;
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    int x = p[1];
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerPointerToPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int** pp;
    int x = **pp;
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerStructFieldWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int a; int b; }

void main() {
    S* p;
    p.b = 3;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerStructFieldRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int a; int b; }

void main() {
    S* p;
    int x = p.b;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerCompoundAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    *p += 1;
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerPostIncrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    (*p)++;
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerFieldDecrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int a; int b; }

void main() {
    S* p;
    p.b--;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerStructAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int a; int b; }

void main() {
    S* p;
    *p = S(1, 2);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullPointerStructCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int a; int b; }

void main() {
    S* p;
    S s = *p;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullClassFieldRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int field; }

void main() {
    C c;
    int x = c.field;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullClassFieldWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int field; }

void main() {
    C c;
    c.field = 3;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullClassFieldIncrement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int field; }

void main() {
    C c;
    c.field++;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullClassBitfieldWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int bits : 3; }

void main() {
    C c;
    c.bits = 1;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullClassVirtualCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int get() { return 1; } }

void main() {
    C c;
    int x = c.get();
}
})(6);
    }
}


// The location of a fault is one decision for all backends: a call on a null
// receiver is reported at the line of the call, also when the receiver is on
// an earlier line.
static foreach (backend; FaultBackends) {
    @("fault.multiLineCallNamesTheLineOfTheCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int get() { return 1; } }

void main() {
    C c;
    auto x = c
        .get();
}
})(7);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullInterfaceCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
interface I { int get(); }

void main() {
    I i;
    int x = i.get();
}
})(6);
    }
}


// `foreach` over a class calls `opApply`, a virtual method.
static foreach (backend; FaultBackends) {
    @("fault.nullClassOpApply." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int opApply(int delegate(int) body_) { return 0; } }

void main() {
    C c;
    foreach (int x; c) {}
}
})(6);
    }
}


// The delegate of a virtual method reads the vtable of the class reference to
// name the target.
static foreach (backend; FaultBackends) {
    @("fault.nullClassVirtualMethodDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { int get() { return 1; } }

void main() {
    C c;
    auto d = &c.get;
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullInterfaceMethodDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
interface I { int get(); }

void main() {
    I i;
    auto d = &i.get;
}
})(6);
    }
}


// `typeid(c)` reads the vtable of `c`.
static foreach (backend; FaultBackends) {
    @("fault.nullClassTypeid." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    auto t = typeid(c);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullInterfaceTypeid." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
interface I { }

void main() {
    I i;
    auto t = typeid(i);
}
})(6);
    }
}


// `synchronized (c)` locks the monitor of `c`, a field of the object.
static foreach (backend; FaultBackends) {
    @("fault.nullClassSynchronized." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    synchronized (c) {}
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullFunctionPointerCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullFunctionPointer.shouldBeFaultOf!(backend, q{
void main() {
    int function() f;
    f();
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullDelegateCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDelegate.shouldBeFaultOf!(backend, q{
void main() {
    int delegate() d;
    d();
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.throwNull." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.throwNull.shouldBeFaultOf!(backend, q{
void main() {
    Throwable t;
    throw t;
}
})(4);
    }
}


// A `ref` argument is only an address: the call is no fault, and the read of
// the parameter is.
static foreach (backend; FaultBackends) {
    @("fault.nullRefParameterRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
int read(ref int value) {
    return value;
}

void main() {
    int* p;
    read(*p);
}
})(3);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullRefParameterWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void write(ref int value) {
    value = 1;
}

void main() {
    int* p;
    write(*p);
}
})(3);
    }
}


// An `out` parameter is set to its default value first, by the callee: the
// write through the null reference faults at the callee.
static foreach (backend; FaultBackends) {
    @("fault.nullOutArgumentInitialisation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void write(out int value) {
    value = 1;
}

void main() {
    int* p;
    write(*p);
}
})(2);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullRefLocalRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    ref int r = *p;
    int x = r;
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullRefResultRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
ref int target(int* p) {
    return *p;
}

void main() {
    int x = target(null);
}
})(7);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullRefResultWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
ref int target(int* p) {
    return *p;
}

void main() {
    target(null) = 1;
}
})(7);
    }
}


// A struct method receives `this` by reference: the call is no fault, and the
// read of a field is.
static foreach (backend; FaultBackends) {
    @("fault.nullStructMethodFieldRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S {
    int field;
    int get() {
        return field;
    }
}

void main() {
    S* p;
    p.get();
}
})(5);
    }
}


// A `final` method reads no vtable: the call is no fault, and the read of a
// field is.
static foreach (backend; FaultBackends) {
    @("fault.nullFinalMethodFieldRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C {
    int field;
    final int get() {
        return field;
    }
}

void main() {
    C c;
    c.get();
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerDivisionByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
int zero() { return 0; }

void main() {
    int x = 5 / zero();
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerModuloByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
int zero() { return 0; }

void main() {
    int x = 5 % zero();
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerDivisionAssignByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
int zero() { return 0; }

void main() {
    int x = 5;
    x /= zero();
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerModuloAssignByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
int zero() { return 0; }

void main() {
    int x = 5;
    x %= zero();
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.unsignedDivisionByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
uint zero() { return 0; }

void main() {
    uint x = 5 / zero();
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.unsignedModuloByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
uint zero() { return 0; }

void main() {
    uint x = 5 % zero();
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.longDivisionByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
long zero() { return 0; }

void main() {
    long x = 5 / zero();
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.byteDivisionByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
byte zero() { return 0; }

void main() {
    byte x = 5 / zero();
}
})(5);
    }
}


// `int.min / -1` has no `int` quotient: the hardware traps.
static foreach (backend; FaultBackends) {
    @("fault.integerDivisionOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
int smallest() { return int.min; }
int minusOne() { return -1; }

void main() {
    int x = smallest() / minusOne();
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerModuloOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
int smallest() { return int.min; }
int minusOne() { return -1; }

void main() {
    int x = smallest() % minusOne();
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerDivisionAssignOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
int smallest() { return int.min; }
int minusOne() { return -1; }

void main() {
    int x = smallest();
    x /= minusOne();
}
})(7);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.integerModuloAssignOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
int smallest() { return int.min; }
int minusOne() { return -1; }

void main() {
    int x = smallest();
    x %= minusOne();
}
})(7);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.longDivisionOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
long smallest() { return long.min; }
long minusOne() { return -1; }

void main() {
    long x = smallest() / minusOne();
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.longModuloOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
long smallest() { return long.min; }
long minusOne() { return -1; }

void main() {
    long x = smallest() % minusOne();
}
})(6);
    }
}


// dmd gives a division the location of its operator.
static foreach (backend; FaultBackends) {
    @("fault.multiLineDivisionNamesTheOperator." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
int zero() { return 0; }

void main() {
    int x = 5
        / zero();
}
})(6);
    }
}


// An array operation divides element by element: a zero element is the same
// hardware trap as a scalar division by zero, and the fault is at the
// statement that has the operation.
static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisionByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 0];
    int[2] c;
    c[] = a[] / b[];
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisionAssignByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 0];
    a[] /= b[1];
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationModuloByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 0];
    int[2] c;
    c[] = a[] % b[];
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisionOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, int.min];
    int[] b = [2, -1];
    int[2] c;
    c[] = a[] / b[];
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationNestedDivisionByZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 0];
    int[2] c;
    c[] = a[] + 1 + a[] / b[];
}
})(6);
    }
}

// An operand of the division can be the result of another operation of the
// same statement: its elements are computed to see the divisor.
static foreach (backend; FaultBackends) {
    @("fault.arrayOperationIntermediateDivisorIsZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 1];
    int[2] c;
    c[] = a[] / (b[] - 1);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationModuloByAnIntermediateZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 1];
    int[2] c;
    c[] = a[] % (b[] - 1);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationIntermediateDividendOverflows." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionOverflow.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [int.min + 4, 6];
    int[] b = [2, 1];
    int[2] c;
    c[] = (a[] - 4) / (b[] - 3);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationNegatedDivisorIsZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [4, 6];
    int[] b = [2, 0];
    int[2] c;
    c[] = a[] / -b[];
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationOfBytesDividesAsInts." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    byte[] a = [4, 6];
    byte[] b = [2, 0];
    byte[2] c;
    c[] = a[] / b[];
}
})(6);
    }
}


// `byte.min / -1` divides the promoted `int` operands, and `128` fits.
static foreach (backend; Matrix!()) {
    @("fault.arrayOperationOfSmallestByteDividedByMinusOneIsNotAnOverflow."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            byte[] a = [byte.min, 6];
            byte[] b = [-1, 1];
            byte[2] c;
            c[] = a[] / b[];
            return c[0] == byte.min ? 0 : 1;
        }
        });
    }
}


// The divisor can be the result of any operation of the statement.
static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisorMadeByAnd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6, 4];
    int[] b = [2, 1, 0];
    int[3] c;
    c[] = a[] / (b[] & 1);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisorMadeByXor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6, 4];
    int[] b = [2, 1, 0];
    int[3] c;
    c[] = a[] / (b[] ^ 2);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisorMadeByOr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6, 4];
    int[] b = [2, 1, 0];
    int[3] c;
    c[] = a[] % (b[] | 0);
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationDivisorMadeByPower." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6, 4];
    int[] b = [2, 1, 0];
    int[3] c;
    c[] = a[] / (b[] ^^ 2);
}
})(6);
    }
}


// An array operation reads each element of its operands and writes each
// element of its result: a slice of a null pointer is a null dereference.
static foreach (backend; FaultBackends) {
    @("fault.arrayOperationOnANullSliceOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6];
    int* p;
    int[2] c;
    c[] = a[] + p[0 .. 2];
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationOnANullSliceOfADivisor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6];
    int* p;
    int[2] c;
    c[] = a[] / p[0 .. 2];
}
})(6);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.arrayOperationOnANullSliceResult." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int[] a = [8, 6];
    int* p;
    p[0 .. 2][] = a[] + 1;
}
})(5);
    }
}


// An operand of another length is the error of the array operation itself,
// before any element is read.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot slice a null pointer"),
)) {
    @("fault.arrayOperationOfANullSliceOfAnotherLengthIsALengthError."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            int[] a = [8, 6, 4];
            int* p;
            int[3] c;
            try {
                c[] = a[] + p[0 .. 2];
            } catch (Error) {
                return 0;
            }
            return 1;
        }
        });
    }
}


// `x ^^ n` of integers divides by zero for a base of zero and a negative
// exponent.
static foreach (backend; FaultBackends) {
    @("fault.integerPowerOfZeroToANegativeExponent." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
int zero() { return 0; }

void main() {
    auto x = zero() ^^ (zero() - 1);
}
})(5);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.longPowerOfZeroToANegativeExponent." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.divisionByZero.shouldBeFaultOf!(backend, q{
long zero() { return 0; }

void main() {
    auto x = zero() ^^ (zero() - 1);
}
})(5);
    }
}


// `p.length = n` and `*p ~= x` write the array that `p` points to.
static foreach (backend; FaultBackends) {
    @("fault.lengthAssignmentThroughANullPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int[]* p;
    p.length = 3;
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.appendThroughANullPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    string* p;
    *p ~= 'c';
}
})(4);
    }
}


// A `ref` argument is an address: `f(*p)` reads no memory, as `&*p` does not.
// Compiled D makes the call; only a use of the parameter faults.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.refArgumentThroughNullPointerIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        size_t addressOf(ref int value) { return cast(size_t) &value; }

        int main() {
            int* p;
            return addressOf(*p) == 0 ? 0 : 1;
        }
        });
    }
}


// The same for a field behind a null pointer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.refArgumentThroughNullFieldIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        struct S { int a; int b; }

        size_t addressOf(ref int value) { return cast(size_t) &value; }

        int main() {
            S* s;
            return addressOf(s.b) == 4 ? 0 : 1;
        }
        });
    }
}


// The same for an element of a null pointer.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.refArgumentThroughNullElementIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        size_t addressOf(ref int value) { return cast(size_t) &value; }

        int main() {
            int* p;
            return addressOf(p[2]) == 8 ? 0 : 1;
        }
        });
    }
}


// A `ref` local is an address too: `ref int r = *p;` reads no memory.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.refLocalThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            int* p;
            ref int r = *p;
            return cast(size_t) &r == 0 ? 0 : 1;
        }
        });
    }
}


// A `ref` return is an address too: `return *p;` reads no memory.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.refReturnThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        ref int target(int* p) { return *p; }

        int main() {
            int* p;
            return &target(p) is null ? 0 : 1;
        }
        });
    }
}


// A slice of a static array field is the address of the field and its length:
// `p.elements[]` reads no memory.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.staticArraySliceThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        struct S { int first; int[4] elements; }

        int main() {
            S* p;
            auto slice = p.elements[];
            return cast(size_t) slice.ptr == 4 && slice.length == 4 ? 0 : 1;
        }
        });
    }
}


// A struct method receives `this` by reference: the call through a null
// pointer reads no memory. Compiled D runs the method; only a use of a field
// faults.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.structMethodThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        struct S {
            int field;
            bool isNull() { return &this is null; }
        }

        int main() {
            S* p;
            return p.isNull() ? 0 : 1;
        }
        });
    }
}


// A `final` method call reads no vtable: compiled D runs the method with a
// null `this`; only a use of a field faults.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a method call on a null class reference"),
)) {
    @("fault.finalMethodOnNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class C {
            int field;
            final bool isNull() { return this is null; }
        }

        int main() {
            C c;
            return c.isNull() ? 0 : 1;
        }
        });
    }
}


// `&e` forms an address and reads no memory: the classic `offsetof` through a
// null pointer is no fault.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects the address of a field behind a null pointer as a " ~
        "dereference of a null pointer"),
)) {
    @("fault.addressOfStructFieldThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        struct S { int a; int b; }

        int main() {
            return cast(size_t) &(cast(S*) null).b == 4 ? 0 : 1;
        }
        });
    }
}


// The address of an element of a null pointer reads no memory.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects a dereference of a null pointer"),
)) {
    @("fault.addressOfPointerElementThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        struct S { int a; int b; }

        int main() {
            S* p;
            return cast(size_t) &p[1] == S.sizeof ? 0 : 1;
        }
        });
    }
}


// The address of a field of a null class reference reads no memory.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE rejects the address of a field of a null class reference: " ~
        "the class is `null` and cannot be dereferenced"),
)) {
    @("fault.addressOfClassFieldThroughNullIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class C { int first; int second; }

        int main() {
            C c;
            return cast(size_t) &c.second == C.second.offsetof ? 0 : 1;
        }
        });
    }
}


// `a /= b` on a `byte` divides the promoted `int` operands: `-128 / -1` is
// `128`, which fits in an `int`, and the assignment truncates it. The
// hardware does not trap, so this is no fault.
static foreach (backend; Matrix!()) {
    @("fault.narrowDivideAssignIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        byte lowest() { return byte.min; }
        byte minusOne() { return -1; }

        int main() {
            byte value = lowest();
            value /= minusOne();
            return value == byte.min ? 0 : 1;
        }
        });
    }
}


// `a /= b` with an `int` target and a `long` divisor divides as `long`:
// `int.min / -1L` is `2147483648L`, which fits. No fault.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects `int.min /= -1L` as an integer overflow"),
)) {
    @("fault.wideDivisorDivideAssignIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int lowest() { return int.min; }
        long minusOne() { return -1; }

        int main() {
            int value = lowest();
            value /= minusOne();
            return value == int.min ? 0 : 1;
        }
        });
    }
}


// `byte.min / -1` divides the promoted `int` operands, and `128` fits.
static foreach (backend; Matrix!()) {
    @("fault.narrowDivisionIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        byte lowest() { return byte.min; }
        byte minusOne() { return -1; }

        int main() {
            return lowest() / minusOne() == 128 ? 0 : 1;
        }
        });
    }
}


// `short.min / -1` divides the promoted `int` operands, and `32768` fits.
static foreach (backend; Matrix!()) {
    @("fault.narrowShortDivisionIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        short lowest() { return short.min; }
        short minusOne() { return -1; }

        int main() {
            return lowest() / minusOne() == 32768 ? 0 : 1;
        }
        });
    }
}


// `int.min / -1L` divides as `long`, and `2147483648L` fits.
static foreach (backend; Matrix!()) {
    @("fault.wideDivisorDivisionIsNotAnOverflow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int lowest() { return int.min; }
        long minusOne() { return -1; }

        int main() {
            return lowest() / minusOne() == 2147483648L ? 0 : 1;
        }
        });
    }
}


// A floating point remainder by zero is `nan`, not a trap.
static foreach (backend; Matrix!()) {
    @("fault.floatingModuloByZeroIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        double zero() { return 0; }

        int main() {
            const remainder = 1.0 % zero();
            return remainder != remainder ? 0 : 1;
        }
        });
    }
}


// A slice of no elements of a null pointer reads no memory.
static foreach (backend; Matrix!()) {
    @("fault.emptySliceOfNullPointerIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            int* p;
            auto slice = p[0 .. 0];
            return slice.length == 0 ? 0 : 1;
        }
        });
    }
}


// A null associative array has no key.
static foreach (backend; Matrix!()) {
    @("fault.nullAssociativeArrayLookupIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            int[int] aa;
            return (1 in aa) is null ? 0 : 1;
        }
        });
    }
}


// A null associative array is an empty one.
static foreach (backend; Matrix!()) {
    @("fault.nullAssociativeArrayLengthIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            int[int] aa;
            return aa.length == 0 ? 0 : 1;
        }
        });
    }
}


// A floating point division by zero is `inf`, not a trap.
static foreach (backend; Matrix!()) {
    @("fault.floatingDivisionByZeroIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        double zero() { return 0; }

        int main() {
            const quotient = 1.0 / zero();
            return quotient == double.infinity ? 0 : 1;
        }
        });
    }
}


// A cast of a null class reference reads no vtable: the result is null.
static foreach (backend; Matrix!()) {
    @("fault.castNullClassReferenceIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class Base { }
        class Derived: Base { }

        int main() {
            Base b;
            return cast(Derived) b is null ? 0 : 1;
        }
        });
    }
}


// `==` on class references compares null first, and reads no vtable.
static foreach (backend; Matrix!()) {
    @("fault.nullClassReferenceEqualityIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class C { }

        int main() {
            C a;
            C b = new C;
            return a == b || b == a ? 1 : 0;
        }
        });
    }
}


// `destroy` of a null class reference does nothing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert the reference that `destroy` takes, `&C`, to " ~
        "`void**`"),
)) {
    @("fault.destroyNullClassReferenceIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class C { }

        int main() {
            C c;
            destroy(c);
            return 0;
        }
        });
    }
}


// The fault belongs to the host: no guest `catch` sees it, `Throwable`
// included, as no guest sees a signal.
static foreach (backend; FaultBackends) {
    @("fault.guestCatchDoesNotSeeTheFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        guestFaultOf!(backend, q{
void main() {
    int* p;
    try {
        *p = 1;
    } catch (Throwable) {
        return;
    }
}
}).kind.should == GuestFault.Kind.nullPointer;
    }
}


// The host gets the guest functions that run at the fault, innermost first:
// the user sees which call led to it.
static foreach (backend; FaultBackends) {
    @("fault.stackNamesTheGuestFunctions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const fault = guestFaultOf!(backend, q{
int target(int* p) {
    return *p;
}

void main() {
    target(null);
}
});
        fault.stack.length.should == 2;
        "target".should.be in fault.stack[0].function_;
        fault.stack[0].line.should == 2;
        "main".should.be in fault.stack[1].function_;
        fault.stack[1].line.should == 6;
    }
}


// `c.classinfo` reads the vtable of `c`, as `typeid(c)` does.
static foreach (backend; FaultBackends) {
    @("fault.nullClassClassinfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    auto info = c.classinfo;
}
})(6);
    }
}


// `c.__vptr` reads the first word of the object.
static foreach (backend; FaultBackends) {
    @("fault.nullClassVptr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    auto table = c.__vptr;
}
})(6);
    }
}


// A destructor that `destroy` runs is called by druntime, which handles
// each `Exception` of a destructor. A fault is not an exception of the
// guest: no guest `catch` sees it on that path too.
static foreach (backend; FaultBackends) {
    @("fault.guestCatchDoesNotSeeTheFaultOfADestructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        guestFaultOf!(backend, q{
class C {
    int* p;
    ~this() { *p = 1; }
}

void main() {
    auto c = new C;
    try {
        destroy(c);
    } catch (Throwable) {
        return;
    }
}
}).kind.should == GuestFault.Kind.nullPointer;
    }
}


// The call stack goes through native code that calls the guest back: the
// guest caller of `qsort` is in it.
static foreach (backend; FaultBackends) {
    @("fault.stackGoesThroughANativeCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const fault = guestFaultOf!(backend, q{
import core.stdc.stdlib: qsort;

extern(C) int compare(const(void)* a, const(void)* b) {
    int* p;
    return *p;
}

void main() {
    int[2] values = [2, 1];
    qsort(values.ptr, values.length, int.sizeof, &compare);
}
});
        fault.stack.length.should == 2;
        "compare".should.be in fault.stack[0].function_;
        "main".should.be in fault.stack[1].function_;
    }
}


// The callee sets an `out` parameter to its default value: the fault is at
// the callee, and the callee is the innermost function of the call stack.
static foreach (backend; FaultBackends) {
    @("fault.nullOutArgumentNamesTheCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const fault = guestFaultOf!(backend, q{
void write(
    out int value,
) {
    value = 1;
}

void main() {
    int* p;
    write(*p);
}
});
        fault.line.should == 2;
        fault.stack.length.should == 2;
        "write".should.be in fault.stack[0].function_;
    }
}


// The same through a function pointer: the callee is known only when the
// call runs.
static foreach (backend; FaultBackends) {
    @("fault.nullOutArgumentThroughAFunctionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const fault = guestFaultOf!(backend, q{
void write(
    out int value,
) {
    value = 1;
}

void other(out int value) { }

void function(out int) pick(int n) { return n ? &write : &other; }

void main() {
    int* p;
    auto f = pick(1);
    f(*p);
}
});
        fault.line.should == 2;
        fault.stack.length.should == 2;
        "write".should.be in fault.stack[0].function_;
    }
}


// A nested function reads the variables of its parent through its context
// pointer: a null context is a null address.
static foreach (backend; FaultBackends) {
    @("fault.nullClosureContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int x = 5;
    int get() { return x; }
    auto d = &get;
    d.ptr = null;
    d();
}
})(4);
    }
}


// Pointer arithmetic on null gives an address in the first page: a load
// through it is the same signal as a load through null.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerOffsetRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    int x = *(p + 1);
}
})(4);
    }
}


// A slice of a null pointer is an address and a length: the read of an
// element is the access.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerSliceElementRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    auto slice = p[0 .. 2];
    int x = slice[1];
}
})(5);
    }
}


// `foreach` over a static array reads each element: through a null
// pointer to the array that is a null dereference.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerStaticArrayForeach." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int[4]* p;
    int sum;
    foreach (element; *p)
        sum += element;
}
})(5);
    }
}


// The same for a static array field of a struct behind a null pointer.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerStaticArrayFieldForeach." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int first; int[4] elements; }

void main() {
    S* p;
    int sum;
    foreach (element; p.elements)
        sum += element;
}
})(7);
    }
}


// A fill of a slice writes each element.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerSliceFill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    p[0 .. 2] = 0;
}
})(4);
    }
}


// A fill of a static array field behind a null pointer writes each element.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerStaticArrayFieldFill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct S { int first; int[4] elements; }

void main() {
    S* p;
    p.elements[] = 1;
}
})(6);
    }
}


// `c.__monitor` reads the second word of the object.
static foreach (backend; FaultBackends) {
    @("fault.nullClassMonitor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullClassReference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    auto monitor = c.__monitor;
}
})(6);
    }
}




// A dual-context function reads the field of its alias argument through
// word 1 of its pair of contexts. A null `this` of the caller makes that
// word null: the call passes it on, the read of the field faults.
static foreach (backend; FaultBackends) {
    @("fault.nullSecondContextOfDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct Holder {
    int base = 2;
    int add(alias field)() { return base + field; }
}
struct Owner {
    int value = 40;
    int run(ref Holder holder) { return holder.add!value(); }
}
void main() {
    Holder holder;
    Owner* owner;
    owner.run(holder);
}
})(4);
    }
}


// As above for word 0 of the pair, the receiver of the dual-context member.
static foreach (backend; FaultBackends) {
    @("fault.nullReceiverOfDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct Holder {
    int base = 2;
    int add(alias field)() { return base + field; }
}
struct Owner {
    int value = 40;
    int run(Holder* holder) { return holder.add!value(); }
}
void main() {
    Owner owner;
    Holder* holder;
    owner.run(holder);
}
})(4);
    }
}


static foreach (backend; FaultBackends) {
    @("fault.nullSecondContextCompoundAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct Inner { int v = 1; }
struct Holder {
    int bump(alias field)() { field.v += 2; return field.v; }
}
struct Owner {
    int pad;
    Inner inner;
    int run(ref Holder holder) { return holder.bump!inner(); }
}
void main() {
    Holder holder;
    Owner* owner;
    owner.run(holder);
}
})(4);
    }
}


// The method call on a field through a null second context passes the
// address of the field on. The read of `this` in the method faults.
static foreach (backend; FaultBackends) {
    @("fault.nullSecondContextMethodOfField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct Inner { int v = 1; int get() { return v; } }
struct Holder {
    int call(alias field)() { return field.get(); }
}
struct Owner {
    int pad;
    Inner inner;
    int run(ref Holder holder) { return holder.call!inner(); }
}
void main() {
    Holder holder;
    Owner* owner;
    owner.run(holder);
}
})(2);
    }
}


// The lambda passes the pair of contexts of its enclosing dual-context
// member on to the call. A null `this` of the caller makes word 1 null.
static foreach (backend; FaultBackends) {
    @("fault.nullSecondContextOfLambdaCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct Holder {
    int base = 2;
    int add(alias field)() { return base + field; }
    int relay(alias field)() { auto l = () => add!field(); return l(); }
}
struct Owner {
    int value = 40;
    int run(ref Holder holder) { return holder.relay!value(); }
}
void main() {
    Holder holder;
    Owner* owner;
    owner.run(holder);
}
})(4);
    }
}


// The delegate to a dual-context member takes the pair of contexts of the
// caller. A null `this` of the caller makes word 1 null.
static foreach (backend; FaultBackends) {
    @("fault.nullSecondContextOfMemberDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullPointer.shouldBeFaultOf!(backend, q{
struct Holder {
    int base = 2;
    int add(alias field)() { return base + field; }
}
struct Owner {
    int value = 40;
    int run(ref Holder holder) { auto dg = &holder.add!value; return dg(); }
}
void main() {
    Holder holder;
    Owner* owner;
    owner.run(holder);
}
})(4);
    }
}
