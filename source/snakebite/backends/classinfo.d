module snakebite.backends.classinfo;


private:


import dmd.dclass: ClassDeclaration;
import dmd.func: FuncDeclaration;
import object: Interface, TypeInfo_Class;


// Guest classes never reach dmd's own code generator, so nothing ever
// emits their `TypeInfo_Class`, instance vtable or `.init` bytes as real
// linked data - both backends build the same shapes by hand instead, from
// the same `ClassDeclaration`. What differs between them is only how a
// vtable slot gets its callable value (an interpreter has no compiled
// address to put there; the bytecode compiler has a `Function*` for every
// guest override), how a slot in a concrete class's per-interface vtable
// gets its callable value (interface dispatch means a second, differently
// shaped question - see `interfaceVtable` below), and how a field's own
// default value is written into the `.init` bytes. Those three questions
// are asked through `Hooks`; everything else - the base chain, the two
// vtable sizes, the native special cases for `Object`/`Throwable`/
// `Exception`/`Error`, and the recursion into a base or an interface - is
// asked once, here.
public struct Hooks {
    // The value for `declaration.vtbl[i]`'s own slot, `method` being the
    // override dmd resolved there - `null` when the caller has nothing to
    // put there (an interpreter dispatches a guest virtual call through
    // dmd's own `ClassDeclaration.vtbl` directly, never through this
    // native vtable, so this slot is left however it already reads: a
    // native address copied down from the base, or unset).
    public void* delegate(FuncDeclaration method) methodAddress;

    // `concrete`'s own override for every method `interface_` declares, in
    // `interface_`'s own vtable order - not `concrete`'s, since a call
    // through an interface reference only ever has the interface's own
    // method index to work from. `interfaceInfo` is `interface_`'s own,
    // already-built `TypeInfo_Class`, handed back in case reusing its
    // (otherwise unused) vtable is all a caller needs.
    public void*[] delegate(
        ClassDeclaration concrete,
        ClassDeclaration interface_,
        TypeInfo_Class interfaceInfo,
    ) interfaceVtable;

    // Every field `declaration` itself declares - not an inherited one,
    // already present in `base` by the time this runs - written at its own
    // offset into `base`.
    public void delegate(ClassDeclaration declaration, ubyte* base)
        fillFieldInits;
}

public alias ClassRuntimeCache = TypeInfo_Class[ClassDeclaration];

// The native metadata a guest class needs at run time: an instance vtable
// (`vtbl[0]` the classinfo pointer, `vtbl[1 .. $]` every guest override in
// the same slots dmd's own `ClassDeclaration.vtbl` already assigns them -
// `vtblOffset` is `1` for a D class, never `0`), a per-interface vtable
// for every interface `declaration` implements, and the `.init` bytes
// `_d_newclassT`'s real body would otherwise copy from a linked symbol
// this project's compiler never emits.
//
// Cached by declaration, in `cache`: every `new`, virtual call and
// `typeid` of the same class reuses the one instance built the first
// time any of them needs it. Registered there before its own vtable and
// fields are filled in, so a class that reaches itself again while
// walking a base or interface chain - direct or mutual recursion - finds
// this same (possibly still-filling) object instead of recursing forever.
public TypeInfo_Class classRuntimeInfo(
    ClassDeclaration declaration,
    ref ClassRuntimeCache cache,
    Hooks hooks,
) {
    if (declaration is ClassDeclaration.object)
        return typeid(Object);

    if (auto cached = declaration in cache)
        return *cached;

    import dmd.root.string: toDString;

    auto typeInfo = new TypeInfo_Class;
    // `TypeInfo_Class.ClassFlags`'s own default (`.init`) is `isCOMclass`,
    // its first member, not `0` - left alone, a guest class not actually a
    // COM class would still carry that flag.
    typeInfo.m_flags = cast(TypeInfo_Class.ClassFlags) 0;
    typeInfo.name = cast(string) declaration.toPrettyChars.toDString;
    cache[declaration] = typeInfo;

    // Only the exact native declaration routes to druntime's own
    // `typeid`: a guest class over a guest class that itself derives from
    // `Exception` (`OutOfBytesError : MinicerealError : Exception`) must
    // still recurse into `classRuntimeInfo` for its own guest base, or
    // `MinicerealError`'s own runtime info - the one every
    // `catch (MinicerealError)` clause names - never gets built, and its
    // slot in the base chain silently becomes `Exception` instead.
    TypeInfo_Class baseInfo;
    if (declaration.isInterfaceDeclaration !is null)
        baseInfo = null;
    else if (declaration.baseClass is null
            || declaration.baseClass is ClassDeclaration.object)
        baseInfo = typeid(Object);
    else if (declaration.baseClass is ClassDeclaration.throwable)
        baseInfo = typeid(Throwable);
    else if (declaration.baseClass is ClassDeclaration.exception)
        baseInfo = typeid(Exception);
    else if (declaration.baseClass is ClassDeclaration.errorException)
        baseInfo = typeid(Error);
    else
        baseInfo = classRuntimeInfo(declaration.baseClass, cache, hooks);

    typeInfo.base = baseInfo;

    // A slot this class never overrides still names the base's own method
    // (`Throwable.toString`, `Object.opEquals`, ...) - copied down rather
    // than left unset, since native code (a native base class's own
    // constructor, for one) calls through this vtable directly and needs
    // a real address there.
    //
    // `declaration.vtbl` only lists the slots dmd's frontend resolved
    // while compiling this class; a guest class over a native base
    // (`Exception`, ...) can end up with a shorter list than the base
    // class's own real vtable, since dmd never lowers the native base's
    // full body here. The vtable is always at least as long as the
    // base's, so every native slot still has a home.
    const baseVtableLength = baseInfo is null ? 0 : baseInfo.vtbl.length;
    const vtableLength = declaration.vtbl.length > baseVtableLength
        ? declaration.vtbl.length : baseVtableLength;
    auto vtbl = new void*[vtableLength];
    if (baseInfo !is null)
        vtbl[0 .. baseVtableLength] = baseInfo.vtbl[];
    vtbl[0] = cast(void*) typeInfo;
    // An interface's own slots name its abstract methods, none with a
    // body a caller could ever compile - only a concrete class's own
    // override is ever a callable value, and only a concrete class ever
    // has `.init` bytes to write one into.
    if (declaration.isInterfaceDeclaration is null) {
        foreach (i; 1 .. declaration.vtbl.length) {
            auto method = declaration.vtbl[i].isFuncDeclaration;
            if (method is null)
                continue;

            auto address = hooks.methodAddress(method);
            if (address !is null)
                vtbl[i] = address;
        }

        typeInfo.m_init = new byte[](declaration.structsize);
        if (baseInfo !is null && baseInfo.m_init.length != 0)
            typeInfo.m_init[0 .. baseInfo.m_init.length] = baseInfo.m_init[];
        *cast(void**) typeInfo.m_init.ptr = vtbl.ptr;
        hooks.fillFieldInits(declaration, cast(ubyte*) typeInfo.m_init.ptr);
    }
    typeInfo.vtbl = vtbl;

    if (declaration.interfaces.length != 0) {
        typeInfo.interfaces = new Interface[declaration.interfaces.length];
        foreach (i, base; declaration.interfaces) {
            auto interfaceInfo =
                classRuntimeInfo(base.sym, cache, hooks);
            typeInfo.interfaces[i] = Interface(
                interfaceInfo,
                hooks.interfaceVtable(declaration, base.sym, interfaceInfo),
                base.offset,
            );
        }
    }

    return typeInfo;
}
