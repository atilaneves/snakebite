module snakebite.nativelayout;


private:


import snakebite.nativevalue:
    nativeArrayLengthOffset = arrayLengthOffset,
    nativeArrayPointerOffset = arrayPointerOffset,
    nativeArrayValueSize = arrayValueSize,
    nativeDelegateContextOffset = delegateContextOffset,
    nativeDelegateFunctionOffset = delegateFunctionOffset,
    nativeDelegateValueSize = delegateValueSize,
    nativeIsIntegralSize = isIntegralSize,
    nativeLoadIntegral = loadIntegral,
    nativeStoreIntegral = storeIntegral;

public alias arrayLengthOffset = nativeArrayLengthOffset;
public alias arrayPointerOffset = nativeArrayPointerOffset;
public alias arrayValueSize = nativeArrayValueSize;
public alias delegateContextOffset = nativeDelegateContextOffset;
public alias delegateFunctionOffset = nativeDelegateFunctionOffset;
public alias delegateValueSize = nativeDelegateValueSize;

// `snakebite.backends.interpreter.walker` calls this on every integral
// assignment it interprets, so it collapses into that caller instead of
// staying a real call boundary on that hot path - not, any more, for an
// FFI return-value write (issue #334 deleted that caller, `abi.
// writeWord`).
pragma(inline, true) public bool isIntegralSize(in size_t size) {
    return nativeIsIntegralSize(size);
}

public bool isNativeBytes(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tvector;
    import dmd.typesem:
        isIntegral, needsCopyOrPostblit, needsDestruction, needsNested, size;

    if (type.ty == Tvector)
        return false;
    if (type.isIntegral && !isIntegralSize(type.size))
        return false;
    return !type.needsCopyOrPostblit
        && !type.needsDestruction
        && !type.needsNested;
}

// Keep the DMD-facing module's historical error behavior while the actual
// byte operations live in the DMD-free native-value module. Backend code
// that already validated its widths can call that module directly.
// `snakebite.backends.interpreter.walker` is this wrapper's own hot
// caller - one of these on nearly every assignment it interprets - so
// this still collapses into it instead of staying a real call boundary;
// not, any more, for an FFI return-value write (issue #334 deleted that
// caller, `abi.writeWord`).
pragma(inline, true) public void storeIntegral(
    void* place, in ulong value, in size_t size,
) {
    import std.conv: text;

    if (!isIntegralSize(size))
        throw new Exception(
            text("no native layout for an integral of ", size, " byte(s)"),
        );
    nativeStoreIntegral(place, value, size);
}

// Reads `size` bytes at `place`, laid out as compiled D lays them out, and
// widens them to 64 bits: sign-extended if `signed`, zero-extended
// otherwise. The result is a `long` either way - for an unsigned width the
// caller reinterprets it as `ulong`, the same 64 bits, since D has no
// integral type wider than either.
//
// The counterpart to `storeIntegral`: an interpreter comparing two
// integral operands needs the bytes-to-value direction as well as the one
// `storeIntegral` already covers.
public long loadIntegral(in void* place, in size_t size, in bool signed) {
    import std.conv: text;

    if (!isIntegralSize(size))
        throw new Exception(
            text("no native layout for an integral of ", size, " byte(s)"),
        );
    return nativeLoadIntegral(place, size, signed);
}

// What a caller on a hot execution path repeatedly asks a dmd `Type`
// for - its size, its alignment, whether it is integral, and if so
// whether it is signed - decided once and kept, instead of re-entering
// dmd's semantic-analysis machinery (`Type.size`, `TypeBasic.alignsize`,
// `isIntegral`, `isUnsigned`) on every visit of the same node. Shared
// between backends (not owned by the interpreter package) because any
// tree-walking or bytecode backend asks a dmd `Type` the same four
// questions to lay a value out in native memory.
public struct TypeFacts {
    import dmd.mtype: Type;

    public size_t size;
    public uint alignment;
    public bool isIntegral;
    public bool isUnsigned;
    // Whether `type` is a dynamic array (`T[]`) - the native `{length,
    // pointer}` pair, always `arrayValueSize` bytes regardless of `T`. A
    // caller that only moves a value between slots (`opCopy`/`opConstant`,
    // parameter passing, a return) needs nothing more than this and `size`
    // to do so correctly; only a caller that indexes into the array needs
    // `elementSize` as well.
    public bool isDynamicArray;
    // The element type's own size, meaningful only when `isDynamicArray` is
    // `true` - what indexing has to multiply an index by to find an
    // element's byte offset from the array's own pointer word.
    public size_t elementSize;

    // A pointer-sized slot: what a `ref`/`out` parameter or local, a
    // struct's hidden `this`, or a `ref` return's own place all hold -
    // the argument's or result's own address, never its pointee's facts.
    // Every backend that reserves such a slot reserves it with this same
    // shape, so it is decided once here rather than spelled out with the
    // same four literals at each call site.
    public static TypeFacts pointer() {
        return TypeFacts(size_t.sizeof, size_t.sizeof, false, false);
    }

