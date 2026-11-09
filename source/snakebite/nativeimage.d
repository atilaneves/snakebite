module snakebite.nativeimage;

private:

import snakebite.relocation: Reloc, Place, Target, recordRelocation;

// Compiler-known allocation bounds and typed pointer stores, not a memory scan.
public struct NativeImageData {
    public struct Block {
        public const(void)[] bytes;
        public size_t alignment;
    }

    public bool enabled;
    public Block[] blocks;
    public Reloc[] relocs;
    public size_t[size_t] targetBases;
    public struct Binding {
        public const(void)* address;
        public string symbol;
        public ptrdiff_t offset;
    }
    public Binding[] bindings;

    public void binding(in const(void)* address, in string symbol, in ptrdiff_t offset = 0) {
        if (enabled && address !is null)
            bindings ~= Binding(address, symbol, offset);
    }

    public void block(in void[] bytes, in size_t alignment) {
        if (enabled)
            blocks ~= Block(bytes, alignment);
    }

    public void pointer(in void* place, in const(void)* target,
        in const(void)* base = null) {
        if (enabled) {
            recordRelocation(relocs,
                Place(Place.Section.data, Place.Field.word, cast(size_t) place),
                Target(Target.Kind.staticData, cast(size_t) target));
            if (base !is null)
                targetBases[cast(size_t) place] = cast(size_t) base;
        }
    }

    // A copied pointer keeps its target, including aliases and interior offsets.
    // Only a complete allocation copy inherits allocation bounds and alignment.
    public void copied(in void[] source, void[] destination) {
        if (!enabled)
            return;
        foreach (allocation; blocks)
            if (allocation.bytes.ptr == source.ptr
                    && allocation.bytes.length == source.length) {
                block(destination, allocation.alignment);
                break;
            }
        foreach (reloc; relocs) {
            const offset = reloc.place.index - cast(size_t) source.ptr;
            if (offset < source.length) {
                recordRelocation(relocs,
                    Place(Place.Section.data, Place.Field.word,
                        cast(size_t) destination.ptr + offset), reloc.target);
                if (auto base = reloc.place.index in targetBases)
                    targetBases[cast(size_t) destination.ptr + offset] = *base;
            }
        }
    }
}
