//===-- gen/llvmhelpers.d - LLVM helpers of the frontend ----------*- D -*-===//
//
//                         LDC - the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// D port of DtoSetFuncDeclIntrinsicName of LDC's gen/llvmhelpers.cpp. The
// size of a type in bits comes from the frontend, not from LLVM's data
// layout.
//
//===----------------------------------------------------------------------===//

module gen.llvmhelpers;

import dmd.astenums;
import dmd.dtemplate;
import dmd.errors;
import dmd.func;
import dmd.mtype;
import dmd.typesem;

import gen.dpragma : LDCPragma;

import core.stdc.string : strlen;

/// Fixes up the name of an overloaded intrinsic: `llvm.bswap.i#` of the
/// instance for `uint` is `llvm.bswap.i32`.
void DtoSetFuncDeclIntrinsicName(TemplateInstance ti, TemplateDeclaration td, FuncDeclaration fd)
{
    if (fd.llvmInternal == LDCPragma.LLVMintrinsic)
        fd.mangleOverride = overloadedIntrinsicName(ti, td);
}

private const(char)[] overloadedIntrinsicName(TemplateInstance ti, TemplateDeclaration td)
{
    import core.stdc.stdio : snprintf;

    assert(td.intrinsicName);
    assert(ti.tdtypes.length == 1);
    Type T = cast(Type) ti.tdtypes[0];

    char prefix;
    if (T.isFloating() && !T.isComplex())
        prefix = 'f';
    else if (T.isIntegral())
        prefix = 'i';
    else
    {
        error(ti.loc, "%s `%s` has invalid template parameter for intrinsic: `%s`",
            ti.kind(), ti.toPrettyChars(), T.toChars());
        fatal();
    }

    string name = td.intrinsicName[0 .. strlen(td.intrinsicName)].idup;

    // `{f,i}#` becomes `{f,i}<bitsize>` (`i32`), or
    // `v<vector length>{f,i}<vector element bitsize>` (`v4f32` for float4).
    string replacement;
    auto vector = T.toBasetype().isTypeVector();
    if (vector !is null)
    {
        auto element = vector.elementType();
        replacement = 'v' ~ decimal(vector.size() / element.size()) ~ prefix ~ decimal(bitSize(element));
    }
    else
        replacement = prefix ~ decimal(bitSize(T));

    string result;
    size_t position = 0;
    for (size_t i = 0; i < name.length; ++i)
    {
        if (name[i] != '#')
            continue;
        if (i > 0 && name[i - 1] == prefix)
        {
            result ~= name[position .. i - 1] ~ replacement;
            position = i + 1;
        }
        else
        {
            if (i > 0 && (name[i - 1] == 'i' || name[i - 1] == 'f'))
                error(ti.loc, "%s `%s` has invalid parameter type for intrinsic `%.*s`: `%s` is not a%s type",
                    ti.kind(), ti.toPrettyChars(), cast(int) name.length, name.ptr, T.toChars(),
                    name[i - 1] == 'i' ? "n integral".ptr : " floating-point".ptr);
            else
                error(td.loc, "%s `%s` has an invalid intrinsic name: `%.*s`",
                    td.kind(), td.toPrettyChars(), cast(int) name.length, name.ptr);
            fatal();
        }
    }
    return (result ~ name[position .. $] ~ '\0')[0 .. $ - 1];
}

// LLVM gives `bool` one bit and `real` its 80 bits (`x86_fp80`).
private ulong bitSize(Type type)
{
    auto base = type.toBasetype();
    if (base.ty == Tbool)
        return 1;
    if (base.ty == Tfloat80)
        return 80;
    return base.size() * 8;
}

private string decimal(ulong value)
{
    char[20] digits;
    size_t first = digits.length;
    do
    {
        digits[--first] = cast(char) ('0' + value % 10);
        value /= 10;
    } while (value != 0);
    return digits[first .. $].idup;
}
