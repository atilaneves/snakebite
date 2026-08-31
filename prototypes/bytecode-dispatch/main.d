module bytecode_dispatch;

private:

import std.algorithm.searching: startsWith;
import std.conv: to;
import std.datetime.stopwatch: AutoStart, StopWatch;
import std.stdio: File, stderr, stdout;

private enum Op: ubyte {
    constant,
    load,
    store,
    add,
    subtract,
    multiply,
    xor,
    lessThan,
    branchTrue,
    branch,
    call,
    return_,
}

private struct LogicalInstruction {
    Op op;
    int operand;
}

private alias LogicalFunction = LogicalInstruction[];
private alias LogicalProgram = LogicalFunction[];

private LogicalProgram corpus() {
    return [
        [
            LogicalInstruction(Op.constant, 0),
            LogicalInstruction(Op.store, 0),
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.add, 1),
            LogicalInstruction(Op.store, 0),
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.lessThan, 2_000),
            LogicalInstruction(Op.branchTrue, 2),
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.return_, 0),
        ],
        [
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.multiply, 1_103_515),
            LogicalInstruction(Op.add, 12_345),
            LogicalInstruction(Op.store, 0),
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.lessThan, 0),
            LogicalInstruction(Op.branchTrue, 9),
            LogicalInstruction(Op.constant, 7),
            LogicalInstruction(Op.branch, 10),
            LogicalInstruction(Op.constant, 11),
            LogicalInstruction(Op.return_, 0),
        ],
        [
            LogicalInstruction(Op.constant, 41),
            LogicalInstruction(Op.store, 3),
            LogicalInstruction(Op.load, 3),
            LogicalInstruction(Op.add, 1),
            LogicalInstruction(Op.return_, 0),
        ],
        [
            LogicalInstruction(Op.constant, 1),
            LogicalInstruction(Op.call, 4),
            LogicalInstruction(Op.add, 4),
            LogicalInstruction(Op.return_, 0),
        ],
        [
            LogicalInstruction(Op.add, 2),
            LogicalInstruction(Op.call, 5),
            LogicalInstruction(Op.return_, 0),
        ],
        [
            LogicalInstruction(Op.add, 3),
            LogicalInstruction(Op.return_, 0),
        ],
        [
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.lessThan, 1),
            LogicalInstruction(Op.branchTrue, 7),
            LogicalInstruction(Op.load, 0),
            LogicalInstruction(Op.subtract, 1),
            LogicalInstruction(Op.call, 6),
            LogicalInstruction(Op.add, 1),
            LogicalInstruction(Op.return_, 0),
        ],
    ];
}

private struct FixedProgram {
    uint[][] functions;
    size_t codeBytes;
}

private FixedProgram compileFixed(scope const LogicalProgram source) {
    FixedProgram result;
    foreach (function_; source) {
        uint[] code;
        foreach (instruction; function_) {
            assert(instruction.operand >= -8_388_608);
            assert(instruction.operand <= 8_388_607);
            code ~= (uint(instruction.op) << 24)
                | (cast(uint) instruction.operand & 0x00ff_ffff);
        }
        result.codeBytes += code.length * uint.sizeof;
        result.functions ~= code;
    }
    return result;
}

private int fixedOperand(in uint instruction) @safe @nogc nothrow pure {
    return cast(int) (instruction << 8) >> 8;
}

private int runFixed(
    scope const FixedProgram program,
    in size_t functionIndex,
    in int argument,
) {
    int[8] slots;
    slots[0] = argument;
    int accumulator;
    auto code = program.functions[functionIndex];
    size_t pc;
    while (true) {
        const instruction = code[pc++];
        const op = cast(Op) (instruction >> 24);
        const operand = fixedOperand(instruction);
        final switch (op) with (Op) {
            case constant: accumulator = operand; break;
            case load: accumulator = slots[operand]; break;
            case store: slots[operand] = accumulator; break;
            case add: accumulator += operand; break;
            case subtract: accumulator -= operand; break;
            case multiply: accumulator *= operand; break;
            case xor: accumulator ^= operand; break;
            case lessThan: accumulator = accumulator < operand; break;
            case branchTrue:
                if (accumulator)
                    pc = operand;
                break;
            case branch: pc = operand; break;
            case call:
                accumulator = runFixed(program, operand, accumulator);
                break;
            case return_: return accumulator;
        }
    }
}

private struct DirectState {
    const(DirectProgram)* program;
    const(DirectInstruction)* codeBegin;
    int[8] slots;
    int accumulator;
}

private struct DirectInstruction {
    alias Handler = const(DirectInstruction)* function(
        const(DirectInstruction)*,
        DirectState*,
    );
    Handler handler;
    int operand;
}

private struct DirectFunction {
    DirectInstruction[] code;
}

private struct DirectProgram {
    DirectFunction[] functions;
    size_t codeBytes;
}

private alias DirectHandler = DirectInstruction.Handler;

