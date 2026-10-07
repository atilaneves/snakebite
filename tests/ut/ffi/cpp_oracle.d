module ut.ffi.cpp_oracle;


// What compiled D does with non-trivially-copyable values that cross into
// the C++ test library (tests/fixtures/native/cpp_image.cpp). The types
// below have the C++ library's own layout, but their copy constructors,
// postblit and destructors are D code that count into this module, because
// `bin/ut` does not link the C++ object: the library's own members are never
// called from here, only its free functions and methods, through pointers.
// The namespace keeps the D-defined members' symbols apart from the
// library's.
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
        this(int v) { value = v; }
        this(ref const(NonPod) other) { value = other.value; ++_copied; }
        ~this() { ++_destroyed; }
    }

    struct DtorOnly {
        int value;
        ~this() { ++_destroyed; }
    }

    struct CopyOnly {
        int value;
        this(ref const(CopyOnly) other) { value = other.value; ++_copied; }
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
    alias CountFn = int function();
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
private CountFn libraryDestroyed;
private CountFn libraryCopied;
private MakerMakeFn makeFn;
private MakerReadFn readFn;

// Callbacks the guest hands to the library. Mixed in here and into each
// guest program, so both define them with the same text.
enum handlers = q{
    extern(C++) int receiveHandler(NonPod n) { return n.value * 2; }
    extern(C++) NonPod returnHandler(int v) {
        NonPod n;
        n.value = v * 3;
        return n;
    }
};
mixin(handlers);



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
    call_non_pod_callback = symbol!CallNonPodCallbackFn(
        image, "_Z21call_non_pod_callbackPFi6NonPodEi");
    call_non_pod_maker_callback = symbol!CallNonPodMakerCallbackFn(
        image, "_Z27call_non_pod_maker_callbackPF6NonPodiEi");
}

Counts nativeShape(string body_)(int v) {
    const destroyedBefore = _destroyed + libraryDestroyed();
    const copiedBefore = _copied + libraryCopied();
    int r;
    {
        mixin(body_);
    }
    return Counts(r, _destroyed + libraryDestroyed() - destroyedBefore,
        _copied + libraryCopied() - copiedBefore);
}
