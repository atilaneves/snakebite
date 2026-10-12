//===-- gen/dpragma.d - LDC-specific pragma handling --------------*- D -*-===//
//
//                         LDC - the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// D port of the parts of LDC's gen/pragma.cpp that decide what a pragma
// means to the frontend. Nothing here depends on LLVM.
//
//===----------------------------------------------------------------------===//

module gen.dpragma;

import dmd.attrib;
import dmd.astenums;
import dmd.declaration;
import dmd.dscope;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.expressionsem;
import dmd.arraytypes : Expressions;
import dmd.func;
import dmd.id;
import dmd.identifier : Identifier;
import dmd.mtype : Type;
import dmd.optimize;

import core.stdc.stdio : snprintf;
import core.stdc.stdlib : atoi;
import core.stdc.string : strlen;

/// The values of the enumeration of LDC's gen/pragma.h.
enum LDCPragma : uint
{
    LLVMnone = 0,
    LLVMignore,
    LLVMintrinsic,
    LLVMglobal_crt_ctor,
    LLVMglobal_crt_dtor,
    LLVMno_typeinfo,
    LLVMalloca,
    LLVMva_start,
    LLVMva_copy,
    LLVMva_end,
    LLVMva_arg,
    LLVMinline_asm,
    LLVMinline_ir,
    LLVMfence,
    LLVMatomic_store,
    LLVMatomic_load,
    LLVMatomic_cmp_xchg,
    LLVMatomic_rmw,
    LLVMbitop_bt,
    LLVMbitop_btc,
    LLVMbitop_btr,
    LLVMbitop_bts,
    LLVMbitop_vld,
    LLVMbitop_vst,
    LLVMconvertvector,
    LLVMextern_weak,
    LLVMprofile_instr,
}

private bool parseStringExp(Expression e, out const(char)* result)
{
    e = e.optimize(WANTvalue);
    auto se = e.isStringExp();
    if (se is null)
        return false;
    result = se.toStringz().ptr;
    return true;
}

private bool parseIntExp(Expression e, out ulong result)
{
    e = e.optimize(WANTvalue);
    if (auto i = e.isIntegerExp())
    {
        result = i.getInteger();
        return true;
    }
    return false;
}

private bool parseBoolExp(Expression e, out bool result)
{
    e = e.optimize(WANTvalue);
    if (auto i = e.isIntegerExp())
    {
        if (e.type.equals(Type.tbool))
        {
            result = i.toInteger() != 0;
            return true;
        }
    }
    return false;
}

// Applies `action` to every symbol of type `T` that `s` is or holds in nested
// attribute declarations, and returns how many there are.
private int applyPragma(T)(Dsymbol s, T function(Dsymbol) predicate, scope void delegate(T) action)
{
    if (T match = predicate(s))
    {
        if (match.llvmInternal != LDCPragma.LLVMnone)
        {
            error(s.loc, "multiple LDC specific pragmas are not allowed");
            fatal();
        }
        action(match);
        return 1;
    }

    if (auto ad = s.isAttribDeclaration())
    {
        if (ad.decl)
        {
            int count = 0;
            foreach (child; *ad.decl)
                count += applyPragma!T(child, predicate, action);
            return count;
        }
    }
    return 0;
}

private int applyFunctionPragma(Dsymbol s, scope void delegate(FuncDeclaration) action)
{
    return applyPragma!FuncDeclaration(s, (Dsymbol s) => s.isFuncDeclaration(), action);
}

private int applyTemplatePragma(Dsymbol s, scope void delegate(TemplateDeclaration) action)
{
    return applyPragma!TemplateDeclaration(s, (Dsymbol s) => s.isTemplateDeclaration(), action);
}

private int applyVariablePragma(Dsymbol s, scope void delegate(VarDeclaration) action)
{
    return applyPragma!VarDeclaration(s, (Dsymbol s) => s.isVarDeclaration(), action);
}

