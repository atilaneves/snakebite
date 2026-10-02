module snakebite.backends.guestfault;


private:


import snakebite.backends.haltprocess: Halted;


// Guest code that compiled D would kill with a signal: a null dereference
// or an integer division the hardware traps. A backend does not decide what
// happens next. It sets the halt flag of its run and calls the fault action
// of its `Program`, which the host that made the program chose:
//
//  - `bin/sb` runs the guest as the process: `endProcess` prints the message
//    and the guest call stack and ends the process, as compiled D dies.
//  - A session (the REPL, an in-process test) runs many calls in one
//    process: `throwFault`, the default, ends the one call with a
//    `GuestFaultException`.
//
// A fault is a halt: the exception is a `Halted`, so no guest `catch`,
// `finally`, `scope` guard or destructor sees it on the way up, in either
// backend, and druntime code that handles every `Exception` lets it pass.
// A crash inside native code that the guest calls is not guest code and
// stays a crash.
public struct GuestFault {
    public enum Kind {
        nullPointer,
        nullClassReference,
        nullFunctionPointer,
        nullDelegate,
        throwNull,
        divisionByZero,
        divisionOverflow,
    }

    public static string message(in Kind kind) @safe @nogc nothrow pure {
        final switch (kind) with (Kind) {
            case nullPointer:
                return "null pointer dereference";
            case nullClassReference:
                return "use of a null class reference";
            case nullFunctionPointer:
                return "call of a null function pointer";
            case nullDelegate:
                return "call of a null delegate";
            case throwNull:
                return "throw of a null reference";
            case divisionByZero:
                return "integer division by zero";
            case divisionOverflow:
                return "integer overflow in division";
        }
    }

    // The first page of the address space is never mapped. A load or a store
    // through an address in it faults, as a null pointer does: pointer
    // arithmetic on null (`*(p + 1)`) and the address of a field behind null
    // (`&p.field`) land in it.
    public enum firstPage = 4096;

    public static bool isNullAddress(in void* address) @trusted @nogc nothrow pure {
        return cast(size_t) address < firstPage;
    }

    // Whether the hardware traps on this division, and why: on a zero
    // divisor, and on the signed quotient that does not fit, the narrowest
    // value of the operand width divided by `-1`. `width` is the size in
    // bytes of the type that the division runs at.
    public static bool divisionFault(
        in long dividend, in long divisor, in size_t width, in bool unsigned,
        out Kind kind,
    ) @safe @nogc nothrow pure {
        if (divisor == 0) {
            kind = Kind.divisionByZero;
            return true;
        }

        if (!unsigned && divisor == -1
                && dividend == long.min >> (64 - width * 8)) {
            kind = Kind.divisionOverflow;
            return true;
        }

        return false;
    }

    // One guest function that was running at the fault, innermost first.
    // `line` is where the function is declared: that is enough to name a
    // `unittest` block, which has no name of its own.
    public struct Frame {
        public const(char)[] function_;
        public const(char)[] file;
        public size_t line;
    }

    // What an action gets and what it makes of it: the frames are visited
    // when the action asks, so that a backend keeps no call record while the
    // guest runs, and an action that only prints allocates nothing. A fault
    // can be in a destructor that the garbage collector runs, where an
    // allocation is an error.
    public alias FrameSink = void delegate(in Frame);
    public alias Stack = void delegate(scope FrameSink);
    public alias Action = noreturn function(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    );

    public static noreturn throwFault(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) {
        throw exceptionOf(kind, file, line, stack);
    }

    public static GuestFaultException exceptionOf(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) {
        const(Frame)[] frames;
        stack((in frame) {
            frames ~= Frame(
                frame.function_.idup, frame.file.idup, frame.line);
        });
        return new GuestFaultException(kind, file.idup, line, frames);
    }

    // The message and the stack, as `bin/sb` prints them and the REPL does
    // for a fault that no cell joins.
    public static void print(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) @trusted {
        import core.stdc.stdio: fflush, fprintf, stderr;

        const text = message(kind);
        fflush(null);
        fprintf(stderr, "%.*s(%llu): fatal: %.*s\n",
            cast(int) file.length, file.ptr, cast(ulong) line,
            cast(int) text.length, text.ptr);
        stack((in frame) {
            fprintf(stderr, "    in %.*s (%.*s(%llu))\n",
                cast(int) frame.function_.length, frame.function_.ptr,
                cast(int) frame.file.length, frame.file.ptr,
                cast(ulong) frame.line);
        });
        fflush(stderr);
    }

    // The action of a process that runs only the guest: compiled D dies of
    // the signal with no guest cleanup, and so does this.
    public static noreturn endProcess(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) {
        import core.stdc.stdlib: _Exit;

        print(kind, file, line, stack);
        _Exit(1);
    }
}


