module ut.backends.bytecode.relocation;


import ut.backends;
import dmd.func: FuncDeclaration;
import snakebite.backends.backend: Program;
import snakebite.backends.bytecode.inspection:
    misplacedRelocs, relocsOf, unrecordedWords;
import snakebite.backends.bytecode.relocation: Place, Target;
import snakebite.backends.bytecode.vm:
    Function, Instruction, opConstant, specialisedHandlersWithoutRoles;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: to;
import std.file: readText;
import std.string: fromStringz, split, splitLines;


// Guest programs that between them put every kind of process address into
// compiled code: static data, thread-local storage, `typeid`, function
// pointers and delegates, assertion messages, native calls, class images,
// literal operands in the constant pool and a function that a caller copies.
// Each `run*` returns a checksum, so that a program also proves that it ran.
package enum addressPrograms = q{
    module relocation_guest;

    import core.stdc.stdlib: abs;

    int threadLocal = 5;
    __gshared int process = 7;
    immutable int[3] table = [1, 2, 3];
    string greeting = "hello";

    class Counter {
        int value;
        int get() { return value; }
    }

    int twice(int x) { return x * 2; }
    int small() { return process; }

    long runStatics() {
        threadLocal += 1;
        process += 2;
        return threadLocal + process + table[1] + greeting.length + small();
    }

    long runPointers() {
        auto pointer = &twice;
        int delegate(int) closure = (int x) => x + threadLocal;
        auto counter = new Counter;
        counter.value = 3;
        TypeInfo info = typeid(counter);
        return pointer(2) + closure(3) + counter.get() + (info is null ? 0 : 1)
            + twice(4);
    }

    long runStackClass() {
        scope counter = new Counter;
        counter.value = 4;
        return counter.get() + abs(-3);
    }

    long runChecks() {
        int[4] array = [1, 2, 3, 4];
        int index = 2;
        assert(array[index] == 3, "index two holds three");
        int[] slice = array[];
        long sum;
        foreach (position; 0 .. 4)
            sum += slice[position];
        if (sum > 100)
            assert(false, "the sum is small");
        return sum;
    }

    long runThrow() {
        try
            throw new Exception("caught");
        catch (Exception exception)
            return exception.msg.length;
        return 0;
    }

    long runLiterals() {
        long seed = 9;
        long total = seed * 3 + 5;
        if (total < 100 && total != 7)
            total -= 11;
        double scale = seed * 2.5;
        return total + cast(long) scale;
    }

    // Every statement starts a full expression, whose lifetime marker is
    // removed when the expression makes no temporary.
    long runRemap() {
        process = 11;
        process = process + 1;
        threadLocal = 2;
        process = 13;
        return process + threadLocal;
    }
};


package string[] entryPoints() {
    return [
        "runStatics", "runPointers", "runStackClass", "runChecks",
        "runThrow", "runLiterals", "runRemap",
    ];
}


private struct Range {
    size_t low;
    size_t high;
}

private Range[] mappedRanges() {
    Range[] ranges;
    foreach (line; readText("/proc/self/maps").splitLines) {
        const bounds = line.split[0].split("-");
        ranges ~= Range(bounds[0].to!size_t(16), bounds[1].to!size_t(16));
    }
    return ranges;
}

private bool isMapped(in Range[] ranges, in size_t word) {
    foreach (range; ranges)
        if (word >= range.low && word < range.high)
            return true;
    return false;
}

// Compiles and runs every entry point of `addressPrograms`, then shows each
// function that the backend compiled to `visit`.
private void withCompiledPrograms(
    scope void delegate(string, const(Function)*) visit,
) {
    auto guestModule = parseSnippet(addressPrograms);
    auto program = Program([guestModule]);
    auto backend = Owned!Bytecode(program);
    foreach (name; entryPoints) {
        long result;
        backend.call(findFunction(guestModule, name), &result, []);
    }
    backend.eachCompiled((FuncDeclaration declaration, const(Function)* function_) {
        visit(declaration.toPrettyChars.fromStringz.idup, function_);
    });
}

// A stored image has to find every address of the process in a function.
// An address that no `Reloc` names is one that would stay stale after the
// image loads into another process.
@("relocation.noAddressWordOfCompiledCodeIsUnrecorded")
unittest {
    const ranges = mappedRanges;
    string[] unrecorded;
    string[] misplaced;
    bool[Target.Kind] seen;
    withCompiledPrograms((name, function_) {
        foreach (word; unrecordedWords(function_, w => ranges.isMapped(w)))
            unrecorded ~= name ~ ": " ~ word;
        foreach (word; misplacedRelocs(function_))
            misplaced ~= name ~ ": " ~ word;
        foreach (reloc; relocsOf(function_))
            seen[reloc.target.kind] = true;
    });

    unrecorded.should == string[].init;
    misplaced.should == string[].init;
    // The programs reach every kind of address, so an empty scan is not a
    // scan that looked at nothing.
    foreach (kind; [
        Target.Kind.staticData, Target.Kind.tlsDescriptor,
        Target.Kind.typeInfo, Target.Kind.functionWord,
        Target.Kind.constantPool, Target.Kind.nativePlan,
        Target.Kind.frontendString,
    ])
        seen.get(kind, false).should == true;
}

@("relocation.scanFlagsAnAddressNoRelocNames")
unittest {
    static int target;
    const ranges = mappedRanges;
    const function_ = new Function(
        [Instruction(&opConstant, 0, 0, size_t.sizeof)],
        [cast(long) &target],
        [],
        [],
        [],
        size_t.sizeof,
        size_t.sizeof,
    );

    unrecordedWords(function_, w => ranges.isMapped(w)).length.should == 1;
}

// Handlers are rewritten after emission, and a rewritten handler has to keep
// the roles of the original: the compiler asks about the original and the
// loader of an image about the final one.
@("relocation.everySpecialisedHandlerHasRoles")
unittest {
    specialisedHandlersWithoutRoles.should == 0;
}

// Removing the lifetime markers of statements without temporaries moves
// every later instruction. A reloc that kept its old index would name an
// instruction that holds no address.
@("relocation.removingEmptyLifetimesKeepsRelocIndexes")
unittest {
    size_t staticRelocs;
    string[] misplaced;
    withCompiledPrograms((name, function_) {
        if (name != "relocation_guest.runRemap")
            return;
        foreach (reloc; relocsOf(function_))
            if (reloc.place.section == Place.Section.instruction
                    && reloc.target.kind == Target.Kind.staticData)
                ++staticRelocs;
        misplaced = misplacedRelocs(function_);
    });

    // Three stores and the final load of `process`, one in the order of the
    // source. The thread-local variable has descriptor relocs instead.
    (staticRelocs >= 4).should == true;
    misplaced.should == string[].init;
}