    // A delegate value's own slot: the fixed two-word `{context,
    // function}` pair, whatever the delegate's own signature.
    public static TypeFacts delegateValue() {
        return TypeFacts(delegateValueSize, size_t.sizeof, false, false);
    }

    // A `lazy` parameter's own slot: dmd's own implicit delegate, the
    // same two words regardless of the type it wraps - never the wrapped
    // type's own facts.
    public alias lazyArgument = delegateValue;

    // The facts for `type`, read from dmd exactly once by the caller
    // that builds this. `resolved`/`forceResolved` force any forward
    // reference `size`/`alignsize`/`toBasetype` below could still
    // resolve, under the frontend lock, before this asks dmd anything -
    // see their own doc for why a call that finds nothing to force
    // needs no lock.
    public static TypeFacts of(Type type) {
        import dmd.astenums: Tarray;
        import dmd.typesem:
            alignsize, isIntegral, isUnsigned, nextOf, size, toBasetype;
        import snakebite.frontend.compiler: forceIfNeeded;

        forceIfNeeded(() => resolved(type), () { forceResolved(type); });

        // An enum value has the representation of its base type. Keeping
        // that representation here lets every byte-storage caller use the
        // same facts for enum values with floating or string bases.
        type = type.toBasetype;

        if (type.ty == Tarray) {
            forceIfNeeded(
                () => resolved(type.nextOf),
                () { forceResolved(type.nextOf); },
            );
            return TypeFacts(
                arrayValueSize, size_t.alignof, false, false, true,
                type.nextOf.size,
            );
        }

        return TypeFacts(
            type.size,
            type.alignsize,
            type.isIntegral,
            type.isUnsigned,
        );
    }

    // Whether every forward reference `toBasetype`/`size`/`alignsize`
    // could still resolve for `type` is already resolved - an enum's own
    // base type (`EnumDeclaration.getMemtype`, reached through
    // `toBasetype`), or a struct's own size
    // (`AggregateDeclaration.determineSize`, reached through `size`/
    // `alignsize` directly, or through `Type.baseElemOf`'s
    // `toBasetype`-then-descend walk for a static array). A pointer, a
    // class handle, a dynamic array's own two words, and every basic
    // type answer `size`/`alignsize` from a fixed table with no dsymbol
    // to force at all (`dmd.typesem.size`'s own switch), so this
    // defaults to `true` for any `Type` kind not named below.
    //
    // Every field read here is `atomicLoad!(MemoryOrder.acq)`, not a
    // plain read - `forceIfNeeded`'s own doc (`snakebite.frontend.
    // compiler`) explains why an unlocked reader needs that much, and
    // why the field itself must be the one dmd sets only once the data
    // it guards is completely settled, not merely a field dmd's own
    // single-threaded code happens to gate re-entrancy on.
    private static bool resolved(Type type) {
        import core.atomic: atomicLoad, MemoryOrder;
        import dmd.astenums: Sizeok;
        import dmd.dsymbol: PASS;

        // `EnumDeclaration.enumSemantic` (dmd/enumsem.d) clears `_scope`
        // (dmd's own re-entrancy gate, and the field `getMemtype` itself
        // reads) as soon as it starts, long before `memtype` is
        // reassigned to its resolved form a few lines later - `_scope
        // is null` can be true while a racing reader still sees the
        // pre-semantic, unresolved `memtype` the parser first assigned
        // (e.g. a `TypeIdentifier` for `enum E : SomeAlias`), not a real
        // answer to `size`/`alignsize`. `semanticRun` only reaches
        // `semanticdone` after that reassignment, on every path through
        // `enumSemantic` that starts with `memtype` non-null - gate on
        // that field instead. `enum { A, B, C }` (no explicit base)
        // leaves `memtype` null past `semanticdone` too (dmd fills it in
        // later still, from the first member's own value) - `memtype
        // !is null` below stays false for that case until dmd truly
        // sets it, keeping every caller on the locked path meanwhile, so
        // it is kept alongside the corrected `semanticRun` check rather
        // than dropped.
        if (auto enumType = type.isTypeEnum)
            return atomicLoad!(MemoryOrder.acq)(enumType.sym.semanticRun)
                    >= PASS.semanticdone
                && atomicLoad!(MemoryOrder.acq)(enumType.sym.memtype)
                    !is null
                && resolved(enumType.sym.memtype);

        // `finalizeSize` (dsymbolsem.d) sets `sizeok = Sizeok.done` as
        // its very last write, strictly after `structsize`/`alignsize`
        // are both final - unlike `EnumDeclaration._scope` above, this
        // field really is the last word.
        if (auto structType = type.isTypeStruct)
            return atomicLoad!(MemoryOrder.acq)(structType.sym.sizeok)
                == Sizeok.done;

        if (auto arrayType = type.isTypeSArray)
            return resolved(arrayType.next);

        return true;
    }

