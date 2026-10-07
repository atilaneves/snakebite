module ut.ffi.cpp_oracle;


// What compiled D does with non-trivially-copyable values that cross into
// the C++ test library (tests/fixtures/native/cpp_image.cpp). The types
// below have the C++ library's own layout, but their copy constructors,
// postblit, destructors and class methods are D code, because `bin/ut` does
// not link the C++ object. The library is called through pointers: its free
// functions, its methods and the constructor of `Base`, which the D `Base`
// runs on its own object. The namespace keeps the D-defined members'
// symbols apart from the library's.
//
// A shape body is the same text a guest program runs. `nativeShape` mixes it
// into a function here, where the names it uses (`make_non_pod`, ...) are
// function pointers of the same shape as the guest's declarations.


import snakebite.dependencyimage: DependencyImage;


struct Counts {
    int result;
    int destroyed;
    int copied;
}

private int _destroyed;
private int _copied;

extern(C++, ut_oracle) {
    struct NonPod {
        int value;
        this(ref const(NonPod) other) { value = other.value; ++_copied; }
        ~this() { ++_destroyed; }
    }

    struct DtorOnly {
        int value;
        ~this() { ++_destroyed; }
    }

    struct CopyOnly {
        int value;
        this(int v) { value = v; }
        this(ref const(CopyOnly) other) { value = other.value; ++_copied; }
    }

    struct Thrower {
        int value;
        this(ref const(Thrower) other) {
            value = other.value;
            throwInt(7);
        }
    }

    struct PostBlit {
        int value;
        this(this) { ++_copied; }
        ~this() { ++_destroyed; }
    }

    struct NonPodMaker {
        int base;
        NonPod make(int v) { return makeFn(&this, v); }
        int read(NonPod n) { return readFn(&this, n); }
    }

    // The constructor runs the library's own, which writes the library's
    // vtable into the object; the D object keeps its own.
    class Base {
        int tag_;
        this(int tag) {
            auto vtable = *cast(void**) cast(void*) this;
            libraryBaseConstructor(cast(void*) this, tag);
            *cast(void**) cast(void*) this = vtable;
        }
        final int tag_value() { return tag_; }
        int first() { return tag_ * 10; }
        int second() { return tag_ * 100; }
    }

    class Derived : Base {
        this(int tag) { super(tag); }
        override int first() { return tag_ * 10 + 1; }
    }
}

extern(C++) {
    alias MakeNonPodFn = NonPod function(int);
    alias ReadNonPodFn = int function(NonPod);
    alias MakeDtorOnlyFn = DtorOnly function(int);
    alias ReadDtorOnlyFn = int function(DtorOnly);
    alias MakeCopyOnlyFn = CopyOnly function(int);
    alias ReadCopyOnlyFn = int function(CopyOnly);
    alias MakePostBlitFn = PostBlit function(int);
    alias ReadPostBlitFn = int function(PostBlit);
    alias MakerMakeFn = NonPod function(NonPodMaker*, int);
    // A reference is what a non-trivially-copyable value is at the ABI, and it
    // keeps the forwarding method above from copying or destroying again.
    alias MakerReadFn = int function(NonPodMaker*, ref NonPod);
    alias NonPodCallback = int function(NonPod);
    alias NonPodMakerCallback = NonPod function(int);
    alias ThrowAfterReadFn = int function(NonPod);
    alias IntCallback = int function(int);
    alias CatchAroundFn = int function(IntCallback, int);
    alias ReadThrowerFn = int function(Thrower);
    alias ThrowIntFn = void function(int);
    alias CountFn = int function();
    alias BaseConstructorFn = void function(void*, int);
    alias CallNonPodCallbackFn = int function(NonPodCallback, int);
    alias CallNonPodMakerCallbackFn = int function(NonPodMakerCallback, int);
}

MakeNonPodFn make_non_pod;
ReadNonPodFn read_non_pod;
MakeDtorOnlyFn make_dtor_only;
ReadDtorOnlyFn read_dtor_only;
MakeCopyOnlyFn make_copy_only;
ReadCopyOnlyFn read_copy_only;
MakePostBlitFn make_post_blit;
ReadPostBlitFn read_post_blit;
CallNonPodCallbackFn call_non_pod_callback;
CallNonPodMakerCallbackFn call_non_pod_maker_callback;
ThrowAfterReadFn throw_after_read;
CatchAroundFn catch_around;
ReadThrowerFn read_thrower;
private ThrowIntFn throwInt;
private CountFn libraryDestroyed;
private CountFn libraryCopied;
private MakerMakeFn makeFn;
private MakerReadFn readFn;
private BaseConstructorFn libraryBaseConstructor;

