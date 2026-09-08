module snakebite.backends.elementaddress;


private:


import snakebite.nativelayout: TypeFacts;
import snakebite.ffi.abi: Register;


// What `IndexExp.e1`/`SliceExp.e1` actually is, once dmd's own semantic
// pass has already proved the expression well-typed. The bytecode
// compiler and the interpreter used to re-derive this from the same
// `expression.e1.type.ty` checks, one arm at a time, in three different
// methods each; `classify` decides it once, and each backend keeps only
// the primitive that computes an address or a bound from the chosen kind.
public enum BaseKind {
    // `struct { size_t length; T* ptr; }`, native layout.
    dynamicArray,
    // Contiguous elements, no header: the array's own storage is the
    // element storage.
    staticArray,
    // No header and no bound of its own - indexing or slicing a pointer
    // is `@system` in compiled D for exactly this reason.
    pointer,
}

// Where the element count to bound-check against comes from.
public enum LengthSource {
    // No bound exists; a pointer index or an unbounded pointer slice is
    // never checked, the same as compiled D.
    none,
    // The dynamic array's own length word, read at run time.
    runtimeWord,
    // `TypeSArray.dim`, already known at compile time.
    staticDimension,
}

public struct ElementAddressPlan {
    public BaseKind base;
    public LengthSource length;
    public TypeFacts elementFacts;
    // Meaningful only when `length` is `staticDimension`.
    public size_t staticLength;
}

// The single decision both backends' `IndexExp`/`SliceExp` adapters read:
// `arrayType` is `expression.e1.type`, already typed by dmd.
public ElementAddressPlan classify(imported!"dmd.mtype".Type arrayType) {
    import dmd.astenums: Tpointer, Tsarray;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf;

    if (arrayType.ty == Tpointer)
        return ElementAddressPlan(
            BaseKind.pointer, LengthSource.none,
            TypeFacts.of(arrayType.nextOf),
        );

    if (arrayType.ty == Tsarray) {
        auto sarrayType = arrayType.isTypeSArray;
        return ElementAddressPlan(
            BaseKind.staticArray, LengthSource.staticDimension,
            TypeFacts.of(sarrayType.next),
            cast(size_t) sarrayType.dim.toInteger,
        );
    }

    return ElementAddressPlan(
        BaseKind.dynamicArray, LengthSource.runtimeWord,
        TypeFacts.of(arrayType.nextOf),
    );
}

// Compiled D specifies `core.exception.ArrayIndexError`/`ArraySliceError`
// (both a `RangeError`) for an out-of-bounds index or slice - see
// CLAUDE.md's runtime-semantics rule against reimplementing druntime.
// Both backends reach the failure through `PlanCache.rawPlanOf`, keyed by
// this name, rather than raising a backend-specific exception of their
// own: a guest `catch (RangeError)` then sees the same throwable whichever
// backend ran it, and neither backend re-derives druntime's message.
public immutable string indexBoundsHook = "_d_arraybounds_indexp";
public immutable string sliceBoundsHook = "_d_arraybounds_slicep";

// `_d_arraybounds_indexp(const(char)* file, uint line, size_t index,
// size_t length)` - one call site regardless of `BaseKind`, since the
// hook itself only ever runs on the failure path.
public immutable Register[4] indexBoundsRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
];

// `_d_arraybounds_slicep(const(char)* file, uint line, size_t lower,
// size_t upper, size_t length)`.
public immutable Register[5] sliceBoundsRegisters = [
    Register(Register.Kind.pointer, 8),
    Register(Register.Kind.unsigned, 4),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
    Register(Register.Kind.unsigned, 8),
];
