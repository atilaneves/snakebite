module snakebite.ffi.call;


private:


import core.stdc.string: memcpy;


// A ref result must stay available as an address for lvalue use while its
// value bytes are copied into the caller's result place.
public struct CallResult {
    private void* _address;
    private size_t _size;

    public void* address() const {
        if (_address is null)
            throw new Exception("ffi call result is not a reference");

        return cast(void*) _address;
    }

    public void copyValue(void* destination) const {
        if (_address !is null && destination !is null)
            memcpy(destination, _address, _size);
    }
}


public alias CallInvoker = void delegate(
    scope void*,
    scope const(void*)[],
);


// DMD declarations are mutable graph objects, so their call facts are read
// once while a function's frame layout is prepared. Calls then cross this
// seam using only the native-layout facts kept here.
public struct CallAdapter {
    import snakebite.nativelayout: TypeFacts;

    private bool _referenceResult;
    private size_t _resultSize;
    private bool _isVoid;
    private TypeFacts _returnFacts;

    public struct Argument {
        private bool _reference;

        public static Argument of(
            imported!"dmd.mtype".Parameter parameter,
        ) {
            import dmd.astenums: STC;

            return Argument(
                (parameter.storageClass & (STC.ref_ | STC.out_)) != 0,
            );
        }

        // Whether this argument is passed by address rather than by value -
        // a `ref`/`out` parameter's own frame slot holds the argument's
        // address, never a copy of its value. A backend that only needs
        // this one fact, without also wanting `store`'s own guest
        // operations, reads it directly.
        public bool isReference() const {
            return _reference;
        }

        // A ref parameter needs the guest lvalue's address; other parameters
        // need its value. The caller supplies both guest operations so the
        // distinction stays inside this package.
        pragma(inline, true) public void store(
            void* place,
            scope void* delegate() address,
            scope void delegate(void*) evaluate,
        ) const {
            if (_reference)
                storeReference(place, address());
            else
                evaluate(place);
        }
    }

    // Both backends consume the same call-site facts, but one can reuse
    // declared argument storage while the other must emit every argument.
    public struct Arguments {
        import dmd.arraytypes: Expressions;
        import dmd.expression: Expression;
        import dmd.func: FuncDeclaration;
        import dmd.mtype: Type, TypeFunction;
        import snakebite.callarguments: CallArguments;
        import snakebite.ffi.plan: CallPlan, PlanCache;

        private TypeFunction _type;
        private Expression[] _expressions;
        private size_t _declaredOffset;

        public static Arguments of(
            TypeFunction type, Expressions* expressions,
        ) {
            Arguments result;
            result._type = type;
            result._expressions = expressions is null ? null : (*expressions)[];
            result._declaredOffset = type.isDstyleVariadic ? 1 : 0;
            return result;
        }

        public Expression[] declared() {
            return _expressions[_declaredOffset .. extraOffset];
        }

        private size_t extraOffset() {
            return _declaredOffset + _type.parameterList.length;
        }

        // Called only when the backend has no plan for this call site.
        // A repeated interpreter call must not rebuild the extra-type list.
        public const(CallPlan)* prepare(
            ref PlanCache plans, FuncDeclaration callee,
        ) {
            import dmd.astenums: VarArg;

            if (_type.parameterList.varargs != VarArg.variadic)
                return plans.of(callee);

            Type[] extraTypes;
            foreach (expression; _expressions[extraOffset .. $])
                extraTypes ~= expression.type;
            return plans.variadicOf(callee, extraTypes);
        }

        public struct Value {
            public Expression expression;
            public TypeFacts facts;
            public bool isReference;
            public bool readsField;
            public size_t fieldOffset;
            public TypeFacts fieldFacts;
        }

        public void each(scope void delegate(Value) emit) {
            if (_declaredOffset)
                emit(hiddenArgument);
            foreach (i, expression; declared) {
                import dmd.astenums: STC;

                auto parameter = _type.parameterList[i];
                const reference = Argument.of(parameter).isReference;
                const facts = reference ? TypeFacts.pointer
                    : parameter.storageClass & STC.lazy_
                        ? TypeFacts.lazyArgument : TypeFacts.of(parameter.type);
                emit(Value(expression, facts, reference));
            }
            foreach (expression; _expressions[extraOffset .. $])
                emit(Value(expression, TypeFacts.of(expression.type)));
        }

        private Value hiddenArgument() {
            import snakebite.ffi.abi: dVariadicArgumentsIsSlice;

            auto expression = _expressions[0];
            auto value = Value(expression, TypeFacts.of(expression.type));
            // The host compiler can require a field read after evaluation.
            if (dVariadicArgumentsIsSlice) {
                value.readsField = true;
                value.fieldOffset = TypeInfo_Tuple.elements.offsetof;
                value.fieldFacts = TypeFacts(
                    (TypeInfo[]).sizeof, (TypeInfo[]).alignof,
                );
            }
            return value;
        }

