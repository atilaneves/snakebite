module snakebite.ffi.plan;


import snakebite.ffi.symbol: Resolver;


private:


// Everything about calling one already-compiled function that does not
// change between calls: where the code is, and what each of its arguments
// and its result must become to travel in a register.
//
// This is the FFI barrier's whole point. Deciding those things means
// mangling a symbol name, asking the dynamic linker for its address, and
// walking the dmd type of every parameter - work that costs far more than
// the call it prepares, and none of which can change from one call to the
// next. A plan holds the answers so that a call is only loading slots into
// registers and jumping.
//
// A plan is immutable once built, and holds no dmd types, so calling
// through one touches nothing the frontend owns. Its heart is a list of
// moves: for every eightbyte of every argument, where its bytes come from
// and which `CallFrame` slot (ADR-0001) it lands in. That shape - which
// eightbyte reaches which integer register, SSE register or stack word -
// depends only on the callee's signature, never on an argument's value, so
// `prepare`/`ofRawAddress` compute it once, in `buildMoves`. `callAt` only
// replays it: read a word, write it into the frame, call the System V stub
// (`snakebite.ffi.sysv`) once, and read the result back.
public struct CallPlan {
    import snakebite.ffi.abi: ArgumentPlan, Register;
    import snakebite.ffi.limits: maxArguments;

    // Worst case: every one of `maxArguments` parameters is a two-eightbyte
    // aggregate, plus the hidden return pointer.
    private enum maxMoves = maxArguments * 2 + 1;
    // Worst case: every eightbyte above spills to the stack.
    private enum maxStackWords = maxArguments * 2;

    private enum DestinationKind { integer, sse, stack }

    // Where one eightbyte lands in a `CallFrame` - `index` is a register
    // number (0..5 integer, 0..7 SSE) or a stack word position.
    private struct Destination {
        DestinationKind kind;
        ubyte index;
    }

    // One eightbyte's source and destination, fixed at prepare time. The
    // source is either the hidden return pointer itself, when
    // `isReturnPointer`, or `byteOffset` bytes into argument
    // `parameterIndex`'s own bytes; `register` names its width and sign
    // for the `word` read `callAt` does at call time.
    private struct Move {
        Register register;
        bool isReturnPointer;
        ubyte parameterIndex;
        ubyte byteOffset;
        Destination destination;
    }

    private void* _address;
    // Indexed by parameter, not by register: a dynamic-array parameter
    // reserves one entry here and two registers at call time, since the
    // two travel together as one argument the guest evaluated once.
    private ArgumentPlan[maxArguments] _arguments;
    private size_t _parameterCount;
    private ArgumentPlan _return;
    // Whether `_return` is meaningless because the result travels through
    // a hidden pointer instead - see `needsHiddenReturnPointer`.
    private bool _hiddenReturnPointer;
    // A method or nested function receives its context before its explicit
    // parameters. The caller's first argument slot holds that pointer.
    private bool _hiddenContext;
    // dmd and ldc use different orders when both invisible arguments are
    // present. See `abi.contextPrecedesHiddenReturnPointer`.
    private bool _contextPrecedesHiddenReturnPointer;
    // Whether the callee reads its parameters out of the registers in
    // reverse declaration order - see `abi.reversedDParameters`.
    private bool _reversedArguments;
    // The moves `callAt` replays - see the module comment.
    private Move[maxMoves] _moves;
    private size_t _moveCount;
    // `CallFrame.sseCount`: how many of the moves above land in an SSE
    // register, for a variadic callee's `%al`.
    private size_t _sseCount;
    private size_t _stackWordCount;

    // Calls the function this plan was prepared for.
    //
    // `arguments` are the addresses of each argument's native bytes, in
    // declaration order, and the result is written to `returnPlace` in
    // native layout - the same convention `Backend.call` uses, so a caller
    // hands over slots it already has rather than marshalling anything.
    //
    // `returnPlace` may be `null` to discard the result, and must
    // otherwise be exactly the return type's size.
    pragma(inline, true) public void call(
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        callAt(_address, returnPlace, arguments);
    }