    // The forcing half of `resolved`: runs, under the frontend lock
    // (`forceIfNeeded`'s own doc explains why only there), exactly the
    // dmd call whose own idempotent gate `resolved` mirrors. Each dmd
    // function re-checks that same gate itself, so calling it again for
    // a branch another thread resolved first, between `resolved`'s read
    // and this thread taking the lock, is itself a no-op - never a
    // second write.
    private static void forceResolved(Type type) {
        import dmd.location: Loc;

        if (auto enumType = type.isTypeEnum) {
            import dmd.enumsem: getMemtype;

            forceResolved(getMemtype(enumType.sym, Loc.initial));
            return;
        }

        if (auto structType = type.isTypeStruct) {
            import dmd.dsymbolsem: size;

            structType.sym.size(Loc.initial);
            return;
        }

        if (auto arrayType = type.isTypeSArray)
            forceResolved(arrayType.next);
    }

    // Which native bytes of a value of `type` decide whether it is true
    // as a condition (`if`, `assert`, `!`, `&&`, `||`, `?:`) - dmd's own
    // `toBoolean` (`dmd.expressionsem`) leaves such a condition's type
    // unchanged for every case here, so the real test is the one native
    // codegen makes of the value's bytes, not any `bool` conversion:
    //
    // * A floating value is true when nonzero, compared as a float, at
    //   `size` bytes from the value's own start.
    // * A dynamic array is true by its pointer word alone (`ptr !is
    //   null`) - a zero-length array over real storage is still true -
    //   so only `arrayPointerOffset` is tested, never the length word.
    //   (A length with a null pointer is not pinned either way: dmd
    //   2.112 and ldc2 1.42 disagree on it, and no guest program either
    //   backend can run builds that value.)
    // * A delegate is true when either of its two words (`ptr`,
    //   `funcptr`) is nonzero - the one shape here with a second word
    //   to test, at `secondOffset`.
    // * A pointer, a class reference, an associative array's one
    //   pointer-sized handle, and every integral (`bool`, `char`, an
    //   enum with an integral base, ...) are already exactly one native
    //   word: `offset` alone, `size` bytes, decides it.
    //
    // One rule shared by every backend that compiles or interprets a
    // condition, so neither special-cases an associative array or a
    // delegate on its own.
    public struct Truth {
        // `false` when `type` cannot be used as a condition at all (for
        // instance an integral width with no native layout); every
        // other field is meaningless then, and the caller reports its
        // own rejection.
        public bool supported;
        public bool isFloat;
        // Offset, from the value's own start, and width, of the bytes
        // that decide truth on their own (the only bytes there are,
        // unless `secondOffset` names a second word).
        public size_t offset;
        public size_t size;
        // Offset of a second, `size_t.sizeof`-wide word to test as well
        // (true if either word is nonzero) - `noSecondWord` when the
        // first word already decides it alone.
        public size_t secondOffset = noSecondWord;

        public enum noSecondWord = size_t.max;

        public static Truth of(Type type) {
            import dmd.astenums:
                Taarray, Tarray, Tclass, Tcomplex32, Tcomplex64, Tcomplex80,
                Tdelegate, Tfloat32, Tfloat64, Tfloat80, Timaginary32,
                Timaginary64, Timaginary80, Tnull, Tpointer;
            import dmd.typesem: isIntegral, size, toBasetype;

            type = type.toBasetype;

            // An imaginary value is one `float`/`double`/`real`-shaped
            // component on its own - the same nonzero test a real one
            // gets, just at its own (imaginary) type's size.
            if (type.ty == Tfloat32 || type.ty == Tfloat64
                    || type.ty == Tfloat80
                    || type.ty == Timaginary32 || type.ty == Timaginary64
                    || type.ty == Timaginary80)
                return Truth(true, true, 0, type.size);

            // A complex value is true when either of its two
            // `float`/`double`/`real`-shaped components (`re`, `im`,
            // each exactly half `type.size` - `nativevalue.
            // loadComplexRe`/`loadComplexIm`'s own layout) is nonzero -
            // `isFloat` picks the same per-word nonzero test the single-
            // component case above does, applied twice by `secondOffset`
            // the way a delegate's two integral words already are.
            if (type.ty == Tcomplex32 || type.ty == Tcomplex64
                    || type.ty == Tcomplex80) {
                const half = type.size / 2;
                return Truth(true, true, 0, half, half);
            }

            if (type.ty == Tarray)
                return Truth(
                    true, false, arrayPointerOffset, size_t.sizeof);

            if (type.ty == Tdelegate)
                return Truth(
                    true, false, delegateContextOffset, size_t.sizeof,
                    delegateFunctionOffset,
                );

            // `typeof(null)` has only ever the one value - always zero
            // bits, so `if (x)` on it is always false - but that is
            // still the same one-word nonzero test a pointer's own
            // `Truth` already is, not a rejection of its own.
            if (type.ty == Tpointer || type.ty == Tclass
                    || type.ty == Taarray || type.ty == Tnull)
                return Truth(true, false, 0, type.size);

            if (type.isIntegral && isIntegralSize(type.size))
                return Truth(true, false, 0, type.size);

            return Truth(false);
        }
    }
}

