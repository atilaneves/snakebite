module snakebite.stack.tls;


private:


import snakebite.failure.report: internalFailure;
import snakebite.ffi.callplanstore: CallPlanStore;
import snakebite.ffi.names: DefinitionHere;


// A thread-local guest variable's compile-time-constant description
// (issue #40, ADR-0006, finding 1.3): the bytes every thread's copy
// starts from. Built once, under the compiler lock, by
// `snakebite.language.statics.data.NativeData.tlsDescriptorOf`; read here with no
// lock, since nothing ever changes a `TlsDescriptor` after that.
//
// A thread-local variable's storage differs by thread, the same way a
// compiled D thread-local's does: compiled D reaches it through the
// thread pointer plus a fixed offset into the TLS segment, never through
// a linked absolute address. The bytecode compiler bakes a pointer to
// one of these into an `opTls*` instruction operand in place of a
// resolved storage address, so no instruction ever holds one thread's
// address as a constant every other thread would read or write through
// too.
//
// This module holds no dmd import, so the bytecode VM - which the
// project's coding guideline forbids from importing dmd - can resolve an
// `opTls*` operand without doing so.
public struct TlsDescriptor {
    public const(void)* templateBytes;
    public size_t size;
    // The alignment that native code gives the variable: each thread's copy
    // has it.
    public uint alignment;
    // Set when the variable's storage is native (a dependency image's
    // own thread-local, or an `extern` one), or can be (a variable of a
    // template instance, which has `templateBytes` too): the linker name
    // that `CallPlanStore.threadLocalAddressIfPresent` answers, on each
    // thread, with that thread's copy in the image's TLS block. No copy is
    // made from a template when the process has the symbol
    // (`CallPlanStore.chosenCopy`), so native code and guest code on one
    // thread reach the same bytes.
    public string nativeName;
    // The declaration of the variable, for the failure of a symbol that no
    // object defines.
    public string declaredBy;
}


// One thread's own copies of the thread-local guest variables it has
// touched, grown on demand. A `TlsSlots` belongs to exactly one thread -
// Fibers on that thread share it (ADR-0006), so `slotFor` takes no lock:
// nothing here is ever visible to another thread.
//
// The copies and the table that finds them live on the C heap and the GC
// scans each copy through `addRange`. The first touch of a variable can
// happen in a destructor that the GC finalizer runs, on a thread that never
// ran guest code, and a GC allocation is forbidden there; `addRange` takes
// no GC lock.
public struct TlsSlots {
    private struct Entry {
        const(void)* key;
        void* bytes;
        size_t size;
        bool owned;
    }

    private Entry[] _table;
    private size_t _count;
    // What a descriptor with a `nativeName` finds its symbol with, on this
    // thread. The store of the program that the table belongs to, which
    // must outlive the table.
    private const(CallPlanStore)* _store;

    @disable this(this);

    public this(const(CallPlanStore)* store) {
        _store = store;
    }

    ~this() {
        import core.memory: GC;
        import core.stdc.stdlib: free;

        foreach (ref entry; _table) {
            if (entry.key is null || !entry.owned)
                continue;
            if (entry.size)
                GC.removeRange(entry.bytes);
            free(entry.bytes);
        }
        free(_table.ptr);
        _table = null;
        _count = 0;
    }

    // No copy that a guest pointer could reach was made.
    public bool empty() const {
        return _count == 0;
    }

