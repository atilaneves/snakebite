module snakebite.nativelayout;


private:


import snakebite.internalfailure: internalFailure;
import snakebite.frontend.typefacts;


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
    import dmd.expression:
        ClassReferenceExp, Expression, StringExp, StructLiteralExp;
    import dmd.location: Loc;
    import dmd.mtype: Type;

    import snakebite.hostthreads: heapNew, PerThread;
    import snakebite.sharedtable: SharedTable;
    import snakebite.tlsstorage: TlsDescriptor, TlsSlots;

    private bool delegate(Dsymbol) const _isRootOwned;
    private VarDeclaration delegate(VarDeclaration) _linkedVariable;
    // An `extern` variable's definition, found once for each variable.
    private SharedTable!(VarDeclaration, VarDeclaration) _definitions;
    private SymbolAddress _symbolAddress;
    private ThreadLocalAddress _threadLocalAddress;
    private TypeInfo_Class delegate(ClassDeclaration) _classInfo;
    private LoweringCall _callLowering;
    // Read and written only under the compiler lock. Class objects and
    // struct values are keyed by their own literal, not by a reference
    // or address expression, to preserve aliases and cycles.
    private void*[StructLiteralExp] _compileTimeValues;
    // The address of each literal's copy, found without a lock. A miss goes
    // to `_stringTexts`, so that nodes with equal text share one address.
    private SharedTable!(StringExp, const(void)*) _stringNodes;
    // Under the compiler lock only. The copies are outside the GC heap, as
    // read-only data is in compiled D, and are freed with this object.
    private const(void)*[StringText] _stringTexts;
    private void*[] _stringBlocks;
    // Written under the compiler lock only, like every miss below.
    private void[][] _blocks;
    private void[] _available;
    // Read without a lock by every thread that runs guest code
    // (ADR-0006). A `shared`/`__gshared`/`immutable` variable's storage
    // is published once it is resolved or initialised; until then only
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
        VarDeclaration delegate(VarDeclaration) linkedVariable,
        SymbolAddress symbolAddress,
        ThreadLocalAddress threadLocalAddress,
        TypeInfo_Class delegate(ClassDeclaration) classInfo,
        LoweringCall call,
    ) {
        _isRootOwned = isRootOwned;
        _linkedVariable = linkedVariable;
        _symbolAddress = symbolAddress;
        _threadLocalAddress = threadLocalAddress;
        _classInfo = classInfo;
        _callLowering = call;
        _tls = PerThread!(TlsSlots*)(() => heapNew!TlsSlots);
    }

    private void callLowering(
        imported!"dmd.func".FuncDeclaration function_,
        void* returnPlace,
        scope void*[] arguments,
    ) {
        _callLowering(function_, returnPlace, arguments);
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
        import dmd.expressionsem: toInteger;
        import snakebite.frontend.compiler: withCompilerLock;
        version(unittest) import snakebite.sharedtable: assertCacheFillAllowed;

        void* address;
        withCompilerLock({
            if (auto found = value.value in _compileTimeValues) {
                address = *found;
                return;
            }
            version(unittest) assertCacheFillAllowed!"class constants";
            const info = _classInfo(value.originalClass);
            auto bytes = new void[info.m_init.length]; // Must remain writable.
            memcpy(bytes.ptr, info.m_init.ptr, bytes.length);
            address = bytes.ptr;
            // Register before fields: compile-time objects can form cycles.
            _compileTimeValues[value.value] = address;
            scope (failure) _compileTimeValues.remove(value.value);
            for (auto declaration = value.originalClass;
                    declaration !is null; declaration = declaration.baseClass) {
                size_t writtenBitEnd;
                foreach (field; declaration.fields) {
                    const index = value.findFieldIndexByName(field);
                    assert(index >= 0);
                    // Frontend expression APIs require mutable AST nodes.
                    auto element = (*value.value.elements)[index];
                    if (element is null)
                        continue;
                    if (!fieldImageIncludes(field, writtenBitEnd))
                        continue;
                    if (field.isBitFieldDeclaration !is null) {
                        const access = bitfieldAccess(field);
                        access.store(cast(ubyte*) address + access.offset,
                            element.toInteger);
                    } else
                        write(field.type, typeFacts(field.type), element,
                            cast(ubyte*) address + field.offset);
                }
            }
        });
        return address;
    }

    // The one static struct value for a compile-time `&literal`.
    private void* structValue(StructLiteralExp literal) {
        import snakebite.frontend.compiler: withCompilerLock;
        version(unittest) import snakebite.sharedtable: assertCacheFillAllowed;

        void* address;
        withCompilerLock({
            if (auto found = literal in _compileTimeValues) {
                address = *found;
                return;
            }
            version(unittest) assertCacheFillAllowed!"struct constants";
            const facts = typeFacts(literal.type);
            auto bytes = reserve(facts);
            address = bytes.ptr;
            // Register before fields: compile-time values can form cycles.
            _compileTimeValues[literal] = address;
            scope (failure) _compileTimeValues.remove(literal);
            write(literal.type, facts, literal, address);
        });
        return address;
    }

    ~this() {
        import core.stdc.stdlib: free;

        foreach (block; _stringBlocks)
            free(block);
    }

    // Equal text has one address, as the object file gives in compiled D:
    // dmd makes a new literal for each use of a manifest constant, and for
    // each instance of a template.
    public const(void)* stringData(StringExp literal) {
        import core.stdc.stdlib: calloc;
        import snakebite.frontend.compiler: withCompilerLock;

        if (auto found = literal in _stringNodes)
            return *found;

        const(void)* address;
        withCompilerLock({
            const text = StringText.of(literal);
            if (auto found = text in _stringTexts) {
                address = *found;
            } else {
                auto bytes = cast(ubyte*) calloc(
                    literal.len + 1, literal.sz);
                assert(bytes !is null);
                _stringBlocks ~= bytes;
                auto units = bytes[0 .. literal.len * literal.sz];
                copyUnits(literal, units);
                address = bytes;
                // Keyed by the copy: the frontend can free its buffer.
                _stringTexts[StringText(literal.sz, units)] = address;
            }
            _stringNodes.insert(literal, address);
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
        const facts = typeFacts(type);
        auto bytes = reserve(facts);
        write(type, facts, expression, bytes.ptr);
        return bytes;
    }

    public const(void)[] value(Type type, in void[] representation) {
        import core.stdc.string: memcpy;

        const facts = typeFacts(type);
        assert(representation.length == facts.size);
        auto bytes = reserve(facts);
        memcpy(bytes.ptr, representation.ptr, bytes.length);
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

    // Gives back this thread's table of thread-local variables, unless it
    // holds a variable: a guest object that outlives the owner can still
    // point into the storage of one, and compiled D keeps it until the
    // thread ends too.
    public void release() {
        _tls.release((slots) => slots.empty);
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
    public void[] storageOf(VarDeclaration declaration) {
        import std.string: fromStringz;

        auto variable = definitionOf(declaration);
        if (auto found = variable in _statics)
            return *found;

        const facts = typeFacts(variable.type);
        if (variable.isThreadLocalStorage)
            return _tls.current.slotFor(tlsDescriptorOf(variable));

        if (hasNativeStorage(variable)) {
            // const would also make the referenced storage read-only here.
            auto address = _symbolAddress(variable);
            if (address !is null)
                return *_statics.insert(variable, address[0 .. facts.size]);
            assert(!isExtern(variable), variable.toChars.fromStringz);
        }

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
    public const(TlsDescriptor)* tlsDescriptorOf(VarDeclaration declaration) {
        auto variable = definitionOf(declaration);
        if (auto found = variable in _tlsDescriptors)
            return found;

        import snakebite.frontend.compiler: withCompilerLock;

        const(TlsDescriptor)* descriptor;
        withCompilerLock({
            if (auto found = variable in _tlsDescriptors) {
                descriptor = found;
                return;
            }
            const facts = typeFacts(variable.type);
            if (hasNativeStorage(variable)) {
                import snakebite.frontend.dmd.mangle: nativeSymbolName;

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

    // The one variable that an `extern` declaration shares its storage
    // with: its definition in a root module, when there is one.
    private VarDeclaration definitionOf(VarDeclaration variable) {
        if (!isExtern(variable))
            return variable;

        if (auto found = variable in _definitions)
            return *found;

        return *_definitions.insert(variable, _linkedVariable(variable));
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
        import snakebite.frontend.compiler: newInFrontend;

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
                ? newInFrontend!getConstInitializer(variable, true)
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
            if (variable.isThreadLocalStorage)
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
        import snakebite.frontend.compiler: newInFrontend;

        size_t writtenBitEnd;
        foreach (field; declaration.fields) {
            if (field._init !is null && field._init.isVoidInitializer)
                continue;
            if (!fieldImageIncludes(field, writtenBitEnd))
                continue;

            const bytes = field._init is null
                ? initialValue(field.type, field.loc)
                : value(
                    field.type,
                    newInFrontend!getConstInitializer(field, false),
                );
            if (field.isBitFieldDeclaration !is null) {
                const access = bitfieldAccess(field);
                access.store(place + access.offset,
                    loadIntegral(bytes.ptr, bytes.length, false));
                continue;
            }

            import core.stdc.string: memcpy;

            memcpy(place + field.offset, bytes.ptr, bytes.length);
        }
    }
}

// Like dmd's `membersToDt`, the first present union member owns its bytes.
// Packed siblings can share bytes, but not the bits of a selected member.
private bool fieldImageIncludes(
    imported!"dmd.declaration".VarDeclaration field,
    ref size_t writtenBitEnd,
) {
    import dmd.typesem: size;

    const bitfield = field.isBitFieldDeclaration;
    const start = field.offset * 8 + (bitfield is null ? 0 : bitfield.bitOffset);
    if (start < writtenBitEnd)
        return false;
    writtenBitEnd = start + (bitfield is null
        ? field.type.size * 8
        : bitfield.fieldWidth);
    return true;
}

private alias SymbolAddress =
    void* delegate(imported!"dmd.declaration".Declaration);
// This thread's address of a thread-local symbol, by linker name.
private alias ThreadLocalAddress = void* delegate(in char[] name);
// Calls the function that a lowering names, as guest or native code:
// `arguments[i]` is the address of parameter `i`'s bytes, and the result
// goes to `returnPlace`.
private alias LoweringCall = void delegate(
    imported!"dmd.func".FuncDeclaration function_,
    void* returnPlace,
    scope void*[] arguments,
);

// Whether two element types are the same type once their qualifiers are
// dropped. `mutableOf` mutates the type's own cache unless the type has no
// qualifier, so only a qualified one needs the frontend lock.
private bool mutableElementsEqual(
    imported!"dmd.mtype".Type first,
    imported!"dmd.mtype".Type second,
) {
    import dmd.typesem: mutableOf;
    import snakebite.frontend.compiler: newInFrontend;

    if (first.mod == 0 && second.mod == 0)
        return first.equals(second);

    return newInFrontend!mutableOf(first).equals(newInFrontend!mutableOf(second));
}

private imported!"dmd.expression".Expression initialExpression(
    imported!"dmd.mtype".Type type,
    in imported!"dmd.location".Loc loc,
) {
    import dmd.typesem: defaultInitLiteral;
    import snakebite.frontend.compiler: newInFrontend;

    return newInFrontend!defaultInitLiteral(type, loc);
}

// Whether `value`, through any casts, is the address of a symbol plus an
// offset: the link-time constant that C allows as the initialiser of an
// integer, `(unsigned long) &variable`.
private bool isSymbolAddress(
    imported!"dmd.expression".Expression value,
    out imported!"dmd.declaration".Declaration symbol,
    out ulong offset,
) {
    while (auto integerCast = value.isCastExp)
        value = integerCast.e1;

    if (auto offsetExpression = value.isSymOffExp) {
        symbol = offsetExpression.var;
        offset = offsetExpression.offset;
        return true;
    }

    if (auto address = value.isAddrExp) {
        if (auto variable = address.e1.isVarExp) {
            symbol = variable.var;
            return true;
        }
    }

    return false;
}

public void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, typeFacts(type), value, place, null);
}

private void storeValue(
    imported!"dmd.mtype".Type type,
    imported!"dmd.expression".Expression value,
    void* place,
    scope SymbolAddress symbolAddress,
    NativeData* nativeData = null,
) {
    storeValue(type, typeFacts(type), value, place, symbolAddress, nativeData);
}

public void storeValue(
    imported!"dmd.mtype".Type type,
    in TypeFacts facts,
    imported!"dmd.expression".Expression value,
    void* place,
) {
    storeValue(type, facts, value, place, null);
}

// The code unit size is part of the key: the terminator has that width, so
// text of equal bytes in two widths does not share a copy.
private struct StringText {
    size_t unitSize;
    const(ubyte)[] units;

    static StringText of(imported!"dmd.expression".StringExp literal) {
        return StringText(
            literal.sz,
            cast(const(ubyte)[]) literal.peekData[0 .. literal.len * literal.sz],
        );
    }
}

private void copyUnits(
    imported!"dmd.expression".StringExp literal,
    ubyte[] destination,
) {
    import core.stdc.string: memcpy;

    memcpy(destination.ptr, literal.peekData.ptr, destination.length);
}

private const(void)* stringPointer(
    NativeData* nativeData,
    imported!"dmd.expression".StringExp literal,
) {
    return nativeData is null
        ? terminatedCopy(literal).ptr : nativeData.stringData(literal);
}

// A literal is followed by one zero code unit in memory, so that it converts
// to a C string. The frontend does not keep one in a literal that it made by
// folding, so the code units are copied to storage that has it.
private ubyte[] terminatedCopy(imported!"dmd.expression".StringExp literal) {
    // `auto`: the copy is written, so it cannot be `const`.
    auto bytes = new ubyte[(literal.len + 1) * literal.sz];
    copyUnits(literal, bytes[0 .. literal.len * literal.sz]);
    return bytes;
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
    import dmd.astenums: TY, Tarray, Tdelegate, Tpointer, Tsarray, Tvector;
    import dmd.mtype: Type;
    import dmd.expressionsem: toComplex, toImaginary, toInteger, toReal;
    import dmd.typesem: mutableOf, nextOf, size, toBasetype;
    import snakebite.frontend.compiler: newInFrontend;
    import std.conv: text;

    if (value.isNullExp) {
        memset(place, 0, facts.size);
        return;
    }

    if (facts.isIntegral) {
        imported!"dmd.declaration".Declaration symbol;
        ulong offset;
        if (isSymbolAddress(value, symbol, offset)) {
            assert(symbolAddress !is null);
            storeIntegral(place,
                cast(ulong) symbolAddress(symbol) + offset, facts.size);
            return;
        }

        storeIntegral(place, value.toInteger, facts.size);
        return;
    }

    type = type.toBasetype;

    // DMD represents an integer-to-pointer cast as an integer literal. Its
    // low pointer-width bits are the pointer value in the native layout.
    if (type.ty == Tpointer && value.isIntegerExp) {
        storeIntegral(place, cast(ulong) value.toInteger, facts.size);
        return;
    }

    auto bytes = cast(ubyte*) place;

    if (auto variable = value.isVarExp) {
        if (auto symbol = variable.var.isSymbolDeclaration) {
            storeValue(type, facts, initialExpression(symbol.dsym.type,
                value.loc), place, symbolAddress, nativeData);
            return;
        }
    }

    if (type.ty == Tvector) {
        auto vector = value.isVectorExp;
        storeValue(type.isTypeVector.basetype,
            vector is null ? value : vector.e1, place,
            symbolAddress, nativeData);
        return;
    }

    if (auto array = type.isTypeSArray) {
        auto sourceElement = value.type.toBasetype.nextOf;
        const wholeArray = sourceElement !is null
            && mutableElementsEqual(sourceElement, array.next);
        if (!wholeArray || value.isStringExp is null) {
            const elementSize = array.next.size;
            auto literal = wholeArray ? value.isArrayLiteralExp : null;
            // dmd's default initializer of a `void[N]` is the `ubyte` one.
            auto storedElement = array.next.toBasetype.ty == TY.Tvoid
                ? Type.tuns8 : array.next;
            foreach (i; 0 .. cast(size_t) array.dim.toInteger)
                storeValue(storedElement, literal is null ? value : literal[i],
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
        if (type.ty == Tdelegate) {
            *cast(void**) (bytes + delegateContextOffset) = null;
            *cast(void**) (bytes + delegateFunctionOffset) =
                symbolAddress(literal.fd);
        } else
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

    // Also `&(struct S){1, 2}` at file scope in C.
    if (auto address = value.isAddrExp) {
        if (isStaticStructAddress(address)) {
            assert(nativeData !is null);
            *cast(void**) place =
                nativeData.structValue(address.e1.isStructLiteralExp);
            return;
        }
    }

    if (auto literal = value.isStringExp) {
        const elementSize = type.nextOf.size;
        assert(literal.sz == elementSize);
        if (type.ty == Tsarray) {
            assert(literal.len * elementSize == facts.size);
            memcpy(place, literal.peekData.ptr, facts.size);
        } else if (type.ty == Tpointer) {
            *cast(const(void)**) place = stringPointer(nativeData, literal);
        } else {
            assert(type.ty == Tarray);
            storeIntegral(bytes + arrayLengthOffset, literal.len, size_t.sizeof);
            *cast(const(void)**) (bytes + arrayPointerOffset) =
                stringPointer(nativeData, literal);
        }
        return;
    }

    if (auto literal = value.isArrayLiteralExp) {
        assert(type.ty == Tarray || type.ty == Tpointer);
        const elementSize = type.nextOf.size;
        auto data = new void[literal.elements.length * elementSize];
        foreach (i; 0 .. literal.elements.length)
            storeValue(type.nextOf, literal[i],
                cast(ubyte*) data.ptr + i * elementSize, symbolAddress, nativeData);
        // `int *p = (int[]){1, 2};` at file scope in C: the literal decays
        // to a pointer to its own static storage.
        if (type.ty == Tpointer) {
            *cast(void**) place = data.ptr;
            return;
        }
        storeIntegral(bytes + arrayLengthOffset, literal.elements.length,
            size_t.sizeof);
        *cast(void**) (bytes + arrayPointerOffset) = data.ptr;
        return;
    }

    if (type.isTypeStruct !is null && value.isIntegerExp) {
        // DMD encodes a zero-initialized struct as an IntegerExp. Resolve
        // that encoding here, not from the destination's byte count.
        assert(value.toInteger == 0);
        memset(place, 0, facts.size);
        return;
    }

    if (auto literal = value.isStructLiteralExp) {
        memset(place, 0, facts.size);
        size_t writtenBitEnd;
        foreach (i, element; *literal.elements) {
            if (element is null)
                continue;
            auto field = literal.sd.fields[i];
            if (!fieldImageIncludes(field, writtenBitEnd))
                continue;
            if (field.isBitFieldDeclaration !is null) {
                const access = bitfieldAccess(field);
                access.store(bytes + access.offset, element.toInteger);
            } else
                storeValue(field.type, element, bytes + field.offset,
                    symbolAddress, nativeData);
        }
        return;
    }

    final switch (type.ty) with (TY) {
        case Tfloat32:
            *cast(float*) place = cast(float) value.toReal;
            return;

        case Tfloat64:
            *cast(double*) place = cast(double) value.toReal;
            return;

        case Tfloat80:
            *cast(real*) place = value.toReal;
            return;

        // A complex value's native layout is its `{re, im}` pair, each
        // exactly half of `facts.size` - `dmd.expressionsem.toComplex`
        // already answers `re`/`im` for an `IntegerExp`/`RealExp` (an
        // implicit real-to-complex promotion, `im` zero) as well as a
        // `ComplexExp` literal, so this one case covers every constant
        // source a `complex`-typed constant declaration can have.
        case Tcomplex32, Tcomplex64, Tcomplex80: {
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
        case Timaginary32, Timaginary64, Timaginary80: {
            const im = value.toImaginary;
            if (facts.size == float.sizeof)
                *cast(float*) place = cast(float) im;
            else if (facts.size == double.sizeof)
                *cast(double*) place = cast(double) im;
            else
                *cast(real*) place = im;
            return;
        }

        // An associative array's layout is druntime's: its literal's
        // lowering, `_d_assocarrayliteralTX`, builds it.
        case Taarray: {
            auto literal = value.isAssocArrayLiteralExp;
            assert(literal !is null, text("no native layout for the ",
                "constant `", value.toString, "` of type `",
                type.toString, "`: an associative-array-typed constant ",
                "is always an associative-array literal"));

            auto constructor = literal.lowering !is null
                ? literal.lowering.isCallExp : null;
            assert(constructor !is null && constructor.f !is null,
                text("no native layout for the constant `",
                    value.toString, "` of type `", type.toString,
                    "`: dmd left it without a static-initializer lowering"));
            assert(nativeData !is null);

            auto aaType = type.isTypeAArray;
            const keyElementSize = aaType.index.size;
            const valueElementSize = aaType.next.size;

            auto keyBytes = new void[literal.keys.length * keyElementSize];
            auto valueBytes =
                new void[literal.values.length * valueElementSize];
            foreach (i, key; *literal.keys)
                storeValue(aaType.index, key,
                    cast(ubyte*) keyBytes.ptr + i * keyElementSize,
                    symbolAddress, nativeData);
            foreach (i, element; *literal.values)
                storeValue(aaType.next, element,
                    cast(ubyte*) valueBytes.ptr + i * valueElementSize,
                    symbolAddress, nativeData);

            ubyte[size_t.sizeof * 2] keysArgument = void;
            ubyte[size_t.sizeof * 2] valuesArgument = void;
            storeIntegral(keysArgument.ptr + arrayLengthOffset,
                literal.keys.length, size_t.sizeof);
            *cast(void**) (keysArgument.ptr + arrayPointerOffset) =
                keyBytes.ptr;
            storeIntegral(valuesArgument.ptr + arrayLengthOffset,
                literal.values.length, size_t.sizeof);
            *cast(void**) (valuesArgument.ptr + arrayPointerOffset) =
                valueBytes.ptr;

            void*[2] arguments =
                [keysArgument.ptr, valuesArgument.ptr];
            nativeData.callLowering(constructor.f, place, arguments[]);
            return;
        }

        case Tarray, Tsarray, Tpointer, Treference, Tfunction,
            Tident, Tclass, Tstruct, Tenum, Tdelegate, Tnone, Tvoid, Tint8,
            Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tint64, Tuns64, Tbool,
            Tchar, Twchar, Tdchar, Terror, Tinstance, Ttypeof, Ttuple,
            Tslice, Treturn, Tnull, Tvector, Tint128, Tuns128, Ttraits,
            Tmixin, Tnoreturn, Ttag:
            internalFailure(text("no native layout for the constant `",
                value.toString, "` of type `", type.toString, "`: the ",
                "cases above handle every constant dmd folds to"));
    }
}
