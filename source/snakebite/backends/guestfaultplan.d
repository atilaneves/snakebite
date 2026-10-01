module snakebite.backends.guestfaultplan;


private:


import snakebite.backends.guestfault: GuestFault, NativeCallCheck;
import std.typecons: Nullable;


// Where a guest fault is reported, decided once for every backend: which
// failure and at which source location. A backend evaluates the reference,
// then runs the check this names before the memory access that needs it.
public struct FaultCheck {
    public GuestFault.Kind kind;
    public imported!"dmd.location".Loc loc;
}

// The check of a load or a store through `expression`, if it needs one. An
// address that nothing reads or writes is no access: native code forms
// `&p.field`, passes `*p` as a `ref` argument and calls a method through
// `p` with a null `p` and lives on. Only the access through that address
// faults, so it is the access that carries the check. The place that
// reads or writes through a `ref` parameter, a `ref` local, a `ref` result,
// `this` of a struct or a field of `this` is a place like any other.
//
// `addressOnly` is the expression whose address the backend forms and does
// not use. Its own node, and the nodes below it that name the memory
// (`&p[i].field` names the memory of `*p`), make no access.
public Nullable!FaultCheck accessFaultOf(
    imported!"dmd.expression".Expression expression,
    imported!"dmd.expression".Expression addressOnly,
) {
    import dmd.astenums: Tarray, Tclass, Tpointer, Tstruct;
    import dmd.typesem: toBasetype;

    alias Check = Nullable!FaultCheck;
    if (namesMemoryOf(addressOnly, expression))
        return Check.init;

    const pointer = Check(FaultCheck(GuestFault.Kind.nullPointer,
        expression.loc));
    const classReference = Check(FaultCheck(
        GuestFault.Kind.nullClassReference, expression.loc));

    if (auto dereference = expression.isPtrExp)
        return addressKindOf(dereference.e1) == GuestFault.Kind.nullPointer
            ? pointer : classReference;

    if (auto index = expression.isIndexExp) {
        const kind = index.e1.type.toBasetype.ty;
        return kind == Tpointer || kind == Tarray ? pointer : Check.init;
    }

    if (auto field = expression.isDotVarExp)
        return field.var.isField && field.e1.type.toBasetype.ty == Tclass
            ? classReference : Check.init;

    if (auto name = expression.isVarExp)
        return accessFaultOfVariable(name);

    if (auto this_ = expression.isThisExp)
        return this_.type.toBasetype.ty == Tstruct ? pointer : Check.init;

    return Check.init;
}

// A fill or a copy writes or reads every element of a slice that has any,
// and the first element is the access: there is no check for a slice with no
// element. The failure is at the statement that does it.
public FaultCheck sliceElementsFaultOf(in imported!"dmd.location".Loc loc) {
    return FaultCheck(GuestFault.Kind.nullPointer, loc);
}

// Whether the address of the static array `array` can be in the first page.
// The storage of a variable cannot be: a local, a global and what is inside
// them have an address of their own. What a pointer, a class reference, a
// `ref` or a slice leads to can.
public bool addressCanBeNull(imported!"dmd.expression".Expression array) {
    import dmd.astenums: Tsarray, Tstruct;
    import dmd.typesem: toBasetype;

    for (auto node = array; node !is null;) {
        if (auto name = node.isVarExp) {
            auto variable = name.var.isVarDeclaration;
            return variable is null || variable.isReference
                || variable.isField;
        }

        if (auto field = node.isDotVarExp)
            node = field.e1.type.toBasetype.ty == Tstruct ? field.e1 : null;
        else if (auto element = node.isIndexExp)
            node = element.e1.type.toBasetype.ty == Tsarray
                ? element.e1 : null;
        else
            break;
    }

    return true;
}

// A variable of an enclosing function is read or written through the context
// pointer of the nested function, and a null context is a null address. The
// check is on the context before its first use.
public Nullable!FaultCheck contextFaultOf(
    imported!"dmd.expression".Expression access,
    imported!"dmd.expression".Expression addressOnly,
) {
    alias Check = Nullable!FaultCheck;
    if (namesMemoryOf(addressOnly, access))
        return Check.init;

    return Check(FaultCheck(GuestFault.Kind.nullPointer, access.loc));
}

