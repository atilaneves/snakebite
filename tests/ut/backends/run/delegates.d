module ut.backends.run.delegates;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("assignDelegateFieldsBeforeNestedCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int value;
                int read() { return value; }
            }
            int invoke(Counter* counter) {
                int delegate() callback;
                callback.funcptr = &Counter.read;
                callback.ptr = counter;
                int helper() { return callback(); }
                return helper();
            }
            void main() {
                Counter counter = Counter(42);
                assert(invoke(&counter) == 42);
            }
        });
    }
}


// A delegate is true when either of its two words (`ptr`, `funcptr`) is
// nonzero: `null` leaves both zero, and assigning a method delegate sets
// both, so the assignment alone flips the condition.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot evaluate a method delegate as a compile-time "
            ~ "boolean condition"),
)) {
    @("delegateTruthyAfterAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int value;
                int read() { return value; }
            }
            void main() {
                int delegate() callback;
                assert(!callback);

                Counter counter = Counter(42);
                callback = &counter.read;
                assert(callback);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read callable TypeInfo fields"),
)) {
    @("callableTypeInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Result { int value; }
            Result operation(int value) { return Result(value); }
            alias Callback = Result delegate(int);
            void main() {
                auto functionInfo = cast(TypeInfo_Function) typeid(typeof(operation));
                assert(functionInfo !is null);
                assert(functionInfo.next is typeid(Result));
                assert(functionInfo.deco == typeof(operation).mangleof);
                assert(functionInfo.tsize == 0);
                auto pointerInfo = cast(TypeInfo_Pointer) typeid(typeof(&operation));
                assert(pointerInfo.m_next is functionInfo);
                auto delegateInfo = cast(TypeInfo_Delegate) typeid(Callback);
                assert(delegateInfo !is null);
                assert(delegateInfo.next is typeid(Result));
                assert(delegateInfo.deco == Callback.mangleof);
                assert(delegateInfo.tsize == Callback.sizeof);
                assert(typeid(Callback) is delegateInfo);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("pointerToVariadicDelegateCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdarg;
            struct Counter {
                int value;
                extern(C) void add(int amount, ...) { value += amount; }
            }
            void invoke(Counter* counter) {
                auto add = &counter.add;
                add(17);
            }
            void main() {
                auto invokePointer = &invoke;
                assert(invokePointer !is null);
            }
        });
    }
}


// A function literal that reads no enclosing local needs no context, so
// binding it to a delegate variable makes a (null, function) pair. Each
// call binds the parameter afresh, so repeated calls see their own
// argument, not a stale one.
static foreach (backend; Matrix!()) {
    @("nonCapturingDelegateBindsItsParameterEachCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int delegate(int) increment = (int value) => value + 1;

                assert(increment(0) == 1);
                assert(increment(41) == 42);
                assert(increment(-3) == -2);

                return 0;
            }
        });
    }
}


// Delegate equality compares both the function and context pointers. A
// copied delegate is equal, while two closures from separate calls are not,
// even when they produce the same result.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("delegateEqualityComparesFunctionAndContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int delegate(int) make(int seed) {
                int add(int value) {
                    return seed + value;
                }

                return &add;
            }

            void main() {
                auto first = make(10);
                auto copy = first;
                auto second = make(10);

                assert(first == copy);
                assert(first != second);
                assert(first(2) == second(2));
            }
        });
    }
}


// The alias-template form `check!F` hands the literal itself to the
// template, so `F(value)` is a direct call of the literal - each
// invocation must see the argument of that invocation.
static foreach (backend; Matrix!()) {
    @("nonCapturingLambdaThroughAliasTemplate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void check(alias F)() {
                foreach (value; 0 .. 5)
                    assert(F(value) == value + 1);
            }

            int main() {
                check!((int value) => value + 1);
                return 0;
            }
        });
    }
}