    // Calls another function with this plan's prepared ABI shape: fills a
    // `CallFrame` by replaying the moves `prepare`/`ofRawAddress` computed,
    // calls the System V stub once, and writes the result back.
    pragma(inline, true) public void callAt(
        const(void)* address,
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        import snakebite.ffi.abi: word, writeWord;
        import snakebite.ffi.sysv: CallFrame, call;
        import std.conv: text;

        if (arguments.length != _parameterCount)
            throw new Exception(
                text("ffi: this plan takes ", _parameterCount,
                    " argument(s), got ", arguments.length),
            );

        if (_hiddenReturnPointer && returnPlace is null)
            throw new Exception(
                "ffi: this plan returns a value larger than a " ~
                    "register, and needs somewhere to write it",
            );

        CallFrame frame = void;
        size_t[maxStackWords] stackArea = void;

        foreach (ref move; _moves[0 .. _moveCount]) {
            const value = move.isReturnPointer
                ? cast(size_t) returnPlace
                : word(
                    move.register,
                    cast(ubyte*) arguments[move.parameterIndex]
                        + move.byteOffset,
                );

            final switch (move.destination.kind) with (DestinationKind) {
                case integer:
                    frame.integer[move.destination.index] = value;
                    break;
                case sse:
                    frame.sse[move.destination.index] = asDouble(value);
                    break;
                case stack:
                    stackArea[move.destination.index] = value;
                    break;
            }
        }

        frame.sseCount = _sseCount;
        frame.stack = stackArea.ptr;
        frame.stackWords = _stackWordCount;

        call(address, frame);

        // A hidden-pointer return already left its bytes at `returnPlace`
        // through that pointer, not in the return registers - which the
        // callee leaves holding that same pointer, not the value. A `void`
        // callee leaves the registers holding whatever it last used them
        // for, so reading them in either case would be reading garbage or
        // an address, not the result.
        if (_hiddenReturnPointer || returnPlace is null)
            return;

        auto bytes = cast(ubyte*) returnPlace;
        size_t integerIndex;
        size_t floatingIndex;
        foreach (i; 0 .. _return.count) {
            const resultWord = _return.registers[i].kind == Register.Kind.sse
                ? bitsOf(frame.sseResult[floatingIndex++])
                : frame.integerResult[integerIndex++];
            writeWord(
                _return.registers[i], resultWord, bytes + i * size_t.sizeof,
            );
        }
    }

    // Prepares a plan for a raw address that has no `FuncDeclaration`
    // behind it - a druntime glue-layer hook such as
    // `_d_arraybounds_indexp`, `gc_malloc` or `_d_arrayappendcd`, called
    // by linker symbol rather than a guest declaration `prepare` walks a
    // dmd type for. Every parameter here is one plain integer-class
    // register, already the exact width its own hook expects, so the
    // caller hands over the register shapes directly instead of this
    // classifying a dmd `Type`. `returnRegister` defaults to
    // `Register.Kind.none`, for a hook such as a bounds check that never
    // returns at all: no hidden pointer, nothing to read back. A hook
    // that does return a plain register-width value, such as `gc_malloc`'s
    // pointer, names its own register instead - never more than one
    // eightbyte, the one shape every hook this backend calls this way
    // needs.
    package static CallPlan ofRawAddress(
        const(void)* address,
        scope const(Register)[] parameterRegisters,
        Register returnRegister = Register(Register.Kind.none, 0),
    ) {
        CallPlan plan;
        plan._address = cast(void*) address;
        plan._parameterCount = parameterRegisters.length;
        foreach (i, register; parameterRegisters)
            plan._arguments[i] =
                ArgumentPlan([register, Register.init], 1, false);
        if (returnRegister.kind != Register.Kind.none)
            plan._return =
                ArgumentPlan([returnRegister, Register.init], 1, false);
        plan.buildMoves;
        return plan;
    }

