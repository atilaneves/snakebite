module snakebite.backends.calls;


private:


// Delegate values use native callback entries, so captured guest contexts
// do not change whether the receiving function executes as guest or host.
public struct CallSelection {
    // Holds a `SharedTable` (finding 2.4): a copy would share its
    // storage with the original until one side grows.
    @disable this(this);

    import dmd.func: FuncDeclaration;

    import snakebite.backends.builtins:
        BuiltinCall, ParameterType, startVariadicEntry;
    import snakebite.sharedtable: SharedTable;

    // Every call site resolves to exactly one of these. `guest` and
    // `native` are the two routes `usesGuestBody` always answered;
    // `builtin` is the third one this backend adds for a bodiless
    // function that is a compiler intrinsic (`buildIntrinsicPlan`) -
    // `core.math.fabs` and friends, which have no host symbol FFI could
    // ever resolve (they compile to an inline instruction, not a call). `snakebite.backends.builtins` holds the
    // wrapper `builtinEntry` calls for that route.
    //
    // `vaStart` is the one intrinsic that is not a pure function of its
    // arguments: it also reads the cursor of the function that calls it,
    // so each backend appends that cursor to the call's arguments.
    // `alloca` is the other: its memory lives as long as the activation
    // that calls it, which only the backend knows how to hold.
    public enum Route { guest, native, builtin, vaStart, alloca }

    // The dmd-touching questions a function's route needs, decided once
    // per function and read back without a lock (ADR-0006, finding
    // 1.2): whether a C-style variadic call must always go native,
    // whether the function nests inside another (so it needs this
    // backend's own static chain), the same-declaration preference
    // every call falls back to otherwise, and - for a bodiless
    // function - whether it is a compiler intrinsic, and its wrapper. `route` and `builtinEntry` together,
    // rather than two separate lookups, so a builtin call site - the
    // interpreter's hot path included - reads this cache once per call,
    // not twice.
    public struct Decision {
        public Route route;
        public BuiltinCall builtinEntry;
        // For `builtin`: the declared parameter that the wrapper takes by
        // address (`snakebite.backends.builtins.destinationParameterOf`).
        public size_t destinationParameter = size_t.max;
    }

    // e2ir substitutes an intrinsic only for an OPvar callee, not an
    // expression that computes that callee (notably a comma prefix).
    public static bool hasIntrinsicCallee(
        imported!"dmd.expression".CallExp expression,
    ) {
        auto callee = expression.e1;
        if (auto variable = callee.isVarExp)
            return variable.var.isFuncDeclaration !is null;
        return false;
    }

    public static Decision atCallSite(
        in Decision decision, imported!"dmd.expression".Expression site,
    ) {
        auto call = site is null ? null : site.isCallExp;
        return call !is null && !hasIntrinsicCallee(call)
                && (decision.route == Route.builtin || decision.route == Route.vaStart)
            ? Decision(Route.native) : decision;
    }

    public static void eachResolvedCalleePrefix(
        imported!"dmd.expression".CallExp expression,
        scope void delegate(imported!"dmd.expression".Expression) execute,
    ) {
        // Indirect calls evaluate their complete callee value themselves.
        if (expression.f is null)
            return;
        auto callee = expression.e1;
        while (auto comma = callee.isCommaExp) {
            execute(comma.e1);
            callee = comma.e2;
        }
    }

    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a decision is built once per function.
    private SharedTable!(FuncDeclaration, Decision) _decisions;

    // Routing and constant proofs use the same finished signature. A prepared
    // callback must not walk frontend ownership again, even for a nonconstant
    // operand or a declaration that has no matching wrapper.
    private struct IntrinsicPlan {
        Decision call = Decision(Route.native);
        const(ParameterType)[] parameters;
        ParameterType result;
    }

    private SharedTable!(FuncDeclaration, IntrinsicPlan) _intrinsics;

    public void prepareIntrinsic(FuncDeclaration function_) {
        if (function_.fbody is null)
            intrinsicPlanOf(function_);
    }

    private IntrinsicPlan intrinsicPlanOf(FuncDeclaration function_) {
        import snakebite.frontend.compiler: withCompilerQuery;
        import snakebite.frontend.dmd.functions: moduleOf;

        if (auto cached = function_ in _intrinsics)
            return *cached;

        version(unittest) {
            import snakebite.sharedtable: assertCacheFillAllowed;
            assertCacheFillAllowed!"intrinsic classification";
        }
        IntrinsicPlan plan;
        withCompilerQuery({
            plan = buildIntrinsicPlan(function_, moduleOf(function_));
        });
        return *_intrinsics.insert(function_, plan);
    }

    // Read without a lock, like `_decisions`; see `definitionOf`.
    private SharedTable!(FuncDeclaration, FuncDeclaration) _definitions;

    // Whether any declaration can have a definition to link to. Set once,
    // from the program, before the first call.
    public bool linksFunctions;

    // The function that a call to `function_` runs. A declaration with no
    // body is the definition that the linker finds for it (see
    // `snakebite.frontend.dmd.linking`), and that is worked out once for
    // each declaration, at its first call or when its call is compiled. A
    // function with a body is its own definition, with no lookup.
    public FuncDeclaration definitionOf(
        FuncDeclaration function_,
        scope FuncDeclaration delegate(FuncDeclaration) link,
    ) {
        if (!linksFunctions || function_.fbody !is null)
            return function_;

        if (auto cached = function_ in _definitions)
            return *cached;

        return *_definitions.insert(function_, link(function_));
    }