// A delegate to a nested function is a (context, function) pair whose
// context is the enclosing frame, so calling it reaches the same locals.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("nestedFunctionDelegateCarriesItsFrame." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            void main() {
                int captured = runtimeSeed(3);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;

                assert(dg.ptr !is null);
                assert(dg.funcptr !is null);

                assert(dg() == 6);
                assert(captured == 6);
            }
        });
    }
}


// `key in aa` gives a pointer to the matched value, not the value
// itself, so calling through it is a call through a delegate pointer,
// not a call on a delegate. dmd's own `(*handler)(...)` syntax for that
// dereference looks exactly like a function-pointer call's own lowered
// shape (issue: bytecode/interpreter must pick the callee kind from
// `e1`'s type, `Tdelegate`, never from `e1` being a `PtrExp`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("callDelegateThroughPointerFromAssociativeArrayIn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            alias Handler = int delegate(int);
            void main() {
                int total;
                Handler[string] handlers;
                handlers["a"] = (int x) { total += x; return x * 2; };
                auto handler = "a" in handlers;
                assert(handler !is null);
                assert((*handler)(5) == 10);
                assert(total == 5);
            }
        });
    }
}


// The address-of a delegate variable is a pointer to a delegate, so
// calling through it dereferences to the two-word delegate value first -
// the same `(*p)(...)` syntax a function pointer's own call lowers to,
// but `p`'s pointee type is `Tdelegate`, not `Tfunction`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("callDelegateThroughPlainPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            alias Handler = int delegate(int);
            void main() {
                int total;
                Handler h = (int x) { total += x; return x * 2; };
                Handler* p = &h;
                assert((*p)(5) == 10);
                assert(total == 5);
            }
        });
    }
}


// A static delegate initialized from a lambda outside any frame has a
// null context and the lambda as its function.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
)) {
    @("staticDelegateInitializerHasNullContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                static int delegate() global = delegate() => 5;

                assert(global.ptr is null);
                assert(global.funcptr !is null);
                assert(global() == 5);
            }
        });
    }
}

// The same through an enum of a delegate. dmd swaps the two words and
// the call crashes; ldc follows the spec.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable's value at compile time"),
    Omit!(Native, Because.diverges,
        "dmd's runtime codegen reads an enum-of-delegate module "
            ~ "initializer's fields swapped and crashes when it is "
            ~ "called; ldc follows the spec"),
)) {
    @("enumOfDelegateModuleInitializerHasNullContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            enum Getter : int delegate() { a = delegate() => 9 }
            Getter gg = Getter.a;

            void main() {
                assert(gg.ptr is null);
                assert(gg.funcptr !is null);
                assert(gg() == 9);
            }
        });
    }
}

// dmd's swapped words, pinned without the call that crashes.
@("enumOfDelegateModuleInitializerHasNullContext.Native")
@Tags(Native.stringof)
unittest {
    0.shouldBeStatusOf!(Native, q{
        enum Getter : int delegate() { a = delegate() => 9 }
        Getter gg = Getter.a;

        void main() {
            assert(gg.ptr !is null);
            assert(gg.funcptr is null);
        }
    });
}


// A delegate literal outside every function has no frame to point at, so
// calling it through a manifest constant gives it a null context.
static foreach (backend; Matrix!()) {
    @("callEnumDelegateLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(backend, q{
            enum dg = delegate int() => 3;
            int run() { return dg(); }
        }, "run");
    }
}


static foreach (backend; Matrix!()) {
    @("callEnumDelegateLiteralWithParameters." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            enum dg = delegate int(int a, int b) => a * 10 + b;
            int run() { return dg(4, 2); }
        }, "run");
    }
}


static foreach (backend; Matrix!()) {
    @("callEnumDelegateLiteralReturningStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        63L.shouldBeRetOf!(backend, q{
            struct Pair { int a; long b; }
            enum dg = delegate Pair(int x) => Pair(x, x * 2L);
            long run() {
                const pair = dg(21);
                return pair.a + pair.b;
            }
        }, "run");
    }
}


