module snakebite.ffi.callback;


private:


import core.sync.mutex: Mutex;
import snakebite.ffi.plan: CallPlan, prepareCallback;
import snakebite.ffi.sysv:
    CallbackTrailer, CallFrame, callbackEntriesPerChunk, callbackEntryBytes,
    snakebite_ffi_callback_chunk, snakebite_ffi_callback_chunk_end,
    snakebite_ffi_callback_chunk_trailer, snakebite_ffi_callback_common;

// `imported!"dmd.func"` is a module-scope-only construct (ai/CODING.md);
// this names the one type this module reads from it, so every struct
// and class below reads it as a plain type instead.
private alias FuncDeclaration = imported!"dmd.func".FuncDeclaration;


// The pool of callback entries (ADR-0003): the addresses host code calls
// when it calls a guest function through a function pointer or a
// delegate. Every entry is a copy of the same position-independent
// template in `sysv_amd64.S`; `snakebite_ffi_callback_common` spills the
// argument registers and calls `snakebite_ffi_callback_handler` below,
// which finds the entry's slot and replays the slot's plan in reverse to
// re-enter the backend that owns the slot.
//
// The first chunk of entries is the template itself, linked into the
// binary. When every slot in every chunk is taken, the pool copies the
// template's bytes into a new mapping and flips that mapping to
// read-execute (`allocateChunk`). Memory is never writable and
// executable at the same time. A slot is never released.


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
    public FuncDeclaration declaration;
    public void* returnPlace;
    public const(void*)[] arguments;
}


public alias CallbackHandler = extern(C) void function(void*, CallbackCall*);