// Rounds `offset` up to the next multiple of `alignment`, by way of dmd's
// default field-alignment rule (`aggregate.alignmember`, the same one it
// uses to lay out a struct's fields), rather than reimplementing it: no
// generic round-up-to-alignment helper exists anywhere else in the dmd
// frontend sources. Parameter frame offsets are ordinarily assigned far
// downstream of this, in dmd's machine-code backend, which this project
// does not use - laying out frames here is unavoidable, not a case of
// redoing work dmd already did for us at this stage.
public size_t alignUp(in size_t offset, in uint alignment) {
    import dmd.aggregate: alignmember;

    return alignmember(defaultAlignment, alignment, cast(uint) offset);
}

// `alignmember` takes a `structalign_t` for cases with an explicit
// `align(N)`; there is none here, so `defaultAlignment` is always the
// type's own natural alignment - and it is built at compile time,
// not on every call, since this runs on every parameter offset and every
// frame stack push.
private enum defaultAlignment = () {
    import dmd.astenums: structalign_t;

    structalign_t alignment;
    alignment.setDefault;
    return alignment;
}();

// Inspecting an initializer's value must not itself run construction.
public imported!"dmd.expression".Expression initializerValueOf(
    imported!"dmd.init".ExpInitializer initializer,
) {
    auto value = initializer.exp;
    if (auto construct = value.isConstructExp)
        return construct.e2;
    if (auto blit = value.isBlitExp)
        return blit.e2;
    return value;
}

// `T[n] v = source;` (a static array constructed from a slice or a
// scalar, never an array literal) is not a plain value initializer: dmd
// rewrites the construction to `v[] = source` (expressionsem.d, around
// line 12776), a `ConstructExp`/`BlitExp` whose `e1` is a `SliceExp` of
// `v`, not `v` itself. That node's own value is the slice `e1` evaluates
// to - storing it as `v`'s own type stores the slice header, not the
// elements. A declaration initializer shaped this way must run as an
// effect, through the normal assignment path that resolves `e1`'s
// address and writes through it, rather than have `initializerValueOf`'s
// `e2` evaluated into `v`'s slot as if it were `v`'s own value.
public bool initializerConstructsThroughSlice(
    imported!"dmd.init".ExpInitializer initializer,
    imported!"dmd.declaration".VarDeclaration variable,
) {
    auto value = initializer.exp;
    auto e1 = value.isConstructExp ? value.isConstructExp.e1
        : value.isBlitExp ? value.isBlitExp.e1 : null;
    if (e1 is null)
        return false;

    auto target = e1.isVarExp;
    return target is null || target.var !is variable;
}

// These literals require neither execution nor a fresh runtime allocation.
public bool isStoredLiteral(imported!"dmd.expression".Expression value) {
    if (auto variable = value.isVarExp) {
        auto symbol = variable.var.isSymbolDeclaration;
        auto declaration = symbol is null
            ? null : symbol.dsym.isStructDeclaration;
        return declaration !is null && !declaration.isNested();
    }
    if (auto literal = value.isStructLiteralExp) {
        if (literal.sd.isNested())
            return false;
        foreach (element; *literal.elements)
            if (element !is null && !isStoredLiteral(element))
                return false;
        return true;
    }
    if (auto literal = value.isArrayLiteralExp) {
        if (literal.type.isTypeSArray is null)
            return false;
        foreach (i; 0 .. literal.elements.length)
            if (!isStoredLiteral(literal[i]))
                return false;
        return true;
    }
    return value.isIntegerExp !is null || value.isRealExp !is null
        || value.isStringExp !is null || value.isNullExp !is null;
}

// Owns constant storage and its referenced data for the backend's lifetime.
public struct NativeData {
    // Holds `SharedTable`s and a `PerThread` (finding 2.4): a copy of
    // either would share storage with the original until one side
    // changed it.
    @disable this(this);

    import dmd.aggregate: AggregateDeclaration;
    import dmd.dclass: ClassDeclaration;
    import dmd.declaration: Declaration, VarDeclaration;
    import dmd.dsymbol: Dsymbol;
    import dmd.expression: ClassReferenceExp, Expression, StructLiteralExp;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    import snakebite.hostthreads: PerThread;
    import snakebite.sharedtable: SharedTable;
    import snakebite.tlsstorage: TlsDescriptor, TlsSlots;

