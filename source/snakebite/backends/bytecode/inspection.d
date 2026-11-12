module snakebite.backends.bytecode.inspection;


// Views of a compiled `Function` for unit tests, which sit outside this
// package and cannot read its fields.
version (unittest):

private:


import snakebite.backends.bytecode.relocation: Place, Reloc;
import snakebite.native.address: Target;
import snakebite.backends.bytecode.vm: Function, Instruction, Roles,
    jitCompiled, rolesOf;
import std.conv: text;

public const(Reloc)[] relocsOf(const(Function)* function_) {
    return function_.relocs;
}

// Whether `function_` runs as JIT code.
public bool isJitCompiled(const(Function)* function_) {
    return jitCompiled(function_);
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
    const(Function)* fn, in Place place, out size_t value,
) {
    const index = place.index;
    final switch (place.section) with (Place.Section) {
        case function_:
            value = cast(size_t) fn.signature;
            return place.field == Place.Field.signature;
        case instruction:
            if (index >= fn.instructions.length)
                return false;
            const instruction = fn.instructions[index];
            switch (place.field) with (Place.Field) {
                case destination: value = instruction.destination; return true;
                case source: value = instruction.source; return true;
                case sourceWidth: value = instruction.sourceWidth; return true;
                default: return false;
            }
        case constant:
            if (index >= fn.constants.length)
                return false;
            value = cast(size_t) fn.constants[index];
            return place.field == Place.Field.word;
        case callSite:
            if (index >= fn.callSites.length)
                return false;
            const site = &fn.callSites[index];
            switch (place.field) with (Place.Field) {
                case callee: value = cast(size_t) site.callee; return true;
                case nativePlan: value = cast(size_t) site.nativePlan; return true;
                case valueSignature:
                    value = cast(size_t) site.value.signature;
                    return true;
                default: return false;
            }
        case assertSite:
            if (index >= fn.assertSites.length)
                return false;
            const site = &fn.assertSites[index];
            switch (place.field) with (Place.Field) {
                case message: value = cast(size_t) site.message.ptr; return true;
                case file: value = cast(size_t) site.file.ptr; return true;
                default: return false;
            }
        case exceptionHandler:
            if (index >= fn.exceptionHandlers.length)
                return false;
            value = cast(size_t) cast(void*) fn.exceptionHandlers[index].type;
            return place.field == Place.Field.type;
        case datum:
            return false;
    }
}