    // `function_`'s full routing decision. The one call every hot path
    // wants: a single cache lookup carries both the route and, for
    // `builtin`, the wrapper to call - `usesGuestBody` below is the one
    // narrower, route-only caller still reaches for.
    //
    // Cache hits do not enter the frontend. A cold decision snapshots its
    // parent-chain facts under the frontend lock: another module's semantic
    // pass can change a shared package parent after this callee is complete.
    public Decision decisionOf(
        FuncDeclaration function_,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
    ) {
        if (auto cached = function_ in _decisions)
            return *cached;

        return *_decisions.insert(
            function_,
            buildDecision(
                function_, hasNativeSymbol, hasIndependentNativeSymbol,
                isGuest,
            ),
        );
    }

    // Whether `function_`'s own body should interpret/compile - the one
    // question every caller that never needs a builtin's wrapper (only
    // `callableAddress`, in both backends, taking a function's address as
    // a value) still asks. A caller that also wants the builtin wrapper
    // itself should read `decisionOf` directly instead of calling this
    // and `decisionOf` both, which would pay the cache lookup twice.
    public bool usesGuestBody(
        FuncDeclaration function_,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
    ) {
        return decisionOf(
            function_, isGuest, hasNativeSymbol, hasIndependentNativeSymbol,
        ).route == Route.guest;
    }

    // Runs the lowered call of a static initialiser (an associative array
    // literal's `_d_assocarrayliteralTX!(K, V)`) the way an ordinary call to
    // it runs: that template instance has machine code only when druntime
    // instantiated it over the same types, so otherwise it is guest code.
    // The routes `builtin`, `vaStart` and `alloca` never apply to such a
    // lowering, so they take the plan with `native`.
    public void callLowering(
        FuncDeclaration function_,
        void* returnPlace,
        scope void*[] arguments,
        scope bool delegate(FuncDeclaration) isGuest,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
        scope void delegate(FuncDeclaration, void*, void*[]) callGuest,
        scope void delegate(FuncDeclaration, void*, scope const(void*)[])
            callPlan,
    ) {
        if (usesGuestBody(function_, isGuest, hasNativeSymbol,
                hasIndependentNativeSymbol))
            callGuest(function_, returnPlace, arguments);
        else
            callPlan(function_, returnPlace, arguments);
    }

    // A host variadic function pointer must keep its host address. Its
    // call plan depends on the extra argument types at each call site.
    public bool usesNativeVariadicAddress(
        FuncDeclaration function_, bool hasNativeSymbol,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        return hasNativeSymbol
            && typeFunctionOf(function_).parameterList.varargs
                == VarArg.variadic;
    }

    // A guest D variadic method called without a receiver adjustment is
    // stored as its guest word. Its call plan depends on the extra
    // arguments at each call site, so no entry stands in for it. With an
    // adjustment the vtable slot still needs an entry to carry the offset.
    public bool storesGuestWord(
        FuncDeclaration function_, bool hasNativeSymbol,
        in ptrdiff_t adjustment,
    ) {
        return adjustment == 0 && isVariadicGuest(function_, hasNativeSymbol);
    }

    public bool isVariadicGuest(
        FuncDeclaration function_, bool hasNativeSymbol,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        return typeFunctionOf(function_).parameterList.varargs
                == VarArg.variadic
            && function_.fbody !is null && !hasNativeSymbol;
    }

    // Guest execution and symbol resolution are outside the parent snapshot.
    private Decision buildDecision(
        FuncDeclaration function_,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
        scope bool delegate(FuncDeclaration) isGuest,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions:
            bodyIsSelected, contextOf, typeFunctionOf;

        const context = contextOf(function_);

        // A declaration without a body can only describe a native call or
        // a builtin - never a guest one, since there is no guest body to
        // run.
        if (function_.fbody is null)
            return isVaStart(function_, context)
                ? Decision(Route.vaStart, &startVariadicEntry)
                : isAlloca(function_) ? Decision(Route.alloca)
                : intrinsicPlanOf(function_).call;

        const rootOwned = isGuest(function_);
        if (!bodyIsSelected(context.module_, rootOwned))
            return Decision(Route.native);

        const type = typeFunctionOf(function_);
        if (type.parameterList.varargs == VarArg.variadic && hasNativeSymbol)
            return Decision(Route.native);

        // This includes siblings and deeper nested callees: every static
        // chain points into frames whose offsets belong to this backend.
        if (context.outerFunction !is null)
            return Decision(Route.guest);

        // A function literal in an imported aggregate has a body but no
        // native symbol of its own. Keep it guest when it is root-owned or
        // when the linker cannot resolve that symbol.
        if (function_.isFuncLiteralDeclaration !is null
                && function_.fbody !is null
                && (rootOwned || !hasNativeSymbol))
            return Decision(Route.guest);

        // The host compiler's druntime implements `va_copy` as an
        // intrinsic, so the process has no symbol for it, but the frontend's
        // druntime gives it a body.
        if (isVaCopy(function_, context))
            return Decision(Route.guest);

        // A root-owned body must run as guest even when its linker name
        // is in the host (notably _Dmain). A template instance can reuse
        // a native copy only when that copy is independent of the running
        // executable - the dependency image or an already-loaded shared
        // object (ADR-0008, ADR-0009). The executable's own copy is never
        // preferred: snakebite instantiates plenty of the same templates a
        // guest program also instantiates (`dirEntries` in
        // `snakebite.project` among them), and that copy's nested closures
        // carry the host compiler's frame layout, not this backend's -
        // reusing it for a guest call reads that closure with the wrong
        // layout. A missing independent symbol leaves the guest body.
        // An ordinary dependency uses its own frontend body when its exact
        // native symbol is absent (ADR-0009, decision 3).
        const prefers = context.instantiated
            ? !hasIndependentNativeSymbol
            : rootOwned || !hasNativeSymbol;
        return Decision(prefers ? Route.guest : Route.native);
    }

