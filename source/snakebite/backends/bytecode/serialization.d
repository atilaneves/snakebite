module snakebite.backends.bytecode.serialization;

private:


// Saved bytecode requires trusted input from the same build and native target.
// The bytecode compiler and VM remain the owners of instruction semantics.
private struct Header {
    import snakebite.backends.returnplace: ReturnPlace;
    ulong magic = 0x34414547414d4953;
    size_t instructions;
    size_t constants;
    size_t parameters;
    size_t literals;
    size_t calls;
    size_t callArgs;
    size_t frameSize;
    uint frameAlignment;
    ReturnPlace returnPlace;
    size_t windowSlot;
    size_t windowBytes;
    bool windowCallable;
    size_t nativeBytes;
    size_t dataBytes;
}

private struct Literal {
    import snakebite.backends.bytecode.relocation: Place;
    size_t instruction;
    size_t field;
    Place.Section section;
    DataReference target;
}

private struct DataReference {
    size_t block = size_t.max;
    size_t offset;
    size_t binding = size_t.max;
}

private struct DataEdge {
    DataReference place;
    DataReference target;
}

private struct DataGraph {
    import snakebite.backends.bytecode.relocation: DataRelocations;
    import std.exception: enforce;
    import std.algorithm.searching: canFind, countUntil;
    const(DataRelocations)*[] owners;
    DataRelocations.Block[] blocks;
    DataEdge[] edges;
    string[] bindings;

    DataReference reference(in size_t address, in size_t base = 0) {
        foreach (i, block; blocks)
            if (references(block.bytes, address, base))
                return DataReference(i, address - cast(size_t) block.bytes.ptr);
        foreach (owner; owners)
            foreach (block; owner.blocks)
                if (references(block.bytes, address, base)) {
                    const index = blocks.length;
                    blocks ~= DataRelocations.Block(block.bytes, block.alignment);
                    return DataReference(index, address - cast(size_t) block.bytes.ptr);
                }
        foreach (owner; owners)
            foreach (binding; owner.bindings)
                if (cast(size_t) binding.address == address) {
                    auto index = bindings.countUntil(binding.symbol);
                    if (index < 0) {
                        index = bindings.length;
                        bindings ~= binding.symbol;
                    }
                    return DataReference(size_t.max, cast(size_t) binding.offset, index);
                }
        enforce(false, "image A data address has no compiler allocation or binding record");
        assert(0);
    }

    void complete() {
        for (size_t i; i < blocks.length; ++i)
            foreach (owner; owners)
                foreach (reloc; owner.relocs) {
                    const place = reloc.place.index;
                    if (!contains(blocks[i].bytes, place))
                        continue;
                    const offset = place - cast(size_t) blocks[i].bytes.ptr;
                    enforce(size_t.sizeof <= blocks[i].bytes.length - offset,
                        "image A pointer crosses data block");
                    const edge = DataEdge(DataReference(i, offset),
                        reference(reloc.target.address, owner.targetBases.get(place, 0)));
                    if (!edges.canFind(edge))
                        edges ~= edge;
                }
    }

    ubyte[] save() {
        ubyte[] bytes;
        append(bytes, bindings.length);
        foreach (binding; bindings) {
            append(bytes, binding.length);
            bytes ~= cast(const(ubyte)[]) binding;
            bytes.length += paddingLength(binding.length);
        }
        append(bytes, blocks.length);
        foreach (index, block; blocks) {
            append(bytes, block.bytes.length);
            append(bytes, block.alignment);
            auto payload = (cast(const(ubyte)*) block.bytes.ptr)[0 .. block.bytes.length].dup;
            foreach (edge; edges)
                if (edge.place.block == index)
                    payload[edge.place.offset .. edge.place.offset + size_t.sizeof] = 0;
            bytes ~= payload;
            bytes.length += paddingLength(payload.length);
        }
        append(bytes, edges.length);
        foreach (edge; edges)
            append(bytes, edge);
        return bytes;
    }
}

private bool references(in void[] bytes, in size_t address, in size_t base) {
    if (base == 0)
        return contains(bytes, address);
    const start = cast(size_t) bytes.ptr;
    return start == base && address >= start && address - start <= bytes.length;
}

