module ut.backends.run.faults;


import ut.backends;

import snakebite.backends.guestfault: GuestFault;


// Guest code that compiled D kills with a signal - a null dereference, an
// integer division the hardware traps - is a guest fault. A backend reports
// it to the host that runs it as a `GuestFaultException`, which no guest
// `catch` sees. Compiled D itself dies of SIGSEGV or SIGFPE, so no
// in-process test can run it, and dmd's interpreter reports a diagnostic
// instead of an exception.
private alias FaultBackends = Matrix!(
    Omit!(Native, Because.inexpressible,
        "compiled D dies of SIGSEGV or SIGFPE, and no in-process test "
        ~ "survives a signal"),
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter reports a null dereference and a division by "
        ~ "zero as diagnostics and raises no GuestFaultException"),
);

// A null dereference is a fault at the load or the store through the
// address, not where an address is formed: native code forms `&p.field`,
// passes `*p` as a `ref` argument and calls a method through a null `p`
// without a signal.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    *p = 3;
}
})(4);
    }
}

static foreach (backend; FaultBackends) {
    @("fault.nullPointerStructFieldWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    (*p)++;
}
})(4);
    }
}

static foreach (backend; FaultBackends) {
    @("fault.nullPointerStructAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
class C { int field; }

void main() {
    C c;
    c.field = 3;
}
})(6);
    }
}

static foreach (backend; FaultBackends) {
    @("fault.nullClassBitfieldWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
class C { int bits : 3; }

void main() {
    C c;
    c.bits = 1;
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    auto t = typeid(c);
}
})(6);
    }
}

// A `ref` argument is only an address: the call is no fault, and the read of
// the parameter is.
static foreach (backend; FaultBackends) {
    @("fault.nullRefParameterRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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

static foreach (backend; FaultBackends) {
    @("fault.nullRefLocalRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
void main() {
    int* p;
    ref int r = *p;
    int x = r;
}
})(5);
    }
}

// A struct method receives `this` by reference: the call is no fault, and the
// read of a field is.
static foreach (backend; FaultBackends) {
    @("fault.nullStructMethodFieldRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
}).kind.should == GuestFault.Kind.nullDereference;
    }
}

// `c.classinfo` reads the vtable of `c`, as `typeid(c)` does.
static foreach (backend; FaultBackends) {
    @("fault.nullClassClassinfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
}).kind.should == GuestFault.Kind.nullDereference;
    }
}

// Pointer arithmetic on null gives an address in the first page: a load
// through it is the same signal as a load through null.
static foreach (backend; FaultBackends) {
    @("fault.nullPointerOffsetRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
class C { }

void main() {
    C c;
    auto monitor = c.__monitor;
}
})(6);
    }
}

// As above for word 0 of the pair, the receiver of the dual-context member.
static foreach (backend; FaultBackends) {
    @("fault.nullReceiverOfDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        GuestFault.Kind.nullDereference.shouldBeFaultOf!(backend, q{
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