    // Whether this plan, built by `ofRawAddress`, was built from exactly
    // these register shapes - the cache keys such a plan by symbol name
    // alone, so a second caller naming the same symbol has to agree.
    private bool hasShape(
        scope const(Register)[] parameterRegisters,
        in Register returnRegister,
    ) const {
        if (_parameterCount != parameterRegisters.length)
            return false;

        foreach (i, register; parameterRegisters)
            if (_arguments[i].registers[0] != register)
                return false;

        const expectedReturn = returnRegister.kind == Register.Kind.none
            ? ArgumentPlan.init
            : ArgumentPlan([returnRegister, Register.init], 1, false);
        return _return == expectedReturn;
    }

    // Computes `_moves`, `_sseCount` and `_stackWordCount` from this plan's
    // shape alone - see the module comment. Called once, from `prepare`
    // and `ofRawAddress`, after every other field is set.
    private void buildMoves() {
        import snakebite.ffi.abi: maxFloatingArguments, maxIntegerArguments;
        import std.algorithm: sort;

        size_t integerCount;
        size_t floatingCount;
        size_t stackCount;
        size_t moveCount;

        void addRegisterMove(
            in Register register,
            in bool isReturnPointer,
            in size_t parameterIndex,
            in size_t byteOffset,
            in bool toFloating,
        ) {
            const destination = toFloating
                ? Destination(
                    DestinationKind.sse, cast(ubyte) floatingCount++)
                : Destination(
                    DestinationKind.integer, cast(ubyte) integerCount++);
            _moves[moveCount++] = Move(
                register, isReturnPointer, cast(ubyte) parameterIndex,
                cast(ubyte) byteOffset, destination,
            );
        }

        void addStackMove(
            in Register register,
            in size_t parameterIndex,
            in size_t byteOffset,
        ) {
            _moves[moveCount++] = Move(
                register, false, cast(ubyte) parameterIndex,
                cast(ubyte) byteOffset,
                Destination(DestinationKind.stack, cast(ubyte) stackCount++),
            );
        }

        // Every eightbyte of argument `i` claims the next register in its
        // own file - only called once that file is known to have room for
        // all of them.
        void registerArgument(in size_t i) {
            const plan = _arguments[i];
            foreach (j; 0 .. plan.count) {
                const toFloating =
                    plan.registers[j].kind == Register.Kind.sse;
                addRegisterMove(
                    plan.registers[j], false, i, j * size_t.sizeof,
                    toFloating,
                );
            }
        }

        size_t firstExplicit;
        if (_hiddenContext) {
            firstExplicit = 1;
            if (_contextPrecedesHiddenReturnPointer)
                registerArgument(0);
        }

        if (_hiddenReturnPointer)
            addRegisterMove(
                Register(Register.Kind.pointer, 8), true, 0, 0, false,
            );

        if (_hiddenContext && !_contextPrecedesHiddenReturnPointer)
            registerArgument(0);

        // dmd's reversed register assignment (see `_reversedArguments`)
        // only ever reorders which parameter reaches the register file
        // first - the stack is a fixed extension of that same file, read
        // by the callee in ordinary declaration order regardless. A
        // parameter that does not fit is deferred to a second pass, in
        // ascending order, once every parameter that does fit has claimed
        // its register.
        size_t[maxArguments] spilled;
        size_t spilledCount;

        // Whether argument `i`'s own eightbytes all still fit in whichever
        // register file(s) they classify to - never a partial answer,
        // since the SysV ABI passes a value classified into more than one
        // eightbyte either entirely in registers or entirely on the
        // stack, never split across that boundary. A mixed INTEGER/SSE
        // pair (one lane of each) is no exception here: both its lanes
        // must find room in their own file, or the whole pair spills to
        // the stack together.
        void visit(in size_t i) {
            const plan = _arguments[i];
            size_t integerLanes;
            size_t floatingLanes;
            foreach (register; plan.registers[0 .. plan.count])
                if (register.kind == Register.Kind.sse)
                    ++floatingLanes;
                else
                    ++integerLanes;

            const mixed = integerLanes == 1 && floatingLanes == 1;
            const integerSpills = integerLanes > 0
                && integerCount + integerLanes > maxIntegerArguments;
            const floatingSpills = floatingLanes > 0
                && floatingCount + floatingLanes > maxFloatingArguments;

            if (mixed && integerSpills && floatingSpills)
                throw new Exception(
                    "ffi cannot place a mixed INTEGER/SSE aggregate " ~
                        "when both register files need stack arguments",
                );

            if (!integerSpills && !floatingSpills)
                registerArgument(i);
            else
                spilled[spilledCount++] = i;
        }

        if (_reversedArguments)
            foreach_reverse (i; firstExplicit .. _parameterCount)
                visit(i);
        else
            foreach (i; firstExplicit .. _parameterCount)
                visit(i);

        sort(spilled[0 .. spilledCount]);
        foreach (i; spilled[0 .. spilledCount]) {
            const plan = _arguments[i];
            foreach (j; 0 .. plan.count)
                addStackMove(plan.registers[j], i, j * size_t.sizeof);
        }

        _moveCount = moveCount;
        _sseCount = floatingCount;
        _stackWordCount = stackCount;
    }
}

