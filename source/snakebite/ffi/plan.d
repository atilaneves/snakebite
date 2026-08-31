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
// through one touches nothing the frontend owns.
public struct CallPlan {
    import snakebite.ffi.abi: ArgumentPlan, Register, maxArguments;

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

    // Calls the function this plan was prepared for.
    //
    // `arguments` are the addresses of each argument's native bytes, in
    // declaration order, and the result is written to `returnPlace` in
    // native layout - the same convention `Backend.call` uses, so a caller
    // hands over slots it already has rather than marshalling anything.
    //
    // `returnPlace` may be `null` to discard the result, and must
    // otherwise be exactly the return type's size.
    public void call(
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        import snakebite.ffi.abi: invoke, word, writeWord;
        import std.conv: text;

        if (arguments.length != _parameterCount)
            throw new Exception(
                text("ffi: this plan takes ", _parameterCount,
                    " argument(s), got ", arguments.length),
            );

        size_t[maxArguments] words;
        Register.Kind[maxArguments] kinds;
        size_t slot;

        void loadHiddenReturnPointer() {
            if (!_hiddenReturnPointer)
                return;

            if (returnPlace is null)
                throw new Exception(
                    "ffi: this plan returns a value larger than a " ~
                        "register, and needs somewhere to write it",
                );

            words[slot] = cast(size_t) returnPlace;
            kinds[slot++] = Register.Kind.pointer;
        }

        // A parameter's own eightbytes keep their order either way; what
        // reverses is which parameter gets the lower-numbered registers.
        void load(in size_t i) {
            const plan = _arguments[i];
            auto bytes = cast(ubyte*) arguments[i];
            foreach (j; 0 .. plan.count) {
                words[slot] =
                    word(plan.registers[j], bytes + j * size_t.sizeof);
                kinds[slot++] = plan.registers[j].kind;
            }
        }

        size_t firstExplicit;
        if (_hiddenContext) {
            firstExplicit = 1;
            if (_contextPrecedesHiddenReturnPointer)
                load(0);
        }

        loadHiddenReturnPointer();

        if (_hiddenContext && !_contextPrecedesHiddenReturnPointer)
            load(0);

        if (_reversedArguments)
            foreach_reverse (i; firstExplicit .. arguments.length)
                load(i);
        else
            foreach (i; firstExplicit .. arguments.length)
                load(i);

        const result = invoke(cast(void*) _address,
            words[0 .. slot], kinds[0 .. slot], _return);

        // A hidden-pointer return already left its bytes at `returnPlace`
        // through that pointer, not in the return registers - which the
        // callee leaves holding that same pointer, not the value. A `void`
        // callee leaves the registers holding whatever it last used them
        // for, so reading them in either case would be reading garbage or
        // an address, not the result.
        if (!_hiddenReturnPointer && returnPlace !is null) {
            const size_t[2] resultWords = [result.first, result.second];
            auto bytes = cast(ubyte*) returnPlace;
            size_t integerIndex;
            size_t floatingIndex;
            foreach (i; 0 .. _return.count) {
                const resultWord = _return.registers[i].kind
                    == Register.Kind.sse
                    ? (floatingIndex++ == 0
                        ? result.floatingFirst : result.floatingSecond)
                    : resultWords[integerIndex++];
                writeWord(_return.registers[i], resultWord,
                    bytes + i * size_t.sizeof);
            }
        }
    }
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
    private CallPlan[imported!"dmd.func".FuncDeclaration] _plans;
    private Resolver _resolver;
    private size_t _preparations;

    // Resolves a linker name through the cache shared by this backend's
    // plan preparation and its other FFI operations.
    public void* resolve(in char[] name) {
        return _resolver.resolve(name);
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
            return *cached;

        ++_preparations;
        _plans[function_] = prepare(function_, _resolver);
        return _plans[function_];
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
    import snakebite.ffi.abi:
        ArgumentPlan, Register, contextPrecedesHiddenReturnPointer,
        maxArguments, needsHiddenReturnPointer, reversedDParameters,
        supported;
    import dmd.astenums: LINK, STC, VarArg;
    import dmd.mangle: mangleExact;
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
        const hasContext = function_.vthis !is null;
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
        // the same convention the interpreter's own `ref`-returning
        // calls use (`resolvedRefAddress` in `interpreter/walker.d`).
        const returnsRef = type.isRef != 0;
        plan._hiddenReturnPointer =
            !returnsRef && needsHiddenReturnPointer(type.nextOf);
        plan._contextPrecedesHiddenReturnPointer =
            contextPrecedesHiddenReturnPointer;

        // The symbol's calling convention comes from its declared linkage,
        // and `extern(D)` code built by the host's own compiler can read
        // its parameters out of the registers in reverse order - an ABI
        // fact about this process, not a routing decision about the
        // callee.
        const linkage = function_.resolvedLinkage;
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
            // `interpreter/framelayout.d`, which lays such a slot out the
            // same way). That address is the value that travels, so the
            // argument is one pointer register whatever
            // `parameterList[i].type` - the *pointee* type - would
            // classify as.
            const isRef = (type.parameterList[i].storageClass & STC.ref_) != 0;
            const argument = isRef
                ? ArgumentPlan(
                    [Register(Register.Kind.pointer, 8), Register.init], 1,
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
        auto address = resolver.resolve(name.fromStringz);
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

        return plan;
    }
}