// What a dereference of `operand` reads: a class reference when the address
// is made from one (`c.classinfo` reads the vtable of `c`, `c.__monitor` the
// second word of the object), a pointer otherwise.
private GuestFault.Kind addressKindOf(
    imported!"dmd.expression".Expression operand,
) {
    import dmd.astenums: Tclass;
    import dmd.typesem: toBasetype;

    for (auto node = operand; node !is null;) {
        if (node.type.toBasetype.ty == Tclass)
            return GuestFault.Kind.nullClassReference;

        if (auto cast_ = node.isCastExp)
            node = cast_.e1;
        else if (auto sum = node.isAddExp)
            node = sum.e1;
        else
            break;
    }

    return GuestFault.Kind.nullPointer;
}

// The result of a call that returns `ref` is an address like any other.
public Nullable!FaultCheck refResultFaultOf(
    imported!"dmd.expression".CallExp call,
    imported!"dmd.expression".Expression addressOnly,
) {
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    alias Check = Nullable!FaultCheck;
    auto functionType = typeFunctionOf(call);
    if (functionType is null || !functionType.isRef
            || namesMemoryOf(addressOnly, call))
        return Check.init;

    return Check(FaultCheck(GuestFault.Kind.nullPointer, call.loc));
}

// A call reads the receiver's vtable, or the function pointer or the
// delegate it calls through. A call that dmd binds statically (a `final`
// method, `super.f()`, a method of a struct) reads nothing of the receiver:
// compiled D runs it with a null `this`, and a read of a field in it is the
// access that faults.
public Nullable!FaultCheck callFaultOf(
    imported!"dmd.expression".CallExp call,
) {
    import dmd.astenums: Tclass, Tfunction;
    import dmd.funcsem: isVirtualMethod;
    import dmd.typesem: toBasetype;
    import snakebite.backends.calls: isIndirectDelegateCall;
    import snakebite.frontend.dmd.functions: unresolvedCalleeOf;

    alias Check = Nullable!FaultCheck;
    auto function_ = call.f is null ? unresolvedCalleeOf(call) : call.f;
    if (function_ is null) {
        if (isIndirectDelegateCall(call.e1.type))
            return Check(FaultCheck(GuestFault.Kind.nullDelegate, call.loc));

        if (call.e1.isPtrExp !is null
                && call.e1.type.toBasetype.ty == Tfunction)
            return Check(
                FaultCheck(GuestFault.Kind.nullFunctionPointer, call.loc));

        return Check.init;
    }

    auto dot = call.e1.isDotVarExp;
    if (dot !is null && dot.e1.type.toBasetype.ty == Tclass
            && dot.e1.isSuperExp is null && !call.directcall
            && function_.isVirtualMethod)
        return Check(
            FaultCheck(GuestFault.Kind.nullClassReference, call.loc));

    return Check.init;
}

// `&c.method` of a virtual method reads the vtable of `c` to name the
// target.
public Nullable!FaultCheck delegateFaultOf(
    in imported!"snakebite.frontend.dmd.delegates".DelegateTarget target,
    in imported!"dmd.location".Loc loc,
) {
    alias Check = Nullable!FaultCheck;
    return target.virtualDispatch
        ? Check(FaultCheck(GuestFault.Kind.nullClassReference, loc))
        : Check.init;
}

// Where the integer division `expression` is reported when the hardware
// traps on it, which is null for an operator that is not one: `/`, `%` and
// their compound assignments of integers trap on a zero divisor and on the
// quotient that does not fit, and floating point ones never do. The place is
// the operator.
public Nullable!(imported!"dmd.location".Loc) divisionFaultOf(
    imported!"dmd.expression".BinExp expression,
) {
    import snakebite.backends.arithmetic: ArithmeticPlan, arithmeticPlan;

    alias Place = Nullable!(imported!"dmd.location".Loc);
    const divides = expression.isDivExp !is null
        || expression.isModExp !is null
        || expression.isDivAssignExp !is null
        || expression.isModAssignExp !is null;
    if (!divides || arithmeticPlan(expression).kind
            != ArithmeticPlan.Kind.integral)
        return Place.init;

    return Place(expression.loc);
}

// A `throw` statement and a `throw` expression alike.
public FaultCheck throwFaultOf(in imported!"dmd.location".Loc loc) {
    return FaultCheck(GuestFault.Kind.throwNull, loc);
}

