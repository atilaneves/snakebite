module snakebite.backends.bytecode.jitflow;

private:

import snakebite.backends.bytecode.jit: jitSupported;

static if (jitSupported):

import snakebite.backends.bytecode.jit: JitOp;
import snakebite.backends.bytecode.vm: addressSlotOf, CompareKind, Comparison,
    Function, IndexBase, indirectBit, Instruction, opFloatSqrt;
import snakebite.native.value: arrayPointerOffset;

package struct ScalarProgram {
    @nogc nothrow:

    enum instructionLimit = 192;
    enum slotLimit = 192;
    enum none = ushort.max;
    enum fp0 = none - 1;
    enum r0 = none - 2;

    enum Kind : ubyte {
        exit, move, integer, floating, sqrt, index, compare, branch, jump,
        returnValue, returnVoid,
    }

    enum Mode : ubyte { unused, frame, indirect, literal, address, register, temporary }

    static struct Operand {
        Mode mode;
        ubyte width;
        uint offset;
        size_t word;

        Operand displaced(uint bytes) const @nogc nothrow {
            Operand result = this;
            if (mode == Mode.indirect)
                result.offset += bytes;
            else
                result.word += bytes;
            return result;
        }
    }

    static struct Operation {
        Kind kind;
        JitOp.IntOperation integer;
        JitOp.FloatOperation floating;
        CompareKind compareKind;
        Comparison comparison;
        bool jumpWhen;
        ushort next = none;
        ushort target = none;
        uint stride;
        Operand output;
        Operand left;
        Operand right;
    }

    static struct Slot {
        ushort offset;
        ubyte width;
        bool isTemporary;
    }

    Operation[instructionLimit] operations;
    Slot[slotLimit] slots;
    ushort slotCount;
    ushort length;
    ushort frameSize;

    bool read(const(Function)* function_, const(Instruction)[] instructions,
        const(JitOp)[] ops)
    {
        if (instructions.length == 0 || instructions.length > instructionLimit
                || function_.frameSize >= r0 || function_.closureOffset != size_t.max
                || function_.exceptionHandlers.length)
            return false;
        length = cast(ushort) instructions.length;
        frameSize = cast(ushort) function_.frameSize;
        slotCount = 0;
        foreach (pc; 0 .. length) {
            auto step = decode(function_, instructions[pc], ops[pc]);
            with (Kind) {
                if (step.kind != exit && step.kind != jump
                        && step.kind != returnValue && step.kind != returnVoid) {
                    if (pc + 1 == length)
                        return false;
                    step.next = cast(ushort) (pc + 1);
                }
            }
            operations[pc] = step;
        }
        return true;
    }

    ushort newTemporary(ubyte width) {
        if (slotCount == slotLimit)
            return none;
        const slot = slotCount++;
        slots[slot] = Slot(0, width, true);
        return slot;
    }

    ushort findSlot(size_t offset, ubyte width) const {
        foreach (index, ref const slot; slots[0 .. slotCount])
            if (!slot.isTemporary && slot.offset == offset && slot.width == width)
                return cast(ushort) index;
        return none;
    }

    ushort slotOf(in Operand operand) {
        return operand.mode == Mode.temporary ? cast(ushort) operand.word
            : slotOf(operand.word, operand.width);
    }

    ushort slotOf(size_t offset, ubyte width) {
        if (offset != fp0 && offset != r0
                && (offset >= frameSize || width > frameSize - offset))
            return none;
        const existing = findSlot(offset, width);
        if (existing != none)
            return existing;
        if (slotCount == slotLimit)
            return none;
        const index = slotCount++;
        slots[index] = Slot(cast(ushort) offset, width);
        return index;
    }

    private static Operation decode(const(Function)* function_,
        ref const Instruction ins, ref const JitOp op)
    {
        const width = op.width ? op.width : ins.width;
        Operation step;
        Operand storage(size_t raw, size_t bytes) {
            if (!scalarWidth(bytes) && bytes != 16)
                return Operand.init;
            const size = cast(ubyte) bytes;
            if (!(raw & indirectBit))
                return raw < function_.frameSize && bytes <= function_.frameSize - raw
                    ? Operand(Mode.frame, size, 0, raw) : Operand.init;
            const slot = addressSlotOf(raw);
            return slot < function_.frameSize && size_t.sizeof <= function_.frameSize - slot
                && cast(uint) raw <= int.max - bytes
                ? Operand(Mode.indirect, size, cast(uint) raw, slot) : Operand.init;
        }
        Operand input(size_t raw, size_t bytes, bool constant) {
            return constant ? literal(raw, bytes) : storage(raw, bytes);
        }
        Operand dereference(size_t raw, size_t bytes) {
            const base = storage(raw, size_t.sizeof);
            return base.mode == Mode.frame && (scalarWidth(bytes) || bytes == 16)
                ? Operand(Mode.indirect, cast(ubyte) bytes, 0, base.word) : Operand.init;
        }
        Operand address(size_t offset) {
            return offset < function_.frameSize
                ? Operand(Mode.address, size_t.sizeof, 0, offset) : Operand.init;
        }
        Operand reg(ushort id, size_t bytes = ulong.sizeof) {
            return Operand(Mode.register, cast(ubyte) bytes, 0, id);
        }
        ushort target(size_t address) {
            const start = cast(size_t) function_.instructions.ptr;
            const distance = address - start;
            return address >= start && distance / Instruction.sizeof < function_.instructions.length
                && distance % Instruction.sizeof == 0
                ? cast(ushort) (distance / Instruction.sizeof) : none;
        }

        switch (op.kind) with (JitOp.Kind) {
        case copy:
            if (op.copy.staticSource && ins.sourceWidth != Instruction.immutableSource)
                return Operation.init;
            step = Operation(Kind.move, output: storage(ins.destination, width),
                left: input(ins.source, width, op.copy.staticSource));
            break;
        case constant, zero:
            if (!scalarWidth(width) || (op.kind == constant
                    && ins.source >= function_.constants.length))
                return Operation.init;
            const bits = op.kind == zero ? 0 : cast(ulong) function_.constants[ins.source];
            step = Operation(Kind.move, output: storage(ins.destination, width),
                left: Operand(Mode.literal, cast(ubyte) width, 0, bits & maskOf(width)));
            break;
        case frameAddr:
            step = Operation(Kind.move, output: storage(ins.destination, size_t.sizeof),
                left: address(ins.source));
            break;
        case loadInd:
            step = Operation(Kind.move, output: storage(ins.destination, width),
                left: dereference(ins.source, width));
            break;
        case storeInd:
            step = Operation(Kind.move, output: dereference(ins.destination, width),
                left: storage(ins.source, width));
            break;
        case index:
            if (!ins.width || ins.width > int.max)
                return Operation.init;
            step.kind = Kind.index;
            step.output = storage(ins.destination, size_t.sizeof);
            step.right = storage(ins.sourceWidth, size_t.sizeof);
            step.stride = cast(uint) ins.width;
            final switch (op.index.base) with (IndexBase) {
            case slice:
                step.left = storage(ins.source, 2 * size_t.sizeof).displaced(arrayPointerOffset);
                step.left.width = size_t.sizeof;
                break;
            case staticArray: step.left = address(ins.source); break;
            case pointer: step.left = storage(ins.source, size_t.sizeof); break;
            }
            break;
        case int3:
            if (!scalarWidth(width))
                return Operation.init;
            step.kind = Kind.integer;
            step.integer = op.int3.operation;
            step.output = op.int3.resultInR0 ? reg(r0) : storage(ins.destination, width);
            step.left = op.int3.leftInR0 ? reg(r0, width)
                : storage(op.int3.twoAddress ? ins.destination : ins.source, width);
            step.right = input(op.int3.twoAddress ? ins.source : ins.sourceWidth,
                width, op.int3.constantRight);
            break;
        case cmp3:
            if (!scalarWidth(width))
                return Operation.init;
            step.kind = Kind.compare;
            step.output = storage(ins.destination, 1);
            step.left = storage(op.cmp3.twoAddress ? ins.destination : ins.source, width);
            step.right = input(op.cmp3.twoAddress ? ins.source : ins.sourceWidth,
                width, op.cmp3.constantRight);
            step.compareKind = op.cmp3.signed ? CompareKind.signed : CompareKind.unsigned;
            step.comparison = op.cmp3.comparison;
            break;
        case fp3:
            if (width != float.sizeof && width != double.sizeof)
                return Operation.init;
            step.kind = Kind.floating;
            step.floating = op.fp3.operation;
            step.output = op.fp3.resultInFp0 ? reg(fp0) : storage(ins.destination, width);
            step.left = op.fp3.leftInFp0 ? reg(fp0) : storage(ins.source, width);
            step.right = input(ins.sourceWidth, width, op.fp3.constantRight);
            break;
        case none:
            version (LDC) {
                if (ins.handler is &opFloatSqrt && (width == double.sizeof
                        || width == float.sizeof)) {
                    step.kind = Kind.sqrt;
                    step.left = step.output = storage(ins.destination, width);
                    break;
                }
            }
            return Operation.init;
        case branch:
            if (!scalarWidth(width))
                return Operation.init;
            step.kind = Kind.branch;
            step.left = storage(ins.destination, width);
            step.right = Operand(Mode.literal, cast(ubyte) width);
            step.comparison = Comparison.notEqual;
            step.jumpWhen = op.branch.jumpIfNonzero;
            step.target = target(ins.source);
            break;
        case fused:
            if (!scalarWidth(width))
                return Operation.init;
            step.kind = Kind.branch;
            step.left = op.fused.leftInR0
                ? reg(op.fused.kind == CompareKind.floating ? fp0 : r0, width)
                : storage(ins.destination, width);
            step.right = input(ins.source, width, op.fused.constantRight);
            step.compareKind = op.fused.kind;
            step.comparison = op.fused.comparison;
            step.jumpWhen = op.fused.jumpWhen;
            step.target = target(ins.sourceWidth);
            break;
        case jump:
            step.kind = Kind.jump;
            step.target = target(ins.destination);
            break;
        case returnVoid:
            return Operation(Kind.returnVoid);
        case returnValue:
            if (!scalarWidth(width))
                return Operation.init;
            step.kind = Kind.returnValue;
            step.left = storage(ins.source, width);
            break;
        default:
            return Operation.init;
        }
        return valid(step) ? step : Operation.init;
    }
}