private bool contains(in void[] bytes, in size_t address) {
    const start = cast(size_t) bytes.ptr;
    return address >= start && address - start < bytes.length;
}

private size_t paddingLength(in size_t bytes) @safe pure nothrow @nogc {
    return -bytes & (size_t.alignof - 1);
}

private void append(T)(ref ubyte[] bytes, in T value) {
    bytes ~= (cast(const(ubyte)*) &value)[0 .. T.sizeof];
}

private T take(T)(ref ubyte[] bytes) {
    import core.stdc.string: memcpy;
    import std.exception: enforce;
    enforce(bytes.length >= T.sizeof, "image A truncated data graph");
    T value;
    memcpy(&value, bytes.ptr, T.sizeof);
    bytes = bytes[T.sizeof .. $];
    return value;
}

private struct LoadedData {
    ubyte[][] blocks;
    void*[] bindings;

    size_t address(in DataReference reference) {
        import std.exception: enforce;
        if (reference.binding != size_t.max) {
            enforce(reference.block == size_t.max
                && reference.binding < bindings.length, "image A bad binding reference");
            return cast(size_t) bindings[reference.binding] + reference.offset;
        }
        enforce(reference.block < blocks.length
            && reference.offset <= blocks[reference.block].length,
            "image A bad data reference");
        return cast(size_t) (blocks[reference.block].ptr + reference.offset);
    }
}

private LoadedData loadDataGraph(
    ubyte[] bytes, ref imported!"snakebite.ffi.symbol".Resolver resolver,
) {
    import std.exception: enforce;
    LoadedData loadedStorage;
    const bindingCount = take!size_t(bytes);
    enforce(bindingCount <= bytes.length / size_t.sizeof, "image A bad binding count");
    foreach (i; 0 .. bindingCount) {
        const length = take!size_t(bytes);
        enforce(length <= bytes.length, "image A truncated binding name");
        const name = cast(string) bytes[0 .. length];
        bytes = bytes[length .. $];
        const padding = paddingLength(length);
        enforce(padding <= bytes.length, "image A truncated binding padding");
        bytes = bytes[padding .. $];
        auto address = resolver.resolve(name);
        enforce(address !is null, "image A cannot resolve process symbol: " ~ name);
        loadedStorage.bindings ~= address;
    }
    const count = take!size_t(bytes);
    enforce(count <= bytes.length / (2 * size_t.sizeof), "image A bad data count");
    loadedStorage.blocks = new ubyte[][count];
    auto blocks = loadedStorage.blocks;
    foreach (ref block; blocks) {
        const size = take!size_t(bytes);
        const alignment = take!size_t(bytes);
        enforce(alignment != 0 && (alignment & (alignment - 1)) == 0
            && size <= bytes.length && alignment - 1 <= size_t.max - size,
            "image A bad data block");
        auto storage = new ubyte[size + alignment - 1];
        const start = -cast(size_t) storage.ptr & (alignment - 1);
        block = storage[start .. start + size];
        block[] = bytes[0 .. size];
        bytes = bytes[size .. $];
        const padding = paddingLength(size);
        enforce(padding <= bytes.length, "image A truncated data padding");
        bytes = bytes[padding .. $];
    }
    const edges = take!size_t(bytes);
    enforce(edges <= bytes.length / DataEdge.sizeof, "image A bad edge count");
    foreach (i; 0 .. edges) {
        const edge = take!DataEdge(bytes);
        enforce(edge.place.block < blocks.length
            && edge.place.binding == size_t.max, "image A bad data edge");
        auto place = blocks[edge.place.block];
        enforce(edge.place.offset <= place.length
            && size_t.sizeof <= place.length - edge.place.offset,
            "image A bad data offset");
        import core.stdc.string: memcpy;
        const address = loadedStorage.address(edge.target);
        memcpy(place.ptr + edge.place.offset, &address, address.sizeof);
    }
    enforce(bytes.length == 0, "image A extra data graph bytes");
    return loadedStorage;
}

private struct SavedCall {
    import snakebite.backends.bytecode.vm: CallSite;
    size_t target;
    size_t argsStart;
    size_t argsCount;
    size_t returnWidth;
    size_t windowSlot;
    size_t windowDisp;
    size_t windowScratch;
    size_t windowEnd;
    uint windowAlignment;
    CallSite.Kind kind;
    size_t nativeOffset;
    size_t nativeLength;
}