// Callbacks the guest hands to the library. Mixed in here and into each
// guest program, so both define them with the same text.
enum handlers = q{
    extern(C++) int receiveHandler(NonPod n) { return n.value * 2; }
    extern(C++) NonPod returnHandler(int v) {
        NonPod n;
        n.value = v * 3;
        return n;
    }
    extern(C++) int throwingHandler(int v) {
        return throw_after_read(make_non_pod(v));
    }
    extern(C++) int cleanupThrowCaughtHandler(int v) {
        try {
            scope(exit) throw new Exception("boom");
            return throw_after_read(make_non_pod(v));
        } catch (Exception e) {
            return 66;
        }
    }
    int cleanupThrowingHelper(int v) {
        scope(exit) throw new Exception("boom");
        return throw_after_read(make_non_pod(v));
    }
    extern(C++) int cleanupThrowCaughtAboveHandler(int v) {
        auto n = make_non_pod(v);
        try {
            return cleanupThrowingHelper(v);
        } catch (Exception e) {
            return 66;
        }
    }
    extern(C++) int finallyThrowsHandler(int v) {
        try {
            throw new Exception("boom");
        } finally {
            count_copy();
            throw_after_read(make_non_pod(v));
        }
    }
    extern(C++) int copyThrowingHandler(int v) {
        auto local = make_non_pod(v);
        Thrower thrower;
        thrower.value = v;
        return read_thrower(thrower);
    }
};
mixin(handlers);

void count_copy() { ++_copied; }



void bind(in DependencyImage image) {
    static T symbol(T)(in DependencyImage image, string name) {
        auto address = image.resolve(name);
        assert(address !is null, "cpp_oracle: missing C++ symbol " ~ name);
        return cast(T) address;
    }
    make_non_pod = symbol!MakeNonPodFn(image, "_Z12make_non_podi");
    read_non_pod = symbol!ReadNonPodFn(image, "_Z12read_non_pod6NonPod");
    make_dtor_only = symbol!MakeDtorOnlyFn(image, "_Z14make_dtor_onlyi");
    read_dtor_only = symbol!ReadDtorOnlyFn(image, "_Z14read_dtor_only8DtorOnly");
    make_copy_only = symbol!MakeCopyOnlyFn(image, "_Z14make_copy_onlyi");
    read_copy_only = symbol!ReadCopyOnlyFn(image, "_Z14read_copy_only8CopyOnly");
    make_post_blit = symbol!MakePostBlitFn(image, "_Z14make_post_bliti");
    read_post_blit = symbol!ReadPostBlitFn(image, "_Z14read_post_blit8PostBlit");
    libraryDestroyed = symbol!CountFn(image, "_Z15destroyed_countv");
    libraryCopied = symbol!CountFn(image, "_Z12copied_countv");
    makeFn = symbol!MakerMakeFn(image, "_ZN11NonPodMaker4makeEi");
    readFn = symbol!MakerReadFn(image, "_ZN11NonPodMaker4readE6NonPod");
    libraryBaseConstructor = symbol!BaseConstructorFn(image, "_ZN4BaseC1Ei");
    throw_after_read = symbol!ThrowAfterReadFn(
        image, "_Z16throw_after_read6NonPod");
    catch_around = symbol!CatchAroundFn(image, "_Z12catch_aroundPFiiEi");
    read_thrower = symbol!ReadThrowerFn(image, "_Z12read_thrower7Thrower");
    throwInt = symbol!ThrowIntFn(image, "_Z9throw_inti");
    call_non_pod_callback = symbol!CallNonPodCallbackFn(
        image, "_Z21call_non_pod_callbackPFi6NonPodEi");
    call_non_pod_maker_callback = symbol!CallNonPodMakerCallbackFn(
        image, "_Z27call_non_pod_maker_callbackPF6NonPodiEi");
}

Counts nativeShape(Shape)(int v) {
    const destroyedBefore = _destroyed + libraryDestroyed();
    const copiedBefore = _copied + libraryCopied();
    int r;
    {
        mixin(Shape.body_);
    }
    return Counts(r, _destroyed + libraryDestroyed() - destroyedBefore,
        _copied + libraryCopied() - copiedBefore);
}