    private bool delegate(Dsymbol) const _isRootOwned;
    private SymbolAddress _symbolAddress;
    private ThreadLocalAddress _threadLocalAddress;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    // Read and written only under the compiler lock. Key by the object,
    // not a reference expression, to preserve aliases and cycles.
    private void*[StructLiteralExp] _classValues;
    // Written under the compiler lock only, like every miss below.
    private void[][] _blocks;
    private void[] _available;
    // Read without a lock by every thread that runs guest code
    // (ADR-0006). A `shared`/`__gshared`/`immutable` variable's storage
    // is published once it is initialised; until then only
    // `_pendingStatics`, which the initialising thread alone reads,
    // knows it, so an initializer that refers to its own variable finds
    // the storage.
    private SharedTable!(VarDeclaration, void[]) _statics;
    private void[][VarDeclaration] _pendingStatics;
    private SharedTable!(Type, const(void)[]) _defaults;
    // A thread-local variable's template: the bytes its storage starts
    // with on every thread, built once under the lock like `_statics`
    // (finding 1.3). `_tls` is this thread's own copies, made from that
    // template on this thread's own first touch of each variable - never
    // shared, so `TlsSlots.slotFor` takes no lock.
    private SharedTable!(VarDeclaration, TlsDescriptor) _tlsDescriptors;
    private PerThread!(TlsSlots*) _tls;

    public this(
        bool delegate(Dsymbol) const isRootOwned,
        SymbolAddress symbolAddress,
        ThreadLocalAddress threadLocalAddress,
        TypeInfo_Class delegate(ClassDeclaration) classInfo,
    ) {
        _isRootOwned = isRootOwned;
        _symbolAddress = symbolAddress;
        _threadLocalAddress = threadLocalAddress;
        _classInfo = classInfo;
        _tls = PerThread!(TlsSlots*)(() => new TlsSlots);
    }

    public void write(
        Type type,
        in TypeFacts facts,
        Expression expression,
        void* place,
    ) {
        storeValue(type, facts, expression, place, &addressOf, &this);
    }

    private void* classValue(ClassReferenceExp value) {
        import core.stdc.string: memcpy;
        import snakebite.frontend.compiler: withCompilerLock;

        void* address;
        withCompilerLock({
            if (auto found = value.value in _classValues) {
                address = *found;
                return;
            }
            const info = _classInfo(value.originalClass);
            auto bytes = new void[info.m_init.length]; // Must remain writable.
            memcpy(bytes.ptr, info.m_init.ptr, bytes.length);
            address = bytes.ptr;
            // Register before fields: compile-time objects can form cycles.
            _classValues[value.value] = address;
            scope (failure) _classValues.remove(value.value);
            for (auto declaration = value.originalClass;
                    declaration !is null; declaration = declaration.baseClass) {
                foreach (field; declaration.fields) {
                    const index = value.findFieldIndexByName(field);
                    assert(index >= 0);
                    // Frontend expression APIs require mutable AST nodes.
                    auto element = (*value.value.elements)[index];
                    if (element !is null)
                        write(field.type, TypeFacts.of(field.type), element,
                            cast(ubyte*) address + field.offset);
                }
            }
        });
        return address;
    }

    public const(void)[] initialValue(
        Type type,
        in Loc loc,
    ) {
        if (auto found = type in _defaults)
            return *found;

        import snakebite.frontend.compiler: withCompilerLock;

        const(void)[] bytes;
        withCompilerLock({
            if (auto found = type in _defaults)
                bytes = *found;
            else
                bytes = *_defaults.insert(
                    type, value(type, initialExpression(type, loc)));
        });
        return bytes;
    }

    public const(void)[] value(
        Type type,
        Expression expression,
    ) {
        const facts = TypeFacts.of(type);
        auto bytes = reserve(facts);
        write(type, facts, expression, bytes.ptr);
        return bytes;
    }

    private void[] reserve(in TypeFacts facts) {
        import snakebite.frontend.compiler: withCompilerLock;

        void[] bytes;
        withCompilerLock({
            // Slots cannot move: constants can hold addresses of other
            // slots.
            const needed = facts.size + facts.alignment - 1;
            if (_available.length < needed) {
                import std.algorithm: max;

                _available = new void[max(4096, needed)];
                _blocks ~= _available;
            }
            const start =
                -cast(size_t) _available.ptr & (facts.alignment - 1);
            bytes = _available[start .. start + facts.size];
            _available = _available[start + facts.size .. $];
        });
        return bytes;
    }

    public TlsSlots* tlsSlots() {
        return _tls.current;
    }