private size_t bitsOf(in double value) @trusted pure nothrow @nogc {
    return *cast(const size_t*) &value;
}

private double asDouble(in size_t bits) @trusted pure nothrow @nogc {
    return *cast(const double*) &bits;
}

// The DMD-free runtime entry point for a prepared call. Backends keep the
// plan opaque and hand this function addresses of values already stored in
// native layout.
public extern(C) void executeCallPlan(
    const(void)* opaquePlan,
    void* returnPlace,
    scope const(void*)* arguments,
    size_t argumentCount,
) {
    const plan = cast(const(CallPlan)*) opaquePlan;
    plan.call(returnPlace, arguments[0 .. argumentCount]);
}

// The plans already prepared, one per function. A backend owns one of
// these and keeps it for its whole life, so the second call to a function
// and every call after it reuses the first call's answers.
//
// Keyed by declaration rather than by call site: two call sites naming the
// same function need the very same plan, and the declaration is what both
// resolve to. A call site is the finer key, and would let a plan be found
// without hashing at all, but it needs somewhere on the call site to keep
// it, which is the caller's business and not this package's.
public struct PlanCache {
    private CallPlan*[imported!"dmd.func".FuncDeclaration] _plans;
    private CallPlan*[string] _rawPlans;
    private bool[imported!"dmd.func".FuncDeclaration] _nativeSymbols;
    private Resolver _resolver;
    private size_t _preparations;
    version(unittest) private size_t _nativeSymbolLookups;

    // Resolves a linker name through the cache shared by this backend's
    // plan preparation and its other FFI operations.
    public void* resolve(in char[] name) {
        return _resolver.resolve(name);
    }

    // Whether `function_` has machine code in this process. Missing symbols
    // are cached too because a synthesized function with a body can validly
    // have no native counterpart.
    public bool hasNativeSymbol(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import dmd.mangle: mangleExact;
        import snakebite.druntime.constructoratomic: nativeTarget;
        import std.string: fromStringz;

        if (auto cached = function_ in _nativeSymbols)
            return *cached;

        version(unittest) ++_nativeSymbolLookups;
        auto target = nativeTarget(function_);
        const found = target.address !is null || resolve(
            mangleExact(function_).fromStringz,
        ) !is null;
        _nativeSymbols[function_] = found;
        return found;
    }

