module snakebite.ffi.callback;


private:


import snakebite.failure.report: internalFailure;


import core.sync.mutex: Mutex;
import core.sys.posix.sys.mman:
    MAP_ANON, MAP_FAILED, MAP_FIXED, MAP_PRIVATE, MAP_SHARED, PROT_EXEC,
    PROT_NONE, PROT_READ, PROT_WRITE, mmap, mprotect, munmap;
import snakebite.ffi.callplan: CallPlan, NativeSignature, prepareCallback;
import snakebite.ffi.sysv:
    CallbackTrailer, CallFrame, callbackEntriesPerChunk, callbackEntryBytes,
    snakebite_ffi_callback_chunk, snakebite_ffi_callback_chunk_end,
    snakebite_ffi_callback_chunk_trailer, snakebite_ffi_callback_common;


// The pool of callback entries (ADR-0003): the addresses host code calls
// when it calls a guest function through a function pointer or a
// delegate. Every entry is a copy of the same position-independent
// template in `sysv_amd64.S`; `snakebite_ffi_callback_common` spills the
// argument registers and calls `snakebite_ffi_callback_handler` below,
// which finds the entry's slot and replays the slot's plan in reverse to
// re-enter the backend that owns the slot.
//
// Each `CallbackBridge` owns a `Pool`: its chunks, its mutex and its
// address range (`Pool`, below). The template linked into the binary is only
// bytes: a new chunk is a copy of them in a new mapping, flipped to
// read-execute (`allocateChunk`), so memory is never writable and executable
// at the same time. A slot is released only by `CallbackBridge.release`, for
// a bridge whose entries no host code can call any more; it unmaps every
// chunk and the range, and drops the root of every slot table. Until then a
// chunk and its slot table stay, so an entry that host code keeps stays
// callable. Nothing else is shared between bridges, and no lock is taken
// when an entry is called (ADR-0006).


// What the pool hands a backend when host code calls one of its guest
// functions: which function, in the backend's own representation, and
// the arguments and result place in native layout - the arguments in
// the same shape `CallPlan.call` takes them, one address per declared
// parameter, and for a `ref`/`out` parameter the address of the pointer
// the host passed. When the signature has a hidden context, `arguments`
// carries it too, first: the address of a pointer-sized word holding it,
// already adjusted for the callee's own place in a class or interface
// hierarchy (`Slot.contextAdjustment`) - one argument list, the same
// shape whether or not there is a context, so a backend's own
// `runHostToGuest` reads it exactly as it reads a declared parameter.
public struct CallbackCall {
    public const(void)* function_;
    public void* returnPlace;
    public const(void*)[] arguments;
    // A native SysV `va_list` cursor for a C or D variadic callback.
    // It points into this invocation's scratch storage.
    public void* variadicCursor;
    // The host's D `_arguments` TypeInfo_Tuple, for an extern(D) untyped
    // variadic callback.
    public const(void)* variadicTypes;
}


public alias CallbackHandler = extern(C) void function(void*, CallbackCall*);


// What one entry re-enters: the backend (`handler`, `owner`), the guest
// function in that backend's own representation (`function_`), and the
// plan its arguments are unpacked with.
private struct Slot {
    CallbackHandler handler;
    void* owner;
    const(void)* function_;
    const(CallPlan)* plan;
    ptrdiff_t contextAdjustment;
    const(void)* nativeAddress;
}


private struct Chunk {
    const(ubyte)* base;
    Slot[] slots;
    size_t used;
}


// How a new chunk gets its executable copy of the template. `protect`
// is the usual way; `dualMapping` is the fallback for a kernel that
// refuses to make an anonymous mapping executable after it was written
// (SELinux `execmem`, PaX, systemd's `MemoryDenyWriteExecute`), and maps
// one memory file twice instead, one view to write and one to execute.
public enum ChunkStrategy {
    protect,
    dualMapping,
}