private struct NativeShape {
    import snakebite.ffi.abi: ArgumentPlan;
    size_t symbolBytes;
    size_t arguments;
    ArgumentPlan result;
    bool hiddenReturnPointer;
    bool hiddenContext;
    bool contextPrecedesHiddenReturnPointer;
    bool reversedArguments;
    bool variadic;
}

private ubyte[] saveNativePlan(in imported!"snakebite.backends.bytecode.vm".CallSite site) {
    import snakebite.ffi.plan: CallPlan;
    const opaque = site.nativePlan !is null ? site.nativePlan : site.prepareNativePlan();
    const description = (cast(const(CallPlan)*) opaque).describe;
    ubyte[] bytes;
    append(bytes, NativeShape(description.symbol.length, description.arguments.length,
        description.result, description.hiddenReturnPointer, description.hiddenContext,
        description.contextPrecedesHiddenReturnPointer, description.reversedArguments,
        description.variadic));
    bytes ~= cast(const(ubyte)[]) description.symbol;
    foreach (argument; description.arguments)
        append(bytes, argument);
    return bytes;
}

private const(imported!"snakebite.ffi.plan".CallPlan)* loadNativePlan(
    ubyte[] bytes, ref imported!"snakebite.ffi.symbol".Resolver resolver,
) {
    import snakebite.ffi.plan: CallPlan;
    import snakebite.ffi.abi: ArgumentPlan;
    import std.exception: enforce;
    const shape = take!NativeShape(bytes);
    enforce(shape.symbolBytes <= bytes.length, "image A truncated native symbol");
    CallPlan.Description description;
    description.symbol = cast(string) bytes[0 .. shape.symbolBytes];
    bytes = bytes[shape.symbolBytes .. $];
    enforce(shape.arguments <= bytes.length / ArgumentPlan.sizeof,
        "image A truncated native signature");
    description.arguments = new ArgumentPlan[shape.arguments];
    foreach (ref argument; description.arguments)
        argument = take!ArgumentPlan(bytes);
    enforce(bytes.length == 0, "image A extra native plan bytes");
    description.result = shape.result;
    description.hiddenReturnPointer = shape.hiddenReturnPointer;
    description.hiddenContext = shape.hiddenContext;
    description.contextPrecedesHiddenReturnPointer = shape.contextPrecedesHiddenReturnPointer;
    description.reversedArguments = shape.reversedArguments;
    description.variadic = shape.variadic;
    auto plan = new CallPlan;
    *plan = CallPlan.fromDescription(description, resolver);
    return plan;
}

private ref size_t operand(
    ref imported!"snakebite.backends.bytecode.vm".Instruction instruction,
    in size_t field,
) {
    import snakebite.backends.bytecode.relocation: Place;
    switch (field) {
        case Place.Field.destination: return instruction.destination;
        case Place.Field.source: return instruction.source;
        case Place.Field.sourceWidth: return instruction.sourceWidth;
        default: assert(0);
    }
}

