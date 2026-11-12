module snakebite.native.staticstore;


private:


import snakebite.backends.bytecode.relocation: DatumRef, Place, Reloc, Target;
import snakebite.host.threads: PerThread;
import snakebite.native.value: TypeFacts;
import snakebite.stack.tls: TlsSlots;


// The bytes of a datum and the datum they belong to. It converts to the bytes.
public struct Placed {
    public void[] bytes;
    public DatumRef where;
    alias bytes this;
}


// The blocks that hold static data, and the free space in them. A block
// never moves: slots can hold addresses of other slots. The blocks are in
// the GC heap, so that the GC scans what the data point to, and live as
// long as this does.
public struct StaticBlocks {
    // A copy would share the free space with the original.
    @disable this(this);

    // What the blocks hold, one record for each datum in the order of
    // `reserve`: where it is and whether its type can hold an address.
    // The blocks describe their own content, as a data section does.
    public struct Datum {
        public size_t block;
        public size_t offset;
        public size_t size;
        public uint alignment;
        public bool canHoldAddress;
        // The words of the datum that hold an address, when the compiler
        // records them (`recordAddress`). The offset of a word is the `index`
        // of its place.
        public Link[] links;
    }

    // What a word of a datum points at. The word in the bytes of the datum
    // holds the address; this names the thing, so that a file can hold it.
    // For `staticData` the target is the offset `offset` in block `block` of
    // the blocks `set`, with `set` null when no known blocks hold the datum
    // that the address was computed from. An offset can be the end of the
    // datum. For any other kind it is `address`.
    public struct Link {
        public Place place;
        public Target.Kind kind;
        public const(StaticBlocks)* set;
        public size_t block;
        public size_t offset;
        public size_t address;
    }

    // Written under the compiler lock only, like every miss that fills
    // them.
    private void[][] _blocks;
    private void[] _available;
    private Datum[] _data;

    public const(Datum)[] data() const @safe pure nothrow @nogc {
        return _data;
    }

    // The bytes of the datum `datum`.
    public inout(void)[] bytesOf(in Datum datum) inout @trusted pure nothrow {
        return _blocks[datum.block][datum.offset .. datum.offset + datum.size];
    }

    // Where an address of this process lies in the blocks, or false. Only the
    // places of words use it: any other datum is named by its `DatumRef`.
    private bool locate(
        in void* address, out size_t block, out size_t offset,
    ) const @trusted pure nothrow @nogc {
        foreach (index, candidate; _blocks) {
            const distance = cast(size_t) address - cast(size_t) candidate.ptr;
            if (distance < candidate.length) {
                block = index;
                offset = distance;
                return true;
            }
        }
        return false;
    }

    // The address `offset` bytes into block `block`, or null.
    public void* addressOf(in size_t block, in size_t offset)
            @trusted pure nothrow @nogc {
        if (block >= _blocks.length || offset > _blocks[block].length)
            return null;
        return _blocks[block].ptr + offset;
    }

    // Records that the word at `place` holds `target`. False when `place` is
    // in no datum.
    public bool recordAddress(in void* place, Link link)
            @trusted pure nothrow {
        const found = datumAt(place);
        if (found.index == size_t.max)
            return false;
        link.place =
            Place(Place.Section.datum, Place.Field.word, found.offset);
        _data[found.index].links ~= link;
        return true;
    }

    // The records of the words in the `length` bytes from `start`, as places
    // relative to `start`.
    public Link[] linksIn(in void* start, in size_t length)
            const @trusted pure nothrow {
        Link[] found;
        const owner = datumAt(start);
        if (owner.index == size_t.max)
            return found;
        foreach (recorded; _data[owner.index].links) {
            Link link = recorded;
            const offset = link.place.index;
            if (offset >= owner.offset && offset - owner.offset < length) {
                link.place.index = offset - owner.offset;
                found ~= link;
            }
        }
        return found;
    }

    // The datum that holds the byte at `address`: where it is, the address of
    // its start, and the distance of `address` from the start.
    public bool locateDatum(
        in void* address, out DatumRef datum, out const(void)* start,
        out size_t distance,
    ) const @trusted pure nothrow @nogc {
        const found = datumAt(address);
        if (found.index == size_t.max)
            return false;
        const record = _data[found.index];
        datum = DatumRef(&this, record.block, record.offset);
        start = _blocks[record.block].ptr + record.offset;
        distance = found.offset;
        return true;
    }