    // The test dmd's own glue applies (`dmd.glue.toir.intrinsic_op`) to
    // find `core.stdc.stdarg.va_start`, which `dmd.builtin` does not
    // classify: a template instance named `va_start` in that module.
    private static bool isVaStart(FuncDeclaration function_,
        in imported!"snakebite.frontend.dmd.functions".FunctionContext context,
    ) {
        const module_ = context.module_;
        return function_.ident.toString == "va_start"
            && context.templateParent
            && module_ !is null && module_.md !is null
            && module_.md.toString == "core.stdc.stdarg";
    }

    private static bool isVaCopy(FuncDeclaration function_,
        in imported!"snakebite.frontend.dmd.functions".FunctionContext context,
    ) {
        const module_ = context.module_;
        return function_.ident.toString == "va_copy"
            && !context.templateParent
            && module_ !is null && module_.md !is null
            && module_.md.toString == "core.stdc.stdarg";
    }

    // dmd's backend turns a call to the function with the symbol `alloca`
    // into stack allocation (`dmd.backend.x86.cod1`, by symbol name), not
    // one with the identifier: `pragma(mangle)` can make them differ.
    private static bool isAlloca(FuncDeclaration function_) {
        import snakebite.frontend.dmd.mangle: mangledNameOf;

        return function_.mangledNameOf == "alloca";
    }

    // `function_`'s wrapper, when it is a bodiless declaration that dmd's
    // code generator inlines instead of calling (`isInlinedByCodeGenerator`)
    // and a wrapper takes exactly its signature. No host symbol exists for
    // an inlined declaration, and any other bodiless declaration is a
    // native call: the host's own symbol, or dmd's link error without one.
    //
    // dmd's `dmd.builtin.isBuiltin` is no part of this decision: it
    // classifies names for CTFE, some of which the code generator does not
    // inline, and this backend never calls the CTFE evaluator at run time.
    //
    // A declaration that dmd inlines and no wrapper takes is a native call
    // too: a wrapper reads and writes at the sizes of its own signature, so
    // it never serves a declaration whose signature differs. dmd gives such
    // a declaration an unspecified result, or a raw SIMD instruction
    // (`__simd_ib`) that has no wrapper.
    private static IntrinsicPlan buildIntrinsicPlan(FuncDeclaration function_,
        in imported!"dmd.dmodule".Module module_,
    ) {
        import snakebite.backends.builtins:
            destinationParameterOf, entryOf;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        if (!isInlinedByCodeGenerator(function_, module_))
            return IntrinsicPlan.init;

        auto parameters = new ParameterType[
            typeFunctionOf(function_).parameterList.length];
        ParameterType result;
        const keyed = signatureOf(function_, parameters, result);
        // dmd's own `determine_builtin` keys on `fd.ident`, too (`dmd/
        // builtin.d`): the identifier is the table's key, not the symbol.
        const name = function_.ident.toString.idup;
        auto entry = keyed ? entryOf(name, parameters, result) : null;
        return entry is null
            ? IntrinsicPlan.init
            : IntrinsicPlan(
                Decision(Route.builtin, entry, destinationParameterOf(name)),
                parameters, result,
            );
    }

    public bool foldedScalarIntrinsic(
        imported!"dmd.expression".CallExp expression,
        out ScalarConstant constant,
    ) {
        import core.stdc.fenv;
        import dmd.ctfeexpr: emplaceExp;
        import dmd.expression: IntegerExp;

        ulong value;
        if (foldedIntegerIntrinsic(expression, value)) {
            emplaceExp!IntegerExp(&constant.value, expression.loc, value, expression.type);
            return true;
        }
        fenv_t environment;
        if (feholdexcept(&environment) != 0)
            return false;
        scope(exit) fesetenv(&environment);
        fesetround(FE_TONEAREST);
        return foldedFloatingIntrinsic(expression, constant)
            && fetestexcept(FE_ALL_EXCEPT) == 0;
    }

    // Backend constants can have a nonnumeric result view. RealExp alone
    // cannot carry a signaling NaN through a narrower native store.
    public struct ScalarConstant {
        private imported!"dmd.ctfeexpr".UnionExp value;
        private imported!"dmd.backend.cdef".Vconst storage;
        private ParameterType representation;
        public bool hasStorage;

        public const(void)[] bytes(in size_t width) return {
            assert(hasStorage && width <= storage.sizeof);
            return (cast(const(void)*) &storage)[0 .. width];
        }

        public imported!"dmd.expression".Expression expression() {
            assert(!hasStorage);
            return value.exp;
        }

        private imported!"dmd.expression".Expression exp() {
            if (hasStorage) {
                auto floating = value.exp.isRealExp;
                final switch (representation) with (ParameterType) {
                    case float_: floating.value = storage.Vfloat; break;
                    case double_: floating.value = storage.Vdouble; break;
                    case real_: floating.value = storage.Vreal; break;
                    case ubyte_, ushort_, short_, int_, uint_, long_, ulong_,
                            vector_, pointer_, void_: assert(0);
                }
            }
            return value.exp;
        }
    }