private ubyte[] encodeFunction(
    scope const ref imported!"snakebite.backends.bytecode.vm".Function function_,
    scope const(imported!"snakebite.backends.bytecode.vm".Function)*[] functions,
    ref DataGraph graph,
) {
    import snakebite.backends.bytecode.vm:
        Instruction, CallSite, Arg, Roles, Role, rolesOf, opReturnVoid,
        branchTargetField;
    import snakebite.backends.bytecode.relocation: Place, Target;
    import std.exception: enforce;
    import std.algorithm.searching: countUntil;
    enforce(function_.assertSites.length == 0
        && function_.exceptionHandlers.length == 0
        && function_.closureSize == 0
        && function_.contextOffset == size_t.max,
        "image A requires a pointer-free arithmetic function");
    size_t callArgsCount;
    auto serializedNativeCalls = new ubyte[][function_.callSites.length];
    size_t nativeBytes;
    foreach (i, site; function_.callSites) {
        enforce((site.kind == CallSite.Kind.guest || site.kind == CallSite.Kind.native)
            && site.value.signature is null, "image A requires fixed calls");
        if (site.kind == CallSite.Kind.native) {
            serializedNativeCalls[i] = saveNativePlan(site);
            nativeBytes += serializedNativeCalls[i].length
                + paddingLength(serializedNativeCalls[i].length);
        }
        callArgsCount += site.args.length;
    }
    size_t literalCount;
    foreach (reloc; function_.relocs)
        if (reloc.place.section == Place.Section.instruction
                || reloc.place.section == Place.Section.constant)
            ++literalCount;
    const header = Header(Header.init.magic, function_.instructions.length,
        function_.constants.length, function_.parameterOffsets.length,
        literalCount, function_.callSites.length, callArgsCount,
        function_.frameSize, function_.frameAlignment, function_.returnPlace,
        function_.windowSlot, function_.windowBytes, function_.windowCallable,
        nativeBytes);
    auto bytes = new ubyte[Header.sizeof
        + function_.instructions.length * Instruction.sizeof
        + function_.constants.length * long.sizeof
        + function_.parameterOffsets.length * size_t.sizeof
        + literalCount * Literal.sizeof
        + function_.callSites.length * SavedCall.sizeof
        + callArgsCount * Arg.sizeof + nativeBytes];
    bytes[0 .. Header.sizeof] = (cast(const(ubyte)*) &header)[0 .. Header.sizeof];
    size_t offset = Header.sizeof;
    foreach (instruction; function_.instructions) {
        Instruction stored = instruction;
        if (auto target = branchTargetField(stored)) {
            const start = cast(size_t) function_.instructions.ptr;
            enforce(*target >= start
                && (*target - start) % Instruction.sizeof == 0
                && (*target - start) / Instruction.sizeof < function_.instructions.length,
                "image A bad branch target");
            *target = (*target - start) / Instruction.sizeof;
        }
        // The same executable has fixed code offsets even when ASLR moves it.
        stored.handler = cast(Instruction.Handler)
            (cast(size_t) stored.handler - cast(size_t) &opReturnVoid);
        bytes[offset .. offset + Instruction.sizeof] =
            (cast(const(ubyte)*) &stored)[0 .. Instruction.sizeof];
        offset += Instruction.sizeof;
    }
    const constants = function_.constants.length * long.sizeof;
    bytes[offset .. offset + constants] =
        (cast(const(ubyte)*) function_.constants.ptr)[0 .. constants];
    offset += constants;
    const parameters = function_.parameterOffsets.length * size_t.sizeof;
    bytes[offset .. offset + parameters] =
        (cast(const(ubyte)*) function_.parameterOffsets.ptr)[0 .. parameters];
    offset += parameters;
    auto instructions = (cast(Instruction*) (bytes.ptr + Header.sizeof))
        [0 .. header.instructions];
    auto literals = (cast(Literal*) (bytes.ptr + offset))[0 .. header.literals];
    auto recorded = new ubyte[header.instructions];
    size_t literalIndex;
    foreach (reloc; function_.relocs) {
        if (reloc.place.section == Place.Section.callSite)
            continue;
        enforce((reloc.target.kind == Target.Kind.constantPool
                || ((reloc.target.kind == Target.Kind.staticData
                    || reloc.target.kind == Target.Kind.typeInfo) && graph.owners.length))
            && (reloc.place.section == Place.Section.constant
                || (reloc.place.section == Place.Section.instruction
                    && reloc.place.index < instructions.length
                    && reloc.place.field <= Place.Field.sourceWidth)),
            "image A instruction holds an address");
        auto literal = Literal(reloc.place.index, reloc.place.field,
            reloc.place.section);
        literal.target = graph.reference(reloc.target.address);
        literals[literalIndex++] = literal;
        if (reloc.place.section == Place.Section.instruction) {
            operand(instructions[reloc.place.index], reloc.place.field) = 0;
            recorded[reloc.place.index] |= 1 << reloc.place.field;
        } else {
            enforce(reloc.place.index < function_.constants.length,
                "image A bad constant location");
            auto pool = cast(long*) (bytes.ptr + Header.sizeof
                + header.instructions * Instruction.sizeof);
            pool[reloc.place.index] = 0;
        }
    }
    foreach (i, instruction; function_.instructions) {
        Roles roles;
        if (!rolesOf(instruction.handler, roles))
            continue;
        foreach (field, role; [roles.destination, roles.source, roles.sourceWidth])
            enforce(role == Role.other || role == Role.instruction
                || (role == Role.address && (recorded[i] & (1 << field))),
                "image A instruction holds an address");
    }
    offset += literalCount * Literal.sizeof;
    auto calls = (cast(SavedCall*) (bytes.ptr + offset))[0 .. header.calls];
    auto args = (cast(Arg*) (bytes.ptr + offset
        + header.calls * SavedCall.sizeof))[0 .. header.callArgs];
    size_t argsIndex;
    size_t nativeOffset;
    foreach (i, site; function_.callSites) {
        size_t target;
        if (site.kind == CallSite.Kind.guest) {
            const callee = site.callee !is null ? site.callee : site.prepareGuest();
            const index = functions.countUntil(callee);
            enforce(index >= 0, "image A call target is not in bundle");
            target = index;
        }
        calls[i] = SavedCall(target, argsIndex, site.args.length,
            site.returnWidth, site.windowSlot, site.windowDisp,
            site.windowScratch, site.windowEnd, site.windowAlignment,
            site.kind, nativeOffset, serializedNativeCalls[i].length);
        bytes[bytes.length - nativeBytes + nativeOffset
            .. bytes.length - nativeBytes + nativeOffset + serializedNativeCalls[i].length] =
            serializedNativeCalls[i];
        nativeOffset += serializedNativeCalls[i].length
            + paddingLength(serializedNativeCalls[i].length);
        args[argsIndex .. argsIndex + site.args.length] = site.args;
        argsIndex += site.args.length;
    }
    return bytes;
}

