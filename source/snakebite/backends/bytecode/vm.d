module snakebite.backends.bytecode.vm;


private:


package struct Instruction {
    public alias Handler = extern(C) const(Instruction)* function(
        const(Instruction)* pc,
        ubyte* frame,
        void* returnPlace,
    ) @nogc nothrow;

    package Handler handler;
    package size_t offset;
    package int immediate;
}


package struct Function {
    package Instruction[] instructions;
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
        while (pc !is null)
            pc = pc.handler(pc, frame.base, returnPlace);
    }
}


package extern(C) const(Instruction)* opConstantI32(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
) @nogc nothrow {
    *cast(int*) (frame + pc.offset) = pc.immediate;
    return pc + 1;
}


package extern(C) const(Instruction)* opReturnI32(
    const(Instruction)* pc,
    ubyte* frame,
    void* returnPlace,
) @nogc nothrow {
    if (returnPlace !is null)
        *cast(int*) returnPlace = *cast(int*) (frame + pc.offset);
    return null;
}