    version(unittest)
    public size_t nativeSymbolLookups()
        @safe @nogc nothrow pure const scope
    {
        return _nativeSymbolLookups;
    }

    version(unittest)
    public size_t symbolLookups() @safe @nogc nothrow pure const scope {
        return _resolver.lookups;
    }

    // How many plans this has had to prepare - the expensive work the
    // cache exists to avoid, counted so that it can be asserted on.
    //
    // The address of a cached plan cannot stand in for this: an
    // associative array's slot keeps its address when its value is
    // overwritten, so a cache that rebuilt a plan on every call would
    // still hand back the same address every time.
    public size_t preparations() const {
        return _preparations;
    }

    // `function_`'s plan, prepared on its first call and reused after.
    //
    // Returned by reference: the plan stays in the cache, and a caller
    // only ever calls through it.
    public ref const(CallPlan) of(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        if (auto cached = function_ in _plans)
            return **cached;

        ++_preparations;
        auto plan = new CallPlan;
        *plan = prepare(function_, _resolver);
        _plans[function_] = plan;
        return *plan;
    }

    // As `.of`, but for a raw address with no `FuncDeclaration` to key
    // on - see `CallPlan.ofRawAddress`. Keyed and cached by linker symbol
    // name instead, so a second bounds check anywhere in the guest
    // program reuses the first one's resolved address and plan. Returns
    // `null` when the symbol is not in this process, the same convention
    // `resolve` itself uses.
    public const(CallPlan)* rawPlanOf(
        string name,
        scope const(imported!"snakebite.ffi.abi".Register)[]
            parameterRegisters,
        imported!"snakebite.ffi.abi".Register returnRegister =
            imported!"snakebite.ffi.abi".Register(
                imported!"snakebite.ffi.abi".Register.Kind.none, 0),
    ) {
        if (auto cached = name in _rawPlans) {
            import std.conv: text;

            assert((*cached).hasShape(parameterRegisters, returnRegister),
                text("ffi: `", name, "` was already planned with a ",
                    "different register shape"));
            return *cached;
        }

        auto address = resolve(name);
        if (address is null)
            return null;

        ++_preparations;
        auto plan = new CallPlan;
        *plan = CallPlan.ofRawAddress(
            address, parameterRegisters, returnRegister);
        _rawPlans[name] = plan;
        return plan;
    }

}

