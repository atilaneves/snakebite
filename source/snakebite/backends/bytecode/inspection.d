module snakebite.backends.bytecode.inspection;


// Views of a compiled `Function` for unit tests, which sit outside this
// package and cannot read its fields.
version (unittest):

private:


import snakebite.backends.bytecode.relocation: Place, Reloc, Target;
import snakebite.backends.bytecode.vm: Function, Instruction, Role, Roles, rolesOf;
import std.conv: text;

public const(Reloc)[] relocsOf(const(Function)* function_) {
    return function_.relocs;
}

public size_t instructionCount(const(Function)* function_) {
    return function_.instructions.length;
}

// Words of the instructions and constants that `isMapped` accepts as an
// address of this process, but that no `Reloc` names and no role of the
// handler excludes. The handler of each instruction is not scanned: every
// instruction has one.
public string[] unrecordedWords(
    const(Function)* function_, scope bool delegate(size_t) isMapped,
) {
    bool[Place] recorded;
    foreach (reloc; function_.relocs)
        recorded[reloc.place] = true;

    string[] found;
    void check(in Place place, in size_t word) {
        if (isMapped(word) && place !in recorded)
            found ~= text(place, " holds ", word);
    }

    foreach (index, instruction; function_.instructions) {
        Roles roles;
        const known = rolesOf(instruction.handler, roles);
        if (!known || roles.destination != Role.instruction)
            check(Place(Place.Section.instruction,
                Place.Field.destination, index), instruction.destination);
        if (!known || roles.source != Role.instruction)
            check(Place(Place.Section.instruction,
                Place.Field.source, index), instruction.source);
        if (!known || roles.sourceWidth != Role.instruction)
            check(Place(Place.Section.instruction,
                Place.Field.sourceWidth, index), instruction.sourceWidth);
        if (isMapped(instruction.width))
            found ~= text("instruction ", index, " has an address as width");
    }
    foreach (index, constant; function_.constants)
        check(Place(Place.Section.constant, Place.Field.word, index),
            cast(size_t) constant);
    static foreach (table; tableFields) {
        foreach (index; 0 .. tableLength(function_, table.section))
            foreach (field; table.fields) {
                const place = Place(table.section, field, index);
                size_t word;
                if (!isRunTimeCache(function_, place)
                        && wordAt(function_, place, word))
                    check(place, word);
            }
    }
    return found;
}

// A call site that has a delegate to prepare its callee or its plan keeps
// the result in `callee` or `nativePlan` when it first runs. The scan runs
// after the programs did, so the cache holds an address that the compiler
// never wrote.
private bool isRunTimeCache(const(Function)* function_, in Place place) {
    if (place.section != Place.Section.callSite)
        return false;
    const site = &function_.callSites[place.index];
    return (place.field == Place.Field.callee
            && site.prepareGuest.funcptr !is null)
        || (place.field == Place.Field.nativePlan
            && site.prepareNativePlan.funcptr !is null);
}

private struct TableFields {
    Place.Section section;
    Place.Field[] fields;
}

private enum tableFields = [
    TableFields(Place.Section.callSite, [
        Place.Field.callee, Place.Field.prepareGuest, Place.Field.nativePlan,
        Place.Field.prepareNativePlan, Place.Field.builtinEntry,
        Place.Field.valueSignature,
    ]),
    TableFields(Place.Section.assertSite, [
        Place.Field.message, Place.Field.file, Place.Field.halt,
    ]),
    TableFields(Place.Section.exceptionHandler, [Place.Field.type]),
];

private size_t tableLength(
    const(Function)* function_, in Place.Section section,
) {
    final switch (section) with (Place.Section) {
        case instruction: return function_.instructions.length;
        case constant: return function_.constants.length;
        case callSite: return function_.callSites.length;
        case assertSite: return function_.assertSites.length;
        case exceptionHandler: return function_.exceptionHandlers.length;
    }
}