private DirectProgram compileDirect(scope const LogicalProgram source) {
    static immutable DirectHandler[] handlers = [
        &directConstant,
        &directLoad,
        &directStore,
        &directAdd,
        &directSubtract,
        &directMultiply,
        &directXor,
        &directLessThan,
        &directBranchTrue,
        &directBranch,
        &directCall,
        &directReturn,
    ];

    DirectProgram result;
    foreach (function_; source) {
        DirectFunction compiled;
        foreach (instruction; function_)
            compiled.code ~= DirectInstruction(
                handlers[instruction.op], instruction.operand,
            );
        result.codeBytes += compiled.code.length
            * DirectInstruction.sizeof;
        result.functions ~= compiled;
    }
    return result;
}

private int runDirect(
    scope const DirectProgram program,
    in size_t functionIndex,
    in int argument,
) {
    DirectState state;
    state.program = &program;
    state.codeBegin = program.functions[functionIndex].code.ptr;
    state.slots[0] = argument;
    auto pc = state.codeBegin;
    while (pc !is null)
        pc = pc.handler(pc, &state);
    return state.accumulator;
}

private const(DirectInstruction)* directConstant(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator = pc.operand; return pc + 1; }

private const(DirectInstruction)* directLoad(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator = state.slots[pc.operand]; return pc + 1; }

private const(DirectInstruction)* directStore(
    const(DirectInstruction)* pc, DirectState* state,
) { state.slots[pc.operand] = state.accumulator; return pc + 1; }

private const(DirectInstruction)* directAdd(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator += pc.operand; return pc + 1; }

private const(DirectInstruction)* directSubtract(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator -= pc.operand; return pc + 1; }

private const(DirectInstruction)* directMultiply(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator *= pc.operand; return pc + 1; }

private const(DirectInstruction)* directXor(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator ^= pc.operand; return pc + 1; }

private const(DirectInstruction)* directLessThan(
    const(DirectInstruction)* pc, DirectState* state,
) { state.accumulator = state.accumulator < pc.operand; return pc + 1; }

private const(DirectInstruction)* directBranchTrue(
    const(DirectInstruction)* pc, DirectState* state,
) {
    return state.accumulator ? state.codeBegin + pc.operand : pc + 1;
}

private const(DirectInstruction)* directBranch(
    const(DirectInstruction)* pc, DirectState* state,
) {
    return state.codeBegin + pc.operand;
}

private const(DirectInstruction)* directCall(
    const(DirectInstruction)* pc, DirectState* state,
) {
    state.accumulator = runDirect(
        *state.program, pc.operand, state.accumulator,
    );
    return pc + 1;
}

private const(DirectInstruction)* directReturn(
    const(DirectInstruction)*, DirectState*,
) { return null; }

private struct VariableFunction {
    ubyte[] code;
}

private struct VariableProgram {
    VariableFunction[] functions;
    size_t codeBytes;
}

private VariableProgram compileVariable(scope const LogicalProgram source) {
    VariableProgram result;
    foreach (function_; source) {
        VariableFunction compiled;
        size_t[] offsets;
        foreach (instruction; function_) {
            offsets ~= compiled.code.length;
            compiled.code ~= cast(ubyte) instruction.op;
            putSigned(compiled.code, instruction.operand);
        }
        compiled.code.length = 0;
        foreach (instruction; function_) {
            compiled.code ~= cast(ubyte) instruction.op;
            const operand = instruction.op == Op.branch
                    || instruction.op == Op.branchTrue
                ? cast(int) offsets[instruction.operand]
                : instruction.operand;
            putSigned(compiled.code, operand);
        }
        result.codeBytes += compiled.code.length;
        result.functions ~= compiled;
    }
    return result;
}

private void putSigned(ref ubyte[] output, int value) {
    bool more;
    do {
        auto byte_ = cast(ubyte) (value & 0x7f);
        value >>= 7;
        more = !((value == 0 && (byte_ & 0x40) == 0)
            || (value == -1 && (byte_ & 0x40) != 0));
        if (more)
            byte_ |= 0x80;
        output ~= byte_;
    } while (more);
}

private int readSigned(scope const ubyte[] code, ref size_t pc) {
    int result;
    uint shift;
    ubyte byte_;
    do {
        byte_ = code[pc++];
        result |= int(byte_ & 0x7f) << shift;
        shift += 7;
    } while (byte_ & 0x80);
    if (shift < 32 && (byte_ & 0x40))
        result |= cast(int) (~0u << shift);
    return result;
}

private int runVariable(
    scope const VariableProgram program,
    in size_t functionIndex,
    in int argument,
) {
    int[8] slots;
    slots[0] = argument;
    int accumulator;
    const function_ = program.functions[functionIndex];
    size_t pc;
    while (true) {
        const op = cast(Op) function_.code[pc++];
        const operand = readSigned(function_.code, pc);
        final switch (op) with (Op) {
            case constant: accumulator = operand; break;
            case load: accumulator = slots[operand]; break;
            case store: slots[operand] = accumulator; break;
            case add: accumulator += operand; break;
            case subtract: accumulator -= operand; break;
            case multiply: accumulator *= operand; break;
            case xor: accumulator ^= operand; break;
            case lessThan: accumulator = accumulator < operand; break;
            case branchTrue:
                if (accumulator)
                    pc = operand;
                break;
            case branch: pc = operand; break;
            case call:
                accumulator = runVariable(program, operand, accumulator);
                break;
            case return_: return accumulator;
        }
    }
}

