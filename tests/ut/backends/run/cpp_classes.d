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