static foreach (backend; Matrix!()) {
    @("callEnumDelegateLiteralThroughAlias." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(backend, q{
            enum dg = delegate int() => 3;
            alias same = dg;
            int run() { return same(); }
        }, "run");
    }
}


static foreach (backend; Matrix!()) {
    @("callEnumDelegateLiteralInTemplate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(backend, q{
            template Make(int n) {
                enum Make = delegate int() => n;
            }
            int run() { return Make!7(); }
        }, "run");
    }
}


static foreach (backend; Matrix!()) {
    @("callDelegateLiteralImmediately." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                assert((delegate int() => 3)() == 3);
            }
        });
    }
}


// A member function template with an alias parameter, instantiated with a
// nested function, has two contexts: the receiver and the frame of the
// function that owns the alias. dmd deprecates this but compiles it.
static foreach (backend; Matrix!()) {
    @("callNestedFunctionFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                int call(alias callee)() { return base + callee(); }
            }
            int main() {
                int local = 40;
                int nested() { return local; }
                auto holder = Holder(2);
                return holder.call!nested() == 42 ? 0 : 1;
            }
        });
    }
}

// A class receiver is a pointer to the object, and the first context
// word holds that pointer.
static foreach (backend; Matrix!()) {
    @("callNestedFunctionFromDualContextClassMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Holder {
                int base;
                this(int base) { this.base = base; }
                int call(alias callee)() { return base + callee(); }
            }
            int main() {
                int local = 40;
                int nested() { return local; }
                auto holder = new Holder(2);
                return holder.call!nested() == 42 ? 0 : 1;
            }
        });
    }
}

// The member writes its own field; the nested function writes the local
// of the function that owns it.
static foreach (backend; Matrix!()) {
    @("writeFieldAndNestedLocalFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                void bump(alias callee)() {
                    base += 1;
                    callee();
                }
            }
            int main() {
                int local = 40;
                void nested() { local += 5; }
                auto holder = Holder(2);
                holder.bump!nested();
                return holder.base == 3 && local == 45 ? 0 : 1;
            }
        });
    }
}

// The nested function is declared in a member function, so it reads
// both its own enclosing `this` and a local.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine asserts on a dual-context function whose "
            ~ "alias is nested in a member function"),
)) {
    @("callNestedFunctionOfMemberFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                int call(alias callee)() { return base + callee(); }
            }
            struct Owner {
                int field = 7;
                int run() {
                    int local = 30;
                    int nested() { return local + field; }
                    auto holder = Holder(5);
                    return holder.call!nested();
                }
            }
            int main() {
                Owner owner;
                return owner.run() == 42 ? 0 : 1;
            }
        });
    }
}

// The alias argument is a local delegate variable.
static foreach (backend; Matrix!()) {
    @("callDelegateVariableFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                int call(alias callee)() { return base + callee(); }
            }
            int main() {
                int local = 40;
                auto lambda = () => local;
                auto holder = Holder(2);
                return holder.call!lambda() == 42 ? 0 : 1;
            }
        });
    }
}

// The delegate's context word points at the pair of contexts.
static foreach (backend; Matrix!()) {
    @("callDualContextMemberThroughDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                int call(alias callee)() { return base + callee(); }
            }
            int main() {
                int local = 40;
                int nested() { return local; }
                auto holder = Holder(2);
                int delegate() callback = &holder.call!nested;
                return callback() == 42 ? 0 : 1;
            }
        });
    }
}

// Control: the alias is a module-level function, so the member
// template has one context only.
static foreach (backend; Matrix!()) {
    @("callGlobalFunctionFromMemberTemplate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int global() { return 40; }
            struct Holder {
                int base;
                int call(alias callee)() { return base + callee(); }
            }
            int main() {
                auto holder = Holder(2);
                return holder.call!global() == 42 ? 0 : 1;
            }
        });
    }
}

