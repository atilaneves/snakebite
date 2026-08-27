module snakebite.ffi.plan;


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
    private Register _return;
    // Whether `_return` is meaningless because the result travels through
    // a hidden pointer instead - see `needsHiddenReturnPointer`.
    private bool _hiddenReturnPointer;

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
        size_t slot;

        // The hidden pointer is itself the first argument register, ahead
        // of every real one - the callee writes the result through it
        // rather than leaving it in a register, so the caller must have
        // supplied somewhere for that to land.
        if (_hiddenReturnPointer) {
            if (returnPlace is null)
                throw new Exception(
                    "ffi: this plan returns a value larger than a " ~
                        "register, and needs somewhere to write it",
                );

            words[slot++] = cast(size_t) returnPlace;
        }

        foreach (i, argument; arguments) {
            const plan = _arguments[i];
            auto bytes = cast(ubyte*) argument;
            foreach (j; 0 .. plan.count)
                words[slot++] =
                    word(plan.registers[j], bytes + j * size_t.sizeof);
        }

        const result = invoke(cast(void*) _address, words[0 .. slot]);

        // A hidden-pointer return already left its bytes at `returnPlace`
        // through that pointer, not in the return register - which the
        // callee leaves holding that same pointer, not the value. A `void`
        // callee leaves the register holding whatever it last used it for,
        // so reading it in either case would be reading garbage or an
        // address, not the result.
        if (!_hiddenReturnPointer && returnPlace !is null)
            writeWord(_return, result, returnPlace);
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
    private size_t _preparations;

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
        _plans[function_] = prepare(function_);
        return _plans[function_];
    }
}

// Works out how to call `function_`, once.
//
// The linkage decides only the symbol's name, which dmd's own mangler
// supplies, so nothing here is specific to C. A signature the implemented
// ABI does not cover throws, naming what it could not pass - here, when
// the plan is prepared, rather than on every call that would use it.
private CallPlan prepare(imported!"dmd.func".FuncDeclaration function_) {
    import snakebite.ffi.abi:
        ArgumentPlan, Register, maxArguments, needsHiddenReturnPointer,
        supported;
    import snakebite.ffi.symbol: symbolAddress;
    import dmd.astenums: STC, VarArg;
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

        // A `ref` return hands back the *address* of the result in the
        // return register, not the result. `type.nextOf` is the
        // referred-to type either way, so classifying it would describe a
        // value that never travels, and writing the return register
        // through that description would store the low bytes of an
        // address as if they were the value - a wrong answer that looks
        // like a right one.
        if (type.isRef)
            throw new Exception(
                text("ffi cannot call `", function_.toString,
                    "`: it returns by `ref`"),
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
        if (count > maxArguments)
            throw new Exception(
                text("ffi cannot call `", function_.toString, "`: it takes ",
                    count, " arguments, and at most ", maxArguments,
                    " are passed in registers"),
            );

        CallPlan plan;
        plan._hiddenReturnPointer = needsHiddenReturnPointer(type.nextOf);

        size_t registers;
        if (plan._hiddenReturnPointer)
            registers = 1;

        foreach (i; 0 .. count) {
            // A `ref` parameter occupies a pointer slot in the caller's
            // frame - the address of the argument's own storage, not a
            // copy of its value (see `FrameLayout.of` in
            // `interpreter/framelayout.d`, which lays such a slot out the
            // same way). `parameterList[i].type` is the *pointee* type,
            // so classifying by it describes a value that never travels:
            // `Register.of(int)` for `ref int` reads 4 bytes of an
            // address as if they were the value, and `ArgumentPlan.of` for
            // `ref int[]` reserves two registers and reads 8 bytes past
            // the single pointer slot the argument actually is. Refusing
            // here restores the same boundary `FrameLayout.of` used to
            // draw before it grew a real `ref` layout of its own.
            if (type.parameterList[i].storageClass & STC.ref_)
                throw new Exception(
                    text("ffi cannot call `", function_.toString,
                        "`: parameter ", i, " is `ref`"),
                );

            auto argument = ArgumentPlan.of(type.parameterList[i].type);
            registers += argument.count;
            if (registers > maxArguments)
                throw new Exception(
                    text("ffi cannot call `", function_.toString,
                        "`: its arguments need more than ", maxArguments,
                        " registers"),
                );

            plan._arguments[i] = argument;
        }

        auto name = mangleExact(function_);
        auto address = symbolAddress(name);
        if (address is null)
            throw new Exception(
                text("ffi cannot resolve the symbol `", name.fromStringz,
                    "` declared by `", function_.toString,
                    "`: it is not in this process"),
            );

        plan._address = address;
        plan._parameterCount = count;
        if (!plan._hiddenReturnPointer)
            plan._return = Register.of(type.nextOf);

        return plan;
    }
}