// What one entry re-enters: the backend (`handler`, `owner`), the guest
// function in that backend's own representation (`function_`), and the
// plan its arguments are unpacked with.
private struct Slot {
    CallbackHandler handler;
    void* owner;
    const(void)* function_;
    FuncDeclaration declaration;
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


private __gshared Slot[callbackEntriesPerChunk] templateSlots;
private __gshared Chunk[] chunks;
private __gshared Mutex mutex;


shared static this() {
    import std.conv: text;

    mutex = new Mutex;

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

    chunks = [Chunk(templateBase, templateSlots[], 0)];
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
// chunk if every existing one is full. Never released.
private const(void)* reserve(Slot slot) {
    mutex.lock;
    scope(exit) mutex.unlock;

    if (chunks[$ - 1].used == callbackEntriesPerChunk)
        chunks ~= allocateChunk(ChunkStrategy.protect, true);

    auto chunk = &chunks[$ - 1];
    const index = chunk.used++;
    chunk.slots[index] = slot;
    return chunk.base + index * callbackEntryBytes;
}


// How many chunks the pool has, the template included.
version(unittest)
public size_t callbackChunkCount() {
    mutex.lock;
    scope(exit) mutex.unlock;

    return chunks.length;
}


// Starts a fresh chunk made with `strategy`, so the entries reserved
// after this come from it: the way a test drives the dual-mapping
// fallback on a kernel that never refuses `mprotect`.
version(unittest)
public void beginCallbackChunk(ChunkStrategy strategy) {
    mutex.lock;
    scope(exit) mutex.unlock;

    chunks ~= allocateChunk(strategy, false);
}


// A new chunk: the template's bytes, in memory this process can execute,
// with the trailer patched to reach `snakebite_ffi_callback_common` from
// the copy's own address and to name the copy's own slot table.
// `fallback` says whether a refused `protect` may fall through to
// `dualMapping`.
private Chunk allocateChunk(in ChunkStrategy strategy, in bool fallback) {
    auto slots = new Slot[callbackEntriesPerChunk];
    const bytes = templateEnd - templateBase;

    const(ubyte)* base;
    final switch (strategy) with (ChunkStrategy) {
        case protect:
            base = copyThenProtect(bytes, slots.ptr);
            if (base is null) {
                if (!fallback)
                    throw new Exception(
                        "ffi callback pool: mprotect refused to make the " ~
                            "chunk executable, and no fallback was allowed",
                    );
                base = copyDualMapped(bytes, slots.ptr);
            }
            break;

        case dualMapping:
            base = copyDualMapped(bytes, slots.ptr);
            break;
    }

    return Chunk(base, slots, 0);
}


// Fills `writable` with the template, patched for a copy whose entries
// will execute at `executable` (the same address, or a second view of
// the same memory).
private void fillChunk(
    ubyte* writable, const(ubyte)* executable, Slot* slots,
) {
    import core.stdc.string: memcpy;

    memcpy(writable, templateBase, templateEnd - templateBase);
    auto trailer = cast(CallbackTrailer*) (writable + trailerOffset);
    trailer.commonDelta = commonEntry - (executable + trailerOffset);
    trailer.slots = slots;
}


// An anonymous read-write mapping, filled, then flipped to read-execute.
// Returns null, with the mapping released, when the kernel refuses the
// flip - the one failure `allocateChunk` can fall back from.
private const(ubyte)* copyThenProtect(in size_t bytes, Slot* slots) {
    import core.sys.posix.sys.mman:
        MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_EXEC, PROT_READ, PROT_WRITE,
        mmap, mprotect, munmap;

    const size = roundUpToPage(bytes);
    auto mapping = cast(ubyte*) mmap(
        null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapping == cast(ubyte*) MAP_FAILED)
        throw new Exception(
            "ffi callback pool: " ~ errnoText("mmap of a new chunk"),
        );

    fillChunk(mapping, mapping, slots);

    if (mprotect(mapping, size, PROT_READ | PROT_EXEC) != 0) {
        munmap(mapping, size);
        return null;
    }

    return mapping;
}


// One anonymous memory file, mapped twice: a read-write view to fill, and
// a read-execute view to keep. The write view is unmapped once filled, so
// nothing stays writable and executable at the same time.
private const(ubyte)* copyDualMapped(in size_t bytes, Slot* slots) {
    import core.sys.posix.sys.mman:
        MAP_FAILED, MAP_SHARED, PROT_EXEC, PROT_READ, PROT_WRITE, mmap,
        munmap;
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
        null, size, PROT_READ | PROT_EXEC, MAP_SHARED, file, 0);
    if (executable == cast(ubyte*) MAP_FAILED)
        throw new Exception(
            "ffi callback pool: "
                ~ errnoText("read-execute mapping of the memory file"),
        );

    auto writable = cast(ubyte*) mmap(
        null, size, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
    if (writable == cast(ubyte*) MAP_FAILED) {
        munmap(executable, size);
        throw new Exception(
            "ffi callback pool: "
                ~ errnoText("read-write mapping of the memory file"),
        );
    }

    fillChunk(writable, executable, slots);
    munmap(writable, size);

    return executable;
}


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
// arguments start. A copied chunk names its own slot table in its
// trailer; the template chunk's table is static. Nothing here takes a
// lock: the slot was fully written before its entry was ever handed out.
public extern(C) void snakebite_ffi_callback_handler(
    const(void)* entry,
    const(CallbackTrailer)* trailer,
    CallFrame* frame,
) {
    auto slots = trailer.slots is null
        ? templateSlots.ptr : cast(Slot*) trailer.slots;
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
    call.declaration = slot.declaration;
    call.arguments = cast(const(void*)[]) addresses;
    call.returnPlace = plan.callbackReturnPlace(frame, scratch);

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
// word back on every call. Slots are never released: host code may keep
// an entry for as long as it likes, and this bridge keeps its owner
// reachable for the same reason.
//
// Not thread-safe on its own: registration and first use both happen on
// the thread that runs this backend instance. ADR-0006 moves per-thread
// state out of the backend; the pool's own reservation already takes a
// lock.
//
// A struct, not a class (ai/CODING.md): no base, no children, no virtual
// methods. `PlanCache` and every plan it prepares share one instance by
// reference, so it is always reached through a heap-allocated
// `CallbackBridge*`, the same way a class reference would be shared.
public struct CallbackBridge {
    private struct Registered {
        FuncDeclaration declaration;
        const(void)* entry;
    }

    private Registered[const(void)*] _words;
    private struct Adjusted {
        const(void)* word;
        ptrdiff_t offset;
    }
    private const(void)*[Adjusted] _adjustedEntries;
    private const(void)*[const(void)*] _wordOfEntry;
    private CallbackHandler _handler;
    private void* _owner;

    public this(CallbackHandler handler, void* owner) {
        if (handler is null)
            throw new Exception("ffi callback bridge has no handler");

        _handler = handler;
        _owner = owner;
    }

    public void register(
        const(void)* word,
        FuncDeclaration declaration,
    ) {
        if (word is null || word in _words)
            return;
        _words[word] = Registered(declaration, null);
    }

    // The pool entry for `word`, reserved on first use, or null when
    // `word` is not a guest function this backend registered - a host
    // address, or already an entry - and so crosses the barrier as it is.
    public const(void)* entryOf(const(void)* word) {
        auto registered = word in _words;
        if (registered is null)
            return null;

        if (registered.entry is null) {
            auto plan = new CallPlan;
            *plan = prepareCallback(registered.declaration);
            registered.entry = reserve(Slot(
                _handler, _owner, word, registered.declaration, plan));
            _wordOfEntry[registered.entry] = word;
        }

        return registered.entry;
    }

    // The guest word behind one of this bridge's own entries, or null.
    public const(void)* wordOf(const(void)* entry) const {
        auto word = entry in _wordOfEntry;
        return word is null ? null : *word;
    }

    public bool contains(const(void)* word) const {
        return (word in _words) !is null;
    }

    // A native ABI thunk owns the receiver adjustment. Callers keep the
    // original interface pointer, including when they store a delegate.
    public const(void)* adjustedEntryOf(
        const(void)* word, FuncDeclaration declaration,
        in ptrdiff_t adjustment,
    ) {
        if (adjustment == 0) {
            const entry = entryOf(word);
            return entry is null ? word : entry;
        }
        const key = Adjusted(word, adjustment);
        if (auto entry = key in _adjustedEntries)
            return *entry;
        auto plan = new CallPlan;
        *plan = prepareCallback(declaration);
        assert(plan.hasHiddenContext);
        const entry = reserve(Slot(
            _handler, _owner, word, declaration, plan, adjustment,
            contains(word) ? null : word,
        ));
        _adjustedEntries[key] = entry;
        return entry;
    }
}
