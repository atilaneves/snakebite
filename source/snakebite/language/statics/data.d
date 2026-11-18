module snakebite.language.statics.data;


private:


import snakebite.frontend.ast: Module;
import snakebite.failure.report: internalFailure;
import snakebite.native.address: Address, DatumRef, Target;
import snakebite.frontend.typefacts;
import snakebite.native.staticstore: Placed, StaticBlocks, StaticStore;
import snakebite.native.value:
    arrayLengthOffset, arrayPointerOffset, arrayValueSize, checkedLoadIntegral,
    checkedStoreIntegral, delegateContextOffset, delegateFunctionOffset,
    TypeFacts;

private alias Link = StaticBlocks.Link;

// A value below the first page is a flag, not an address.
private enum firstAddress = 4096;


// Owns constant storage and its referenced data for the backend's lifetime.
public struct NativeData {
    // Holds `SharedTable`s and a `PerThread` (finding 2.4): a copy of
    // either would share storage with the original until one side
    // changed it.
    @disable this(this);

    import snakebite.frontend.ast: AggregateDeclaration, ClassDeclaration,
        ClassReferenceExp, Declaration, Dsymbol, Expression, Loc, StringExp,
        StructLiteralExp, Type, VarDeclaration;

    import snakebite.ffi.callplanstore: CallPlanStore;
    import snakebite.ffi.names: Name;
    import snakebite.host.sharedtable: SharedTable;
    import snakebite.stack.tls: TlsDescriptor, TlsSlots;

    private bool delegate(Dsymbol) const _isRootOwned;
    private bool delegate(Dsymbol) const _isDefinedElsewhere;
    private VarDeclaration delegate(VarDeclaration) _linkedVariable;
    // An `extern` variable's definition, found once for each variable.
    private SharedTable!(VarDeclaration, VarDeclaration) _definitions;
    private SymbolAddress _symbolAddress;
    // The names of the symbols of the program, and where their addresses
    // are found (`snakebite.ffi.names`).
    private CallPlanStore* _plans;
    // The name of the storage of each variable that is not thread-local:
    // null when the program holds the storage.
    private SharedTable!(VarDeclaration, const(Name)*) _storageNames;
    private FunctionKind _functionKind;
    private ThreadLocalAddress _threadLocalAddress;
    // Writes the initial image of an object of a class.
    private void delegate(ClassDeclaration, void*) _classImage;
    private TypeInfoOf _typeInfo;
    // Read and written only under the compiler lock. Class objects and
    // struct values are keyed by their own literal, not by a reference
    // or address expression, to preserve aliases and cycles.
    private Placed[StructLiteralExp] _compileTimeValues;
    // The address of each literal's copy, found without a lock. A miss goes
    // to `_stringTexts`, so that nodes with equal text share one address.
    private SharedTable!(StringExp, const(void)*) _stringNodes;
    // Under the compiler lock only. The copies are owned by `_store`, which
    // the owner of this gives at construction and keeps alive longer.
    private const(void)*[StringText] _stringTexts;
    private StaticStore* _store;
    // Whether a write of an address into a datum is recorded in the datum
    // (`StaticBlocks.recordAddress`), so that the data can be stored in a
    // file.
    private bool recordRelocs() const @safe pure nothrow @nogc {
        return _store.recordsAddresses;
    }
    // The blocks that hold a datum of this, for `recordRelocs`. Under the
    // compiler lock only.
    private StaticBlocks*[] _knownBlocks;
    // The blocks of the D module that defines a variable, or null when
    // every datum goes to `_store`. Called under the compiler lock.
    private StaticBlocks* delegate(Module) _blocksOf;
    // Read without a lock by every thread that runs guest code
    // (ADR-0006). A `shared`/`__gshared`/`immutable` variable's storage
    // is published once it is resolved or initialised; until then only
    // `_pendingStatics`, which the initialising thread alone reads,
    // knows it, so an initializer that refers to its own variable finds
    // the storage.
    private SharedTable!(VarDeclaration, Placed) _statics;
    private Placed[VarDeclaration] _pendingStatics;
    private SharedTable!(Type, Placed) _defaults;
    // A thread-local variable's descriptor, a datum of the blocks that holds
    // the address of the template: the bytes its storage starts with on
    // every thread. Built once under the lock like `_statics` (finding 1.3).
    private SharedTable!(VarDeclaration, Placed) _tlsDescriptors;

    public this(
        StaticStore* store,
        CallPlanStore* plans,
        bool delegate(Dsymbol) const isRootOwned,
        bool delegate(Dsymbol) const isDefinedElsewhere,
        VarDeclaration delegate(VarDeclaration) linkedVariable,
        SymbolAddress symbolAddress,
        ThreadLocalAddress threadLocalAddress,
        void delegate(ClassDeclaration, void*) classImage,
        TypeInfoOf typeInfo,
        StaticBlocks* delegate(Module) blocksOf = null,
        FunctionKind functionKind = null,
    ) {
        _isRootOwned = isRootOwned;
        _isDefinedElsewhere = isDefinedElsewhere;
        _linkedVariable = linkedVariable;
        _symbolAddress = symbolAddress;
        _threadLocalAddress = threadLocalAddress;
        _classImage = classImage;
        _typeInfo = typeInfo;
        _store = store;
        _plans = plans;
        _blocksOf = blocksOf;
        _functionKind = functionKind;
    }