// The alias is nested two levels deep, and reads a local of each level.
static foreach (backend; Matrix!()) {
    @("callTwiceNestedFunctionFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                int call(alias callee)() { return base + callee(); }
            }
            int main() {
                int outerLocal = 30;
                int outer() {
                    int innerLocal = 10;
                    int inner() { return outerLocal + innerLocal; }
                    auto holder = Holder(2);
                    return holder.call!inner();
                }
                return outer() == 42 ? 0 : 1;
            }
        });
    }
}


// A dual-context member returns a delegate that reads both contexts. The
// delegate's context is the frame of the member, which holds the address
// of the pair, so the pair must outlive the function that made the call:
// dmd declares it as a closure variable of the caller (`CallExp.vthis2`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE does not support closures"),
)) {
    @("callDelegateFromDualContextMemberAfterCallerReturned."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base;
                int delegate() make(alias callee)() {
                    return () => base + callee();
                }
            }
            int delegate() build(Holder* holder) {
                int local = 40;
                int nested() { return local; }
                return holder.make!nested();
            }
            int clobber(int depth) {
                int[32] junk = 7;
                return depth == 0 ? junk[3] : clobber(depth - 1) + junk[5];
            }
            int main() {
                auto holder = new Holder(2);
                auto callback = build(holder);
                clobber(8);
                return callback() == 42 ? 0 : 1;
            }
        });
    }
}

// As above with a class receiver.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE does not support closures"),
)) {
    @("callDelegateFromDualContextClassMemberAfterCallerReturned."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Holder {
                int base = 2;
                int delegate() make(alias callee)() {
                    return () => base + callee();
                }
            }
            int delegate() build(Holder holder) {
                int local = 40;
                int nested() { return local; }
                return holder.make!nested();
            }
            int clobber(int depth) {
                int[32] junk = 7;
                return depth == 0 ? junk[3] : clobber(depth - 1) + junk[5];
            }
            int main() {
                auto holder = new Holder;
                auto callback = build(holder);
                clobber(8);
                return callback() == 42 ? 0 : 1;
            }
        });
    }
}


// The alias argument is a field of another struct, so the second context
// is the `this` of the member function that makes the call, not a frame.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("readFieldOfOtherStructFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
            }
            struct Owner {
                int value = 40;
                int run(ref Holder holder) { return holder.add!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                return owner.run(holder) == 42 ? 0 : 1;
            }
        });
    }
}

// The second context is a class reference.
static foreach (backend; Matrix!()) {
    @("readFieldOfOtherClassFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
            }
            class Owner {
                int value = 40;
                int run(Holder holder) { return holder.add!value(); }
            }
            int main() {
                auto holder = new Holder;
                auto owner = new Owner;
                return owner.run(holder) == 42 ? 0 : 1;
            }
        });
    }
}

// The call is in a function nested in the member, so the second context
// (the member's `this`) is one step up the static chain.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("readFieldOfOtherStructFromDualContextMemberInNestedFunction."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
            }
            struct Owner {
                int value = 40;
                int run(ref Holder holder) {
                    int nested() { return holder.add!value(); }
                    return nested();
                }
            }
            int main() {
                Holder holder;
                Owner owner;
                return owner.run(holder) == 42 ? 0 : 1;
            }
        });
    }
}

// A delegate to a dual-context member whose second context is a `this`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE does not support closures"),
)) {
    @("delegateToDualContextMemberWithFieldOfOtherStruct."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
            }
            struct Owner {
                int value = 40;
                int delegate() bind(ref Holder holder) {
                    return &holder.add!value;
                }
            }
            int main() {
                Holder holder;
                Owner owner;
                auto callback = owner.bind(holder);
                return callback() == 42 ? 0 : 1;
            }
        });
    }
}


// Assigning to the field of the other struct writes through the second
// context, the `this` of the member function that makes the call.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("writeFieldOfOtherStructFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                void set(alias field)() { field = base + 40; }
            }
            struct Owner {
                int value;
                void run(ref Holder holder) { holder.set!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                owner.run(holder);
                return owner.value == 42 ? 0 : 1;
            }
        });
    }
}