private bool valid(in ScalarProgram.Operation op) @nogc nothrow {
    with (ScalarProgram.Kind) {
        if ((op.kind == jump || op.kind == branch) && op.target == ScalarProgram.none)
            return false;
        if (op.kind != jump && op.left.mode == ScalarProgram.Mode.unused)
            return false;
        if ((op.kind == integer || op.kind == index || op.kind == compare
                || op.kind == floating || op.kind == branch)
                && op.right.mode == ScalarProgram.Mode.unused)
            return false;
        return op.kind == jump || op.kind == branch || op.kind == returnValue
            || op.output.mode != ScalarProgram.Mode.unused;
    }
}

private ScalarProgram.Operand literal(size_t address, size_t width) @nogc nothrow {
    import core.stdc.string: memcpy;

    if (!scalarWidth(width) || !address)
        return ScalarProgram.Operand.init;
    ulong bits;
    memcpy(&bits, cast(const(void)*) address, width);
    return ScalarProgram.Operand(ScalarProgram.Mode.literal, cast(ubyte) width, 0, bits);
}

private bool scalarWidth(size_t width) @nogc nothrow pure @safe {
    return width == 1 || width == 2 || width == 4 || width == 8;
}

private ulong maskOf(size_t width) @nogc nothrow pure @safe {
    return ulong.max >> ((ulong.sizeof - width) * 8);
}

