module snakebite.host.buildid;


private:


// The GNU build ID of the running executable, or empty when the linker wrote
// none. Two processes that run the same executable have the same ID.
public immutable(ubyte)[] ownBuildId() {
    import core.sys.linux.link: dl_iterate_phdr;

    immutable(ubyte)[] id;
    dl_iterate_phdr(&visit, &id);
    return id;
}


// Stops after the first object, which is the executable.
private extern(C) int visit(
    imported!"core.sys.linux.link".dl_phdr_info* object,
    size_t size,
    void* result,
) nothrow {
    import core.sys.linux.elf: Elf64_Nhdr, NT_GNU_BUILD_ID;

    enum noteType = 4; // PT_NOTE
    enum noteAlignment = 4;
    static size_t padded(in size_t length) {
        return (length + noteAlignment - 1) & ~(noteAlignment - 1);
    }

    auto id = cast(immutable(ubyte)[]*) result;
    foreach (header; object.dlpi_phdr[0 .. object.dlpi_phnum]) {
        if (header.p_type != noteType)
            continue;
        auto notes = (cast(const(ubyte)*) (object.dlpi_addr + header.p_vaddr))
            [0 .. header.p_memsz];
        while (notes.length >= Elf64_Nhdr.sizeof) {
            const note = *cast(const(Elf64_Nhdr)*) notes.ptr;
            const nameEnd = Elf64_Nhdr.sizeof + padded(note.n_namesz);
            const end = nameEnd + padded(note.n_descsz);
            if (end > notes.length)
                break;
            const name = cast(const(char)[])
                notes[Elf64_Nhdr.sizeof .. Elf64_Nhdr.sizeof + note.n_namesz];
            if (note.n_type == NT_GNU_BUILD_ID && name == "GNU\0") {
                *id = notes[nameEnd .. nameEnd + note.n_descsz].idup;
                return 1;
            }
            notes = notes[end .. $];
        }
    }
    return 1;
}