    // DMD's backend constant folder (`evalu8`, OPbswap) uses the operand
    // width; `cdbswap` uses the result width for a nonconstant operand.
    // The call site must keep that distinction before argument evaluation.
    private bool foldedIntegerIntrinsic(
        imported!"dmd.expression".CallExp expression, out ulong value,
    ) {
        import core.bitop: popcnt;
        import core.stdc.fenv;
        import snakebite.backends.dmdintrinsics: swapTo;
        import snakebite.nativelayout: TypeFacts;

        auto function_ = expression.f;
        if (function_ is null || function_.fbody !is null
                || !hasIntrinsicCallee(expression)
                || expression.arguments is null
                || expression.arguments.length != 1)
            return false;
        const identifier = function_.ident.toString;
        if (identifier != "bswap" && identifier != "_popcnt")
            return false;
        const name = identifier == "bswap" ? "bswap" : "_popcnt";
        auto operand = (*expression.arguments)[0];
        const plan = intrinsicPlanOf(function_);
        if (plan.call.route != Route.builtin || plan.parameters.length != 1)
            return false;

        // Native compilation uses its own FP environment. A proof must
        // neither depend on nor change the guest's rounding or flags.
        fenv_t environment;
        if (feholdexcept(&environment) != 0)
            return false;
        scope(exit) fesetenv(&environment);
        fesetround(FE_TONEAREST);
        ulong bits;
        if (!integerConstantOf(operand, bits))
            return false;

        switch (TypeFacts.of(operand.type).size) {
            case 2:
                value = name == "bswap" ? swapTo!ushort(bits)
                    : popcnt(cast(ushort) bits); break;
            case 4:
                value = name == "bswap" ? swapTo!uint(bits)
                    : popcnt(cast(uint) bits); break;
            case 8:
                value = name == "bswap" ? swapTo!ulong(bits)
                    : popcnt(bits); break;
            default: return false;
        }
        return true;
    }

    private bool integerConstantOf(
        imported!"dmd.expression".Expression expression, out ulong value,
    ) {
        import dmd.expressionsem: toInteger;
        ScalarConstant constant;
        if (!scalarConstantOf(expression, constant)
                || constant.exp.isIntegerExp is null)
            return false;
        value = constant.exp.toInteger;
        return true;
    }

