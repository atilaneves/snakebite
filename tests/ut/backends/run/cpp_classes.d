module ut.backends.run.cpp_classes;


// An `extern(C++)` class has its vtable pointer at offset 0, no monitor
// field, and no `TypeInfo` slot at the head of its vtable, so its first
// virtual method sits at vtable index 0.


import ut.backends;

static foreach (backend; Matrix!()) {
    @("cppClass.virtualCallThroughNew." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Counter {
                int value() { return 7; }
            }
            void main() {
                auto counter = new Counter;
                assert(counter.value == 7);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.overrideRunsThroughBaseReference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int value() { return 1; }
                int twice() { return value * 2; }
            }
            extern(C++) class Derived: Base {
                override int value() { return 21; }
            }
            void main() {
                Base base = new Derived;
                assert(base.value == 21);
                assert(base.twice == 42);
                assert((new Base).twice == 2);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.finalMethodCallsDirectly." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                final int fixed() { return 5; }
                int open() { return fixed; }
            }
            void main() {
                auto base = new Base;
                assert(base.fixed == 5);
                assert(base.open == 5);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.fieldsReadAndWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int first = 3;
                int read() { return first; }
            }
            extern(C++) class Derived: Base {
                long second = 4;
            }
            void main() {
                auto derived = new Derived;
                assert(derived.first == 3);
                assert(derived.second == 4);
                derived.first = 10;
                derived.second = 20;
                assert(derived.read == 10);
                assert(derived.second == 20);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.constructorInitialisesFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int first;
                this(int first) { this.first = first; }
                int read() { return first; }
            }
            extern(C++) class Derived: Base {
                int second;
                this(int first, int second) {
                    super(first);
                    this.second = second;
                }
            }
            void main() {
                auto derived = new Derived(3, 4);
                assert(derived.first == 3);
                assert(derived.second == 4);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "`destroy` reads the initializer symbol, whose address CTFE cannot take"),
)) {
    @("cppClass.destructorRunsOnDestroy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Resource {
                int* destroyed;
                this(int* destroyed) { this.destroyed = destroyed; }
                ~this() { ++*destroyed; }
            }
            void main() {
                int destroyed;
                auto resource = new Resource(&destroyed);
                destroy(resource);
                assert(destroyed == 1);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.interfaceDispatchesToImplementation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Shape {
                int sides();
            }
            extern(C++) class Square: Shape {
                int sides() { return 4; }
            }
            void main() {
                Shape shape = new Square;
                assert(shape.sides == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.dClassImplementsInterface." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Shape {
                int sides();
            }
            class Triangle: Shape {
                extern(C++) int sides() { return 3; }
            }
            void main() {
                Shape shape = new Triangle;
                assert(shape.sides == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.castBetweenBaseAndDerived." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Shape {
                int sides();
            }
            extern(C++) class Base {
                int id() { return 1; }
            }
            extern(C++) class Square: Base, Shape {
                int sides() { return 4; }
            }
            void main() {
                Base base = new Square;
                auto square = cast(Square) base;
                assert(square !is null);
                assert(square is base);
                assert(square.id == 1);
                auto shape = cast(Shape) square;
                assert(shape.sides == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.scopeInstanceCallsVirtual." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int* destroyed;
                this(int* destroyed) { this.destroyed = destroyed; }
                int value() { return 1; }
                ~this() { ++*destroyed; }
            }
            extern(C++) class Derived: Base {
                this(int* destroyed) { super(destroyed); }
                override int value() { return 9; }
            }
            void main() {
                int destroyed;
                {
                    scope Base base = new Derived(&destroyed);
                    assert(base.value == 9);
                }
                assert(destroyed == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot reinterpret an object's memory as bytes"),
)) {
    @("cppClass.objectHasVtablePointerThenFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Counter {
                int count = 6;
                int value() { return count; }
            }
            void main() {
                assert(__traits(classInstanceSize, Counter)
                    == (void*).sizeof + int.sizeof);
                auto counter = new Counter;
                auto raw = cast(ubyte*) counter;
                assert(*cast(int*) (raw + (void*).sizeof) == 6);
                *cast(int*) (raw + (void*).sizeof) = 11;
                assert(counter.value == 11);
            }
        });
    }
}


// druntime reads `ClassFlags.isCPPclass` to know that vtable slot 0 of an
// object holds a method, not a `TypeInfo_Class`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not implement `typeid(Resource).m_flags`"),
)) {
    @("cppClass.classInfoSaysCppClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Resource {
                int value() { return 1; }
                ~this() {}
            }
            void main() {
                assert(typeid(Resource).m_flags
                    & TypeInfo_Class.ClassFlags.isCPPclass);
            }
        });
    }
}

