module snakebite.backends.bytecode.compiler;


private:

import dmd.visitor: Visitor;
import snakebite.ffi: maxArguments, PlanCache;


// Whether this compiler can lay `facts` out in a frame slot at all: an
// integral of a width `nativelayout.storeIntegral` knows, or a dynamic
// array, always `nativelayout.arrayValueSize` bytes as its own two-word
// `{length, pointer}` pair regardless of its element type. Shared between
// `Bytecode.compileFunction`'s parameter/return checks and
// `FunctionCompiler.compileCall`'s, which ask the same question of a
// callee's own signature.
private bool isSupportedFacts(
    in imported!"snakebite.nativelayout".TypeFacts facts,
) {
    import snakebite.nativelayout: isIntegralSize;

    return facts.isDynamicArray
        || (facts.isIntegral && isIntegralSize(facts.size));
}

// As above, for a caller that also has `type` in hand and so can ask the
// one further question `TypeFacts` alone cannot answer: whether `type` is
// a struct this compiler can copy bytewise (see `isPlainOldStruct`).
private bool isSupportedFacts(
    in imported!"snakebite.nativelayout".TypeFacts facts,
    imported!"dmd.mtype".Type type,
) {
    return isSupportedFacts(facts) || isPlainOldStruct(type);
}

// Whether this compiler can treat `type` as plain bytes it never has to
// call guest code to copy, construct or destroy: a struct with no
// postblit, copy constructor, destructor or user-defined assignment, not a
// `union` (whose fields this compiler cannot lay out from a plain field
// list) and not nested in an enclosing scope (a local struct with its own
// `this` captured context, unsupported the same way a method is), whose
// every field is itself one of an integral this compiler already lays
// out, a dynamic array (a plain two-word slice, copied the same way an
// integral field is - by value, sharing whatever it points at), or a
// nested struct meeting this same predicate. `declaration.zeroInit` is
// required too: this compiler's only default-value story for a struct is
// zeroing its bytes (see `opZero`), the same way `nativelayout.storeValue`
// already special-cases a zero-init struct's own `.init` elsewhere.
private bool isPlainOldStruct(imported!"dmd.mtype".Type type) {
    import dmd.astenums: STC, Tarray;
    import snakebite.nativelayout: isIntegralSize, TypeFacts;

    auto structType = type.isTypeStruct;
    if (structType is null)
        return false;

    auto declaration = structType.sym;
    if (!declaration.zeroInit
            || declaration.isUnionDeclaration !is null
            || declaration.enclosing !is null
            || declaration.postblit !is null || declaration.hasCopyCtor
            || declaration.dtor !is null
            || declaration.hasIdentityAssign || declaration.hasBlitAssign)
        return false;

    foreach (field; declaration.fields) {
        if (field.isBitFieldDeclaration !is null
                || (field.storage_class & STC.ref_))
            return false;

        if (field.type.isTypeStruct !is null) {
            if (!isPlainOldStruct(field.type))
                return false;
            continue;
        }

        if (field.type.ty == Tarray)
            continue;

        const facts = TypeFacts.of(field.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            return false;
    }

    return true;
}

// Whether `type` is `float`/`double` - `TypeFacts` has no notion of its own
// for this, since nothing outside array element types and their literals
// needs to ask, unlike `isIntegral`/`isDynamicArray`, which drive checks
// all over this compiler.
private bool isFloatingType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tfloat32, Tfloat64;

    return type.ty == Tfloat32 || type.ty == Tfloat64;
}

// A pointer-sized temporary's facts: the shape every address this compiler
// computes at run time - a `ref` binding, an array element's, an
// allocation's result - shares, whatever the value living behind it
// eventually is.
private imported!"snakebite.nativelayout".TypeFacts pointerFactsOf() {
    import snakebite.nativelayout: TypeFacts;

    return TypeFacts(size_t.sizeof, size_t.sizeof, false, true);
}

// An array element type this compiler can lay out: every integral width it
// already accepts elsewhere, plus `float`/`double`, which have no `.init`
// this compiler can write any other way but zero.
private bool isSupportedElementFacts(
    in imported!"snakebite.nativelayout".TypeFacts facts,
    imported!"dmd.mtype".Type type,
) {
    import snakebite.nativelayout: isIntegralSize;

    return (facts.isIntegral && isIntegralSize(facts.size))
        || isFloatingType(type)
        || isPlainOldStruct(type);
}


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Function, maxReturnWidth, Vm;
    import snakebite.exception: SnakebiteException;
    import snakebite.framestack: defaultFrameCapacity;

    private Vm _vm;
    private PlanCache _plans;
    // Keyed by pointer, not by value: a call site compiled while
    // `function_` itself is still mid-compile - direct or mutual
    // recursion - embeds this pointer in its `CallSite` before the body
    // this AA slot points at has been filled in. The slot's address must
    // therefore never move once handed out, which is why this holds a
    // `Function*` rather than a `Function` - a heap block `new` allocates
    // once and never relocates, unlike an associative array's own
    // storage, which can rehash as more entries go in.
    private Function*[FuncDeclaration] _compiled;
    // The resolved address of druntime's own allocator, looked up once and
    // reused by every `new T[](n)`/array literal any function compiles -
    // the same `Resolver` `_plans` already owns, so this costs nothing new
    // besides the one symbol lookup.
    private void* _allocatorAddress;

    public this(const Program program) {
        super(program);
        _vm = Vm(defaultFrameCapacity);
    }

    public void compile(Program program) {
        if (program.main.func is null)
            throw new SnakebiteException(
                "bytecode compiler needs a program entry function",
            );

        compileFunction(program.main.func);
    }

    public override void call(
        FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        if (args.length != 0)
            throw new SnakebiteException(
                "bytecode compiler does not support host-to-guest " ~
                    "arguments yet",
            );

        _vm.call(*compileFunction(function_), returnPlace);
    }

    public override string eval(FuncDeclaration function_) {
        throw new SnakebiteException(
            "eval not implemented for the bytecode backend yet",
        );
    }

    package bool hasNativeSymbol(FuncDeclaration function_) {
        return _plans.hasNativeSymbol(function_);
    }

    // The address of druntime's own `gc_malloc`, the real allocator a
    // `new T[](n)`/array literal calls through the same FFI `Resolver`
    // every guest-declared native call already goes through - never a
    // private bump allocator or free list of this compiler's own.
    package void* allocatorAddress() {
        if (_allocatorAddress is null) {
            _allocatorAddress = _plans.resolve("gc_malloc");
            if (_allocatorAddress is null)
                throw new SnakebiteException(
                    "bytecode compiler cannot resolve druntime's " ~
                        "`gc_malloc`",
                );
        }

        return _allocatorAddress;
    }

    // `function_`'s compiled form, compiling it - and, transitively,
    // whatever it calls - on first use. Reused on every later call to the
    // same function, the way compiled code only ever compiles a function
    // once. Returns a stable pointer (see `_compiled`) so a call site
    // reached while this very function is still being compiled can point
    // at it too.
    package const(Function)* compileFunction(FuncDeclaration function_) {
        import dmd.astenums: STC, Tvoid;
        import snakebite.backends.layout: FrameLayout;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.nativelayout: TypeFacts;
        import std.conv: text;

        if (function_ is null)
            throw new SnakebiteException(
                "bytecode compiler cannot compile a null function",
            );

        if (auto found = function_ in _compiled)
            return *found;

        // A struct method's hidden `this` is not a value this compiler
        // lays out yet; only a free function's own parameters are.
        if (function_.vthis !is null)
            throw rejection(function_, function_.loc, "a method");

        auto functionType = typeFunctionOf(function_);
        auto returnType = function_.type.nextOf;
        const isVoidReturn = returnType !is null && returnType.ty == Tvoid;
        // A `ref` return hands the caller the returned storage's own
        // address rather than a copy of its value - see `compileReturn` and
        // `compileAddress` - so the frame slot a caller reads it into is
        // one pointer wide regardless of what the returned type itself
        // would otherwise need, the same convention `snakebite.ffi.plan`
        // already uses for a native `ref`-returning callee.
        const isRefReturn = functionType.isRef;
        const pointeeFacts = isVoidReturn ? TypeFacts.init : TypeFacts.of(returnType);
        if (!isVoidReturn && (!isSupportedFacts(pointeeFacts, returnType)
                || (!isRefReturn && pointeeFacts.size > maxReturnWidth)))
            throw rejection(function_, function_.loc, text(
                "a `", returnType is null ? "auto" : returnType.toString,
                "` return",
            ));
        const returnFacts = isRefReturn ? pointerFactsOf : pointeeFacts;

        foreach (i; 0 .. functionType.parameterList.length) {
            auto parameter = functionType.parameterList[i];
            if (parameter.storageClass & (STC.out_ | STC.lazy_))
                throw rejection(function_, function_.loc,
                    "an `out`/`lazy` parameter");

            const facts = TypeFacts.of(parameter.type);
            if (!isSupportedFacts(facts, parameter.type))
                throw rejection(function_, function_.loc, text(
                    "a `", parameter.type.toString, "` parameter"));
        }

        auto body_ = function_.fbody;
        if (body_ is null)
            throw rejection(function_, function_.loc,
                "a function with no body");

        auto layout = FrameLayout.of(function_);

        // Registered before the body is walked, not after: a call inside
        // this very body to `function_` itself finds this placeholder
        // through `_compiled` above instead of recompiling forever. Its
        // fields are filled in below, once `build` returns; nothing reads
        // them before then, since a `CallSite`'s callee is only ever
        // dereferenced when the VM actually runs the call, which cannot
        // happen before `compile`/`call` returns from the top-level
        // compile that reached here.
        auto placeholder = new Function;
        _compiled[function_] = placeholder;

        scope compiler = new FunctionCompiler(
            this, function_, layout, returnFacts, isVoidReturn, isRefReturn);
        *placeholder = compiler.build(body_);

        return placeholder;
    }
}