// The call is in a member of a class nested in the class that owns the
// alias, so the second context is the outer object, found through the
// nested object's context field.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine reads a null outer object in a class nested in a "
            ~ "class that calls a dual-context function"),
)) {
    @("readFieldOfOuterClassFromDualContextMemberInInnerClass."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
            }
            class Owner {
                int value = 40;
                class Inner {
                    int run(Holder holder) { return holder.add!value(); }
                }
            }
            int main() {
                auto holder = new Holder;
                auto owner = new Owner;
                auto inner = owner.new Inner;
                return inner.run(holder) == 42 ? 0 : 1;
            }
        });
    }
}


// A nested function template is dual-context too: word 0 of its pair is
// the frame of the function that declares it, word 1 the frame of the
// function that owns the alias. A delegate to it holds the address of
// the pair.
static foreach (backend; Matrix!()) {
    @("callDualContextNestedFunctionThroughDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int outerLocal = 40;
                int callee() { return outerLocal; }
                int owner() {
                    int innerLocal = 2;
                    int add(alias other)() { return innerLocal + other(); }
                    auto callback = &add!callee;
                    return callback();
                }
                return owner() == 42 ? 0 : 1;
            }
        });
    }
}

// The delegate to the dual-context nested function is called after the
// function that declares it returned.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE does not support closures"),
)) {
    @("callDualContextNestedFunctionThroughEscapedDelegate."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int outerLocal = 40;
                int callee() { return outerLocal; }
                int delegate() owner() {
                    int innerLocal = 2;
                    int add(alias other)() { return innerLocal + other(); }
                    return &add!callee;
                }
                auto callback = owner();
                return callback() == 42 ? 0 : 1;
            }
        });
    }
}


// A class template nested in a class and instantiated with an alias to a
// nested function has two context fields: the outer object, and the frame
// of the function that owns the alias.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine reads a null outer object in a dual-context "
            ~ "class"),
)) {
    @("callNestedFunctionFromDualContextClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int base = 2;
                class Inner(alias callee) {
                    int call() { return base + callee(); }
                }
            }
            int main() {
                int local = 40;
                int nested() { return local; }
                auto outer = new Outer;
                auto inner = outer.new Outer.Inner!nested;
                return inner.call() == 42 ? 0 : 1;
            }
        });
    }
}

// The caller is a dual-context member too, so the `this` that owns the
// alias is word 1 of the caller's own pair, not the caller's receiver:
// dmd's code generator selects the word of each dual-context function on
// the path with `followInstantiationContext`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine does not implement a read through the second "
            ~ "context of a dual-context function that another one calls"),
)) {
    @("callDualContextMemberFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
                int relay(alias field)() { return add!field(); }
            }
            struct Owner {
                int value = 40;
                int run(ref Holder holder) { return holder.relay!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                return owner.run(holder) == 42 ? 0 : 1;
            }
        });
    }
}

// As above, with the call in a lambda in the dual-context member, so the
// pair of the member is one step up the static chain.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine asserts on a dual-context function called from "
            ~ "a lambda in a dual-context function"),
)) {
    @("callDualContextMemberFromLambdaInDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                int add(alias field)() { return base + field; }
                int relay(alias field)() {
                    auto lambda = () => add!field();
                    return lambda();
                }
            }
            struct Owner {
                int value = 40;
                int run(ref Holder holder) { return holder.relay!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                return owner.run(holder) == 42 ? 0 : 1;
            }
        });
    }
}

// A dual-context class made in a dual-context member: its second context
// field holds word 1 of the pair of the member.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine reads a null outer object in a dual-context "
            ~ "class"),
)) {
    @("makeDualContextClassInDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int base = 2;
                class Inner(alias field) {
                    int call() { return base + field; }
                }
            }
            struct Holder {
                int padding = 5;
                int relay(alias field)(Outer outer) {
                    auto inner = outer.new Outer.Inner!field;
                    return inner.call();
                }
            }
            struct Owner {
                int value = 40;
                int run(ref Holder holder, Outer outer) {
                    return holder.relay!value(outer);
                }
            }
            int main() {
                Holder holder;
                Owner owner;
                return owner.run(holder, new Outer) == 42 ? 0 : 1;
            }
        });
    }
}