    // evalu8's scalar producers, after e2ir's intrinsic substitution:
    // numeric leaves, arithmetic, comparisons, conversions and selection.
    // Use DMD's allocation-free constant operations on private UnionExps;
    // optimize() also expands declarations and allocates frontend objects.
    private bool scalarConstantOf(
        imported!"dmd.expression".Expression expression,
        out ScalarConstant constant,
    ) {
        import dmd.constfold;
        import dmd.ctfeexpr: emplaceExp;
        import dmd.expression: IntegerExp, RealExp;
        import dmd.expressionsem: toBool, toInteger;
        import dmd.typesem: toBasetype, isIntegral, isReal, isUnsigned, size;
        import dmd.tokens: EXP;
        import core.stdc.fenv;

        auto type = expression.type.toBasetype;
        if (!type.isIntegral && !type.isReal)
            return false;
        if (expression.isIntegerExp !is null || expression.isRealExp !is null) {
            emplaceExp(&constant.value, expression);
            normalizeScalar(constant, expression.type);
            // Literal storage happens before evalu8 clears exception flags.
            feclearexcept(FE_ALL_EXCEPT);
            return true;
        } else if (auto call = expression.isCallExp) {
            ulong value;
            if (foldedIntegerIntrinsic(call, value)) {
                emplaceExp!IntegerExp(&constant.value, call.loc, value, call.type);
            } else if (!foldedFloatingIntrinsic(call, constant))
                return false;
        } else if (auto conditional = expression.isCondExp) {
            ScalarConstant condition;
            if (!scalarConstantOf(conditional.econd, condition))
                return false;
            const truth = condition.exp.toBool.get;
            if (fetestexcept(FE_ALL_EXCEPT)
                    || !scalarConstantOf(truth
                        ? conditional.e1 : conditional.e2, constant))
                return false;
        } else if (auto binary = expression.isBinExp) {
            ScalarConstant left, right;
            if (!scalarConstantOf(binary.e1, left))
                return false;
            if (binary.isLogicalExp !is null) {
                const truth = left.exp.toBool.get;
                if (fetestexcept(FE_ALL_EXCEPT))
                    return false;
                if (truth == (binary.op == EXP.orOr)) {
                    emplaceExp!IntegerExp(&constant.value, binary.loc, truth, binary.type);
                    return true;
                }
            }
            if (!scalarConstantOf(binary.e2, right))
                return false;
            if ((binary.op == EXP.div || binary.op == EXP.mod)
                    && type.isIntegral) {
                const numerator = left.exp.toInteger;
                const denominator = right.exp.toInteger;
                const minimum = type.size == 8 ? long.min : int.min;
                // Do not diagnose a fault while selecting an unexecuted call.
                if (denominator == 0 || (!type.isUnsigned && numerator == minimum
                        && denominator == -1))
                    return false;
            }
            auto e1 = left.exp;
            auto e2 = right.exp;
            const loc = expression.loc;
            auto resultType = expression.type;
            feclearexcept(FE_ALL_EXCEPT);
            switch (expression.op) with (EXP) {
                case add: constant.value = Add(loc, resultType, e1, e2); break;
                case min: constant.value = Min(loc, resultType, e1, e2); break;
                case mul: constant.value = Mul(loc, resultType, e1, e2); break;
                case div: constant.value = Div(loc, resultType, e1, e2); break;
                case mod: constant.value = Mod(loc, resultType, e1, e2); break;
                case leftShift: constant.value = Shl(loc, resultType, e1, e2); break;
                case rightShift: constant.value = Shr(loc, resultType, e1, e2); break;
                case unsignedRightShift: constant.value = Ushr(loc, resultType, e1, e2); break;
                case and: constant.value = And(loc, resultType, e1, e2); break;
                case or: constant.value = Or(loc, resultType, e1, e2); break;
                case xor: constant.value = Xor(loc, resultType, e1, e2); break;
                case equal, notEqual:
                    constant.value = Equal(expression.op, loc, resultType, e1, e2); break;
                case identity, notIdentity:
                    constant.value = Identity(expression.op, loc, resultType, e1, e2); break;
                case lessThan, lessOrEqual, greaterThan, greaterOrEqual:
                    constant.value = Cmp(expression.op, loc, resultType, e1, e2); break;
                case andAnd, orOr:
                    emplaceExp!IntegerExp(&constant.value, loc, e2.toBool.get, resultType);
                    break;
                case comma: constant = right; break;
                // Assignments, memory access, and library calls (PowExp)
                // are not scalar backend constant operations.
                default: return false;
            }
        } else if (auto unary = expression.isUnaExp) {
            ScalarConstant operand;
            if (!scalarConstantOf(unary.e1, operand))
                return false;
            if (operand.hasStorage && unary.op == EXP.negate) {
                constant = operand;
                applyFloatingSign(constant.storage, constant.representation,
                    FloatingSign.negate);
                return true;
            }
            if (auto cast_ = unary.isCastExp) {
                if (cast_.lowering !is null)
                    return false;
                if (operand.hasStorage && type.isReal) {
                    ParameterType result;
                    if (!parameterTypeOf(type, result))
                        return false;
                    constant = operand;
                    feclearexcept(FE_ALL_EXCEPT);
                    convertFloatingStorage(constant.storage,
                        constant.representation, result);
                    constant.representation = result;
                    constant.value.exp.type = expression.type;
                    return fetestexcept(FE_ALL_EXCEPT) == 0;
                }
            }
            auto e1 = operand.exp;
            feclearexcept(FE_ALL_EXCEPT);
            if (auto cast_ = unary.isCastExp) {
                if (cast_.lowering !is null)
                    return false;
                constant.value = Cast(unary.loc, unary.type, cast_.to, e1);
            } else switch (unary.op) with (EXP) {
                case negate: constant.value = Neg(unary.type, e1); break;
                case tilde: constant.value = Com(unary.type, e1); break;
                case not: constant.value = Not(unary.type, e1); break;
                default: return false;
            }
        } else
            return false;
        if (constant.value.exp.isIntegerExp is null && constant.value.exp.isRealExp is null)
            return false;
        normalizeScalar(constant, expression.type);
        return fetestexcept(FE_ALL_EXCEPT) == 0;
    }

    private static void normalizeScalar(
        ref ScalarConstant constant,
        imported!"dmd.mtype".Type type,
    ) {
        import core.volatile: volatileLoad;
        import dmd.backend.cdef: Vconst;
        import dmd.expressionsem: toInteger, toReal;
        import dmd.astenums: TY;
        import dmd.typesem: toBasetype;

        // Inner producers must be stored at their own width before use.
        constant.value.exp.type = type;
        if (constant.hasStorage)
            return;
        if (auto integer = constant.exp.isIntegerExp) {
            integer.value = integer.toInteger;
            return;
        }
        const base = type.toBasetype;
        auto floating = constant.exp.isRealExp;
        if (base.ty == TY.Tfloat32 || base.ty == TY.Tfloat64) {
            // An immediate cast followed by widening can keep excess x87
            // precision. Force the same memory stores as DMD's backend.
            Vconst stored;
            stored.Vdouble = cast(double) floating.toReal;
            stored.Vullong = volatileLoad(&stored.Vullong);
            if (base.ty == TY.Tfloat32) {
                stored.Vfloat = cast(float) stored.Vdouble;
                stored.Vuns = volatileLoad(&stored.Vuns);
                floating.value = stored.Vfloat;
            } else
                floating.value = stored.Vdouble;
        }
    }