private struct Result {
    string format;
    long compileNanoseconds;
    long executeNanoseconds;
    size_t codeBytes;
    long checksum;
}

private Result measureFixed(
    scope const LogicalProgram source,
    in size_t iterations,
) {
    auto compileWatch = StopWatch(AutoStart.yes);
    const program = compileFixed(source);
    compileWatch.stop;
    auto executeWatch = StopWatch(AutoStart.yes);
    const checksum = executeFixedCorpus(program, iterations);
    executeWatch.stop;
    return Result(
        "fixed32", compileWatch.peek.total!"nsecs",
        executeWatch.peek.total!"nsecs", program.codeBytes, checksum,
    );
}

private long executeFixedCorpus(
    scope const FixedProgram program,
    in size_t iterations,
) {
    long checksum;
    foreach (index; 0 .. iterations) {
        checksum += runFixed(program, 0, cast(int) index);
        checksum += runFixed(program, 1, cast(int) index);
        checksum += runFixed(program, 2, cast(int) index);
        checksum += runFixed(program, 3, cast(int) index);
        checksum += runFixed(program, 6, 12);
    }
    return checksum;
}

private Result measureDirect(
    scope const LogicalProgram source,
    in size_t iterations,
) {
    auto compileWatch = StopWatch(AutoStart.yes);
    const program = compileDirect(source);
    compileWatch.stop;
    auto executeWatch = StopWatch(AutoStart.yes);
    const checksum = executeDirectCorpus(program, iterations);
    executeWatch.stop;
    return Result(
        "direct", compileWatch.peek.total!"nsecs",
        executeWatch.peek.total!"nsecs", program.codeBytes, checksum,
    );
}

private long executeDirectCorpus(
    scope const DirectProgram program,
    in size_t iterations,
) {
    long checksum;
    foreach (index; 0 .. iterations) {
        checksum += runDirect(program, 0, cast(int) index);
        checksum += runDirect(program, 1, cast(int) index);
        checksum += runDirect(program, 2, cast(int) index);
        checksum += runDirect(program, 3, cast(int) index);
        checksum += runDirect(program, 6, 12);
    }
    return checksum;
}

private Result measureVariable(
    scope const LogicalProgram source,
    in size_t iterations,
) {
    auto compileWatch = StopWatch(AutoStart.yes);
    const program = compileVariable(source);
    compileWatch.stop;
    auto executeWatch = StopWatch(AutoStart.yes);
    const checksum = executeVariableCorpus(program, iterations);
    executeWatch.stop;
    return Result(
        "variable", compileWatch.peek.total!"nsecs",
        executeWatch.peek.total!"nsecs", program.codeBytes, checksum,
    );
}

private long executeVariableCorpus(
    scope const VariableProgram program,
    in size_t iterations,
) {
    long checksum;
    foreach (index; 0 .. iterations) {
        checksum += runVariable(program, 0, cast(int) index);
        checksum += runVariable(program, 1, cast(int) index);
        checksum += runVariable(program, 2, cast(int) index);
        checksum += runVariable(program, 3, cast(int) index);
        checksum += runVariable(program, 6, 12);
    }
    return checksum;
}

private void writeResult(scope File output, scope const Result result) {
    output.writefln(
        "%s,%s,%s,%s,%s,%s",
        result.format,
        result.compileNanoseconds,
        result.executeNanoseconds,
        result.compileNanoseconds + result.executeNanoseconds,
        result.codeBytes,
        result.checksum,
    );
}

public int main(string[] args) {
    size_t iterations = 2_000;
    string onlyFormat;
    foreach (argument; args[1 .. $]) {
        if (argument.startsWith("--iterations="))
            iterations = argument[13 .. $].to!size_t;
        else if (argument.startsWith("--format="))
            onlyFormat = argument[9 .. $];
        else {
            stderr.writeln("unknown argument: ", argument);
            return 2;
        }
    }

    const source = corpus;
    stdout.writeln(
        "format,compile_ns,execute_ns,total_ns,code_bytes,checksum",
    );
    Result[] results;
    if (onlyFormat.length == 0 || onlyFormat == "fixed32")
        results ~= measureFixed(source, iterations);
    if (onlyFormat.length == 0 || onlyFormat == "direct")
        results ~= measureDirect(source, iterations);
    if (onlyFormat.length == 0 || onlyFormat == "variable")
        results ~= measureVariable(source, iterations);
    if (results.length == 0) {
        stderr.writeln("unknown format: ", onlyFormat);
        return 2;
    }
    foreach (result; results) {
        assert(result.checksum == results[0].checksum);
        stdout.writeResult(result);
    }
    return 0;
}