public ubyte[] saveFunction(
    scope const ref imported!"snakebite.backends.bytecode.vm".Function function_,
) {
    import snakebite.backends.bytecode.relocation: Target;
    import std.exception: enforce;
    enforce(function_.callSites.length == 0,
        "image A direct calls require a bundle");
    DataGraph graph;
    foreach (reloc; function_.relocs)
        enforce(reloc.target.kind == Target.Kind.constantPool,
            "image A instruction holds an address");
    if (function_.dataRelocations !is null)
        graph.owners ~= function_.dataRelocations;
    auto bytes = encodeFunction(function_, null, graph);
    graph.complete;
    const serializedStorage = graph.save;
    (cast(Header*) bytes.ptr).dataBytes = serializedStorage.length;
    bytes ~= serializedStorage;
    return bytes;
}

// This is not a bytecode verifier. Do not load files from another build or
// from an untrusted source. Operand bounds are guaranteed by the compiler.
public imported!"snakebite.backends.bytecode.vm".Function loadFunction(in string path) {
    import std.file: read;
    import snakebite.ffi.symbol: Resolver;
    Resolver resolver;
    return decodeFunction(cast(ubyte[]) read(path), resolver);
}

private imported!"snakebite.backends.bytecode.vm".Function decodeFunction(
    ubyte[] bytes,
    ref imported!"snakebite.ffi.symbol".Resolver resolver,
    imported!"snakebite.backends.bytecode.vm".Function[] functions = null,
    LoadedData loadedStorage = LoadedData.init,
) {
    import snakebite.backends.bytecode.vm:
        Function, Instruction, Arg, CallSite, opReturnVoid, branchTargetField;
    import snakebite.backends.bytecode.relocation: Place;
    import std.exception: enforce;
    enforce(bytes.length >= Header.sizeof, "image A truncated header");
    const header = *cast(const(Header)*) bytes.ptr;
    enforce(header.magic == Header.init.magic, "image A bad magic");
    enforce(header.dataBytes <= bytes.length - Header.sizeof,
        "image A truncated data graph");
    if (header.dataBytes) {
        loadedStorage = loadDataGraph(bytes[$ - header.dataBytes .. $], resolver);
        bytes = bytes[0 .. $ - header.dataBytes];
    }
    size_t remaining = bytes.length - Header.sizeof;
    void take(in size_t count, in size_t width) {
        enforce(count <= remaining / width, "image A truncated data");
        remaining -= count * width;
    }
    take(header.instructions, Instruction.sizeof);
    take(header.constants, long.sizeof);
    take(header.parameters, size_t.sizeof);
    take(header.literals, Literal.sizeof);
    take(header.calls, SavedCall.sizeof);
    take(header.callArgs, Arg.sizeof);
    take(header.nativeBytes, 1);
    enforce(remaining == 0 && header.instructions != 0
        && header.frameAlignment != 0
        && (header.frameAlignment & (header.frameAlignment - 1)) == 0,
        "image A invalid shape");
    Function function_;
    function_.loadedAllocations = loadedStorage.blocks;
    size_t offset = Header.sizeof;
    function_.instructions = (cast(Instruction*) (bytes.ptr + offset))
        [0 .. header.instructions];
    offset += header.instructions * Instruction.sizeof;
    function_.constants = (cast(long*) (bytes.ptr + offset))[0 .. header.constants];
    offset += header.constants * long.sizeof;
    function_.parameterOffsets = (cast(size_t*) (bytes.ptr + offset))
        [0 .. header.parameters];
    offset += header.parameters * size_t.sizeof;
    function_.frameSize = header.frameSize;
    function_.frameAlignment = header.frameAlignment;
    function_.returnPlace = header.returnPlace;
    function_.windowSlot = header.windowSlot;
    function_.windowBytes = header.windowBytes;
    function_.windowCallable = header.windowCallable;
    foreach (ref instruction; function_.instructions) {
        instruction.handler = cast(Instruction.Handler)
            (cast(size_t) &opReturnVoid + cast(size_t) instruction.handler);
        if (auto target = branchTargetField(instruction)) {
            enforce(*target < function_.instructions.length,
                "image A bad branch target");
            *target = cast(size_t) (function_.instructions.ptr + *target);
        }
    }
    auto literals = (cast(Literal*) (bytes.ptr + offset))[0 .. header.literals];
    foreach (ref literal; literals) {
        const address = loadedStorage.address(literal.target);
        if (literal.section == Place.Section.constant) {
            enforce(literal.instruction < function_.constants.length,
                "image A bad constant location");
            function_.constants[literal.instruction] = address;
        } else {
            enforce(literal.section == Place.Section.instruction
                && literal.instruction < function_.instructions.length
                && literal.field <= Place.Field.sourceWidth,
                "image A bad literal location");
            operand(function_.instructions[literal.instruction], literal.field) = address;
        }
    }
    offset += header.literals * Literal.sizeof;
    auto savedCalls = (cast(SavedCall*) (bytes.ptr + offset))[0 .. header.calls];
    auto savedArgs = (cast(Arg*) (bytes.ptr + offset
        + header.calls * SavedCall.sizeof))[0 .. header.callArgs];
    auto nativeBytes = bytes[$ - header.nativeBytes .. $];
    function_.callSites = new CallSite[header.calls];
    foreach (i, saved; savedCalls) {
        enforce(saved.argsStart <= savedArgs.length
            && saved.argsCount <= savedArgs.length - saved.argsStart,
            "image A bad call record");
        auto arguments = savedArgs[saved.argsStart .. saved.argsStart + saved.argsCount];
        CallSite site;
        if (saved.kind == CallSite.Kind.guest) {
            enforce(saved.target < functions.length, "image A bad guest target");
            site = CallSite.guest(&functions[saved.target], arguments, saved.returnWidth);
        } else {
            enforce(saved.kind == CallSite.Kind.native
                && saved.nativeOffset <= nativeBytes.length
                && saved.nativeLength <= nativeBytes.length - saved.nativeOffset,
                "image A bad native call record");
            site = CallSite.native(loadNativePlan(nativeBytes[saved.nativeOffset
                .. saved.nativeOffset + saved.nativeLength], resolver), arguments,
                saved.returnWidth);
        }
        site.windowSlot = saved.windowSlot;
        site.windowDisp = saved.windowDisp;
        site.windowScratch = saved.windowScratch;
        site.windowEnd = saved.windowEnd;
        site.windowAlignment = saved.windowAlignment;
        function_.callSites[i] = site;
    }
    function_.fixWindowFacts;
    return function_;
}