    // A descriptor is stored once and never moves, so its own address
    // identifies the variable.
    public void[] slotFor(const(TlsDescriptor)* descriptor) {
        const key = cast(const(void)*) descriptor;
        if (auto found = find(key))
            return found.bytes[0 .. found.size];

        Entry entry = Entry(key);
        // A variable that an SBC file defines has one copy on each thread,
        // made from the descriptor of the definition, as a linker gives a
        // thread-local symbol one place in the thread-local block of the
        // process. The copy of the process goes first for a variable that
        // no SBC file defines or that other objects can define too
        // (`SymbolDefinition.usesProcessCopyFirst`), as for any other datum
        // (`CallPlanStore.chosenCopy`). It is resolved on this thread: a
        // thread-local symbol's address is the calling thread's own, so
        // another thread's answer would be that thread's copy.
        const name = descriptor.nativeName;
        const here = name.length ? _store.names.definitionHere(name) : null;
        const asksProcess = name.length
            && (here is null || here.usesProcessCopyFirst);
        // `auto`: the copy of a thread is written through `native`.
        auto processCopy = asksProcess
            ? _store.threadLocalAddressIfPresent(name)
            : null;
        const defining = here is null ? null : descriptorOf(here.definition);
        void* native;
        if (processCopy !is null)
            native = processCopy;
        // No SBC file defines the variable: the program's own copy is made
        // below from the template, and a variable with no template is a
        // symbol that no object defines.
        else if (defining is null) {
            if (name.length && descriptor.templateBytes is null)
                throw CallPlanStore.missing(name, descriptor.declaredBy);
        }
        // Another descriptor is the definition: its copy is the one copy.
        else if (defining !is descriptor)
            native = slotFor(defining).ptr;
        // Else this descriptor is the definition: its copy is made below from
        // its own template.
        if (native !is null)
            entry.bytes = native;
        else {
            import core.memory: GC;
            import core.stdc.string: memcpy;
            import core.sys.posix.stdlib: posix_memalign;
            import std.algorithm: max;

            // `posix_memalign` takes no alignment below a pointer's, and can
            // give null for a request of no bytes, which is not a failure
            // here: a variable of no size still has an address.
            const alignment = max(descriptor.alignment, (void*).sizeof);
            const requestSize = max(descriptor.size, 1);
            if (posix_memalign(&entry.bytes, alignment, requestSize) != 0)
                internalFailure("out of memory for a thread-local variable");
            memcpy(entry.bytes, descriptor.templateBytes, descriptor.size);
            if (descriptor.size)
                GC.addRange(entry.bytes, descriptor.size);
            entry.owned = true;
        }
        entry.size = descriptor.size;
        insert(entry);
        return entry.bytes[0 .. entry.size];
    }

    // The descriptor of a thread-local variable that an SBC file defines,
    // which is the datum of its definition
    // (`NativeData.makeAndDefineStorage`): one descriptor gives each thread
    // its copy, as the template of a thread-local symbol does in native code.
    private static const(TlsDescriptor)* descriptorOf(
        in DefinitionHere definition,
    ) {
        import snakebite.ffi.names: GuestFunction;
        import snakebite.native.address: DatumRef;
        import snakebite.native.staticstore: startOf;
        import std.sumtype: match;

        return definition.match!(
            (in GuestFunction guest) => internalFailure(
                "a thread-local variable is defined by a function",
            ),
            (in DatumRef datum) => cast(const(TlsDescriptor)*) startOf(datum),
        );
    }

    private Entry* find(const(void)* key) {
        if (_table.length == 0)
            return null;
        const mask = _table.length - 1;
        for (auto at = hashOf(key) & mask; ; at = (at + 1) & mask) {
            if (_table[at].key is key)
                return &_table[at];
            if (_table[at].key is null)
                return null;
        }
    }

    private void insert(Entry entry) {
        // Keep the table at most half full so a probe always finds a gap.
        if ((_count + 1) * 2 > _table.length)
            grow;
        place(_table, entry);
        ++_count;
    }

    private void grow() {
        import core.stdc.stdlib: calloc, free;

        const length = _table.length ? _table.length * 2 : 8;
        auto memory = cast(Entry*) calloc(length, Entry.sizeof);
        if (memory is null)
            internalFailure("out of memory for a thread-local table");
        auto bigger = memory[0 .. length];
        foreach (entry; _table)
            if (entry.key !is null)
                place(bigger, entry);
        free(_table.ptr);
        _table = bigger;
    }

    private static void place(Entry[] table, Entry entry) {
        const mask = table.length - 1;
        auto at = hashOf(entry.key) & mask;
        while (table[at].key !is null)
            at = (at + 1) & mask;
        table[at] = entry;
    }
}
