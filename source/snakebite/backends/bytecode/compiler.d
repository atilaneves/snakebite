module snakebite.backends.bytecode.compiler;


private:

import dmd.mtype: Type;
import object: TypeInfo, TypeInfo_Array, TypeInfo_Class, TypeInfo_Struct;
import snakebite.backends.loweringvisitor: LoweringVisitor;
import snakebite.ffi:
    CallbackBridge, maxArguments, PlanCache, supportsBoolFunction;


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

// As above, for a caller that also has `type` in hand and so can ask the
// one further question `TypeFacts` alone cannot answer: whether `type` is a
// struct whose native bytes can occupy a frame slot. Operations that need
// aggregate semantics still check `isPlainOldStruct` below.
private bool isSupportedFacts(
    in imported!"snakebite.nativelayout".TypeFacts facts,
    imported!"dmd.mtype".Type type,
) {
    import dmd.astenums: Tpointer;

    return isSupportedFacts(facts) || isFloatingType(type)
        || type.ty == Tpointer
        || type.isTypeStruct !is null;
}

// Whether this compiler can treat `type` as plain bytes it never has to
// call guest code to copy, construct or destroy: a struct with no
// postblit, copy constructor, destructor or user-defined assignment, not a
// `union` (whose fields this compiler cannot lay out from a plain field
// list) and not nested in an enclosing scope (a local struct with its own
// `this` captured context, unsupported the same way a method is), whose
// every field is itself one of an integral this compiler already lays
// out, a dynamic array (a plain two-word slice, copied the same way an
// integral field is - by value, sharing whatever it points at), or a
// nested struct meeting this same predicate. `declaration.zeroInit` is
// required too: this compiler's only default-value story for a struct is
// zeroing its bytes (see `opZero`), the same way `nativelayout.storeValue`
// already special-cases a zero-init struct's own `.init` elsewhere.
private bool isPlainOldStruct(imported!"dmd.mtype".Type type) {
    import dmd.astenums: STC, Tarray, Tpointer;
    import snakebite.nativelayout: isIntegralSize, TypeFacts;

    auto structType = type.isTypeStruct;
    if (structType is null)
        return false;

    auto declaration = structType.sym;
    if (!declaration.zeroInit
            || declaration.isUnionDeclaration !is null
            || declaration.enclosing !is null
            || declaration.postblit !is null || declaration.hasCopyCtor
            || declaration.dtor !is null
            || declaration.hasIdentityAssign || declaration.hasBlitAssign)
        return false;

    foreach (field; declaration.fields) {
        if (field.isBitFieldDeclaration !is null
                || (field.storage_class & STC.ref_))
            return false;

        if (field.type.isTypeStruct !is null) {
            if (!isPlainOldStruct(field.type))
                return false;
            continue;
        }

        if (field.type.ty == Tarray || field.type.ty == Tpointer)
            continue;

        const facts = TypeFacts.of(field.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            return false;
    }

    return true;
}

// Whether `type` is `float`/`double`/`real` - `TypeFacts` has no notion of
// its own for this, unlike `isIntegral`/`isDynamicArray`, which drive
// checks all over this compiler.
private bool isFloatingType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tfloat32, Tfloat64, Tfloat80;

    return type.ty == Tfloat32 || type.ty == Tfloat64 || type.ty == Tfloat80;
}

// A pointer-sized temporary's facts: the shape every address this compiler
// computes at run time - a `ref` binding, an array element's, an
// allocation's result - shares, whatever the value living behind it
// eventually is.
private imported!"snakebite.nativelayout".TypeFacts pointerFactsOf() {
    import snakebite.nativelayout: TypeFacts;

    return TypeFacts(size_t.sizeof, size_t.sizeof, false, true);
}

// An array element type this compiler can lay out: every integral width it
// already accepts elsewhere, plus `float`/`double`/`real`, which have no
// `.init` this compiler can write any other way but zero.
private bool isSupportedElementFacts(
    in imported!"snakebite.nativelayout".TypeFacts facts,
    imported!"dmd.mtype".Type type,
) {
    import snakebite.nativelayout: isIntegralSize;

    return (facts.isIntegral && isIntegralSize(facts.size))
        || isFloatingType(type)
        || isPlainOldStruct(type);
}


public final class Bytecode: imported!"snakebite.backends.backend".Backend {
    import dmd.func: FuncDeclaration;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode.vm: Function, maxReturnWidth, Vm;
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
    private TypeInfo[] _typeInfoRoots;
    private size_t _compilationDepth;
    private size_t _cacheMisses;
    private imported!"core.time".Duration _compilationTime;
    private CallbackBridge _callbacks;

    public this(const Program program) {
        super(program);
        _vm = Vm(defaultFrameCapacity);
        _callbacks = new CallbackBridge(
            &invokeBoolFunction,
            cast(void*) this,
            &isGuestForCallback,
            cast(void*) this,
            "bytecode",
        );
    }

    public ~this() {
        if (_callbacks !is null)
            _callbacks.release;
    }

    public override imported!"snakebite.backends.backend".CompilationStatistics
        compilationStatistics() const {
        return imported!"snakebite.backends.backend".CompilationStatistics(
            true,
            _cacheMisses,
            _compilationTime,
        );
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
        string result;
        call(function_, &result, []);
        return result;
    }

    package bool hasNativeSymbol(FuncDeclaration function_) {
        return _plans.hasNativeSymbol(function_);
    }

    package bool isGuestFunction(FuncDeclaration function_) const {
        return _program.isInterpreted(function_);
    }

    package void* boolFunctionAddress(FuncDeclaration function_) {
        return _callbacks.address(function_);
    }

    extern(C) private static bool isGuestForCallback(
        void* context,
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        return (cast(Bytecode) context)._program.isInterpreted(function_);
    }