    private bool foldedFloatingIntrinsic(
        imported!"dmd.expression".CallExp expression,
        out ScalarConstant constant,
    ) {
        import dmd.expression: RealExp;
        import dmd.ctfeexpr: emplaceExp;
        import dmd.expressionsem: toReal;
        import dmd.backend.cdef: Vconst;
        import core.stdc.fenv;
        import core.stdc.string: memcpy;
        import snakebite.backends.dmdintrinsics: magnitudeTo;
        import snakebite.nativelayout: TypeFacts;

        // e2ir replaces toPrec with conversions, and evalu8 folds OPabs.
        // The other floating intrinsic ops remain instructions.
        auto function_ = expression.f;
        if (function_ is null || function_.fbody !is null
                || !hasIntrinsicCallee(expression)
                || expression.arguments is null
                || expression.arguments.length != 1)
            return false;
        const identifier = function_.ident.toString;
        if (identifier != "fabs" && identifier != "toPrec")
            return false;
        const name = identifier == "fabs" ? "fabs" : "toPrec";
        const plan = intrinsicPlanOf(function_);
        if (plan.call.route != Route.builtin || plan.parameters.length != 1)
            return false;
        const parameters = plan.parameters;
        const result = plan.result;
        ScalarConstant operand;
        if (!scalarConstantOf((*expression.arguments)[0], operand)
                || operand.value.exp.isRealExp is null)
            return false;
        Vconst stored;
        stored.Vreal = 0;
        if (operand.hasStorage) {
            const width = TypeFacts.of((*expression.arguments)[0].type).size;
            memcpy(&stored, operand.bytes(width).ptr, width);
        } else {
            const value = operand.exp.toReal;
            final switch (parameters[0]) with (ParameterType) {
                case float_: stored.Vfloat = cast(float) value; break;
                case double_: stored.Vdouble = cast(double) value; break;
                case real_: stored.Vreal = value; break;
                case ubyte_, ushort_, short_, int_, uint_, long_, ulong_,
                        vector_, pointer_, void_: return false;
            }
        }
        // evalu8 clears flags after reading its operands, before OPabs.
        feclearexcept(FE_ALL_EXCEPT);
        if (name == "toPrec")
            convertFloatingStorage(stored, parameters[0], result);
        // The owner's exception replaces only stale child-pointer
        // float widening with DMD's emitted instructions. Cleared storage
        // already gives the zero-extended XMM double view.
        else if (parameters[0] == ParameterType.float_
                && result == ParameterType.real_)
            stored.Vreal = magnitudeTo!real(stored.Vfloat);
        else
            applyFloatingSign(stored, parameters[0], FloatingSign.magnitude);
        constant.storage = stored;
        constant.representation = result;
        constant.hasStorage = true;
        emplaceExp!RealExp(&constant.value, expression.loc, 0.0L, expression.type);
        return fetestexcept(FE_ALL_EXCEPT) == 0;
    }

    private enum FloatingSign { magnitude, negate }

    private static void applyFloatingSign(
        ref imported!"dmd.backend.cdef".Vconst storage,
        in ParameterType representation, in FloatingSign operation,
    ) {
        size_t signByte;
        final switch (representation) with (ParameterType) {
            case float_: signByte = float.sizeof - 1; break;
            case double_: signByte = double.sizeof - 1; break;
            case real_: signByte = real.mant_dig / 8 + 1; break;
            case ubyte_, ushort_, short_, int_, uint_, long_, ulong_,
                    vector_, pointer_, void_: assert(0);
        }
        auto bytes = cast(ubyte*) &storage;
        final switch (operation) with (FloatingSign) {
            case magnitude: bytes[signByte] &= 0x7f; break;
            case negate: bytes[signByte] ^= 0x80; break;
        }
    }

    // e2ir's floating conversion nodes read the native operand directly.
    // Widening a signaling NaN to a temporary real first would quiet it
    // before evalu8 checks the actual conversion's exception flags.
    private static void convertFloatingStorage(
        ref imported!"dmd.backend.cdef".Vconst storage,
        in ParameterType source, in ParameterType result,
    ) {
        import core.volatile: volatileLoad;

        final switch (source) with (ParameterType) {
            case float_:
                if (result != float_) {
                    storage.Vdouble = storage.Vfloat;
                    storage.Vullong = volatileLoad(&storage.Vullong);
                }
                break;
            case double_: break;
            case real_:
                if (result != real_) {
                    storage.Vdouble = cast(double) storage.Vreal;
                    storage.Vullong = volatileLoad(&storage.Vullong);
                }
                break;
            case ubyte_, ushort_, short_, int_, uint_, long_, ulong_,
                    vector_, pointer_, void_: assert(0);
        }
        final switch (result) with (ParameterType) {
            case float_:
                if (source != float_) {
                    storage.Vfloat = cast(float) storage.Vdouble;
                    storage.Vuns = volatileLoad(&storage.Vuns);
                }
                break;
            case double_: break;
            case real_:
                if (source != real_)
                    storage.Vreal = storage.Vdouble;
                break;
            case ubyte_, ushort_, short_, int_, uint_, long_, ulong_,
                    vector_, pointer_, void_: assert(0);
        }
    }