package struct ScalarRanges {
    @nogc nothrow:

    alias Program = ScalarProgram;
    alias Operand = Program.Operand;
    alias Operation = Program.Operation;
    alias Mode = Program.Mode;
    alias Kind = Program.Kind;
    enum none = Program.none;
    enum frame = none - 1;
    enum number = none - 2;

    static struct Linear {
        long factor;
        long bias;
        ushort home = none;
        bool known;
    }

    static struct Value {
        ulong low;
        ulong high;
        ushort root = none;
        bool localBits;
        uint multiple = 1;
        Linear equation;
        Linear upper;

        bool exact() const @nogc nothrow { return root == number && low == high; }
    }

    static struct Memory {
        ushort root = none;
        uint first;
        uint end;
        uint multiple;
        uint displacement;
        ubyte width;

        bool disjoint(in Memory other) const @nogc nothrow {
            if (root == none || other.root == none)
                return false;
            if ((root == frame) != (other.root == frame))
                return true;
            if (root != other.root)
                return false;
            if (end <= other.first || other.end <= first)
                return true;
            const stride = gcd(multiple, other.multiple);
            if (!stride)
                return false;
            const difference = (cast(ulong) (other.displacement % stride) + stride
                - displacement % stride) % stride;
            return difference >= width && stride - difference >= other.width;
        }
    }

    static struct Span {
        uint first = uint.max;
        uint end;
    }

    static struct State {
        Value[Program.slotLimit] values;
        bool reached;
        ubyte backedgeChanges;
    }

    Program program;
    State[Program.instructionLimit] states;
    State working;
    State incomingEdge;
    State priorJoin;
    Operation[Program.instructionLimit] resolved;
    Span[Program.slotLimit] spans;
    bool[Program.instructionLimit] visited;
    ushort[Program.instructionLimit] memoryOrigin;
    ushort[Program.instructionLimit] predecessors;
    ushort length;
    bool hasFloats;
    bool hasLoop;

    bool analyze() {
        predecessors[] = 0;
        // The canonical entry supplies state independently of bytecode edges.
        predecessors[0] = 1;
        foreach (ref const step; program.operations[0 .. program.length]) {
            if (step.next != none)
                ++predecessors[step.next];
            if (step.target != none && step.target != step.next)
                ++predecessors[step.target];
        }
        // A frame address can discover a new scalar component during the
        // first pass. Repeat with the full set so that all overlapping
        // writes are present before results are used.
        while (true) {
            const slots = program.slotCount;
            states[0 .. program.length] = State.init;
            states[0].reached = true;
            bool changed;
            do {
                changed = false;
                foreach (pc; 0 .. program.length) {
                    if (!states[pc].reached)
                        continue;
                    working = states[pc];
                    auto step = program.operations[pc];
                    if (!transfer(step, working, false))
                        continue;
                    changed |= merge(pc, step.next, working);
                    changed |= merge(pc, step.target, working);
                }
                if (program.slotCount != slots)
                    break;
            } while (changed);
            if (program.slotCount == slots)
                break;
        }

        length = program.length;
        spans[] = Span.init;
        visited[] = false;
        hasFloats = false;
        hasLoop = false;
        ushort[Program.instructionLimit] queue;
        queue[0] = 0;
        visited[0] = true;
        size_t pending = 1;
        for (size_t head; head < pending; ++head) {
            const pc = queue[head];
            auto step = program.operations[pc];
            working = states[pc];
            if (!transfer(step, working, true)) {
                step = Operation.init;
            } else if (step.kind == Kind.jump) {
                step.left = step.right = Operand.init;
            } else {
                foldRead(step.left, states[pc]);
                foldRead(step.right, states[pc]);
            }
            resolved[pc] = step;
            memoryOrigin[pc] = pc;
            hasFloats |= step.kind == Kind.floating || step.kind == Kind.sqrt
                || (step.kind == Kind.branch && step.compareKind == CompareKind.floating);
            foreach (const target; [step.next, step.target]) {
                if (target == none)
                    continue;
                hasLoop |= target <= pc;
                if (!visited[target]) {
                    visited[target] = true;
                    queue[pending++] = target;
                }
            }
        }
        return hasLoop;
    }

    private void foldRead(ref Operand operand, ref State state) {
        if (operand.mode != Mode.frame || !scalarWidth(operand.width))
            return;
        const value = read(operand, state);
        if (value.exact && !value.localBits)
            operand = Operand(Mode.literal, operand.width, 0, value.low);
    }

    private bool transfer(ref Operation step, ref State state, bool record) {
        // Resolve addresses against the incoming state before evaluating or
        // writing any field, just as the instruction decoder does.
        if (step.kind == Kind.exit)
            return false;
        if (!resolve(step.left, state, record) || !resolve(step.right, state, record)
                || !resolve(step.output, state, record))
            return false;
        if (step.kind == Kind.jump || step.kind == Kind.returnVoid || step.kind == Kind.returnValue)
            return true;

        if (step.kind == Kind.move && step.left.width == 16) {
            if (step.left.mode != Mode.frame || step.output.mode != Mode.frame)
                return false;
            Operand left = step.left;
            Operand output = step.output;
            left.width = output.width = ulong.sizeof;
            const a = read(left, state);
            const b = read(left.displaced(ulong.sizeof), state);
            return write(output, a, state) && write(output.displaced(ulong.sizeof), b, state);
        }
        const left = read(step.left, state);
        const right = read(step.right, state);
        const width = step.left.width;
        auto result = unknown(step.output.width);
        final switch (step.kind) with (Kind) {
        case exit, jump, returnVoid, returnValue:
            break;
        case move:
            result = left;
            break;
        case integer:
            result = arithmetic(step.integer, left, right, step.right.width);
            break;
        case floating, sqrt:
            break;
        case index:
            const scaled = arithmetic(JitOp.IntOperation.multiply, right,
                Value(step.stride, step.stride, number), ulong.sizeof);
            result = arithmetic(JitOp.IntOperation.add, left, scaled, ulong.sizeof);
            // A bound on the index can cancel the variable part of the
            // base. The sub-slice pointer and length can depend on the same
            // value even when neither offset nor index has a tight range.
            const bound = addLinear(formOf(left), scaleLinear(right.upper, step.stride));
            if (bound.known && bound.home == none && bound.bias >= 0
                    && cast(ulong) bound.bias < result.high
                    && cast(ulong) bound.bias >= result.low)
                result.high = cast(ulong) bound.bias;
            break;
        case compare:
            result = compareValues(left, right, step.comparison, step.compareKind, width);
            break;
        case branch:
            const test = compareValues(left, right, step.comparison, step.compareKind, width);
            if (test.exact()) {
                const taken = (test.low != 0) == step.jumpWhen;
                if (!taken)
                    step.target = step.next;
                step.next = none;
                step.kind = jump;
            }
            return true;
        }
        if (step.output.mode == Mode.indirect && result.localBits)
            return false;
        return write(step.output, result, state);
    }

    private bool resolve(ref Operand operand, ref State state, bool record) {
        if (operand.mode != Mode.indirect)
            return true;
        const slot = program.slotOf(operand.word, size_t.sizeof);
        if (slot == none)
            return false;
        const address = read(Operand(Mode.frame, size_t.sizeof, 0, operand.word), state);
        if (address.root == frame && address.low == address.high) {
            if (address.low >= program.frameSize || operand.offset > program.frameSize - address.low
                    || operand.width > program.frameSize - address.low - operand.offset)
                return false;
            operand = Operand(Mode.frame, operand.width, 0, address.low + operand.offset);
            return true;
        }
        if (address.root >= program.slotCount || address.localBits
                || address.high > int.max - operand.offset - operand.width)
            return false;
        if (record) {
            ref span = spans[address.root];
            const first = cast(uint) address.low + operand.offset;
            const end = cast(uint) address.high + operand.offset + operand.width;
            if (first < span.first)
                span.first = first;
            if (end > span.end)
                span.end = end;
        }
        return true;
    }

    private Value read(in Operand operand, ref State state) {
        final switch (operand.mode) with (Mode) {
        case unused, indirect, temporary:
            return unknown(operand.width);
        case literal:
            return Value(operand.word, operand.word, number);
        case address:
            return Value(operand.word, operand.word, ScalarRanges.frame, true);
        case frame, register:
            const slot = program.slotOf(operand.word, operand.width);
            if (slot == none)
                return unknown(operand.width);
            auto value = actual(state.values[slot], slot);
            if (value.root == number && !value.exact && !value.equation.known)
                value.equation = Linear(1, 0, slot, true);
            return value;
        }
    }

    private bool write(in Operand operand, in Value value, ref State state) {
        if (operand.mode == Mode.indirect)
            return true;
        const slot = program.slotOf(operand.word, operand.width);
        if (slot == none)
            return false;
        Value stored = value;
        clearRelationships(stored, operand);
        foreach (other, ref const home; program.slots[0 .. program.slotCount]) {
            clearRelationships(state.values[other], operand);
            if (other != slot && overlaps(home, operand)) {
                auto invalidated = unknown(home.width);
                invalidated.localBits = value.localBits || state.values[other].localBits;
                state.values[other] = invalidated;
            }
        }
        state.values[slot] = stored;
        return true;
    }

    private void clearRelationships(ref Value value, in Operand written) const {
        if (value.equation.home != none && overlaps(program.slots[value.equation.home], written))
            value.equation = Linear.init;
        if (value.upper.home != none && overlaps(program.slots[value.upper.home], written))
            value.upper = Linear.init;
    }

    private static bool overlaps(in Program.Slot home, in Operand operand) {
        return operand.word == home.offset || (operand.word < Program.r0
            && home.offset < Program.r0 && operand.word < home.offset + home.width
            && home.offset < operand.word + operand.width);
    }

    private bool merge(size_t pc, ushort target, ref State state) {
        if (target == none)
            return false;
        ref destination = states[target];
        ref incoming = incomingEdge;
        incoming = state;
        const step = program.operations[pc];
        if (step.kind == Kind.branch && step.next != step.target && !refine(step,
                (step.target == target) == step.jumpWhen, incoming))
            return false;
        incoming.backedgeChanges = 0;
        if (!destination.reached || predecessors[target] == 1) {
            if (destination == incoming)
                return false;
            destination = incoming;
            return true;
        }
        priorJoin = destination;
        bool changed;
        foreach (slot; 0 .. program.slotCount) {
            ref current = destination.values[slot];
            if (current == incoming.values[slot])
                continue;
            const a = actual(current, cast(ushort) slot);
            const b = actual(incoming.values[slot], cast(ushort) slot);
            const width = program.slots[slot].width;
            auto joined = a.root == b.root
                ? Value(a.low < b.low ? a.low : b.low, a.high > b.high ? a.high : b.high,
                    a.root) : unknown(width);
            if (target <= pc && destination.backedgeChanges >= 4) {
                if (joined.low < a.low)
                    joined.low = 0;
                if (joined.high > a.high)
                    joined.high = maskOf(width);
            }
            if (joined.root == a.root && joined.root == b.root) {
                joined.multiple = gcd(multipleOf(a), multipleOf(b));
                if (a.equation == b.equation || satisfies(b, a.equation, incoming, false))
                    joined.equation = a.equation;
                else if (satisfies(a, b.equation, priorJoin, false))
                    joined.equation = b.equation;
                if (a.upper == b.upper || satisfies(b, a.upper, incoming, true))
                    joined.upper = a.upper;
                else if (satisfies(a, b.upper, priorJoin, true))
                    joined.upper = b.upper;
            }
            joined.localBits = a.localBits || b.localBits;
            if (joined != a) {
                current = joined;
                changed = true;
            }
        }
        if (changed && target <= pc && destination.backedgeChanges != ubyte.max)
            ++destination.backedgeChanges;
        return changed;
    }

    private bool satisfies(in Value value, in Linear relationship, in State state,
        bool upperBound) const
    {
        import core.checkedint: adds, muls;

        if (!relationship.known)
            return false;
        long limit = relationship.bias;
        if (relationship.home != none) {
            const atom = actual(state.values[relationship.home], relationship.home);
            if (atom.root != number || atom.high > long.max
                    || (!upperBound && !atom.exact))
                return false;
            const endpoint = relationship.factor < 0 ? atom.high : atom.low;
            bool overflow;
            const variable = muls(relationship.factor, cast(long) endpoint, overflow);
            limit = adds(limit, variable, overflow);
            if (overflow)
                return false;
        }
        if (limit < 0)
            return false;
        return upperBound ? value.high <= cast(ulong) limit
            : value.low == value.high && value.low == cast(ulong) limit;
    }

    private bool refine(in Operation op, bool whenTrue, ref State state) {
        if (op.compareKind == CompareKind.floating)
            return true;
        const a = read(op.left, state);
        const b = read(op.right, state);
        const width = op.left.width;
        const predicate = compareValues(a, b, op.comparison, op.compareKind, width);
        if (predicate.exact())
            return (predicate.low != 0) == whenTrue;
        if (a.root != number || b.root != number
                || (op.compareKind == CompareKind.signed && (a.high | b.high) > maskOf(width) / 2))
            return true;

        Value left = a;
        Value right = b;
        auto cmp = whenTrue ? op.comparison : inverted(op.comparison);
        switch (cmp) with (Comparison) {
        case greaterThan, greaterOrEqual:
            if (!limit(right, left, cmp == greaterThan))
                return false;
            break;
        case lessThan, lessOrEqual:
            if (!limit(left, right, cmp == lessThan))
                return false;
            break;
        case equal:
            if (!limit(left, right, false) || !limit(right, left, false))
                return false;
            break;
        case notEqual:
            return true;
        default:
            return true;
        }
        if ((op.left.mode == Mode.frame || op.left.mode == Mode.register) && left != a) {
            const slot = program.slotOf(op.left.word, op.left.width);
            if (slot != none)
                state.values[slot] = left;
        }
        if ((op.right.mode == Mode.frame || op.right.mode == Mode.register) && right != b) {
            const slot = program.slotOf(op.right.word, op.right.width);
            if (slot != none)
                state.values[slot] = right;
        }
        return true;
    }

    private Value actual(in Value value, ushort slot) const {
        if (value.root != none)
            return value;
        ref const home = program.slots[slot];
        if (home.width == size_t.sizeof && home.offset < program.frameSize)
            return Value(0, 0, slot);
        return unknown(home.width);
    }

    private static Value unknown(size_t width) {
        return Value(0, width == 0 || width > ulong.sizeof ? ulong.max : maskOf(width), number);
    }

    private static Value arithmetic(JitOp.IntOperation op, Value left, Value right, size_t width) {
        import core.checkedint: addu, mulu;

        const maximum = maskOf(width);
        auto result = unknown(width);
        result.localBits = left.localBits || right.localBits;

        if (op == JitOp.IntOperation.add && right.root != number) {
            const saved = left;
            left = right;
            right = saved;
        }
        if (right.root != number || (left.root != number && (width != ulong.sizeof
                || (op != JitOp.IntOperation.add && op != JitOp.IntOperation.subtract))))
            return result;
        if (left.exact && right.exact) {
            ulong bits;
            final switch (op) with (JitOp.IntOperation) {
            case add: bits = left.low + right.low; break;
            case subtract: bits = left.low - right.low; break;
            case multiply: bits = left.low * right.low; break;
            case and: bits = left.low & right.low; break;
            case or: bits = left.low | right.low; break;
            case xor: bits = left.low ^ right.low; break;
            }
            bits &= maximum;
            return Value(bits, bits, number, result.localBits);
        }

        ulong low, high;
        bool overflow;
        switch (op) with (JitOp.IntOperation) {
        case add:
            high = addu(left.high, right.high, overflow);
            low = left.low + right.low;
            break;
        case subtract:
            if (left.low < right.high)
                return result;
            low = left.low - right.high;
            high = left.high - right.low;
            break;
        case multiply:
            high = mulu(left.high, right.high, overflow);
            low = left.low * right.low;
            break;
        default:
            return result;
        }
        if (!overflow && high <= maximum) {
            result = Value(low, high, left.root, result.localBits);
            if (op == JitOp.IntOperation.multiply) {
                const product = cast(ulong) multipleOf(left) * multipleOf(right);
                if (product <= uint.max)
                    result.multiple = cast(uint) product;
                if (left.exact && left.low <= long.max)
                    result.equation = scaleLinear(formOf(right), cast(long) left.low);
                else if (right.exact && right.low <= long.max)
                    result.equation = scaleLinear(formOf(left), cast(long) right.low);
            } else {
                result.multiple = gcd(multipleOf(left), multipleOf(right));
                const rightForm = formOf(right);
                result.equation = addLinear(formOf(left),
                    op == JitOp.IntOperation.subtract ? scaleLinear(rightForm, -1) : rightForm);
            }
        }
        return result;
    }

    private static Linear formOf(in Value value) {
        if (value.low == value.high && value.low <= long.max)
            return Linear(0, cast(long) value.low, none, true);
        return value.equation;
    }

    private static Linear scaleLinear(in Linear value, long scale) {
        import core.checkedint: muls;

        if (!value.known)
            return Linear.init;
        bool overflow;
        const factor = muls(value.factor, scale, overflow);
        const bias = muls(value.bias, scale, overflow);
        if (overflow)
            return Linear.init;
        return Linear(factor, bias, factor ? value.home : none, true);
    }

    private static Linear addLinear(in Linear a, in Linear b) {
        import core.checkedint: adds;

        if (!a.known || !b.known || (a.home != none && b.home != none && a.home != b.home))
            return Linear.init;
        bool overflow;
        const factor = adds(a.factor, b.factor, overflow);
        const bias = adds(a.bias, b.bias, overflow);
        if (overflow)
            return Linear.init;
        const home = a.home == none ? b.home : a.home;
        return Linear(factor, bias, factor ? home : none, true);
    }

    Memory memoryOf(in Operand operand, ushort pc) const {
        if (operand.mode == Mode.frame)
            return Memory(frame, cast(uint) operand.word,
                cast(uint) operand.word + operand.width);
        if (operand.mode != Mode.indirect)
            return Memory.init;
        const home = program.findSlot(operand.word, ulong.sizeof);
        if (home == none)
            return Memory.init;
        const origin = actual(states[memoryOrigin[pc]].values[home], home);
        if (origin.root == none || origin.root == number || origin.high > uint.max
                || origin.high + operand.offset + operand.width > uint.max)
            return Memory.init;
        return Memory(origin.root, cast(uint) origin.low + operand.offset,
            cast(uint) origin.high + operand.offset + operand.width,
            multipleOf(origin), operand.offset, operand.width);
    }

    private static uint multipleOf(in Value value) {
        return value.low == value.high && value.low <= uint.max
            ? cast(uint) value.low : value.multiple;
    }

    private static uint gcd(uint a, uint b) {
        while (b) {
            const rest = a % b;
            a = b;
            b = rest;
        }
        return a;
    }

    private static Value compareValues(in Value a, in Value b, Comparison comparison,
        CompareKind kind, size_t width)
    {
        if (kind == CompareKind.floating || a.root != number || b.root != number)
            return Value(0, 1, number);
        Value left = a;
        Value right = b;
        const sign = (maskOf(width) >> 1) + 1;
        if (kind == CompareKind.signed) {
            if ((left.low ^ left.high) & sign || (right.low ^ right.high) & sign)
                return Value(0, 1, number);
            left.low ^= sign;
            left.high ^= sign;
            right.low ^= sign;
            right.high ^= sign;
        }
        bool yes, no;
        final switch (comparison) with (Comparison) {
        case lessThan: yes = left.high < right.low; no = left.low >= right.high; break;
        case lessOrEqual: yes = left.high <= right.low; no = left.low > right.high; break;
        case greaterThan: yes = left.low > right.high; no = left.high <= right.low; break;
        case greaterOrEqual: yes = left.low >= right.high; no = left.high < right.low; break;
        case equal, notEqual:
            yes = left.exact && right.exact && left.low == right.low;
            no = left.high < right.low || left.low > right.high;
            if (comparison == notEqual) {
                const saved = yes;
                yes = no;
                no = saved;
            }
            break;
        }
        return Value(yes, !no, number);
    }

    private static Comparison inverted(Comparison cmp) {
        final switch (cmp) with (Comparison) {
        case lessThan: return greaterOrEqual;
        case lessOrEqual: return greaterThan;
        case greaterThan: return lessOrEqual;
        case greaterOrEqual: return lessThan;
        case equal: return notEqual;
        case notEqual: return equal;
        }
    }

    private static bool limit(ref Value a, ref Value b, bool strict) {
        if (a.low > b.high || (strict && a.low == b.high))
            return false;
        const high = b.high - strict;
        const low = a.low + strict;
        if (a.high > high)
            a.high = high;
        if (b.low < low)
            b.low = low;
        const upper = addLinear(formOf(b), Linear(0, -cast(long) strict, none, true));
        if (upper.known)
            a.upper = upper;
        return true;
    }
}

