module snakebite.backends.bytecode.emitted;


private:


import snakebite.backends.bytecode.relocation: Place, Reloc;
import snakebite.backends.bytecode.vm;
import snakebite.failure.report: internalFailure;
import snakebite.native.value: CastKind;
import object: TypeInfo_Class;


// Each active compiler owns its capacity. Published slices keep their GC
// allocation; no later compile can reuse it, including a nested compile.
package static struct CompileBuffer(T) {
    package T[] _storage;
    T[] data;
    alias data this;

    void opOpAssign(string op)(T value) if (op == "~") {
        const count = data.length;
        if (count == _storage.length) {
            const capacity = count == 0 ? 4 : count * 2;
            if (capacity <= count || capacity > size_t.max / T.sizeof)
                internalFailure("compile buffer capacity overflows");
            auto storage = new T[capacity];
            storage[0 .. count] = data[];
            _storage = storage;
        }
        _storage[count] = value;
        data = _storage[0 .. count + 1];
    }
}

package struct PendingExceptionHandler {
    package TypeInfo_Class _type;
    package size_t _bodyStart;
    package size_t _bodyEnd;
    package size_t _handler;
    package size_t _catchOffset;
    package size_t _cleanupEnd = size_t.max;
}

package struct ColdRange {
    size_t first, end, siteFirst, siteEnd, hooks;
}

package enum indirectCopyWidths = [1, 2, 4, 8, 16, 32];


// How a copied instruction names frame storage. `ignored` marks a field
// that holds no storage operand.
package enum Operand { ignored, storage, constant, callSite }

package struct Operands {
    Operand destination;
    Operand source;
    // The right operand of a three-address instruction, held in
    // `sourceWidth`.
    Operand right;
}

// The operand roles of every handler a copied function may use, and
// `false` for any other. A handler outside this list never gets copied,
// so a new opcode starts as not copyable.
package bool inlineOperandsOf(
    Instruction.Handler handler, out Operands roles,
) {
    import std.meta: AliasSeq;

    enum S = Operand.storage;
    enum N = Operand.ignored;
    static foreach (operation; AliasSeq!(
        opCopy, opLoadIndirect, opStoreIndirect, opAdd, opSubtract,
        opMultiply, opBitAnd, opBitOr, opBitXor, opShiftLeft,
        opShiftRightLogical, opShiftRightArithmetic, opLessThanSigned,
        opLessThanUnsigned, opLessOrEqualSigned, opLessOrEqualUnsigned,
        opGreaterThanSigned, opGreaterThanUnsigned,
        opGreaterOrEqualSigned, opGreaterOrEqualUnsigned, opEqual,
        opNotEqual, opFrameAddress,
        opCopyFixed!1, opCopyFixed!2, opCopyFixed!4, opCopyFixed!8,
        opCopyFixed!16,
    )) {
        if (handler is &operation) {
            roles = Operands(S, S);
            return true;
        }
    }
    static foreach (index, operation; threeAddressHandlers) {
        if (handler is &operation) {
            roles = Operands(S, S, S);
            return true;
        }
        // The constant form holds the address of a native constant in
        // `sourceWidth`; it does not move.
        if (handler is &threeAddressConstantHandlers[index]) {
            roles = Operands(S, S, N);
            return true;
        }
    }
    static foreach (operation; AliasSeq!(
        opIndexSlice, opIndexStatic, opIndexPointer,
    )) {
        if (handler is &operation) {
            roles = Operands(S, S, S);
            return true;
        }
    }
    // A fused compare-and-branch: the left operand is in `destination`
    // and the branch target in `sourceWidth`, which the caller of this
    // method moves as it moves every branch target.
    if (isFusedBranch(handler)) {
        roles = Operands(S, fusesConstant(handler) ? N : S);
        return true;
    }
    static foreach (width; indirectCopyWidths) {
        if (handler is &opLoadIndirectFixed!width
                || handler is &opStoreIndirectFixed!width) {
            roles = Operands(S, S);
            return true;
        }
    }
    static foreach (kind; [
        CastKind.narrow, CastKind.widenSigned, CastKind.widenUnsigned,
    ])
        static foreach (destSize; [1UL, 2, 4, 8])
            static foreach (sourceSize; [1UL, 2, 4, 8])
                if (handler is &opCastFixedAs!(kind, destSize, sourceSize)) {
                    roles = Operands(S, S);
                    return true;
                }
    static foreach (operation; AliasSeq!(
        opNegate, opComplement, opLogicalNot, opCastToBool,
        opCastWidenSigned, opCastWidenUnsigned, opStaticLoad, opZero,
        opThrow, opBranchTrue, opBranchFalse,
    )) {
        if (handler is &operation) {
            roles = Operands(S, N);
            return true;
        }
    }
    if (handler is &opConstant) {
        roles = Operands(S, Operand.constant);
        return true;
    }
    if (handler is &opReturn) {
        roles = Operands(N, S);
        return true;
    }
    if (handler is &opJump || handler is &opReturnVoid) {
        roles = Operands(N, N);
        return true;
    }
    return false;
}