// `typeid(c)` reads the vtable of `c`.
public FaultCheck typeidFaultOf(
    imported!"dmd.expression".TypeidExp expression,
) {
    return FaultCheck(GuestFault.Kind.nullClassReference, expression.loc);
}

// Whether `target` names memory that `addressOnly` only addresses: the node
// itself, or what a struct field or a static array element in it stands in.
private bool namesMemoryOf(
    imported!"dmd.expression".Expression addressOnly,
    imported!"dmd.expression".Expression target,
) {
    import dmd.astenums: Tsarray, Tstruct;
    import dmd.typesem: isIntegral, toBasetype;

    for (auto node = addressOnly; node !is null;) {
        if (node is target)
            return true;

        if (auto field = node.isDotVarExp)
            node = field.e1.type.toBasetype.ty == Tstruct ? field.e1 : null;
        else if (auto element = node.isIndexExp)
            node = element.e1.type.toBasetype.ty == Tsarray
                ? element.e1 : null;
        else if (auto comma = node.isCommaExp)
            node = comma.e2;
        else if (auto cast_ = node.isCastExp)
            node = isIntegral(cast_.e1.type) && isIntegral(cast_.type)
                ? cast_.e1 : null;
        else if (auto condition = node.isCondExp)
            return namesMemoryOf(condition.e1, target)
                || namesMemoryOf(condition.e2, target);
        else
            node = null;
    }

    return false;
}

private Nullable!FaultCheck accessFaultOfVariable(
    imported!"dmd.expression".VarExp name,
) {
    alias Check = Nullable!FaultCheck;
    auto variable = name.var.isVarDeclaration;
    if (variable is null)
        return Check.init;

    if (variable.isField) {
        auto kind = variable.toParent2.isClassDeclaration is null
            ? GuestFault.Kind.nullPointer
            : GuestFault.Kind.nullClassReference;
        return Check(FaultCheck(kind, name.loc));
    }

    if (!variable.isReference)
        return Check.init;

    // The callee sets an `out` parameter to its default value first, and
    // that write is the access: compiled D does it in the callee, at the
    // line of the callee.
    auto function_ = variable.isOut ? variable.toParent2.isFuncDeclaration : null;
    return Check(FaultCheck(GuestFault.Kind.nullPointer,
        function_ is null ? name.loc : function_.loc));
}


// The check that a call to `callee` needs before it runs, or null. The
// callees are the ones that read memory the guest hands over, and native
// code that reads a null object or divides by zero dies of a signal:
//
//  - `synchronized (c)` locks the monitor of `c`, a field of the object.
//  - `p.length = n` and `*p ~= x` change the array that `p` points to: the
//    hook takes it by `ref` as its first argument and writes it.
//  - An array operation divides the elements of its operands one by one,
//    in the loop of `core.internal.array.operations.arrayOp`, which is
//    native code whatever the module that instantiates it. The operands and
//    the operations are template arguments in Reverse Polish Notation.
public const(NativeCallCheck)* nativeCallCheckOf(
    imported!"dmd.func".FuncDeclaration callee,
) {
    import dmd.id: Id;

    if (callee.ident is Id.monitorenter) {
        auto check = new NativeCallCheck;
        check.nonNull = 0;
        check.nonNullKind = GuestFault.Kind.nullClassReference;
        return check;
    }

    if (growsArrayInPlace(callee)) {
        auto check = new NativeCallCheck;
        check.nonNull = 0;
        check.nonNullKind = GuestFault.Kind.nullPointer;
        return check;
    }

    if (auto power = integerPowerCheckOf(callee))
        return power;

    return arrayOperationCheckOf(callee);
}

// `pow` of `std.math` with an integer base and exponent, which is what
// `x ^^ n` is for integers.
private const(NativeCallCheck)* integerPowerCheckOf(
    imported!"dmd.func".FuncDeclaration callee,
) {
    import core.stdc.string: strcmp;
    import dmd.dtemplate: isType;
    import dmd.typesem: isIntegral, isUnsigned, size, toBasetype;

    auto instance = callee.parent is null
        ? null : callee.parent.isTemplateInstance;
    if (instance is null || instance.tiargs is null
            || instance.tiargs.length != 2
            || instance.name.toString != "pow"
            || strcmp(instance.tempdecl.parent.toPrettyChars,
                "std.math.exponential") != 0)
        return null;

    auto base = (*instance.tiargs)[0].isType;
    auto exponent = (*instance.tiargs)[1].isType;
    if (base is null || exponent is null || !base.toBasetype.isIntegral
            || !exponent.toBasetype.isIntegral)
        return null;

    auto check = new NativeCallCheck;
    check.integerPower = NativeCallCheck.IntegerPower(
        true, base.size, exponent.size, !exponent.toBasetype.isUnsigned);
    return check;
}