    extern(C) private static bool invokeBoolFunction(
        void* context,
        void* functionAddress,
    ) {
        auto bytecode = cast(Bytecode) context;
        auto function_ = cast(FuncDeclaration) functionAddress;
        bool result;
        bytecode._vm.call(*bytecode.compileFunction(function_), &result);
        return result;
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

    private TypeInfo runtimeTypeInfo(Type type) {
        import dmd.astenums:
            Tarray, Tbool, Tchar, Tdchar, Tfloat32, Tfloat64, Tfloat80,
            Tint8, Tint16, Tint32, Tint64, Tuns8, Tuns16, Tuns32, Tuns64,
            Twchar;
        import dmd.typesem: nextOf;

        if (type.vtinfo !is null) {
            auto address = _plans.resolve(type.vtinfo.ident.toString);
            if (address !is null)
                return cast(TypeInfo) address;
        }

        import dmd.astenums: Tclass;
        if (type.ty == Tclass)
            return cast(TypeInfo) cast() TypeInfo_Class.find(type.toString);

        if (auto structType = type.isTypeStruct) {
            auto info = new TypeInfo_Struct;
            info.m_init = new byte[](structType.sym.structsize);
            info.m_align = structType.sym.alignsize;
            if (structType.sym.hasPointerField)
                info.m_flags = TypeInfo_Struct.StructFlags.hasPointers;
            _typeInfoRoots ~= info;
            return info;
        }

        if (type.ty == Tarray) {
            auto info = new TypeInfo_Array;
            info.value = runtimeTypeInfo(type.nextOf);
            if (info.value is null)
                return null;
            _typeInfoRoots ~= info;
            return info;
        }

        switch (type.ty) {
            case Tbool: return typeid(bool);
            case Tchar: return typeid(char);
            case Twchar: return typeid(wchar);
            case Tdchar: return typeid(dchar);
            case Tint8: return typeid(byte);
            case Tint16: return typeid(short);
            case Tint32: return typeid(int);
            case Tint64: return typeid(long);
            case Tuns8: return typeid(ubyte);
            case Tuns16: return typeid(ushort);
            case Tuns32: return typeid(uint);
            case Tuns64: return typeid(ulong);
            case Tfloat32: return typeid(float);
            case Tfloat64: return typeid(double);
            case Tfloat80: return typeid(real);
            default: return null;
        }
    }

    // `function_`'s compiled form, compiling it - and, transitively,
    // whatever it calls - on first use. Reused on every later call to the
    // same function, the way compiled code only ever compiles a function
    // once. Returns a stable pointer (see `_compiled`) so a call site
    // reached while this very function is still being compiled can point
    // at it too.
    package const(Function)* compileFunction(FuncDeclaration function_) {
        import dmd.astenums: STC, Tvoid;
        import dmd.funcsem: needsClosure;
        import dmd.typesem: nextOf;
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

        import std.datetime.stopwatch: AutoStart, StopWatch;

        const outermost = _compilationDepth == 0;
        ++_compilationDepth;
        ++_cacheMisses;
        auto stopWatch = StopWatch(AutoStart.yes);
        scope (exit) {
            --_compilationDepth;
            if (outermost)
                _compilationTime += stopWatch.peek;
        }

        // A struct method's hidden `this` is a pointer to the receiver. A
        // nested function uses the same DMD slot for its static chain, which
        // the bytecode frame now carries as a context pointer. Class methods
        // still need virtual dispatch and remain outside this scope.
        if (function_.vthis !is null
                && function_.isThis !is null
                && function_.isThis.isStructDeclaration is null)
            throw rejection(function_, function_.loc, "a class method");

        auto functionType = typeFunctionOf(function_);
        auto returnType = function_.type.nextOf;
        const isVoidReturn = returnType !is null && returnType.ty == Tvoid;
        // A `ref` return hands the caller the returned storage's own
        // address rather than a copy of its value - see `compileReturn` and
        // `compileAddress` - so the frame slot a caller reads it into is
        // one pointer wide regardless of what the returned type itself
        // would otherwise need, the same convention `snakebite.ffi.plan`
        // already uses for a native `ref`-returning callee.
        const isRefReturn = functionType.isRef;
        const pointeeFacts = isVoidReturn ? TypeFacts.init : TypeFacts.of(returnType);
        if (!isVoidReturn && (!isSupportedFacts(pointeeFacts, returnType)
                || (!isRefReturn && pointeeFacts.size > maxReturnWidth)))
            throw rejection(function_, function_.loc, text(
                "a `", returnType is null ? "auto" : returnType.toString,
                "` return",
            ));
        const returnFacts = isRefReturn ? pointerFactsOf : pointeeFacts;

        foreach (i; 0 .. functionType.parameterList.length) {
            auto parameter = functionType.parameterList[i];
            if (parameter.storageClass & (STC.out_ | STC.lazy_))
                throw rejection(function_, function_.loc,
                    "an `out`/`lazy` parameter");

            const facts = TypeFacts.of(parameter.type);
            if (!isSupportedFacts(facts, parameter.type))
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

        scope compiler = new FunctionCompiler(
            this, function_, layout, returnFacts, isVoidReturn, isRefReturn);
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
extern(C++) private final class FunctionCompiler: LoweringVisitor {
    import dmd.declaration: VarDeclaration;
    import dmd.identifier: Identifier;
    import dmd.init: ExpInitializer;
    import dmd.expression;
    import dmd.func: FuncDeclaration;
    import dmd.mtype: Type;
    import dmd.statement:
        BreakStatement, CaseStatement, CompoundStatement, ContinueStatement,
        DefaultStatement, DoStatement, ExpStatement, ForStatement,
        GotoCaseStatement, GotoDefaultStatement, IfStatement, ImportStatement,
        LabelStatement, ReturnStatement, ScopeStatement, Statement,
        SwitchErrorStatement, SwitchStatement, ThrowStatement,
        TryCatchStatement, TryFinallyStatement, UnrolledLoopStatement;
    import dmd.tokens: EXP;
    import snakebite.backends.bytecode.vm:
        Arg, AssertSite, CallSite, ClosureSlot, discardResult,
        ExceptionHandler, Function,
        Instruction,
        opAdd, opAssert, opBitAnd, opBitOr, opBitXor, opBranchFalse,
        opBranchTrue, opCall,
        opCastToBool, opCastWidenSigned, opCastWidenUnsigned, opComplement,
        opArrayEqual, opConstant, opCopy, opDivideSigned, opDivideUnsigned,
        opEqual,
        opFloatAdd, opFloatDivide, opFloatEqual, opFloatGreaterOrEqual,
        opFloatGreaterThan, opFloatLessOrEqual, opFloatLessThan,
        opFloatModulo, opFloatMultiply, opFloatNegate, opFloatNotEqual,
        opFloatSubtract, opFloatToIntegralSigned, opFloatToIntegralUnsigned,
        opFloatWidthCast, opFrameAddress, opGreaterOrEqualSigned,
        opGreaterOrEqualUnsigned, opGreaterThanSigned, opGreaterThanUnsigned,
        opIntegralToFloatSigned, opIntegralToFloatUnsigned,
        opJump, opLessOrEqualSigned, opLessOrEqualUnsigned, opLessThanSigned,
        opLessThanUnsigned, opLoadIndirect, opLogicalNot, opModuloSigned,
        opModuloUnsigned, opMultiply, opNegate, opNotEqual, opRangeError,
        opReturn,
        opReturnVoid, opShiftLeft, opShiftRightArithmetic, opShiftRightLogical,
        opStaticAddress, opStaticLoad, opStaticStore, opStoreIndirect,
        opSubtract, opThrow, opZero;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf;
    import snakebite.backends.layout: ClosureLayout, FrameLayout;
    import snakebite.exception: SnakebiteException;
    import snakebite.nativelayout:
        alignUp, isIntegralSize, storeValue, TypeFacts;

    alias visit = LoweringVisitor.visit;

    extern(D):

    private Bytecode _bytecode;
    private FuncDeclaration _function;
    private const FrameLayout _layout;
    private ClosureLayout _closureLayout;
    private TypeFacts _returnFacts;
    private bool _isVoidReturn;
    // Whether this function returns by `ref`: `compileReturn` then compiles
    // its own returned storage's address instead of its value, and a
    // caller's own `opCall` result slot holds that address rather than a
    // copy - see `compileAddress`'s own `CallExp` case, the one place that
    // address is read back out.
    private bool _isRefReturn;

    private Instruction[] _instructions;
    private long[] _constants;
    private CallSite[] _callSites;
    private AssertSite[] _assertSites;
    private PendingExceptionHandler[] _exceptionHandlers;
    private size_t _tempSize;
    private uint _tempAlignment;
    private size_t _closureOffset = size_t.max;
    private struct StaticSlot {
        private size_t _offset;
    }
    private StaticSlot[VarDeclaration] _staticSlots;
    private ubyte[] _staticInitialValue;
    private uint _staticAlignment = 1;
    // Set once nothing after the statement just compiled can run: a
    // `return`, a `continue`, or an `if`/loop whose every path already
    // ends one of those. Every statement kind after one in the same block
    // is dead code dmd itself only warns about, so nothing is compiled
    // for it, and none of its own kinds need this compiler to recognise
    // them. Reset by whichever construct (`if`, a loop) knows execution
    // can still reach past it - a `continue` inside a loop body, say,
    // does not end the loop itself.
    private bool _finished;
    // The loop or unrolled `foreach` this compiler is currently inside the
    // body of, innermost last - what a `continue` targets, labelled or
    // not. A `do` knows its own continue target (the condition it
    // re-checks) before it compiles its body; a `for`'s increment and an
    // unrolled `foreach`'s next element are both only known once the body
    // ahead of them is already compiled, so a `continue` reached first
    // queues its own instruction index in `pendingContinueJumps` instead,
    // and `resolveContinues` patches every one of them in once the target
    // is known.
    private struct LoopContext {
        Identifier label;
        size_t continueTarget = size_t.max;
        size_t[] pendingContinueJumps;
    }

    private struct PendingExceptionHandler {
        private TypeInfo_Class _type;
        private size_t _bodyStart;
        private size_t _bodyEnd;
        private size_t _handler;
        private size_t _catchOffset;
    }

    // What a `break` targets: the innermost loop, `switch`, or unrolled
    // `foreach` this compiler is currently inside the body of, or - given
    // a label - whichever of those an enclosing `LabelStatement` names.
    // `pendingBreakJumps` collects every `break` that targets this one,
    // patched once this construct's own compiled code ends.
    private struct Breakable {
        Identifier label;
        size_t[] pendingBreakJumps;
    }
    private Breakable[] _breakables;

    // A label of a `LabelStatement` this compiler is currently inside,
    // not yet claimed by the loop/`switch`/unrolled `foreach` it labels.
    // dmd does not resolve `break ident`/`continue ident` to a target
    // itself - only `findLoopIndex`/`findBreakableIndex` below do, by
    // identifier - but it does resolve which statement a label names:
    // `_pendingLabelTarget` holds that resolved `Statement` (see
    // `compileLabel`), since a labelled `for` with an init is rewritten
    // to put the label on the generated `ForStatement` alone, not on
    // whatever the init itself also compiles (a `switch`, say).
    private Identifier _pendingLabel;
    private Statement _pendingLabelTarget;

    // The `switch` a `default:` inside its body belongs to - needed only
    // because, unlike `GotoDefaultStatement`, dmd's `DefaultStatement`
    // does not itself carry a pointer back to its own `SwitchStatement`.
    private SwitchStatement[] _switchStack;

    // Where a `CaseStatement` this compiler has already compiled starts -
    // filled in by `recordCaseTarget` the moment that case's own first
    // instruction is known. A `goto case`, or the head of the `switch`
    // itself, reached before that point instead queues its own jump in
    // `_pendingCaseJumps`, resolved once the target is recorded.
    private size_t[CaseStatement] _caseTargets;
    private struct PendingCaseJump {
        size_t instructionIndex;
        CaseStatement case_;
    }
    private PendingCaseJump[] _pendingCaseJumps;

    // As `_caseTargets`/`_pendingCaseJumps`, for a `switch`'s own
    // `default:` - always present by the time this compiler sees a
    // `SwitchStatement`, since dmd itself synthesises one (see
    // `compileSwitch`'s own doc) whenever the source had none.
    private size_t[SwitchStatement] _defaultTargets;
    private struct PendingDefaultJump {
        size_t instructionIndex;
        SwitchStatement switch_;
    }
    private PendingDefaultJump[] _pendingDefaultJumps;
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
        in bool isRefReturn,
    ) {
        _bytecode = bytecode;
        _function = function_;
        _layout = layout;
        _returnFacts = returnFacts;
        _isVoidReturn = isVoidReturn;
        _isRefReturn = isRefReturn;
        _tempSize = layout.size;
        _tempAlignment = layout.alignment;

        import dmd.funcsem: needsClosure;
        if (function_.needsClosure()) {
            _closureLayout = ClosureLayout.of(function_);
            _closureOffset = reserveTemp(pointerFacts);
        }
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

        ExceptionHandler[] exceptionHandlers;
        foreach (pending; _exceptionHandlers) {
            if (pending._handler >= _instructions.length)
                throw rejection(_function, _function.loc,
                    "an empty catch handler");

            exceptionHandlers ~= ExceptionHandler(
                pending._type,
                instructionAt(pending._bodyStart),
                instructionAt(pending._bodyEnd),
                instructionAt(pending._handler),
                pending._catchOffset,
            );
        }

        auto staticData = allocateStaticData;
        resolveStaticAddresses(staticData);

        ClosureSlot[] closureSlots;
        if (_closureOffset != size_t.max)
            foreach (variable; _function.closureVars) {
                const slot = _closureLayout.slotOf(variable);
                closureSlots ~= ClosureSlot(
                    _layout.offsetOf(variable), slot.offset, slot.facts.size,
                );
            }

        const contextOffset = _layout.hiddenThis.variable is null
            ? size_t.max : _layout.hiddenThis.parameter.offset;
        return Function(
            _instructions, _constants, _callSites, _assertSites,
            exceptionHandlers,
            staticData,
            _tempSize, _tempAlignment,
            _closureOffset, contextOffset,
            _closureOffset == size_t.max ? 0 : _closureLayout.size,
            _closureOffset == size_t.max ? 1 : _closureLayout.alignment,
            closureSlots,
        );
    }

    private const(Instruction)* instructionAt(in size_t index) const {
        return cast(const(Instruction)*) (_instructions.ptr + index);
    }

    private void emit(
        Instruction.Handler handler,
        in size_t destination,
        in size_t source,
        in size_t width,
        in size_t sourceWidth = 0,
    ) {
        _instructions ~= Instruction(
            handler, destination, source, width, sourceWidth);
    }

    private size_t addConstant(in long value) {
        _constants ~= value;
        return _constants.length - 1;
    }

    private ubyte[] allocateStaticData() {
        if (_staticInitialValue.length == 0)
            return null;

        auto block = new ubyte[
            _staticInitialValue.length + _staticAlignment - 1];
        const start = -cast(size_t) block.ptr & (_staticAlignment - 1);
        auto data = block[start .. start + _staticInitialValue.length];
        data[] = _staticInitialValue[];
        return data;
    }

    private void resolveStaticAddresses(ubyte[] staticData) {
        if (staticData is null)
            return;

        foreach (ref instruction; _instructions) {
            size_t* address;
            if (instruction.handler is &opStaticLoad
                    || instruction.handler is &opStaticAddress)
                address = &instruction.source;
            else if (instruction.handler is &opStaticStore)
                address = &instruction.destination;
            else
                continue;

            *address = cast(size_t) (staticData.ptr + *address);
        }
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
    // `compileIf`/`compileFor`/`compileContinue` patch
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

    private void compileStatements(Statements)(Statements* statements) {
        if (statements is null)
            return;

        foreach (child; *statements) {
            compileStatement(child);
            if (_finished)
                return;
        }
    }

    extern(C++):

    override void visit(Statement statement) {
        throw rejection(_function, statement.loc, statementText(statement));
    }

    override void visit(CompoundStatement statement) {
        compileStatements(statement.statements);
    }

    // dmd unrolls a `foreach` over a tuple (an `AliasSeq`, `static
    // foreach`'s own arguments) into one statement per element at
    // semantic time - see `makeTupleForeach` in `statementsem.d` - so
    // there is no run time loop left to compile, only this fixed sequence
    // of already-distinct statements. A `continue` there still needs a
    // real jump, the same as `compileFor`'s: it must skip only the rest
    // of the current element, landing on the next element's own first
    // instruction (or, from the last element, after the whole
    // statement) rather than falling into whatever the current element
    // was itself about to skip (an `else`, a `catch` handler, the next
    // `case`).
    override void visit(UnrolledLoopStatement statement) {
        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        if (statement.statements is null) {
            _finished = false;
            return;
        }

        _loops ~= LoopContext(label);
        _breakables ~= Breakable(label);

        bool lastFinished;
        foreach (child; *statement.statements) {
            resolveContinues(_instructions.length);
            _finished = false;
            compileStatement(child);
            lastFinished = _finished;
        }
        const hadContinue = _loops[$ - 1].pendingContinueJumps.length > 0;
        resolveContinues(_instructions.length);

        const breakable = _breakables[$ - 1];
        _breakables = _breakables[0 .. $ - 1];
        _loops = _loops[0 .. $ - 1];

        const afterLoop = _instructions.length;
        foreach (index; breakable.pendingBreakJumps)
            patchTarget(index, afterLoop);

        _finished = lastFinished && !hadContinue
            && breakable.pendingBreakJumps.length == 0;
    }

    // `do`-`while` always runs its own body once before the condition is
    // ever checked, so - unlike `compileFor` - there is no upfront branch
    // to skip the body with, only a trailing one that decides whether to
    // run it again. `continue` still needs a target distinct from that
    // trailing branch itself: the spec sends it to the condition check,
    // not back to the body's own start, so a `continue` reached before
    // the condition is compiled queues its own jump the same way
    // `compileFor`'s does for its increment.
    override void visit(DoStatement statement) {
        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        const bodyStart = _instructions.length;

        _loops ~= LoopContext(label);
        _breakables ~= Breakable(label);
        compileStatement(statement._body);
        const bodyFinished = _finished;
        const breakable = _breakables[$ - 1];
        _breakables = _breakables[0 .. $ - 1];
        const hadContinue = _loops[$ - 1].pendingContinueJumps.length > 0;
        _finished = false;

        const conditionIndex = _instructions.length;
        resolveContinues(conditionIndex);
        _loops = _loops[0 .. $ - 1];

        // See `compileFor`'s own doc for why a trivially-true condition
        // is never guarded - here that means the trailing check becomes
        // an unconditional jump back to the body instead of a real test.
        const guarded = !isTriviallyTrueCondition(statement.condition);
        if (guarded) {
            const conditionOffset = compileCondition(statement.condition);
            const width = conditionWidth(statement.condition);
            emit(&opBranchTrue, conditionOffset, bodyStart, width);
        } else {
            emit(&opJump, bodyStart, 0, 0);
        }

        const afterLoop = _instructions.length;
        foreach (index; breakable.pendingBreakJumps)
            patchTarget(index, afterLoop);

        // A body that returns on every path, with nothing left to
        // `continue` past it, never reaches the condition at all - the
        // whole loop is then finished the same way the body is, the
        // condition's own instructions being dead code nothing jumps
        // into.
        const hadBreak = breakable.pendingBreakJumps.length > 0;
        _finished = !hadBreak && (bodyFinished && !hadContinue || !guarded);
    }

    // `gotoTarget` is unset when dmd did not need to rewrite the labelled
    // statement, so the label names `statement.statement` itself then.
    override void visit(LabelStatement statement) {
        auto outerLabel = _pendingLabel; // auto: const(Identifier) will not implicitly convert back
        auto outerTarget = _pendingLabelTarget;
        _pendingLabel = statement.ident;
        _pendingLabelTarget = statement.gotoTarget !is null
            ? statement.gotoTarget : statement.statement;
        compileStatement(statement.statement);
        _pendingLabel = outerLabel;
        _pendingLabelTarget = outerTarget;
    }

    override void visit(ScopeStatement statement) {
        compileStatement(statement.statement);
    }

    override void visit(ImportStatement statement) {
    }

    override void visit(TryCatchStatement statement) {
        const bodyStart = _instructions.length;
        compileStatement(statement._body);
        const bodyFinished = _finished;
        const bodyEnd = _instructions.length;

        size_t skipHandlers = size_t.max;
        if (!bodyFinished) {
            skipHandlers = _instructions.length;
            emit(&opJump, 0, 0, 0);
        }

        bool allHandlersFinished = true;
        foreach (catch_; *statement.catches) {
            const handler = _instructions.length;
            const catchOffset = catch_.var is null
                ? size_t.max
                : _layout.offsetOf(catch_.var);
            auto type = runtimeClassInfo(catch_.type);
            _exceptionHandlers ~= PendingExceptionHandler(
                type, bodyStart, bodyEnd, handler, catchOffset,
            );

            _finished = false;
            compileStatement(catch_.handler);
            allHandlersFinished &= _finished;
        }

        if (skipHandlers != size_t.max)
            _instructions[skipHandlers].destination = _instructions.length;

        _finished = bodyFinished && allHandlersFinished;
    }

    override void visit(TryFinallyStatement statement) {
        compileStatement(statement._body);
        if (_finished)
            throw rejection(_function, statement.loc, statementText(statement));

        compileStatement(statement.finalbody);
    }

    override void visit(ThrowStatement statement) {
        import dmd.astenums: Tclass;

        if (statement.exp is null || statement.exp.type.ty != Tclass)
            throw rejection(_function, statement.loc, statementText(statement));

        const facts = TypeFacts.of(statement.exp.type);
        const offset = reserveTemp(facts);
        evalInto(statement.exp, offset, facts.size);
        emit(&opThrow, offset, 0, 0);
        _finished = true;
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

    override void visit(ForStatement statement) {
        compileFor(statement);
    }

    override void visit(ContinueStatement statement) {
        compileContinue(statement);
    }

    // A `switch` on a string is fully gone by the time this compiler ever
    // sees the `SwitchStatement`: dmd's own semantic pass rewrites
    // `condition` into a call to druntime's `object.__switch`, which
    // returns the matching case's index as a plain `int`, and rewrites
    // every `case` expression into that same index - see
    // `visitSwitch`/`visitCase` in dmd's `statementsem.d`. That call
    // compiles through the ordinary `CallExp` path below like any other
    // native call, so nothing here treats a string `switch` differently
    // from an integral one. A `CaseRangeStatement` is gone the same way,
    // replaced by one `CaseStatement` per value in the range, chained by
    // fallthrough - this compiler never sees that node either.
    //
    // dmd also always resolves `hasDefault`/`sdefault` before semantic
    // returns: a `switch` with no `default:` of its own gets one
    // synthesised (an `assert(0)`, or a call to `object.__switch_error`),
    // so `statement.sdefault` is never null here, final or not.
    //
    // Case dispatch is a linear chain of equality tests against the
    // already-evaluated condition, each branching straight into its own
    // case's body once that body's own position is known (see
    // `recordCaseTarget`) - no jump table, since nothing about this
    // compiler's `Instruction` stream supports one.
    override void visit(SwitchStatement statement) {
        import snakebite.nativelayout: TypeFacts;

        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        const facts = TypeFacts.of(statement.condition.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, statement.loc, statementText(statement));

        const conditionOffset = reserveTemp(facts);
        evalInto(statement.condition, conditionOffset, facts.size);

        if (statement.cases !is null) {
            foreach (case_; *statement.cases) {
                if (case_.exp.isIntegerExp is null)
                    throw rejection(_function, case_.loc, statementText(case_));

                const testOffset = reserveTemp(facts);
                emit(&opCopy, testOffset, conditionOffset, facts.size);
                const literalOffset = reserveTemp(facts);
                emit(&opConstant, literalOffset,
                    addConstant(case_.exp.toInteger), facts.size);
                emit(&opEqual, testOffset, literalOffset, facts.size);

                const branchIndex = _instructions.length;
                emit(&opBranchTrue, testOffset, 0, 1);
                jumpToCase(case_, branchIndex);
            }
        }

        if (statement.sdefault is null)
            throw rejection(_function, statement.loc, statementText(statement));

        const defaultJumpIndex = _instructions.length;
        emit(&opJump, 0, 0, 0);
        jumpToDefault(statement, defaultJumpIndex);

        _breakables ~= Breakable(label);
        _switchStack ~= statement;
        compileSwitchBody(statement._body);
        const bodyFinished = _finished;
        const hadBreak = _breakables[$ - 1].pendingBreakJumps.length > 0;

        const afterSwitch = _instructions.length;
        foreach (index; _breakables[$ - 1].pendingBreakJumps)
            patchTarget(index, afterSwitch);

        _switchStack = _switchStack[0 .. $ - 1];
        _breakables = _breakables[0 .. $ - 1];

        _finished = !hadBreak && bodyFinished;
    }

    override void visit(CaseStatement statement) {
        recordCaseTarget(statement);
        _finished = false;
        compileStatement(statement.statement);
    }

    override void visit(DefaultStatement statement) {
        if (_switchStack.length == 0)
            throw rejection(_function, statement.loc, statementText(statement));

        recordDefaultTarget(_switchStack[$ - 1]);
        _finished = false;
        compileStatement(statement.statement);
    }

    override void visit(GotoCaseStatement statement) {
        if (statement.cs is null)
            throw rejection(_function, statement.loc, statementText(statement));

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        jumpToCase(statement.cs, index);
        _finished = true;
    }

    override void visit(GotoDefaultStatement statement) {
        if (statement.sw is null)
            throw rejection(_function, statement.loc, statementText(statement));

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        jumpToDefault(statement.sw, index);
        _finished = true;
    }

    // dmd's own synthesised "no case matched" default (see
    // `visit(SwitchStatement)`'s own doc) wraps a call to
    // `object.__switch_error` already resolved to a real
    // `FuncDeclaration` - compiled the same way any other call to a
    // function this compiler did not itself compile is, through the
    // native FFI boundary in `compileCall`.
    override void visit(SwitchErrorStatement statement) {
        if (statement.exp !is null)
            compileEffect(statement.exp);

        _finished = true;
    }

    override void visit(BreakStatement statement) {
        if (_breakables.length == 0)
            throw rejection(_function, statement.loc, statementText(statement));

        const target = findBreakableIndex(statement.ident);
        if (target == size_t.max)
            throw rejection(_function, statement.loc, statementText(statement));

        const index = _instructions.length;
        emit(&opJump, 0, 0, 0);
        _breakables[target].pendingBreakJumps ~= index;
        _finished = true;
    }

    extern(D):

    private TypeInfo_Class runtimeClassInfo(Type type) {
        import dmd.astenums: Tclass;
        import std.conv: text;

        if (type.ty != Tclass)
            throw new SnakebiteException(text(
                "bytecode compiler cannot compile a non-class catch type `",
                type.toString, "`",
            ));

        auto info = cast(TypeInfo_Class) cast() _bytecode.runtimeTypeInfo(type);
        if (info is null)
            throw new SnakebiteException(text(
                "bytecode compiler cannot resolve catch type `",
                type.toString, "`",
            ));
        return info;
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

        if (_isRefReturn) {
            const addressOffset = compileAddress(statement.exp);
            emit(&opReturn, 0, addressOffset, size_t.sizeof);
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
        import dmd.astenums: Tpointer;

        const facts = TypeFacts.of(condition.type);
        if (facts.isDynamicArray) {
            const arrayOffset = reserveTemp(facts);
            evalInto(condition, arrayOffset, facts.size);
            return arrayOffset + arrayPointerOffset;
        }

        if (condition.type.ty == Tpointer)
            return compilePointerCondition(condition, facts);

        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, condition.loc,
                expressionText(condition));

        const offset = reserveTemp(facts);
        evalInto(condition, offset, facts.size);
        return offset;
    }

    private size_t compilePointerCondition(
        Expression condition, in TypeFacts facts,
    ) {
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
    private void compileAssert(AssertExp expression) {
        import dmd.astenums: Tnoreturn;
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
        _finished = expression.type.ty == Tnoreturn;
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

    // Claims the pending label only when `statement` is what dmd resolved
    // it to, not merely the first breakable construct compiled while one
    // is pending.
    private Identifier consumeLabel(Statement statement) {
        if (_pendingLabelTarget !is statement)
            return null;

        auto label = _pendingLabel;
        _pendingLabel = null;
        _pendingLabelTarget = null;
        return label;
    }

    private void compileFor(ForStatement statement) {
        auto label = consumeLabel(statement); // auto: const(Identifier) will not implicitly convert back
        if (statement._init !is null)
            compileStatement(statement._init);

        // A condition that can never be false - `while (1)`, always
        // rewritten by dmd to a `for` (see `visitWhile` in
        // `statementsem.d`), or a bare `for (;;)` - is never guarded: the
        // check itself would still compile correctly, but its false
        // branch would then target the position right after this loop's
        // own last instruction, which exists only when something follows
        // the loop in source. Nothing does when a trivially-true loop is
        // a function's own last statement (its body returns
        // unconditionally instead), and a branch aimed one past the last
        // instruction is exactly what `resolveBranches` exists to catch.
        // A `break` inside such a loop still lands somewhere real:
        // `build` appends a trailing `opReturnVoid` at that exact
        // position whenever nothing else already made it reachable.
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

        _loops ~= LoopContext(label);
        _breakables ~= Breakable(label);
        compileStatement(statement._body);
        const breakable = _breakables[$ - 1];
        _breakables = _breakables[0 .. $ - 1];
        _finished = false;

        const incrementIndex = _instructions.length;
        resolveContinues(incrementIndex);
        _loops = _loops[0 .. $ - 1];

        if (statement.increment !is null)
            compileEffect(statement.increment);

        emit(&opJump, conditionIndex, 0, 0);

        const afterLoop = _instructions.length;
        if (branchIndex != size_t.max)
            _instructions[branchIndex].source = afterLoop;

        foreach (index; breakable.pendingBreakJumps)
            patchTarget(index, afterLoop);

        _finished = !guarded && breakable.pendingBreakJumps.length == 0;
    }

    // dmd resolves neither `break ident` nor `continue ident` to a
    // target itself, only confirming one exists (`checkLabeledLoop` in
    // `statementsem.d`), so this compiler searches outward by identifier
    // for the entry a legally-typed program guarantees is there.
    private size_t findLoopIndex(Identifier label) {
        if (label is null)
            return _loops.length - 1;

        foreach_reverse (i, ref loop; _loops)
            if (loop.label is label)
                return i;

        return size_t.max;
    }

    private size_t findBreakableIndex(Identifier label) {
        if (label is null)
            return _breakables.length - 1;

        foreach_reverse (i, ref breakable; _breakables)
            if (breakable.label is label)
                return i;

        return size_t.max;
    }

    private void compileContinue(ContinueStatement statement) {
        if (_loops.length == 0)
            throw rejection(_function, statement.loc, statementText(statement));

        const index = findLoopIndex(statement.ident);
        if (index == size_t.max)
            throw rejection(_function, statement.loc, statementText(statement));

        const target = _loops[index].continueTarget;
        if (target != size_t.max) {
            emit(&opJump, target, 0, 0);
        } else {
            _loops[index].pendingContinueJumps ~= _instructions.length;
            emit(&opJump, 0, 0, 0);
        }

        _finished = true;
    }

    private void resolveContinues(in size_t target) {
        foreach (index; _loops[$ - 1].pendingContinueJumps)
            _instructions[index].destination = target;
        _loops[$ - 1].pendingContinueJumps = [];
    }

    // A `switch`'s own body is, once every `ScopeStatement`/
    // `CompoundStatement` wrapper around it is looked through, a flat
    // sequence of `CaseStatement`/`DefaultStatement` (and, when dmd had
    // to synthesise a missing `default:`, a plain statement or two
    // alongside them - see `visit(SwitchStatement)`'s own doc) each
    // holding only its own case's statements - fallthrough is simply the
    // next one's instructions following on directly, with nothing to jump
    // over.
    // `parseStatement`'s own `ParseStatementFlags.scope_` wraps every
    // curly-braced body in a `ScopeStatement`, the same as a
    // `while`/`for`'s own body, and dmd's synthesised default wraps the
    // original body and its own `DefaultStatement` in one more
    // `CompoundStatement` that never itself goes through semantic's
    // usual flattening - so this looks through as many layers of either
    // as are actually there, rather than assuming exactly one.
    // `compileStatement`/`compileStatements` on their own would skip a
    // sibling, at any of these layers, once `_finished` was left set by
    // an earlier one (a `break`, a `return`) - exactly wrong here, since
    // an earlier case ending that way must not hide a later one's own
    // instructions, which a jump from elsewhere in the `switch` may
    // still target.
    private void compileSwitchBody(Statement body_) {
        if (body_ is null)
            return;

        if (auto scope_ = body_.isScopeStatement()) {
            compileSwitchBody(scope_.statement);
            return;
        }

        if (auto compound = body_.isCompoundStatement()) {
            foreach (child; *compound.statements) {
                _finished = false;
                compileSwitchBody(child);
            }
            return;
        }

        _finished = false;
        compileStatement(body_);
    }

    private void jumpToCase(CaseStatement case_, in size_t instructionIndex) {
        if (auto target = case_ in _caseTargets) {
            patchTarget(instructionIndex, *target);
            return;
        }

        _pendingCaseJumps ~= PendingCaseJump(instructionIndex, case_);
    }

    private void recordCaseTarget(CaseStatement case_) {
        const target = _instructions.length;
        _caseTargets[case_] = target;

        size_t i = 0;
        while (i < _pendingCaseJumps.length) {
            if (_pendingCaseJumps[i].case_ !is case_) {
                ++i;
                continue;
            }

            patchTarget(_pendingCaseJumps[i].instructionIndex, target);
            _pendingCaseJumps =
                _pendingCaseJumps[0 .. i] ~ _pendingCaseJumps[i + 1 .. $];
        }
    }

    private void jumpToDefault(
        SwitchStatement switch_, in size_t instructionIndex,
    ) {
        if (auto target = switch_ in _defaultTargets) {
            patchTarget(instructionIndex, *target);
            return;
        }

        _pendingDefaultJumps ~= PendingDefaultJump(instructionIndex, switch_);
    }

    private void recordDefaultTarget(SwitchStatement switch_) {
        const target = _instructions.length;
        _defaultTargets[switch_] = target;

        size_t i = 0;
        while (i < _pendingDefaultJumps.length) {
            if (_pendingDefaultJumps[i].switch_ !is switch_) {
                ++i;
                continue;
            }

            patchTarget(_pendingDefaultJumps[i].instructionIndex, target);
            _pendingDefaultJumps =
                _pendingDefaultJumps[0 .. i] ~ _pendingDefaultJumps[i + 1 .. $];
        }
    }

    // Patches a still-pending `opJump`/`opBranchTrue`/`opBranchFalse`
    // this compiler itself emitted with the instruction index its own
    // target is now known to start at - the same instruction-index
    // currency `resolveBranches` later turns into a real address, via
    // the same field each opcode keeps it in (`branchTargetField`).
    private void patchTarget(in size_t instructionIndex, in size_t target) {
        auto field = branchTargetField(_instructions[instructionIndex]);
        assert(field !is null);
        *field = target;
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
        // These declarations bind names for the semantic pass but have no
        // runtime action, the same way an `import` inside a function body
        // does.
        if (expression.declaration.isStructDeclaration !is null
                || expression.declaration.isAliasDeclaration !is null
                || expression.declaration.isTemplateDeclaration !is null
                || expression.declaration.isFuncDeclaration !is null
                || expression.declaration.isEnumDeclaration !is null)
            return;

        auto variable = expression.declaration.isVarDeclaration;
        if (variable is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (variable.isDataseg) {
            staticOffsetOf(variable);
            return;
        }

        // dmd always installs an `ExpInitializer` holding the type's own
        // default value for a function local with no initialiser written -
        // `int ret;` and `int ret = 0;` reach here the same way. Zero is
        // also the wrong default for some of the integral types this
        // compiler accepts (`char.init`/`wchar.init` are `0xFF`/`0xFFFF`,
        // not zero), so there is no "blit to zero" case of its own to
        // handle here, only this invariant to assert.
        assert(variable._init !is null,
            "a local variable declaration with no initializer at all");

        if (variable._init.isVoidInitializer !is null)
            return;

        auto expInitializer = variable._init.isExpInitializer;
        if (expInitializer is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        auto initializer = initializerValueOf(expInitializer);
        auto nativeCall = initializer.isCallExp;
        // A native aggregate return already writes directly to caller-owned
        // storage. It does not need the bytewise copy path, which is only
        // valid for plain-old structs.
        const nativeAggregateReturn = variable.type.isTypeStruct !is null
            && nativeCall !is null && nativeCall.f !is null
            && (nativeCall.f.fbody is null
                || _bytecode.hasNativeSymbol(nativeCall.f));
        if (!isSupportedFacts(facts, variable.type)
                && !nativeAggregateReturn)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (isClosureVariable(variable)) {
            const slot = _closureLayout.slotOf(variable);
            const target = closureSlotAddress(slot.offset);
            if (slot.isRef) {
                const addressOffset = compileAddress(initializerValueOf(
                    expInitializer));
                emit(&opStoreIndirect, target, addressOffset,
                    size_t.sizeof);
            } else {
                const valueOffset = reserveTemp(facts);
                evalInto(
                    nativeAggregateReturn ? initializer : expInitializer.exp,
                    valueOffset, facts.size,
                );
                emit(&opStoreIndirect, target, valueOffset, facts.size);
            }
            return;
        }

        const offset = _layout.offsetOf(variable);

        // `foreach (ref value; values) ...` declares `value` afresh each
        // iteration, bound to `values[i]`'s own storage - the same `ref`
        // local shape a `ref int x = y;` written by hand has. Its own
        // slot holds `y`'s address, not `y`'s value, so this stores the
        // address `compileAddress` computes rather than evaluating the
        // initialiser as a value the way a by-value local's is.
        if (_layout.isRef(variable)) {
            const addressOffset = compileAddress(initializerValueOf(expInitializer));
            emit(&opCopy, offset, addressOffset, size_t.sizeof);
            return;
        }

        evalInto(
            nativeAggregateReturn ? initializer : expInitializer.exp,
            offset,
            facts.size,
        );
    }

    // Reserves one native-layout slot for a function-local static and stores
    // its constant initializer in the same layout. A static initializer is
    // part of the compiled function's persistent data, so the declaration
    // statement itself has no per-call instruction to run.
    private size_t staticOffsetOf(VarDeclaration variable) {
        import dmd.typesem: defaultInit;
        import std.conv: text;

        if (auto found = variable in _staticSlots)
            return found._offset;

        if (!variable.isDataseg)
            throw rejection(_function, variable.loc,
                text("the variable `", variable.toString, "`"));

        const facts = TypeFacts.of(variable.type);
        if (!isSupportedFacts(facts, variable.type))
            throw rejection(_function, variable.loc,
                text("the variable `", variable.toString, "`"));

        auto initializer = variable._init is null
            ? null : variable._init.isExpInitializer;
        if (variable._init !is null && initializer is null)
            throw rejection(_function, variable.loc, text(
                "the variable `", variable.toString, "`",
            ));
        auto value = initializer is null
            ? defaultInit(variable.type, variable.loc)
            : initializerValueOf(initializer);
        if (!isSupportedStaticInitializer(variable.type, facts, value))
            throw rejection(_function, variable.loc,
                text("the variable `", variable.toString, "`"));

        const offset = alignUp(_staticInitialValue.length, facts.alignment);
        const end = offset + facts.size;
        _staticInitialValue.length = end;
        if (facts.alignment > _staticAlignment)
            _staticAlignment = facts.alignment;
        _staticSlots[variable] = StaticSlot(offset);

        storeValue(
            variable.type,
            facts,
            value,
            _staticInitialValue.ptr + offset,
        );
        return offset;
    }

    private static bool isSupportedStaticInitializer(
        Type type,
        in TypeFacts facts,
        Expression value,
    ) {
        import dmd.astenums: Tarray;
        import dmd.expressionsem: toInteger;
        import dmd.typesem: nextOf, size;
        import snakebite.nativelayout: arrayValueSize;

        if (value.isNullExp !is null)
            return true;

        if (auto literal = value.isStringExp) {
            auto element = type.nextOf;
            return type.ty == Tarray && facts.size == arrayValueSize
                && element !is null && literal.sz == element.size;
        }

        if (isFloatingType(type))
            return value.isRealExp !is null;

        if (type.isTypeStruct !is null) {
            auto integer = value.isIntegerExp;
            return integer !is null && integer.toInteger == 0;
        }

        return facts.isIntegral && value.isIntegerExp !is null;
    }

    // A `ref` local's `ExpInitializer` holds a full `value = target`
    // assignment (a `ConstructExp`, dmd's node for initialising storage the
    // guest has not touched yet) rather than bare `target` the way a
    // by-value local's does - `compileAddress` wants `target` alone, the
    // right side that names the storage to bind to. Unwrapped the same way
    // `snakebite.backends.layout`'s own `collectDeclarations` already does
    // for the temporaries `~=`'s lowering leaves the same way.
    private Expression initializerValueOf(ExpInitializer expInitializer) {
        auto value = expInitializer.exp;
        if (auto construct = value.isConstructExp)
            return construct.e2;
        if (auto blit = value.isBlitExp)
            return blit.e2;
        return value;
    }

    // A plain `=` to a local or parameter. `destOffset` is where the
    // assignment's own value (D specifies an assignment as an expression)
    // goes too, `discardResult` when a caller at statement level has
    // nowhere for it and does not want it.
    private void compileAssign(AssignExp expression, in size_t destOffset) {
        if (auto indexTarget = expression.e1.isIndexExp)
            return compileIndexAssign(expression, indexTarget, destOffset);

        // `pick(a, b, true) = 5;`: the call's own return is `ref`, an
        // lvalue naming whichever of its own arguments it picked, not a
        // value of its own - the same address `compileAddress`'s own
        // `CallExp` case already knows how to compile.
        if (auto callTarget = expression.e1.isCallExp)
            return compileIndirectAssign(expression, callTarget, destOffset);
        if (auto fieldTarget = expression.e1.isDotVarExp)
            return compileFieldAssign(expression, fieldTarget, destOffset);

        if (auto ptrTarget = expression.e1.isPtrExp)
            return compileIndirectAssign(expression, ptrTarget, destOffset);

        auto varExp = expression.e1.isVarExp;
        auto variable = varExp is null ? null : varExp.var.isVarDeclaration;
        if (variable is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (isThisField(variable))
            return compileIndirectAssign(expression, varExp, destOffset);

        const facts = TypeFacts.of(variable.type);
        if (!isSupportedFacts(facts, variable.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (variable.isDataseg) {
            const valueOffset = reserveTemp(facts);
            evalInto(expression.e2, valueOffset, facts.size);
            emitStaticStore(variable, valueOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

        if (_layout.isRef(variable))
            return compileIndirectAssign(expression, varExp, destOffset);

        if (!_layout.hasSlot(variable) || isClosureVariable(variable)) {
            const refOffset = addressOfVariable(variable);
            const valueOffset = reserveTemp(facts);
            evalInto(expression.e2, valueOffset, facts.size);
            emit(&opStoreIndirect, refOffset, valueOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

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

    private void emitStaticStore(
        VarDeclaration variable,
        in size_t sourceOffset,
        in size_t width,
    ) {
        emit(&opStaticStore, staticOffsetOf(variable), sourceOffset, width);
    }

    private bool isThisField(VarDeclaration variable) const {
        auto aggregate = variable.toParent2;
        auto thisAggregate = _function.isThis;
        return thisAggregate !is null
            && thisAggregate.isStructDeclaration !is null
            && aggregate is thisAggregate;
    }

    private bool isClosureVariable(VarDeclaration variable) const {
        return _closureOffset != size_t.max
            && _closureLayout.hasSlot(variable);
    }

    private FuncDeclaration outerFunctionOf(VarDeclaration variable) const {
        auto parent = variable.toParent2();
        return parent is null ? null : parent.isFuncDeclaration;
    }

    private bool functionNeedsClosure(FuncDeclaration function_) const {
        import dmd.funcsem: needsClosure;

        return function_.needsClosure();
    }

    private size_t addPointerOffset(
        in size_t pointerOffset,
        in size_t byteOffset,
    ) {
        if (byteOffset == 0)
            return pointerOffset;

        const offset = reserveTemp(pointerFacts);
        emit(&opConstant, offset, addConstant(cast(long) byteOffset),
            size_t.sizeof);
        emit(&opAdd, pointerOffset, offset, size_t.sizeof);
        return pointerOffset;
    }

    // The context of `owner`, as a pointer value in a temporary frame slot.
    // A closure's first word links to its parent context. A non-closure
    // nested frame stores that link in its hidden `vthis` slot.
    private size_t contextAddressOf(FuncDeclaration owner) {
        if (owner is _function) {
            if (_closureOffset != size_t.max)
                return _closureOffset;

            const result = reserveTemp(pointerFacts);
            emit(&opFrameAddress, result, 0, size_t.sizeof);
            return result;
        }

        auto parent = _function.toParent2();
        auto current = parent is null ? null : parent.isFuncDeclaration;
        if (current is null)
            throw rejection(_function, _function.loc, "a static chain");

        const result = reserveTemp(pointerFacts);
        emit(&opCopy, result,
            _layout.hiddenThis.parameter.offset, size_t.sizeof);

        while (current !is owner) {
            if (functionNeedsClosure(current)) {
                emit(&opLoadIndirect, result, result, size_t.sizeof);
            } else {
                const layout = FrameLayout.of(current);
                if (layout.hiddenThis.variable is null)
                    throw rejection(_function, _function.loc,
                        "a static chain");

                const offset = reserveTemp(pointerFacts);
                emit(&opConstant, offset,
                    addConstant(cast(long)
                        layout.hiddenThis.parameter.offset), size_t.sizeof);
                emit(&opAdd, result, offset, size_t.sizeof);
                emit(&opLoadIndirect, result, result, size_t.sizeof);
            }

            auto next = current.toParent2();
            current = next is null ? null : next.isFuncDeclaration;
            if (current is null)
                throw rejection(_function, _function.loc, "a static chain");
        }

        return result;
    }

    // The address of a variable's storage as a pointer value in a frame
    // slot. A ref variable is indirected here, so all callers see the
    // storage it refers to rather than its pointer slot.
    private size_t addressOfVariable(VarDeclaration variable) {
        if (isClosureVariable(variable)) {
            const slot = _closureLayout.slotOf(variable);
            auto result = closureSlotAddress(slot.offset);
            if (slot.isRef)
                emit(&opLoadIndirect, result, result, size_t.sizeof);
            return result;
        }

        auto owner = outerFunctionOf(variable);
        if (owner is _function) {
            if (_layout.isRef(variable))
                return _layout.offsetOf(variable);

            const result = reserveTemp(pointerFacts);
            emit(&opFrameAddress, result, _layout.offsetOf(variable),
                size_t.sizeof);
            return result;
        }

        if (owner is null)
            throw rejection(_function, variable.loc, "a local variable");

        auto context = contextAddressOf(owner);
        if (functionNeedsClosure(owner)) {
            const closure = ClosureLayout.of(owner);
            if (closure.hasSlot(variable)) {
                const slot = closure.slotOf(variable);
                context = addPointerOffset(context, slot.offset);
                if (slot.isRef)
                    emit(&opLoadIndirect, context, context, size_t.sizeof);
                return context;
            }
        }

        const layout = FrameLayout.of(owner);
        if (!layout.hasSlot(variable))
            throw rejection(_function, variable.loc, "a local variable");

        context = addPointerOffset(context, layout.offsetOf(variable));
        if (layout.isRef(variable))
            emit(&opLoadIndirect, context, context, size_t.sizeof);
        return context;
    }

    private size_t closureSlotAddress(in size_t offset) {
        const closure = reserveTemp(pointerFacts);
        emit(&opCopy, closure, _closureOffset, size_t.sizeof);
        return addPointerOffset(closure, offset);
    }

    private size_t hiddenThisOffset(VarDeclaration variable = null) {
        auto hiddenThis = variable is null
            ? cast() _layout.hiddenThis.variable
            : variable;
        if (hiddenThis is null || !_layout.isRef(hiddenThis))
            throw rejection(_function, _function.loc, "a struct `this`");

        return _layout.offsetOf(hiddenThis);
    }

    private size_t compileThisFieldAddress(VarDeclaration field) {
        const addressOffset = hiddenThisOffset;
        if (field.offset == 0)
            return addressOffset;

        const fieldOffset = reserveTemp(pointerFacts);
        emit(&opConstant, fieldOffset,
            addConstant(cast(long) field.offset), size_t.sizeof);
        emit(&opAdd, fieldOffset, addressOffset, size_t.sizeof);
        return fieldOffset;
    }

    // `*p = value` in every guise this compiler reaches it through: a `ref`
    // variable's own target, or a `ref`-returning call's own result.
    // `compileAddress` already knows how to compile either lvalue's
    // address; this only adds the store once that address is in hand, the
    // same split `visit(IndexExp)`/`compileIndexAssign` already share for
    // an array element.
    private void compileIndirectAssign(
        AssignExp expression, Expression target, in size_t destOffset,
    ) {
        const facts = TypeFacts.of(expression.e1.type);
        if (!isSupportedFacts(facts, expression.e1.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const addressOffset = compileAddress(target);
        const valueOffset = reserveTemp(facts);
        evalInto(expression.e2, valueOffset, facts.size);
        emit(&opStoreIndirect, addressOffset, valueOffset, facts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, facts.size);
    }

    // `s.field = value`, with the target address computed from the receiver
    // lvalue. This also covers a method's implicit field (`_bytes`) and a
    // field reached through `this`, so writes update the caller's struct.
    private void compileFieldAssign(
        AssignExp expression, DotVarExp target, in size_t destOffset,
    ) {
        auto field = target.var.isVarDeclaration;
        if (field is null || field.isBitFieldDeclaration !is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(target.type);
        if (!isSupportedFacts(facts, target.type))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const addressOffset = compileFieldAddress(target);
        const valueOffset = reserveTemp(facts);
        evalInto(expression.e2, valueOffset, facts.size);
        emit(&opStoreIndirect, addressOffset, valueOffset, facts.size);

        if (destOffset != discardResult)
            emit(&opCopy, destOffset, valueOffset, facts.size);
    }

    private size_t compileFieldAddress(DotVarExp expression) {
        import dmd.astenums: Tclass;

        auto field = expression.var.isVarDeclaration;
        if (field is null || field.isBitFieldDeclaration !is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        size_t addressOffset;
        if (expression.e1.type.ty == Tclass) {
            addressOffset = reserveTemp(pointerFacts);
            evalInto(expression.e1, addressOffset, size_t.sizeof);
        } else {
            if (expression.e1.type.isTypeStruct is null)
                throw rejection(_function, expression.loc,
                    expressionText(expression));
            addressOffset = compileAddress(expression.e1);
        }

        if (field.offset == 0)
            return addressOffset;

        const fieldOffset = reserveTemp(pointerFacts);
        emit(&opConstant, fieldOffset,
            addConstant(cast(long) field.offset), size_t.sizeof);
        emit(&opAdd, fieldOffset, addressOffset, size_t.sizeof);
        return fieldOffset;
    }

    // `arr[i] = value`. `opStoreIndirect` writes `facts.size` bytes
    // wherever `expression.e2` evaluated to, whatever that width is - a
    // scalar or a whole plain-old struct - so this needs no case of its
    // own for either.
    private void compileIndexAssign(
        AssignExp expression, IndexExp target, in size_t destOffset,
    ) {
        const arrayFacts = TypeFacts.of(target.e1.type);
        if (!arrayFacts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(expression.e1.type);
        if (!isSupportedFacts(facts, expression.e1.type))
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
        if (variable is null)
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

        const rightOffset = reserveTemp(facts);
        evalInto(expression.e2, rightOffset, facts.size);

        if (variable.isDataseg) {
            const valueOffset = reserveTemp(facts);
            emitStaticLoad(variable, valueOffset, facts.size);
            emit(handler, valueOffset, rightOffset, facts.size);
            emitStaticStore(variable, valueOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

        // A `ref` target, a captured variable, or a variable in an outer
        // frame is reached through its storage address. Read and write
        // through that address so the operation changes the variable's
        // value, not a context pointer or a ref slot.
        if (!_layout.hasSlot(variable) || isClosureVariable(variable)
                || _layout.isRef(variable)) {
            const refOffset = addressOfVariable(variable);
            const valueOffset = reserveTemp(facts);
            emit(&opLoadIndirect, valueOffset, refOffset, facts.size);
            emit(handler, valueOffset, rightOffset, facts.size);
            emit(&opStoreIndirect, refOffset, valueOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);
            return;
        }

        const varOffset = _layout.offsetOf(variable);
        emit(handler, varOffset, rightOffset, facts.size);

        if (destOffset != discardResult && destOffset != varOffset)
            emit(&opCopy, destOffset, varOffset, facts.size);
    }

    private void emitStaticLoad(
        VarDeclaration variable,
        in size_t destinationOffset,
        in size_t width,
    ) {
        emit(&opStaticLoad, destinationOffset, staticOffsetOf(variable), width);
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
        if (variable is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const facts = TypeFacts.of(variable.type);
        if (!facts.isIntegral || !isIntegralSize(facts.size))
            throw rejection(_function, expression.loc,
                expressionText(expression));

        if (variable.isDataseg) {
            const valueOffset = reserveTemp(facts);
            emitStaticLoad(variable, valueOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);

            const stepOffset = reserveTemp(facts);
            evalInto(expression.e2, stepOffset, facts.size);

            auto handler = expression.op == EXP.plusPlus
                ? &opAdd : &opSubtract;
            emit(handler, valueOffset, stepOffset, facts.size);
            emitStaticStore(variable, valueOffset, facts.size);
            return;
        }

        if (!_layout.hasSlot(variable) || isClosureVariable(variable)) {
            const refOffset = addressOfVariable(variable);
            const valueOffset = reserveTemp(facts);
            emit(&opLoadIndirect, valueOffset, refOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);

            const stepOffset = reserveTemp(facts);
            evalInto(expression.e2, stepOffset, facts.size);

            auto handler = expression.op == EXP.plusPlus
                ? &opAdd : &opSubtract;
            emit(handler, valueOffset, stepOffset, facts.size);
            emit(&opStoreIndirect, refOffset, valueOffset, facts.size);
            return;
        }

        const varOffset = _layout.offsetOf(variable);

        if (_layout.isRef(variable)) {
            const valueOffset = reserveTemp(facts);
            emit(&opLoadIndirect, valueOffset, varOffset, facts.size);

            if (destOffset != discardResult)
                emit(&opCopy, destOffset, valueOffset, facts.size);

            const stepOffset = reserveTemp(facts);
            evalInto(expression.e2, stepOffset, facts.size);

            auto handler = expression.op == EXP.plusPlus
                ? &opAdd : &opSubtract;
            emit(handler, valueOffset, stepOffset, facts.size);
            emit(&opStoreIndirect, varOffset, valueOffset, facts.size);
            return;
        }

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

        // A zero-init struct's own `.init` is `IntegerExp(0)` - dmd's own
        // shorthand for "zero every byte", the same one
        // `nativelayout.storeValue` already special-cases for a struct
        // target. `opConstant`'s `storeWidth` only lays out up to 8 bytes,
        // the widest integral this compiler ever moves through a single
        // constant, so a wider destination (only ever a zero-init struct's
        // own slot; every other value this compiler evaluates is `long`s
        // sized or narrower) reaches for `opZero` instead.
        if (_width > long.sizeof) {
            if (expression.toInteger != 0)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            emit(&opZero, _destination, 0, _width);
            return;
        }

        emit(&opConstant, _destination,
            addConstant(expression.toInteger), _width);
    }

    // A `float`/`double` literal, as the raw bits `opConstant` writes -
    // `storeValue` already knows how to lay either width out (see its own
    // doc), so this only has to fold that same compile-time write into one
    // constant rather than reimplementing the float-to-bits conversion.
    // `real` is wider than the `long` a single constant carries, so it
    // instead folds into the two 8-byte halves of its own 16-byte native
    // layout, the same way `StringExp` below folds its own two words into
    // two separate constants.
    override void visit(RealExp expression) {
        import snakebite.nativelayout: storeValue;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.type);
        if (!isFloatingType(expression.type))
            return visit(cast(Expression) expression);

        if (_width > long.sizeof) {
            align(real.alignof) ubyte[real.sizeof] bits = 0;
            storeValue(expression.type, facts, expression, bits.ptr);
            auto halves = cast(const(long)*) bits.ptr;
            emit(&opConstant, _destination, addConstant(halves[0]),
                long.sizeof);
            emit(&opConstant, _destination + long.sizeof,
                addConstant(halves[1]), _width - long.sizeof);
            return;
        }

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
        if (_destination == discardResult)
            return;

        requireDestination(expression);
        auto variable = expression.var.isVarDeclaration;
        if (variable is null)
            return visit(cast(Expression) expression);

        if (variable.isDataseg) {
            emitStaticLoad(variable, _destination, _width);
            return;
        }

        if (isThisField(variable)) {
            const addressOffset = compileThisFieldAddress(variable);
            emit(&opLoadIndirect, _destination, addressOffset, _width);
            return;
        }

        // `$` inside an index has no frame slot of its own - dmd hands out
        // a fresh `VarDeclaration` for it that no statement declares
        // (`FrameLayout` never reserves it a slot for exactly that reason),
        // and `compileElementAddress` binds `_dollar` to the length it
        // stands for around evaluating the index expression it appears in.
        if (variable is _dollarVariable) {
            emit(&opCopy, _destination, _dollarOffset, _width);
            return;
        }

        if (!_layout.hasSlot(variable) || isClosureVariable(variable)) {
            const address = addressOfVariable(variable);
            emit(&opLoadIndirect, _destination, address, _width);
            return;
        }

        const source = _layout.offsetOf(variable);

        // A `ref` variable's own slot holds the address of the storage it
        // is bound to, not the storage itself - reading it means reading
        // through that address instead of the slot's own bytes, the one
        // place every plain variable read resolves this.
        if (_layout.isRef(variable)) {
            emit(&opLoadIndirect, _destination, source, _width);
            return;
        }

        if (source != _destination)
            emit(&opCopy, _destination, source, _width);
    }

    // `&variable`: dmd folds this straight into a `SymOffExp` naming the
    // variable and a byte offset into it, rather than wrapping a `VarExp`
    // in a general `AddrExp` - the address a `ref` return's own ternary
    // (`cond ? &a : &b`) is built from. A field offset (`offset != 0`) is
    // out of scope; only a whole variable's own address is supported.
    override void visit(SymOffExp expression) {
        requireDestination(expression);
        if (auto function_ = expression.var.isFuncDeclaration) {
            if (expression.offset != 0)
                return visit(cast(Expression) expression);

            // A guest function pointer's run-time value is the compiled
            // callee itself - the same `const(Function)*` `opCall` already
            // dereferences for an ordinary call - not `function_`'s own
            // address: the VM module never imports dmd's frontend (see
            // `ai/CODING.md`), so it has no `FuncDeclaration` to resolve
            // one from at call time; this is the only place that can.
            auto compiled = _bytecode.compileFunction(function_);
            emit(&opConstant, _destination,
                addConstant(cast(long) cast(size_t) compiled), _width);
            return;
        }

        auto variable = expression.var.isVarDeclaration;
        if (variable is null || expression.offset != 0)
            return visit(cast(Expression) expression);

        if (variable.isDataseg) {
            const addressOffset = compileStaticAddress(variable);
            if (addressOffset != _destination)
                emit(&opCopy, _destination, addressOffset, size_t.sizeof);
            return;
        }

        const addressOffset = addressOfVariable(variable);
        if (addressOffset != _destination)
            emit(&opCopy, _destination, addressOffset, size_t.sizeof);
    }

    override void visit(FuncExp expression) {
        requireDestination(expression);
        if (expression.fd is null)
            return visit(cast(Expression) expression);

        // Same run-time value as `visit(SymOffExp)`'s function case above:
        // the compiled callee, not the literal's own declaration.
        auto compiled = _bytecode.compileFunction(expression.fd);
        emit(&opConstant, _destination,
            addConstant(cast(long) cast(size_t) compiled), _width);
    }

    private size_t compileStaticAddress(VarDeclaration variable) {
        const addressOffset = reserveTemp(pointerFacts);
        emit(&opStaticAddress, addressOffset,
            staticOffsetOf(variable), size_t.sizeof);
        return addressOffset;
    }

    // `this` is a reference to a struct value. Its hidden slot contains the
    // receiver's address, so a value read loads the struct bytes through it.
    // A constructor can synthesize a `ThisExp` without a declaration; the
    // shared layout records the declaration in that case.
    override void visit(ThisExp expression) {
        requireDestination(expression);

        emit(&opLoadIndirect, _destination,
            hiddenThisOffset(expression.var),
            _width);
    }

    // The general `&expression` node: dmd only folds `&variable` into a
    // `SymOffExp` above when the variable is *not* itself `ref`
    // (`optimize.d`'s own `visitAddr`) - `&a` for a `ref` parameter `a`
    // stays this node instead, since its meaning is different: `a`'s own
    // slot already holds the address `&a` names, not a further
    // indirection into a pointer-to-pointer. `compileAddress` already
    // answers that same question for every lvalue this compiler reaches
    // through `ref` binding, so this is nothing more than that answer
    // copied to `_destination`.
    override void visit(AddrExp expression) {
        requireDestination(expression);

        const addressOffset = compileAddress(expression.e1);
        if (addressOffset != _destination)
            emit(&opCopy, _destination, addressOffset, size_t.sizeof);
    }

    override void visit(PtrExp expression) {
        requireDestination(expression);

        const addressOffset = compileAddress(expression);
        emit(&opLoadIndirect, _destination, addressOffset, _width);
    }

    // `s.field`, read as a value. `expression.e1` is evaluated into a
    // temporary of its own first, whatever kind of expression it is - a
    // local, an array element, another field access - the same way any
    // other sub-expression this compiler evaluates is; the field then
    // reads out of that temporary at its own `field.offset`, laid out by
    // dmd's own native semantics rather than recomputed here.
    override void visit(DotVarExp expression) {
        if (_destination == discardResult) {
            const facts = TypeFacts.of(expression.type);
            const offset = reserveTemp(facts);
            evalInto(expression, offset, facts.size);
            return;
        }

        requireDestination(expression);

        auto field = expression.var.isVarDeclaration;
        if (field is null || field.isBitFieldDeclaration !is null)
            return visit(cast(Expression) expression);

        import dmd.astenums: Tclass;
        if (expression.e1.type.ty == Tclass) {
            const facts = TypeFacts.of(field.type);
            if (!isSupportedFacts(facts, field.type))
                return visit(cast(Expression) expression);

            const objectOffset = reserveTemp(pointerFacts);
            evalInto(expression.e1, objectOffset, size_t.sizeof);
            const fieldOffset = reserveTemp(pointerFacts);
            emit(&opConstant, fieldOffset,
                addConstant(cast(long) field.offset), size_t.sizeof);
            emit(&opAdd, objectOffset, fieldOffset, size_t.sizeof);
            emit(&opLoadIndirect, _destination, objectOffset, _width);
            return;
        }

        if (expression.e1.type.isTypeStruct is null)
            return visit(cast(Expression) expression);

        const baseFacts = TypeFacts.of(expression.e1.type);
        const baseOffset = reserveTemp(baseFacts);
        evalInto(expression.e1, baseOffset, baseFacts.size);
        emit(&opCopy, _destination, baseOffset + field.offset, _width);
    }

    // `Point(3, 4)`, dmd's own literal form for a plain-old struct with no
    // user-defined constructor: every field evaluated directly into its
    // own slot at `field.offset` within `_destination`, zeroed first for
    // any field the literal itself leaves out - the same "zero, then fill
    // what is given" shape `compileNewArray`'s own default fill and
    // `StructLiteralExp.elements` sparseness both call for.
    override void visit(StructLiteralExp expression) {
        requireDestination(expression);

        if (!isPlainOldStruct(expression.type))
            return visit(cast(Expression) expression);

        emit(&opZero, _destination, 0, _width);

        if (expression.elements is null)
            return;

        foreach (i, element; *expression.elements) {
            if (element is null)
                continue;

            auto field = expression.sd.fields[i];
            const facts = TypeFacts.of(field.type);
            evalInto(element, _destination + field.offset, facts.size);
        }
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

    // `arr[]`: dmd's own `foreach` lowering over an array takes a bare
    // whole-array slice of it before iterating, to fix the range being
    // walked against mutation of the original variable during the loop.
    // A dynamic array's whole slice is the same two words as the array
    // itself, so it does not need the bounds work of a bounded slice.
    override void visit(SliceExp expression) {
        import dmd.astenums: Tpointer;
        import snakebite.nativelayout:
            arrayLengthOffset, arrayPointerOffset;
        import std.string: fromStringz;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.e1.type);
        if (expression.e1.type.ty == Tpointer
                && expression.upr !is null) {
            const pointerOffset = reserveTemp(facts);
            evalInto(expression.e1, pointerOffset, facts.size);

            const lowOffset = reserveTemp(pointerFacts);
            if (expression.lwr is null)
                emit(&opConstant, lowOffset, addConstant(0), size_t.sizeof);
            else
                evalOperandInto(expression.lwr, lowOffset, size_t.sizeof);

            const highOffset = reserveTemp(pointerFacts);
            evalOperandInto(expression.upr, highOffset, size_t.sizeof);
            emit(&opSubtract, highOffset, lowOffset, size_t.sizeof);
            emit(&opCopy, _destination + arrayLengthOffset, highOffset,
                size_t.sizeof);

            const elementFacts = TypeFacts.of(expression.e1.type.nextOf);
            const elementSizeOffset = reserveTemp(pointerFacts);
            emit(&opConstant, elementSizeOffset,
                addConstant(cast(long) elementFacts.size), size_t.sizeof);
            emit(&opMultiply, lowOffset, elementSizeOffset, size_t.sizeof);
            emit(&opAdd, pointerOffset, lowOffset, size_t.sizeof);
            emit(&opCopy, _destination + arrayPointerOffset, pointerOffset,
                size_t.sizeof);
            return;
        }

        if (!facts.isDynamicArray)
            return visit(cast(Expression) expression);

        if (expression.lwr is null && expression.upr is null) {
            evalInto(expression.e1, _destination, _width);
            return;
        }

        const arrayOffset = reserveTemp(facts);
        evalInto(expression.e1, arrayOffset, facts.size);

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

        const lowOffset = reserveTemp(pointerFacts);
        if (expression.lwr is null)
            emit(&opConstant, lowOffset, addConstant(0), size_t.sizeof);
        else
            evalOperandInto(expression.lwr, lowOffset, size_t.sizeof);

        const highOffset = reserveTemp(pointerFacts);
        if (expression.upr is null)
            emit(&opCopy, highOffset,
                arrayOffset + arrayLengthOffset, size_t.sizeof);
        else
            evalOperandInto(expression.upr, highOffset, size_t.sizeof);

        // D requires both bounds to be within the source array and the
        // lower bound to come first. Check before pointer arithmetic so a
        // bad slice cannot form an address outside the guest array.
        const orderOffset = reserveTemp(pointerFacts);
        emit(&opCopy, orderOffset, lowOffset, size_t.sizeof);
        emit(&opLessOrEqualUnsigned, orderOffset, highOffset, size_t.sizeof);
        const site = AssertSite(
            null,
            expression.loc.filename.fromStringz.idup,
            expression.loc.linnum,
        );
        _assertSites ~= site;
        const siteIndex = _assertSites.length - 1;
        emit(&opRangeError, orderOffset, siteIndex, 1);

        emit(&opCopy, orderOffset, highOffset, size_t.sizeof);
        emit(&opLessOrEqualUnsigned, orderOffset,
            arrayOffset + arrayLengthOffset, size_t.sizeof);
        emit(&opRangeError, orderOffset, siteIndex, 1);

        emit(&opCopy, _destination + arrayLengthOffset,
            highOffset, size_t.sizeof);
        emit(&opSubtract, _destination + arrayLengthOffset,
            lowOffset, size_t.sizeof);

        const byteOffsetOffset = reserveTemp(pointerFacts);
        emit(&opCopy, byteOffsetOffset, lowOffset, size_t.sizeof);
        const elementFacts = TypeFacts.of(expression.e1.type.nextOf);
        const elementSizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, elementSizeOffset,
            addConstant(cast(long) elementFacts.size), size_t.sizeof);
        emit(&opMultiply, byteOffsetOffset, elementSizeOffset,
            size_t.sizeof);

        const pointerOffset = reserveTemp(pointerFacts);
        emit(&opCopy, pointerOffset,
            arrayOffset + arrayPointerOffset, size_t.sizeof);
        emit(&opAdd, pointerOffset, byteOffsetOffset, size_t.sizeof);
        emit(&opCopy, _destination + arrayPointerOffset,
            pointerOffset, size_t.sizeof);
    }

    // `arr[i]`, read as a value. `compileElementAddress` does the shared
    // work of computing where that element actually lives; this only adds
    // the load once that address is in hand.
    override void visit(IndexExp expression) {
        if (_destination == discardResult) {
            const elementFacts = TypeFacts.of(expression.type);
            const offset = reserveTemp(elementFacts);
            evalInto(expression, offset, elementFacts.size);
            return;
        }

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

    override void visit(NewExp expression) {
        if (expression.lowering is null)
            return visit(cast(Expression) expression);

        expression.lowering.accept(this);
    }

    // `null`: pointers and class references are one zero word, while a
    // dynamic array is two zero words. These are the native representations
    // the host expects for their null values.
    override void visit(NullExp expression) {
        import snakebite.nativelayout: arrayLengthOffset, arrayPointerOffset;
        import dmd.astenums: Tclass, Tpointer;

        requireDestination(expression);

        const facts = TypeFacts.of(expression.type);
        if (expression.type.ty == Tpointer || expression.type.ty == Tclass) {
            emit(&opConstant, _destination,
                addConstant(0), facts.size);
            return;
        }

        if (!facts.isDynamicArray)
            return visit(cast(Expression) expression);

        emit(&opConstant, _destination + arrayLengthOffset,
            addConstant(0), size_t.sizeof);
        emit(&opConstant, _destination + arrayPointerOffset,
            addConstant(0), size_t.sizeof);
    }

    override void visit(TypeidExp expression) {
        import dmd.dtemplate: isType;
        import std.conv: text;

        requireDestination(expression);

        auto type = isType(expression.obj);
        if (type is null || type.vtinfo is null)
            throw rejection(_function, expression.loc,
                text("`", expression.toString,
                    "` without resolved type information"));

        auto address = _bytecode._plans.resolve(
            type.vtinfo.ident.toString);
        if (address is null)
            address = cast(void*) _bytecode.runtimeTypeInfo(type);
        if (address is null)
            throw rejection(_function, expression.loc,
                text("unresolved `", expression.toString, "`"));

        emit(&opConstant, _destination,
            addConstant(cast(long) cast(size_t) address), _width);
    }

    override void visit(CallExp expression) {
        if (_destination != discardResult && expression.f !is null
                && expression.f.isCtorDeclaration() !is null) {
            compileCall(expression, _destination);
            return;
        }

        if (_destination != discardResult && isRefCall(expression)) {
            const addressOffset = compileAddress(expression);
            emit(&opLoadIndirect, _destination, addressOffset, _width);
            return;
        }

        compileCall(expression, _destination);
    }

    // Whether `expression` calls a `ref`-returning function, resolved
    // (`expression.f`) or through a function pointer's own `TypeFunction`
    // - both `visit(CallExp)` and `compileAddress`'s `CallExp` case need
    // this same answer to know whether the call's result is a value or an
    // address to load through.
    private bool isRefCall(CallExp expression) {
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        auto callee = expression.f;
        if (callee is null) {
            auto calleeExp = expression.e1.isVarExp;
            callee = calleeExp is null
                ? null : calleeExp.var.isFuncDeclaration;
        }
        if (callee !is null)
            return typeFunctionOf(callee).isRef;

        auto deref = expression.e1.isPtrExp;
        auto functionType = deref is null ? null : deref.type.isTypeFunction;
        return functionType !is null && functionType.isRef;
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

    override void visit(ConstructExp expression) {
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

        compileAssign(expression, _destination);
    }

    // DMD lowers a dynamic-array length assignment to the druntime call
    // that owns allocation, prefix preservation, and the native array
    // representation. Compile that call instead of trying to infer the
    // lowering from the source assignment node.
    override void visit(LoweredAssignExp expression) {
        if (expression.lowering is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        expression.lowering.accept(this);
    }

    override void visit(BinAssignExp expression) {
        compileCompoundAssign(expression, _destination);
    }

    // `~=` appending a `dchar` (`CatDcharAssignExp`) never gets a
    // `.lowering`: dmd's semantic pass builds one only for `CatAssignExp`'s
    // other two operators (see `LoweringVisitor.visit(CatAssignExp)`),
    // leaving this case's UTF-8/UTF-16 encoding to glue-layer codegen
    // alone, which calls `_d_arrayappendcd`/`_d_arrayappendwd` by linker
    // symbol with no `FuncDeclaration` behind it - so, unlike every other
    // `~=` lowering here, there is no `CallExp` this compiler could walk
    // through the ordinary native-call path. This resolves and calls that
    // same hook directly (see `CallSite.isAppendDchar`), the same symbol a
    // real build's glue layer would call.
    override void visit(CatDcharAssignExp expression) {
        import dmd.astenums: Tchar, Twchar;
        import snakebite.nativelayout: arrayValueSize;

        auto elementType = expression.e1.type.nextOf;
        const name = elementType.ty == Tchar ? "_d_arrayappendcd"
            : elementType.ty == Twchar ? "_d_arrayappendwd"
            : null;
        if (name is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        auto address = _bytecode._plans.resolve(name);
        if (address is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const arrayOffset = compileAddress(expression.e1);

        const valueFacts = TypeFacts.of(expression.e2.type);
        const valueOffset = reserveTemp(valueFacts);
        evalInto(expression.e2, valueOffset, valueFacts.size);

        _callSites ~= CallSite(
            null,
            [
                Arg(arrayOffset, 0, size_t.sizeof),
                Arg(valueOffset, 0, valueFacts.size),
            ],
            arrayValueSize,
            null,
            address,
            false,
            0,
            true,
        );
        emit(&opCall, _destination, _callSites.length - 1, 0);
    }

    override void visit(CatExp expression) {
        if (expression.lowering is null)
            return visit(cast(Expression) expression);

        expression.lowering.accept(this);
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
        if (expression.lowering !is null) {
            expression.lowering.accept(this);
            return;
        }

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

    protected override void visitUnloweredEqual(EqualExp expression) {
        import dmd.astenums: Tarray;

        requireDestination(expression);

        if (expression.e1.type.ty == Tarray
                && expression.e2.type.ty == Tarray) {
            compileMemcmpDynamicArrayEquality(expression, _destination);
            return;
        }

        compileComparison(expression, _destination);
    }

    override void visit(IdentityExp expression) {
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
        import dmd.astenums: Tpointer;

        if (expression.type.ty == Tpointer) {
            if (handler !is &opAdd && handler !is &opSubtract)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            Expression pointerOperand = expression.e1.type.ty == Tpointer
                ? expression.e1 : expression.e2;
            Expression integralOperand = pointerOperand is expression.e1
                ? expression.e2 : expression.e1;
            if (pointerOperand.type.ty != Tpointer) {
                throw rejection(_function, expression.loc,
                    expressionText(expression));
            }

            const pointerFacts = TypeFacts.of(pointerOperand.type);
            const integralFacts = TypeFacts.of(integralOperand.type);
            if (!integralFacts.isIntegral
                    || !isIntegralSize(integralFacts.size))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            const leftOffset = reserveTemp(pointerFacts);
            evalInto(pointerOperand, leftOffset, pointerFacts.size);
            const rightOffset = reserveTemp(pointerFacts);
            evalOperandInto(integralOperand, rightOffset,
                pointerFacts.size);
            emit(handler, leftOffset, rightOffset, pointerFacts.size);

            if (destOffset != leftOffset)
                emit(&opCopy, destOffset, leftOffset, width);
            return;
        }

        const facts = TypeFacts.of(expression.type);
        if (isFloatingType(expression.type)) {
            const leftOffset = reserveTemp(facts);
            evalInto(expression.e1, leftOffset, facts.size);
            const rightOffset = reserveTemp(facts);
            evalInto(expression.e2, rightOffset, facts.size);
            emit(floatingBinaryHandler(expression), leftOffset, rightOffset,
                facts.size);

            if (destOffset != leftOffset)
                emit(&opCopy, destOffset, leftOffset, width);
            return;
        }

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

    private Instruction.Handler floatingBinaryHandler(BinExp expression) {
        with (EXP) switch (expression.op) {
            case add: return &opFloatAdd;
            case min: return &opFloatSubtract;
            case mul: return &opFloatMultiply;
            case div: return &opFloatDivide;
            case mod: return &opFloatModulo;
            default:
                throw rejection(_function, expression.loc,
                    expressionText(expression));
        }
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
        import dmd.astenums: Tpointer;

        const operandFacts = TypeFacts.of(expression.e1.type);

        if (expression.e1.type.ty == Tpointer) {
            Instruction.Handler pointerHandler;
            with (EXP) switch (expression.op) {
                case lessThan:
                    pointerHandler = &opLessThanUnsigned;
                    break;
                case lessOrEqual:
                    pointerHandler = &opLessOrEqualUnsigned;
                    break;
                case greaterThan:
                    pointerHandler = &opGreaterThanUnsigned;
                    break;
                case greaterOrEqual:
                    pointerHandler = &opGreaterOrEqualUnsigned;
                    break;
                case equal, identity: pointerHandler = &opEqual; break;
                case notEqual, notIdentity: pointerHandler = &opNotEqual;
                    break;
                default:
                    throw rejection(_function, expression.loc,
                        expressionText(expression));
            }

            const leftOffset = reserveTemp(operandFacts);
            evalInto(expression.e1, leftOffset, operandFacts.size);
            const rightOffset = reserveTemp(operandFacts);
            evalInto(expression.e2, rightOffset, operandFacts.size);
            emit(pointerHandler, leftOffset, rightOffset, operandFacts.size);

            if (destOffset != leftOffset)
                emit(&opCopy, destOffset, leftOffset, 1);
            return;
        }

        // Host floating-point operators preserve D's NaN and signed-zero
        // semantics for equality and ordering. Integral equality instead
        // compares the stored bits, which would make a NaN equal itself and
        // positive and negative zero unequal.
        if (isFloatingType(expression.e1.type)) {
            Instruction.Handler floatHandler;
            with (EXP) switch (expression.op) {
                case lessThan: floatHandler = &opFloatLessThan; break;
                case lessOrEqual: floatHandler = &opFloatLessOrEqual; break;
                case greaterThan: floatHandler = &opFloatGreaterThan; break;
                case greaterOrEqual:
                    floatHandler = &opFloatGreaterOrEqual; break;
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

    // DMD leaves EqualExp.lowering null only when its semantic pass approved
    // bytewise element equality. All other array equality runs through that
    // lowering instead of entering this fast path.
    private void compileMemcmpDynamicArrayEquality(
        EqualExp expression, in size_t destOffset,
    ) {
        import dmd.tokens: EXP;
        import snakebite.nativelayout: arrayValueSize;

        assert(expression.lowering is null);

        if (expression.op != EXP.equal && expression.op != EXP.notEqual)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const arrayFacts = TypeFacts.of(expression.e1.type);
        auto elementType = expression.e1.type.nextOf;
        const elementFacts = TypeFacts.of(elementType);
        if (!arrayFacts.isDynamicArray)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const leftOffset = reserveTemp(arrayFacts);
        evalInto(expression.e1, leftOffset, arrayValueSize);
        const rightOffset = reserveTemp(arrayFacts);
        evalInto(expression.e2, rightOffset, arrayValueSize);

        emit(&opArrayEqual, leftOffset, rightOffset, elementFacts.size);
        if (expression.op == EXP.notEqual)
            emit(&opLogicalNot, leftOffset, 0, 1);
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
        if (isFloatingType(expression.type)) {
            if (handler !is &opNegate)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            evalInto(expression.e1, destOffset, width);
            emit(&opFloatNegate, destOffset, 0, width);
            return;
        }

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
        import std.conv: text;

        auto sourceType = expression.e1.type;
        auto destType = expression.type;

        const sourceFacts = TypeFacts.of(sourceType);
        const destFacts = TypeFacts.of(destType);
        import dmd.astenums: Tpointer, Tsarray;

        if (isFloatingType(destType)) {
            if (isFloatingType(sourceType)) {
                if (sourceFacts.size == destFacts.size)
                    return evalInto(expression.e1, destOffset, width);

                const sourceOffset = sourceFacts.size > destFacts.size
                    ? reserveTemp(sourceFacts) : destOffset;
                evalInto(expression.e1, sourceOffset, sourceFacts.size);
                emit(&opFloatWidthCast, destOffset, sourceOffset, destFacts.size,
                    sourceFacts.size);
                return;
            }

            if (!sourceFacts.isIntegral
                    || !isIntegralSize(sourceFacts.size))
                throw rejection(_function, expression.loc,
                    text("a cast from `", sourceType.toString, "` to `",
                        destType.toString, "`"));

            const sourceOffset = reserveTemp(sourceFacts);
            evalInto(expression.e1, sourceOffset, sourceFacts.size);
            emit(
                sourceFacts.isUnsigned
                    ? &opIntegralToFloatUnsigned
                    : &opIntegralToFloatSigned,
                destOffset, sourceOffset, destFacts.size, sourceFacts.size,
            );
            return;
        }

        if (isFloatingType(sourceType)) {
            if (!destFacts.isIntegral || !isIntegralSize(destFacts.size))
                throw rejection(_function, expression.loc,
                    text("a cast from `", sourceType.toString, "` to `",
                        destType.toString, "`"));

            const sourceOffset = reserveTemp(sourceFacts);
            evalInto(expression.e1, sourceOffset, sourceFacts.size);
            emit(
                destFacts.isUnsigned
                    ? &opFloatToIntegralUnsigned
                    : &opFloatToIntegralSigned,
                destOffset, sourceOffset, destFacts.size, sourceFacts.size,
            );
            return;
        }

        if (sourceType.ty == Tpointer && destType.ty == Tpointer
                && width == sourceFacts.size)
            return evalInto(expression.e1, destOffset, width);

        if (sourceType.ty == Tpointer && destFacts.isDynamicArray) {
            const addressOffset = reserveTemp(pointerFacts);
            evalInto(expression.e1, addressOffset, sourceFacts.size);
            emit(&opLoadIndirect, destOffset, addressOffset,
                destFacts.size);
            return;
        }

        if (sourceType.ty == Tsarray && destFacts.isDynamicArray
                && destType.nextOf !is null
                && sourceType.nextOf.equals(destType.nextOf)) {
            import snakebite.nativelayout:
                arrayLengthOffset, arrayPointerOffset;

            const length = cast(size_t)
                sourceType.isTypeSArray.dim.toInteger;
            const addressOffset = compileAddress(expression.e1);
            emit(&opConstant, destOffset + arrayLengthOffset,
                addConstant(cast(long) length), size_t.sizeof);
            emit(&opCopy, destOffset + arrayPointerOffset,
                addressOffset, size_t.sizeof);
            return;
        }

        if (sourceFacts.isDynamicArray && destType.ty == Tpointer
                && destType.nextOf !is null
                && sourceType.nextOf.equals(destType.nextOf)) {
            import snakebite.nativelayout: arrayPointerOffset;

            const arrayOffset = reserveTemp(sourceFacts);
            evalInto(expression.e1, arrayOffset, sourceFacts.size);
            emit(&opCopy, destOffset, arrayOffset + arrayPointerOffset,
                size_t.sizeof);
            return;
        }

        if (sourceFacts.isDynamicArray && destFacts.isDynamicArray
                && width == sourceFacts.size) {
            evalInto(expression.e1, destOffset, width);
            return;
        }

        if (!sourceFacts.isIntegral || !isIntegralSize(sourceFacts.size)
                || !destFacts.isIntegral)
            throw rejection(_function, expression.loc,
                text("a cast from `", sourceType.toString, "` to `",
                    destType.toString, "`"));

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

        auto callee = expression.f;
        if (callee is null) {
            auto calleeExp = expression.e1.isVarExp;
            callee = calleeExp is null
                ? null : calleeExp.var.isFuncDeclaration;
        }
        if (callee is null)
            return compileIndirectCall(expression, destOffset);

        if (callee.fbody is null || _bytecode.hasNativeSymbol(callee)) {
            auto type = typeFunctionOf(callee);
            const parameterCount = type.parameterList.length;
            const argumentCount = expression.arguments is null
                ? 0
                : expression.arguments.length;
            if (argumentCount != parameterCount)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            // A `ref` return hands back its target's address in the
            // return register, whatever the pointee's own facts are - the
            // same convention `snakebite.ffi.plan` already prepares for a
            // native callee (see `CallPlan.prepare`'s own `returnsRef`).
            const isRefCallee = type.isRef;
            auto returnType = type.next;
            const isVoidCallee = returnType is null || returnType.ty == Tvoid;
            const returnFacts = isRefCallee
                ? pointerFacts
                : isVoidCallee ? TypeFacts.init : TypeFacts.of(returnType);
            if (isVoidCallee && destOffset != discardResult)
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            Arg[] args;
            if (callee.vthis !is null) {
                auto dot = expression.e1.isDotVarExp;
                if (dot is null)
                    throw rejection(_function, expression.loc,
                        expressionText(expression));

                const thisOffset = compileAddress(dot.e1);
                args ~= Arg(thisOffset, 0, size_t.sizeof);
            }
            foreach (i; 0 .. parameterCount) {
                auto parameter = type.parameterList[i];
                if (parameter.storageClass & (STC.out_ | STC.lazy_))
                    throw rejection(_function, expression.loc,
                        expressionText(expression));

                if (auto callback = guestFunctionPointer(
                        (*expression.arguments)[i])) {
                    const argumentOffset = reserveTemp(pointerFacts);
                    const address = _bytecode.boolFunctionAddress(callback);
                    emit(&opConstant, argumentOffset,
                        addConstant(cast(long) cast(size_t) address),
                        size_t.sizeof);
                    args ~= Arg(argumentOffset, 0, size_t.sizeof);
                    continue;
                }

                auto pointer = parameter.type.isTypePointer;
                if (pointer !is null && pointer.next.isTypeFunction !is null
                        && (*expression.arguments)[i].isNullExp is null)
                    throw rejection(_function, expression.loc,
                        expressionText(expression));

                if (parameter.storageClass & STC.ref_) {
                    const argumentOffset =
                        compileAddress((*expression.arguments)[i]);
                    args ~= Arg(argumentOffset, 0, size_t.sizeof);
                    continue;
                }

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
        const isConstructor = callee.isCtorDeclaration !is null;
        // `calleeLayout.hiddenThis.variable`, not `callee.vthis`: a
        // `FuncLiteralDeclaration` bound through `auto` can keep a dead
        // `vthis` semantic proved nothing reads (see `FrameLayout.of`'s
        // own `hasDeadContext`), and `calleeLayout` is what actually
        // knows whether this callee's frame reserved it a slot.
        if (calleeLayout.hiddenThis.variable !is null) {
            size_t thisOffset;
            if (callee.isThis is null) {
                auto parent = callee.toParent2();
                auto parentFunction = parent is null
                    ? null : parent.isFuncDeclaration;
                if (parentFunction is null)
                    throw rejection(_function, expression.loc,
                        "a static chain");
                thisOffset = contextAddressOf(parentFunction);
            } else if (isConstructor) {
                if (destOffset == discardResult)
                    throw rejection(_function, expression.loc,
                        expressionText(expression));

                thisOffset = reserveTemp(pointerFacts);
                emit(&opFrameAddress, thisOffset, destOffset,
                    size_t.sizeof);
            } else {
                auto dot = expression.e1.isDotVarExp;
                if (dot !is null)
                    thisOffset = compileAddress(dot.e1);
                else
                    thisOffset = hiddenThisOffset;
            }

            args ~= Arg(
                thisOffset,
                calleeLayout.hiddenThis.parameter.offset,
                size_t.sizeof,
            );
        }

        foreach (i; 0 .. parameterCount) {
            auto parameter = calleeLayout.parameters[i];

            // A `ref` parameter's own `facts` are the pointer slot's,
            // never `isSupportedFacts` on their own terms (`isIntegral`
            // is `false` for them) - the pointee's own facts are what
            // that check is for, and `Bytecode.compileFunction` already
            // made it of the callee's declared parameter type.
            if (parameter.isRef) {
                const argumentOffset =
                    compileAddress((*expression.arguments)[i]);
                args ~= Arg(argumentOffset, parameter.offset, size_t.sizeof);
                continue;
            }

            if (!isSupportedFacts(parameter.facts,
                    calleeType.parameterList[i].type))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            const argumentOffset = reserveTemp(parameter.facts);
            evalInto(
                (*expression.arguments)[i], argumentOffset,
                parameter.facts.size,
            );
            args ~= Arg(argumentOffset, parameter.offset, parameter.facts.size);
        }

        // A `ref` return hands the caller the callee's own returned
        // storage's address - `compileAddress`'s `CallExp` case is the one
        // place that address is read back out, and `compileIndirectAssign`
        // is the one place it is written through.
        const isRefCallee = calleeType.isRef;
        auto calleeReturnType = calleeType.next;
        const isVoidCallee = isConstructor || calleeReturnType is null
            || calleeReturnType.ty == Tvoid;
        const returnFacts = isRefCallee
            ? pointerFacts
            : isVoidCallee ? TypeFacts.init : TypeFacts.of(calleeReturnType);
        if (!isRefCallee && !isVoidCallee
                && !isSupportedFacts(returnFacts, calleeReturnType))
            throw rejection(_function, expression.loc,
                expressionText(expression));
        if (isVoidCallee && !isConstructor && destOffset != discardResult)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const siteIndex = _callSites.length;
        _callSites ~=
            CallSite(calleeFunction, args, isVoidCallee ? 0 : returnFacts.size);
        emit(&opCall, destOffset, siteIndex, 0);
    }

    // `fn(args)` where dmd left `expression.f` unresolved: a call through a
    // function pointer's own value rather than a name. dmd lowers this to
    // `(*fn)(args)` (see the interpreter's own `calleeOf` for the same
    // shape), so `expression.e1` is a `PtrExp` whose pointee type is the
    // `TypeFunction` this call's own signature comes from - there is no
    // `FuncDeclaration` to read a `FrameLayout` from, since more than one
    // could reach this call site at run time. `FrameLayout.ofParameters`
    // packs from that `TypeFunction` alone, the same packing every callee's
    // own `FrameLayout.of` uses for its declared parameters, so argument
    // `i` lands where whichever callee this call reaches at run time reads
    // it from.
    private void compileIndirectCall(CallExp expression, in size_t destOffset) {
        import dmd.astenums: STC, Tvoid;

        auto deref = expression.e1.isPtrExp;
        auto functionType = deref is null ? null : deref.type.isTypeFunction;
        if (functionType is null)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const parameterCount = functionType.parameterList.length;
        const argumentCount =
            expression.arguments is null ? 0 : expression.arguments.length;
        if (argumentCount != parameterCount)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        // A `ref` return hands back its target's address in the return
        // register regardless of the pointee's own width - the same
        // convention `compileCall`'s own `isRefCallee` follows for a
        // resolved callee.
        const isRefCallee = functionType.isRef;
        auto returnType = functionType.next;
        const isVoidCallee = returnType is null || returnType.ty == Tvoid;
        const returnFacts = isRefCallee
            ? pointerFacts
            : isVoidCallee ? TypeFacts.init : TypeFacts.of(returnType);
        if (!isRefCallee && !isVoidCallee
                && !isSupportedFacts(returnFacts, returnType))
            throw rejection(_function, expression.loc,
                expressionText(expression));
        if (isVoidCallee && destOffset != discardResult)
            throw rejection(_function, expression.loc,
                expressionText(expression));

        const calleeOffset = reserveTemp(pointerFacts);
        evalInto(deref.e1, calleeOffset, size_t.sizeof);

        auto calleeLayout = FrameLayout.ofParameters(functionType);

        Arg[] args;
        foreach (i; 0 .. parameterCount) {
            auto parameter = functionType.parameterList[i];
            if (parameter.storageClass & (STC.out_ | STC.lazy_ | STC.ref_))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            auto slot = calleeLayout.parameters[i];
            if (!isSupportedFacts(slot.facts, parameter.type))
                throw rejection(_function, expression.loc,
                    expressionText(expression));

            const argumentOffset = reserveTemp(slot.facts);
            evalInto(
                (*expression.arguments)[i], argumentOffset, slot.facts.size);
            args ~= Arg(argumentOffset, slot.offset, slot.facts.size);
        }

        CallSite site;
        site.args = args;
        site.returnWidth = isVoidCallee ? 0 : returnFacts.size;
        site.isIndirect = true;
        site.calleeSlotOffset = calleeOffset;

        const siteIndex = _callSites.length;
        _callSites ~= site;
        emit(&opCall, destOffset, siteIndex, 0);
    }

    private FuncDeclaration guestFunctionPointer(Expression argument) {
        // A guest function has no machine address. Keep its declaration as
        // the bytecode value, but give native code an executable callback
        // entry for the one signature the shared FFI layer supports.
        auto expression = argument;
        while (auto cast_ = expression.isCastExp)
            expression = cast_.e1;

        FuncDeclaration function_;
        if (auto literal = expression.isFuncExp)
            function_ = literal.fd;
        else if (auto address = expression.isSymOffExp)
            function_ = address.var.isFuncDeclaration;

        if (function_ is null || !_bytecode.isGuestFunction(function_))
            return null;

        if (!supportsBoolFunction(function_))
            throw rejection(_function, argument.loc,
                expressionText(argument));

        return function_;
    }

    private TypeFacts pointerFacts() {
        return pointerFactsOf;
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
        import std.conv: text;
        import std.string: fromStringz;

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

        const site = AssertSite(
            text("bytecode: index out of bounds: `", expression.e2.toString,
                "`"),
            expression.loc.filename.fromStringz.idup,
            expression.loc.linnum,
        );
        _assertSites ~= site;
        emit(&opAssert, boundsOffset, _assertSites.length - 1, 1);

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

    // Where `expression`'s own storage lives, as a run-time pointer value
    // left in a fresh temporary - the one operation `ref` binding (a `ref`
    // parameter's argument, a `ref` local's initialiser, a `ref` return's
    // own expression) and `~=`'s `ref` argument to druntime all reduce to.
    //
    // A plain variable's address is its frame slot's own address, computed
    // fresh by `opFrameAddress` since the frame this compiled function runs
    // in only exists at run time. A `ref` variable's slot already holds the
    // address it is bound to - the same reach `visit(VarExp)` makes to read
    // through it - so that slot's own offset already answers the question
    // without a further instruction. An indexed element's address is
    // `compileElementAddress`'s own job, already shared with a load and a
    // store. A `ref`-returning call's result is likewise already an
    // address once `compileCall` compiles it into a pointer-sized slot -
    // see `_isRefReturn` in `compileReturn`.
    private size_t compileAddress(Expression expression) {
        import dmd.astenums: Tclass;

        if (auto varExp = expression.isVarExp) {
            auto variable = varExp.var.isVarDeclaration;
            if (variable !is null && variable.isDataseg)
                return compileStaticAddress(variable);
            if (variable !is null && !variable.isDataseg) {
                if (isThisField(variable))
                    return compileThisFieldAddress(variable);
                return addressOfVariable(variable);
            }
        }

        if (auto thisExp = expression.isThisExp)
            return hiddenThisOffset(thisExp.var);

        if (auto dot = expression.isDotVarExp) {
            auto field = dot.var.isVarDeclaration;
            if (field !is null && field.isBitFieldDeclaration is null
                    && (dot.e1.type.ty == Tclass
                        || dot.e1.type.isTypeStruct !is null))
                return compileFieldAddress(dot);
        }

        if (auto indexExp = expression.isIndexExp) {
            const arrayFacts = TypeFacts.of(indexExp.e1.type);
            if (arrayFacts.isDynamicArray)
                return compileElementAddress(indexExp, arrayFacts);
        }

        if (auto callExp = expression.isCallExp) {
            auto callee = callExp.f;
            if (callee is null) {
                auto calleeExp = callExp.e1.isVarExp;
                callee = calleeExp is null
                    ? null : calleeExp.var.isFuncDeclaration;
            }
            if (isRefCall(callExp)) {
                const offset = reserveTemp(pointerFacts);
                compileCall(callExp, offset);
                return offset;
            }

            if (callee !is null) {
                const facts = TypeFacts.of(callExp.type);
                const offset = reserveTemp(facts);
                compileCall(callExp, offset);
                const address = reserveTemp(pointerFacts);
                emit(&opFrameAddress, address, offset, size_t.sizeof);
                return address;
            }
        }

        if (expression.type.isTypeStruct !is null) {
            const facts = TypeFacts.of(expression.type);
            const offset = reserveTemp(facts);
            evalInto(expression, offset, facts.size);
            const address = reserveTemp(pointerFacts);
            emit(&opFrameAddress, address, offset, size_t.sizeof);
            return address;
        }

        // `*(cond ? &a : &b)`: dmd wraps a `ref` return's own conditional
        // expression this way (see `_isRefReturn` in `compileReturn`) -
        // `expression.e1` is itself a pointer-typed value (a ternary of
        // addresses, an ordinary expression `evalInto` already knows how
        // to compile through `visit(SymOffExp)`/`visit(CondExp)`), and the
        // address `*p` names is exactly `p`'s own value, not a further
        // indirection.
        if (auto ptrExp = expression.isPtrExp) {
            const offset = reserveTemp(pointerFacts);
            evalInto(ptrExp.e1, offset, size_t.sizeof);
            return offset;
        }

        throw rejection(_function, expression.loc, expressionText(expression));
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

    // `[a, b, c]`: allocates one block through druntime for every element,
    // then evaluates each element expression directly into its own slot in
    // it - never constant-folded bytes copied in bulk, since an element
    // like `x + 1` only evaluating can produce. `[]` needs no allocation at
    // all: a null pointer and a zero length already are an empty dynamic
    // array's own two words.
    //
    // The length and pointer are built up in a temporary, not `destOffset`
    // itself, and copied out to `destOffset` only once every element is
    // done: an element expression can read `destOffset`'s own variable
    // (`a = [a[1], a[0]]`), and until the whole literal is ready that
    // variable's old value is the only correct thing living there.
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

        if (count == 0) {
            emit(&opConstant, destOffset + arrayLengthOffset,
                addConstant(0), size_t.sizeof);
            emit(&opConstant, destOffset + arrayPointerOffset,
                addConstant(0), size_t.sizeof);
            return;
        }

        const lengthOffset = reserveTemp(pointerFacts);
        emit(&opConstant, lengthOffset,
            addConstant(cast(long) count), size_t.sizeof);

        const pointerOffset = reserveTemp(pointerFacts);
        const sizeOffset = reserveTemp(pointerFacts);
        emit(&opConstant, sizeOffset,
            addConstant(cast(long) (count * elementFacts.size)),
            size_t.sizeof);
        emitAllocate(sizeOffset, pointerOffset);

        foreach (i; 0 .. count) {
            auto element = (*expression.elements)[i];
            const elementOffset = reserveTemp(elementFacts);
            evalInto(element, elementOffset, elementFacts.size);

            const addressOffset = reserveTemp(pointerFacts);
            emit(&opCopy, addressOffset, pointerOffset, size_t.sizeof);
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

        emit(&opCopy, destOffset + arrayLengthOffset, lengthOffset,
            size_t.sizeof);
        emit(&opCopy, destOffset + arrayPointerOffset, pointerOffset,
            size_t.sizeof);
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
