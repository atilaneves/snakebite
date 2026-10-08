module ut.backends.run.finalizers;


import ut.backends;


// The library-unload scan can read unrelated finalizable blocks before their
// class initialization copy, including in native druntime. The serial
// runner pass finishes these tests before any other guest test starts.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access class destructors through TypeInfo"),
)) {
    @("firstDestructorCallFromGc." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            class Resource {
                int* count;
                this(int* count) { this.count = count; }
                ~this() { ++*count; }
            }
            void main() {
                int count;
                auto resource = new Resource(&count);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(count == 1);
            }
        });
    }

    // A destructor runs from GC finalization, where the GC must not
    // allocate. Its first call to another function therefore has to reach
    // code that was already prepared before the finalizer started.
    @("firstDestructorHelperCallFromGc." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            class Resource {
                int* count;
                this(int* count) { this.count = count; }
                void increment() { ++*count; }
                ~this() { increment(); }
            }
            void main() {
                int count;
                auto resource = new Resource(&count);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(count == 1);
            }
        });
    }
    // Force the first call through finalization, not an earlier guest call or
    // a collection whose conservative roots can keep the object alive.
    @("firstDestructorCompoundFieldsFromGc." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            struct Owner {
                byte pad = 9;
                double d = 1.5;
                long l = 20;
                double run() {
                    d += 0.5;
                    l <<= 1;
                    return d + l;
                }
            }
            class Resource {
                int* count;
                Owner owner;
                this(int* count) { this.count = count; }
                ~this() { if (owner.run == 42.0) ++*count; }
            }
            void main() {
                int count;
                auto resource = new Resource(&count);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(count == 1);
            }
        });
    }

    @("firstDestructorInheritedClassContractsFromGc." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            class Base {
                int limit = 7;
                int* checks;
                int f(int x)
                in { ++*checks; assert(x < limit); }
                out (r) { ++*checks; assert(r == x * limit); }
                do { return x * limit; }
            }
            class Derived: Base {
                override int f(int x)
                in (x > 0)
                do { return x * limit; }
            }
            class Resource {
                Base target;
                int* result;
                this(int* checks, int* result) {
                    target = new Derived;
                    target.checks = checks;
                    this.result = result;
                }
                ~this() { *result = target.f(3); }
            }
            void main() {
                int checks, result;
                auto resource = new Resource(&checks, &result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(result == 21);
                assert(checks == 2);
            }
        });
    }

    @("firstDestructorInheritedInterfaceContractsFromGc." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            interface First { int a(); }
            interface Second {
                int f(int x)
                in { record(); assert(x == g()); }
                out (r) { record(); assert(r == g() * 2); }
                int g();
                void record();
            }
            class Impl: First, Second {
                int value = 7;
                int* checks;
                int a() { return 1; }
                int g() { return value; }
                void record() { ++*checks; }
                int f(int x)
                in (x > 0)
                do { return x * 2; }
            }
            class Resource {
                Second target;
                int* result;
                this(int* checks, int* result) {
                    auto impl = new Impl;
                    impl.checks = checks;
                    target = impl;
                    this.result = result;
                }
                ~this() { *result = target.f(7); }
            }
            void main() {
                int checks, result;
                auto resource = new Resource(&checks, &result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(result == 14);
                assert(checks == 2);
            }
        });
    }
}
