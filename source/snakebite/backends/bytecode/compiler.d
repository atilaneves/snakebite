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
// its way out - by growing `_tempSize`/`_tempAlignment` past it; nothing
// about a temporary slot is ever handed back through `FrameLayout` itself.
private final class FunctionCompiler {
    import dmd.declaration: VarDeclaration;
    import dmd.expression:
        AssignExp, CallExp, DeclarationExp, Expression, IntegerExp, VarExp;
    import dmd.func: FuncDeclaration;
    import dmd.statement:
        CompoundStatement, ExpStatement, ReturnStatement, ScopeStatement,
        Statement;
    import snakebite.backends.bytecode.vm:
        Arg, CallSite, discardResult, Function, Instruction, opCall,
        opConstant, opCopy, opReturn, opReturnVoid;
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
    // Set by the return statement that ends this straight-line body; every
    // statement after it in source is dead code dmd itself only warns
    // about, so nothing is compiled for it, and none of its own kinds -
    // an `if` among them - need this compiler to recognise them.
    private bool _finished;

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

        return Function(
            _instructions, _constants, _callSites, _tempSize, _tempAlignment,
        );
    }

    private void emit(
        Instruction.Handler handler, in size_t a, in size_t b, in size_t c,
    ) {
        _instructions ~= Instruction(handler, a, b, c);
    }

    private size_t addConstant(in long value) {
        _constants ~= value;
        return _constants.length - 1;
    }

    // Grows this compiled function's own frame past whatever `_layout`
    // already reserved, for a value only this compiler's own generated
    // code ever reads or writes - a call's argument, a return value on
    // its way to `returnPlace`. Never reachable through `_layout.offsetOf`,
    // which only ever answers for a declared parameter or local.
    private size_t reserveTemp(in TypeFacts facts) {
        const offset = alignUp(_tempSize, facts.alignment);
        _tempSize = offset + facts.size;
        if (facts.alignment > _tempAlignment)
            _tempAlignment = facts.alignment;

        return offset;
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
        emit(&opReturn, offset, _returnFacts.size, 0);
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

    // Compiles `expression`'s value into `frame[destOffset .. destOffset +
    // width]` - a literal, a parameter or local read, a nested call, or a
    // nested assignment's own value (`return (sum = five());`).
    private void evalInto(
        Expression expression, in size_t destOffset, in size_t width,
    ) {
        if (auto integer = expression.isIntegerExp) {
            emit(&opConstant, destOffset, width, addConstant(integer.toInteger));
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

        throw rejection(_function, expression.loc, expressionText(expression));
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
        emit(&opCall, siteIndex, destOffset, 0);
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
