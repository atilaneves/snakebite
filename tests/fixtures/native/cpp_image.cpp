struct Point {
    int x;
    int y;
};

int add_ints(int a, int b) { return a + b; }
double add_doubles(double a, double b) { return a + b; }
int sum_point(Point p) { return p.x + p.y; }

// Three words: 24 bytes, more than the two-eightbyte SysV register
// limit. A method that returns this must use the hidden return
// pointer (`abi.needsHiddenReturnPointer`) - and for `extern(C++)`,
// unlike `extern(D)`, `this` follows that pointer instead of coming
// before it (`abi.contextPrecedesHiddenReturnPointer`). That order is
// the one ABI fact this branch changes (issue #336 review, finding 4).
struct Big {
    unsigned long a;
    unsigned long b;
    unsigned long c;
};

// Every method reads a field through `this`. A non-virtual call with
// a wrong or null `this` then returns the wrong answer, not the same
// constant every call used to return (issue #336 review, finding 3).
// `first` and `second` are both virtual, so a vtable slot swap - not
// only a crash - shows up as a wrong value on one of them. `bigVirtual`
// is a third virtual slot that also returns through the hidden
// pointer, so a virtual call pins finding 4's ABI fact too, not only
// a non-virtual one. `tag_value` and `big` stay non-virtual, so
// `Derived` overriding only `first` still leaves a vtable with one
// overridden slot next to two inherited ones.
//
// Neither class declares a destructor: an `extern(C++)` class in D
// mirrors the C++ side's own virtual function order to compute the
// right vtable slot (`ClassDeclaration.vtblIndex`), and a virtual
// destructor the D side never repeats would shift every slot after it.
//
// Every method is defined out of its class body, not inline: an
// unused inline definition is not guaranteed a symbol in the compiled
// object at all, and this library's whole point is to be called from
// outside its own translation unit.
class Base {
protected:
    int tag_;
public:
    Base(int tag);
    int tag_value();
    virtual int first();
    virtual int second();
    Big big();
    virtual Big bigVirtual();
};

class Derived : public Base {
public:
    Derived(int tag);
    int first() override;
};

Base::Base(int tag) : tag_(tag) {}
int Base::tag_value() { return tag_; }
int Base::first() { return tag_ * 10; }
int Base::second() { return tag_ * 100; }
Big Base::big() {
    return Big{
        (unsigned long) tag_, (unsigned long) (tag_ + 1),
        (unsigned long) (tag_ + 2),
    };
}
Big Base::bigVirtual() { return big(); }

Derived::Derived(int tag) : Base(tag) {}
int Derived::first() { return tag_ * 10 + 1; }

static Base baseInstance(7);
static Derived derivedInstance(7);

Base* get_base() { return &baseInstance; }
Base* get_derived_as_base() { return &derivedInstance; }

// One resolved symbol reaches a class method - `ut.ffi.symbol`'s own
// pattern for a free function. These wrappers let the `Native` row
// below call the very same compiled method the other rows reach
// through the barrier, instead of only asserting a constant (issue
// #336 review, finding 8).
int call_tag_value(Base* b) { return b->tag_value(); }
int call_first(Base* b) { return b->first(); }
int call_second(Base* b) { return b->second(); }
Big call_big(Base* b) { return b->big(); }
Big call_big_virtual(Base* b) { return b->bigVirtual(); }

// A struct, not a class, with its own method: `this` is the address
// of a value type's storage, not a class reference
// (`FrameLayout.of`'s own `isRefThis` case for a struct - issue #336
// review, finding 13).
struct Vector2 {
    int x;
    int y;
    int sum();
};
int Vector2::sum() { return x + y; }
int call_vector_sum(Vector2* v) { return v->sum(); }

struct NonPod {
    int value;
    NonPod(int v);
    NonPod(const NonPod& other);
    ~NonPod();
};

static int destroyedCount = 0;

NonPod::NonPod(int v) : value(v) {}
NonPod::NonPod(const NonPod& other) : value(other.value) {}
NonPod::~NonPod() { ++destroyedCount; }

int read_non_pod(NonPod n) { return n.value; }
NonPod make_non_pod(int v) { return NonPod(v); }
int destroyed_count() { return destroyedCount; }

// A callback that itself takes a non-trivially-copyable value by
// hidden reference: the reverse plan (`prepareCallback`) must unpack
// that reference the same way a forward call does (issue #336 review,
// finding 13).
typedef int (*NonPodCallback)(NonPod);
int call_non_pod_callback(NonPodCallback callback, int v) {
    return callback(NonPod(v));
}

// Never instantiated anywhere in this file: its mangled name never
// reaches the compiled object.
template <typename T>
T uninstantiated_template(T value) { return value; }