// Whether `callee` is one of the druntime hooks that dmd lowers a change of
// the length of an array, or an append to it, to. Its first argument is the
// array by `ref`.
private bool growsArrayInPlace(imported!"dmd.func".FuncDeclaration callee) {
    import core.stdc.string: strcmp, strncmp;

    auto instance = callee.parent is null
        ? null : callee.parent.isTemplateInstance;
    if (instance is null)
        return false;

    const name = instance.name.toString;
    if (name != "_d_arraysetlengthT" && name != "_d_arrayappendcTX"
            && name != "_d_arrayappendT")
        return false;

    enum package_ = "core.internal.array.";
    return strncmp(instance.tempdecl.parent.toPrettyChars, package_.ptr,
        package_.length) == 0;
}

private const(NativeCallCheck)* arrayOperationCheckOf(
    imported!"dmd.func".FuncDeclaration callee,
) {
    import core.stdc.string: strcmp;
    import dmd.dtemplate: isExpression, isType;
    import dmd.mtype: Type;
    import dmd.typesem: isIntegral, isUnsigned, size, toBasetype;

    auto instance = callee.parent is null
        ? null : callee.parent.isTemplateInstance;
    if (instance is null || instance.tiargs is null
            || instance.name.toString != "arrayOp"
            || strcmp(instance.tempdecl.parent.toPrettyChars,
                "core.internal.array.operations") != 0)
        return null;

    alias Step = NativeCallCheck.ArrayOperation.Step;
    alias Operand = NativeCallCheck.ArrayOperation.Operand;

    // `arrayOp(T : T[], Args...)(T[] res, ...)`: the first template
    // argument is for `res`, argument 0 of the call. The operands are the
    // arguments 1 and up, in the order of the types in `Args`.
    Operand operandOf(Type type, in size_t argument, in bool isSlice) {
        auto element = isSlice ? type.toBasetype.isTypeDArray.next : type;
        return Operand(argument, isSlice, element.size,
            element.toBasetype.isIntegral, element.toBasetype.isUnsigned);
    }

    auto resultType = (*instance.tiargs)[][0].isType;
    auto check = new NativeCallCheck;
    size_t nextArgument = 1;
    bool divides;
    foreach (argument; (*instance.tiargs)[][1 .. $]) {
        Step step;
        if (auto type = isType(argument)) {
            step.kind = Step.Kind.operand;
            step.operand = operandOf(
                type, nextArgument++, type.toBasetype.isTypeDArray !is null);
            check.arrayOperation.steps ~= step;
            continue;
        }

        const operation = isExpression(argument).isStringExp.peekString;
        if (operation[0] == 'u') {
            step.kind = operation == "u-"
                ? Step.Kind.negate
                : operation == "u~" ? Step.Kind.complement
                    : Step.Kind.unknownUnary;
        } else if (operation == "=") {
            step.kind = Step.Kind.assign;
        } else {
            const compound = operation.length > 1 && operation[$ - 1] == '=';
            const binary = compound ? operation[0 .. $ - 1] : operation;
            step.kind = binaryKindOf(binary);
            if (compound) {
                step.assignsToResult = true;
                step.operand = operandOf(resultType, 0, true);
            }
            divides = divides || step.kind == Step.Kind.divide
                || step.kind == Step.Kind.modulo;
        }

        check.arrayOperation.steps ~= step;
    }

    return divides ? check : null;
}

private imported!"snakebite.backends.guestfault".NativeCallCheck
    .ArrayOperation.Step.Kind binaryKindOf(in const(char)[] operation) {
    alias Kind = NativeCallCheck.ArrayOperation.Step.Kind;

    switch (operation) {
        case "+":
            return Kind.add;
        case "-":
            return Kind.subtract;
        case "*":
            return Kind.multiply;
        case "/":
            return Kind.divide;
        case "%":
            return Kind.modulo;
        default:
            return Kind.unknownBinary;
    }
}