    // `variable`'s storage: this thread's own copy if it is thread-local
    // (finding 1.3 - compiled D gives every thread its own copy of a
    // module-level or `static` local that is not `shared`/`__gshared`),
    // otherwise the one copy every thread shares. Native storage when
    // the variable has it (`hasNativeStorage`); this program's own
    // otherwise.
    public void[] storageOf(VarDeclaration variable) {
        import std.string: fromStringz;

        const facts = TypeFacts.of(variable.type);
        if (variable.isThreadlocal)
            return _tls.current.slotFor(tlsDescriptorOf(variable));

        if (hasNativeStorage(variable)) {
            // const would also make the referenced storage read-only here.
            auto address = _symbolAddress(variable);
            if (address !is null)
                return address[0 .. facts.size];
            assert(!isExtern(variable), variable.toChars.fromStringz);
        }

        if (auto found = variable in _statics)
            return *found;

        import snakebite.frontend.compiler: withCompilerLock;

        void[] bytes;
        withCompilerLock({
            if (auto found = variable in _statics) {
                bytes = *found;
                return;
            }
            bytes = buildInitialBytes(variable, facts);
            _statics.insert(variable, bytes);
        });
        return bytes;
    }

    // The bytes every thread's own copy of a thread-local variable
    // starts from, and the identity `TlsSlots.slotFor` keys that copy
    // by - built once, under the lock, and read without one after that
    // (like `_statics`). The bytecode compiler bakes a pointer to this
    // into an `opTls*` instruction operand in place of a resolved
    // address (finding 1.3): a thread-local variable's address is never
    // a compile-time constant, the same way it never is in compiled D.
    public const(TlsDescriptor)* tlsDescriptorOf(VarDeclaration variable) {
        if (auto found = variable in _tlsDescriptors)
            return found;

        import snakebite.frontend.compiler: withCompilerLock;

        const(TlsDescriptor)* descriptor;
        withCompilerLock({
            if (auto found = variable in _tlsDescriptors) {
                descriptor = found;
                return;
            }
            const facts = TypeFacts.of(variable.type);
            if (hasNativeStorage(variable)) {
                const name = nativeSymbolName(variable);
                // Only to learn that the symbol is there: this thread's
                // address is not the descriptor's to keep.
                if (_threadLocalAddress(name) !is null) {
                    descriptor = _tlsDescriptors.insert(variable, TlsDescriptor(
                        cast(const(void)*) variable, null, facts.size,
                        name, _threadLocalAddress));
                    return;
                }
                assert(!isExtern(variable), name);
            }
            const bytes = buildInitialBytes(variable, facts);
            descriptor = _tlsDescriptors.insert(variable, TlsDescriptor(
                cast(const(void)*) variable, bytes.ptr, bytes.length));
        });
        return descriptor;
    }

    // Whether `variable`'s storage is native rather than this program's
    // own. An `extern` declaration's is by definition. A dependency's is
    // too: a module dmd only reached through an `import` has its machine
    // code in the dependency image, and its globals with it, and that
    // code reads and writes them there. One storage per variable, or a
    // native setter and an interpreted reader would each see their own.
    // A dependency variable with no native symbol (a template instance
    // only guest code made) keeps this program's own storage.
    private bool hasNativeStorage(VarDeclaration variable) const {
        return isExtern(variable) || !_isRootOwned(variable);
    }

    private static bool isExtern(VarDeclaration variable) {
        import dmd.astenums: STC;

        return (variable.storage_class & STC.extern_) != 0;
    }

    // Reserves and fills a variable's own storage bytes: called under
    // the compiler lock, for a `shared`/`__gshared` variable's one and
    // only storage, or for a thread-local variable's template. A
    // recursive call for the same variable - its own initializer refers
    // to it - finds the reservation `_pendingStatics` is already holding
    // for it, rather than reserving a second time.
    private void[] buildInitialBytes(VarDeclaration variable, in TypeFacts facts) {
        import core.stdc.string: memcpy;
        import dmd.expressionsem: getConstInitializer;

        if (auto pending = variable in _pendingStatics)
            return *pending;

        auto bytes = reserve(facts);
        _pendingStatics[variable] = bytes;
        scope (exit) _pendingStatics.remove(variable);

        if (variable._init is null) {
            const initial = initialValue(variable.type, variable.loc);
            memcpy(bytes.ptr, initial.ptr, bytes.length);
        } else if (variable._init.isVoidInitializer is null) {
            auto initializer = variable._init.isExpInitializer;
            auto expression = initializer is null
                ? variable.getConstInitializer
                : initializerValueOf(initializer);
            write(variable.type, facts, expression, bytes.ptr);
        }
        return bytes;
    }