/// Which LDC pragma `decl` is, and its string argument in `arg1str`.
LDCPragma DtoGetPragma(Scope* sc, PragmaDeclaration decl, ref const(char)* arg1str)
{
    Identifier ident = decl.ident;
    Expressions* args = decl.args;

    Expression getFirstArg()
    {
        return (args && args.length > 0) ? (*args)[0].expressionSemantic(sc) : null;
    }

    void pragmaError(const(char)* message)
    {
        error(decl.loc, "`pragma(%s)` %s", decl.ident.toChars(), message);
    }

    // `pragma(name)` with no parameters, and the value that it gives.
    LDCPragma withoutParameters(LDCPragma result)
    {
        if (args && args.length > 0)
        {
            pragmaError("takes no parameters");
            fatal();
        }
        return result;
    }

    if (ident == Id.LDC_intrinsic)
    {
        if (!args || args.length != 1 || !parseStringExp(getFirstArg(), arg1str))
        {
            pragmaError("requires exactly 1 string literal parameter");
            fatal();
        }

        static struct LdcIntrinsic
        {
            string name;
            LDCPragma pragma_;
        }
        static immutable LdcIntrinsic[] ldcIntrinsics = [
            LdcIntrinsic("bitop.bt", LDCPragma.LLVMbitop_bt),
            LdcIntrinsic("bitop.btc", LDCPragma.LLVMbitop_btc),
            LdcIntrinsic("bitop.btr", LDCPragma.LLVMbitop_btr),
            LdcIntrinsic("bitop.bts", LDCPragma.LLVMbitop_bts),
            LdcIntrinsic("bitop.vld", LDCPragma.LLVMbitop_vld),
            LdcIntrinsic("bitop.vst", LDCPragma.LLVMbitop_vst),
            LdcIntrinsic("convertvector", LDCPragma.LLVMconvertvector),
        ];

        const name = arg1str[0 .. strlen(arg1str)];
        if (name.length > "ldc.".length && name[0 .. "ldc.".length] == "ldc.")
        {
            foreach (entry; ldcIntrinsics)
                if (name["ldc.".length .. $] == entry.name)
                    return entry.pragma_;
        }
        return LDCPragma.LLVMintrinsic;
    }

    if (ident == Id.LDC_global_crt_ctor || ident == Id.LDC_global_crt_dtor
        || ident == Id.crt_constructor || ident == Id.crt_destructor)
    {
        ulong priority = 65535;
        if (args)
        {
            if (args.length != 1 || !parseIntExp(getFirstArg(), priority))
            {
                pragmaError("requires at most 1 integer literal parameter");
                fatal();
            }
            if (priority > 65535)
            {
                pragmaError("may not have a priority greater than 65535");
                priority = 65535;
            }
        }
        char[8] buffer;
        snprintf(buffer.ptr, buffer.length, "%llu", priority);
        arg1str = (buffer[0 .. strlen(buffer.ptr) + 1]).idup.ptr;
        return ident == Id.LDC_global_crt_ctor || ident == Id.crt_constructor
            ? LDCPragma.LLVMglobal_crt_ctor
            : LDCPragma.LLVMglobal_crt_dtor;
    }

    if (ident == Id.LDC_no_typeinfo)
        return withoutParameters(LDCPragma.LLVMno_typeinfo);

    // The module flags of LDC's `pragma(LDC_no_moduleinfo)` and
    // `pragma(LDC_verbose)` steer its code generator; the frontend here
    // has nothing to set.
    if (ident == Id.LDC_no_moduleinfo || ident == Id.LDC_verbose)
        return withoutParameters(LDCPragma.LLVMignore);

    if (ident == Id.LDC_alloca)
        return withoutParameters(LDCPragma.LLVMalloca);
    if (ident == Id.LDC_va_start)
        return withoutParameters(LDCPragma.LLVMva_start);
    if (ident == Id.LDC_va_copy)
        return withoutParameters(LDCPragma.LLVMva_copy);
    if (ident == Id.LDC_va_end)
        return withoutParameters(LDCPragma.LLVMva_end);
    if (ident == Id.LDC_va_arg)
        return withoutParameters(LDCPragma.LLVMva_arg);
    if (ident == Id.LDC_fence)
        return withoutParameters(LDCPragma.LLVMfence);
    if (ident == Id.LDC_atomic_load)
        return withoutParameters(LDCPragma.LLVMatomic_load);
    if (ident == Id.LDC_atomic_store)
        return withoutParameters(LDCPragma.LLVMatomic_store);
    if (ident == Id.LDC_atomic_cmp_xchg)
        return withoutParameters(LDCPragma.LLVMatomic_cmp_xchg);

    if (ident == Id.LDC_atomic_rmw)
    {
        if (!args || args.length != 1 || !parseStringExp(getFirstArg(), arg1str))
        {
            pragmaError("requires exactly 1 string literal parameter");
            fatal();
        }
        return LDCPragma.LLVMatomic_rmw;
    }

    if (ident == Id.LDC_inline_asm)
        return withoutParameters(LDCPragma.LLVMinline_asm);
    if (ident == Id.LDC_inline_ir)
        return withoutParameters(LDCPragma.LLVMinline_ir);
    if (ident == Id.LDC_extern_weak)
        return withoutParameters(LDCPragma.LLVMextern_weak);

    // `DtoCheckProfileInstrPragma` checks the arguments.
    if (ident == Id.LDC_profile_instr)
        return LDCPragma.LLVMprofile_instr;

    return LDCPragma.LLVMnone;
}

