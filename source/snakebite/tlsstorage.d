module snakebite.tlsstorage;


private:


// A thread-local guest variable's compile-time-constant description
// (issue #40, ADR-0006, finding 1.3): the identity `TlsSlots.slotFor`
// keys this thread's own copy by, and the bytes every thread's copy
// starts from. Built once, under the compiler lock, by
// `snakebite.nativelayout.NativeData.tlsDescriptorOf`; read here with no
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
    public const(void)* key;
    public const(void)* templateBytes;
    public size_t size;
    // Set when the variable's storage is native (a dependency image's
    // own thread-local, or an `extern` one): the linker name that
    // `nativeAddress` resolves, on each thread, to that thread's copy in
    // the image's TLS block. No copy is made from a template then, so
    // native code and guest code on one thread reach the same bytes.
    public string nativeName;
    public void* delegate(in char[] name) nativeAddress;
}


// One thread's own copies of the thread-local guest variables it has
// touched, grown on demand. A `TlsSlots` belongs to exactly one thread -
// Fibers on that thread share it (ADR-0006), so `slotFor` takes no lock:
// nothing here is ever visible to another thread.
public struct TlsSlots {
    private void[][const(void)*] _slots;

    public void[] slotFor(const(TlsDescriptor)* descriptor) {
        if (auto found = descriptor.key in _slots)
            return *found;

        void[] bytes;
        if (descriptor.nativeName.length) {
            // Resolved on this thread: a thread-local symbol's address
            // is the calling thread's own, so another thread's answer
            // would be that thread's copy.
            auto address = descriptor.nativeAddress(descriptor.nativeName);
            assert(address !is null, descriptor.nativeName);
            bytes = address[0 .. descriptor.size];
        } else {
            import core.stdc.string: memcpy;

            bytes = new void[descriptor.size];
            memcpy(bytes.ptr, descriptor.templateBytes, descriptor.size);
        }
        _slots[descriptor.key] = bytes;
        return bytes;
    }
}