    // Only for a constant initializer (`storeValue`'s address-of case):
    // the address this call bakes in is read back by every thread, so
    // it must be one every thread agrees on. A `shared`/`__gshared`
    // variable's storage qualifies; a thread-local variable's does not
    // - `storageOf` would hand back this compiling thread's own copy,
    // baked in for every other thread to read as if it were theirs
    // (finding 14). dmd rejects most expressions that would reach this
    // with a thread-local variable (its address is not a compile-time
    // constant there either), so this is a clear failure instead of a
    // silent one for whatever is left.
    private void* addressOf(Declaration symbol) {
        import std.conv: text;

        if (auto variable = symbol.isVarDeclaration) {
            if (variable.isThreadlocal)
                throw new Exception(text(
                    "cannot bake the address of thread-local variable `",
                    variable.toChars, "` into a constant initializer"));
            return storageOf(variable).ptr;
        }
        return _symbolAddress(symbol);
    }

    public void fillFields(
        AggregateDeclaration declaration,
        ubyte* place,
    ) {
        import dmd.expressionsem: getConstInitializer;

        foreach (field; declaration.fields) {
            if (field._init !is null && field._init.isVoidInitializer)
                continue;

            const bytes = field._init is null
                ? initialValue(field.type, field.loc)
                : value(field.type, field.getConstInitializer(false));
            import core.stdc.string: memcpy;

            memcpy(place + field.offset, bytes.ptr, bytes.length);
        }
    }
}

private alias SymbolAddress =
    void* delegate(imported!"dmd.declaration".Declaration);
// This thread's address of a thread-local symbol, by linker name.
private alias ThreadLocalAddress = void* delegate(in char[] name);

public string nativeSymbolName(imported!"dmd.declaration".Declaration symbol) {
    import dmd.common.outbuffer: OutBuffer;
    import dmd.mangle: mangleToBuffer;

    OutBuffer name;
    mangleToBuffer(symbol, name);
    return name[].idup;
}

private imported!"dmd.expression".Expression initialExpression(
    imported!"dmd.mtype".Type type,
    in imported!"dmd.location".Loc loc,
) {
    import dmd.typesem: defaultInitLiteral;

    return type.defaultInitLiteral(loc);
}

public void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, TypeFacts.of(type), value, place, null);
}

private void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
    scope SymbolAddress symbolAddress,
    NativeData* nativeData = null,
) {
    storeValue(type, TypeFacts.of(type), value, place, symbolAddress, nativeData);
}

public void storeValue(
    imported!"dmd.mtype".Type type,
    in TypeFacts facts,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, facts, value, place, null);
}