// What `CallbackBridge.guestTarget` reads for an entry in the bridge's
// reserved range. `word` is written last, with release, and is null while
// the entry is free or forwards to a host function.
private struct GuestEntry {
    const(void)* word;
    ptrdiff_t adjustment;
}


// 1 MiB of address space for the chunks of one bridge: 256 one-page chunks,
// 65024 entries. Nothing is committed until a chunk is mapped, and the part
// of the guest-entry table that describes a chunk is committed when the
// chunk's place in the range is claimed.
private enum reservedBytes = size_t(1) << 20;


// One bridge's pool of entries. Guarded by `mutex`; the entry code and
// the handler read a chunk's slot table without it, and a slot is written
// completely before its entry is handed out.
//
// The pool reserves one address range at its first chunk, followed by a
// table with a `GuestEntry` for each 16 bytes of the range, and maps each
// chunk into the next page of the range. An address inside the claimed part
// of the range is an entry of this pool, and the table says which guest
// function it runs: one comparison and an index, no hash lookup and no lock
// (ADR-0006). A chunk that does not fit in the range, or every chunk when
// the reservation failed, is mapped wherever the kernel chooses and found
// through the bridge's hash tables, so the pool has no fixed limit
// (ADR-0003).
private struct Pool {
    Chunk[] chunks;
    Mutex mutex;
    // Set under `mutex` before the first release store of `rangeClaimed`;
    // read without a lock only after an acquire load of `rangeClaimed`.
    // Null when the reservation failed or was not tried yet.
    ubyte* range;
    GuestEntry* guestEntries;
    // How much of the range chunks use. Written under `mutex`.
    size_t rangeUsed;
    // How much of `guestEntries` is committed, as a length of the range.
    // Stored with release under `mutex`, after the pages are readable; an
    // address at or past it is not an entry yet.
    shared(size_t) rangeClaimed;
    bool rangeTried;

    bool inRange(in const(void)* address) const {
        return cast(size_t) address - cast(size_t) range < reservedBytes;
    }

    // The table position of `address` when it is in the claimed part of the
    // range; null for any other address.
    inout(GuestEntry)* guestEntryOf(in const(void)* address) inout {
        import core.atomic: atomicLoad, MemoryOrder;

        const claimed = atomicLoad!(MemoryOrder.acq)(rangeClaimed);
        const offset = cast(size_t) address - cast(size_t) range;
        return offset < claimed
            ? &guestEntries[offset / callbackEntryBytes] : null;
    }

    // The slot that `entry` runs, which a chunk of this pool holds.
    const(Slot) slotOf(in const(void)* entry) const {
        auto lock = cast(Mutex) mutex;
        lock.lock;
        scope(exit) lock.unlock;

        foreach (chunk; chunks)
            if (entry >= chunk.base && entry < chunk.base + chunkBytes)
                return chunk.slots[(cast(const(ubyte)*) entry - chunk.base)
                    / callbackEntryBytes];
        internalFailure("an entry that no chunk of the pool holds");
    }
}


shared static this() {
    import std.conv: text;

    // The assembler's own `CB_*` defines cannot be read from D, so the
    // template's real layout is checked against `sysv.d`'s constants here,
    // once, before any entry is handed out.
    const entryBytes = callbackEntriesPerChunk * callbackEntryBytes;
    if (trailerOffset != entryBytes
            || templateEnd - cast(const(ubyte)*) templateTrailer
                <= CallbackTrailer.sizeof
            || templateTrailer.commonDelta
                != commonEntry - cast(const(ubyte)*) templateTrailer
            || templateTrailer.slots !is null)
        throw new Exception(
            text("ffi callback template layout mismatch: trailer at ",
                trailerOffset, ", expected ", entryBytes),
        );
}

private const(ubyte)* templateBase() {
    return cast(const(ubyte)*) &snakebite_ffi_callback_chunk;
}

private const(ubyte)* templateEnd() {
    return cast(const(ubyte)*) &snakebite_ffi_callback_chunk_end;
}

private const(CallbackTrailer)* templateTrailer() {
    return cast(const(CallbackTrailer)*)
        &snakebite_ffi_callback_chunk_trailer;
}

