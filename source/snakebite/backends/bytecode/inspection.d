module snakebite.backends.bytecode.inspection;


// Views of a compiled `Function` for unit tests, which sit outside this
// package and cannot read its fields.
version (unittest):

private:


import snakebite.backends.bytecode.vm: bindInstructionReferences,
    CountingSite, Function, Instruction, Roles, TargetWord, jitCompiled,
    rolesOf;
import std.conv: text;

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

// What `bindInstructionReferences` says about a function of `instructions`
// whose records name each `targets` entry as (instruction, word) and each
// `counting` entry as an instruction; null when it accepts them.
public string bindWithRecords(Instruction[] instructions,
    const uint[2][] targets, const uint[] counting)
{
    Function function_;
    function_.instructions = instructions;
    foreach (target; targets)
        function_.targetWords ~= TargetWord(target[0], target[1]);
    foreach (instruction; counting)
        function_.countingSites ~= CountingSite(instruction,
            instructions[0].handler);
    return bindInstructionReferences(function_);
}
