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

// Whether `type` is `float`/`double` - `TypeFacts` has no notion of its own
// for this, since nothing outside array element types and their literals
// needs to ask, unlike `isIntegral`/`isDynamicArray`, which drive checks
// all over this compiler.
private bool isFloatingType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tfloat32, Tfloat64;

    return type.ty == Tfloat32 || type.ty == Tfloat64;
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
        || isFloatingType(type);
}


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Function, Vm;
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
        const returnFacts = isVoidReturn ? TypeFacts.init : TypeFacts.of(returnType);
        if (!isVoidReturn && !isSupportedFacts(returnFacts))
            throw rejection(function_, function_.loc, text(
                "a `", returnType is null ? "auto" : returnType.toString,
                "` return",
            ));

        foreach (i; 0 .. functionType.parameterList.length) {
            auto parameter = functionType.parameterList[i];
            if (parameter.storageClass & (STC.out_ | STC.lazy_ | STC.ref_))
                throw rejection(function_, function_.loc,
                    "a `ref`/`out`/`lazy` parameter");

            const facts = TypeFacts.of(parameter.type);
            if (!isSupportedFacts(facts))
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

        scope compiler =
            new FunctionCompiler(this, function_, layout, returnFacts, isVoidReturn);
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
        opFloatEqual, opFloatNotEqual, opGreaterOrEqualSigned,
        opGreaterOrEqualUnsigned, opGreaterThanSigned, opGreaterThanUnsigned,
        opJump, opLessOrEqualSigned, opLessOrEqualUnsigned, opLessThanSigned,
        opLessThanUnsigned, opLoadIndirect, opLogicalNot, opModuloSigned,
        opModuloUnsigned, opMultiply, opNegate, opNotEqual, opReturn,
        opReturnVoid, opShiftLeft, opShiftRightArithmetic, opShiftRightLogical,
        opStoreIndirect, opSubtract;
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
    ) {
        _bytecode = bytecode;
        _function = function_;
        _layout = layout;
        _returnFacts = returnFacts;
        _isVoidReturn = isVoidReturn;
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
        auto variable = expression.declaration.isVarDeclaration;
        if (variable is null || variable.isDataseg)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!isSupportedFacts(facts))
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

        evalInto(expInitializer.exp, offset, facts.size);
    }

    // A plain `=` to a local or parameter. `destOffset` is where the
    // assignment's own value (D specifies an assignment as an expression)
    // goes too, `discardResult` when a caller at statement level has
    // nowhere for it and does not want it.
    private void compileAssign(AssignExp expression, in size_t destOffset) {
        if (auto indexTarget = expression.e1.isIndexExp)
            return compileIndexAssign(expression, indexTarget, destOffset);

        auto varExp = expression.e1.isVarExp;
        auto variable = varExp is null ? null : varExp.var.isVarDeclaration;
        if (variable is null || variable.isDataseg || _layout.isRef(variable))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!isSupportedFacts(facts))
            throw rejection(_function, expression.loc,
                expressionText(expression));

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

    // `arr[i] = value`. Struct-typed elements are out of scope here (they
    // fail `isSupportedElementFacts` below the same way a struct local
    // would), so this never has to worry about the target being anything
    // wider than a single scalar `opStoreIndirect` can write in one go.
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
        if (variable is null || variable.isDataseg || _layout.isRef(variable))
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

        const varOffset = _layout.offsetOf(variable);
        const rightOffset = reserveTemp(facts);
        evalInto(expression.e2, rightOffset, facts.size);
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
        if (variable is null || variable.isDataseg || _layout.isRef(variable))
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
        if (source != _destination)
            emit(&opCopy, _destination, source, _width);
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

            auto returnType = type.next;
            const isVoidCallee = returnType is null || returnType.ty == Tvoid;
            const returnFacts = isVoidCallee
                ? TypeFacts.init
                : TypeFacts.of(returnType);
            if (isVoidCallee && destOffset != discardResult)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            Arg[] args;
            foreach (i; 0 .. parameterCount) {
                auto parameter = type.parameterList[i];
                if (parameter.storageClass & (STC.out_ | STC.lazy_ | STC.ref_))
                    throw rejection(_function, expression.loc,
                        expressionText(expression));

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
            if (!isSupportedFacts(parameter.facts) || parameter.isRef)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            const argumentOffset = reserveTemp(parameter.facts);
            evalInto(
                (*expression.arguments)[i], argumentOffset,
                parameter.facts.size,
            );
            args ~= Arg(argumentOffset, parameter.offset, parameter.facts.size);
        }

        auto calleeReturnType = calleeType.next;
        const isVoidCallee =
            calleeReturnType is null || calleeReturnType.ty == Tvoid;
        const returnFacts =
            isVoidCallee ? TypeFacts.init : TypeFacts.of(calleeReturnType);
        if (!isVoidCallee && !isSupportedFacts(returnFacts))
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

    // A pointer-sized temporary: the shape every address this compiler
    // computes at run time - an array element's, a `static`'s own, an
    // allocation's result - shares, whatever the value living behind it
    // eventually is.
    private TypeFacts pointerFacts() {
        return TypeFacts(size_t.sizeof, size_t.sizeof, false, true);
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
        emit(&opAssert, boundsOffset, 0, 1);

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

        emit(&opConstant, destOffset + arrayLengthOffset,
            addConstant(cast(long) count), size_t.sizeof);

        if (count == 0) {
            emit(&opConstant, destOffset + arrayPointerOffset,
                addConstant(0), size_t.sizeof);
            return;
        }

        const sizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, sizeOffset,
            addConstant(cast(long) (count * elementFacts.size)),
            size_t.sizeof);
        emitAllocate(sizeOffset, destOffset + arrayPointerOffset);

        foreach (i; 0 .. count) {
            auto element = (*expression.elements)[i];
            const elementOffset = reserveTemp(elementFacts);
            evalInto(element, elementOffset, elementFacts.size);

            const addressOffset = reserveTemp(pointerFacts);
            emit(&opCopy, addressOffset, destOffset + arrayPointerOffset,
                size_t.sizeof);
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