private const(ubyte)* commonEntry() {
    return cast(const(ubyte)*) &snakebite_ffi_callback_common;
}

private size_t trailerOffset() {
    return cast(const(ubyte)*) templateTrailer() - templateBase();
}


// The address host code calls for `slot`: the next free entry, from a new
// chunk if every existing one is full.
private const(void)* reserve(ref Pool pool, Slot slot) {
    pool.mutex.lock;
    scope(exit) pool.mutex.unlock;

    if (pool.chunks.length == 0
            || pool.chunks[$ - 1].used == callbackEntriesPerChunk)
        pool.chunks ~= pool.allocateChunk(ChunkStrategy.protect, true);

    auto chunk = &pool.chunks[$ - 1];
    const index = chunk.used++;
    chunk.slots[index] = slot;
    const entry = chunk.base + index * callbackEntryBytes;
    pool.publishGuest(entry, slot);
    return entry;
}


// Callers hold `pool.mutex`. The fields are written before `word`, whose
// release store publishes them to `guestTarget`. The entry's address
// reaches guest data only after this returns.
private void publishGuest(ref Pool pool, in const(void)* entry, in Slot slot) {
    import core.atomic: atomicStore, MemoryOrder;

    auto guest = pool.guestEntryOf(entry);
    if (guest is null || slot.nativeAddress !is null)
        return;

    guest.adjustment = slot.contextAdjustment;
    atomicStore!(MemoryOrder.rel)(guest.word, slot.function_);
}


// Gives every chunk of `pool` back: unmaps its entries and lets the
// collector free its slot table. Host code must not call any entry of the
// pool after this.
private void releaseChunks(ref Pool pool) {
    import core.atomic: atomicStore, MemoryOrder;
    import core.memory: GC;

    pool.mutex.lock;
    scope(exit) pool.mutex.unlock;

    // No entry is an entry any more, and no reader gets a stale table.
    atomicStore!(MemoryOrder.rel)(pool.rangeClaimed, 0);
    foreach (chunk; pool.chunks) {
        GC.removeRoot(chunk.slots.ptr);
        if (!pool.inRange(chunk.base))
            munmap(cast(void*) chunk.base, roundUpToPage(chunkBytes));
    }
    pool.chunks = null;
    if (pool.range !is null)
        munmap(pool.range, reservedBytes + tableBytes);
    pool.range = null;
    pool.guestEntries = null;
    pool.rangeUsed = 0;
    pool.rangeTried = false;
}


private enum tableBytes = reservedBytes / callbackEntryBytes * GuestEntry.sizeof;


private size_t chunkBytes() {
    return templateEnd - templateBase;
}


// A new chunk: the template's bytes, in memory this process can execute,
// with the trailer patched to reach `snakebite_ffi_callback_common` from
// the copy's own address and to name the copy's own slot table. The table
// is a GC root until `releaseChunks`: host code can call the chunk's
// entries until then, and each used slot holds its owner.
// `fallback` says whether a refused `protect` may fall through to
// `dualMapping`.
private Chunk allocateChunk(
    ref Pool pool, in ChunkStrategy strategy, in bool fallback,
) {
    import core.memory: GC;

    auto slots = new Slot[callbackEntriesPerChunk];
    const bytes = chunkBytes;
    auto target = pool.claimRange(roundUpToPage(bytes));

    const(ubyte)* base;
    final switch (strategy) with (ChunkStrategy) {
        case protect:
            base = copyThenProtect(bytes, slots.ptr, target);
            if (base is null) {
                if (!fallback)
                    throw new Exception(
                        "ffi callback pool: mprotect refused to make the " ~
                            "chunk executable, and no fallback was allowed",
                    );
                base = copyDualMapped(bytes, slots.ptr, target);
            }
            break;

        case dualMapping:
            base = copyDualMapped(bytes, slots.ptr, target);
            break;
    }

    GC.addRoot(slots.ptr);
    return Chunk(base, slots, 0);
}


