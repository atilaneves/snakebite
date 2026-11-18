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

// Each function that `backend` compiled, with the position of its function in
// the compiled program: the index of its module in the program and its index
// in the module. A save and a load keep both orders.
public void eachCompiledPosition(
    imported!"snakebite.backends.bytecode".Bytecode backend,
    scope void delegate(
        imported!"snakebite.frontend.ast".FuncDeclaration, size_t, size_t,
    ) visit,
) {
    size_t[2][const(Function)*] positions;
    foreach (m, module_; backend.compiledProgram._modules)
        foreach (f, function_; module_._functions)
            positions[function_] = [m, f];
    backend.eachCompiled((declaration, compiled) {
        if (const position = compiled in positions)
            visit(declaration, (*position)[0], (*position)[1]);
    });
}

// The function at `index` of the module `module_` of `program`.
public const(Function)* functionAt(
    ref imported!"snakebite.backends.bytecode.program".Program program,
    size_t module_, size_t index,
) {
    return program._modules[module_]._functions[index];
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

// The jump after a short-circuit chain returns to the chain's last test.
public ubyte runBranchReentry(bool jit, out bool compiled) {
    import snakebite.backends.bytecode.vm: Vm, opBranchFalse, opBranchTrue,
        opCopyFixed, opJump, opReturn, opZero;

    enum temporary = 0, first = 1, second = 2, repeat = 3, falseValue = 4;
    enum lastTest = 4, succeeded = 8, failed = 9;
    enum byteWidth = ubyte.sizeof;
    ubyte[5] seed = [0, 1, 1, 1, 0];
    auto instructions = [
        Instruction(&opCopyFixed!byteWidth, temporary, first, byteWidth),
        Instruction(&opBranchTrue, temporary, lastTest, byteWidth),
        Instruction(&opCopyFixed!byteWidth, temporary, second, byteWidth),
        Instruction(&opBranchFalse, temporary, failed, byteWidth),
        Instruction(&opBranchFalse, temporary, failed, byteWidth),
        Instruction(&opBranchFalse, repeat, succeeded, byteWidth),
        Instruction(&opZero, repeat, 0, byteWidth),
        Instruction(&opJump, lastTest, 0, 0),
        Instruction(&opReturn, 0, first, byteWidth),
        Instruction(&opReturn, 0, falseValue, byteWidth),
    ];
    return runBranchFunction(instructions, seed.sizeof, ubyte.alignof,
        [Vm.HostArgument(0, &seed, seed.sizeof)], jit, compiled);
}

// Two independent conditions both have to pass for the function to return
// the success value. The inputs are bytes, so any nonzero value is true.
public ubyte runBranchConditions(ref const ubyte[6] flags, bool jit,
    out bool compiled)
{
    import snakebite.backends.bytecode.vm: Vm, indirectStorage,
        opBranchFalse, opBranchTrue, opCopyFixed, opLogicalNot, opReturn, opZero;

    enum left = 0, right = 1, success = 2, failure = 3;
    enum pointerSlot = (ubyte*).alignof;
    enum firstJoin = 8, secondJoin = 15, failed = 17;
    enum byteWidth = ubyte.sizeof;
    const data = flags.ptr;
    const ubyte successValue = 42;
    const fields = indirectStorage(pointerSlot);
    auto instructions = [
        Instruction(&opCopyFixed!(byteWidth, true), success,
            cast(size_t) &successValue, byteWidth),
        Instruction(&opZero, failure, 0, byteWidth),
        Instruction(&opCopyFixed!byteWidth, left, fields, byteWidth),
        Instruction(&opBranchTrue, left, firstJoin, byteWidth),
        Instruction(&opCopyFixed!byteWidth, left, fields + 1, byteWidth),
        Instruction(&opLogicalNot, left, 0, byteWidth),
        Instruction(&opBranchFalse, left, firstJoin, byteWidth),
        Instruction(&opCopyFixed!byteWidth, left, fields + 2, byteWidth),
        Instruction(&opBranchFalse, left, failed, byteWidth),
        Instruction(&opCopyFixed!byteWidth, right, fields + 3, byteWidth),
        Instruction(&opBranchFalse, right, secondJoin, byteWidth),
        Instruction(&opCopyFixed!byteWidth, right, fields + 4, byteWidth),
        Instruction(&opBranchFalse, right, secondJoin, byteWidth),
        Instruction(&opCopyFixed!byteWidth, right, fields + 5, byteWidth),
        Instruction(&opLogicalNot, right, 0, byteWidth),
        Instruction(&opBranchFalse, right, failed, byteWidth),
        Instruction(&opReturn, 0, success, byteWidth),
        Instruction(&opReturn, 0, failure, byteWidth),
    ];
    return runBranchFunction(instructions, pointerSlot + data.sizeof,
        (ubyte*).alignof, [Vm.HostArgument(pointerSlot, &data, data.sizeof)],
        jit, compiled);
}

private ubyte runBranchFunction(Instruction[] instructions, size_t frameSize,
    uint alignment,
    scope const imported!"snakebite.backends.bytecode.vm".Vm.HostArgument[] args,
    bool jit, out bool compiled)
{
    import snakebite.backends.bytecode.jit: jitSupported;
    import snakebite.backends.bytecode.vm: JitSetting, Vm, prepareForExecution,
        recordLocalReferences;
    import snakebite.stack.frames: defaultFrameCapacity;

    auto function_ = Function(instructions, [], [], [], [], frameSize, alignment);
    function_.recordLocalReferences;
    const error = function_.bindInstructionReferences;
    assert(error is null, error);
    static if (jitSupported) {
        import snakebite.backends.bytecode.jit: JitInstance;
        JitInstance instance;
    }
    scope(exit) {
        static if (jitSupported)
            instance.release;
    }
    static if (jitSupported)
        prepareForExecution(&function_, JitSetting(jit, true), &instance, null);

    auto vm = Vm(defaultFrameCapacity);
    ubyte result;
    vm.call(function_, &result, args);
    compiled = isJitCompiled(&function_);
    return result;
}
