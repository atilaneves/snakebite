module snakebite.backends.bytecode.vm;


private:


package enum Opcode: ubyte {
    constantI32,
    returnI32,
}


package struct Function {
    package uint[] instructions;
    package int[] constants;
    package size_t frameSize;
    package uint frameAlignment;
}


package uint encodeInstruction(
    in Opcode opcode,
    in int operand,
) @safe @nogc nothrow pure {
    assert(operand >= -8_388_608);
    assert(operand <= 8_388_607);
    return (uint(opcode) << 24) | (cast(uint) operand & 0x00ff_ffff);
}


package struct Vm {
    import snakebite.framestack: FrameStack;

    private FrameStack _frames;

    @disable this();
    @disable this(this);

    package this(in size_t frameCapacity) {
        _frames = FrameStack(frameCapacity);
    }

    package void call(
        scope const ref Function function_,
        void* returnPlace,
    ) {
        assert(function_.instructions.length > 0);
        assert(function_.frameAlignment > 0);

        auto frame = _frames.push(
            function_.frameSize,
            function_.frameAlignment,
        );
        size_t pc;
        while (true) {
            const instruction = function_.instructions[pc++];
            const opcode = cast(Opcode) (instruction >> 24);
            const operand = cast(int) (instruction << 8) >> 8;
            final switch (opcode) with (Opcode) {
                case constantI32:
                    *cast(int*) frame.base = function_.constants[operand];
                    break;
                case returnI32:
                    if (returnPlace !is null)
                        *cast(int*) returnPlace = *cast(int*) frame.base;
                    return;
            }
        }
    }
}
