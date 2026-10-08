module snakebite.backends.calls;


private:


// Delegate values use native callback entries, so captured guest contexts
// do not change whether the receiving function executes as guest or host.
public struct CallSelection {
    // Holds a `SharedTable` (finding 2.4): a copy would share its
    // storage with the original until one side grows.
    @disable this(this);

    import dmd.func: BUILTIN, FuncDeclaration;

    import snakebite.backends.builtins:
        BuiltinCall, ParameterType, startVariadicEntry;
    import snakebite.sharedtable: SharedTable;

    // Every call site resolves to exactly one of these. `guest` and
    // `native` are the two routes `usesGuestBody` always answered;
    // `builtin` is the third one this backend adds for a bodiless
    // function that is a compiler intrinsic (`builtinDecision`) -
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

    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a decision is built once per function.
    private SharedTable!(FuncDeclaration, Decision) _decisions;

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
    // No frontend lock here at all (measured: 7,721 acquisitions, 61.3s
    // wait, in a parallel `bin/ut` run before this fix) - every dmd
    // field `buildDecision` reads (`fbody`, `type`, `parent`, `vtbl`'s
    // `isInstantiated`/`isFuncLiteralDeclaration` classification) is set
    // by dmd's ordinary declaration/type semantic (phase 1), not lazily
    // deferred to a body walk (`semantic3`) the way `functionNeedsClosure`/
    // `hasHiddenThis`'s own fields are - a `FuncDeclaration` this ever
    // sees has already had its own signature resolved by whatever
    // frontend pass made it a valid call target in the first place, so
    // there is no dmd forward reference here to force at all, only a
    // cache miss to fill. `_decisions` is a `SharedTable`, which brings
    // its own insert lock (ADR-0006), so nothing about this cache needs
    // the frontend one - the same reasoning `snakebite.backends.
    // interpreter.walker`'s `Cache.build` already applies to its own
    // caches.
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

    // Every dmd query a function's decision needs, resolved once and
    // never again - no lock, `decisionOf`'s own doc explains why none of
    // these reads needs one.
    private static Decision buildDecision(
        FuncDeclaration function_,
        lazy bool hasNativeSymbol,
        lazy bool hasIndependentNativeSymbol,
        scope bool delegate(FuncDeclaration) isGuest,
    ) {
        import dmd.astenums: VarArg;
        import snakebite.frontend.dmd.functions: typeFunctionOf;
        import snakebite.frontend.dmd.delegates: outerFunctionOf;

        // A declaration without a body can only describe a native call or
        // a builtin - never a guest one, since there is no guest body to
        // run.
        if (function_.fbody is null)
            return isVaStart(function_)
                ? Decision(Route.vaStart, &startVariadicEntry)
                : isAlloca(function_) ? Decision(Route.alloca)
                : builtinDecision(function_);

        const type = typeFunctionOf(function_);
        if (type.parameterList.varargs == VarArg.variadic && hasNativeSymbol)
            return Decision(Route.native);

        // This includes siblings and deeper nested callees: every static
        // chain points into frames whose offsets belong to this backend.
        if (outerFunctionOf(function_) !is null)
            return Decision(Route.guest);

        // A function literal in an imported aggregate has a body but no
        // native symbol of its own. Keep it guest when it is root-owned or
        // when the linker cannot resolve that symbol.
        if (function_.isFuncLiteralDeclaration !is null
                && function_.fbody !is null
                && (isGuest(function_) || !hasNativeSymbol))
            return Decision(Route.guest);

        // The host compiler's druntime implements `va_copy` as an
        // intrinsic, so the process has no symbol for it, but the frontend's
        // druntime gives it a body.
        if (isVaCopy(function_))
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
        const prefers = function_.isInstantiated() !is null
            ? !hasIndependentNativeSymbol : isGuest(function_);
        return Decision(prefers ? Route.guest : Route.native);
    }

    // The test dmd's own glue applies (`dmd.glue.toir.intrinsic_op`) to
    // find `core.stdc.stdarg.va_start`, which `dmd.builtin` does not
    // classify: a template instance named `va_start` in that module.
    private static bool isVaStart(FuncDeclaration function_) {
        const module_ = function_.getModule;
        return function_.ident.toString == "va_start"
            && function_.toParent.isTemplateInstance !is null
            && module_ !is null && module_.md !is null
            && module_.md.toString == "core.stdc.stdarg";
    }

