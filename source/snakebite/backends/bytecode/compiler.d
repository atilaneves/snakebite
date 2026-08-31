module snakebite.backends.bytecode.compiler;


private:


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Function, Vm;
    import snakebite.exception: SnakebiteException;
    import snakebite.framestack: defaultFrameCapacity;

    private Vm _vm;
    // Keyed by pointer, not by value: a call site compiled while
    // `function_` itself is still mid-compile - direct or mutual
    // recursion - embeds this pointer in its `CallSite` before the body
    // this AA slot points at has been filled in. The slot's address must
    // therefore never move once handed out, which is why this holds a
    // `Function*` rather than a `Function` - a heap block `new` allocates
    // once and never relocates, unlike an associative array's own
    // storage, which can rehash as more entries go in.
    private Function*[FuncDeclaration] _compiled;

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
        import snakebite.nativelayout: isIntegralSize, TypeFacts;
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
        if (!isVoidReturn && !(returnFacts.isIntegral && isIntegralSize(returnFacts.size)))
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
            if (!facts.isIntegral || !isIntegralSize(facts.size))
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
private final class FunctionCompiler {
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AssignExp, BinAssignExp, BinExp, CallExp, CastExp, CmpExp, CondExp,
        DeclarationExp, EqualExp, Expression, IntegerExp, LogicalExp, NotExp,
        PostExp, UnaExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.statement:
        CompoundStatement, ContinueStatement, ExpStatement, ForStatement,
        IfStatement, ReturnStatement, ScopeStatement, Statement,
        WhileStatement;
    import dmd.tokens: EXP;
    import snakebite.backends.bytecode.vm:
        Arg, CallSite, discardResult, Function, Instruction, opAdd, opBitAnd,
        opBitOr, opBitXor, opBranchFalse, opBranchTrue, opCall,
        opCastToBool, opCastWidenSigned, opCastWidenUnsigned, opComplement,
        opConstant, opCopy, opDivideSigned, opDivideUnsigned, opEqual,
        opGreaterOrEqualSigned, opGreaterOrEqualUnsigned, opGreaterThanSigned,
        opGreaterThanUnsigned, opJump, opLessOrEqualSigned,
        opLessOrEqualUnsigned, opLessThanSigned, opLessThanUnsigned,
        opLogicalNot, opModuloSigned, opModuloUnsigned, opMultiply,
        opNegate, opNotEqual, opReturn, opReturnVoid, opShiftLeft,
        opShiftRightArithmetic, opShiftRightLogical, opSubtract;
    import snakebite.backends.layout: FrameLayout;
    import snakebite.exception: SnakebiteException;
    import snakebite.nativelayout: alignUp, isIntegralSize, TypeFacts;

    private Bytecode _bytecode;
    private FuncDeclaration _function;
    private const FrameLayout _layout;
    private TypeFacts _returnFacts;
    private bool _isVoidReturn;

    private Instruction[] _instructions;
    private long[] _constants;
    private CallSite[] _callSites;
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
            _instructions, _constants, _callSites, _tempSize, _tempAlignment,
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

        if (auto compound = statement.isCompoundStatement) {
            if (compound.statements !is null)
                foreach (child; *compound.statements) {
                    if (_finished)
                        return;

                    compileStatement(child);
                }
            return;
        }

        if (auto scope_ = statement.isScopeStatement) {
            compileStatement(scope_.statement);
            return;
        }

        if (statement.isImportStatement)
            return;

        if (auto ret = statement.isReturnStatement) {
            compileReturn(ret);
            return;
        }

        if (auto exp = statement.isExpStatement) {
            if (exp.exp !is null)
                compileEffect(exp.exp);
            return;
        }

        if (auto if_ = statement.isIfStatement) {
            compileIf(if_);
            return;
        }

        if (auto while_ = statement.isWhileStatement) {
            compileWhile(while_);
            return;
        }

        if (auto for_ = statement.isForStatement) {
            compileFor(for_);
            return;
        }

        if (auto continue_ = statement.isContinueStatement) {
            compileContinue(continue_);
            return;
        }