public ubyte[] save(
    scope const(imported!"snakebite.backends.bytecode.vm".Function)*[] functions,
) {
    import snakebite.backends.bytecode.vm: Function, CallSite;
    import std.exception: enforce;
    import std.algorithm.searching: canFind;
    import snakebite.backends.bytecode.relocation: recordRelocs;
    const previous = recordRelocs;
    recordRelocs = true;
    scope(exit) recordRelocs = previous;
    const(Function)*[] reachable = functions.dup;
    for (size_t i; i < reachable.length; ++i) {
        foreach (site; reachable[i].callSites) {
            if (site.kind == CallSite.Kind.native)
                continue;
            enforce(site.kind == CallSite.Kind.guest && site.value.signature is null,
                "image A requires direct guest calls");
            enforce(site.callee !is null || site.prepareGuest !is null,
                "image A direct call has no target");
            const callee = site.callee !is null ? site.callee : site.prepareGuest();
            if (!reachable.canFind(callee))
                reachable ~= callee;
        }
    }
    ubyte[] bytes;
    DataGraph graph;
    foreach (function_; reachable)
        if (function_.dataRelocations !is null
                && !graph.owners.canFind(function_.dataRelocations))
            graph.owners ~= function_.dataRelocations;
    ubyte[][] serializedFunctions;
    foreach (function_; reachable)
        serializedFunctions ~= encodeFunction(*function_, reachable, graph);
    graph.complete;
    const serializedStorage = graph.save;
    const count = reachable.length;
    bytes ~= (cast(const(ubyte)*) &count)[0 .. count.sizeof];
    const roots = functions.length;
    bytes ~= (cast(const(ubyte)*) &roots)[0 .. roots.sizeof];
    append(bytes, serializedStorage.length);
    bytes ~= serializedStorage;
    foreach (serializedFunction; serializedFunctions) {
        const length = serializedFunction.length;
        bytes ~= (cast(const(ubyte)*) &length)[0 .. length.sizeof];
        bytes ~= serializedFunction;
    }
    return bytes;
}