// What a call into native code needs before it runs: native code that gets
// it wrong dies of a signal, and a guest that does so is a guest fault. The
// shared plan names the check of a callee (`nativeCallCheckOf`), and each
// backend runs it on the arguments of the call, in native layout.
public struct NativeCallCheck {
    public enum noArgument = size_t.max;

    // An array operation, as the Reverse Polish Notation that dmd gives
    // the loop that runs it, over one element at a time. The loop is native
    // code, and a division in it that traps kills the process, so the check
    // runs the steps on the elements to see whether one does. The result
    // array is argument 0 and has the length of every array operand.
    public struct ArrayOperation {
        public struct Operand {
            public size_t argument;
            public bool isSlice;
            public size_t elementSize;
            public bool integral;
            public bool unsigned;
        }

        public struct Step {
            public enum Kind {
                operand,
                negate,
                complement,
                add,
                subtract,
                multiply,
                divide,
                modulo,
                // The store of the result: no value is left.
                assign,
                // Operations whose result the check does not follow: it has
                // no known value.
                unknownUnary,
                unknownBinary,
            }

            public Kind kind;
            // The operand that `Kind.operand` pushes. For a compound
            // assignment (`a[] /= b[]`) it is the element of the result that
            // is the left operand of the step.
            public Operand operand;
            public bool assignsToResult;
        }

        public Step[] steps;
    }

    // `x ^^ n` of integers is a call of `pow`, which divides by zero for a
    // base of zero and a negative exponent. The base is argument 0 and the
    // exponent is argument 1.
    public struct IntegerPower {
        public bool present;
        public size_t baseSize;
        public size_t exponentSize;
        public bool exponentIsSigned;
    }

    // An argument that must not be null, as the monitor that `synchronized`
    // locks or the array that a hook changes by `ref`, and the failure when
    // it is.
    public size_t nonNull = noArgument;
    public GuestFault.Kind nonNullKind;
    public ArrayOperation arrayOperation;
    public IntegerPower integerPower;

    public bool failure(
        scope const(void*)[] arguments, out GuestFault.Kind kind,
    ) const {
        if (nonNull != noArgument
                && GuestFault.isNullAddress(
                    *cast(const(void*)*) arguments[nonNull])) {
            kind = nonNullKind;
            return true;
        }

        if (integerPower.present && integerPower.fails(arguments)) {
            kind = GuestFault.Kind.divisionByZero;
            return true;
        }

        return arrayOperation.steps.length != 0
            && arrayOperation.fails(arguments, kind);
    }
}

private bool fails(
    in NativeCallCheck.IntegerPower power, scope const(void*)[] arguments,
) @trusted @nogc nothrow {
    import snakebite.nativevalue: loadSigned, loadUnsigned;

    return power.exponentIsSigned
        && loadUnsigned(cast(const(ubyte)*) arguments[0], power.baseSize) == 0
        && loadSigned(cast(const(ubyte)*) arguments[1], power.exponentSize) < 0;
}

// A value that an array operation computes for one element: the type that
// D gives it, and the number, if the check knows it.
private struct Value {
    long number;
    size_t size;
    bool unsigned;
    bool known;
}

private bool fails(
    in NativeCallCheck.ArrayOperation operation,
    scope const(void*)[] arguments, out GuestFault.Kind kind,
) @trusted {
    alias Kind = NativeCallCheck.ArrayOperation.Step.Kind;

    const length = *cast(const(size_t)*) arguments[0];
    // The array operation reports a length mismatch itself.
    foreach (step; operation.steps) {
        if (step.kind == Kind.operand && step.operand.isSlice
            && *cast(const(size_t)*) arguments[step.operand.argument] != length)
            return false;
    }

    auto stack = new Value[operation.steps.length];
    foreach (index; 0 .. length) {
        size_t top;
        foreach (step; operation.steps) {
            final switch (step.kind) with (Kind) {
                case operand:
                    stack[top++] = valueOf(step.operand, arguments, index);
                    break;
                case negate:
                    stack[top - 1] = negated(stack[top - 1]);
                    break;
                case complement:
                    stack[top - 1] = complemented(stack[top - 1]);
                    break;
                case assign:
                    --top;
                    break;
                case unknownUnary:
                    stack[top - 1] = Value.init;
                    break;
                case unknownBinary:
                    --top;
                    if (!step.assignsToResult)
                        stack[top - 1] = Value.init;
                    break;
                case add:
                case subtract:
                case multiply:
                case divide:
                case modulo:
                    const right = stack[--top];
                    const left = step.assignsToResult
                        ? valueOf(step.operand, arguments, index)
                        : stack[--top];
                    if (step.kind == Kind.divide || step.kind == Kind.modulo) {
                        if (divisionFails(left, right, kind))
                            return true;
                    }
                    if (!step.assignsToResult)
                        stack[top++] = combined(step.kind, left, right);
                    break;
            }
        }
    }

    return false;
}

