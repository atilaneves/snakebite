module snakebite.backends.bytecode.inspection;


// Views of a compiled `Function` for unit tests, which sit outside this
// package and cannot read its fields.
version (unittest):

private:


import snakebite.backends.bytecode.relocation: Place, Reloc;
import snakebite.native.address: Target;
import snakebite.backends.bytecode.vm: Function, Instruction, Roles,
    jitCompiled, rolesOf, wordAt;
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
        const word = wordAt(*function_, reloc.place);
        if (word is null)
            found ~= text(reloc.place, " is outside the function");
        else if (*word != reloc.target.address)
            found ~= text(reloc.place, " holds ", *word, ", not ",
                reloc.target.address);
    }
    return found;
}