package struct ScalarFlow {
    @nogc nothrow:

    alias Program = ScalarProgram;
    alias Kind = Program.Kind;
    alias Operand = Program.Operand;
    alias Mode = Program.Mode;
    enum none = Program.none;
    enum valueLimit = 4096;
    enum nodeLimit = Program.instructionLimit * 8;
    enum gpCount = 4;
    enum fpCount = 13;

    enum Lane : ubyte { either, integer, floating }
    enum Origin : ubyte { produced, phi, literal, address, entry }
    enum Action : ubyte { load, store, operation }

    static struct Set {
        @nogc nothrow:

        ulong[(Program.slotLimit + 63) / 64] words;

        bool has(size_t index) const {
            return (words[index / 64] & (1UL << (index % 64))) != 0;
        }

        void add(size_t index) {
            words[index / 64] |= 1UL << (index % 64);
        }

        void include(in Set other) {
            foreach (i; 0 .. words.length)
                words[i] |= other.words[i];
        }

        void exclude(in Set other) {
            foreach (i; 0 .. words.length)
                words[i] &= ~other.words[i];
        }
    }

    static struct Value {
        ulong bits;
        ushort home = none;
        ushort first;
        ushort last;
        ushort overwrite = none;
        ushort preference = none;
        ubyte width;
        Lane lane;
        Origin origin;
        byte color = -1;
        bool spilled;
        bool used;

        bool allocated() const @nogc nothrow {
            return origin == Origin.produced || origin == Origin.phi;
        }
    }

    static struct Node {
        Action action;
        ushort pc;
        ushort output = none;
        ushort left = none;
        ushort right = none;
        ushort address = none;
        uint offset;
        ubyte width;
        Lane lane;
        bool used;
        ScalarRanges.Memory memory;
    }

    static struct Block {
        ushort pc;
        ushort end;
        ushort firstNode;
        ushort endNode;
        ushort firstValue;
        ushort endValue;
        ushort next = none;
        ushort target = none;
        ushort[Program.slotLimit] incoming;
        ushort[Program.slotLimit] outgoing;
        Set uses;
        Set defs;
        Set live;
    }

    ScalarRanges ranges;
    Block[Program.instructionLimit] blocks;
    Value[valueLimit] values;
    Node[nodeLimit] nodes;
    ushort[Program.instructionLimit] whichBlock;
    ushort blockCount;
    ushort valueCount;
    ushort nodeCount;
    Set canonical;
    Set modified;
    ushort fp0Slot;
    ushort r0Slot;
    bool failed;

    bool prepare(const(Function)* function_, const(Instruction)[] instructions,
        const(JitOp)[] ops)
    {
        if (!ranges.program.read(function_, instructions, ops) || !ranges.analyze)
            return false;
        blockCount = valueCount = nodeCount = 0;
        failed = false;
        canonical = modified = Set.init;
        hoistLoads;
        auto p = &ranges.program;
        fp0Slot = p.slotOf(Program.fp0, double.sizeof);
        r0Slot = p.slotOf(Program.r0, ulong.sizeof);
        if (fp0Slot == none || r0Slot == none)
            return false;

        foreach (i, ref const a; p.slots[0 .. p.slotCount]) {
            if (a.isTemporary)
                continue;
            foreach (j, ref const b; p.slots[0 .. i]) {
                if (b.isTemporary)
                    continue;
                if (a.offset == b.offset || (a.offset < Program.r0 && b.offset < Program.r0
                        && a.offset < b.offset + b.width && b.offset < a.offset + a.width)) {
                    canonical.add(i);
                    canonical.add(j);
                }
            }
        }
        if (canonical.has(r0Slot) || canonical.has(fp0Slot))
            return false;
        splitBlocks;
        findLiveHomes;
        foreach (i; 0 .. blockCount)
            rename(blocks[i]);
        if (failed)
            return false;
        connect;
        scheduleBlocks;
        return !failed && color;
    }


    private alias Members = bool[Program.instructionLimit];

    private static struct Hoist {
        Operand memory;
        ushort pc;
        ushort home = none;
    }

    private static struct Recurrence {
        ushort index = none;
        ushort update = none;
        ulong step;
    }

    private void hoistLoads() {
        foreach (header; 1 .. ranges.program.length) {
            if (!ranges.visited[header] || ranges.resolved[header].kind != Kind.branch)
                continue;
            Members members;
            if (!naturalLoop(cast(ushort) header, members))
                continue;
            const branch = ranges.resolved[header];
            if (members[branch.next] == members[branch.target])
                continue;
            const body = members[branch.next] ? branch.next : branch.target;

            enum maximumHoists = 12;
            Hoist[maximumHoists] candidates;
            size_t count;
            Recurrence induction;
            ushort end = body;
            for (ushort pc = body; pc < ranges.program.length; ++pc) {
                ref const step = ranges.resolved[pc];
                end = cast(ushort) (pc + 1);
                foreach (const operand; [step.left, step.right]) {
                    if (count == candidates.length || operand.mode != Mode.indirect
                            || operand.width > ulong.sizeof
                            || !unchanged(operand.word, ulong.sizeof, members)
                            || !loadCanMove(operand, pc, members))
                        continue;
                    bool known;
                    foreach (ref const candidate; candidates[0 .. count])
                        known |= candidate.memory == operand;
                    if (!known)
                        candidates[count++] = Hoist(operand, pc);
                }
                if (step.kind == Kind.index && induction.index == none) {
                    bool changedIndex;
                    foreach (ref const earlier; ranges.resolved[body .. pc])
                        changedIndex |= overlaps(earlier.output, step.right.word, step.right.width);
                    if (!changedIndex)
                        induction = recurrence(pc, step, members);
                }
                if (step.target != none || step.next != pc + 1)
                    break;
                bool sharedEntry;
                foreach (other, ref const op; ranges.resolved[0 .. ranges.length])
                    if (ranges.visited[other] && other != pc
                            && (op.target == step.next || op.next == step.next)) {
                        sharedEntry = true;
                        break;
                    }
                if (sharedEntry)
                    break;
            }
            if (!count && induction.index == none)
                continue;
            if (ranges.length + count + 3 > Program.instructionLimit
                    || ranges.program.slotCount + count + 1 > Program.slotLimit)
                continue;
            rotate(cast(ushort) header, body, end, members, candidates[0 .. count], induction);
        }
    }

    private bool naturalLoop(ushort header, ref Members members) {
        members[header] = true;
        bool found;
        foreach (pc; header + 1 .. ranges.program.length) {
            const step = ranges.resolved[pc];
            if (ranges.visited[pc] && (step.next == header || step.target == header)) {
                members[pc] = true;
                found = true;
            }
        }
        if (!found)
            return false;
        bool changed;
        do {
            changed = false;
            foreach (pc, ref const step; ranges.resolved[0 .. ranges.length]) {
                if (!ranges.visited[pc] || members[pc])
                    continue;
                if ((step.next != none && step.next != header && members[step.next])
                        || (step.target != none && step.target != header && members[step.target])) {
                    members[pc] = true;
                    changed = true;
                }
            }
        } while (changed);
        return !members[0];
    }

    private bool unchanged(size_t offset, ubyte width, in Members members) {
        foreach (pc, ref const step; ranges.resolved[0 .. ranges.length])
            if (members[pc] && overlaps(step.output, offset, width))
                return false;
        return true;
    }

    private static bool overlaps(in Operand output, size_t offset, ubyte width) {
        return output.mode == Mode.frame && output.word < offset + width
            && offset < output.word + output.width;
    }

    private bool loadCanMove(in Operand operand, ushort pc, in Members members) {
        const source = ranges.memoryOf(operand, pc);
        if (source.root == none)
            return false;
        foreach (i, ref const step; ranges.resolved[0 .. ranges.length])
            if (members[i] && step.output.mode == Mode.indirect
                    && !source.disjoint(ranges.memoryOf(step.output, cast(ushort) i)))
                return false;
        return true;
    }

    private Recurrence recurrence(ushort pc, in Program.Operation index,
        in Members members)
    {
        if (index.left.mode != Mode.frame || index.right.mode != Mode.frame
                || !unchanged(index.left.word, index.left.width, members))
            return Recurrence.init;
        Recurrence result;
        foreach (i, ref const step; ranges.resolved[0 .. ranges.length]) {
            if (!members[i] || !overlaps(step.output, index.right.word, index.right.width))
                continue;
            if (result.update != none || step.kind != Kind.integer
                    || step.integer != JitOp.IntOperation.add
                    || step.output != index.right || step.left != index.right
                    || step.right.mode != Mode.literal || step.next == none)
                return Recurrence.init;
            result = Recurrence(pc, cast(ushort) i, step.right.word * index.stride);
        }
        return result;
    }

    private void rotate(ushort header, ushort body, ushort end, in Members members,
        Hoist[] hoists, in Recurrence induction)
    {
        const originalLength = ranges.length;
        auto initial = ranges.resolved[header];
        const first = appendStep(initial, header);
        ushort previous = first;
        if (initial.next == body)
            ranges.resolved[first].next = cast(ushort) (originalLength + 1);
        else
            ranges.resolved[first].target = cast(ushort) (originalLength + 1);

        foreach (ref hoist; hoists) {
            const output = newTemporary(hoist.memory.width);
            hoist.home = cast(ushort) output.word;
            const pc = appendStep(Program.Operation(Kind.move, next: body,
                output: output, left: hoist.memory), hoist.pc);
            if (previous != first)
                ranges.resolved[previous].next = pc;
            previous = pc;
        }
        if (induction.index != none) {
            const temp = newTemporary(ulong.sizeof);
            auto seed = ranges.resolved[induction.index];
            seed.output = temp;
            seed.next = body;
            const pc = appendStep(seed, induction.index);
            if (previous != first)
                ranges.resolved[previous].next = pc;

            ref index = ranges.resolved[induction.index];
            index.kind = Kind.move;
            index.left = temp;
            index.right = Operand.init;
            ref update = ranges.resolved[induction.update];
            const step = Operand(Mode.literal, ulong.sizeof, 0, induction.step);
            update.next = appendStep(Program.Operation(Kind.integer, JitOp.IntOperation.add,
                next: update.next, output: temp, left: temp, right: step), induction.update);
        }

        foreach (pc, ref step; ranges.resolved[0 .. originalLength]) {
            if (!ranges.visited[pc] || members[pc])
                continue;
            if (step.next == header)
                step.next = first;
            if (step.target == header)
                step.target = first;
        }

        foreach (ref step; ranges.resolved[body .. end]) {
            foreach (ref const hoist; hoists) {
                if (step.left == hoist.memory)
                    step.left = Operand(Mode.temporary, step.left.width, 0, hoist.home);
                if (step.right == hoist.memory)
                    step.right = Operand(Mode.temporary, step.right.width, 0, hoist.home);
            }
        }
    }

    private Operand newTemporary(ubyte width) {
        const home = ranges.program.newTemporary(width);
        return Operand(Mode.temporary, width, 0, home);
    }

    private ushort appendStep(in Program.Operation step, ushort origin) {
        const pc = ranges.length++;
        ranges.resolved[pc] = step;
        ranges.visited[pc] = true;
        ranges.memoryOrigin[pc] = ranges.memoryOrigin[origin];
        return pc;
    }

    private void splitBlocks() {
        bool[Program.instructionLimit] starts;
        const count = ranges.length;
        starts[0] = true;
        foreach (pc, ref const step; ranges.resolved[0 .. count]) {
            if (!ranges.visited[pc])
                continue;
            if (step.target != none)
                starts[step.target] = true;
            if (step.next != none && (step.target != none || step.next != pc + 1))
                starts[step.next] = true;
            if (pc + 1 < count && (step.next != pc + 1 || step.target != none))
                starts[pc + 1] = true;
        }
        ushort first;
        foreach (pc; 0 .. count) {
            if (!ranges.visited[pc])
                continue;
            if (starts[pc] || pc > 0 && !ranges.visited[pc - 1]) {
                first = cast(ushort) pc;
                blocks[blockCount] = Block.init;
                blocks[blockCount++].pc = first;
            }
            whichBlock[pc] = cast(ushort) (blockCount - 1);
            blocks[blockCount - 1].end = cast(ushort) (pc + 1);
        }
        foreach (ref block; blocks[0 .. blockCount]) {
            ref const last = ranges.resolved[block.end - 1];
            if (last.next != none)
                block.next = whichBlock[last.next];
            if (last.target != none)
                block.target = whichBlock[last.target];
        }
    }

    private void findLiveHomes() {
        foreach (ref block; blocks[0 .. blockCount]) {
            foreach (ref const step; ranges.resolved[block.pc .. block.end]) {
                mention(block, step.left, false);
                mention(block, step.right, false);
                mention(block, step.output, true);
            }
            foreach (home, ref const slot; ranges.program.slots[0 .. ranges.program.slotCount])
                if (block.defs.has(home) && !slot.isTemporary)
                    modified.add(home);
        }
        foreach (ref block; blocks[0 .. blockCount]) {
            const last = ranges.resolved[block.end - 1].kind;
            if (last == Kind.exit || last == Kind.returnValue) {
                auto uses = modified;
                uses.exclude(block.defs);
                block.uses.include(uses);
            }
            if (last == Kind.returnVoid || last == Kind.returnValue || last == Kind.exit) {
                if (modified.has(fp0Slot) && !block.defs.has(fp0Slot))
                    block.uses.add(fp0Slot);
                if (modified.has(r0Slot) && !block.defs.has(r0Slot))
                    block.uses.add(r0Slot);
            }
        }
        bool changed;
        do {
            changed = false;
            foreach_reverse (ref block; blocks[0 .. blockCount]) {
                Set live;
                foreach (const next; [block.next, block.target])
                    if (next != none)
                        live.include(blocks[next].live);
                live.exclude(block.defs);
                live.include(block.uses);
                if (live != block.live) {
                    block.live = live;
                    changed = true;
                }
            }
        } while (changed);
    }

    private void mention(ref Block block, Operand operand, bool write) {
        if (operand.mode == Mode.indirect) {
            operand = Operand(Mode.frame, ulong.sizeof, 0, operand.word);
            write = false;
        }
        if (operand.mode != Mode.frame && operand.mode != Mode.register
                && operand.mode != Mode.temporary)
            return;
        if (operand.width == 2 * ulong.sizeof) {
            operand.width = ulong.sizeof;
            mention(block, operand.displaced(ulong.sizeof), write);
        }
        const home = ranges.program.slotOf(operand);
        if (home == none) {
            failed = true;
            return;
        }
        if (canonical.has(home))
            return;
        if (write)
            block.defs.add(home);
        else if (!block.defs.has(home))
            block.uses.add(home);
    }

    private void rename(ref Block block) {
        block.firstNode = nodeCount;
        block.firstValue = valueCount;
        block.incoming[] = none;
        block.outgoing[] = none;
        foreach (home, ref const slot; ranges.program.slots[0 .. ranges.program.slotCount]) {
            if (!block.live.has(home))
                continue;
            const lane = home == fp0Slot ? Lane.floating : Lane.either;
            const id = value(Value(0, cast(ushort) home, nodeCount, nodeCount,
                none, none, slot.width, lane, Origin.phi));
            block.incoming[home] = block.outgoing[home] = id;
        }
        foreach (pc; block.pc .. block.end) {
            ref const step = ranges.resolved[pc];
            if (step.kind == Kind.move && step.left.width == 16) {
                Operand left = step.left;
                Operand output = step.output;
                left.width = output.width = ulong.sizeof;
                const low = read(block, left, Lane.either, cast(ushort) pc);
                const high = read(block, left.displaced(ulong.sizeof), Lane.either, cast(ushort) pc);
                write(block, output, low, cast(ushort) pc);
                write(block, output.displaced(ulong.sizeof), high, cast(ushort) pc);
                continue;
            }
            if (step.kind == Kind.exit || step.kind == Kind.returnValue || step.kind == Kind.returnVoid
                    || step.kind == Kind.jump)
                continue;
            const lane = step.kind == Kind.floating || step.kind == Kind.sqrt
                || (step.kind == Kind.branch && step.compareKind == CompareKind.floating)
                ? Lane.floating : step.kind == Kind.move ? Lane.either : Lane.integer;
            const index = cast(ushort) pc;
            const left = read(block, step.left, lane, index);
            const right = read(block, step.right, lane, index);
            if (step.kind == Kind.move) {
                write(block, step.output, left, index);
                continue;
            }
            if (step.kind == Kind.branch) {
                append(Node(Action.operation, index, none, left, right));
                continue;
            }
            const destination = step.output;
            const result = value(Value(0, none, nodeCount, nodeCount,
                none, left, destination.width, lane));
            append(Node(Action.operation, index, result, left, right));
            write(block, destination, result, index);
        }
        block.endNode = nodeCount;
        block.endValue = valueCount;
    }

    private ushort read(ref Block block, in Operand operand, Lane lane, ushort pc) {
        final switch (operand.mode) with (Mode) {
        case unused:
            return none;
        case literal, address:
            const origin = operand.mode == literal ? Origin.literal : Origin.address;
            return value(Value(operand.word, none, nodeCount, nodeCount,
                none, none, operand.width, lane, origin));
        case frame, register, temporary: {
            const home = ranges.program.slotOf(operand);
            if (home == none) {
                failed = true;
                return none;
            }
            if (canonical.has(home)) {
                const result = value(Value(0, none, nodeCount, nodeCount, none, none,
                    operand.width, lane));
                append(Node(Action.load, pc, result, none, none, none,
                    cast(uint) operand.word, operand.width, lane, false, ranges.memoryOf(operand, pc)));
                return result;
            }
            const id = block.outgoing[home];
            if (id == none) {
                failed = true;
                return none;
            }
            prefer(id, lane);
            return id;
        }
        case indirect: {
            const address = read(block, Operand(Mode.frame, ulong.sizeof, 0,
                operand.word), Lane.integer, pc);
            const memory = ranges.memoryOf(operand, pc);
            foreach_reverse (ref const previous; nodes[block.firstNode .. nodeCount]) {
                if (previous.action == Action.store && !memory.disjoint(previous.memory))
                    break;
                if (previous.action == Action.load && previous.address == address
                        && previous.offset == operand.offset && previous.width == operand.width) {
                    prefer(previous.output, lane);
                    return previous.output;
                }
            }
            const result = value(Value(0, none, nodeCount, nodeCount, none, none,
                operand.width, lane));
            append(Node(Action.load, pc, result, none, none, address,
                operand.offset, operand.width, lane, false, memory));
            return result;
        }
        }
    }

    private void write(ref Block block, in Operand operand, ushort id, ushort pc) {
        if (id == none) {
            failed = true;
            return;
        }
        if (operand.mode == Mode.indirect) {
            const address = read(block, Operand(Mode.frame, ulong.sizeof, 0,
                operand.word), Lane.integer, pc);
            append(Node(Action.store, pc, none, id, none, address,
                operand.offset, operand.width, Lane.either, false, ranges.memoryOf(operand, pc)));
            return;
        }
        const home = ranges.program.slotOf(operand);
        if (home == none) {
            failed = true;
            return;
        }
        if (canonical.has(home)) {
            append(Node(Action.store, pc, none, id, none, none,
                cast(uint) operand.word, operand.width, Lane.either, false,
                ranges.memoryOf(operand, pc)));
            return;
        }
        const previous = block.outgoing[home];
        if (previous != none && previous != id && values[previous].home == home
                && values[previous].overwrite == none)
            values[previous].overwrite = nodeCount;
        if (values[id].home == none && values[id].allocated
                && nodes[values[id].first].pc == pc)
            values[id].home = home;
        block.outgoing[home] = id;
    }

    private ushort value(in Value definition) {
        if (valueCount == values.length) {
            failed = true;
            return none;
        }
        const id = valueCount++;
        values[id] = definition;
        return id;
    }

    private void append(in Node node) {
        if (nodeCount == nodes.length) {
            failed = true;
            return;
        }
        nodes[nodeCount++] = node;
    }

    private void use(ushort id, ushort position) {
        if (id == none)
            return;
        ref v = values[id];
        v.used = true;
        if (position > v.last)
            v.last = position;
    }

    private void prefer(ushort id, Lane lane) {
        if (id == none)
            return;
        ref v = values[id];
        if (v.lane == Lane.either)
            v.lane = lane;
    }

    private void connect() {
        // Phi operands are uses on the incoming edge. This distinguishes
        // definitions within the block from definitions at the join.
        bool changed;
        size_t live;
        do {
            changed = false;
            foreach (ref block; blocks[0 .. blockCount]) {
                foreach (const successor; [block.next, block.target]) {
                    if (successor == none)
                        continue;
                    ref const target = blocks[successor];
                    foreach (home, id; target.incoming[0 .. ranges.program.slotCount]) {
                        if (id == none)
                            continue;
                        const from = block.outgoing[home];
                        if (from == none) {
                            failed = true;
                            return;
                        }
                        if (values[id].used)
                            use(from, block.endNode);
                        const source = values[from].lane;
                        const dest = values[id].lane;
                        if (source == Lane.either && dest != Lane.either) {
                            values[from].lane = dest;
                            changed = true;
                        } else if (dest == Lane.either && source != Lane.either) {
                            values[id].lane = source;
                            changed = true;
                        }
                    }
                }
                const last = ranges.resolved[block.end - 1].kind;
                if (last == Kind.exit || last == Kind.returnValue) {
                    foreach (home, id; block.outgoing[0 .. ranges.program.slotCount])
                        if (modified.has(home))
                            use(id, block.endNode);
                }
                if (last == Kind.exit || last == Kind.returnValue || last == Kind.returnVoid) {
                    if (modified.has(fp0Slot))
                        use(block.outgoing[fp0Slot], block.endNode);
                    if (modified.has(r0Slot))
                        use(block.outgoing[r0Slot], block.endNode);
                }
            }
            markLiveNodes;
            size_t current;
            foreach (ref const value; values[0 .. valueCount])
                current += value.used;
            changed |= current != live;
            live = current;
        } while (changed);
    }

    private void markLiveNodes() {
        foreach_reverse (index, ref node; nodes[0 .. nodeCount]) {
            const kind = ranges.resolved[node.pc].kind;
            node.used = node.output == none || values[node.output].used
                || (node.action == Action.operation && (kind == Kind.floating || kind == Kind.sqrt));
            if (node.used) {
                use(node.left, cast(ushort) index);
                use(node.right, cast(ushort) index);
                use(node.address, cast(ushort) index);
            }
        }
    }


    private enum scheduleLimit = 128;

    private static struct Schedule {
        bool[scheduleLimit][scheduleLimit] depends;
        ushort[scheduleLimit] pending;
        ushort[scheduleLimit] height;
        ushort[scheduleLimit] readyAt;
        ushort[scheduleLimit] oldToNew;
        ushort[valueLimit] uses;
        bool[scheduleLimit] issued;
        Node[scheduleLimit] ordered;
    }

    private Schedule schedule;
    private ushort[valueLimit] allocationOrder;

    private void scheduleBlocks() {
        foreach (ref const block; blocks[0 .. blockCount]) {
            const count = block.endNode - block.firstNode;
            if (count < 2 || count > scheduleLimit)
                continue;
            scheduleBlock(block, count);
        }
        foreach (ref value; values[0 .. valueCount]) {
            value.used = false;
            value.last = value.first;
        }
        connect;
    }

    private void scheduleBlock(in Block block, size_t count) {
        schedule = Schedule.init;
        auto work = nodes[block.firstNode .. block.endNode];
        int gpPressure;
        int fpPressure;
        foreach (id; block.firstValue .. block.endValue) {
            ref const value = values[id];
            if (value.used && value.last == block.endNode)
                ++schedule.uses[id];
            if (value.used && value.origin == Origin.phi) {
                if (value.lane == Lane.floating)
                    ++fpPressure;
                else
                    ++gpPressure;
            }
        }
        foreach (now, ref const node; work) {
            if (!node.used)
                continue;
            foreach (id; [node.left, node.right, node.address]) {
                if (id == none || !values[id].allocated)
                    continue;
                ++schedule.uses[id];
                if (values[id].origin == Origin.produced)
                    schedule.depends[now][values[id].first - block.firstNode] = true;
            }
            foreach (prior, ref const earlier; work[0 .. now]) {
                if (!earlier.used)
                    continue;
                const terminal = node.action == Action.operation
                    && ranges.resolved[node.pc].kind == Kind.branch;
                const orderedStores = node.action == Action.store && earlier.action == Action.store;
                const aliased = (node.action == Action.load && earlier.action == Action.store)
                    || (node.action == Action.store && earlier.action == Action.load);
                if (terminal || orderedStores || (aliased && !node.memory.disjoint(earlier.memory)))
                    schedule.depends[now][prior] = true;
            }
            foreach (prior; 0 .. now)
                schedule.pending[now] += schedule.depends[now][prior] ? 1 : 0;
        }

        foreach_reverse (i, ref const node; work) {
            if (!node.used)
                continue;
            ushort best;
            foreach (later; i + 1 .. count)
                if (schedule.depends[later][i] && schedule.height[later] > best)
                    best = schedule.height[later];
            schedule.height[i] = cast(ushort) (best + latency(node));
        }

        ushort tick;
        size_t issue;
        foreach (position; 0 .. count) {
            size_t chosen = count;
            while (chosen == count) {
                int score = int.min;
                foreach (i, ref const node; work) {
                    if (schedule.issued[i] || schedule.pending[i] || schedule.readyAt[i] > tick)
                        continue;
                    const priority = schedulingPriority(node, schedule.height[i],
                        gpPressure, fpPressure);
                    if (priority > score) {
                        chosen = i;
                        score = priority;
                    }
                }
                if (chosen == count) {
                    ++tick;
                    issue = 0;
                }
            }
            const node = work[chosen];
            schedule.ordered[position] = node;
            schedule.oldToNew[chosen] = cast(ushort) position;
            schedule.issued[chosen] = true;
            if (node.used) {
                foreach (id; [node.left, node.right, node.address]) {
                    if (id == none || !values[id].allocated || --schedule.uses[id])
                        continue;
                    if (values[id].lane == Lane.floating)
                        --fpPressure;
                    else
                        --gpPressure;
                }
                if (node.output != none && schedule.uses[node.output]) {
                    if (values[node.output].lane == Lane.floating)
                        ++fpPressure;
                    else
                        ++gpPressure;
                }
                const ready = cast(ushort) (tick + latency(node));
                foreach (later; chosen + 1 .. count) {
                    if (!schedule.depends[later][chosen])
                        continue;
                    --schedule.pending[later];
                    if (schedule.readyAt[later] < ready)
                        schedule.readyAt[later] = ready;
                }
            }
            enum issueWidth = 3;
            if (++issue == issueWidth) {
                ++tick;
                issue = 0;
            }
        }
        work[] = schedule.ordered[0 .. count];
        foreach (id; block.firstValue .. block.endValue) {
            ref value = values[id];
            if (value.origin == Origin.produced)
                value.first = cast(ushort) (block.firstNode
                    + schedule.oldToNew[value.first - block.firstNode]);
            if (value.overwrite != none && value.overwrite != block.firstNode) {
                value.overwrite = cast(ushort) (block.firstNode
                    + schedule.oldToNew[value.overwrite - block.firstNode - 1] + 1);
            }
        }
    }

    private int schedulingPriority(in Node node, int height, int gpPressure, int fpPressure) {
        if (!node.used)
            return int.min + 1;
        int gpGrowth;
        int fpGrowth;
        foreach (id; [node.left, node.right, node.address]) {
            if (id != none && values[id].allocated && schedule.uses[id] == 1) {
                if (values[id].lane == Lane.floating)
                    --fpGrowth;
                else
                    --gpGrowth;
            }
        }
        if (node.output != none && schedule.uses[node.output]) {
            if (values[node.output].lane == Lane.floating)
                ++fpGrowth;
            else
                ++gpGrowth;
        }
        if (gpPressure >= gpCount - 1)
            height -= 36 * gpGrowth;
        if (fpPressure >= fpCount - 3)
            height -= 64 * fpGrowth;
        return height;
    }

    private int latency(in Node node) const {
        if (node.action == Action.load)
            return 4;
        if (node.action == Action.store)
            return 1;
        const op = ranges.resolved[node.pc];
        if (op.kind == Kind.sqrt)
            return 13;
        if (op.kind == Kind.floating)
            return op.floating == JitOp.FloatOperation.divide ? 14 : 4;
        if (op.kind == Kind.index || op.kind == Kind.integer
                && op.integer == JitOp.IntOperation.multiply)
            return 3;
        return 1;
    }

    private bool color() {
        byte[Program.slotLimit] hints = -1;
        foreach (ref const block; blocks[0 .. blockCount]) {
            ushort[gpCount] gp = none;
            ushort[fpCount] fp = none;
            size_t count;
            foreach (id; block.firstValue .. block.endValue) {
                if (!values[id].allocated || !values[id].used)
                    continue;
                size_t at = count++;
                while (at && values[allocationOrder[at - 1]].first > values[id].first) {
                    allocationOrder[at] = allocationOrder[at - 1];
                    --at;
                }
                allocationOrder[at] = cast(ushort) id;
            }
            foreach (id; allocationOrder[0 .. count]) {
                ref v = values[id];
                if (!v.used || !v.allocated)
                    continue;
                auto bank = v.lane == Lane.floating ? fp[] : gp[];
                byte wanted = -1;
                if (v.home != none)
                    wanted = hints[v.home];
                if (v.preference != none) {
                    const left = values[v.preference];
                    if (left.lane == v.lane && left.last == v.first && left.color >= 0)
                        wanted = left.color;
                }
                foreach (ref assigned; bank)
                    if (assigned != none && values[assigned].last < v.first)
                        assigned = none;
                if (wanted >= 0 && wanted < bank.length && bank[wanted] == none) {
                    v.color = wanted;
                } else if (wanted >= 0 && wanted < bank.length && bank[wanted] == v.preference
                        && v.preference != none && values[v.preference].last == v.first) {
                    v.color = wanted;
                } else {
                    foreach (index, assigned; bank)
                        if (assigned == none) {
                            v.color = cast(byte) index;
                            break;
                        }
                }
                if (v.color < 0) {
                    if (canSpill(v)) {
                        v.spilled = true;
                        continue;
                    }
                    foreach (index, assigned; bank) {
                        ref other = values[assigned];
                        if (canSpill(other) && (v.color < 0
                                || values[bank[v.color]].last < other.last))
                            v.color = cast(byte) index;
                    }
                    if (v.color < 0)
                        return false;
                    ref other = values[bank[v.color]];
                    other.spilled = true;
                    other.color = -1;
                }
                bank[v.color] = cast(ushort) id;
                if (v.home != none && hints[v.home] < 0)
                    hints[v.home] = v.color;
            }
        }
        return true;
    }

    private bool canSpill(in Value value) const {
        return value.home != none && value.home != r0Slot && value.home != fp0Slot
            && !ranges.program.slots[value.home].isTemporary
            && value.last < value.overwrite;
    }
}