    private static bool isVaCopy(FuncDeclaration function_) {
        const module_ = function_.getModule;
        return function_.ident.toString == "va_copy"
            && function_.toParent.isTemplateInstance is null
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
    // A declaration that dmd inlines but no wrapper takes (an instruction
    // whose wrapper does not exist, or a result type that dmd converts
    // unspecified) is a native call too. A wrapper writes its result at its
    // own size, so a wrapper never serves a declaration it differs from.
    private static Decision builtinDecision(FuncDeclaration function_) {
        import snakebite.backends.builtins:
            destinationParameterOf, entryOf;

        if (!isInlinedByCodeGenerator(function_))
            return Decision(Route.native);

        ParameterType[] parameters;
        ParameterType result;
        const keyed = signatureOf(function_, parameters, result);
        // dmd's own `determine_builtin` keys on `fd.ident`, too (`dmd/
        // builtin.d`): the identifier is the table's key, not the symbol.
        const name = function_.ident.toString.idup;
        auto entry = keyed ? entryOf(name, parameters, result) : null;
        return entry is null
            ? Decision(Route.native)
            : Decision(Route.builtin, entry, destinationParameterOf(name));
    }

    // `intrinsic_op` of dmd 2.113.0 (`dmd.glue.toir`), row by row. The
    // function is `package(dmd.glue)` and cannot be called, so this is a
    // copy. The code generator compares the type of the first parameter by
    // identity with its basic type singletons, so a qualified type matches
    // none of them: no `toBasetype` before the `.ty` tests below.
    private static bool isInlinedByCodeGenerator(
        FuncDeclaration declaration,
    ) {
        import dmd.astenums: TY;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto function_ = declaration.toAliasFunc;
        if (function_.isDeprecated)
            return false;
        const module_ = function_.getModule;
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
        out ParameterType[] parameters,
        out ParameterType result,
    ) {
        import dmd.astenums: STC, TY, VarArg;
        import dmd.typesem: toBasetype;
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto type = typeFunctionOf(function_);
        if (type.isRef || type.parameterList.varargs != VarArg.none)
            return false;
        auto resultType = type.next.toBasetype;
        if (resultType.ty == TY.Tvoid)
            result = ParameterType.void_;
        else if (!parameterTypeOf(resultType, false, result))
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
                    parameter.type.toBasetype, false, parameterType))
                return false;
            parameters ~= parameterType;
        }
        return true;
    }

    // `pointee` is for the type that a pointer parameter points to.
    private static bool parameterTypeOf(
        imported!"dmd.mtype".Type type,
        in bool pointee,
        out ParameterType result,
    ) {
        import dmd.astenums: TY;
        import dmd.typesem: nextOf, size, toBasetype;

        // The wrappers of `core.simd` move this many bytes.
        enum vectorSize = 16;

        final switch (type.ty) with (TY) {
            case Tfloat32: result = ParameterType.float_; return !pointee;
            case Tfloat64: result = ParameterType.double_; return !pointee;
            case Tfloat80: result = ParameterType.real_; return !pointee;
            case Tuns8:
                result = pointee
                    ? ParameterType.ubytePointer_ : ParameterType.ubyte_;
                return true;
            case Tuns16:
                result = pointee
                    ? ParameterType.ushortPointer_ : ParameterType.ushort_;
                return true;
            case Tint32: result = ParameterType.int_; return !pointee;
            case Tint64: result = ParameterType.long_; return !pointee;
            case Tuns32:
                result = pointee
                    ? ParameterType.uintPointer_ : ParameterType.uint_;
                return true;
            case Tuns64:
                result = pointee
                    ? ParameterType.ulongPointer_ : ParameterType.ulong_;
                return true;
            case Tvoid: result = ParameterType.voidPointer_; return pointee;
            case Tvector:
                result = ParameterType.vector_;
                return !pointee && type.size == vectorSize;
            case Tpointer:
                return !pointee && parameterTypeOf(
                    type.nextOf.toBasetype, true, result);
            case Tarray, Tsarray, Taarray, Treference, Tfunction,
                Tident, Tclass, Tstruct, Tenum, Tdelegate, Tnone,
                Tint8, Tint16, Timaginary32,
                Timaginary64, Timaginary80, Tcomplex32, Tcomplex64,
                Tcomplex80, Tbool, Tchar, Twchar, Tdchar, Terror,
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