        // Declared arguments are already bound in the interpreter's frame.
        // Only hidden and extra arguments need fresh expression storage.
        public CallArguments bind(
            void* context,
            scope void* delegate(size_t) declaredAddress,
            scope void* delegate(Value) evaluate,
        ) {
            auto arguments = CallArguments(
                _expressions.length + (context !is null),
            );
            auto slots = arguments.values; // The address slots must stay mutable.
            size_t first;
            if (context !is null)
                slots[first++] = context;

            foreach (i; 0 .. _type.parameterList.length)
                slots[first + _declaredOffset + i] = declaredAddress(i);
            if (_declaredOffset)
                slots[first] = evaluate(hiddenArgument);
            foreach (i; extraOffset .. _expressions.length)
                slots[first + i] = evaluate(Value(
                    _expressions[i], TypeFacts.of(_expressions[i].type),
                ));
            return arguments;
        }
    }

    public static CallAdapter of(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        // dmd's function-type accessors are mutable, even for a read-only
        // declaration query.
        auto type = function_.type.isTypeFunction;
        assert(type !is null);

        return ofType(type, function_.isCtorDeclaration !is null);
    }

    // As `of`, from a bare `TypeFunction` rather than a declaration - the
    // shape a call through a function pointer or a delegate value returns
    // into, since there is no `FuncDeclaration` at that call site to read
    // a result adapter from otherwise. `isVoidResult` covers a constructor,
    // whose `TypeFunction` is `void` already, and any other callee dmd's
    // own semantics already treat as returning nothing regardless of its
    // declared return type.
    public static CallAdapter ofType(
        imported!"dmd.mtype".TypeFunction type,
        in bool isVoidResult = false,
    ) {
        import dmd.astenums: Tvoid;
        import dmd.typesem: nextOf;

        CallAdapter adapter;
        adapter._referenceResult = type.isRef;

        auto returnType = type.nextOf;
        adapter._isVoid = isVoidResult
            || returnType is null || returnType.ty == Tvoid;

        if (adapter._referenceResult) {
            assert(returnType !is null);
            adapter._resultSize = TypeFacts.of(returnType).size;
            adapter._returnFacts = TypeFacts.pointer;
        } else if (!adapter._isVoid) {
            adapter._returnFacts = TypeFacts.of(returnType);
        }

        return adapter;
    }

    // Whether the callee returns nothing a caller can read back - `void`,
    // or a constructor, whose own "return" is the receiver it was handed
    // rather than a value in the return place at all.
    public bool isVoid() const {
        return _isVoid;
    }

    // Whether the return place holds the result's own bytes or the address
    // of storage holding them.
    public bool isReferenceResult() const {
        return _referenceResult;
    }

    // The facts of whatever the return place actually holds: a pointer's,
    // for a `ref` return; the declared return type's, for a value one; and
    // `TypeFacts.init` for a void callee, which reserves no return place at
    // all.
    public TypeFacts returnFacts() const {
        return _returnFacts;
    }

    // A host backend promises a value-sized return place, so it cannot accept
    // a reference result as its direct return value.
    public void rejectHostReferenceReturn(
        imported!"dmd.func".FuncDeclaration function_,
    ) const {
        import snakebite.exception: SnakebiteException;
        import std.conv: text;

        if (_referenceResult)
            throw new SnakebiteException(
                text("interpreter cannot call `", function_.toString,
                    "` from the host: it returns by `ref`"),
            );
    }

    // A ref return exposes a guest lvalue, while a value return exposes bytes.
    // The caller supplies both guest operations so the distinction stays
    // inside this package.
    pragma(inline, true) public void returnFromCall(
        void* place,
        scope void* delegate() address,
        scope void delegate() evaluate,
    ) const {
        if (_referenceResult) {
            storeReference(place, address());
            return;
        }

        evaluate();
    }

    // A reference result must remain an lvalue while its current value also
    // reaches an ordinary expression's return place.
    pragma(inline, true) public CallResult invoke(
        void* returnPlace,
        scope const(void*)[] arguments,
        scope CallInvoker invoke,
    ) const {
        if (!_referenceResult) {
            invoke(returnPlace, arguments);
            return CallResult.init;
        }

        align(size_t.sizeof) ubyte[size_t.sizeof] addressPlace = void;
        invoke(addressPlace.ptr, arguments);

        // D makes a `const` local return as `const(CallResult)`, which does
        // not match this method's return type.
        auto result = CallResult(
            referenceAt(addressPlace.ptr),
            _resultSize,
        );
        result.copyValue(returnPlace);
        return result;
    }
}


// Keep the pointer-sized guest representation of a reference in one place,
// so interpreted and native calls use the same FFI seam.
pragma(inline, true) private void storeReference(
    void* place,
    void* address,
) {
    import snakebite.nativelayout: storeIntegral;

    storeIntegral(place, cast(size_t) address, size_t.sizeof);
}


private void* referenceAt(const(void)* place) {
    import snakebite.nativelayout: loadIntegral;

    return cast(void*) loadIntegral(place, size_t.sizeof, false);
}