private void storeValue(
    imported!"dmd.mtype".Type type,
    in TypeFacts facts,
    imported!"dmd.expression".Expression value,
    void* place,
    scope SymbolAddress symbolAddress,
    NativeData* nativeData = null,
) {
    import core.stdc.string: memcpy, memset;
    import dmd.astenums:
        Tarray, Tcomplex32, Tcomplex64, Tcomplex80, Tfloat32, Tfloat64,
        Tfloat80, Timaginary32, Timaginary64, Timaginary80, Tpointer,
        Tsarray;
    import dmd.expressionsem: toComplex, toImaginary, toInteger, toReal;
    import dmd.typesem: mutableOf, nextOf, size, toBasetype;
    import std.conv: text;

    if (value.isNullExp) {
        memset(place, 0, facts.size);
        return;
    }

    if (facts.isIntegral) {
        storeIntegral(place, value.toInteger, facts.size);
        return;
    }

    // DMD represents an integer-to-pointer cast as an integer literal. Its
    // low pointer-width bits are the pointer value in the native layout.
    if (type.ty == Tpointer && value.isIntegerExp) {
        storeIntegral(place, cast(ulong) value.toInteger, facts.size);
        return;
    }

    type = type.toBasetype;
    auto bytes = cast(ubyte*) place;

    if (auto variable = value.isVarExp) {
        if (auto symbol = variable.var.isSymbolDeclaration) {
            storeValue(type, facts, initialExpression(symbol.dsym.type,
                value.loc), place, symbolAddress, nativeData);
            return;
        }
    }

    if (auto vector = value.isVectorExp) {
        storeValue(type.isTypeVector.basetype, vector.e1, place,
            symbolAddress, nativeData);
        return;
    }

    if (auto array = type.isTypeSArray) {
        auto sourceElement = value.type.toBasetype.nextOf;
        const wholeArray = sourceElement !is null
            && sourceElement.mutableOf.equals(array.next.mutableOf);
        if (!wholeArray || value.isStringExp is null) {
            const elementSize = array.next.size;
            auto literal = wholeArray ? value.isArrayLiteralExp : null;
            foreach (i; 0 .. cast(size_t) array.dim.toInteger)
                storeValue(array.next, literal is null ? value : literal[i],
                    bytes + i * elementSize, symbolAddress, nativeData);
            return;
        }
    }

    if (auto symbol = value.isSymOffExp) {
        assert(symbolAddress !is null);
        *cast(void**) place =
            cast(ubyte*) symbolAddress(symbol.var) + symbol.offset;
        return;
    }

    if (auto literal = value.isFuncExp) {
        assert(symbolAddress !is null);
        *cast(void**) place = symbolAddress(literal.fd);
        return;
    }

    if (auto reference = value.isClassReferenceExp) {
        assert(nativeData !is null);
        const address = nativeData.classValue(reference);
        int offset;
        type.isTypeClass.sym.isBaseOf(reference.originalClass, &offset);
        *cast(void**) place = cast(ubyte*) address + offset;
        return;
    }

    if (auto literal = value.isStringExp) {
        const elementSize = type.nextOf.size;
        assert(literal.sz == elementSize);
        if (type.ty == Tsarray) {
            assert(literal.len * elementSize == facts.size);
            memcpy(place, literal.peekData.ptr, facts.size);
        } else if (type.ty == Tpointer) {
            *cast(const(void)**) place = literal.peekData.ptr;
        } else {
            assert(type.ty == Tarray);
            storeIntegral(bytes + arrayLengthOffset, literal.len, size_t.sizeof);
            *cast(const(void)**) (bytes + arrayPointerOffset) =
                literal.peekData.ptr;
        }
        return;
    }

    if (auto literal = value.isArrayLiteralExp) {
        assert(type.ty == Tarray);
        const elementSize = type.nextOf.size;
        auto data = new void[literal.elements.length * elementSize];
        foreach (i; 0 .. literal.elements.length)
            storeValue(type.nextOf, literal[i],
                cast(ubyte*) data.ptr + i * elementSize, symbolAddress, nativeData);
        storeIntegral(bytes + arrayLengthOffset, literal.elements.length,
            size_t.sizeof);
        *cast(void**) (bytes + arrayPointerOffset) = data.ptr;
        return;
    }

    if (type.isTypeStruct !is null && value.isIntegerExp) {
        // DMD encodes a zero-initialized struct as an IntegerExp. Resolve
        // that encoding here, not from the destination's byte count.
        assert(value.toInteger == 0);
        storeValue(type, facts, initialExpression(type, value.loc), place,
            symbolAddress, nativeData);
        return;
    }

    if (auto literal = value.isStructLiteralExp) {
        memset(place, 0, facts.size);
        foreach (i, element; *literal.elements) {
            if (element is null)
                continue;
            auto field = literal.sd.fields[i];
            if (auto bitfield = field.isBitFieldDeclaration) {
                const fieldBytes = field.type.size;
                auto bits = loadIntegral(bytes + field.offset, fieldBytes, false);
                const mask = ulong.max >> (64 - bitfield.fieldWidth);
                const shift = bitfield.bitOffset;
                bits = (bits & ~(mask << shift))
                    | ((element.toInteger & mask) << shift);
                storeIntegral(bytes + field.offset, bits, fieldBytes);
            } else
                storeValue(field.type, element, bytes + field.offset,
                    symbolAddress, nativeData);
        }
        return;
    }

    if (type.ty == Tfloat32) {
        *cast(float*) place = cast(float) value.toReal;
        return;
    }

    if (type.ty == Tfloat64) {
        *cast(double*) place = cast(double) value.toReal;
        return;
    }

    if (type.ty == Tfloat80) {
        *cast(real*) place = value.toReal;
        return;
    }

    // A complex value's native layout is its `{re, im}` pair, each
    // exactly half of `facts.size` - `dmd.expressionsem.toComplex`
    // already answers `re`/`im` for an `IntegerExp`/`RealExp` (an
    // implicit real-to-complex promotion, `im` zero) as well as a
    // `ComplexExp` literal, so this one case covers every constant
    // source a `complex`-typed constant declaration can have.
    if (type.ty == Tcomplex32 || type.ty == Tcomplex64
            || type.ty == Tcomplex80) {
        const parts = value.toComplex;
        const half = facts.size / 2;
        if (half == float.sizeof) {
            *cast(float*) bytes = cast(float) parts.re;
            *cast(float*) (bytes + half) = cast(float) parts.im;
        } else if (half == double.sizeof) {
            *cast(double*) bytes = cast(double) parts.re;
            *cast(double*) (bytes + half) = cast(double) parts.im;
        } else {
            *cast(real*) bytes = parts.re;
            *cast(real*) (bytes + half) = parts.im;
        }
        return;
    }

    // An imaginary value is one component on its own - `toImaginary`
    // answers `0` for any source with no imaginary axis (an `Integer`/
    // real-typed `RealExp`), the same way `toReal` above answers `0`
    // for an imaginary-typed one.
    if (type.ty == Timaginary32 || type.ty == Timaginary64
            || type.ty == Timaginary80) {
        const im = value.toImaginary;
        if (facts.size == float.sizeof)
            *cast(float*) place = cast(float) im;
        else if (facts.size == double.sizeof)
            *cast(double*) place = cast(double) im;
        else
            *cast(real*) place = im;
        return;
    }

    throw new Exception(
        text("no native layout for a value of type `", type.toString, "`"),
    );
}