// `inlineOperandsOf`, and the handlers whose `width` or `source` field is
// not a plain operand. The operand analyses of `classify` read only
// `inlineOperandsOf`, because their reading of `width` does not fit these.
package bool copyOperandsOf(
    Instruction.Handler handler, out Operands roles,
) {
    enum S = Operand.storage;
    enum N = Operand.ignored;
    if (inlineOperandsOf(handler, roles))
        return true;
    if (handler is &opColdThrow) {
        roles = Operands(S, Operand.callSite);
        return true;
    }
    if (handler is &opCall) {
        roles = Operands(N, Operand.callSite);
        return true;
    }
    // The left array is read from `destination`, which then takes the
    // result; `width` is an element size.
    if (handler is &opArrayEqual || handler is &opStaticArrayEqual) {
        roles = Operands(S, S);
        return true;
    }
    CheckedAccess access;
    bool constantValue;
    if (checkedIndexKind(handler, access, constantValue)) {
        // A check has no value operand, and a constant value is the
        // address of a native constant.
        roles = Operands(
            access == CheckedAccess.check || constantValue ? N : S, S);
        return true;
    }
    return false;
}


// The code of one function while the compiler emits it: the instructions and
// the tables that they index, and the passes that work on them after the
// last instruction. It holds nothing of the frontend. An instruction is
// known by its index here; the indices become addresses when the function is
// complete.
package struct EmittedCode {
    package bool inCold(in size_t index) const {
        foreach (range; cold)
            if (index >= range.first && index < range.end)
                return true;
        return false;
    }


    package CompileBuffer!Instruction instructions;

    package long[] constants;

    // Every word of the instructions and constants that holds an address.
    package Reloc[] relocs;

    package CompileBuffer!CallSite callSites;

    package AssertSite[] assertSites;

    package PendingExceptionHandler[] exceptionHandlers;

    package ColdRange[] cold;

    // Temporaries made for an operand and read by its one parent.
    package CompileBuffer!size_t operandTemps;

    // The offset and size of every temporary `reserveTemp` made, in
    // increasing order of offset.
    package CompileBuffer!size_t tempStarts;

    package CompileBuffer!size_t tempSizes;

    package void optimizeStaticLoads() {
        foreach (ref instruction; instructions) {
            if (instruction.handler is &opStaticLoad) {
                static foreach (width; 1 .. 17)
                    if (instruction.width == width)
                        instruction.handler = &opCopyFixed!(width, true);
            }
        }
    }

    // The arrays of `assignRegisters`, kept for the next compile on the same
    // thread so that the pass allocates nothing once they are big enough. A
    // compile runs on one thread and the pass does not call out, so thread
    // local storage is enough.
    package static uint[] _mentionsStorage;
    package static bool[] _isTargetStorage;
    package static bool[] _readsRegisterStorage;
    package static bool[] _writesRegisterStorage;
    package static bool[] _fusedStorage;

    // The first `length` elements of `storage`, set to `T.init`. A short
    // `storage` doubles at least, so a run of larger compiles allocates
    // O(log n) times.
    package static T[] zeroed(T)(ref T[] storage, in size_t length)
        @safe nothrow pure
    {
        if (storage.length < length)
            storage = new T[length > storage.length * 2
                ? length : storage.length * 2];
        else
            storage[0 .. length] = T.init;
        return storage[0 .. length];
    }

    // Keeps the result of an arithmetic instruction in a register when the
    // next instruction is its only reader: the operand temporary is read by
    // that instruction alone, and the next instruction is not a branch
    // target, an exception handler entry or a cleanup bound.
    package void assignRegisters() {
        const count = instructions.length;
        if (count < 2)
            return;
        // Only operand temporaries are ever looked up, so a value that is
        // not one is not counted. `operandTemps` grows in increasing offset
        // order (`_tempSize` never shrinks), so the position of an offset in
        // it, found by binary search, is a dense index. Cost does not depend
        // on the frame size.
        import std.range: assumeSorted;

        auto mentions = zeroed(_mentionsStorage, operandTemps.length);
        auto isTarget = zeroed(_isTargetStorage, count + 1);
        size_t tempIndex(in size_t offset) {
            const index = operandTemps.data.assumeSorted.lowerBound(offset).length;
            return index < operandTemps.length
                    && operandTemps[index] == offset
                ? index : operandTemps.length;
        }
        void mention(in size_t operand) {
            const index = tempIndex(operand);
            if (index < mentions.length)
                mentions[index]++;
        }
        foreach (ref instruction; instructions) {
            mention(instruction.destination);
            if (instruction.source != instruction.destination)
                mention(instruction.source);
            if (instruction.sourceWidth != instruction.source
                    && instruction.sourceWidth != instruction.destination)
                mention(instruction.sourceWidth);
            // A temp that holds an address is mentioned by every indirect
            // operand that reads through it. A field that is not an operand
            // can only add mentions, which only stops a pairing.
            static foreach (field; ["destination", "source", "sourceWidth"])
                if (mixin("instruction." ~ field) & (1UL << 63))
                    mention((mixin("instruction." ~ field) >> 32)
                        & 0x7fff_ffffUL);
            if (auto field = branchTargetField(instruction)) {
                if (*field < isTarget.length)
                    isTarget[*field] = true;
            }
        }
        markScopeTargets(isTarget);

        auto readsRegister = zeroed(_readsRegisterStorage, count);
        auto writesRegister = zeroed(_writesRegisterStorage, count);
        auto fused = zeroed(_fusedStorage, count);
        foreach (index; 0 .. count - 1) {
            auto producer = &instructions[index];
            auto consumer = &instructions[index + 1];
            if (isTarget[index + 1])
                continue;
            const family = registerFamily(producer.handler, producer.width);
            if (family == RegisterFamily.none)
                continue;
            const temp = producer.destination;
            const tempSlot = tempIndex(temp);
            if (tempSlot == mentions.length || mentions[tempSlot] != 2)
                continue;
            if (consumer.width != producer.width)
                continue;
            if (registerFamily(consumer.handler, consumer.width) == family) {
                if (consumer.source != temp || consumer.sourceWidth == temp
                        || consumer.destination == temp)
                    continue;
            } else if (fusedRegisterFamily(consumer.handler, consumer.width)
                    == family) {
                if (consumer.destination != temp || consumer.source == temp)
                    continue;
                fused[index + 1] = true;
            } else
                continue;
            writesRegister[index] = true;
            readsRegister[index + 1] = true;
        }
        foreach (index, ref instruction; instructions) {
            if (fused[index]) {
                instruction.handler = fusedRegisterForm(instruction.handler);
            } else if (readsRegister[index] || writesRegister[index]) {
                instruction.handler = registerForm(instruction.handler,
                    readsRegister[index], writesRegister[index]);
            }
        }
    }



    // Copy forwarding. A temporary that one instruction fills and one copy
    // empties makes the producer write the copy's destination instead; a
    // copy into a temporary that one instruction reads makes that
    // instruction read the copy's source instead. A temporary counts only
    // when `reserveTemp` made it, and a pass counts every access that
    // overlaps it: an instruction field, a call argument or a catch
    // offset. The VM can write storage with no instruction naming it (the
    // closure pointer), so `reserveStorage` makes that and the pass never
    // sees it.
    package void forwardCopies() {
        const count = instructions.length;
        if (count < 2 || tempStarts.length == 0)
            return;

        auto isTarget = new bool[count + 1];
        markTargets(isTarget);

        auto state = CopyForwarding(
            instructions, tempStarts, tempSizes, isTarget);
        foreach (ref site; callSites) {
            foreach (arg; site.args)
                state.count(arg.callerOffset, arg.width, 1);
            foreach (arg; site.nativeArgs)
                state.count(arg.callerOffset, arg.width, 1);
            foreach (arg; site.value.surplus)
                state.count(arg.callerOffset, arg.width, 1);
            if (site.kind == CallSite.Kind.indirect
                    || site.kind == CallSite.Kind.value)
                state.count(site.calleeSlotOffset, size_t.sizeof, 1);
        }
        foreach (handler; exceptionHandlers)
            if (handler._catchOffset != size_t.max)
                state.count(handler._catchOffset, size_t.sizeof, 1);
        state.run;
    }

    // Calls `visit` with each place of the tables that holds the index of an
    // instruction: the bounds of each cold range, the four places of each
    // exception handler and the cleanup range of each call site. With the
    // target of each branch (`branchTargetField`) these are all the holders
    // of an instruction index, and this is the one list of them: a pass that
    // needs the jump targets, or that moves instructions, reads it.
    package void eachScopeIndex(scope void delegate(ref size_t index) visit) {
        foreach (ref range; cold) {
            visit(range.first);
            visit(range.end);
        }
        foreach (ref handler; exceptionHandlers) {
            visit(handler._bodyStart);
            visit(handler._bodyEnd);
            visit(handler._handler);
            if (handler._cleanupEnd != size_t.max)
                visit(handler._cleanupEnd);
        }
        foreach (ref site; callSites)
            if (site.cleanupStartIndex != size_t.max) {
                visit(site.cleanupStartIndex);
                visit(site.cleanupEndIndex);
            }
    }

    // Marks the instructions that a cold range, an exception handler or a
    // cleanup range starts or ends at. `isTarget` has one more element than
    // there are instructions.
    package void markScopeTargets(bool[] isTarget) {
        eachScopeIndex((ref size_t index) {
            if (index < isTarget.length)
                isTarget[index] = true;
        });
    }

    // Marks each instruction that control can reach from another place than
    // the instruction before it. `isTarget` has one more element than there
    // are instructions.
    package void markTargets(bool[] isTarget) {
        foreach (ref instruction; instructions) {
            if (instruction.handler is null)
                continue;
            if (auto field = branchTargetField(instruction))
                if (*field < isTarget.length)
                    isTarget[*field] = true;
        }
        markScopeTargets(isTarget);
    }


    // How the pass treats the operands of a handler.
    package static struct Access {
        enum Kind {
            // Not known well enough to change a field.
            opaque,
            // Reads its operands, then writes `destination` alone and reads
            // nothing from it.
            pureWriter,
            // Reads `destination` and writes it with a result of the same
            // width.
            inPlace,
            // Writes none of its storage operands.
            reader,
        }

        Kind kind;
        // Which fields name storage. A handler outside the role table may
        // name storage in every field.
        Operands roles;
        // The handler uses the address of its source, not its value.
        bool takesAddress;
        // `width` holds the frame offset of an index in its low 32 bits.
        bool widthIsSlot;
        // The role table knows the handler, so each operand names one object
        // of `width` bytes at most.
        bool known;
        // The width of a copy, or 0.
        size_t copyWidth;
        // The bytes that the handler touches through `destination` or
        // `source` whatever the width of the instruction, or 0.
        size_t destinationExtent;
        size_t sourceExtent;

        bool isWriter() const {
            return kind == Kind.pureWriter || kind == Kind.inPlace;
        }

        bool namesStorage(in Field field) const {
            final switch (field) {
                case Field.destination:
                    return roles.destination == Operand.storage;
                case Field.source:
                    return roles.source == Operand.storage;
                case Field.right:
                    return roles.right == Operand.storage;
            }
        }

        // The fields from which the handler only reads a value, as a bit
        // mask of `1 << Field`.
        uint readOnlyFields() const {
            if (kind == Kind.opaque || takesAddress)
                return 0;
            uint mask;
            foreach (field; allFields) {
                if (namesStorage(field)
                        && !(field == Field.destination && isWriter))
                    mask |= 1 << cast(int) field;
            }
            return mask;
        }
    }

    package static Access accessOf(in Instruction.Handler handler) {
        // A direct-mapped cache of `classify`, thread-local: a handler never
        // changes what it is.
        static struct Entry {
            Instruction.Handler handler;
            Access access;
        }
        enum entries = 256;
        static Entry[entries] cache;

        auto entry = &cache[(cast(size_t) handler >> 4) % entries];
        if (entry.handler !is handler) {
            entry.access = classify(handler);
            entry.handler = cast(Instruction.Handler) handler;
        }
        return entry.access;
    }

    package static Access classify(Instruction.Handler handler) {
        import std.meta: AliasSeq;

        Access access;
        access.known = inlineOperandsOf(handler, access.roles);
        if (!access.known) {
            enum S = Operand.storage;
            access.roles = Operands(S, S, S);
        }
        access.widthIsSlot = widthHoldsIndexSlot(handler);

        with (Access.Kind) {
            static foreach (operation; AliasSeq!(
                opConstant, opZero, opStaticLoad,
            ))
                if (handler is &operation)
                    access.kind = pureWriter;
            // These write an address.
            static foreach (operation; AliasSeq!(
                opFrameAddress, opIndexSlice, opIndexStatic, opIndexPointer,
            ))
                if (handler is &operation) {
                    access.kind = pureWriter;
                    access.destinationExtent = size_t.sizeof;
                }
            static foreach (width; copyWidths)
                if (handler is &opCopyFixed!width) {
                    access.kind = pureWriter;
                    access.copyWidth = width;
                }
            static foreach (width; indirectCopyWidths) {
                if (handler is &opLoadIndirectFixed!width) {
                    access.kind = pureWriter;
                    access.sourceExtent = size_t.sizeof;
                }
                if (handler is &opStoreIndirectFixed!width) {
                    access.kind = reader;
                    access.destinationExtent = size_t.sizeof;
                }
            }
            static foreach (kind; [
                CastKind.narrow, CastKind.widenSigned, CastKind.widenUnsigned,
            ])
                static foreach (destSize; [1UL, 2, 4, 8])
                    static foreach (sourceSize; [1UL, 2, 4, 8])
                        if (handler
                                is &opCastFixedAs!(kind, destSize, sourceSize)) {
                            access.kind = pureWriter;
                            access.destinationExtent = destSize;
                            access.sourceExtent = sourceSize;
                        }
            static foreach (index, operation; threeAddressHandlers) {
                if (handler is &operation
                        || handler is &threeAddressConstantHandlers[index]) {
                    access.kind = pureWriter;
                    // A comparison writes one byte whatever its operand
                    // width.
                    static if (index >= firstComparisonHandler)
                        access.destinationExtent = 1;
                }
            }
            static foreach (operation; AliasSeq!(
                opAdd, opSubtract, opMultiply, opBitAnd, opBitOr, opBitXor,
                opShiftLeft, opShiftRightLogical, opShiftRightArithmetic,
                opNegate, opComplement, opLogicalNot, opCastToBool,
                opFloatAdd, opFloatSubtract, opFloatMultiply, opFloatDivide,
                opFloatNegate,
            ))
                if (handler is &operation)
                    access.kind = inPlace;
            static foreach (operation; AliasSeq!(
                opReturn, opBranchFalse, opBranchTrue,
            ))
                if (handler is &operation)
                    access.kind = reader;
            if (isFusedBranch(handler))
                access.kind = reader;
        }
        // The address of the operand matters, not only its value.
        static foreach (operation; AliasSeq!(
            opFrameAddress, opIndexSlice, opIndexStatic, opIndexPointer,
        ))
            if (handler is &operation)
                access.takesAddress = true;
        return access;
    }

    package enum copyWidths = [1, 2, 4, 8, 16];

    package static immutable Field[3] allFields = [
        Field.destination, Field.source, Field.right,
    ];

    // The bytes that a writer writes to `destination`.
    package static size_t writtenSize(
        in Instruction instruction, in Access access,
    ) {
        return access.destinationExtent != 0
            ? access.destinationExtent : instruction.width;
    }

    // The bytes that an instruction reads or writes through `field`. A
    // handler outside the role table is assumed to touch one object at the
    // field's base.
    package static size_t extentOf(
        in Instruction instruction, in Access access, in Field field,
    ) {
        if (field == Field.destination && access.destinationExtent != 0)
            return access.destinationExtent;
        if (field == Field.source && access.sourceExtent != 0)
            return access.sourceExtent;
        if (!access.known || access.takesAddress)
            return 1;
        return instruction.width == 0 ? 1 : instruction.width;
    }

    package static ref size_t operandOf(ref Instruction instruction, in Field field) {
        final switch (field) {
            case Field.destination: return instruction.destination;
            case Field.source: return instruction.source;
            case Field.right: return instruction.sourceWidth;
        }
    }

    package static bool overlaps(
        in size_t a, in size_t aWidth, in size_t b, in size_t bWidth,
    ) {
        return a < b + bWidth && b < a + aWidth;
    }

    // The analysis state of copy forwarding: for each temporary, how many
    // accesses overlap it.
    package static struct CopyForwarding {
        Instruction[] instructions;
        // The temporaries, in increasing order of offset, and their sizes.
        const(size_t)[] starts;
        const(size_t)[] sizes;
        long[] counts;
        // The end of the last temporary.
        size_t tempsEnd;
        // An instruction that control may enter from outside the previous one.
        const(bool)[] isTarget;

        this(
            Instruction[] instructions, const(size_t)[] starts,
            const(size_t)[] sizes, const(bool)[] isTarget,
        ) {
            this.instructions = instructions;
            this.starts = starts;
            this.sizes = sizes;
            this.isTarget = isTarget;
            tempsEnd = starts[$ - 1] + sizes[$ - 1];
            counts = new long[starts.length];
            foreach (ref instruction; instructions)
                if (instruction.handler !is null)
                    adjust(instruction, 1);
        }

        void run() {
            foreach (index; 1 .. instructions.length) {
                if (instructions[index].handler is null || isTarget[index])
                    continue;
                if (redirectProducer(index))
                    continue;
                forwardSource(index);
            }
        }

        // Adds `delta` to every temporary that the `extent` bytes from `base`
        // overlap, or to the temporary at the address slot of an indirect
        // `base`.
        void count(in size_t base, in size_t extent, in long delta) {
            if (!isFrameOperand(base)) {
                countFrame(addressSlotOf(base), size_t.sizeof, delta);
                return;
            }
            countFrame(base, extent, delta);
        }

        package void countFrame(
            in size_t base, in size_t extent, in long delta,
        ) {
            if (base >= tempsEnd || base + extent <= starts[0])
                return;
            // The first temporary that ends after `base`.
            size_t low;
            size_t high = starts.length;
            while (low < high) {
                const middle = (low + high) / 2;
                if (starts[middle] + sizes[middle] <= base)
                    low = middle + 1;
                else
                    high = middle;
            }
            const end = base + extent;
            for (size_t at = low; at < starts.length && starts[at] < end; ++at)
                counts[at] += delta;
        }

        // Counts or uncounts every access of `instruction`.
        package void adjust(ref Instruction instruction, in long delta) {
            const access = accessOf(instruction.handler);
            foreach (field; allFields) {
                if (access.namesStorage(field))
                    count(operandOf(instruction, field),
                        extentOf(instruction, access, field), delta);
            }
            if (access.widthIsSlot)
                countFrame(cast(uint) instruction.width, size_t.sizeof, delta);
        }

        package void set(
            ref Instruction instruction, in Field field, in size_t value,
        ) {
            adjust(instruction, -1);
            operandOf(instruction, field) = value;
            adjust(instruction, 1);
        }

        package void drop(ref Instruction instruction) {
            adjust(instruction, -1);
            instruction.handler = null;
        }

        // The index into `starts` of the temporary at `offset`, or the
        // length of `starts`.
        package size_t tempAt(in size_t offset) const {
            size_t low;
            size_t high = starts.length;
            while (low < high) {
                const middle = (low + high) / 2;
                if (starts[middle] < offset)
                    low = middle + 1;
                else
                    high = middle;
            }
            return low < starts.length && starts[low] == offset
                ? low : starts.length;
        }

        // The size of the temporary at `offset`, or 0.
        package size_t sizeOf(in size_t offset) const {
            const at = tempAt(offset);
            return at == starts.length ? 0 : sizes[at];
        }

        // How many accesses overlap the temporary at `offset`.
        package long mentions(in size_t offset) const {
            const at = tempAt(offset);
            return at == starts.length ? 0 : counts[at];
        }

        // The number of fields of `instruction` that have `temp` as base or
        // as address slot.
        package size_t fieldsNaming(ref Instruction instruction, in size_t temp) {
            const access = accessOf(instruction.handler);
            size_t found;
            foreach (field; allFields) {
                if (!access.namesStorage(field))
                    continue;
                const operand = operandOf(instruction, field);
                if ((isFrameOperand(operand) ? operand : addressSlotOf(operand))
                        == temp)
                    ++found;
            }
            return found;
        }

        // `copy` empties a temporary that a run of earlier instructions
        // fills. The run is one pure writer, then in-place operations on the
        // same temporary, with constants loaded in between. They write the
        // destination of the copy, and the copy goes.
        package bool redirectProducer(in size_t copyIndex) {
            auto copy = &instructions[copyIndex];
            const width = accessOf(copy.handler).copyWidth;
            if (width == 0 || width > size_t.sizeof)
                return false;
            const temp = copy.source;
            const destination = copy.destination;
            const direct = isFrameOperand(destination);
            if (!isFrameOperand(temp) || sizeOf(temp) != width
                    || destination == temp
                    || (direct && overlaps(destination, width, temp, width)))
                return false;

            // One mention of the temporary is the copy.
            long need = mentions(temp);
            if (need < 2)
                return false;
            --need;
            size_t[] run;
            size_t writer = size_t.max;
            enum maxScan = 16;
            for (size_t at = copyIndex; at > 0 && copyIndex - at < maxScan;) {
                --at;
                auto candidate = &instructions[at];
                if (candidate.handler is null || isTarget[at + 1])
                    return false;
                const found = fieldsNaming(*candidate, temp);
                if (found == 0) {
                    // Only a load of a constant to a frame slot elsewhere may
                    // sit in between. It is not between an indirect
                    // destination and its writer: it could write the address
                    // slot or the pointee.
                    if (!direct
                            || (candidate.handler !is &opConstant
                                && candidate.handler !is &opZero)
                            || !isFrameOperand(candidate.destination)
                            || overlaps(candidate.destination, candidate.width,
                                destination, width))
                        return false;
                    continue;
                }
                if (found != 1 || need == 0)
                    return false;
                --need;
                const access = accessOf(candidate.handler);
                if (candidate.destination == temp
                        && access.kind == Access.Kind.pureWriter
                        && writtenSize(*candidate, access) == width) {
                    if (need != 0)
                        return false;
                    writer = at;
                    break;
                }
                if (candidate.destination != temp
                        || access.kind != Access.Kind.inPlace
                        || candidate.width != width
                        || !readsAwayFrom(*candidate, access, temp,
                            destination, width))
                    return false;
                run ~= at;
            }
            if (writer == size_t.max)
                return false;

            auto first = &instructions[writer];
            if (!direct && (run.length != 0
                    || !decodesIndirect(first.handler, Field.destination)))
                return false;
            // A copy now writes over a source that it reads, which a copy
            // through the temporary did not.
            if (accessOf(first.handler).copyWidth != 0
                    && partlyOverlaps(first.source, destination, width))
                return false;

            set(*first, Field.destination, destination);
            foreach (at; run)
                set(instructions[at], Field.destination, destination);
            drop(*copy);
            return true;
        }

        // Whether every frame operand that `instruction` reads besides
        // `destination` is a plain frame offset away from both `temp` and
        // the `width` bytes at `destination`.
        package bool readsAwayFrom(
            ref Instruction instruction, in Access access, in size_t temp,
            in size_t destination, in size_t width,
        ) {
            foreach (field; [Field.source, Field.right]) {
                if (!access.namesStorage(field))
                    continue;
                const operand = operandOf(instruction, field);
                if (!isFrameOperand(operand) || operand == temp
                        || overlaps(operand, width, destination, width))
                    return false;
            }
            return true;
        }

        // Whether `source` partly overlaps the `width` bytes at
        // `destination`, which a copy cannot do and a copy through a
        // temporary could.
        package static bool partlyOverlaps(
            in size_t source, in size_t destination, in size_t width,
        ) {
            return isFrameOperand(source) && isFrameOperand(destination)
                && source != destination
                && overlaps(source, width, destination, width);
        }

        // A cast in place over a temporary that a copy has just filled
        // writes all of it, so the copy is dead once the cast reads the
        // copy's source.
        package bool forwardIntoCast(
            ref Instruction producer, ref Instruction consumer,
            in size_t temp, in size_t value, in size_t width, in size_t size,
        ) {
            static foreach (kind; [
                CastKind.narrow, CastKind.widenSigned, CastKind.widenUnsigned,
            ])
                static foreach (destSize; [1UL, 2, 4, 8])
                    static foreach (sourceSize; [1UL, 2, 4, 8])
                        if (consumer.handler
                                is &opCastFixedAs!(kind, destSize, sourceSize)) {
                            if (consumer.destination != temp
                                    || consumer.source != temp
                                    || width != sourceSize
                                    || destSize != size
                                    || (!isFrameOperand(value)
                                        && !decodesIndirect(consumer.handler,
                                            Field.source)))
                                return false;
                            set(consumer, Field.source, value);
                            drop(producer);
                            return true;
                        }
            return false;
        }

        // `producer` copies a temporary that the next instruction reads. That
        // instruction reads the copy's source instead, and the copy goes.
        package bool forwardSource(in size_t consumerIndex) {
            auto producer = &instructions[consumerIndex - 1];
            auto consumer = &instructions[consumerIndex];
            const width = accessOf(producer.handler).copyWidth;
            if (width == 0)
                return false;
            const temp = producer.destination;
            const value = producer.source;
            const size = sizeOf(temp);
            if (!isFrameOperand(temp) || size < width)
                return false;
            // The copy of a wide value feeds a return alone.
            if (width > size_t.sizeof && consumer.handler !is &opReturn)
                return false;

            if (forwardIntoCast(*producer, *consumer, temp, value, width, size))
                return true;

            const access = accessOf(consumer.handler);
            const readOnly = access.readOnlyFields;
            long named;
            Field[3] patched;
            size_t patchedCount;
            foreach (field; allFields) {
                if (!access.namesStorage(field))
                    continue;
                const current = operandOf(*consumer, field);
                const isSlot = !isFrameOperand(current);
                if ((isSlot ? addressSlotOf(current) : current) != temp)
                    continue;
                ++named;
                if (isSlot) {
                    // An address slot read by a handler that decodes operands.
                    if (access.kind == Access.Kind.opaque
                            || !isFrameOperand(value)
                            || size_t.sizeof > width)
                        return false;
                } else if (field == Field.destination
                        && access.kind == Access.Kind.pureWriter) {
                    // The consumer overwrites the temporary.
                    continue;
                } else {
                    if (!(readOnly & (1 << cast(int) field))
                            || extentOf(*consumer, access, field) > width)
                        return false;
                    if (!isFrameOperand(value)
                            && !decodesIndirect(consumer.handler, field))
                        return false;
                }
                patched[patchedCount++] = field;
            }
            if (patchedCount == 0 || mentions(temp) != 1 + named)
                return false;
            // The consumer writes where it now reads, which a copy through
            // the temporary did not allow.
            if (access.copyWidth != 0
                    && partlyOverlaps(value, consumer.destination,
                        consumer.width))
                return false;

            foreach (field; patched[0 .. patchedCount]) {
                const current = operandOf(*consumer, field);
                set(*consumer, field, isFrameOperand(current)
                    ? value : withAddressSlot(current, value));
            }
            drop(*producer);
            return true;
        }
    }

    package void fuseLoadCopies() {
        foreach (index, ref instruction; instructions) {
            if (index + 1 == instructions.length)
                break;
            const next = &instructions[index + 1];
            // Keep both writes and the separate copy as a branch target.
            static foreach (loadWidth; indirectCopyWidths) {
                if (instruction.handler is &opLoadIndirectFixed!loadWidth) {
                    static foreach (copyWidth; [1, 2, 4, 8, 16]) {
                        if (next.handler is &opCopyFixed!copyWidth)
                            instruction.handler = &opLoadThenCopy!(
                                loadWidth, copyWidth);
                    }
                }
            }
        }
    }

    package void fuseReturns() {
        import std.meta: AliasSeq;

        foreach (index, ref instruction; instructions) {
            if (index + 1 == instructions.length)
                break;
            const next = &instructions[index + 1];
            if (next.handler !is &opReturn
                    || next.source != instruction.destination
                    || next.width != instruction.width)
                continue;

            // Keep the separate return as a possible branch target. The
            // fused path must still write the producer's destination.
            static foreach (operation; AliasSeq!(
                opConstant, opCopy, opLoadIndirect, opFrameAddress,
                opCopyFixed!1, opCopyFixed!2, opCopyFixed!4,
                opCopyFixed!8, opCopyFixed!16,
            )) {
                if (instruction.handler is &operation)
                    instruction.handler = &opThenReturn!operation;
            }
            static foreach (width; indirectCopyWidths) {
                if (instruction.handler is &opLoadIndirectFixed!width)
                    instruction.handler = &opThenReturn!(opLoadIndirectFixed!width);
            }
            static foreach (width; 1 .. 17) {
                if (instruction.handler is &opCopyFixed!(width, true))
                    instruction.handler = &opThenReturn!(
                        opCopyFixed!(width, true));
            }
        }
    }

    // Empty lifetimes have no runtime work. Remove their placeholders
    // before indices become pointers, including exception and cleanup bounds.
    package void removeEmptyLifetimes() {
        auto offsets = new size_t[instructions.length + 1];
        size_t count;
        foreach (index, instruction; instructions) {
            offsets[index] = count;
            if (instruction.handler !is null) {
                instructions[count++] = instruction;
            }
        }
        offsets[$ - 1] = count;
        instructions.length = count;

        foreach (ref reloc; relocs)
            if (reloc.place.section == Place.Section.instruction)
                reloc.place.index = offsets[reloc.place.index];

        foreach (ref instruction; instructions) {
            auto target = branchTargetField(instruction);
            if (target !is null)
                *target = offsets[*target];
        }
        eachScopeIndex((ref size_t index) {
            index = offsets[index];
        });
    }

}