/// Marks the declarations that `sym` holds for the pragma `llvm_internal`.
void DtoCheckPragma(PragmaDeclaration decl, Dsymbol s, LDCPragma llvm_internal, const(char)* arg1str)
{
    if (llvm_internal == LDCPragma.LLVMnone || llvm_internal == LDCPragma.LLVMignore
        || llvm_internal == LDCPragma.LLVMprofile_instr)
        return;

    Identifier ident = decl.ident;

    void wrongCount(const(char)* what)
    {
        error(s.loc, "the `%s` pragma doesn't affect exactly 1 %s declaration", ident.toChars(), what);
        fatal();
    }

    with (LDCPragma) switch (llvm_internal)
    {
    case LLVMintrinsic:
    {
        int count = applyFunctionPragma(s, (FuncDeclaration fd) {
            fd.llvmInternal = llvm_internal;
            fd.mangleOverride = arg1str[0 .. strlen(arg1str)];
        });
        count += applyTemplatePragma(s, (TemplateDeclaration td) {
            td.llvmInternal = llvm_internal;
            td.intrinsicName = arg1str;
        });
        if (count != 1)
        {
            error(s.loc, "the `%s` pragma doesn't affect exactly 1 function/template declaration", ident.toChars());
            fatal();
        }
        break;
    }

    case LLVMglobal_crt_ctor:
    case LLVMglobal_crt_dtor:
    {
        const count = applyFunctionPragma(s, (FuncDeclaration fd) {
            auto tf = fd.type.isTypeFunction();
            assert(tf);

            bool isValid = false;
            if (tf.next.ty != Tvoid)
                error(fd.loc, "%s `%s` must return `void` for `pragma(%s)`", fd.kind(), fd.toPrettyChars(), ident.toChars());
            else if (tf.parameterList.length > 0)
                error(fd.loc, "%s `%s` must not take any parameters for `pragma(%s)`", fd.kind(), fd.toPrettyChars(), ident.toChars());
            else if (fd.isThis())
                error(fd.loc, "%s `%s` cannot be a non-static member function for `pragma(%s)`", fd.kind(), fd.toPrettyChars(), ident.toChars());
            else
                isValid = true;

            if (llvm_internal == LLVMglobal_crt_ctor)
                fd.isCrtCtor = isValid;
            else
                fd.isCrtDtor = isValid;
            if (isValid)
                fd.priority = atoi(arg1str);
        });
        if (count != 1)
            wrongCount("function");
        break;
    }

    case LLVMatomic_rmw:
    case LLVMconvertvector:
    {
        const count = applyTemplatePragma(s, (TemplateDeclaration td) {
            td.llvmInternal = llvm_internal;
            td.intrinsicName = arg1str;
        });
        if (count != 1)
            wrongCount("template");
        break;
    }

    case LLVMva_start:
    case LLVMva_arg:
    case LLVMatomic_load:
    case LLVMatomic_store:
    case LLVMatomic_cmp_xchg:
    {
        const count = applyTemplatePragma(s, (TemplateDeclaration td) {
            if (td.parameters.length != 1)
            {
                error(s.loc, "the `%s` pragma template must have exactly one template parameter", ident.toChars());
                fatal();
            }
            else if (!td.onemember)
            {
                error(s.loc, "the `%s` pragma template must have exactly one member", ident.toChars());
                fatal();
            }
            else if (td.overnext || td.overroot)
            {
                error(s.loc, "the `%s` pragma template must not be overloaded", ident.toChars());
                fatal();
            }
            td.llvmInternal = llvm_internal;
        });
        if (count != 1)
            wrongCount("template");
        break;
    }

    case LLVMalloca:
    case LLVMva_copy:
    case LLVMva_end:
    case LLVMfence:
    case LLVMbitop_bt:
    case LLVMbitop_btc:
    case LLVMbitop_btr:
    case LLVMbitop_bts:
    case LLVMbitop_vld:
    case LLVMbitop_vst:
    {
        const count = applyFunctionPragma(s, (FuncDeclaration fd) {
            fd.llvmInternal = llvm_internal;
        });
        if (count != 1)
            wrongCount("function");
        break;
    }

    case LLVMno_typeinfo:
        applyPragma!Dsymbol(s, (Dsymbol s) => s, (Dsymbol s) {
            s.llvmInternal = llvm_internal;
        });
        break;

    case LLVMinline_asm:
    {
        const count = applyTemplatePragma(s, (TemplateDeclaration td) {
            if (td.parameters.length > 1)
            {
                error(s.loc, "the `%s` pragma template must have exactly zero or one template parameters", ident.toChars());
                fatal();
            }
            else if (!td.onemember)
            {
                error(s.loc, "the `%s` pragma template must have exactly one member", ident.toChars());
                fatal();
            }
            td.llvmInternal = llvm_internal;
        });
        if (count != 1)
            wrongCount("template");
        break;
    }

    case LLVMinline_ir:
    {
        const count = applyTemplatePragma(s, (TemplateDeclaration td) {
            if (!td.onemember)
            {
                error(s.loc, "the `%s` pragma template must have exactly one member", ident.toChars());
                fatal();
            }
            td.llvmInternal = llvm_internal;
        });
        if (count != 1)
            wrongCount("template");
        break;
    }

    case LLVMextern_weak:
    {
        int count = applyVariablePragma(s, (VarDeclaration vd) {
            if (!vd.isDataseg() || !(vd.storage_class & STC.extern_))
            {
                error(s.loc, "`%s` requires storage class `extern`", ident.toChars());
                fatal();
            }
            // The interaction of weak symbols and thread-local storage is
            // not well defined, so LDC refuses the pair.
            if (vd.isThreadlocal())
            {
                error(s.loc, "`%s` cannot be applied to thread-local variable `%s`", ident.toChars(), vd.toPrettyChars());
                fatal();
            }
            vd.llvmInternal = llvm_internal;
        });
        count += applyFunctionPragma(s, (FuncDeclaration fd) {
            if (fd.fbody)
            {
                error(s.loc, "`%s` cannot be applied to function definitions", ident.toChars());
                fatal();
            }
            fd.llvmInternal = llvm_internal;
        });
        if (count == 0)
        {
            error(s.loc, "the `%s` pragma doesn't affect any variable or function declarations", ident.toChars());
            fatal();
        }
        break;
    }

    default:
        warning(s.loc, "the LDC specific pragma `%s` is not yet implemented, ignoring", ident.toChars());
    }
}

bool DtoIsIntrinsic(FuncDeclaration fd)
{
    return fd.llvmInternal == LDCPragma.LLVMintrinsic || DtoIsMagicIntrinsic(fd);
}

bool DtoIsMagicIntrinsic(FuncDeclaration fd)
{
    with (LDCPragma) switch (fd.llvmInternal)
    {
    case LLVMva_start:
    case LLVMva_copy:
    case LLVMva_arg:
    case LLVMva_end:
    case LLVMalloca:
    case LLVMfence:
    case LLVMatomic_store:
    case LLVMatomic_load:
    case LLVMatomic_cmp_xchg:
    case LLVMatomic_rmw:
    case LLVMbitop_bt:
    case LLVMbitop_btc:
    case LLVMbitop_btr:
    case LLVMbitop_bts:
    case LLVMbitop_vld:
    case LLVMbitop_vst:
    case LLVMconvertvector:
        return true;
    default:
        return false;
    }
}

// pragma(LDC_profile_instr, [true | false])
// Returns false if an error occurred.
bool DtoCheckProfileInstrPragma(Expression arg, ref bool value)
{
    return parseBoolExp(arg, value);
}
