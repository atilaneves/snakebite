module snakebite.ffi.call;


private:

import snakebite.nativelayout: typeFacts;



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
    import dmd.func: FuncDeclaration;
    import dmd.mtype: TypeFunction;
    import snakebite.nativelayout: TypeFacts;

    private bool _referenceResult;
    private size_t _resultSize;
    private bool _isVoid;
    private bool _resultIsReceiver;
    private TypeFacts _returnFacts;

    public struct Argument {
        import dmd.mtype: Parameter;

        private bool _reference;

        public static Argument of(
            Parameter parameter,
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
        private size_t _destination = size_t.max;

        // `destination` is a declared parameter that the callee takes by
        // address though its declaration says by value (`snakebite.
        // backends.calls.CallSelection.Decision.destinationParameter`).
        public static Arguments of(
            TypeFunction type, Expressions* expressions,
            in size_t destination = size_t.max,
        ) {
            Arguments result;
            result._destination = destination;
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

        public const(CallPlan)* prepareAtAddress(
            ref PlanCache plans, const(void)* address, bool hasContext,
        ) {
            import dmd.astenums: VarArg;
            import dmd.mtype: Type;

            if (_type.parameterList.varargs != VarArg.variadic)
                return null;

            Type[] extraTypes;
            foreach (expression; _expressions[extraOffset .. $])
                extraTypes ~= expression.type;
            return plans.variadicAtAddress(
                _type, hasContext, address, extraTypes);
        }

        public struct Value {
            public Expression expression;
            public TypeFacts facts;
            public bool isReference;
            public bool readsField;
            public size_t fieldOffset;
            public TypeFacts fieldFacts;
        }

        public struct Declared {
            public Expression expression;
            public Type parameterType;
            public Type evaluationType;
            public bool isReference;
            public bool isLazy;

            public void store(
                void* place,
                scope void* delegate() address,
                scope void delegate(void*) evaluate,
            ) const {
                Argument(isReference).store(place, address, evaluate);
            }
        }

        // Guest calls reuse cached frame facts. Keeping type layout out of
        // this traversal avoids frontend layout work on each interpreter call.
        public void eachDeclared(
            scope void delegate(size_t, Declared) emit,
        ) {
            import std.algorithm: min;

            const bound = _expressions.length - _declaredOffset;
            foreach (i; 0 .. min(_type.parameterList.length, bound))
                emit(i, declaredValue(i));
        }

        public void each(scope void delegate(Value) emit) {
            if (_declaredOffset)
                emit(hiddenArgument);
            foreach (i; 0 .. _type.parameterList.length) {
                auto declared = declaredValue(i); // Frontend types remain mutable.
                const facts = declared.isReference ? TypeFacts.pointer
                    : declared.isLazy
                        ? TypeFacts.lazyArgument
                        : typeFacts(declared.parameterType);
                emit(Value(
                    declared.expression, facts, declared.isReference,
                ));
            }
            foreach (expression; _expressions[extraOffset .. $])
                emit(Value(expression, typeFacts(expression.type)));
        }

        // The order a native callee takes already-evaluated arguments in,
        // the order `each` emits them: a D variadic's hidden `TypeInfo`
        // tuple, the declared arguments, then the extra ones.
        public T[] nativeOrder(T)(T hidden, T[] declared, T[] extras) const {
            return (_declaredOffset ? [hidden] : []) ~ declared ~ extras;
        }

        public void eachExtra(scope void delegate(Value) emit) {
            foreach (expression; _expressions[extraOffset .. $])
                emit(Value(expression, typeFacts(expression.type)));
        }

        private Declared declaredValue(in size_t i) {
            import dmd.astenums: STC;

            auto parameter = _type.parameterList[i]; // Frontend types remain mutable.
            const reference = Argument.of(parameter).isReference
                || i == _destination;
            const isLazy = (parameter.storageClass & STC.lazy_) != 0;
            auto parameterType = parameter.type; // Frontend types remain mutable.
            auto evaluationType = isLazy // Frontend types remain mutable.
                ? _expressions[_declaredOffset + i].type
                : parameterType;
            return Declared(
                i == _destination
                    ? memoryOperand(_expressions[_declaredOffset + i])
                    : _expressions[_declaredOffset + i],
                parameterType, evaluationType, reference, isLazy,
            );
        }

        // The semantic pass converts a vector operand to the declared vector
        // type of the parameter (`void16`) with a cast that reinterprets the
        // same bytes, and the cast of a memory operand is no memory. dmd's
        // code generator does not see that cast either.
        private static Expression memoryOperand(Expression expression) {
            import dmd.expression: CastExp;
            import dmd.astenums: TY;
            import dmd.typesem: toBasetype;

            while (true) {
                auto cast_ = expression.isCastExp;
                if (cast_ is null
                        || cast_.type.toBasetype.ty != TY.Tvector
                        || cast_.e1.type.toBasetype.ty != TY.Tvector)
                    return expression;
                expression = cast_.e1;
            }
        }

        public Value hiddenArgument() {
            import snakebite.ffi.abi: dVariadicArgumentsIsSlice;

            auto expression = _expressions[0];
            auto value = Value(expression, typeFacts(expression.type));
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
                    _expressions[i], typeFacts(_expressions[i].type),
                ));
            return arguments;
        }
    }

    public static CallAdapter of(
        FuncDeclaration function_,
    ) {
        // dmd's function-type accessors are mutable, even for a read-only
        // declaration query.
        auto type = function_.type.isTypeFunction;
        assert(type !is null);

        return ofType(type);
    }

    // As `of`, from a bare `TypeFunction` rather than a declaration - the
    // shape a call through a function pointer or a delegate value returns
    // into, since there is no `FuncDeclaration` at that call site to read
    // a result adapter from otherwise.
    public static CallAdapter ofType(
        TypeFunction type,
    ) {
        import dmd.astenums: Tvoid;
        import dmd.typesem: nextOf;

        CallAdapter adapter;
        adapter._referenceResult = type.isRef;

        auto returnType = type.nextOf;
        adapter._resultIsReceiver = type.isCtor;
        adapter._isVoid = type.isCtor
            || returnType is null || returnType.ty == Tvoid;

        if (adapter._referenceResult) {
            assert(returnType !is null);
            adapter._resultSize = typeFacts(returnType).size;
            adapter._returnFacts = TypeFacts.pointer;
        } else if (!adapter._isVoid) {
            adapter._returnFacts = typeFacts(returnType);
        }

        return adapter;
    }

    // Whether the call's value is the receiver the constructor was handed,
    // for a struct and for a class. dmd's glue layer makes it the value of a
    // call to a constructor with C++ linkage, because the Itanium ABI makes
    // such a constructor return `void` (`glue/e2ir.d`, `isCPPCtor`). A
    // constructor with D linkage returns its receiver itself, so the same
    // value holds there. Whatever a callee leaves in the return register is
    // not that value; the executor of the call supplies the receiver.
    public bool resultIsReceiver() const {
        return _resultIsReceiver;
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
        void* receiver,
        scope const(void*)[] arguments,
        scope CallInvoker invoke,
    ) const {
        if (!_referenceResult) {
            invoke(returnPlace, arguments);
            if (_resultIsReceiver && returnPlace !is null)
                storeReference(returnPlace, receiver);
            return CallResult.init;
        }

        align(size_t.sizeof) ubyte[size_t.sizeof] addressPlace = void;
        invoke(addressPlace.ptr, arguments);
        if (_resultIsReceiver)
            storeReference(addressPlace.ptr, receiver);

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