    // `intrinsic_op` of dmd 2.113.0 (`dmd.glue.toir`), row by row. The
    // function is `package(dmd.glue)` and cannot be called, so this is a
    // copy. The code generator compares the type of the first parameter by
    // identity with its basic type singletons, so a qualified type matches
    // none of them: no `toBasetype` before the `.ty` tests below.
    //
    // `intrinsic_op` first resolves an alias to its function
    // (`toAliasFunc`). The call plan only sees the resolved function,
    // because the frontend resolves the alias when it picks the overload.
    private static bool isInlinedByCodeGenerator(
        FuncDeclaration function_, in imported!"dmd.dmodule".Module module_,
    ) {
        import dmd.astenums: TY;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        if (function_.isDeprecated)
            return false;
        if (module_ is null || module_.md is null)
            return false;
        const packages = module_.md.packages;
        if (packages.length == 0)
            return false;

        const name = function_.ident.toString;
        auto parameterList = typeFunctionOf(function_).parameterList;
        const operand = parameterList.length > 0
            ? parameterList[0].type : null;
        const unqualified = operand !is null && operand.mod == 0;
        const real_ = unqualified && operand.ty == TY.Tfloat80;
        const float_ = unqualified && operand.ty == TY.Tfloat32;
        const double_ = unqualified && operand.ty == TY.Tfloat64;
        const floating = real_ || float_ || double_;

        const first = packages[0].toString;
        const last = module_.md.id.toString;
        // Any module of `std.math.*`; every other two-package module is
        // only for `core.stdc.stdarg.va_start`, which `isVaStart` finds.
        const stdMath = packages.length == 2
            ? first == "std" && packages[1].toString == "math"
            : first == "std" && last == "math";
        if (packages.length == 2 && !stdMath)
            return false;

        bool inlined;
        bool x87Only;
        bool bitInstruction;
        if (stdMath) {
            inlined = (real_ || name == "sqrt")
                ? floating && isMathRow(name, x87Only)
                : name == "fabs" && (float_ || double_);
        } else if (first != "core") {
            return false;
        } else if (last == "math") {
            inlined = floating && isMathRow(name, x87Only);
        } else if (last == "simd") {
            switch (name) {
                case "__prefetch", "__simd_sto", "__simd", "__simd_ib":
                    inlined = true;
                    break;
                default:
                    break;
            }
        } else if (last == "bitop") {
            switch (name) {
                case "bsf", "bsr", "btc", "btr", "bts":
                    inlined = true;
                    bitInstruction = true;
                    break;
                case "volatileLoad", "volatileStore", "inp", "inpl", "inpw",
                        "outp", "outpl", "outpw", "bswap", "_popcnt":
                    inlined = true;
                    break;
                default:
                    break;
            }
        } else if (last == "volatile") {
            inlined = name == "volatileLoad" || name == "volatileStore";
        }

        // The backend of dmd has no x87 or bit instructions for AArch64.
        version (AArch64)
            return inlined && !x87Only && !bitInstruction;
        else
            return inlined;
    }

    // The names of `core.math` that dmd's code generator inlines, and
    // whether the instruction exists on x87 only.
    private static bool isMathRow(in const(char)[] name, ref bool x87Only) {
        x87Only = name != "fabs" && name != "yl2x";
        switch (name) {
            case "cos", "sin", "fabs", "rint", "sqrt", "yl2x", "ldexp",
                    "rndtol", "yl2xp1", "toPrec":
                return true;
            default:
                return false;
        }
    }

    // The concrete types `function_` declares for its parameters and its
    // result: the lookup key of `snakebite.backends.builtins.entryOf`,
    // which the name alone does not give. `false` when the signature has a
    // type that no wrapper takes, or a parameter or result that does not
    // have the plain value layout a wrapper reads and writes.
    private static bool signatureOf(
        FuncDeclaration function_,
        scope ParameterType[] parameters,
        out ParameterType result,
    ) {
        import dmd.astenums: STC, TY, VarArg;
        import dmd.typesem: toBasetype;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto type = typeFunctionOf(function_);
        if (type.isRef || type.parameterList.varargs != VarArg.none
                || parameters.length != type.parameterList.length)
            return false;
        auto resultType = type.next.toBasetype;
        if (resultType.ty == TY.Tvoid)
            result = ParameterType.void_;
        else if (!parameterTypeOf(resultType, result))
            return false;

        // `const` fails: `ParameterList.length` and `opIndex` are not
        // `const` methods.
        auto parameterList = type.parameterList;
        foreach (i; 0 .. parameterList.length) {
            auto parameter = parameterList[i];
            if (parameter.storageClass & (STC.ref_ | STC.out_ | STC.lazy_))
                return false;
            ParameterType parameterType;
            if (!parameterTypeOf(
                    parameter.type.toBasetype, parameterType))
                return false;
            parameters[i] = parameterType;
        }
        return true;
    }

    private static bool parameterTypeOf(
        imported!"dmd.mtype".Type type,
        out ParameterType result,
    ) {
        import dmd.astenums: TY;
        import dmd.typesem: size;

        // The wrappers of `core.simd` move this many bytes.
        enum vectorSize = 16;

        final switch (type.ty) with (TY) {
            case Tfloat32: result = ParameterType.float_; return true;
            case Tfloat64: result = ParameterType.double_; return true;
            case Tfloat80: result = ParameterType.real_; return true;
            case Tint8, Tuns8, Tbool, Tchar:
                result = ParameterType.ubyte_; return true;
            case Tint16:
                result = ParameterType.short_; return true;
            case Tuns16:
            case Twchar:
                result = ParameterType.ushort_; return true;
            case Tint32: result = ParameterType.int_; return true;
            case Tint64: result = ParameterType.long_; return true;
            case Tuns32, Tdchar:
                result = ParameterType.uint_; return true;
            case Tuns64:
                result = ParameterType.ulong_; return true;
            case Tvoid: return false;
            case Tvector:
                result = ParameterType.vector_;
                return type.size == vectorSize;
            case Tpointer:
                result = ParameterType.pointer_; return true;
            case Tarray, Tsarray, Taarray, Treference, Tfunction,
                Tident, Tclass, Tstruct, Tenum, Tdelegate, Tnone,
                Timaginary32,
                Timaginary64, Timaginary80, Tcomplex32, Tcomplex64,
                Tcomplex80, Terror,
                Tinstance, Ttypeof, Ttuple, Tslice, Treturn, Tnull,
                Tint128, Tuns128, Ttraits, Tmixin, Tnoreturn, Ttag:
                return false;
        }
    }
}