public imported!"snakebite.backends.bytecode.vm".Function[] load(in string path) {
    import snakebite.ffi.symbol: Resolver;
    import snakebite.backends.bytecode.vm: Function;
    import std.exception: enforce;
    import std.file: read;
    auto bytes = cast(ubyte[]) read(path);
    enforce(bytes.length >= 2 * size_t.sizeof, "image A truncated bundle");
    const count = *cast(const(size_t)*) bytes.ptr;
    bytes = bytes[size_t.sizeof .. $];
    const roots = *cast(const(size_t)*) bytes.ptr;
    bytes = bytes[size_t.sizeof .. $];
    enforce(roots <= count, "image A bad root count");
    Resolver resolver;
    const dataLength = take!size_t(bytes);
    enforce(dataLength <= bytes.length, "image A truncated data graph");
    auto loadedStorage = loadDataGraph(bytes[0 .. dataLength], resolver); // Fixups write native pointers.
    bytes = bytes[dataLength .. $];
    enforce(count <= bytes.length / size_t.sizeof, "image A bad function count");
    auto functions = new Function[count];
    foreach (ref function_; functions) {
        enforce(bytes.length >= size_t.sizeof, "image A truncated bundle");
        const length = *cast(const(size_t)*) bytes.ptr;
        bytes = bytes[size_t.sizeof .. $];
        enforce(length <= bytes.length, "image A truncated function");
        function_ = decodeFunction(bytes[0 .. length], resolver, functions, loadedStorage);
        bytes = bytes[length .. $];
    }
    enforce(bytes.length == 0, "image A extra bundle data");
    return functions[0 .. roots];
}

public ulong execute(
    scope const ref imported!"snakebite.backends.bytecode.vm".Function function_,
    ulong x, ulong y,
) {
    import snakebite.backends.bytecode.vm: Vm;
    import std.exception: enforce;
    import snakebite.framestack: defaultFrameCapacity;
    enforce(function_.parameterOffsets.length == 2,
        "image A expects two arithmetic arguments");
    auto vm = Vm(defaultFrameCapacity);
    const arguments = [
        Vm.HostArgument(function_.parameterOffsets[0], &x, x.sizeof),
        Vm.HostArgument(function_.parameterOffsets[1], &y, y.sizeof),
    ];
    ulong result;
    vm.call(function_, &result, arguments);
    return result;
}