    public void write(
        Type type,
        in TypeFacts facts,
        Expression expression,
        void* place,
    ) {
        storeValue(type, facts, expression, place, &placeOf, &this);
    }

    // The object is a datum of the blocks of the D module of its class.
    private Placed classValue(ClassReferenceExp value) {
        import snakebite.frontend.typefacts: integerValue;
        import snakebite.frontend.compiler: withCompilerLock;
        version(unittest) import snakebite.host.sharedtable: assertCacheFillAllowed;

        Placed placed;
        withCompilerLock({
            if (auto found = value.value in _compileTimeValues) {
                placed = *found;
                return;
            }
            version(unittest) assertCacheFillAllowed!"class constants";
            const alignment = value.originalClass.alignsize;
            // Must remain writable.
            placed = reserve(TypeFacts(value.originalClass.structsize,
                alignment == 0 ? 1 : alignment), value.originalClass);
            auto address = placed.ptr;
            _classImage(value.originalClass, address);
            // Register before fields: compile-time objects can form cycles.
            _compileTimeValues[value.value] = placed;
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
                            element.integerValue);
                    } else
                        write(field.type, typeFacts(field.type), element,
                            cast(ubyte*) address + field.offset);
                }
            }
        });
        return placed;
    }

    // The one static struct value for a compile-time `&literal`.
    private Placed structValue(StructLiteralExp literal) {
        import snakebite.frontend.compiler: withCompilerLock;
        version(unittest) import snakebite.host.sharedtable: assertCacheFillAllowed;

        Placed value;
        withCompilerLock({
            if (auto found = literal in _compileTimeValues) {
                value = *found;
                return;
            }
            version(unittest) assertCacheFillAllowed!"struct constants";
            const facts = typeFacts(literal.type);
            value = reserve(facts);
            // Register before fields: compile-time values can form cycles.
            _compileTimeValues[literal] = value;
            scope (failure) _compileTimeValues.remove(literal);
            write(literal.type, facts, literal, value.ptr);
        });
        return value;
    }

    // Equal text has one address, as the object file gives in compiled D:
    // dmd makes a new literal for each use of a manifest constant, and for
    // each instance of a template.
    public const(void)* stringData(StringExp literal) {
        import snakebite.frontend.compiler: withCompilerLock;

        if (auto found = literal in _stringNodes)
            return *found;

        const(void)* address;
        withCompilerLock({
            const text = StringText.of(literal);
            if (auto found = text in _stringTexts) {
                address = *found;
            } else {
                auto bytes = _store.newString((literal.len + 1) * literal.sz);
                auto units = bytes[0 .. literal.len * literal.sz];
                copyUnits(literal, units);
                address = bytes.ptr;
                // Keyed by the copy: the frontend can free its buffer.
                _stringTexts[StringText(literal.sz, units)] = address;
            }
            _stringNodes.insert(literal, address);
        });
        return address;
    }

    public Placed initialValue(
        Type type,
        in Loc loc,
    ) {
        if (auto found = type in _defaults)
            return *found;

        import snakebite.frontend.compiler: withCompilerLock;

        Placed bytes;
        withCompilerLock({
            if (auto found = type in _defaults)
                bytes = *found;
            else
                bytes = *_defaults.insert(type, value(type,
                    initialExpression(type, loc), declarationOf(type)));
        });
        return bytes;
    }

    // The struct or enum that declares `type`, or null for any other type: the
    // `.init` image of a declared type is data of the module of the declaration.
    private static Dsymbol declarationOf(Type type) {
        import snakebite.frontend.typefacts: baseType;

        // The enum first: its base type is the type of its members, not its
        // own declaration.
        if (auto enum_ = type.isTypeEnum)
            return enum_.sym;
        if (auto struct_ = type.baseType.isTypeStruct)
            return struct_.sym;
        return null;
    }

    // The constant goes to the blocks of the D module of `owner`, when there
    // is one: the function whose instructions refer to it, or the field it
    // initializes. Without `owner` it goes to `_store`.
    public Placed value(
        Type type,
        Expression expression,
        Dsymbol owner = null,
    ) {
        const facts = typeFacts(type);
        auto bytes = reserve(facts, owner);
        write(type, facts, expression, bytes.ptr);
        return bytes;
    }

    public Placed value(
        Type type,
        in void[] representation,
        Dsymbol owner = null,
    ) {
        const facts = typeFacts(type);
        assert(representation.length == facts.size);
        auto bytes = reserve(facts, owner);
        copyBytes(bytes.ptr, representation);
        return bytes;
    }

    // Space for a datum goes to the blocks of the D module of `owner`, when
    // `owner` is given and there are such blocks: a variable, the constants
    // of a function and the initial bytes of a field. Any other datum (no
    // `owner`, or no blocks) goes to `_store`.
    public Placed reserve(in TypeFacts facts, Dsymbol owner = null) {
        import snakebite.frontend.compiler: withCompilerLock;
        import snakebite.frontend.dmd.functions: moduleOf;

        Placed bytes;
        withCompilerLock({
            import std.algorithm: canFind;

            auto blocks = _store.blocks;
            if (owner !is null && _blocksOf !is null)
                if (auto module_ = moduleOf(owner))
                    blocks = _blocksOf(module_);
            bytes = blocks.reserve(facts);
            if (recordRelocs && !_knownBlocks.canFind(blocks))
                _knownBlocks ~= blocks;
        });
        return bytes;
    }

    // Records that the word at `place` holds the address `target + offset`,
    // when `place` is in a datum of this: a word in other memory is not in the
    // data of the program, and what points to that memory gets no position.
    // For `staticData`, `target` is the start of its datum and `offset` can
    // reach the end of it; the datum has no blocks when no known blocks hold
    // it. A null `target` is no address.
    private void recordAddress(
        in void* place, in Target target, in size_t offset,
    ) {
        if (!recordRelocs || target.address == 0)
            return;
        Link link;
        link.kind = target.kind;
        if (target.kind == Target.Kind.staticData) {
            link.set = cast(const(StaticBlocks)*) target.datum.set;
            link.block = target.datum.block;
            link.offset = target.datum.offset + offset;
        } else {
            link.address = target.address + offset;
            link.index = target.index;
        }
        recordLink(place, link);
    }

    private void recordLink(in void* place, in Link link) {
        foreach (blocks; _knownBlocks)
            if (blocks.recordAddress(place, link))
                return;
    }

    // The word that refers to `target` in a datum. A datum of a compile to
    // RAM is ready to run once it is written, so a name gives the address
    // of its symbol (`CallPlanStore.wordOf`). A save makes nothing ready to
    // run: the word of a name stays empty, and its record names it.
    private size_t wordOf(in Target target) {
        if (recordRelocs && _plans.isNamed(target))
            return 0;
        return _plans.wordOf(target);
    }

    // A name takes `distance` into itself, so that the word names the
    // symbol and the distance from it.
    private void foldDistance(ref Target target, ref size_t distance) {
        if (distance == 0)
            return;
        if (auto name = _plans.names.nameAt(cast(const(void)*) target.address)) {
            if (name.adjusted !is null)
                internalFailure("a word points into an entry of host code");
            target.address = cast(size_t) _plans.names.named(
                name.symbol, name.distance + distance);
            distance = 0;
        }
    }

    // The name of the symbol `symbol`.
    public const(Name)* named(string symbol) {
        return _plans.names.named(symbol);
    }

    // Copies `source` to `place`, with the records of the addresses in it.
    public void copyBytes(void* place, in void[] source) {
        import core.stdc.string: memcpy;

        memcpy(place, source.ptr, source.length);
        if (!recordRelocs)
            return;
        foreach (blocks; _knownBlocks)
            foreach (link; blocks.linksIn(source.ptr, source.length))
                recordLink(cast(ubyte*) place + link.wordOffset, link);
    }

    // Type data are real druntime objects in datums of the blocks, so that a
    // file can hold them: an object of class `T`, with its vtable pointer a
    // word that names the vtable of `T` in the host.
    public T newObject(T)(Dsymbol owner = null) if (is(T == class)) {
        import core.stdc.string: memcpy;
        import std.traits: InterfacesTuple;

        // An interface slot of the initial image holds a table address, and
        // only the vtable pointer has a record here. The fields of the type
        // data have no default that is an address.
        static assert(InterfacesTuple!T.length == 0,
            T.stringof ~ " implements an interface");

        // The vtable of a class of druntime, as the code generator names it.
        enum vtable = "_D" ~ T.mangleof[1 .. $] ~ "6__vtblZ";
        const initial = T.classinfo.m_init;
        auto placed = reserve(
            TypeFacts(initial.length, (void*).alignof), owner);
        memcpy(placed.ptr, initial.ptr, initial.length);
        storeAddress(&this, placed.ptr,
            Address(Target.Kind.hostSymbol, named(vtable)));
        return cast(T) placed.ptr;
    }

    // What `object` is for a word that holds it: a datum of the blocks, with
    // the distance into the datum, the name of a symbol, or code or data of
    // the host. Without `recordRelocs` only a name is asked for.
    public Address addressOfData(
        in void* object, out size_t distance,
    ) {
        distance = 0;
        if (_plans.names.nameAt(object) !is null)
            return Address(Target.Kind.hostSymbol, object);
        if (!recordRelocs)
            return Address(Target.Kind.staticData, object);
        foreach (blocks; _knownBlocks) {
            DatumRef datum;
            const(void)* start;
            if (blocks.locateDatum(object, datum, start, distance))
                return Address(Target.Kind.staticData, start, datum);
        }
        return Address(Target.Kind.hostSymbol, object);
    }

    // The address of the start of the datum that holds `object`, or the host
    // symbol it is.
    public Address addressOfData(in void* object) {
        size_t distance;
        const address = addressOfData(object, distance);
        if (distance == 0)
            return address;
        const target = address.target;
        return Address(target.kind,
            cast(void*) (target.address + distance), target.datum);
    }

    // The word at `place` becomes a reference to `object`. A value below a
    // page is no address: it is a flag, and it stays as it is.
    public void storeReference(void* place, in void* object) {
        if (cast(size_t) object < firstAddress) {
            *cast(size_t*) place = cast(size_t) object;
            return;
        }
        size_t distance;
        const target = addressOfData(object, distance);
        storeAddress(&this, place, target, distance);
    }

    // The word at `place` becomes the callable address `address`, of the
    // kind that the backend gives it.
    public void storeFunction(void* place, in void* address) {
        if (address is null) {
            *cast(void**) place = null;
            return;
        }
        storeAddress(&this, place, functionAddress(address));
    }

    private Address functionAddress(in void* address) {
        return Address(_functionKind is null
            ? Target.Kind.hostSymbol : _functionKind(address), address);
    }

    // The word at `place` becomes the table (`interfaceTable`) or the record
    // (`interfaceRecord`) `interfaces[index]` of the class information
    // `info` of another object.
    public void storeInterface(
        void* place, in Target.Kind kind, in TypeInfo_Class info,
        in size_t index,
    ) {
        storeAddress(&this, place, Address.ofInterface(kind, info, index));
    }

    // The slice at `place` becomes `data`, which is bytes of a datum, of
    // elements of `elementSize` bytes.
    public void storeSlice(
        void* place, in void[] data, in size_t elementSize = 1,
    ) {
        checkedStoreIntegral(cast(ubyte*) place + arrayLengthOffset,
            data.length / elementSize, size_t.sizeof);
        storeReference(cast(ubyte*) place + arrayPointerOffset, data.ptr);
    }

    // The string at `place` becomes a copy of `text` that the process store
    // owns, with a terminating zero as a literal has.
    public void storeString(void* place, in char[] text) {
        import core.stdc.string: memcpy;

        auto bytes = _store.newString(text.length + 1);
        memcpy(bytes.ptr, text.ptr, text.length);
        checkedStoreIntegral(cast(ubyte*) place + arrayLengthOffset,
            text.length, size_t.sizeof);
        storeAddress(&this, cast(ubyte*) place + arrayPointerOffset,
            Address(Target.Kind.adoptedString, bytes.ptr));
    }

    public void release() {
        _store.release();
    }

    public TlsSlots* tlsSlots() {
        return _store.tlsSlots;
    }

    // `variable`'s storage: this thread's own copy if it is thread-local
    // (finding 1.3 - compiled D gives every thread its own copy of a
    // module-level or `static` local that is not `shared`/`__gshared`),
    // otherwise the one copy every thread shares. Native storage when
    // the variable has it (`storageKindOf`); this program's own
    // otherwise.
    public Placed storageOf(VarDeclaration declaration) {
        auto variable = definitionOf(declaration);
        if (auto found = variable in _statics)
            return *found;

        const facts = typeFacts(variable.type);
        if (variable.isThreadLocalStorage)
            return Placed(_store.tlsSlots.slotFor(
                cast(const(TlsDescriptor)*) tlsDescriptorOf(variable).ptr));

        if (auto name = storageName(variable))
            return *_statics.insert(variable, Placed(
                (cast(void*) _plans.addressOf(name))[0 .. facts.size]));

        import snakebite.frontend.compiler: withCompilerLock;

        Placed bytes;
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

    // The address of the storage of a variable that is not thread-local, with
    // what it points at: a datum of the blocks, or, for native storage, the
    // name of its symbol.
    public Address addressOfStorage(VarDeclaration declaration) {
        auto variable = definitionOf(declaration);
        if (auto name = storageName(variable))
            return Address(Target.Kind.hostSymbol, name);
        auto placed = storageOf(variable);
        return Address(Target.Kind.staticData, placed.ptr, placed.where);
    }

    // The name of the native storage of `variable`, which is not
    // thread-local, or null when the program holds the storage. The
    // declaration decides that another object defines the variable. A
    // variable that the program and another object can both define uses the
    // copy of the process when there is one.
    private const(Name)* storageName(VarDeclaration variable) {
        if (auto found = variable in _storageNames)
            return *found;

        import snakebite.frontend.dmd.mangle: nativeSymbolName;

        const(Name)* name;
        const kind = storageKindOf(variable);
        if (kind != StorageKind.own) {
            name = named(nativeSymbolName(variable));
            if (kind == StorageKind.nativeIfPresent && !_plans.isPresent(name))
                name = null;
        }
        return *_storageNames.insert(variable, name);
    }

    // The descriptor of a thread-local variable: the bytes every thread's
    // own copy starts from, and the identity `TlsSlots.slotFor` keys that
    // copy by. It is a datum, built once, under the lock, and read without
    // one after that (like `_statics`). The bytecode compiler bakes the
    // address of this into an `opTls*` instruction operand in place of a
    // resolved address (finding 1.3): a thread-local variable's address is
    // never a compile-time constant, the same way it never is in compiled D.
    public Placed tlsDescriptorOf(VarDeclaration declaration) {
        auto variable = definitionOf(declaration);
        if (auto found = variable in _tlsDescriptors)
            return *found;

        import snakebite.frontend.compiler: withCompilerLock;

        Placed descriptor;
        withCompilerLock({
            if (auto found = variable in _tlsDescriptors) {
                descriptor = *found;
                return;
            }
            const facts = typeFacts(variable.type);
            string nativeName;
            const kind = storageKindOf(variable);
            if (kind != StorageKind.own) {
                import snakebite.frontend.dmd.mangle: nativeSymbolName;

                const name = nativeSymbolName(variable);
                // Only to learn that the symbol is there: this thread's
                // address is not the descriptor's to keep. Another object
                // defines a native variable: its symbol is found on each
                // thread (`TlsSlots.slotFor`).
                if (kind == StorageKind.native
                        || _threadLocalAddress(name) !is null)
                    nativeName = name;
            }
            Placed template_;
            if (nativeName.length == 0)
                template_ = buildInitialBytes(variable, facts);

            TypeFacts descriptorFacts;
            descriptorFacts.size = TlsDescriptor.sizeof;
            descriptorFacts.alignment = TlsDescriptor.alignof;
            descriptor = reserve(descriptorFacts, variable);
            auto bytes = cast(ubyte*) descriptor.ptr;
            (cast(TlsDescriptor*) bytes).size = facts.size;
            if (nativeName.length) {
                import core.stdc.string: memcpy;

                auto copy = _store.newString(nativeName.length + 1);
                memcpy(copy.ptr, nativeName.ptr, nativeName.length);
                const nameOffset = TlsDescriptor.nativeName.offsetof;
                checkedStoreIntegral(bytes + nameOffset + arrayLengthOffset,
                    nativeName.length, size_t.sizeof);
                storeAddress(&this, bytes + nameOffset + arrayPointerOffset,
                    Address(Target.Kind.adoptedString, copy.ptr));
            } else
                storeAddress(&this, bytes + TlsDescriptor.templateBytes.offsetof,
                    Address(Target.Kind.staticData, template_.ptr,
                        template_.where));
            _tlsDescriptors.insert(variable, descriptor);
        });
        return descriptor;
    }

    // The address of the descriptor of a thread-local variable, with what it
    // points at.
    public Address addressOfTlsDescriptor(VarDeclaration variable) {
        auto placed = tlsDescriptorOf(variable);
        return Address(Target.Kind.staticData, placed.ptr, placed.where);
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

    private enum StorageKind {
        // Another object defines the variable: its storage is native, and a
        // missing symbol is an error, as at the link of a native build. Native
        // code reads and writes it there, so one storage serves both sides.
        native,
        own,
        // The program defines it, and a dependency can define it too: a
        // static variable of a template instance, or one nested in a
        // function of one. A native build keeps one copy of it, so the
        // native copy is used when the process has one.
        nativeIfPresent,
    }

    private StorageKind storageKindOf(VarDeclaration variable) const {
        if (_isDefinedElsewhere(variable))
            return StorageKind.native;
        return _isRootOwned(variable)
            ? StorageKind.own : StorageKind.nativeIfPresent;
    }

    private static bool isExtern(VarDeclaration variable) {
        import snakebite.frontend.ast: STC;

        return (variable.storage_class & STC.extern_) != 0;
    }

    // Reserves and fills a variable's own storage bytes: called under
    // the compiler lock, for a `shared`/`__gshared` variable's one and
    // only storage, or for a thread-local variable's template. A
    // recursive call for the same variable - its own initializer refers
    // to it - finds the reservation `_pendingStatics` is already holding
    // for it, rather than reserving a second time.
    private Placed buildInitialBytes(VarDeclaration variable, in TypeFacts facts) {
        import core.stdc.string: memcpy;
        import snakebite.frontend.compiler: inFrontend;

        if (auto pending = variable in _pendingStatics)
            return *pending;

        auto bytes = reserve(facts, variable);
        _pendingStatics[variable] = bytes;
        scope (exit) _pendingStatics.remove(variable);

        if (variable._init is null) {
            const initial = initialValue(variable.type, variable.loc);
            copyBytes(bytes.ptr, initial[0 .. bytes.length]);
        } else if (variable._init.isVoidInitializer is null) {
            auto initializer = variable._init.isExpInitializer;
            auto expression = initializer is null
                ? inFrontend!"getConstInitializer"(variable, true)
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
    private Address placeOf(Declaration symbol) {
        import std.conv: text;

        if (auto variable = symbol.isVarDeclaration) {
            if (variable.isThreadLocalStorage)
                throw new Exception(text(
                    "cannot bake the address of thread-local variable `",
                    variable.toChars, "` into a constant initializer"));
            return addressOfStorage(variable);
        }
        auto address = _symbolAddress(symbol);
        // A function address is code: a guest function, the entry that host
        // code calls for one, or a function of the host.
        if (symbol.isFuncDeclaration !is null)
            return functionAddress(address);
        return Address(Target.Kind.hostSymbol, address);
    }

    public void fillFields(
        AggregateDeclaration declaration,
        ubyte* place,
    ) {
        import snakebite.frontend.compiler: inFrontend;

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
                    inFrontend!"getConstInitializer"(field, false),
                    field,
                );
            if (field.isBitFieldDeclaration !is null) {
                const access = bitfieldAccess(field);
                access.store(place + access.offset,
                    checkedLoadIntegral(bytes.ptr, bytes.length, false));
                continue;
            }

            copyBytes(place + field.offset, bytes);
        }
    }
}

// Like dmd's `membersToDt`, the first present union member owns its bytes.
// Packed siblings can share bytes, but not the bits of a selected member.
private bool fieldImageIncludes(
    imported!"snakebite.frontend.ast".VarDeclaration field,
    ref size_t writtenBitEnd,
) {
    const bitfield = field.isBitFieldDeclaration;
    const start = field.offset * 8 + (bitfield is null ? 0 : bitfield.bitOffset);
    if (start < writtenBitEnd)
        return false;
    writtenBitEnd = start + (bitfield is null
        ? representationSize(field.type) * 8
        : bitfield.fieldWidth);
    return true;
}

private alias SymbolAddress =
    void* delegate(imported!"snakebite.frontend.ast".Declaration);
private alias SymbolPlaceOf =
    Address delegate(imported!"snakebite.frontend.ast".Declaration);
// What kind of target a function address is (`Target.Kind`).
private alias FunctionKind = Target.Kind delegate(in void* address);
// This thread's address of a thread-local symbol, by linker name.
private alias ThreadLocalAddress = void* delegate(in char[] name);
// The `TypeInfo` object of a type.
private alias TypeInfoOf = TypeInfo delegate(imported!"snakebite.frontend.ast".Type);

// Whether two element types are the same type once their qualifiers are
// dropped. `mutableOf` mutates the type's own cache unless the type has no
// qualifier, so only a qualified one needs the frontend lock.
private bool mutableElementsEqual(
    imported!"snakebite.frontend.ast".Type first,
    imported!"snakebite.frontend.ast".Type second,
) {
    import snakebite.frontend.compiler: inFrontend;

    if (first.mod == 0 && second.mod == 0)
        return first.equals(second);

    return inFrontend!"mutableOf"(first).equals(inFrontend!"mutableOf"(second));
}

private imported!"snakebite.frontend.ast".Expression initialExpression(
    imported!"snakebite.frontend.ast".Type type,
    in imported!"snakebite.frontend.ast".Loc loc,
) {
    import snakebite.frontend.compiler: inFrontend;

    return inFrontend!"defaultInitLiteral"(type, loc);
}

// Whether `value`, through any casts, is the address of a symbol plus an
// offset: the link-time constant that C allows as the initialiser of an
// integer, `(unsigned long) &variable`.
private bool isSymbolAddress(
    imported!"snakebite.frontend.ast".Expression value,
    out imported!"snakebite.frontend.ast".Declaration symbol,
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
    imported!"snakebite.frontend.ast".Type type,
    imported!"snakebite.frontend.ast".Expression value,
    void* place,
) {
    storeValue(type, typeFacts(type), value, place, null);
}

private void storeValue(
    imported!"snakebite.frontend.ast".Type type,
    imported!"snakebite.frontend.ast".Expression value,
    void* place,
    scope SymbolPlaceOf symbolAddress,
    NativeData* nativeData = null,
) {
    storeValue(type, typeFacts(type), value, place, symbolAddress, nativeData);
}

public void storeValue(
    imported!"snakebite.frontend.ast".Type type,
    in TypeFacts facts,
    imported!"snakebite.frontend.ast".Expression value,
    void* place,
) {
    storeValue(type, facts, value, place, null);
}

// The code unit size is part of the key: the terminator has that width, so
// text of equal bytes in two widths does not share a copy.
private struct StringText {
    size_t unitSize;
    const(ubyte)[] units;

    static StringText of(imported!"snakebite.frontend.ast".StringExp literal) {
        return StringText(
            literal.sz,
            cast(const(ubyte)[]) literal.peekData[0 .. literal.len * literal.sz],
        );
    }
}

private void copyUnits(
    imported!"snakebite.frontend.ast".StringExp literal,
    ubyte[] destination,
) {
    import core.stdc.string: memcpy;

    memcpy(destination.ptr, literal.peekData.ptr, destination.length);
}

// The one write of an address into a datum: the word `target + offset` goes
// to `place`, with its record. `size` is the width of the word.
private void storeAddress(
    NativeData* nativeData, void* place, in Address target,
    in size_t offset = 0, in size_t size = size_t.sizeof,
) {
    if (nativeData is null) {
        checkedStoreIntegral(place, target.word + offset, size);
        return;
    }
    Target where = target.target;
    size_t distance = offset;
    nativeData.foldDistance(where, distance);
    checkedStoreIntegral(place, nativeData.wordOf(where) + distance, size);
    nativeData.recordAddress(place, where, distance);
}

private const(void)* stringPointer(
    NativeData* nativeData,
    imported!"snakebite.frontend.ast".StringExp literal,
) {
    return nativeData is null
        ? terminatedCopy(literal).ptr : nativeData.stringData(literal);
}

// A literal is followed by one zero code unit in memory, so that it converts
// to a C string. The frontend does not keep one in a literal that it made by
// folding, so the code units are copied to storage that has it.
private ubyte[] terminatedCopy(imported!"snakebite.frontend.ast".StringExp literal) {
    // `auto`: the copy is written, so it cannot be `const`.
    auto bytes = new ubyte[(literal.len + 1) * literal.sz];
    copyUnits(literal, bytes[0 .. literal.len * literal.sz]);
    return bytes;
}

private void storeValue(
    imported!"snakebite.frontend.ast".Type type,
    in TypeFacts facts,
    imported!"snakebite.frontend.ast".Expression value,
    void* place,
    scope SymbolPlaceOf symbolAddress,
    NativeData* nativeData = null,
) {
    import core.stdc.string: memcpy, memset;
    import snakebite.frontend.ast: nextOf, Tarray, Tdelegate, toImaginary,
        Tpointer, Tsarray, Tvector, TY, Type;
    import snakebite.frontend.compiler: inFrontend;
    import snakebite.frontend.typefacts:
        baseType, complexValue, integerValue, realValue;
    import std.conv: text;

    if (value.isNullExp) {
        memset(place, 0, facts.size);
        return;
    }

    if (facts.isIntegral) {
        imported!"snakebite.frontend.ast".Declaration symbol;
        ulong offset;
        if (isSymbolAddress(value, symbol, offset)) {
            assert(symbolAddress !is null);
            storeAddress(nativeData, place, symbolAddress(symbol), offset,
                facts.size);
            return;
        }

        checkedStoreIntegral(place, value.integerValue, facts.size);
        return;
    }

    type = type.baseType;

    // DMD represents an integer-to-pointer cast as an integer literal. Its
    // low pointer-width bits are the pointer value in the native layout.
    if (type.ty == Tpointer && value.isIntegerExp) {
        checkedStoreIntegral(place, cast(ulong) value.integerValue, facts.size);
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
        auto sourceElement = value.type.baseType.nextOf;
        const wholeArray = sourceElement !is null
            && mutableElementsEqual(sourceElement, array.next);
        if (!wholeArray || value.isStringExp is null) {
            const elementSize = representationSize(array.next);
            auto literal = wholeArray ? value.isArrayLiteralExp : null;
            // dmd's default initializer of a `void[N]` is the `ubyte` one.
            auto storedElement = array.next.baseType.ty == TY.Tvoid
                ? Type.tuns8 : array.next;
            foreach (i; 0 .. cast(size_t) array.dim.integerValue)
                storeValue(storedElement, literal is null ? value : literal[i],
                    bytes + i * elementSize, symbolAddress, nativeData);
            return;
        }
    }

    if (auto symbol = value.isSymOffExp) {
        assert(symbolAddress !is null);
        storeAddress(nativeData, place, symbolAddress(symbol.var),
            symbol.offset);
        return;
    }

    if (auto literal = value.isFuncExp) {
        assert(symbolAddress !is null);
        if (type.ty == Tdelegate) {
            *cast(void**) (bytes + delegateContextOffset) = null;
            storeAddress(nativeData, bytes + delegateFunctionOffset,
                symbolAddress(literal.fd));
        } else
            storeAddress(nativeData, place, symbolAddress(literal.fd));
        return;
    }

    if (auto typeId = value.isTypeidExp) {
        import snakebite.frontend.ast: isType;

        auto objectType = isType(typeId.obj);
        assert(nativeData !is null && objectType !is null);
        nativeData.storeReference(place,
            cast(const(void)*) nativeData._typeInfo(objectType));
        return;
    }

    if (auto reference = value.isClassReferenceExp) {
        assert(nativeData !is null);
        auto object = nativeData.classValue(reference);
        int offset;
        type.isTypeClass.sym.isBaseOf(reference.originalClass, &offset);
        storeAddress(nativeData, place,
            Address(Target.Kind.staticData, object.ptr, object.where), offset);
        return;
    }

    // Also `&(struct S){1, 2}` at file scope in C.
    if (auto address = value.isAddrExp) {
        if (isStaticStructAddress(address)) {
            assert(nativeData !is null);
            auto struct_ = nativeData.structValue(address.e1.isStructLiteralExp);
            storeAddress(nativeData, place, Address(
                Target.Kind.staticData, struct_.ptr, struct_.where));
            return;
        }
    }

    if (auto literal = value.isStringExp) {
        const elementSize = representationSize(type.nextOf);
        assert(literal.sz == elementSize);
        if (type.ty == Tsarray) {
            assert(literal.len * elementSize == facts.size);
            memcpy(place, literal.peekData.ptr, facts.size);
        } else if (type.ty == Tpointer) {
            storeAddress(nativeData, place, Address(Target.Kind.adoptedString,
                stringPointer(nativeData, literal)));
        } else {
            assert(type.ty == Tarray);
            checkedStoreIntegral(bytes + arrayLengthOffset, literal.len, size_t.sizeof);
            storeAddress(nativeData, bytes + arrayPointerOffset,
                Address(Target.Kind.adoptedString,
                    stringPointer(nativeData, literal)));
        }
        return;
    }

    if (auto literal = value.isArrayLiteralExp) {
        assert(type.ty == Tarray || type.ty == Tpointer);
        const elementSize = representationSize(type.nextOf);
        // The data of the process store when there is one, so that a file can
        // hold them.
        Placed data;
        if (nativeData !is null && literal.elements.length != 0) {
            auto arrayFacts = typeFacts(type.nextOf);
            arrayFacts.size = literal.elements.length * elementSize;
            data = nativeData.reserve(arrayFacts);
        } else
            data = Placed(new void[literal.elements.length * elementSize]);
        foreach (i; 0 .. literal.elements.length)
            storeValue(type.nextOf, literal[i],
                cast(ubyte*) data.ptr + i * elementSize, symbolAddress, nativeData);
        // `int *p = (int[]){1, 2};` at file scope in C: the literal decays
        // to a pointer to its own static storage.
        if (type.ty == Tpointer) {
            storeAddress(nativeData, place,
                Address(Target.Kind.staticData, data.ptr, data.where));
            return;
        }
        checkedStoreIntegral(bytes + arrayLengthOffset, literal.elements.length,
            size_t.sizeof);
        storeAddress(nativeData, bytes + arrayPointerOffset,
            Address(Target.Kind.staticData, data.ptr, data.where));
        return;
    }

    if (type.isTypeStruct !is null && value.isIntegerExp) {
        // DMD encodes a zero-initialized struct as an IntegerExp. Resolve
        // that encoding here, not from the destination's byte count.
        assert(value.integerValue == 0);
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
                access.store(bytes + access.offset, element.integerValue);
            } else
                storeValue(field.type, element, bytes + field.offset,
                    symbolAddress, nativeData);
        }
        return;
    }

    final switch (type.ty) with (TY) {
        case Tfloat32:
            *cast(float*) place = cast(float) value.realValue;
            return;

        case Tfloat64:
            *cast(double*) place = cast(double) value.realValue;
            return;

        case Tfloat80:
            *cast(real*) place = value.realValue;
            return;

        // A complex value's native layout is its `{re, im}` pair, each
        // exactly half of `facts.size` - `complexValue`
        // already answers `re`/`im` for an `IntegerExp`/`RealExp` (an
        // implicit real-to-complex promotion, `im` zero) as well as a
        // `ComplexExp` literal, so this one case covers every constant
        // source a `complex`-typed constant declaration can have.
        case Tcomplex32, Tcomplex64, Tcomplex80: {
            const parts = value.complexValue;
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

        // An associative array's layout is druntime's. The frontend has
        // interpreted the lowering of the literal for a static initialiser,
        // as it does for compiled code: the result is a pointer to a
        // struct literal of the implementation, which is data as any other.
        case Taarray: {
            auto literal = value.isAssocArrayLiteralExp;
            assert(literal !is null, text("no native layout for the ",
                "constant `", value.toString, "` of type `",
                type.toString, "`: an associative-array-typed constant ",
                "is always an associative-array literal"));

            auto lowered = literal.loweringCtfe;
            assert(lowered !is null, text("no native layout for the constant `",
                value.toString, "` of type `", type.toString,
                "`: dmd left it without a static-initializer lowering"));
            assert(nativeData !is null);

            storeValue(lowered.type, typeFacts(lowered.type), lowered, place,
                symbolAddress, nativeData);
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
