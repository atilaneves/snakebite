module snakebite.backends.bytecode.vm;


private:


package struct Instruction {
    public alias Handler = extern(C) void function(
        const(Instruction)* pc,
        ubyte* frame,
        void* returnPlace,
        scope const int[] constants,
    ) @nogc nothrow;

    package Handler handler;
    package int operand;
}


package struct Function {
    package Instruction[] instructions;
    package int[] constants;
    package size_t frameSize;
    package uint frameAlignment;
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
        auto pc = function_.instructions.ptr;
        pc.handler(pc, frame.base, returnPlace, function_.constants);
    }
}


package extern(C) void opConstantI32(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
    scope const int[] constants,
) @nogc nothrow {
    *cast(int*) frame = constants[pc.operand];
    const next = pc + 1;
    next.handler(next, frame, returnPlace, constants);
}


package extern(C) void opReturnI32(
    const(Instruction)*,
    ubyte* frame,
    void* returnPlace,
    scope const int[],
) @nogc nothrow {
    if (returnPlace !is null)
        *cast(int*) returnPlace = *cast(int*) frame;
}


package extern(C) void opReturnVoid(
    const(Instruction)*,
    ubyte*,
    void*,
    scope const int[],
) @nogc nothrow {
}