private Value valueOf(
    in NativeCallCheck.ArrayOperation.Operand operand,
    scope const(void*)[] arguments, in size_t index,
) @trusted @nogc nothrow {
    import snakebite.nativevalue: loadSigned, loadUnsigned;

    if (!operand.integral)
        return Value.init;

    const place = operand.isSlice
        ? *cast(const(ubyte*)*) (
            cast(const(ubyte)*) arguments[operand.argument] + size_t.sizeof)
            + index * operand.elementSize
        : cast(const(ubyte)*) arguments[operand.argument];
    return promoted(Value(
        operand.unsigned
            ? cast(long) loadUnsigned(place, operand.elementSize)
            : loadSigned(place, operand.elementSize),
        operand.elementSize, operand.unsigned, true));
}

// Integral promotion: a type narrower than `int` is an `int`.
private Value promoted(in Value value) @safe @nogc nothrow pure {
    return value.size < 4 ? Value(value.number, 4, false, value.known) : value;
}

// The value at the width and the signedness of its type: what the machine
// does with a result that does not fit.
private Value wrapped(
    in long number, in size_t size, in bool unsigned,
) @safe @nogc nothrow pure {
    if (size == 8)
        return Value(number, size, unsigned, true);

    return Value(
        unsigned ? cast(long) cast(uint) number : cast(long) cast(int) number,
        size, unsigned, true);
}

// The type of a binary operation: the wider operand decides, and the
// unsigned one when they are equally wide.
private Value[2] converted(in Value left, in Value right) @safe @nogc nothrow pure {
    const size = left.size > right.size ? left.size : right.size;
    const unsigned = left.size == right.size
        ? left.unsigned || right.unsigned
        : left.size > right.size ? left.unsigned : right.unsigned;
    return [
        wrapped(left.number, size, unsigned),
        wrapped(right.number, size, unsigned),
    ];
}

private Value negated(in Value operand) @safe @nogc nothrow pure {
    if (!operand.known)
        return Value.init;

    const value = promoted(operand);
    return wrapped(-value.number, value.size, value.unsigned);
}

private Value complemented(in Value operand) @safe @nogc nothrow pure {
    if (!operand.known)
        return Value.init;

    const value = promoted(operand);
    return wrapped(~value.number, value.size, value.unsigned);
}

private bool divisionFails(
    in Value left, in Value right, out GuestFault.Kind kind,
) @safe @nogc nothrow pure {
    if (!left.known || !right.known)
        return false;

    const both = converted(left, right);
    return GuestFault.divisionFault(both[0].number, both[1].number,
        both[0].size, both[0].unsigned, kind);
}

private Value combined(
    in NativeCallCheck.ArrayOperation.Step.Kind kind,
    in Value left, in Value right,
) @safe @nogc nothrow pure {
    alias Kind = NativeCallCheck.ArrayOperation.Step.Kind;

    if (!left.known || !right.known)
        return Value.init;

    const both = converted(left, right);
    const a = both[0].number;
    const b = both[1].number;
    const size = both[0].size;
    const unsigned = both[0].unsigned;
    switch (kind) {
        case Kind.add:
            return wrapped(a + b, size, unsigned);
        case Kind.subtract:
            return wrapped(a - b, size, unsigned);
        case Kind.multiply:
            return wrapped(a * b, size, unsigned);
        case Kind.divide:
            if (b == 0 || (!unsigned && b == -1))
                return Value.init;

            return unsigned
                ? wrapped(cast(long) (cast(ulong) a / cast(ulong) b), size, true)
                : wrapped(a / b, size, false);
        case Kind.modulo:
            if (b == 0 || (!unsigned && b == -1))
                return Value.init;

            return unsigned
                ? wrapped(cast(long) (cast(ulong) a % cast(ulong) b), size, true)
                : wrapped(a % b, size, false);
        default:
            assert(0, "combined is for a binary arithmetic step");
    }
}


public final class GuestFaultException: Halted {
    import std.conv: text;

    public const GuestFault.Kind kind;
    public const(GuestFault.Frame)[] stack;

    // Whether the host already printed the fault, so that whoever gets the
    // exception later, such as a thread that joins the faulting thread, does
    // not report it a second time.
    public bool reported;

    public this(
        in GuestFault.Kind kind,
        string file,
        in size_t line,
        const(GuestFault.Frame)[] stack,
    ) {
        super(text(file, "(", line, "): fatal: ", GuestFault.message(kind)),
            file, line);
        this.kind = kind;
        this.stack = stack;
    }
}