    // The datum that holds the byte at `address` and the offset of the byte
    // in the datum. The data are in the order of their addresses in a block.
    private auto datumAt(in void* address) const @trusted pure nothrow @nogc {
        static struct Found {
            size_t index = size_t.max;
            size_t offset;
        }

        size_t block, offset;
        if (!locate(address, block, offset))
            return Found();
        size_t low, high = _data.length;
        while (low < high) {
            const middle = (low + high) / 2;
            const datum = _data[middle];
            if (datum.block < block
                    || (datum.block == block && datum.offset <= offset))
                low = middle + 1;
            else
                high = middle;
        }
        if (low == 0)
            return Found();
        const datum = _data[low - 1];
        if (datum.block != block || offset >= datum.offset + datum.size)
            return Found();
        return Found(low - 1, offset - datum.offset);
    }

    // Whether nothing has reserved a byte.
    public bool isEmpty() const @safe pure nothrow @nogc {
        return _blocks.length == 0;
    }

    // The caller holds the compiler lock.
    public Placed reserve(in TypeFacts facts) @trusted pure nothrow {
        // Slots cannot move: constants can hold addresses of other slots.
        const needed = facts.size + facts.alignment - 1;
        if (_available.length < needed) {
            import core.memory: GC;
            import std.algorithm: max;

            // Not `new void[]`: the GC takes that for an appendable array,
            // and `assumeSafeAppend` on a datum would let an append grow it
            // over its neighbours.
            const size = max(4096, needed);
            _available = GC.calloc(size, 0)[0 .. size];
            _blocks ~= _available;
        }
        const start = -cast(size_t) _available.ptr & (facts.alignment - 1);
        auto bytes = _available[start .. start + facts.size];
        _data ~= Datum(_blocks.length - 1,
            _blocks[$ - 1].length - _available.length + start, facts.size,
            facts.alignment, facts.canHoldAddress);
        _available = _available[start + facts.size .. $];
        return Placed(bytes, DatumRef(&this, _data[$ - 1].block,
            _data[$ - 1].offset));
    }
}


// The storage that holds the static data and constants of a program while
// it runs. It holds no frontend type: what fills it is in `NativeData`.
public struct StaticStore {
    // Holds a `PerThread`: a copy would share storage with the original.
    @disable this(this);

    // The blocks of the data that no D module owns, or all of the data when
    // the owner of this gives no other blocks.
    private StaticBlocks _blocks;
    // The copies are outside the GC heap, as read-only data is in compiled
    // D, and are freed with this object.
    private ubyte[][] _strings;
    // This thread's own copies of the thread-local variables, never shared,
    // so `TlsSlots.slotFor` takes no lock.
    private PerThread!(TlsSlots*) _tls;

    // `newTlsSlots` makes the table of thread-local variables that a thread
    // gets on its first use of the store.
    public this(TlsSlots* delegate() newTlsSlots) {
        _tls = PerThread!(TlsSlots*)(newTlsSlots);
    }

    ~this() {
        import core.stdc.stdlib: free;

        foreach (string_; _strings)
            free(string_.ptr);
    }

    // The blocks of the data that no D module owns.
    public inout(StaticBlocks)* blocks() inout @trusted pure nothrow @nogc {
        return &_blocks;
    }

    // The copies of string literals, in the order of `newString`.
    public const(ubyte[])[] strings() const @safe pure nothrow @nogc {
        return _strings;
    }

    // Whether nothing has reserved a byte or made a string.
    public bool isEmpty() const @safe pure nothrow @nogc {
        return _blocks.isEmpty && _strings.length == 0;
    }

    // The index of the string that holds `address` and the offset of the
    // byte in it, or false.
    public bool locateString(
        in void* address, out size_t index, out size_t offset,
    ) const @trusted pure nothrow @nogc {
        foreach (candidate, string_; _strings) {
            const distance = cast(size_t) address - cast(size_t) string_.ptr;
            if (distance < string_.length) {
                index = candidate;
                offset = distance;
                return true;
            }
        }
        return false;
    }

    // The address `offset` bytes into string `index`, or null.
    public void* addressInString(in size_t index, in size_t offset)
            @trusted pure nothrow @nogc {
        if (index >= _strings.length || offset > _strings[index].length)
            return null;
        return _strings[index].ptr + offset;
    }

    // The caller holds the compiler lock.
    public Placed reserve(in TypeFacts facts) @safe pure nothrow {
        return _blocks.reserve(facts);
    }

    // A zeroed block of `size` bytes outside the GC heap that this owns and
    // frees. The caller holds the compiler lock.
    public ubyte[] newString(in size_t size) {
        import core.stdc.stdlib: calloc;

        auto block = cast(ubyte*) calloc(size, 1);
        assert(block !is null);
        _strings ~= block[0 .. size];
        return _strings[$ - 1];
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
}