// Whether the role table says that the handler's `field` holds an address
// (`Role.address`) or an instruction (`Role.instruction`); "none" when the
// table does not know the handler.
public string rolesOfHandler(const Instruction.Handler handler) {
    Roles roles;
    if (!rolesOf(handler, roles))
        return "none";
    return text(roles.destination, "/", roles.source, "/", roles.sourceWidth);
}

// The handlers that no specialisation covers, with the roles that they have
// to hold, as `destination/source/sourceWidth`. The fused returns keep the
// roles of the copy they replace.
public string[] handlerRoleMismatches() {
    import snakebite.backends.bytecode.vm: opJump, opStaticAddress,
        opStaticStore, opThenReturn, opTlsAddress, opTlsLoad, opTlsStore,
        opCopyFixed;

    string[] found;
    void expect(string name, const Instruction.Handler handler, string roles) {
        const actual = rolesOfHandler(handler);
        if (actual != roles)
            found ~= text(name, " has roles ", actual, ", not ", roles);
    }

    expect("opJump", &opJump, "instruction/other/other");
    expect("opStaticStore", &opStaticStore, "address/other/other");
    expect("opStaticAddress", &opStaticAddress, "other/address/other");
    expect("opTlsLoad", &opTlsLoad, "other/address/other");
    expect("opTlsStore", &opTlsStore, "address/other/other");
    expect("opTlsAddress", &opTlsAddress, "other/address/other");
    static foreach (width; 1 .. 17)
        expect("opThenReturn!(opCopyFixed!(" ~ width.stringof ~ ", true))",
            &opThenReturn!(opCopyFixed!(width, true)), "other/address/other");
    return found;
}

// The relocs whose place does not hold the address that the reloc names.
public string[] misplacedRelocs(const(Function)* function_) {
    string[] found;
    foreach (reloc; function_.relocs) {
        size_t value;
        if (!wordAt(function_, reloc.place, value))
            found ~= text(reloc.place, " is outside the function");
        else if (value != reloc.target.address)
            found ~= text(reloc.place, " holds ", value, ", not ",
                reloc.target.address);
    }
    return found;
}

private bool wordAt(
    const(Function)* function_, in Place place, out size_t value,
) {
    const index = place.index;
    final switch (place.section) with (Place.Section) {
        case instruction:
            if (index >= function_.instructions.length)
                return false;
            const instruction = function_.instructions[index];
            switch (place.field) with (Place.Field) {
                case destination: value = instruction.destination; return true;
                case source: value = instruction.source; return true;
                case sourceWidth: value = instruction.sourceWidth; return true;
                default: return false;
            }
        case constant:
            if (index >= function_.constants.length)
                return false;
            value = cast(size_t) function_.constants[index];
            return place.field == Place.Field.word;
        case callSite:
            if (index >= function_.callSites.length)
                return false;
            const site = &function_.callSites[index];
            switch (place.field) with (Place.Field) {
                case callee: value = cast(size_t) site.callee; return true;
                case prepareGuest:
                    value = cast(size_t) site.prepareGuest.funcptr;
                    return true;
                case nativePlan: value = cast(size_t) site.nativePlan; return true;
                case prepareNativePlan:
                    value = cast(size_t) site.prepareNativePlan.funcptr;
                    return true;
                case builtinEntry:
                    value = cast(size_t) site.builtinEntry;
                    return true;
                case valueSignature:
                    value = cast(size_t) site.value.signature;
                    return true;
                default: return false;
            }
        case assertSite:
            if (index >= function_.assertSites.length)
                return false;
            const site = &function_.assertSites[index];
            switch (place.field) with (Place.Field) {
                case message: value = cast(size_t) site.message.ptr; return true;
                case file: value = cast(size_t) site.file.ptr; return true;
                case halt: value = cast(size_t) site.halt; return true;
                default: return false;
            }
        case exceptionHandler:
            if (index >= function_.exceptionHandlers.length)
                return false;
            value = cast(size_t) cast(void*) function_.exceptionHandlers[index].type;
            return place.field == Place.Field.type;
    }
}