// Works out how to call `function_`, once.
//
// The linkage decides only the symbol's name, which dmd's own mangler
// supplies, so nothing here is specific to C. A signature the implemented
// ABI does not cover throws, naming what it could not pass - here, when
// the plan is prepared, rather than on every call that would use it.
private CallPlan prepare(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
) {
    import snakebite.frontend.dmd.delegates: hasHiddenThis;
    import snakebite.druntime.constructoratomic: nativeTarget;
    import snakebite.ffi.abi:
        ArgumentPlan, Register, contextPrecedesHiddenReturnPointer,
        needsHiddenReturnPointer, reversedDParameters,
        supported;
    import snakebite.ffi.limits: maxArguments;
    import dmd.astenums: LINK, STC, VarArg;
    import dmd.mangle: mangleExact;
    import dmd.typesem: nextOf;
    import std.conv: text;
    import std.string: fromStringz;

    static if (!supported)
        throw new Exception(
            "ffi is implemented for the System V AMD64 ABI only",
        );
    else {
        auto type = function_.type.isTypeFunction;
        if (type is null)
            throw new Exception(
                text("ffi cannot call `", function_.toString,
                    "`: it is not a function"),
            );

        // A variadic callee is handed its arguments differently - on the
        // System V AMD64 ABI the caller must also report how many SSE
        // registers it used - so the fixed-arity call this plans would be
        // the wrong call, not merely an incomplete one.
        if (type.parameterList.varargs != VarArg.none)
            throw new Exception(
                text("ffi cannot call the variadic function `",
                    function_.toString, "`"),
            );

        const count = type.parameterList.length;
        const hasContext = hasHiddenThis(function_);
        const argumentCount = count + hasContext;
        if (argumentCount > maxArguments)
            throw new Exception(
                text("ffi cannot call `", function_.toString, "`: it takes ",
                    argumentCount,
                    hasContext
                        ? " arguments including hidden context, "
                        : " arguments, ",
                    "and at most ", maxArguments,
                    " argument slots are available"),
            );

        CallPlan plan;
        // A `ref` return hands back the *address* of the result in the
        // return register, not the result: that address is what travels,
        // whatever `type.nextOf` says, so the return is a pointer and
        // never needs the hidden pointer a large returned *value* would.
        // The caller gets the address and reads the value through it -
        // the call adapter in `ffi.call` applies this same convention to
        // interpreted and native callees.
        const returnsRef = type.isRef != 0;
        plan._hiddenReturnPointer =
            !returnsRef && needsHiddenReturnPointer(type.nextOf);
        plan._contextPrecedesHiddenReturnPointer =
            contextPrecedesHiddenReturnPointer;

        auto target = nativeTarget(function_);

        // The symbol's calling convention comes from its declared linkage,
        // and `extern(D)` code built by the host's own compiler can read
        // its parameters out of the registers in reverse order - an ABI
        // fact about this process, not a routing decision about the
        // callee.
        const linkage = target.address is null
            ? function_.resolvedLinkage : target.linkage;
        plan._reversedArguments = reversedDParameters
            && (linkage == LINK.d || linkage == LINK.default_);

        size_t words;
        if (plan._hiddenReturnPointer)
            words = 1;

        size_t argumentIndex;
        if (hasContext) {
            plan._hiddenContext = true;
            plan._arguments[argumentIndex++] = ArgumentPlan(
                [Register(Register.Kind.pointer, 8), Register.init], 1,
                false,
            );
            ++words;
        }

        foreach (i; 0 .. count) {
            // A `ref` parameter occupies a pointer slot in the caller's
            // frame - the address of the argument's own storage, not a
            // copy of its value (see `FrameLayout.of` in
            // `backends/layout.d`, which lays such a slot out the
            // same way). That address is the value that travels, so the
            // argument is one pointer register whatever
            // `parameterList[i].type` - the *pointee* type - would
            // classify as.
            const storageClass = type.parameterList[i].storageClass;
            const isRef = (storageClass & (STC.ref_ | STC.out_)) != 0;
            const argument = isRef
                ? ArgumentPlan(
                    [Register(Register.Kind.pointer, 8), Register.init], 1,
                    false,
                )
                : storageClass & STC.lazy_
                    ? ArgumentPlan(
                        [
                            Register(Register.Kind.pointer, 8),
                            Register(Register.Kind.pointer, 8),
                        ],
                        2,
                        false,
                    )
                : ArgumentPlan.of(type.parameterList[i].type);
            words += argument.count;
            if (words > maxArguments)
                throw new Exception(
                    text("ffi cannot call `", function_.toString,
                        "`: its arguments need more than ", maxArguments,
                        " ABI words"),
                );

            plan._arguments[argumentIndex++] = argument;
        }

        auto name = mangleExact(function_);
        void* address = target.address;
        if (address is null)
            address = resolver.resolve(name.fromStringz);
        if (address is null)
            throw new Exception(
                text("ffi cannot resolve the symbol `", name.fromStringz,
                    "` declared by `", function_.toString,
                    "`: it is not in this process"),
            );

        plan._address = address;
        plan._parameterCount = argumentCount;
        if (returnsRef) {
            plan._return = ArgumentPlan(
                [Register(Register.Kind.pointer, 8), Register.init], 1,
                false,
            );
        } else if (!plan._hiddenReturnPointer)
            plan._return = ArgumentPlan.of(type.nextOf);

        plan.buildMoves;

        return plan;
    }
}