// The next `size` bytes of the pool's range, or null when it is used up,
// could not be reserved, or the kernel refuses to commit the matching part
// of the table. The first call reserves the range. Callers hold
// `pool.mutex`.
private ubyte* claimRange(ref Pool pool, in size_t size) {
    import core.atomic: atomicStore, MemoryOrder;
    import core.memory: pageSize;

    if (!pool.rangeTried) {
        pool.rangeTried = true;
        auto range = mmap(
            null, reservedBytes + tableBytes, PROT_NONE,
            MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (range != MAP_FAILED) {
            pool.range = cast(ubyte*) range;
            pool.guestEntries = cast(GuestEntry*) (pool.range + reservedBytes);
        }
    }

    if (pool.range is null || pool.rangeUsed + size > reservedBytes)
        return null;

    const first = pool.rangeUsed / callbackEntryBytes * GuestEntry.sizeof;
    const last = (pool.rangeUsed + size) / callbackEntryBytes
        * GuestEntry.sizeof;
    const start = first / pageSize * pageSize;
    if (mprotect(
            cast(ubyte*) pool.guestEntries + start,
            roundUpToPage(last) - start,
            PROT_READ | PROT_WRITE) != 0)
        return null;

    auto claimed = pool.range + pool.rangeUsed;
    pool.rangeUsed += size;
    atomicStore!(MemoryOrder.rel)(pool.rangeClaimed, pool.rangeUsed);
    return claimed;
}


// Gives a mapping back: a chunk in the range goes back to reserved address
// space, which later chunks may need, and any other mapping is unmapped.
private void discardMapping(ubyte* mapping, in size_t size, in bool inRange) {
    if (inRange)
        mmap(mapping, size, PROT_NONE,
            MAP_PRIVATE | MAP_ANON | MAP_NORESERVE | MAP_FIXED, -1, 0);
    else
        munmap(mapping, size);
}


// Fills `writable` with the template, patched for a copy whose entries
// will execute at `executable` (the same address, or a second view of
// the same memory).
private void fillChunk(
    ubyte* writable, const(ubyte)* executable, Slot* slots,
) {
    import core.stdc.string: memcpy;

    memcpy(writable, templateBase, chunkBytes);
    auto trailer = cast(CallbackTrailer*) (writable + trailerOffset);
    trailer.commonDelta = commonEntry - (executable + trailerOffset);
    trailer.slots = slots;
}


// An anonymous read-write mapping at `target` (anywhere when null), filled,
// then flipped to read-execute. Returns null, with the mapping released,
// when the kernel refuses the flip - the one failure `allocateChunk` can
// fall back from.
private const(ubyte)* copyThenProtect(
    in size_t bytes, Slot* slots, ubyte* target,
) {
    const size = roundUpToPage(bytes);
    auto mapping = cast(ubyte*) mmap(
        target, size, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON | (target is null ? 0 : MAP_FIXED), -1, 0);
    if (mapping == cast(ubyte*) MAP_FAILED)
        throw new Exception(
            "ffi callback pool: " ~ errnoText("mmap of a new chunk"),
        );

    fillChunk(mapping, mapping, slots);

    if (mprotect(mapping, size, PROT_READ | PROT_EXEC) != 0) {
        discardMapping(mapping, size, target !is null);
        return null;
    }

    return mapping;
}


// One anonymous memory file, mapped twice: a read-write view to fill, and
// a read-execute view to keep. The write view is unmapped once filled, so
// nothing stays writable and executable at the same time. The read-execute
// view goes to `target` (anywhere when null).
private const(ubyte)* copyDualMapped(
    in size_t bytes, Slot* slots, ubyte* target,
) {
    import core.sys.posix.unistd: close, ftruncate;

    const size = roundUpToPage(bytes);
    const file = memfd_create("snakebite-callbacks", MFD_CLOEXEC);
    if (file < 0)
        throw new Exception(
            "ffi callback pool: " ~ errnoText("memfd_create"),
        );
    scope(exit) close(file);

    if (ftruncate(file, size) != 0)
        throw new Exception(
            "ffi callback pool: " ~ errnoText("ftruncate of the memory file"),
        );

    auto executable = cast(ubyte*) mmap(
        target, size, PROT_READ | PROT_EXEC,
        MAP_SHARED | (target is null ? 0 : MAP_FIXED), file, 0);
    if (executable == cast(ubyte*) MAP_FAILED)
        throw new Exception(
            "ffi callback pool: "
                ~ errnoText("read-execute mapping of the memory file"),
        );

    auto writable = cast(ubyte*) mmap(
        null, size, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
    if (writable == cast(ubyte*) MAP_FAILED) {
        discardMapping(executable, size, target !is null);
        throw new Exception(
            "ffi callback pool: "
                ~ errnoText("read-write mapping of the memory file"),
        );
    }

    fillChunk(writable, executable, slots);
    munmap(writable, size);

    return executable;
}


// Linux's value; druntime does not declare it.
private enum MAP_NORESERVE = 0x4000;


private extern(C) int memfd_create(const(char)* name, uint flags) @nogc nothrow;
private enum MFD_CLOEXEC = 1;


private size_t roundUpToPage(in size_t bytes) {
    import core.memory: pageSize;

    return (bytes + pageSize - 1) / pageSize * pageSize;
}


private string errnoText(string what) {
    import core.stdc.errno: errno;
    import core.stdc.string: strerror;
    import std.conv: text;
    import std.string: fromStringz;

    return text(what, " failed: ", strerror(errno).fromStringz);
}


// Called by `snakebite_ffi_callback_common` for every callback: `entry`
// is the entry the host called, `trailer` its chunk's trailer, and
// `frame` the spilled argument registers plus where the host's stack
// arguments start. A chunk names its own slot table in its trailer. Nothing
// here takes a lock: the slot was fully written before its entry was ever
// handed out.
public extern(C) void snakebite_ffi_callback_handler(
    const(void)* entry,
    const(CallbackTrailer)* trailer,
    CallFrame* frame,
) {
    auto slots = cast(Slot*) trailer.slots;
    const base = cast(const(ubyte)*) trailer
        - callbackEntriesPerChunk * callbackEntryBytes;
    const index = (cast(const(ubyte)*) entry - base) / callbackEntryBytes;
    invoke(slots[index], frame);
}


private void invoke(ref Slot slot, CallFrame* frame) {
    const plan = slot.plan;

    const scratchBytes = plan.callbackScratchBytes;
    align(16) ubyte[256] inlineScratch = void;
    // `new void[]`, not `new ubyte[]`: druntime marks a `ubyte[]` block
    // NO_SCAN, but the return place a guest callback writes through
    // (`callbackReturnPlace`, below) can land here, and a class, slice
    // or delegate the callback returns must stay visible to the
    // collector (ADR-0005).
    auto scratch = scratchBytes <= inlineScratch.length
        ? inlineScratch.ptr : (cast(ubyte[]) new void[scratchBytes]).ptr;

    const count = plan.callbackArgumentCount;
    void*[16] inlineAddresses = void;
    auto addresses = count <= inlineAddresses.length
        ? inlineAddresses[0 .. count] : new void*[count];
    plan.unpackArguments(frame, scratch, addresses);

    const typesIndex = plan.callbackVariadicTypesIndex;
    const(void)* variadicTypes;
    void*[] guestAddresses = addresses;
    if (typesIndex != size_t.max) {
        import snakebite.ffi.argumentplan: callbackVariadicTypes;

        variadicTypes = callbackVariadicTypes(addresses[typesIndex]);
        guestAddresses = new void*[count - 1];
        foreach (i; 0 .. count)
            if (i != typesIndex)
                guestAddresses[i - (i > typesIndex)] = addresses[i];
    }

    // The context word lives at `addresses[0]`, in the same shape as any
    // other argument - the address of its own pointer-sized storage
    // (here, a slot in `scratch`). Adjusting it in place, rather than
    // copying it out to a separate field, keeps one argument list for
    // every caller below: the backend's own `runHostToGuest` and a
    // forwarded native call both read `addresses`/`call.arguments`
    // exactly as they read a declared parameter.
    if (plan.hasHiddenContext) {
        auto contextSlot = cast(void**) addresses[0];
        *contextSlot = cast(ubyte*) *contextSlot + slot.contextAdjustment;
    }

    CallbackCall call;
    call.function_ = slot.function_;
    call.arguments = cast(const(void*)[]) guestAddresses;
    call.returnPlace = plan.callbackReturnPlace(frame, scratch);
    call.variadicCursor = plan.callbackVariadicCursor(frame, scratch);
    call.variadicTypes = variadicTypes;

    if (slot.nativeAddress is null)
        slot.handler(slot.owner, &call);
    else
        plan.callAt(slot.nativeAddress, call.returnPlace,
            cast(const(void*)[]) addresses);

    plan.packResult(frame, call.returnPlace);
}


// One backend instance's registry of guest function words, and the owner
// of their pool slots. A backend registers every word it stores for a
// guest function's address (`register`); a plan asks for the word's
// entry when that word is about to cross the barrier (`entryOf`), which
// reserves the slot on first use - keyed by guest function, so a
// delegate to a function and a pointer to it share one entry, and the
// delegate keeps its own context word because the host passes that
// word back on every call. Slots are not released one by one: host code
// may keep an entry for as long as it likes, and this bridge keeps its
// owner reachable for the same reason, until `release`.
//
// Any thread that runs guest code registers words and crosses the
// barrier with them (ADR-0006): a registered word is found without a
// lock, and only the first crossing of a word, which reserves its
// entry, takes this bridge's mutex (never the compiler lock).
//
// A struct, not a class (ai/CODING.md): no base, no children, no virtual
// methods. `CallPlanStore` owns one, and every plan prepared with it shares
// it by reference, so it is always reached through a heap-allocated
// `CallbackBridge*`, the same way a class reference would be shared.
public struct CallbackBridge {
    import snakebite.host.sharedtable: SharedTable;

    private struct Registered {
        NativeSignature signature;
        const(void)* entry;
    }

    private struct Adjusted {
        const(void)* word;
        ptrdiff_t offset;
    }

    private SharedTable!(const(void)*, Registered) _words;
    private shared(size_t) _firstWord = size_t.max;
    private shared(size_t) _lastWord;
    // Read without a lock the same way as `_words` (ADR-0006); an
    // adjusted entry is reserved once, under this bridge's mutex, the
    // same as an unadjusted one.
    private SharedTable!(Adjusted, const(void)*) _adjustedEntries;
    private SharedTable!(const(void)*, const(void)*) _wordOfEntry;
    private SharedTable!(const(void)*, Adjusted) _adjustedGuestEntries;
    // The signature that made an adjusted entry that forwards to host code.
    // The host code and the adjustment are in the slot of the entry. A
    // backend that saves its program asks for them (`adjustedHostTarget`).
    private SharedTable!(const(void)*, NativeSignature) _adjustedHostSignatures;
    private CallbackHandler _handler;
    private void* _owner;
    private void function(void*, const(void)*) _prepare;
    // Guards the tables above against concurrent writers: the first
    // crossing of a word, an adjusted entry and `release`. Readers never
    // take it. Lock order, outermost first: the compiler lock (a caller
    // may hold it when it calls the bridge; nothing here takes it, and
    // nothing here reads the AST), this mutex, then the pool's mutex
    // (`reserve`, `releaseChunks`) and the tables' own insert locks, which
    // are leaves.
    private Mutex _mutex;
    // This bridge's chunks of entries, free list and lock (ADR-0003).
    private Pool _pool;

    public this(
        CallbackHandler handler,
        void* owner,
        void function(void*, const(void)*) prepare = null,
    ) {
        if (handler is null)
            throw new Exception("ffi callback bridge has no handler");

        _handler = handler;
        _owner = owner;
        _prepare = prepare;
        _mutex = new Mutex;
        _pool.mutex = new Mutex;
    }

    public void register(const(void)* word, NativeSignature signature) {
        if (word is null || word in _words)
            return;
        includeWord(cast(size_t) word);
        _words.insert(word, Registered(signature, null));
    }

    // Publish a wider range before publishing its new word. Concurrent
    // registrations can only widen it, so a reader never excludes a word
    // whose registration it can already observe.
    private void includeWord(in size_t word) @safe @nogc nothrow {
        import core.atomic: atomicLoad, cas, MemoryOrder;

        auto first = atomicLoad!(MemoryOrder.acq)(_firstWord);
        while (word < first) {
            if (cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(
                    &_firstWord, first, word))
                break;
            first = atomicLoad!(MemoryOrder.acq)(_firstWord);
        }
        auto last = atomicLoad!(MemoryOrder.acq)(_lastWord);
        while (word > last) {
            if (cas!(MemoryOrder.acq_rel, MemoryOrder.acq)(
                    &_lastWord, last, word))
                break;
            last = atomicLoad!(MemoryOrder.acq)(_lastWord);
        }
    }

    // The pool entry for `word`, reserved on first use, or null when
    // `word` is not a guest function this backend registered - a host
    // address, or already an entry - and so crosses the barrier as it is.
    public const(void)* entryOf(const(void)* word) {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;

        // Most pointer arguments are data, not functions. Do not pay for
        // address-dependent hash collisions when the word cannot be present.
        const address = cast(size_t) word;
        if (address < atomicLoad!(MemoryOrder.acq)(_firstWord)
                || address > atomicLoad!(MemoryOrder.acq)(_lastWord))
            return null;

        auto registered = word in _words;
        if (registered is null)
            return null;

        if (auto entry = atomicLoad!(MemoryOrder.acq)(registered.entry))
            return entry;

        if (_prepare !is null)
            _prepare(_owner, word);

        {
            _mutex.lock;
            scope(exit) _mutex.unlock;

            if (registered.entry is null) {
                auto plan = new CallPlan;
                *plan = prepareCallback(registered.signature);
                auto slot = Slot(
                    _handler, _owner, word, plan);
                const entry = _pool.reserve(slot);
                _wordOfEntry.insert(entry, word);
                atomicStore!(MemoryOrder.rel)(registered.entry, entry);
            }
        }

        // A plain read here would be racing the `atomicStore` above:
        // this thread's own write is visible to itself either way, but
        // another thread's `entryOf` call for the same word, arriving
        // just after the bridge's mutex was released, needs the
        // acquire load to be certain it sees the stored entry and not
        // a stale `null` (finding 8).
        return atomicLoad!(MemoryOrder.acq)(registered.entry);
    }

    // Gives back every chunk of this bridge, and with them the reference to
    // the owner that the pool slots held. The caller promises that no host
    // code can call an entry again, and does not use the bridge again.
    public void release() {
        _mutex.lock;
        scope(exit) _mutex.unlock;

        _pool.releaseChunks;
    }

    // Whether host code can hold an entry of this bridge: it reserved one and
    // did not give it back.
    public bool hasEntries() {
        _pool.mutex.lock;
        scope(exit) _pool.mutex.unlock;

        return _pool.chunks.length != 0;
    }

    // How many chunks this bridge has.
    version(unittest)
    public size_t chunkCount() {
        _pool.mutex.lock;
        scope(exit) _pool.mutex.unlock;

        return _pool.chunks.length;
    }

    // Starts a fresh chunk made with `strategy`, so the entries reserved
    // after this come from it: the way a test drives the dual-mapping
    // fallback on a kernel that never refuses `mprotect`.
    version(unittest)
    public void beginChunk(ChunkStrategy strategy) {
        _pool.mutex.lock;
        scope(exit) _pool.mutex.unlock;

        _pool.chunks ~= _pool.allocateChunk(strategy, false);
    }

    // The guest word behind one of this bridge's own entries, or null.
    public const(void)* wordOf(const(void)* entry) const {
        auto word = entry in _wordOfEntry;
        return word is null ? null : *word;
    }

    public bool contains(const(void)* word) const {
        return _words.contains(word);
    }

    // The signature that `word` was registered with, or null.
    public const(NativeSignature)* signatureOf(const(void)* word) const {
        const registered = word in _words;
        return registered is null ? null : &registered.signature;
    }

    public struct GuestTarget {
        const(void)* word;
        ptrdiff_t adjustment;
    }

    // Adjusted entries must retain their receiver offset when a backend
    // resolves them to guest calls. Stripping only the entry loses it.
    public GuestTarget guestTarget(const(void)* address) const {
        import core.atomic: atomicLoad, MemoryOrder;

        // An address in this bridge's range is one of its entries or none,
        // and the table says which. It is read without a lock: `word` is
        // stored last, with release.
        if (const guest = _pool.guestEntryOf(address)) {
            const word = atomicLoad!(MemoryOrder.acq)(guest.word);
            return word !is null
                ? GuestTarget(word, guest.adjustment) : GuestTarget.init;
        }

        if (auto adjusted = address in _adjustedGuestEntries)
            return GuestTarget(adjusted.word, adjusted.offset);
        if (const word = wordOf(address))
            return GuestTarget(word, 0);
        return contains(address) ? GuestTarget(address, 0) : GuestTarget.init;
    }

    // Whether `entry` is an entry that `adjustedEntryOf` made for host code.
    public bool isAdjustedHostEntry(const(void)* entry) const {
        return (entry in _adjustedHostSignatures) !is null;
    }

    // Whether `entry` is an entry that `adjustedEntryOf` made for host code,
    // and if so the host code, the adjustment and the signature it was made
    // with.
    public bool adjustedHostTarget(
        const(void)* entry, out const(void)* word, out ptrdiff_t adjustment,
        out const(NativeSignature)* signature,
    ) const {
        signature = entry in _adjustedHostSignatures;
        if (signature is null)
            return false;
        const slot = _pool.slotOf(entry);
        word = slot.nativeAddress;
        adjustment = slot.contextAdjustment;
        return true;
    }

    // The entry `adjustedEntryOf` already reserved for `word` with a nonzero
    // `adjustment`, or null. No lock: a caller that has to read the AST to
    // build the signature asks this first and builds it only on a miss.
    public const(void)* reservedAdjustedEntry(
        const(void)* word, in ptrdiff_t adjustment,
    ) {
        if (auto entry = Adjusted(word, adjustment) in _adjustedEntries)
            return *entry;
        return null;
    }

    // A native ABI thunk owns the receiver adjustment. Callers keep the
    // original interface pointer, including when they store a delegate.
    // `signature` is not read for a zero `adjustment` or an entry that
    // exists. The bridge never reads the AST: the caller builds `signature`
    // before the call, under the compiler lock if it needs one.
    public const(void)* adjustedEntryOf(
        const(void)* word, in NativeSignature signature,
        in ptrdiff_t adjustment,
    ) {
        if (adjustment == 0) {
            const entry = entryOf(word);
            return entry is null ? word : entry;
        }
        const key = Adjusted(word, adjustment);
        if (auto entry = key in _adjustedEntries)
            return *entry;

        _mutex.lock;
        scope(exit) _mutex.unlock;

        if (auto found = key in _adjustedEntries)
            return *found;
        auto plan = new CallPlan;
        *plan = prepareCallback(signature);
        assert(plan.hasHiddenContext);
        auto slot = Slot(
            _handler, _owner, word, plan, adjustment,
            contains(word) ? null : word,
        );
        const reserved = _pool.reserve(slot);
        if (contains(word)) {
            _adjustedGuestEntries.insert(reserved, key);
        } else {
            _adjustedHostSignatures.insert(reserved, cast() signature);
        }
        return *_adjustedEntries.insert(key, reserved);
    }
}