// `TypeInfo_Class.create` allocates through `_d_newclass`. That function
// asks the GC to finalize an object with a destructor, unless the class is
// an `extern(C++)` class: the finalizer reads the `TypeInfo_Class` from
// vtable slot 0, and an `extern(C++)` class has a method there.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read `typeid(Resource)`: it is a static variable"),
)) {
    @("cppClass.createdThroughClassInfoIsNotFinalized." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Resource {
                int value() { return 1; }
                ~this() {}
            }
            void main() {
                import core.memory: GC;
                auto created = cast(void*) typeid(Resource).create;
                assert(created !is null);
                assert(!(GC.getAttr(created) & GC.BlkAttr.FINALIZE));
                assert((cast(Resource) created).value == 1);
            }
        });
    }
}

// A class that implements an interface named `IUnknown` is a COM class.
// druntime reads `ClassFlags.isCOMclass` to allocate it outside the GC.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not implement `typeid(Impl).m_flags`"),
)) {
    @("comClass.classInfoSaysComClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface IUnknown {
                int ping();
            }
            class Impl: IUnknown {
                extern(Windows) int ping() { return 5; }
            }
            void main() {
                assert(typeid(Impl).m_flags
                    & TypeInfo_Class.ClassFlags.isCOMclass);
                assert(typeid(IUnknown).info.m_flags
                    & TypeInfo_Class.ClassFlags.isCOMclass);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE hits an internal assertion (`dinterpret.d:4777`) on "
        ~ "`destroy` of a derived C++ class"),
)) {
    @("cppClass.destroyThroughBaseRunsBothDestructors." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int* log;
                this(int* log) { this.log = log; }
                ~this() { *log = *log * 10 + 1; }
            }
            extern(C++) class Derived: Base {
                this(int* log) { super(log); }
                ~this() { *log = *log * 10 + 2; }
            }
            void main() {
                int log;
                Base base = new Derived(&log);
                destroy(base);
                assert(log == 21);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.dClassHoldsCppClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Plain {
                Cpp cpp;
                int value() { return 3; }
            }
            extern(C++) class Cpp {
                int value() { return 4; }
            }
            void main() {
                auto plain = new Plain;
                plain.cpp = new Cpp;
                assert(plain.cpp.value == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.cppClassHoldsDClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Plain {
                int value() { return 3; }
            }
            extern(C++) class Cpp {
                Plain plain;
            }
            void main() {
                auto cpp = new Cpp;
                cpp.plain = new Plain;
                assert(cpp.plain.value == 3);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppStruct.withMethods." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) struct Point {
                int x;
                int y;
                int sum() const { return x + y; }
                void move(int dx, int dy) { x += dx; y += dy; }
                static Point origin() { return Point(0, 0); }
            }
            void main() {
                auto point = Point(1, 2);
                assert(point.sum == 3);
                point.move(10, 20);
                assert(point.sum == 33);
                assert(Point.origin.sum == 0);
                assert(Point.sizeof == 8);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.namespaceClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++, "geometry") {
                class Shape {
                    int sides() { return 0; }
                }
                class Square: Shape {
                    override int sides() { return 4; }
                }
            }
            void main() {
                Shape shape = new Square;
                assert(shape.sides == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.namespaceFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++, "geometry") {
                int twice(int value) { return value * 2; }
            }
            void main() {
                assert(twice(4) == 8);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.namespaceStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++, "geometry") {
                struct Size { int width; int area() { return width * width; } }
            }
            void main() {
                assert(Size(3).area == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.finalDerivedClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int value() { return 1; }
            }
            extern(C++) final class Leaf: Base {
                int extra = 5;
                override int value() { return extra; }
                int more() { return extra + 1; }
            }
            void main() {
                auto leaf = new Leaf;
                Base base = leaf;
                assert(base.value == 5);
                assert(leaf.more == 6);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.finalClassWithNoBase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) final class Alone {
                int value() { return 8; }
            }
            void main() {
                assert((new Alone).value == 8);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.abstractClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) abstract class Shape {
                abstract int sides();
                int twice() { return sides * 2; }
            }
            extern(C++) class Square: Shape {
                override int sides() { return 4; }
            }
            void main() {
                Shape shape = new Square;
                assert(shape.sides == 4);
                assert(shape.twice == 8);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.superCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Base {
                int value() { return 1; }
            }
            extern(C++) class Middle: Base {
                override int value() { return super.value + 10; }
            }
            extern(C++) class Derived: Middle {
                override int value() { return super.value + 100; }
            }
            void main() {
                Base base = new Derived;
                assert(base.value == 111);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.secondInterfaceDispatches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Shape {
                int sides();
            }
            extern(C++) interface Named {
                int code();
                int more(int extra);
            }
            extern(C++) class Square: Shape, Named {
                int field = 7;
                int sides() { return field + 1; }
                int code() { return field + 2; }
                int more(int extra) { return field + extra; }
            }
            void main() {
                auto square = new Square;
                Shape shape = square;
                Named named = square;
                assert(shape.sides == 8);
                assert(named.code == 9);
                assert(named.more(3) == 10);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not support a pointer cast from an interface to `void*`"),
)) {
    @("cppClass.secondInterfacePointerDiffers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Shape {
                int sides();
            }
            extern(C++) interface Named {
                int code();
            }
            extern(C++) class Square: Shape, Named {
                int sides() { return 1; }
                int code() { return 2; }
            }
            void main() {
                auto square = new Square;
                Shape shape = square;
                Named named = square;
                assert(cast(void*) shape !is cast(void*) named);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.secondInterfaceOverrideInDerived." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Shape {
                int sides();
            }
            extern(C++) interface Named {
                int code();
                int more(int extra);
            }
            extern(C++) class Square: Shape, Named {
                int field = 7;
                int sides() { return field + 1; }
                int code() { return field + 2; }
                int more(int extra) { return field + extra; }
            }
            extern(C++) class Big: Square {
                int other = 100;
                override int code() { return field + other; }
            }
            void main() {
                Named big = new Big;
                assert(big.code == 107);
                assert(big.more(1) == 8);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the static variable `typeid(Counter)`"),
)) {
    @("cppClass.typeidOfType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) class Counter {
                int count = 6;
                int value() { return count; }
            }
            void main() {
                assert(typeid(Counter).initializer.length
                    == __traits(classInstanceSize, Counter));
                assert(Counter.classinfo is typeid(Counter));
                assert(typeid(Counter).base is null);
            }
        });
    }
}

// The linkage attribute permits white space before its parentheses.
static foreach (backend; Matrix!()) {
    @("cppClass.linkageAttributeWithSpace." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern (C++) class Counter {
                int value() { return 9; }
            }
            void main() {
                assert((new Counter).value == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.virtualCallInCalledFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.shouldBeRetOf!(backend, q{
            extern(C++) class Counter {
                int value() { return 11; }
            }
            int answer() {
                return (new Counter).value;
            }
        }, "answer");
    }
}

static foreach (backend; Matrix!()) {
    @("cppClass.virtualCallInExpression." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        eval!(backend, q{
            extern(C++) class Counter {
                int value() { return 13; }
            }
        }, q{ (new Counter).value }).should == "13";
    }
}

static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "dmd cannot link the C++ typeinfo of a catch clause, LDC can"),
)) {
    @("cppInterface.catchClauseOnCppInterface." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C++) interface Listener {
                void notify();
            }
            void main() {
                try {
                    const value = 1;
                    assert(value == 1);
                } catch (Listener) {
                    assert(0);
                }
            }
        });
    }
}