// Compiles one function's body into bytecode against its already-computed
// declared-storage layout (`_layout`, shared with the interpreter). Beyond
// that layout's own `size`, this owns every byte the compiled function
// needs for its own temporaries - a call's arguments, a return value on
// its way out, an operand of a nested expression - by growing
// `_tempSize`/`_tempAlignment` past it; nothing about a temporary slot is
// ever handed back through `FrameLayout` itself.
extern(C++) private final class FunctionCompiler: Visitor {
    import dmd.declaration: VarDeclaration;
    import dmd.init: ExpInitializer;
    import dmd.expression;
    import dmd.func: FuncDeclaration;
    import dmd.statement:
        CompoundStatement, ContinueStatement, ExpStatement, ForStatement,
        IfStatement, ImportStatement, ReturnStatement, ScopeStatement,
        Statement, WhileStatement;
    import dmd.tokens: EXP;
    import snakebite.backends.bytecode.vm:
        Arg, AssertSite, CallSite, discardResult, Function, Instruction,
        opAdd, opAssert, opBitAnd, opBitOr, opBitXor, opBranchFalse,
        opBranchTrue, opCall,
        opCastToBool, opCastWidenSigned, opCastWidenUnsigned, opComplement,
        opConstant, opCopy, opDivideSigned, opDivideUnsigned, opEqual,
        opFloatEqual, opFloatNotEqual, opFrameAddress, opGreaterOrEqualSigned,
        opGreaterOrEqualUnsigned, opGreaterThanSigned, opGreaterThanUnsigned,
        opJump, opLessOrEqualSigned, opLessOrEqualUnsigned, opLessThanSigned,
        opLessThanUnsigned, opLoadIndirect, opLogicalNot, opModuloSigned,
        opModuloUnsigned, opMultiply, opNegate, opNotEqual, opReturn,
        opReturnVoid, opShiftLeft, opShiftRightArithmetic, opShiftRightLogical,
        opStoreIndirect, opSubtract, opZero;
    import snakebite.backends.layout: FrameLayout;
    import snakebite.exception: SnakebiteException;
    import snakebite.nativelayout: alignUp, isIntegralSize, TypeFacts;

    alias visit = Visitor.visit;

    extern(D):

    private Bytecode _bytecode;
    private FuncDeclaration _function;
    private const FrameLayout _layout;
    private TypeFacts _returnFacts;
    private bool _isVoidReturn;
    // Whether this function returns by `ref`: `compileReturn` then compiles
    // its own returned storage's address instead of its value, and a
    // caller's own `opCall` result slot holds that address rather than a
    // copy - see `compileAddress`'s own `CallExp` case, the one place that
    // address is read back out.
    private bool _isRefReturn;

    private Instruction[] _instructions;
    private long[] _constants;
    private CallSite[] _callSites;
    private AssertSite[] _assertSites;
    private size_t _tempSize;
    private uint _tempAlignment;
    // Set once nothing after the statement just compiled can run: a
    // `return`, a `continue`, or an `if`/loop whose every path already
    // ends one of those. Every statement kind after one in the same block
    // is dead code dmd itself only warns about, so nothing is compiled
    // for it, and none of its own kinds need this compiler to recognise
    // them. Reset by whichever construct (`if`, a loop) knows execution
    // can still reach past it - a `continue` inside a loop body, say,
    // does not end the loop itself.
    private bool _finished;
    // The loop this compiler is currently inside the body of, innermost
    // last - what an unlabelled `continue` targets. A `while` already
    // knows its own continue target (the condition it re-checks) the
    // moment it starts compiling its body; a `for`'s is its increment,
    // compiled only after the body is, so a `continue` reached first
    // records its own instruction's index here instead and
    // `resolveContinues` patches every one of them in once the target is
    // known.
    private struct LoopContext {
        size_t continueTarget = size_t.max;
        size_t[] pendingContinueJumps;
    }
    private LoopContext[] _loops;
    private size_t _destination;
    private size_t _width;
    // The `$` currently in scope, if any: the `VarDeclaration` dmd hands
    // out for it (`IndexExp.lengthVar`) and where its value - the
    // enclosing array's own length, already evaluated - sits in this
    // frame. `compileElementAddress` binds this around compiling an
    // index's own expression and restores whatever was there before once
    // it is done, the same way a nested `$` inside that index (a call's
    // own argument, say) must see its own array's length rather than this
    // one's.
    private VarDeclaration _dollarVariable;
    private size_t _dollarOffset;

    public this(
        Bytecode bytecode,
        FuncDeclaration function_,
        in FrameLayout layout,
        in TypeFacts returnFacts,
        in bool isVoidReturn,
        in bool isRefReturn,
    ) {
        _bytecode = bytecode;
        _function = function_;
        _layout = layout;
        _returnFacts = returnFacts;
        _isVoidReturn = isVoidReturn;
        _isRefReturn = isRefReturn;
        _tempSize = layout.size;
        _tempAlignment = layout.alignment;
    }

    public Function build(Statement body_) {
        compileStatement(body_);

        if (!_finished) {
            if (!_isVoidReturn)
                throw rejection(_function, _function.loc,
                    "a body that does not return on every path");

            emit(&opReturnVoid, 0, 0, 0);
        }

        resolveBranches();

        return Function(
            _instructions, _constants, _callSites, _assertSites,
            _tempSize, _tempAlignment,
        );
    }

    private void emit(
        Instruction.Handler handler,
        in size_t destination,
        in size_t source,
        in size_t width,
    ) {
        _instructions ~= Instruction(handler, destination, source, width);
    }

    private size_t addConstant(in long value) {
        _constants ~= value;
        return _constants.length - 1;
    }

    // Grows this compiled function's own frame past whatever `_layout`
    // already reserved, for a value only this compiler's own generated
    // code ever reads or writes - a call's argument, a return value on
    // its way to `returnPlace`, an expression's operand. Never reachable
    // through `_layout.offsetOf`, which only ever answers for a declared
    // parameter or local.
    private size_t reserveTemp(in TypeFacts facts) {
        const offset = alignUp(_tempSize, facts.alignment);
        _tempSize = offset + facts.size;
        if (facts.alignment > _tempAlignment)
            _tempAlignment = facts.alignment;

        return offset;
    }

    // Every `opJump`/`opBranchFalse`/`opBranchTrue` this compiler emitted
    // still names its target by a plain instruction index at this point -
    // `compileIf`/`compileWhile`/`compileFor`/`compileContinue` patch
    // that index in once they know it, but never resolve it to an
    // address themselves, since `_instructions` can still grow (and so
    // move, on a reallocation) at any point before `build` returns. Once
    // it has stopped growing, out-of-range indices are refused - the
    // compiler's own bug, since every index this compiler itself ever
    // wrote names a position within the same, single pass of
    // instructions, but refused here rather than trusted, since a wrong
    // one would otherwise send the VM to run whatever instructions
    // happen to sit at that address instead of failing loudly - and the
    // rest are rewritten from that index to the address it names, which
    // is what every branch opcode above expects to find.
    private void resolveBranches() {
        import std.conv: text;

        foreach (ref instruction; _instructions) {
            auto target = branchTargetField(instruction);
            if (target is null)
                continue;

            if (*target >= _instructions.length)
                throw new SnakebiteException(text(
                    "bytecode compiler produced an out-of-range branch " ~
                    "target ", *target, " for `", _function.toString, "`",
                ));

            *target = cast(size_t) &_instructions[*target];
        }
    }

    private size_t* branchTargetField(ref Instruction instruction) {
        if (instruction.handler is &opJump)
            return &instruction.destination;

        if (instruction.handler is &opBranchFalse
                || instruction.handler is &opBranchTrue)
            return &instruction.source;

        return null;
    }

    private void compileStatement(Statement statement) {
        if (_finished || statement is null)
            return;

        statement.accept(this);
    }

    extern(C++):

    override void visit(Statement statement) {
        throw rejection(_function, statement.loc, statementText(statement));
    }

    override void visit(CompoundStatement statement) {
        if (statement.statements is null)
            return;

        foreach (child; *statement.statements) {
            compileStatement(child);
            if (_finished)
                return;
        }
    }

    override void visit(ScopeStatement statement) {
        compileStatement(statement.statement);
    }

    override void visit(ImportStatement statement) {
    }

    override void visit(ReturnStatement statement) {
        compileReturn(statement);
    }

    override void visit(ExpStatement statement) {
        if (statement.exp !is null)
            compileEffect(statement.exp);
    }

    override void visit(IfStatement statement) {
        compileIf(statement);
    }

    override void visit(WhileStatement statement) {
        compileWhile(statement);
    }

    override void visit(ForStatement statement) {
        compileFor(statement);
    }

    override void visit(ContinueStatement statement) {
        compileContinue(statement);
    }

    extern(D):

    private void compileReturn(ReturnStatement statement) {
        _finished = true;

        // A `void` return's own expression, when it has one, is only the
        // synthetic `0` dmd appends to `main` - nowhere to write it, so it
        // is discarded the same way the interpreter discards it.
        if (_isVoidReturn || statement.exp is null) {
            emit(&opReturnVoid, 0, 0, 0);
            return;
        }

        if (_isRefReturn) {
            const addressOffset = compileAddress(statement.exp);
            emit(&opReturn, 0, addressOffset, size_t.sizeof);
            return;
        }

        const offset = reserveTemp(_returnFacts);
        evalInto(statement.exp, offset, _returnFacts.size);
        emit(&opReturn, 0, offset, _returnFacts.size);
    }

    // The condition of an `if`, a `while`/`for`, or a ternary: read at its
    // own type's width, not necessarily `bool` - `if (one())`, `one()`
    // returning `int`, is truthy exactly when its low bytes are nonzero,
    // the same test `opBranchFalse`/`opBranchTrue` already make of
    // whatever width they are handed.
    //
    // A dynamic array has no such single width of its own to test: its
    // truthiness is D's `ptr !is null` rule, not "any of its sixteen bytes
    // is nonzero" (a zero-length array over real storage is still `true`),
    // so this evaluates the array once and hands back its pointer word
    // alone - `conditionWidth` below reports that same narrower width for
    // it, not the array's own full size.
    private size_t compileCondition(Expression condition) {
        import snakebite.nativelayout: arrayPointerOffset;

        const facts = TypeFacts.of(condition.type);
        if (facts.isDynamicArray) {
            const arrayOffset = reserveTemp(facts);
            evalInto(condition, arrayOffset, facts.size);
            return arrayOffset + arrayPointerOffset;
        }

        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, condition.loc,
                expressionText(condition));

        const offset = reserveTemp(facts);
        evalInto(condition, offset, facts.size);
        return offset;
    }

    private size_t conditionWidth(Expression condition) {
        const facts = TypeFacts.of(condition.type);
        return facts.isDynamicArray ? size_t.sizeof : facts.size;
    }

    // `assert(cond)`: evaluated the same way an `if`'s own condition is,
    // then handed to `opAssert`, which throws a real `AssertError` at run
    // time when it is false and otherwise falls through - the only two
    // things D's own assertion semantics call for.
    //
    // dmd gives an `AssertExp` whose condition it can already prove false at
    // compile time (`assert(0)`, `assert(false)`, `assert(1 == 2)`) the
    // `noreturn` type for flow analysis, but that changes nothing about how
    // this compiles: with asserts enabled - `useAssert == CHECKENABLE.off`
    // is what turns one into a plain trap (dmd's own `HaltExp`, a different
    // node this compiler never sees here) - it still throws the same
    // `AssertError` at the same instant a call to `fail()` returning `false`
    // would, so `opAssert` handles both without asking which one this is.
    private void compileAssert(AssertExp expression) {
        import std.conv: text;
        import std.string: fromStringz;

        const conditionOffset = compileCondition(expression.e1);
        const width = conditionWidth(expression.e1);

        const site = AssertSite(
            text("bytecode: assertion failed: `", expression.e1.toString, "`"),
            expression.loc.filename.fromStringz.idup,
            expression.loc.linnum,
        );
        _assertSites ~= site;
        emit(&opAssert, conditionOffset, _assertSites.length - 1, width);
    }

    // Only the branch taken at run time ever executes - the other one, if
    // there is one, does not even get instructions emitted for it that
    // never run, the same way an untaken `if` skips them at run time in
    // the interpreter. Finished (see `_finished`'s own doc) only when
    // there is an `else` and both branches are.
    private void compileIf(IfStatement statement) {
        const conditionOffset = compileCondition(statement.condition);
        const width = conditionWidth(statement.condition);

        const branchIndex = _instructions.length;
        emit(&opBranchFalse, conditionOffset, 0, width);

        compileStatement(statement.ifbody);
        const ifFinished = _finished;

        if (statement.elsebody is null) {
            _instructions[branchIndex].source = _instructions.length;
            _finished = false;
            return;
        }

        _finished = false;
        // Skipped when the `if` branch already ended in a `return`/
        // `continue`: nothing would ever reach this jump, so emitting it
        // would leave a dead instruction whose target - one past the
        // `else` branch's own last instruction - does not exist at all
        // when the `else` branch also always ends its own path, since
        // then nothing follows this whole `if` either and `build` never
        // appends a trailing instruction for it to land on.
        size_t jumpIndex = size_t.max;
        if (!ifFinished) {
            jumpIndex = _instructions.length;
            emit(&opJump, 0, 0, 0);
        }
        _instructions[branchIndex].source = _instructions.length;

        compileStatement(statement.elsebody);
        const elseFinished = _finished;
        if (jumpIndex != size_t.max)
            _instructions[jumpIndex].destination = _instructions.length;

        _finished = ifFinished && elseFinished;
    }

    // A condition that is a nonzero literal - `1`, in place of `true`,
    // dmd's own way of spelling an infinite `for`/`while` - is always
    // taken, so a loop headed by one, or by no condition at all
    // (`for (;;)`), never falls out of its own bottom the way one whose
    // condition can become false does.
    private bool isTriviallyTrueCondition(Expression condition) {
        if (condition is null)
            return true;

        auto integer = condition.isIntegerExp;
        return integer !is null && integer.toInteger != 0;
    }

    private void compileWhile(WhileStatement statement) {
        const loopStart = _instructions.length;
        // A condition that can never be false - `while (1)` - is never
        // guarded: the check itself would still compile correctly, but
        // its false branch would then target the position right after
        // this loop's own last instruction, which exists only when
        // something follows the loop in source. Nothing does when a
        // trivially-true loop is a function's own last statement (its
        // body returns unconditionally instead), and a branch aimed
        // one past the last instruction is exactly what `resolveBranches`
        // exists to catch.
        const guarded = !isTriviallyTrueCondition(statement.condition);
        size_t branchIndex = size_t.max;
        if (guarded) {
            const conditionOffset = compileCondition(statement.condition);
            const width = conditionWidth(statement.condition);
            branchIndex = _instructions.length;
            emit(&opBranchFalse, conditionOffset, 0, width);
        }

        _loops ~= LoopContext(loopStart);
        compileStatement(statement._body);
        _loops = _loops[0 .. $ - 1];
        _finished = false;

        emit(&opJump, loopStart, 0, 0);
        if (branchIndex != size_t.max)
            _instructions[branchIndex].source = _instructions.length;

        _finished = !guarded;
    }

    private void compileFor(ForStatement statement) {
        if (statement._init !is null)
            compileStatement(statement._init);

        // See `compileWhile`'s own doc for why a trivially-true condition
        // is never guarded.
        const guarded = statement.condition !is null
            && !isTriviallyTrueCondition(statement.condition);
        const conditionIndex = _instructions.length;
        size_t branchIndex = size_t.max;
        if (guarded) {
            const conditionOffset = compileCondition(statement.condition);
            const width = conditionWidth(statement.condition);
            branchIndex = _instructions.length;
            emit(&opBranchFalse, conditionOffset, 0, width);
        }

        _loops ~= LoopContext();
        compileStatement(statement._body);
        _finished = false;

        const incrementIndex = _instructions.length;
        resolveContinues(incrementIndex);
        _loops = _loops[0 .. $ - 1];

        if (statement.increment !is null)
            compileEffect(statement.increment);

        emit(&opJump, conditionIndex, 0, 0);

        if (branchIndex != size_t.max)
            _instructions[branchIndex].source = _instructions.length;

        _finished = !guarded;
    }

    private void compileContinue(ContinueStatement statement) {
        if (statement.ident !is null)
            throw rejection(_function, statement.loc, statementText(statement));

        if (_loops.length == 0)
            throw rejection(_function, statement.loc, statementText(statement));

        auto target = _loops[$ - 1].continueTarget;
        if (target != size_t.max) {
            emit(&opJump, target, 0, 0);
        } else {
            _loops[$ - 1].pendingContinueJumps ~= _instructions.length;
            emit(&opJump, 0, 0, 0);
        }

        _finished = true;
    }

    private void resolveContinues(in size_t target) {
        foreach (index; _loops[$ - 1].pendingContinueJumps)
            _instructions[index].destination = target;
    }

    // Runs `expression` for effect, at statement level: whatever value it
    // produces (a call's return, an assignment's own value) is never read.
    private void compileEffect(Expression expression) {
        const destination = _destination;
        const width = _width;
        scope (exit) {
            _destination = destination;
            _width = width;
        }

        _destination = discardResult;
        _width = 0;
        expression.accept(this);
    }

    // Runs a local's initialiser into the frame slot `_layout` already
    // gave it - `int sum = 0;` is a `DeclarationExp` here, the same as in
    // the interpreter.
    private void compileDeclaration(DeclarationExp expression) {
        // A function-local struct declaration binds a name to a type
        // dmd's semantic pass has already resolved every use of - nothing
        // runs when it is "declared" here, the same way an `import`
        // inside a function body binds a name with nothing left to
        // execute (see `visit(ImportStatement)`).
        if (expression.declaration.isStructDeclaration !is null)
            return;

        auto variable = expression.declaration.isVarDeclaration;
        if (variable is null || variable.isDataseg)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!isSupportedFacts(facts, variable.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const offset = _layout.offsetOf(variable);

        // dmd always installs an `ExpInitializer` holding the type's own
        // default value for a function local with no initialiser written -
        // `int ret;` and `int ret = 0;` reach here the same way. Zero is
        // also the wrong default for some of the integral types this
        // compiler accepts (`char.init`/`wchar.init` are `0xFF`/`0xFFFF`,
        // not zero), so there is no "blit to zero" case of its own to
        // handle here, only this invariant to assert.
        assert(variable._init !is null,
            "a local variable declaration with no initializer at all");

        auto expInitializer = variable._init.isExpInitializer;
        if (expInitializer is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        // `foreach (ref value; values) ...` declares `value` afresh each
        // iteration, bound to `values[i]`'s own storage - the same `ref`
        // local shape a `ref int x = y;` written by hand has. Its own
        // slot holds `y`'s address, not `y`'s value, so this stores the
        // address `compileAddress` computes rather than evaluating the
        // initialiser as a value the way a by-value local's is.
        if (_layout.isRef(variable)) {
            const addressOffset = compileAddress(initializerValueOf(expInitializer));
            emit(&opCopy, offset, addressOffset, size_t.sizeof);
            return;
        }

        evalInto(expInitializer.exp, offset, facts.size);
    }

    // A `ref` local's `ExpInitializer` holds a full `value = target`
    // assignment (a `ConstructExp`, dmd's node for initialising storage the
    // guest has not touched yet) rather than bare `target` the way a
    // by-value local's does - `compileAddress` wants `target` alone, the
    // right side that names the storage to bind to. Unwrapped the same way
    // `snakebite.backends.layout`'s own `collectDeclarations` already does
    // for the temporaries `~=`'s lowering leaves the same way.
    private Expression initializerValueOf(ExpInitializer expInitializer) {
        auto value = expInitializer.exp;
        if (auto construct = value.isConstructExp)
            return construct.e2;
        if (auto blit = value.isBlitExp)
            return blit.e2;
        return value;
    }

    // A plain `=` to a local or parameter. `destOffset` is where the
    // assignment's own value (D specifies an assignment as an expression)
    // goes too, `discardResult` when a caller at statement level has
    // nowhere for it and does not want it.
    private void compileAssign(AssignExp expression, in size_t destOffset) {
        if (auto indexTarget = expression.e1.isIndexExp)
            return compileIndexAssign(expression, indexTarget, destOffset);

        // `pick(a, b, true) = 5;`: the call's own return is `ref`, an
        // lvalue naming whichever of its own arguments it picked, not a
        // value of its own - the same address `compileAddress`'s own
        // `CallExp` case already knows how to compile.
        if (auto callTarget = expression.e1.isCallExp)
            return compileIndirectAssign(expression, callTarget, destOffset);
        if (auto fieldTarget = expression.e1.isDotVarExp)
            return compileFieldAssign(expression, fieldTarget, destOffset);

        auto varExp = expression.e1.isVarExp;
        auto variable = varExp is null ? null : varExp.var.isVarDeclaration;
        if (variable is null || variable.isDataseg)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!isSupportedFacts(facts, variable.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (_layout.isRef(variable))
            return compileIndirectAssign(expression, varExp, destOffset);

        const targetOffset = _layout.offsetOf(variable);

        // A postfix expression yields the old value, but also increments
        // its variable. If both the assignment target and postfix variable
        // are this same slot, preserve the result in a temporary before
        // the postfix operation changes the slot.
        auto post = expression.e2.isPostExp;
        auto postVarExp = post is null ? null : post.e1.isVarExp;
        auto postVariable = postVarExp is null
            ? null : postVarExp.var.isVarDeclaration;
        if (postVariable is variable) {
            const tempOffset = reserveTemp(facts);
            evalInto(expression.e2, tempOffset, facts.size);
            emit(&opCopy, targetOffset, tempOffset, facts.size);
            return;
        }

        evalInto(expression.e2, targetOffset, facts.size);

        if (destOffset != discardResult && destOffset != targetOffset)
            emit(&opCopy, destOffset, targetOffset, facts.size);
    }

    // `*p = value` in every guise this compiler reaches it through: a `ref`
    // variable's own target, or a `ref`-returning call's own result.
    // `compileAddress` already knows how to compile either lvalue's
    // address; this only adds the store once that address is in hand, the
    // same split `visit(IndexExp)`/`compileIndexAssign` already share for
    // an array element.
    private void compileIndirectAssign(
        AssignExp expression, Expression target, in size_t destOffset,
    ) {
        const facts = TypeFacts.of(expression.e1.type);
        if (!isSupportedFacts(facts, expression.e1.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const addressOffset = compileAddress(target);
        const valueOffset = reserveTemp(facts);
        evalInto(expression.e2, valueOffset, facts.size);
        emit(&opStoreIndirect, addressOffset, valueOffset, facts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, facts.size);
    }

    // `s.field = value`, `s` a chain of local struct fields (`a.b.c = 5`)
    // grounded in a local or parameter - never an array element, which has
    // no frame offset of its own to write the field's bytes into (see
    // `fieldBaseFrameOffset`).
    private void compileFieldAssign(
        AssignExp expression, DotVarExp target, in size_t destOffset,
    ) {
        auto field = target.var.isVarDeclaration;
        if (field is null || field.isBitFieldDeclaration !is null
                || !isPlainOldStruct(target.e1.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(target.type);
        if (!isSupportedFacts(facts, target.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const targetOffset = fieldBaseFrameOffset(target.e1) + field.offset;
        evalInto(expression.e2, targetOffset, facts.size);

        if (destOffset != discardResult && destOffset != targetOffset)
            emit(&opCopy, destOffset, targetOffset, facts.size);
    }

    // Where `expression` - a local, a parameter, or a field access chain
    // grounded in one of those - already lives in this frame, with no
    // `evalInto` of its own needed to get it there: `compileFieldAssign`'s
    // own target, and each step of a nested field chain (`a.b.c`) it
    // recurses through to reach `a`'s own slot before adding every field
    // offset from there back down to `c`.
    private size_t fieldBaseFrameOffset(Expression expression) {
        if (auto varExp = expression.isVarExp) {
            auto variable = varExp.var.isVarDeclaration;
            if (variable is null || variable.isDataseg
                    || _layout.isRef(variable))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            return _layout.offsetOf(variable);
        }

        if (auto dot = expression.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field is null || field.isBitFieldDeclaration !is null
                    || !isPlainOldStruct(dot.e1.type))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            return fieldBaseFrameOffset(dot.e1) + field.offset;
        }

        throw rejection(_function, expression.loc,
            expressionText(expression));
    }

    // `arr[i] = value`. `opStoreIndirect` writes `facts.size` bytes
    // wherever `expression.e2` evaluated to, whatever that width is - a
    // scalar or a whole plain-old struct - so this needs no case of its
    // own for either.
    private void compileIndexAssign(
        AssignExp expression, IndexExp target, in size_t destOffset,
    ) {
        const arrayFacts = TypeFacts.of(target.e1.type);
        if (!arrayFacts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(expression.e1.type);
        if (!isSupportedElementFacts(facts, expression.e1.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const addressOffset = compileElementAddress(target, arrayFacts);
        const valueOffset = reserveTemp(facts);
        evalInto(expression.e2, valueOffset, facts.size);
        emit(&opStoreIndirect, addressOffset, valueOffset, facts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, facts.size);
    }

    // `+=`, `-=`, ... and every other compound assignment: the target is
    // read once, not once to combine and again to write, since D
    // evaluates the left side of one of these a single time. The right
    // side is evaluated into a temporary first, before the target's
    // current value is touched, since evaluating it can itself change
    // what the target holds (`a[f()] += 1`, though this compiler does not
    // yet support an indexed target). `destOffset` is where the
    // assignment's own value - the *new* one, unlike `PostExp`'s own old
    // one below - goes too, `discardResult` when nothing wants it.
    private void compileCompoundAssign(
        BinAssignExp expression, in size_t destOffset,
    ) {
        auto varExp = expression.e1.isVarExp;
        auto variable = varExp is null ? null : varExp.var.isVarDeclaration;
        if (variable is null || variable.isDataseg)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto handler = compoundHandler(expression, facts.isUnsigned);
        if (handler is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const rightOffset = reserveTemp(facts);
        evalInto(expression.e2, rightOffset, facts.size);

        // A `ref` target's own slot holds its storage's address, not the
        // storage: the current value is read through it into a temporary,
        // combined there, and written back the same way - `opCopy` on the
        // slot itself would combine into the address, not the value it
        // points at.
        if (_layout.isRef(variable)) {
            const refOffset = _layout.offsetOf(variable);
            const valueOffset = reserveTemp(facts);
            emit(&opLoadIndirect, valueOffset, refOffset, facts.size);
            emit(handler, valueOffset, rightOffset, facts.size);
            emit(&opStoreIndirect, refOffset, valueOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

        const varOffset = _layout.offsetOf(variable);
        emit(handler, varOffset, rightOffset, facts.size);

        if (destOffset != discardResult && destOffset != varOffset)
            emit(&opCopy, destOffset, varOffset, facts.size);
    }

    private Instruction.Handler compoundHandler(
        BinAssignExp expression, in bool unsigned,
    ) {
        if (expression.isAddAssignExp) return &opAdd;
        if (expression.isMinAssignExp) return &opSubtract;
        if (expression.isMulAssignExp) return &opMultiply;
        if (expression.isAndAssignExp) return &opBitAnd;
        if (expression.isOrAssignExp) return &opBitOr;
        if (expression.isXorAssignExp) return &opBitXor;
        if (expression.isShlAssignExp) return &opShiftLeft;
        if (expression.isShrAssignExp)
            return unsigned ? &opShiftRightLogical : &opShiftRightArithmetic;
        if (expression.isUshrAssignExp) return &opShiftRightLogical;
        if (expression.isDivAssignExp)
            return unsigned ? &opDivideUnsigned : &opDivideSigned;
        if (expression.isModAssignExp)
            return unsigned ? &opModuloUnsigned : &opModuloSigned;

        return null;
    }

    // `x++`/`x--`, dmd's own node for the postfix forms alone - the
    // prefix ones are rewritten into `x += 1`/`x -= 1` during semantic
    // analysis and never reach this compiler as their own node.
    // `destOffset` is where the *old* value - what a `PostExp` yields as
    // an expression - goes, captured before the target changes;
    // `discardResult` when a caller at statement level does not want it.
    private void compilePost(PostExp expression, in size_t destOffset) {
        auto varExp = expression.e1.isVarExp;
        auto variable = varExp is null ? null : varExp.var.isVarDeclaration;
        if (variable is null || variable.isDataseg || _layout.isRef(variable))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const varOffset = _layout.offsetOf(variable);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, varOffset, facts.size);

        const stepOffset = reserveTemp(facts);
        evalInto(expression.e2, stepOffset, facts.size);

        auto handler = expression.op == EXP.plusPlus ? &opAdd : &opSubtract;
        emit(handler, varOffset, stepOffset, facts.size);
    }

    // `arr ~= x;`/`arr ~= other;`: dmd's semantic pass, not this compiler,
    // decides which of druntime's own growth hooks the guest needs -
    // `_d_arrayappendcTX` for one element, `_d_arrayappendT` for a whole
    // slice - and leaves the resolved `FuncDeclaration` reachable on
    // `expression.lowering`'s own call node (`CatAssignExp.lowering` in
    // dmd's `expressionsem.d`). `findLoweredCallee` only reads that
    // declaration back out; the arguments this compiler passes it are
    // built fresh from `expression.e1`/`e2` themselves; the appended
    // storage always grows through that real, already-compiled druntime
    // call, never a private growth algorithm of this compiler's own.
    private void compileCatAssign(CatAssignExp expression, in size_t destOffset) {
        import dmd.tokens: EXP;

        auto hook = findLoweredCallee(expression.lowering);
        if (hook is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (expression.op == EXP.concatenateElemAssign)
            return compileElementAppend(expression, hook, destOffset);

        if (expression.op == EXP.concatenateAssign)
            return compileSliceAppend(expression, hook, destOffset);

        throw rejection(_function, expression.loc, expressionText(expression));
    }

    private FuncDeclaration findLoweredCallee(Expression expression) {
        if (expression is null)
            return null;

        if (auto call = expression.isCallExp)
            return call.f;

        if (auto comma = expression.isCommaExp) {
            if (auto found = findLoweredCallee(comma.e1))
                return found;
            return findLoweredCallee(comma.e2);
        }

        return null;
    }

    // `arr ~= x;`: grows `arr` by one element through `_d_arrayappendcTX`,
    // passed `arr`'s own address so the growth it may have to do - a new,
    // larger block, when the old one has no room left to extend in place -
    // lands back in `arr` itself, then writes `x` into the slot that
    // growth made. `x` is evaluated *before* the call: `arr ~= arr[$-1] +
    // 1` reads the pre-growth `$`, the same order dmd's own lowering
    // already forces by extracting `x` into a temporary ahead of the call
    // for exactly this reason (`extractSideEffect` in `expressionsem.d`).
    private void compileElementAppend(
        CatAssignExp expression, FuncDeclaration hook, in size_t destOffset,
    ) {
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        const arrayFacts = TypeFacts.of(expression.e1.type);
        if (!arrayFacts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto elementType = expression.e1.type.nextOf;
        const elementFacts = TypeFacts.of(elementType);
        // `messages ~= "failure";` appends a whole `string` as one element
        // of a `string[]` - the element itself is a dynamic array, not a
        // scalar `isSupportedElementFacts` accepts elsewhere (a literal or
        // `new T[](n)`'s own per-element default fill, which both need a
        // single `long`-sized constant this two-word case cannot be).
        // `opStoreIndirect` only ever memcpies the element's own bytes, so
        // a two-word element is exactly as supported here as a one-word
        // one.
        if (!isSupportedElementFacts(elementFacts, elementType)
                && !elementFacts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const valueOffset = reserveTemp(elementFacts);
        evalInto(expression.e2, valueOffset, elementFacts.size);

        const arrayAddressOffset = compileAddress(expression.e1);

        const oneOffset = reserveTemp(pointerFacts);
        emit(&opConstant, oneOffset, addConstant(1), size_t.sizeof);

        auto plan = &_bytecode._plans.of(hook);
        _callSites ~= CallSite(
            null,
            [
                Arg(arrayAddressOffset, 0, size_t.sizeof),
                Arg(oneOffset, 0, size_t.sizeof),
            ],
            0,
            cast(const(void)*) plan,
        );
        emit(&opCall, discardResult, _callSites.length - 1, 0);

        const grownOffset = reserveTemp(arrayFacts);
        emit(&opLoadIndirect, grownOffset, arrayAddressOffset, arrayFacts.size);

        const elementSizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, elementSizeOffset,
            addConstant(cast(long) elementFacts.size), size_t.sizeof);

        const byteOffsetOffset = reserveTemp(pointerFacts);
        emit(&opCopy, byteOffsetOffset, grownOffset + arrayLengthOffset,
            size_t.sizeof);
        emit(&opSubtract, byteOffsetOffset, oneOffset, size_t.sizeof);
        emit(&opMultiply, byteOffsetOffset, elementSizeOffset, size_t.sizeof);

        const elementAddressOffset = reserveTemp(pointerFacts);
        emit(&opCopy, elementAddressOffset, grownOffset + arrayPointerOffset,
            size_t.sizeof);
        emit(&opAdd, elementAddressOffset, byteOffsetOffset, size_t.sizeof);

        emit(&opStoreIndirect, elementAddressOffset, valueOffset,
            elementFacts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, grownOffset, arrayFacts.size);
    }

    // `arr ~= other;`: grows `arr` in place through `_d_arrayappendT`,
    // which copies `other`'s own elements into the room it made - this
    // compiler never touches an element itself, the same as the single-
    // element form above hands the element write to `opStoreIndirect`
    // rather than druntime.
    private void compileSliceAppend(
        CatAssignExp expression, FuncDeclaration hook, in size_t destOffset,
    ) {
        const arrayFacts = TypeFacts.of(expression.e1.type);
        const otherFacts = TypeFacts.of(expression.e2.type);
        if (!arrayFacts.isDynamicArray || !otherFacts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const otherOffset = reserveTemp(otherFacts);
        evalInto(expression.e2, otherOffset, otherFacts.size);

        const arrayAddressOffset = compileAddress(expression.e1);

        auto plan = &_bytecode._plans.of(hook);
        _callSites ~= CallSite(
            null,
            [
                Arg(arrayAddressOffset, 0, size_t.sizeof),
                Arg(otherOffset, 0, otherFacts.size),
            ],
            0,
            cast(const(void)*) plan,
        );
        emit(&opCall, discardResult, _callSites.length - 1, 0);

        if (destOffset != discardResult)
            emit(&opLoadIndirect, destOffset, arrayAddressOffset,
                arrayFacts.size);
    }

    // Compiles `expression`'s value into `frame[destOffset .. destOffset +
    // width]` - a literal, a parameter or local read, a nested call, a
    // nested assignment's own value (`return (sum = five());`), or any of
    // the operators below.
    private void evalInto(
        Expression expression, in size_t destOffset, in size_t width,
    ) {
        const destination = _destination;
        const savedWidth = _width;
        scope (exit) {
            _destination = destination;
            _width = savedWidth;
        }

        _destination = destOffset;
        _width = width;
        expression.accept(this);
    }

    extern(C++):

    override void visit(Expression expression) {
        throw rejection(_function, expression.loc, expressionText(expression));
    }

    override void visit(DeclarationExp expression) {
        if (_destination != discardResult)
            return visit(cast(Expression) expression);

        compileDeclaration(expression);
    }

    override void visit(IntegerExp expression) {
        requireDestination(expression);

        // A zero-init struct's own `.init` is `IntegerExp(0)` - dmd's own
        // shorthand for "zero every byte", the same one
        // `nativelayout.storeValue` already special-cases for a struct
        // target. `opConstant`'s `storeWidth` only lays out up to 8 bytes,
        // the widest integral this compiler ever moves through a single
        // constant, so a wider destination (only ever a zero-init struct's
        // own slot; every other value this compiler evaluates is `long`s
        // sized or narrower) reaches for `opZero` instead.
        if (_width > long.sizeof) {
            if (expression.toInteger != 0)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            emit(&opZero, _destination, 0, _width);
            return;
        }

        emit(&opConstant, _destination,
            addConstant(expression.toInteger), _width);
    }

    // A `float`/`double` literal, as the raw bits `opConstant` writes -
    // `storeValue` already knows how to lay either width out (see its own
    // doc), so this only has to fold that same compile-time write into one
    // constant rather than reimplementing the float-to-bits conversion.
    override void visit(RealExp expression) {
        import snakebite.nativelayout: storeValue;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.type);
        if (!isFloatingType(expression.type))
            return visit(cast(Expression) expression);

        long bits;
        storeValue(expression.type, facts, expression, &bits);
        emit(&opConstant, _destination, addConstant(bits), _width);
    }

    // A string literal is a slice over dmd's own memory, never copied or
    // allocated - `storeValue` already knows how to write that pair of
    // words at compile time (see its own doc), the same way it already
    // writes an `IntegerExp`'s bytes; this only has to fold that same
    // compile-time write into two constants `opConstant` can hand to the
    // VM, since a temporary this compiler owns is host memory dmd's
    // `storeValue` can write straight into.
    override void visit(StringExp expression) {
        import core.stdc.string: memcpy;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset, arrayValueSize,
            storeValue;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.type);
        if (!facts.isDynamicArray)
            return visit(cast(Expression) expression);

        ubyte[arrayValueSize] bytes = void;
        storeValue(expression.type, facts, expression, bytes.ptr);

        long length, pointer;
        memcpy(&length, bytes.ptr + arrayLengthOffset, size_t.sizeof);
        memcpy(&pointer, bytes.ptr + arrayPointerOffset, size_t.sizeof);

        emit(&opConstant, _destination + arrayLengthOffset,
            addConstant(length), size_t.sizeof);
        emit(&opConstant, _destination + arrayPointerOffset,
            addConstant(pointer), size_t.sizeof);
    }

    override void visit(VarExp expression) {
        requireDestination(expression);
        auto variable = expression.var.isVarDeclaration;
        if (variable is null || variable.isDataseg)
            return visit(cast(Expression) expression);

        // `$` inside an index has no frame slot of its own - dmd hands out
        // a fresh `VarDeclaration` for it that no statement declares
        // (`FrameLayout` never reserves it a slot for exactly that reason),
        // and `compileElementAddress` binds `_dollar` to the length it
        // stands for around evaluating the index expression it appears in.
        if (variable is _dollarVariable) {
            emit(&opCopy, _destination, _dollarOffset, _width);
            return;
        }

        const source = _layout.offsetOf(variable);

        // A `ref` variable's own slot holds the address of the storage it
        // is bound to, not the storage itself - reading it means reading
        // through that address instead of the slot's own bytes, the one
        // place every plain variable read resolves this.
        if (_layout.isRef(variable)) {
            emit(&opLoadIndirect, _destination, source, _width);
            return;
        }

        if (source != _destination)
            emit(&opCopy, _destination, source, _width);
    }

    // `&variable`: dmd folds this straight into a `SymOffExp` naming the
    // variable and a byte offset into it, rather than wrapping a `VarExp`
    // in a general `AddrExp` - the address a `ref` return's own ternary
    // (`cond ? &a : &b`) is built from. A field offset (`offset != 0`) is
    // out of scope; only a whole variable's own address is supported.
    override void visit(SymOffExp expression) {
        requireDestination(expression);
        auto variable = expression.var.isVarDeclaration;
        if (variable is null || variable.isDataseg || expression.offset != 0)
            return visit(cast(Expression) expression);

        const addressOffset = addressOfVariable(variable);
        if (addressOffset != _destination)
            emit(&opCopy, _destination, addressOffset, size_t.sizeof);
    }

    // The general `&expression` node: dmd only folds `&variable` into a
    // `SymOffExp` above when the variable is *not* itself `ref`
    // (`optimize.d`'s own `visitAddr`) - `&a` for a `ref` parameter `a`
    // stays this node instead, since its meaning is different: `a`'s own
    // slot already holds the address `&a` names, not a further
    // indirection into a pointer-to-pointer. `compileAddress` already
    // answers that same question for every lvalue this compiler reaches
    // through `ref` binding, so this is nothing more than that answer
    // copied to `_destination`.
    override void visit(AddrExp expression) {
        requireDestination(expression);

        const addressOffset = compileAddress(expression.e1);
        if (addressOffset != _destination)
            emit(&opCopy, _destination, addressOffset, size_t.sizeof);
    }

    // `s.field`, read as a value. `expression.e1` is evaluated into a
    // temporary of its own first, whatever kind of expression it is - a
    // local, an array element, another field access - the same way any
    // other sub-expression this compiler evaluates is; the field then
    // reads out of that temporary at its own `field.offset`, laid out by
    // dmd's own native semantics rather than recomputed here.
    override void visit(DotVarExp expression) {
        requireDestination(expression);

        auto field = expression.var.isVarDeclaration;
        if (field is null || field.isBitFieldDeclaration !is null
                || !isPlainOldStruct(expression.e1.type))
            return visit(cast(Expression) expression);

        const baseFacts = TypeFacts.of(expression.e1.type);
        const baseOffset = reserveTemp(baseFacts);
        evalInto(expression.e1, baseOffset, baseFacts.size);
        emit(&opCopy, _destination, baseOffset + field.offset, _width);
    }

    // `Point(3, 4)`, dmd's own literal form for a plain-old struct with no
    // user-defined constructor: every field evaluated directly into its
    // own slot at `field.offset` within `_destination`, zeroed first for
    // any field the literal itself leaves out - the same "zero, then fill
    // what is given" shape `compileNewArray`'s own default fill and
    // `StructLiteralExp.elements` sparseness both call for.
    override void visit(StructLiteralExp expression) {
        requireDestination(expression);

        if (!isPlainOldStruct(expression.type))
            return visit(cast(Expression) expression);

        emit(&opZero, _destination, 0, _width);

        if (expression.elements is null)
            return;

        foreach (i, element; *expression.elements) {
            if (element is null)
                continue;

            auto field = expression.sd.fields[i];
            const facts = TypeFacts.of(field.type);
            evalInto(element, _destination + field.offset, facts.size);
        }
    }

    // `arr.length`: the array's own length word, read straight out of its
    // own two-word slot - `arrayLengthOffset` is `0`, so this is really
    // just `arr`'s own first word, but named through the constant rather
    // than assumed, the same way `compileElementAddress` names the pointer
    // word through `arrayPointerOffset` instead of assuming it comes
    // second.
    override void visit(ArrayLengthExp expression) {
        import snakebite.nativelayout: arrayLengthOffset;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.e1.type);
        if (!facts.isDynamicArray)
            return visit(cast(Expression) expression);

        const arrayOffset = reserveTemp(facts);
        evalInto(expression.e1, arrayOffset, facts.size);
        emit(&opCopy, _destination, arrayOffset + arrayLengthOffset, _width);
    }

    // `arr[]`: dmd's own `foreach` lowering over an array takes a bare
    // whole-array slice of it before iterating, to fix the range being
    // walked against mutation of the original variable during the loop.
    // A dynamic array's whole slice is the same two words as the array
    // itself, so this is nothing more than evaluating `e1` again; a
    // bounded slice (`arr[a .. b]`) is out of scope, since nothing this
    // compiler lowers writes one.
    override void visit(SliceExp expression) {
        requireDestination(expression);

        const facts = TypeFacts.of(expression.e1.type);
        if (!facts.isDynamicArray
                || expression.lwr !is null || expression.upr !is null)
            return visit(cast(Expression) expression);

        evalInto(expression.e1, _destination, _width);
    }

    // `arr[i]`, read as a value. `compileElementAddress` does the shared
    // work of computing where that element actually lives; this only adds
    // the load once that address is in hand.
    override void visit(IndexExp expression) {
        requireDestination(expression);

        const facts = TypeFacts.of(expression.e1.type);
        if (!facts.isDynamicArray)
            return visit(cast(Expression) expression);

        const addressOffset = compileElementAddress(expression, facts);
        emit(&opLoadIndirect, _destination, addressOffset, _width);
    }

    // `[a, b, c]`. Every element is evaluated in order into the block this
    // allocates, even when every one of them happens to be a constant - dmd
    // already folds a genuinely compile-time-constant literal into
    // something this compiler need never see as an `ArrayLiteralExp` at
    // all, so one that does reach here may have an element like `x + 1`
    // that only evaluating can produce.
    override void visit(ArrayLiteralExp expression) {
        requireDestination(expression);
        compileArrayLiteral(expression, _destination);
    }

    // `new T[](n)`/`new T[n]`: dmd represents both spellings the same way,
    // an allocation of `n` elements whose count is only known once this
    // compiler evaluates `n` itself.
    override void visit(NewExp expression) {
        requireDestination(expression);
        compileNewArray(expression, _destination);
    }

    // `null`, as a dynamic array: the same all-zero two words `[]` already
    // writes for an empty literal, since a `null` slice and an empty one
    // share that same representation.
    override void visit(NullExp expression) {
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.type);
        if (!facts.isDynamicArray)
            return visit(cast(Expression) expression);

        emit(&opConstant, _destination + arrayLengthOffset,
            addConstant(0), size_t.sizeof);
        emit(&opConstant, _destination + arrayPointerOffset,
            addConstant(0), size_t.sizeof);
    }

    override void visit(CallExp expression) {
        compileCall(expression, _destination);
    }

    // `assert(x)`, run at statement level for its effect alone - it has no
    // value for anything to read, so unlike every other expression here,
    // this ignores `_destination` rather than requiring one.
    override void visit(AssertExp expression) {
        compileAssert(expression);
    }

    override void visit(AssignExp expression) {
        compileAssign(expression, _destination);
    }

    override void visit(BinAssignExp expression) {
        compileCompoundAssign(expression, _destination);
    }

    // `~=`: more specific than `BinAssignExp`, whose own base class this
    // is (`CatElemAssignExp`/`CatDcharAssignExp` in turn derive from this),
    // so this takes priority over `visit(BinAssignExp)` for all three.
    override void visit(CatAssignExp expression) {
        compileCatAssign(expression, _destination);
    }

    override void visit(PostExp expression) {
        compilePost(expression, _destination);
    }

    override void visit(CommaExp expression) {
        compileEffect(expression.e1);
        if (_destination == discardResult)
            compileEffect(expression.e2);
        else
            evalInto(expression.e2, _destination, _width);
    }

    override void visit(CastExp expression) {
        requireDestination(expression);
        compileCast(expression, _destination, _width);
    }

    override void visit(NotExp expression) {
        requireDestination(expression);
        compileNot(expression, _destination);
    }

    override void visit(LogicalExp expression) {
        requireDestination(expression);
        compileLogical(expression, _destination, _width);
    }

    override void visit(CondExp expression) {
        requireDestination(expression);
        compileTernary(expression, _destination, _width);
    }

    override void visit(CmpExp expression) {
        requireDestination(expression);
        compileComparison(expression, _destination);
    }

    override void visit(EqualExp expression) {
        requireDestination(expression);
        compileComparison(expression, _destination);
    }

    override void visit(NegExp expression) {
        requireDestination(expression);
        compileUnary(expression, _destination, _width, &opNegate);
    }

    override void visit(ComExp expression) {
        requireDestination(expression);
        compileUnary(expression, _destination, _width, &opComplement);
    }

    override void visit(AddExp expression) {
        compileBinaryExpression(expression, &opAdd);
    }

    override void visit(MinExp expression) {
        compileBinaryExpression(expression, &opSubtract);
    }

    override void visit(MulExp expression) {
        compileBinaryExpression(expression, &opMultiply);
    }

    override void visit(AndExp expression) {
        compileBinaryExpression(expression, &opBitAnd);
    }

    override void visit(OrExp expression) {
        compileBinaryExpression(expression, &opBitOr);
    }

    override void visit(XorExp expression) {
        compileBinaryExpression(expression, &opBitXor);
    }

    override void visit(ShlExp expression) {
        compileBinaryExpression(expression, &opShiftLeft);
    }

    override void visit(UshrExp expression) {
        compileBinaryExpression(expression, &opShiftRightLogical);
    }

    override void visit(ShrExp expression) {
        compileSignedBinaryExpression(
            expression, &opShiftRightArithmetic, &opShiftRightLogical);
    }

    override void visit(DivExp expression) {
        compileSignedBinaryExpression(
            expression, &opDivideSigned, &opDivideUnsigned);
    }

    override void visit(ModExp expression) {
        compileSignedBinaryExpression(
            expression, &opModuloSigned, &opModuloUnsigned);
    }

    extern(D):

    private void requireDestination(Expression expression) {
        if (_destination == discardResult)
            visit(expression);
    }

    private void compileBinaryExpression(
        BinExp expression, Instruction.Handler handler,
    ) {
        requireDestination(expression);
        compileBinary(expression, _destination, _width, handler);
    }

    private void compileSignedBinaryExpression(
        BinExp expression,
        Instruction.Handler signedHandler,
        Instruction.Handler unsignedHandler,
    ) {
        const handler = TypeFacts.of(expression.e1.type).isUnsigned
            ? unsignedHandler : signedHandler;
        compileBinaryExpression(expression, handler);
    }

    // `+`, `-`, `*`, `&`, `|`, `^`, `<<`, `>>`, `>>>`, `/`, `%`: both
    // operands are evaluated into temporaries of their own - never
    // `destOffset` directly, which can already be a variable either
    // operand itself reads (`x = y + x`; evaluating `y` straight into
    // `x`'s own slot would clobber `x` before it is read for the right
    // operand) - then combined in place with `handler`, already the
    // right one for this operator and, where it matters, this
    // expression's own signedness (decided by the caller, which knows
    // which operator this is; this compiler has no per-operator table of
    // its own to keep in step with the VM's opcodes). The answer is
    // copied out to `destOffset` only when it differs from the left
    // operand's own temporary.
    private void compileBinary(
        BinExp expression, in size_t destOffset, in size_t width,
        Instruction.Handler handler,
    ) {
        const facts = TypeFacts.of(expression.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const leftOffset = reserveTemp(facts);
        evalOperandInto(expression.e1, leftOffset, width);
        const rightOffset = reserveTemp(facts);
        evalOperandInto(expression.e2, rightOffset, width);
        emit(handler, leftOffset, rightOffset, width);

        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, width);
    }

    // Evaluates `operand` for use as one side of a binary opcode that
    // reads both its operands at one shared `width` - `compileBinary`'s
    // own opcodes, whose `Instruction` has only one `width` field for
    // both. Every operator's own usual arithmetic conversions already
    // give both operands `width` except a shift's right side, which
    // keeps its own, possibly narrower, type (`x << (someByte + 1)`) -
    // evaluating it as if it already had `width` bytes reserved, the way
    // `evalInto`'s `VarExp` case does verbatim, would `opCopy` bytes past
    // whatever narrower storage actually holds it. This evaluates the
    // operand at its own type's width first, then widens or narrows the
    // same temporary in place to `width` - the same conversion a cast to
    // `width` bytes performs, because that is exactly what reading a
    // narrower or wider operand as this opcode's shared width means.
    private void evalOperandInto(
        Expression operand, in size_t destOffset, in size_t width,
    ) {
        const operandFacts = TypeFacts.of(operand.type);
        if (!operandFacts.isIntegral || !isIntegralSize(operandFacts.size))
            throw rejection(_function, operand.loc, expressionText(operand));

        if (operandFacts.size == width) {
            evalInto(operand, destOffset, width);
            return;
        }

        if (operandFacts.size < width) {
            evalInto(operand, destOffset, operandFacts.size);
            emit(
                operandFacts.isUnsigned
                    ? &opCastWidenUnsigned : &opCastWidenSigned,
                destOffset, operandFacts.size, width,
            );
            return;
        }

        const temp = reserveTemp(operandFacts);
        evalInto(operand, temp, operandFacts.size);
        emit(&opCopy, destOffset, temp, width);
    }

    // `<`, `<=`, `>`, `>=`, `==`, `!=`: both operands are read into
    // temporaries of their own common width - not necessarily
    // `destOffset`'s own width, since the result is always a one-byte
    // `bool` - and the comparison opcode leaves its answer in the first
    // of those, copied out to `destOffset` only when it differs.
    private void compileComparison(BinExp expression, in size_t destOffset) {
        const operandFacts = TypeFacts.of(expression.e1.type);

        // `float`/`double` compare unequal to themselves when they are NaN,
        // so this reaches for the host's own float comparison
        // (`opFloatEqual`/`opFloatNotEqual`) rather than the bit-pattern
        // test every integral comparison uses - only `==`/`!=` are
        // supported for now, since nothing in scope needs a floating
        // ordering.
        if (isFloatingType(expression.e1.type)) {
            Instruction.Handler floatHandler;
            with (EXP) switch (expression.op) {
                case equal: floatHandler = &opFloatEqual; break;
                case notEqual: floatHandler = &opFloatNotEqual; break;
                default:
                    throw rejection(_function, expression.loc,
                        expressionText(expression));
            }

            const floatLeftOffset = reserveTemp(operandFacts);
            evalInto(expression.e1, floatLeftOffset, operandFacts.size);
            const floatRightOffset = reserveTemp(operandFacts);
            evalInto(expression.e2, floatRightOffset, operandFacts.size);
            emit(floatHandler, floatLeftOffset, floatRightOffset,
                operandFacts.size);

            if (destOffset != floatLeftOffset)
                emit(&opCopy, destOffset, floatLeftOffset, 1);
            return;
        }

        if (!operandFacts.isIntegral || !isIntegralSize(operandFacts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto handler = comparisonHandler(expression, operandFacts.isUnsigned);

        const leftOffset = reserveTemp(operandFacts);
        evalInto(expression.e1, leftOffset, operandFacts.size);
        const rightOffset = reserveTemp(operandFacts);
        evalInto(expression.e2, rightOffset, operandFacts.size);
        emit(handler, leftOffset, rightOffset, operandFacts.size);

        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, 1);
    }

    private Instruction.Handler comparisonHandler(
        BinExp expression, in bool unsigned,
    ) {
        with (EXP) switch (expression.op) {
            case lessThan:
                return unsigned ? &opLessThanUnsigned : &opLessThanSigned;
            case lessOrEqual:
                return unsigned
                    ? &opLessOrEqualUnsigned : &opLessOrEqualSigned;
            case greaterThan:
                return unsigned
                    ? &opGreaterThanUnsigned : &opGreaterThanSigned;
            case greaterOrEqual:
                return unsigned
                    ? &opGreaterOrEqualUnsigned : &opGreaterOrEqualSigned;
            case equal:
                return &opEqual;
            case notEqual:
                return &opNotEqual;
            default:
                throw rejection(_function, expression.loc,
                    expressionText(expression));
        }
    }

    // `-x`, `~x`: evaluates the operand directly into `destOffset`, then
    // applies `handler` in place.
    private void compileUnary(
        UnaExp expression, in size_t destOffset, in size_t width,
        Instruction.Handler handler,
    ) {
        const facts = TypeFacts.of(expression.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        evalInto(expression.e1, destOffset, width);
        emit(handler, destOffset, 0, width);
    }

    // `!x`: evaluated the same way any other condition is - `compileCondition`
    // already knows how to reduce a dynamic array operand to its pointer
    // word alone, which this needs exactly as much as `if`/`while` do -
    // then reduced to a single-byte `bool` the same way a comparison is,
    // copied out to `destOffset` only when the temporary is not already it.
    private void compileNot(NotExp expression, in size_t destOffset) {
        const operandOffset = compileCondition(expression.e1);
        const width = conditionWidth(expression.e1);
        emit(&opLogicalNot, operandOffset, 0, width);

        if (destOffset != operandOffset)
            emit(&opCopy, destOffset, operandOffset, 1);
    }

    // `&&`/`||`: dmd does not cast either operand to `bool` - `yes() &&
    // five()`, `five()` returning a plain `int`, is legal and tests
    // `five()` for nonzero the same way an `if`'s own condition does - so
    // each operand is evaluated at its own type's width (`compileCondition`,
    // the same helper `if`/`while`/`for`/the ternary already use), never
    // at this expression's own one-byte `bool` width: evaluating an `int`
    // operand there would truncate it to its low byte before testing it,
    // and evaluating a call there would have `compileCall` write the
    // callee's full return width into a one-byte slot. A branch skips the
    // right operand exactly when D's own short-circuit rule says to -
    // `&&` skips it once the left side is already false, `||` once it is
    // already true - and whichever operand actually decided the answer is
    // then reduced to a proper `bool` and copied out to `destOffset`.
    private void compileLogical(
        LogicalExp expression, in size_t destOffset, in size_t width,
    ) {
        const leftOffset = compileCondition(expression.e1);
        const leftWidth = conditionWidth(expression.e1);

        const branchIndex = _instructions.length;
        auto shortCircuit = expression.op == EXP.andAnd
            ? &opBranchFalse : &opBranchTrue;
        emit(shortCircuit, leftOffset, 0, leftWidth);

        // The left side did not decide the answer: the right side's own
        // truthiness does.
        const rightOffset = compileCondition(expression.e2);
        const rightWidth = conditionWidth(expression.e2);
        emit(&opCastToBool, rightOffset, 0, rightWidth);
        if (destOffset != rightOffset)
            emit(&opCopy, destOffset, rightOffset, 1);
        const jumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);

        // Short-circuited: the left side decided the answer by itself.
        _instructions[branchIndex].source = _instructions.length;
        emit(&opCastToBool, leftOffset, 0, leftWidth);
        if (destOffset != leftOffset)
            emit(&opCopy, destOffset, leftOffset, 1);

        _instructions[jumpIndex].destination = _instructions.length;
    }

    // `cond ? a : b`: only the branch the condition selects at run time
    // is ever evaluated, the same as `if`/`else`.
    private void compileTernary(
        CondExp expression, in size_t destOffset, in size_t width,
    ) {
        const conditionOffset = compileCondition(expression.econd);
        const conditionWidth_ = conditionWidth(expression.econd);

        const branchIndex = _instructions.length;
        emit(&opBranchFalse, conditionOffset, 0, conditionWidth_);

        evalInto(expression.e1, destOffset, width);
        const jumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);

        _instructions[branchIndex].source = _instructions.length;
        evalInto(expression.e2, destOffset, width);
        _instructions[jumpIndex].destination = _instructions.length;
    }

    // `cast(T) x`. `cast(bool)` is not a narrowing: dmd classifies `bool`
    // as an integral type, so a plain low-byte truncation would answer
    // `cast(bool) 256` as `false` rather than D's own `true`, and this
    // refuses that shortcut by name rather than by width. A cast that
    // does not change width is a reinterpretation of the same bits -
    // `cast(uint)` of an `int`, say - so it just evaluates the operand
    // straight into `destOffset`; narrowing does too, into a wider
    // temporary first, since this VM's little-endian layout already
    // makes the low bytes of a wider stored value its truncation to a
    // narrower one (`opCopy` reads exactly those bytes); only widening
    // needs the operand's own signedness to fill the new high bits
    // correctly, so it alone reaches for `opCastWidenSigned`/
    // `opCastWidenUnsigned`.
    private void compileCast(
        CastExp expression, in size_t destOffset, in size_t width,
    ) {
        auto sourceType = expression.e1.type;
        auto destType = expression.type;

        const sourceFacts = TypeFacts.of(sourceType);
        if (!sourceFacts.isIntegral || !isIntegralSize(sourceFacts.size)
                || !TypeFacts.of(destType).isIntegral)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        import dmd.astenums: Tbool;

        if (destType.ty == Tbool) {
            evalInto(expression.e1, destOffset, sourceFacts.size);
            emit(&opCastToBool, destOffset, 0, sourceFacts.size);
            return;
        }

        if (width == sourceFacts.size) {
            evalInto(expression.e1, destOffset, width);
            return;
        }

        if (width < sourceFacts.size) {
            const temp = reserveTemp(sourceFacts);
            evalInto(expression.e1, temp, sourceFacts.size);
            emit(&opCopy, destOffset, temp, width);
            return;
        }

        evalInto(expression.e1, destOffset, sourceFacts.size);
        emit(
            sourceFacts.isUnsigned ? &opCastWidenUnsigned : &opCastWidenSigned,
            destOffset, sourceFacts.size, width,
        );
    }

    // Compiles a call to `expression.f`: every argument evaluated into a
    // temporary of this function's own, in the callee's parameter order,
    // then one `opCall` naming the call site those temporaries and the
    // compiled callee are recorded under. `destOffset` is `discardResult`
    // for a call run at statement level, whose result (`void` or
    // otherwise) is discarded.
    private void compileCall(CallExp expression, in size_t destOffset) {
        import dmd.astenums: STC, Tvoid;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        if (expression.f is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto callee = expression.f;
        if (callee.fbody is null || _bytecode.hasNativeSymbol(callee)) {
            auto type = typeFunctionOf(callee);
            const parameterCount = type.parameterList.length;
            const argumentCount = expression.arguments is null
                ? 0
                : expression.arguments.length;
            if (argumentCount != parameterCount)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            // A `ref` return hands back its target's address in the
            // return register, whatever the pointee's own facts are - the
            // same convention `snakebite.ffi.plan` already prepares for a
            // native callee (see `CallPlan.prepare`'s own `returnsRef`).
            const isRefCallee = type.isRef;
            auto returnType = type.next;
            const isVoidCallee = returnType is null || returnType.ty == Tvoid;
            const returnFacts = isRefCallee
                ? pointerFacts
                : isVoidCallee ? TypeFacts.init : TypeFacts.of(returnType);
            if (isVoidCallee && destOffset != discardResult)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            Arg[] args;
            foreach (i; 0 .. parameterCount) {
                auto parameter = type.parameterList[i];
                if (parameter.storageClass & (STC.out_ | STC.lazy_))
                    throw rejection(_function, expression.loc,
                        expressionText(expression));

                if (parameter.storageClass & STC.ref_) {
                    const argumentOffset =
                        compileAddress((*expression.arguments)[i]);
                    args ~= Arg(argumentOffset, 0, size_t.sizeof);
                    continue;
                }

                const facts = TypeFacts.of(parameter.type);
                const argumentOffset = reserveTemp(facts);
                evalInto((*expression.arguments)[i], argumentOffset, facts.size);
                args ~= Arg(argumentOffset, 0, facts.size);
            }

            auto plan = &_bytecode._plans.of(callee);
            _callSites ~= CallSite(
                null, args, isVoidCallee ? 0 : returnFacts.size,
                cast(const(void)*) plan,
            );
            emit(&opCall, destOffset, _callSites.length - 1, 0);
            return;
        }
        auto calleeFunction = _bytecode.compileFunction(callee);
        auto calleeLayout = FrameLayout.of(callee);
        auto calleeType = typeFunctionOf(callee);

        const parameterCount = calleeType.parameterList.length;
        const argumentCount =
            expression.arguments is null ? 0 : expression.arguments.length;
        if (argumentCount != parameterCount)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        Arg[] args;
        foreach (i; 0 .. parameterCount) {
            auto parameter = calleeLayout.parameters[i];

            // A `ref` parameter's own `facts` are the pointer slot's,
            // never `isSupportedFacts` on their own terms (`isIntegral`
            // is `false` for them) - the pointee's own facts are what
            // that check is for, and `Bytecode.compileFunction` already
            // made it of the callee's declared parameter type.
            if (parameter.isRef) {
                const argumentOffset =
                    compileAddress((*expression.arguments)[i]);
                args ~= Arg(argumentOffset, parameter.offset, size_t.sizeof);
                continue;
            }

            if (!isSupportedFacts(parameter.facts,
                    calleeType.parameterList[i].type))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            const argumentOffset = reserveTemp(parameter.facts);
            evalInto(
                (*expression.arguments)[i], argumentOffset,
                parameter.facts.size,
            );
            args ~= Arg(argumentOffset, parameter.offset, parameter.facts.size);
        }

        // A `ref` return hands the caller the callee's own returned
        // storage's address - `compileAddress`'s `CallExp` case is the one
        // place that address is read back out, and `compileIndirectAssign`
        // is the one place it is written through.
        const isRefCallee = calleeType.isRef;
        auto calleeReturnType = calleeType.next;
        const isVoidCallee =
            calleeReturnType is null || calleeReturnType.ty == Tvoid;
        const returnFacts = isRefCallee
            ? pointerFacts
            : isVoidCallee ? TypeFacts.init : TypeFacts.of(calleeReturnType);
        if (!isRefCallee && !isVoidCallee
                && !isSupportedFacts(returnFacts, calleeReturnType))
            throw rejection(_function, expression.loc,
                expressionText(expression));
        if (isVoidCallee && destOffset != discardResult)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const siteIndex = _callSites.length;
        _callSites ~=
            CallSite(calleeFunction, args, isVoidCallee ? 0 : returnFacts.size);
        emit(&opCall, destOffset, siteIndex, 0);
    }

    private TypeFacts pointerFacts() {
        return pointerFactsOf;
    }

    // Where `expression`'s element actually lives: `expression.e1`'s own
    // pointer word, offset by its index times the element's own size.
    // Shared by a load (`visit(IndexExp)`) and a store
    // (`compileIndexAssign`), which differ only in what they do with the
    // address once they have it.
    //
    // An index outside the array would otherwise read or write through
    // whatever raw address the arithmetic below happens to land on -
    // corrupting host memory, not failing the guest - so this checks
    // before computing that address, reusing `opAssert` rather than a
    // second throwing opcode for the same "fail loudly, now" job.
    private size_t compileElementAddress(
        IndexExp expression, in TypeFacts arrayFacts,
    ) {
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;
        import std.conv: text;
        import std.string: fromStringz;

        const arrayOffset = reserveTemp(arrayFacts);
        evalInto(expression.e1, arrayOffset, arrayFacts.size);

        auto outerDollarVariable = _dollarVariable;
        auto outerDollarOffset = _dollarOffset;
        scope (exit) {
            _dollarVariable = outerDollarVariable;
            _dollarOffset = outerDollarOffset;
        }
        if (expression.lengthVar !is null) {
            _dollarVariable = expression.lengthVar;
            _dollarOffset = arrayOffset + arrayLengthOffset;
        }

        const indexOffset = reserveTemp(pointerFacts);
        evalOperandInto(expression.e2, indexOffset, size_t.sizeof);

        const boundsOffset = reserveTemp(pointerFacts);
        emit(&opCopy, boundsOffset, indexOffset, size_t.sizeof);
        emit(&opLessThanUnsigned, boundsOffset,
            arrayOffset + arrayLengthOffset, size_t.sizeof);

        const site = AssertSite(
            text("bytecode: index out of bounds: `", expression.e2.toString,
                "`"),
            expression.loc.filename.fromStringz.idup,
            expression.loc.linnum,
        );
        _assertSites ~= site;
        emit(&opAssert, boundsOffset, _assertSites.length - 1, 1);

        const elementSizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, elementSizeOffset,
            addConstant(cast(long) arrayFacts.elementSize), size_t.sizeof);
        emit(&opMultiply, indexOffset, elementSizeOffset, size_t.sizeof);

        const addressOffset = reserveTemp(pointerFacts);
        emit(&opCopy, addressOffset, arrayOffset + arrayPointerOffset,
            size_t.sizeof);
        emit(&opAdd, addressOffset, indexOffset, size_t.sizeof);

        return addressOffset;
    }

    // Where `expression`'s own storage lives, as a run-time pointer value
    // left in a fresh temporary - the one operation `ref` binding (a `ref`
    // parameter's argument, a `ref` local's initialiser, a `ref` return's
    // own expression) and `~=`'s `ref` argument to druntime all reduce to.
    //
    // A plain variable's address is its frame slot's own address, computed
    // fresh by `opFrameAddress` since the frame this compiled function runs
    // in only exists at run time. A `ref` variable's slot already holds the
    // address it is bound to - the same reach `visit(VarExp)` makes to read
    // through it - so that slot's own offset already answers the question
    // without a further instruction. An indexed element's address is
    // `compileElementAddress`'s own job, already shared with a load and a
    // store. A `ref`-returning call's result is likewise already an
    // address once `compileCall` compiles it into a pointer-sized slot -
    // see `_isRefReturn` in `compileReturn`.
    private size_t compileAddress(Expression expression) {
        if (auto varExp = expression.isVarExp) {
            auto variable = varExp.var.isVarDeclaration;
            if (variable !is null && !variable.isDataseg)
                return addressOfVariable(variable);
        }

        if (auto indexExp = expression.isIndexExp) {
            const arrayFacts = TypeFacts.of(indexExp.e1.type);
            if (arrayFacts.isDynamicArray)
                return compileElementAddress(indexExp, arrayFacts);
        }

        if (auto callExp = expression.isCallExp) {
            import snakebite.frontend.dmd.functions: typeFunctionOf;

            if (callExp.f !is null && typeFunctionOf(callExp.f).isRef) {
                const offset = reserveTemp(pointerFacts);
                compileCall(callExp, offset);
                return offset;
            }
        }

        // `*(cond ? &a : &b)`: dmd wraps a `ref` return's own conditional
        // expression this way (see `_isRefReturn` in `compileReturn`) -
        // `expression.e1` is itself a pointer-typed value (a ternary of
        // addresses, an ordinary expression `evalInto` already knows how
        // to compile through `visit(SymOffExp)`/`visit(CondExp)`), and the
        // address `*p` names is exactly `p`'s own value, not a further
        // indirection.
        if (auto ptrExp = expression.isPtrExp) {
            const offset = reserveTemp(pointerFacts);
            evalInto(ptrExp.e1, offset, size_t.sizeof);
            return offset;
        }

        throw rejection(_function, expression.loc, expressionText(expression));
    }

    // `variable`'s own address, as a run-time pointer value left in a
    // fresh temporary: a `ref` variable's slot already holds the address
    // it is bound to, so that slot's own offset already answers the
    // question; a value variable's address is its frame slot's own
    // address, computed fresh by `opFrameAddress` since the frame this
    // compiled function runs in only exists at run time. Shared by
    // `compileAddress`'s own `VarExp` case and `visit(SymOffExp)`, dmd's
    // own node for `&variable` written directly rather than through a
    // `VarExp`.
    private size_t addressOfVariable(VarDeclaration variable) {
        if (_layout.isRef(variable))
            return _layout.offsetOf(variable);

        const offset = reserveTemp(pointerFacts);
        emit(&opFrameAddress, offset, _layout.offsetOf(variable),
            size_t.sizeof);
        return offset;
    }

    // Calls druntime's allocator for `size` bytes and leaves the resulting
    // pointer at `resultOffset` - `destOffset + arrayPointerOffset`, for
    // every caller here, so the array's own pointer word is filled in
    // directly rather than through an extra copy. Every element type this
    // compiler accepts is a scalar with no pointers of its own, so the
    // block is always `NO_SCAN`: nothing inside it is ever itself a
    // reference the collector would need to follow.
    private void emitAllocate(in size_t sizeOffset, in size_t resultOffset) {
        import core.memory: GC;

        const siteIndex = _callSites.length;
        _callSites ~= CallSite(
            null,
            [Arg(sizeOffset, 0, size_t.sizeof)],
            (void*).sizeof,
            null,
            _bytecode.allocatorAddress,
            true,
            GC.BlkAttr.NO_SCAN,
        );
        emit(&opCall, resultOffset, siteIndex, 0);
    }

    // `elementType`'s own `.init`, as the raw bits `opConstant` can write
    // into an element slot directly - zero for most of the scalar types
    // this compiler accepts, but not for `float`/`double`, whose `.init`
    // is NaN, not zero, so a `new T[](n)`'s default fill cannot simply
    // zero the block the way an integral element's default could.
    private long defaultConstantOf(
        imported!"dmd.mtype".Type elementType,
        in TypeFacts elementFacts,
    ) {
        import dmd.typesem: defaultInit;
        import snakebite.nativelayout: storeValue;

        auto initializer = defaultInit(elementType, _function.loc);
        long bits;
        storeValue(elementType, elementFacts, initializer, &bits);
        return bits;
    }

    // `[a, b, c]`: allocates one block through druntime for every element,
    // then evaluates each element expression directly into its own slot in
    // it - never constant-folded bytes copied in bulk, since an element
    // like `x + 1` only evaluating can produce. `[]` needs no allocation at
    // all: a null pointer and a zero length already are an empty dynamic
    // array's own two words.
    //
    // The length and pointer are built up in a temporary, not `destOffset`
    // itself, and copied out to `destOffset` only once every element is
    // done: an element expression can read `destOffset`'s own variable
    // (`a = [a[1], a[0]]`), and until the whole literal is ready that
    // variable's old value is the only correct thing living there.
    private void compileArrayLiteral(
        ArrayLiteralExp expression, in size_t destOffset,
    ) {
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        const facts = TypeFacts.of(expression.type);
        if (!facts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const elementFacts = TypeFacts.of(expression.type.nextOf);
        if (!isSupportedElementFacts(elementFacts, expression.type.nextOf))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const count =
            expression.elements is null ? 0 : expression.elements.length;

        if (count == 0) {
            emit(&opConstant, destOffset + arrayLengthOffset,
                addConstant(0), size_t.sizeof);
            emit(&opConstant, destOffset + arrayPointerOffset,
                addConstant(0), size_t.sizeof);
            return;
        }

        const lengthOffset = reserveTemp(pointerFacts);
        emit(&opConstant, lengthOffset,
            addConstant(cast(long) count), size_t.sizeof);

        const pointerOffset = reserveTemp(pointerFacts);
        const sizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, sizeOffset,
            addConstant(cast(long) (count * elementFacts.size)),
            size_t.sizeof);
        emitAllocate(sizeOffset, pointerOffset);

        foreach (i; 0 .. count) {
            auto element = (*expression.elements)[i];
            const elementOffset = reserveTemp(elementFacts);
            evalInto(element, elementOffset, elementFacts.size);

            const addressOffset = reserveTemp(pointerFacts);
            emit(&opCopy, addressOffset, pointerOffset, size_t.sizeof);
            if (i != 0) {
                const byteOffsetOffset = reserveTemp(pointerFacts);
                emit(&opConstant, byteOffsetOffset,
                    addConstant(cast(long) (i * elementFacts.size)),
                    size_t.sizeof);
                emit(&opAdd, addressOffset, byteOffsetOffset, size_t.sizeof);
            }
            emit(&opStoreIndirect, addressOffset, elementOffset,
                elementFacts.size);
        }

        emit(&opCopy, destOffset + arrayLengthOffset, lengthOffset,
            size_t.sizeof);
        emit(&opCopy, destOffset + arrayPointerOffset, pointerOffset,
            size_t.sizeof);
    }

    // `new T[](n)`/`new T[n]` - dmd represents both spellings the same way.
    // `n` is a run-time value, unlike a literal's own element count, so the
    // default fill below is a genuine loop rather than something this
    // compiler can unroll at compile time.
    private void compileNewArray(NewExp expression, in size_t destOffset) {
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;

        const facts = TypeFacts.of(expression.type);
        if (!facts.isDynamicArray || expression.arguments is null
                || expression.arguments.length != 1)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto elementType = expression.type.nextOf;
        const elementFacts = TypeFacts.of(elementType);
        if (!isSupportedElementFacts(elementFacts, elementType))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const countOffset = reserveTemp(pointerFacts);
        evalOperandInto(
            (*expression.arguments)[0], countOffset, size_t.sizeof);
        emit(&opCopy, destOffset + arrayLengthOffset, countOffset,
            size_t.sizeof);

        const sizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, sizeOffset,
            addConstant(cast(long) elementFacts.size), size_t.sizeof);
        emit(&opMultiply, sizeOffset, countOffset, size_t.sizeof);
        emitAllocate(sizeOffset, destOffset + arrayPointerOffset);

        const indexOffset = reserveTemp(pointerFacts);
        emit(&opConstant, indexOffset, addConstant(0), size_t.sizeof);

        const loopStart = _instructions.length;
        const condOffset = reserveTemp(pointerFacts);
        emit(&opCopy, condOffset, indexOffset, size_t.sizeof);
        emit(&opLessThanUnsigned, condOffset, countOffset, size_t.sizeof);
        const branchIndex = _instructions.length;
        emit(&opBranchFalse, condOffset, 0, 1);

        const addressOffset = reserveTemp(pointerFacts);
        emit(&opCopy, addressOffset, destOffset + arrayPointerOffset,
            size_t.sizeof);
        const byteOffsetOffset = reserveTemp(pointerFacts);
        emit(&opCopy, byteOffsetOffset, indexOffset, size_t.sizeof);
        const elementSizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, elementSizeOffset,
            addConstant(cast(long) elementFacts.size), size_t.sizeof);
        emit(&opMultiply, byteOffsetOffset, elementSizeOffset, size_t.sizeof);
        emit(&opAdd, addressOffset, byteOffsetOffset, size_t.sizeof);

        const defaultOffset = reserveTemp(elementFacts);
        // A zero-init struct element can be wider than the 8 bytes
        // `defaultConstantOf` folds a default into - it goes through
        // `opZero` directly instead, the same way `visit(IntegerExp)`
        // reaches for it over `opConstant` for the same reason.
        if (isPlainOldStruct(elementType))
            emit(&opZero, defaultOffset, 0, elementFacts.size);
        else
            emit(&opConstant, defaultOffset,
                addConstant(defaultConstantOf(elementType, elementFacts)),
                elementFacts.size);
        emit(&opStoreIndirect, addressOffset, defaultOffset,
            elementFacts.size);

        const oneOffset = reserveTemp(pointerFacts);
        emit(&opConstant, oneOffset, addConstant(1), size_t.sizeof);
        emit(&opAdd, indexOffset, oneOffset, size_t.sizeof);

        emit(&opJump, loopStart, 0, 0);
        _instructions[branchIndex].source = _instructions.length;
    }
}

// Renders `statement` back to source text for a rejection message, on one
// line: dmd's own renderer (`toChars`) includes the trailing newline a
// statement carries in source.
private string statementText(imported!"dmd.statement".Statement statement) {
    import dmd.hdrgen: toChars;
    import std.string: fromStringz, strip;
    import std.conv: text;

    return text("`", toChars(statement).fromStringz.strip, "`");
}

// As `statementText`, for an expression: `Expression.toString` already
// renders on one line, unlike a statement's.
private string expressionText(imported!"dmd.expression".Expression expression) {
    import std.conv: text;

    return text("`", expression.toString, "`");
}

// A rejection naming where in the guest source it happened (`loc`), what
// the compiler refused (`operation`), and which function it was compiling.
private imported!"snakebite.exception".SnakebiteException rejection(
    imported!"dmd.func".FuncDeclaration function_,
    imported!"dmd.location".Loc loc,
    string operation,
) {
    import snakebite.exception: SnakebiteException;
    import std.conv: text;
    import std.string: fromStringz;

    return new SnakebiteException(text(
        loc.toChars.fromStringz, ": bytecode compiler cannot compile ",
        operation, " in `", function_.toString, "`",
    ));
}