// Whether a call site's own argument list has the wrong length for
// `parameterList` - the one check every call-compiling and call-binding
// site makes before reading arguments positionally against parameters,
// whether the callee is a resolved declaration, a bare `TypeFunction`
// reached through a pointer or delegate value, or a constructor's own
// parameter list. Typesafe `T t...` arrives as one array-typed argument
// by the time this ever runs (the frontend already packed it), so this
// stays exact for that variadic kind too.
//
// A variadic parameter list (`VarArg.variadic`) only requires *at
// least* its declared parameters: a C-style variadic call site's own
// extra arguments (issue #334 step 5) sit past `parameterList.length`
// in `arguments`; an `extern(D)` untyped variadic call site adds its own
// leading `_arguments` too (issue #334 step 6), at index `0`, ahead of
// the declared parameters, not past them - only the call's total
// argument count exceeds `parameterList.length`, by one for
// `_arguments` and again for each of its own extra arguments past that.
// Either way, nothing here need know an extra argument's own count or
// types, positionally unmatched to any parameter - only whoever builds
// the call's own plan does (`snakebite.ffi.plan.CallPlan.
// prepareVariadic`). `VarArg.typesafe`
// (`T t...`) needs no such allowance: the frontend has already packed a
// typesafe call's trailing arguments into one array-typed argument by
// the time this ever runs, so `>=` never actually admits more arguments
// than `parameterList.length` for that kind.
public bool arityMismatches(
    imported!"dmd.mtype".ParameterList parameterList,
    imported!"dmd.arraytypes".Expressions* arguments,
    in bool allowExtra = false,
) {
    const count = arguments is null ? 0 : arguments.length;
    return allowExtra
        ? count < parameterList.length
        : count != parameterList.length;
}

// The caller side of a call through a function pointer or a delegate
// value. A cast can give the value a type that is not the type of the
// function that it holds, so the type of the value decides what the
// arguments are and how each converts, and the callee reads its parameters
// from where the C calling convention puts them, as native code does
// (`ArgumentFlow`): a parameter reads the argument that is in the same
// register, and not the argument at the same position. That is true for the
// `extern(D)` convention too when the types agree, which is the one that
// `signature` decides; for a mismatch of the `extern(D)` convention dmd
// passes the arguments in reverse register order, so only the C convention
// is matched.
//
// When the signature of the value is the signature of the callee the frames
// agree and the arguments go where the value's layout puts them. A callee
// that has no context, such as a function literal that a delegate type holds,
// has the parameters of `withoutContext`.
public struct ValueCall {
    import dmd.mtype: TypeFunction;
    import snakebite.backends.argumentflow: ArgumentFlow, Shape, Signature;
    import snakebite.backends.layout: FrameLayout;

    public TypeFunction type;
    public bool hasContext;
    public FrameLayout layout;
    public FrameLayout withoutContext;

    public static ValueCall of(TypeFunction type, in bool hasContext) {
        return ValueCall(
            type,
            hasContext,
            FrameLayout.ofParameters(type, hasContext),
            FrameLayout.ofParameters(type, false),
        );
    }

    public bool isVariadic() const {
        import dmd.astenums: VarArg;

        return type.parameterList.varargs == VarArg.variadic;
    }

    public bool mismatches(
        imported!"dmd.arraytypes".Expressions* arguments,
    ) {
        // dmd's `ParameterList` has no `const` methods.
        return arityMismatches(type.parameterList, arguments, isVariadic);
    }

    // The layout that the callee reads its arguments by when the signatures
    // are equal.
    public const(FrameLayout)* layoutFor(in bool calleeHasContext) const {
        return hasContext && !calleeHasContext ? &withoutContext : &layout;
    }

    public const(Signature)* signature() const {
        return layout.signature;
    }

    // Where each argument of a call goes for a callee with `callee` as its
    // signature, given the shapes of the variadic arguments of the call.
    public ArgumentFlow flowTo(
        in Signature callee, in Shape[] surplus, in bool calleeHasContext,
    ) const {
        return ArgumentFlow(
            signature.parameters, surplus, callee.parameters,
            hasContext && calleeHasContext,
        );
    }
}

// An indirect call - one whose callee `expression.e1` is a bare value,
// not a resolved `FuncDeclaration` - is a delegate call whenever that
// value's own type is `Tdelegate`, never mind whether dmd's parser put a
// `PtrExp` there. `key in aa` on an associative array of delegates, and
// `&someDelegateVariable`, both give a *pointer to a delegate*; calling
// through either dereferences with the same `(*p)(args)` syntax dmd
// itself lowers a bare function-pointer call to (`fn(args)` becomes
// `(*fn)(args)`, see `snakebite.backends.layout.FrameLayout.
// ofParameters`'s own callers). Reading the syntax instead of `e1.type`
// mistakes that delegate-pointer dereference for the function-pointer
// shape it merely resembles: `deref.e1`, the pointer's own pointee, is a
// `Tdelegate`, not the `Tfunction` a function pointer's pointee always
// is, so a function-pointer read off it is nonsense. Either shape leaves
// `e1` itself as the one expression to evaluate for the callee's value -
// the delegate's own two words when `e1.type` is `Tdelegate` (dereferenced
// already, whatever the syntax), or, when it is a `PtrExp` and dmd's
// lowering leaves `e1.type` the pointed-to `Tfunction`, that `PtrExp`'s
// own `e1` for the function pointer's single word.
public bool isIndirectDelegateCall(
    imported!"dmd.mtype".Type calleeType,
) {
    import dmd.astenums: Tdelegate;
    import dmd.typesem: toBasetype;

    return calleeType !is null && calleeType.toBasetype.ty == Tdelegate;
}