// The alias argument of a dual-context class is a field of a base class of
// the class whose member makes the object. The second context field is
// then the `this` of that member: `setEthis` in dmd's code generator
// accepts a base class of the class of the calling member.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine reads a null outer object in a dual-context "
            ~ "class"),
)) {
    @("readFieldOfBaseClassFromDualContextClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int base = 2;
                class Inner(alias field) {
                    int call() { return base + field; }
                }
            }
            class Base { int value = 40; }
            class Derived : Base {
                int run(Outer outer) {
                    auto inner = outer.new Outer.Inner!value;
                    return inner.call();
                }
            }
            int main() {
                auto derived = new Derived;
                return derived.run(new Outer) == 42 ? 0 : 1;
            }
        });
    }
}

// As above, with the object made in a function nested in the member, so
// the `this` of the member is one step up the static chain.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine reads a null outer object in a dual-context "
            ~ "class"),
)) {
    @("readFieldOfBaseClassFromDualContextClassMadeInNestedFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int base = 2;
                class Inner(alias field) {
                    int call() { return base + field; }
                }
            }
            class Base { int value = 40; }
            class Derived : Base {
                int run(Outer outer) {
                    int nested() {
                        auto inner = outer.new Outer.Inner!value;
                        return inner.call();
                    }
                    return nested();
                }
            }
            int main() {
                auto derived = new Derived;
                return derived.run(new Outer) == 42 ? 0 : 1;
            }
        });
    }
}

// A dual-context nested function called directly: its second context is
// the frame of the function that owns the alias.
static foreach (backend; Matrix!()) {
    @("callDualContextNestedFunctionDirectly." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int outerLocal = 40;
                int callee() { return outerLocal; }
                int innerLocal = 2;
                int add(alias other)() { return innerLocal + other(); }
                return add!callee() == 42 ? 0 : 1;
            }
        });
    }
}

// A compound assignment to the field of another struct goes through the
// second context, which dmd types as a pointer to the struct.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("compoundAssignFieldOfOtherStructFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                int base = 2;
                void bump(alias field)() { field += base; field *= 2; ++field; }
            }
            struct Owner {
                int value = 19;
                void run(ref Holder holder) { holder.bump!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                owner.run(holder);
                return owner.value == 43 ? 0 : 1;
            }
        });
    }
}

// The field of another struct passed by `ref` is the address of that
// field in the object behind the second context.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("passFieldOfOtherStructByRefFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void addTwo(ref int number) { number += 2; }
            struct Holder {
                void touch(alias field)() { addTwo(field); }
            }
            struct Owner {
                int value = 40;
                void run(ref Holder holder) { holder.touch!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                owner.run(holder);
                return owner.value == 42 ? 0 : 1;
            }
        });
    }
}

// Taking the address of the field of another struct gives a pointer into
// the object behind the second context.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("addressOfFieldOfOtherStructFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                void store(alias field)() {
                    int* pointer = &field;
                    *pointer = 42;
                }
            }
            struct Owner {
                int value = 40;
                void run(ref Holder holder) { holder.store!value(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                owner.run(holder);
                return owner.value == 42 ? 0 : 1;
            }
        });
    }
}

// A method call on a struct field of another struct passes the address of
// that field as its receiver.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on a dual-context "
            ~ "function whose second context is a struct `this`"),
)) {
    @("callMethodOfFieldOfOtherStructFromDualContextMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int count;
                void add(int amount) { count += amount; }
            }
            struct Holder {
                void touch(alias field)() { field.add(42); }
            }
            struct Owner {
                Counter counter;
                void run(ref Holder holder) { holder.touch!counter(); }
            }
            int main() {
                Holder holder;
                Owner owner;
                owner.run(holder);
                return owner.counter.count == 42 ? 0 : 1;
            }
        });
    }
}
