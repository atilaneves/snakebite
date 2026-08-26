module snakebite.frontend.dmd.types;

private:

public bool isIntegralExpression(
    imported!"dmd.expression".Expression expression,
) {
    if (expression is null || expression.type is null)
        return false;

    return isIntegralType(expression.type);
}

public bool isIntegralType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    auto basetype = type.toBasetype;
    if (basetype is null)
        return false;

    with (TY) switch (basetype.ty) {
        case Tbool:
        case Tchar:
        case Twchar:
        case Tdchar:
            return false;
        default:
            return basetype.isIntegral;
    }
}

public bool isCharacterType(imported!"dmd.mtype".Type type) {
    import dmd.astenums: TY;

    if (type is null)
        return false;

    auto basetype = type.toBasetype;
    if (basetype is null)
        return false;

    with (TY) switch (basetype.ty) {
        case Tchar:
        case Twchar:
        case Tdchar:
            return true;

        default:
            return false;
    }
}

public bool isCharacterExpression(
    imported!"dmd.expression".Expression expression,
) {
    return expression !is null && isCharacterType(expression.type);
}

public bool isCharacterArrayType(imported!"dmd.mtype".Type type) {
    if (type is null)
        return false;

    auto elementType = arrayElementType(type);
    return elementType !is null && isCharacterType(elementType);
}

public imported!"dmd.mtype".Type arrayElementType(
    imported!"dmd.mtype".Type type,
) {
    if (type is null)
        return null;

    auto basetype = type.toBasetype;
    if (basetype is null)
        return null;

    if (auto dynamicArray = basetype.isTypeDArray)
        return dynamicArray.nextOf;

    if (auto staticArray = basetype.isTypeSArray)
        return staticArray.nextOf;

    return null;
}

public bool isArrayType(imported!"dmd.mtype".Type type) {
    return arrayElementType(type) !is null;
}

public bool isDynamicArrayType(imported!"dmd.mtype".Type type) {
    return type !is null && type.toBasetype.isTypeDArray !is null;
}

public bool isStaticArrayType(imported!"dmd.mtype".Type type) {
    return type !is null && type.toBasetype.isTypeSArray !is null;
}

public bool isAssocArrayType(imported!"dmd.mtype".Type type) {
    return type !is null && type.toBasetype.isTypeAArray !is null;
}

public bool isPointerType(imported!"dmd.mtype".Type type) {
    return type !is null && type.toBasetype.isTypePointer !is null;
}

public bool isStructType(imported!"dmd.mtype".Type type) {
    return type !is null && type.toBasetype.isTypeStruct !is null;
}

public template dmdScalarType(imported!"dmd.astenums".TY type) {
    import dmd.astenums: TY;

    static if (type == TY.Tbool)
        alias dmdScalarType = bool;
    else static if (type == TY.Tint8)
        alias dmdScalarType = byte;
    else static if (type == TY.Tuns8)
        alias dmdScalarType = ubyte;
    else static if (type == TY.Tint16)
        alias dmdScalarType = short;
    else static if (type == TY.Tuns16)
        alias dmdScalarType = ushort;
    else static if (type == TY.Tint32)
        alias dmdScalarType = int;
    else static if (type == TY.Tuns32)
        alias dmdScalarType = uint;
    else static if (type == TY.Tint64)
        alias dmdScalarType = long;
    else static if (type == TY.Tuns64)
        alias dmdScalarType = ulong;
    else static if (type == TY.Tfloat32)
        alias dmdScalarType = float;
    else static if (type == TY.Tfloat64)
        alias dmdScalarType = double;
    else static if (type == TY.Tfloat80)
        alias dmdScalarType = real;
    else static if (type == TY.Tchar)
        alias dmdScalarType = char;
    else static if (type == TY.Twchar)
        alias dmdScalarType = wchar;
    else static if (type == TY.Tdchar)
        alias dmdScalarType = dchar;
    else
        static assert(false, "Unsupported DMD scalar type.");
}