        throw rejection(_function, statement.loc, statementText(statement));
    }

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
    private size_t compileCondition(Expression condition) {
        const facts = TypeFacts.of(condition.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, condition.loc,
                expressionText(condition));

        const offset = reserveTemp(facts);
        evalInto(condition, offset, facts.size);
        return offset;
    }

    private size_t conditionWidth(Expression condition) {
        return TypeFacts.of(condition.type).size;
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
        const jumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);
        _instructions[branchIndex].source = _instructions.length;

        compileStatement(statement.elsebody);
        const elseFinished = _finished;
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
        const conditionOffset = compileCondition(statement.condition);
        const width = conditionWidth(statement.condition);

        const branchIndex = _instructions.length;
        emit(&opBranchFalse, conditionOffset, 0, width);

        _loops ~= LoopContext(loopStart);
        compileStatement(statement._body);
        const bodyFinished = _finished;
        _loops = _loops[0 .. $ - 1];
        _finished = false;

        emit(&opJump, loopStart, 0, 0);
        _instructions[branchIndex].source = _instructions.length;

        _finished = isTriviallyTrueCondition(statement.condition)
            && bodyFinished;
    }

    private void compileFor(ForStatement statement) {
        if (statement._init !is null)
            compileStatement(statement._init);

        const hasCondition = statement.condition !is null;
        const conditionIndex = _instructions.length;
        size_t branchIndex = size_t.max;
        if (hasCondition) {
            const conditionOffset = compileCondition(statement.condition);
            const width = conditionWidth(statement.condition);
            branchIndex = _instructions.length;
            emit(&opBranchFalse, conditionOffset, 0, width);
        }

        _loops ~= LoopContext();
        compileStatement(statement._body);
        const bodyFinished = _finished;
        _finished = false;

        const incrementIndex = _instructions.length;
        resolveContinues(incrementIndex);
        _loops = _loops[0 .. $ - 1];

        if (statement.increment !is null)
            compileEffect(statement.increment);

        emit(&opJump, conditionIndex, 0, 0);

        if (branchIndex != size_t.max)
            _instructions[branchIndex].source = _instructions.length;

        _finished = isTriviallyTrueCondition(statement.condition)
            && bodyFinished;
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
        if (auto declaration = expression.isDeclarationExp) {
            compileDeclaration(declaration);
            return;
        }

        if (auto call = expression.isCallExp) {
            compileCall(call, discardResult);
            return;
        }

        if (auto assign = assignLike(expression)) {
            compileAssign(assign, discardResult);
            return;
        }

        if (auto compound = expression.isBinAssignExp) {
            compileCompoundAssign(compound, discardResult);
            return;
        }

        if (auto post = expression.isPostExp) {
            compilePost(post, discardResult);
            return;
        }

        // dmd builds a comma expression when a `for`'s own initialiser is
        // more than one expression - `for (i = 0, j = 10; ...)` - the same
        // node it uses to sequence a scoped temporary's setup before an
        // expression that needs it. Both operands run for their own
        // effects alone here; a comma expression's *value* (its right
        // side) is only ever needed when it is itself a nested operand,
        // which `evalInto` handles.
        if (auto comma = expression.isCommaExp) {
            compileEffect(comma.e1);
            compileEffect(comma.e2);
            return;
        }

        throw rejection(_function, expression.loc, expressionText(expression));
    }

    // dmd represents `=`, and a local or field's own construction and
    // default blit, as three different `AssignExp` subclasses distinguished
    // only by `op` (`ConstructExp`/`BlitExp` narrow it after semantic
    // analysis, the way `sum = 0` in `long sum = 0;`'s own initialiser
    // arrives as a `ConstructExp`, not a bare `AssignExp`). All three write
    // the same bytes the same way for an integral target - no destructor,
    // no postblit, nothing construction and assignment specify
    // differently - so this compiler treats them alike rather than
    // refusing two thirds of them. `isConstructExp`/`isBlitExp` upcast to
    // `AssignExp` implicitly, a safe conversion the compiler itself
    // checks - unlike `cast(AssignExp) expression`, an unsound downcast
    // dmd's `extern(C++)` nodes carry no `ClassInfo` to support.
    private AssignExp assignLike(Expression expression) {
        if (auto assign = expression.isAssignExp)
            return assign;

        if (auto construct = expression.isConstructExp)
            return construct;

        if (auto blit = expression.isBlitExp)
            return blit;

        return null;
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
        if (!facts.isIntegral || !isIntegralSize(facts.size))
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
        auto varExp = expression.e1.isVarExp;
        auto variable = varExp is null ? null : varExp.var.isVarDeclaration;
        if (variable is null || variable.isDataseg || _layout.isRef(variable))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const targetOffset = _layout.offsetOf(variable);
        evalInto(expression.e2, targetOffset, facts.size);

        if (destOffset != discardResult && destOffset != targetOffset)
            emit(&opCopy, destOffset, targetOffset, facts.size);
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
        if (auto integer = expression.isIntegerExp) {
            emit(&opConstant, destOffset, addConstant(integer.toInteger), width);
            return;
        }

        if (auto varExp = expression.isVarExp) {
            auto variable = varExp.var.isVarDeclaration;
            if (variable is null || variable.isDataseg
                    || _layout.isRef(variable))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            const srcOffset = _layout.offsetOf(variable);
            if (srcOffset != destOffset)
                emit(&opCopy, destOffset, srcOffset, width);
            return;
        }

        if (auto call = expression.isCallExp) {
            compileCall(call, destOffset);
            return;
        }

        if (auto assign = assignLike(expression)) {
            compileAssign(assign, destOffset);
            return;
        }

        if (auto compound = expression.isBinAssignExp) {
            compileCompoundAssign(compound, destOffset);
            return;
        }

        if (auto post = expression.isPostExp) {
            compilePost(post, destOffset);
            return;
        }

        if (auto comma = expression.isCommaExp) {
            compileEffect(comma.e1);
            evalInto(comma.e2, destOffset, width);
            return;
        }

        if (auto cast_ = expression.isCastExp) {
            compileCast(cast_, destOffset, width);
            return;
        }

        if (auto not = expression.isNotExp) {
            compileNot(not, destOffset);
            return;
        }

        if (auto logical = expression.isLogicalExp) {
            compileLogical(logical, destOffset, width);
            return;
        }

        if (auto cond = expression.isCondExp) {
            compileTernary(cond, destOffset, width);
            return;
        }

        if (auto cmp = asCmpExp(expression)) {
            compileComparison(cmp, destOffset);
            return;
        }

        if (auto eq = expression.isEqualExp) {
            compileComparison(eq, destOffset);
            return;
        }

        if (auto neg = expression.isNegExp) {
            compileUnary(neg, destOffset, width, &opNegate);
            return;
        }

        if (auto com = expression.isComExp) {
            compileUnary(com, destOffset, width, &opComplement);
            return;
        }

        if (auto add = expression.isAddExp) {
            compileBinary(add, destOffset, width, &opAdd);
            return;
        }

        if (auto min = expression.isMinExp) {
            compileBinary(min, destOffset, width, &opSubtract);
            return;
        }

        if (auto mul = expression.isMulExp) {
            compileBinary(mul, destOffset, width, &opMultiply);
            return;
        }

        if (auto and_ = expression.isAndExp) {
            compileBinary(and_, destOffset, width, &opBitAnd);
            return;
        }

        if (auto or_ = expression.isOrExp) {
            compileBinary(or_, destOffset, width, &opBitOr);
            return;
        }

        if (auto xor_ = expression.isXorExp) {
            compileBinary(xor_, destOffset, width, &opBitXor);
            return;
        }

        if (auto shl = expression.isShlExp) {
            compileBinary(shl, destOffset, width, &opShiftLeft);
            return;
        }

        if (auto ushr = expression.isUshrExp) {
            compileBinary(ushr, destOffset, width, &opShiftRightLogical);
            return;
        }

        if (auto shr = expression.isShrExp) {
            const unsigned = TypeFacts.of(shr.e1.type).isUnsigned;
            compileBinary(shr, destOffset, width,
                unsigned ? &opShiftRightLogical : &opShiftRightArithmetic);
            return;
        }

        if (auto div = expression.isDivExp) {
            const unsigned = TypeFacts.of(div.e1.type).isUnsigned;
            compileBinary(div, destOffset, width,
                unsigned ? &opDivideUnsigned : &opDivideSigned);
            return;
        }

        if (auto mod = expression.isModExp) {
            const unsigned = TypeFacts.of(mod.e1.type).isUnsigned;
            compileBinary(mod, destOffset, width,
                unsigned ? &opModuloUnsigned : &opModuloSigned);
            return;
        }

        throw rejection(_function, expression.loc, expressionText(expression));
    }

    // dmd has no generated `isCmpExp()` (see the commented-out entry in
    // its own `Expression` class), unlike every other binary operator
    // this compiler recognises by node kind - so this checks `op` and
    // casts itself, the same test dmd's own generated methods make.
    private CmpExp asCmpExp(Expression expression) {
        with (EXP) switch (expression.op) {
            case lessThan, lessOrEqual, greaterThan, greaterOrEqual:
                return cast(CmpExp) expression;
            default:
                return null;
        }
    }

    // `+`, `-`, `*`, `&`, `|`, `^`, `<<`, `>>`, `>>>`, `/`, `%`: evaluates
    // the left operand directly into `destOffset` - already this
    // expression's own destination, so no separate slot is needed for
    // it - then the right operand into a temporary of its own, and
    // combines the two in place with `handler`, already the right one
    // for this operator and, where it matters, this expression's own
    // signedness (decided by the caller, which knows which operator this
    // is; this compiler has no per-operator table of its own to keep in
    // step with the VM's opcodes).
    private void compileBinary(
        BinExp expression, in size_t destOffset, in size_t width,
        Instruction.Handler handler,
    ) {
        const facts = TypeFacts.of(expression.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        evalInto(expression.e1, destOffset, width);
        const rightOffset = reserveTemp(facts);
        evalInto(expression.e2, rightOffset, width);
        emit(handler, destOffset, rightOffset, width);
    }

    // `<`, `<=`, `>`, `>=`, `==`, `!=`: both operands are read into
    // temporaries of their own common width - not necessarily
    // `destOffset`'s own width, since the result is always a one-byte
    // `bool` - and the comparison opcode leaves its answer in the first
    // of those, copied out to `destOffset` only when it differs.
    private void compileComparison(BinExp expression, in size_t destOffset) {
        const operandFacts = TypeFacts.of(expression.e1.type);
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

    // `!x`: evaluated at the operand's own width, then reduced to a
    // single-byte `bool` the same way a comparison is - copied out to
    // `destOffset` only when the temporary is not already it.
    private void compileNot(NotExp expression, in size_t destOffset) {
        const facts = TypeFacts.of(expression.e1.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const operandOffset = reserveTemp(facts);
        evalInto(expression.e1, operandOffset, facts.size);
        emit(&opLogicalNot, operandOffset, 0, facts.size);

        if (destOffset != operandOffset)
            emit(&opCopy, destOffset, operandOffset, 1);
    }

    // `&&`/`||`: the left operand, already `bool`-typed, is evaluated
    // directly into `destOffset`; a branch skips the right operand
    // exactly when D's own short-circuit rule says to - `&&` skips it
    // once the left side is already false, `||` once it is already
    // true - leaving the left side's own value as the whole expression's
    // answer. Otherwise the right operand overwrites `destOffset`,
    // becoming the answer instead.
    private void compileLogical(
        LogicalExp expression, in size_t destOffset, in size_t width,
    ) {
        evalInto(expression.e1, destOffset, width);

        const branchIndex = _instructions.length;
        auto shortCircuit = expression.op == EXP.andAnd
            ? &opBranchFalse : &opBranchTrue;
        emit(shortCircuit, destOffset, 0, width);

        evalInto(expression.e2, destOffset, width);
        _instructions[branchIndex].source = _instructions.length;
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
        import dmd.astenums: Tvoid;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        if (expression.f is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto callee = expression.f;
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
            if (!parameter.facts.isIntegral
                    || !isIntegralSize(parameter.facts.size)
                    || parameter.isRef)
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
        if (!isVoidCallee
                && !(returnFacts.isIntegral && isIntegralSize(returnFacts.size)))
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
