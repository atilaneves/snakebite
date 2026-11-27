/**
The dmd names that code outside the frontend package uses. Only the package
`snakebite.frontend` imports dmd modules; the build fails when another own
module does (`build/frontend_boundary.py`, ADR 0015). Every other dmd function
is reached through `snakebite.frontend.compiler.inFrontend`, which takes the
frontend lock: `inFrontend!"mutableOf"(type)`.

An entry is an alias of the dmd symbol, so a call costs what a direct call
costs. A selective import of a name that is not here does not compile.

The rule for a function on this list: the function, read to its leaves in the
dmd source of the version that snakebite links (2.113.0), writes only its own
stack, reads no global table, and reads only fields that dmd does not write
after the parse that made the node returns. A function that is safe only for
some arguments (`toBasetype`) is not on the list: the frontend package gives a
function that is always safe (`snakebite.frontend.typefacts.baseType`).

The block marked "not reviewed" below does not follow this rule yet. It holds
50 names (functions and the globals `global`, `target`, `diagnostics` and
`Id`) that outside code called, or read, directly when the boundary was made,
among them `size`. Each is to be shown safe or replaced by a function of the
frontend package, and then removed from the block. Until then the build does
not check a call of them with the lock.

Not on the list, and not caught by the build: a member that a node value or a
type on the list gives (a method, a static), and a read of a node field that
dmd still writes.
*/
module snakebite.frontend.ast;

// Node types and the other dmd types.
public import dmd.aggregate: AggregateDeclaration;
public import dmd.arraytypes: Expressions, FuncDeclarations;
public import dmd.backend.cdef: Vconst;
public import dmd.common.outbuffer: OutBuffer;
public import dmd.ctfeexpr: UnionExp;
public import dmd.dclass: BaseClass, ClassDeclaration, InterfaceDeclaration;
public import dmd.declaration: Declaration, ThisDeclaration,
    TypeInfoClassDeclaration, TypeInfoDeclaration, VarDeclaration;
public import dmd.denum: EnumDeclaration;
public import dmd.dmodule: Module;
public import dmd.dstruct: StructDeclaration, UnionDeclaration;
public import dmd.dsymbol: Dsymbol;
public import dmd.dtemplate: TemplateDeclaration, TemplateInstance;
public import dmd.expression: AddAssignExp, AddExp, AddrExp, AndAssignExp,
    AndExp, ArrayExp, ArrayLengthExp, ArrayLiteralExp, AssertExp, AssignExp,
    AssocArrayLiteralExp, BinAssignExp, BinExp, BlitExp, CallExp, CastExp,
    CatAssignExp, CatDcharAssignExp, CatElemAssignExp, CatExp,
    ClassReferenceExp, CmpExp, ComExp, CommaExp, ComplexExp, CompoundLiteralExp,
    CondExp, ConstructExp, CTFEExp, DeclarationExp, DefaultInitExp, DelegateExp,
    DelegateFuncptrExp, DelegatePtrExp, DeleteExp, DivAssignExp, DivExp,
    DollarExp, DotExp, DotIdExp, DotTemplateExp, DotTemplateInstanceExp,
    DotTypeExp, DotVarExp, DsymbolExp, EqualExp, ErrorExp, Expression,
    FileInitExp, FuncExp, FuncInitExp, GenericExp, HaltExp, IdentifierExp,
    IdentityExp, ImportExp, IndexExp, InExp, IntegerExp, InterpExp, IntervalExp,
    IsExp, LineInitExp, LogicalExp, LoweredAssignExp, MinAssignExp, MinExp,
    MixinExp, ModAssignExp, ModExp, ModuleInitExp, MulAssignExp, MulExp, NegExp,
    NewAnonClassExp, NewExp, NotExp, NullExp, ObjcClassReferenceExp,
    OrAssignExp, OrExp, OverExp, PostExp, PowAssignExp, PowExp, PreExp,
    PrettyFuncInitExp, PtrExp, RealExp, RemoveExp, ScopeExp, ShlAssignExp,
    ShlExp, ShrAssignExp, ShrExp, SliceExp, StringExp, StructLiteralExp,
    SuperExp, SymbolExp, SymOffExp, TemplateExp, ThisExp, ThrowExp,
    ThrownExceptionExp, TraitsExp, TupleExp, TypeExp, TypeidExp, UAddExp,
    UnaExp, UshrAssignExp, UshrExp, VarExp, VectorArrayExp, VectorExp,
    VoidInitExp, XorAssignExp, XorExp;
public import dmd.func: FuncDeclaration, FuncLiteralDeclaration;
public import dmd.identifier: Identifier;
public import dmd.init: ExpInitializer;
public import dmd.location: Loc;
public import dmd.mtype: Parameter, ParameterList, Type, TypeFunction;
public import dmd.rootobject: RootObject;
public import dmd.statement: AsmStatement, BreakStatement, CaseRangeStatement,
    CaseStatement, Catch, CompoundStatement, ConditionalStatement,
    ContinueStatement, DebugStatement, DefaultStatement, DoStatement,
    ErrorStatement, ExpStatement, ForeachRangeStatement, ForeachStatement,
    ForStatement, ForwardingStatement, GccAsmStatement, GotoCaseStatement,
    GotoDefaultStatement, GotoStatement, IfStatement, ImportStatement,
    InlineAsmStatement, LabelStatement, MixinStatement, PeelStatement,
    PragmaStatement, ReturnStatement, ScopeGuardStatement, ScopeStatement,
    Statement, StaticAssertStatement, StaticForeachStatement,
    SwitchErrorStatement, SwitchStatement, SynchronizedStatement,
    ThrowStatement, TryCatchStatement, TryFinallyStatement,
    UnrolledLoopStatement, WhileStatement, WithStatement;
public import dmd.visitor: SemanticTimeTransitiveVisitor, StoppableVisitor,
    Visitor;
public import dmd.visitor.statement_rewrite_walker: StatementRewriteWalker;

// Enums and their members.
public import dmd.astenums: CHECKACTION, CHECKENABLE, FileType, LINK, STC, STMT,
    StorageClass, Taarray, Tarray, Tbool, Tchar, Tclass, Tcomplex32, Tcomplex64,
    Tcomplex80, Tdchar, Tdelegate, Tenum, Terror, Tfloat32, Tfloat64, Tfloat80,
    Tfunction, Tident, Timaginary32, Timaginary64, Timaginary80, Tinstance,
    Tint128, Tint16, Tint32, Tint64, Tint8, Tmixin, Tnone, Tnoreturn, Tnull,
    Tpointer, Treference, Treturn, TRUST, Tsarray, Tslice, Tstruct, Ttag,
    Ttraits, Ttuple, Ttypeof, Tuns128, Tuns16, Tuns32, Tuns64, Tuns8, Tvector,
    Tvoid, Twchar, TY, VarArg;
public import dmd.errors: ErrorKind;
public import dmd.expression: MemorySet;
public import dmd.tokens: EXP, TOK;

// Not reviewed. Code outside the frontend package called these dmd functions,
// and read these dmd globals, directly when the boundary was made. Each one is
// to be shown safe with no lock by the rule above, or replaced by a function
// of the frontend package, and then removed from this block.
public import dmd.common.blake3: blake3;
public import dmd.constfold: Add, And, Cast, Cmp, Com, Div, Equal, Identity,
    Min, Mod, Mul, Neg, Not, Or, Shl, Shr, Ushr, Xor;
public import dmd.ctfeexpr: emplaceExp;
public import dmd.dsymbolsem: apply, fillVtbl, followInstantiationContext,
    hasPointers, isAbstract, toAlias, toParentP;
public import dmd.dtemplate: getType, isDsymbol, isExpression, isTuple, isType;
public import dmd.errors: diagnostics;
public import dmd.expressionsem: isLvalue, toImaginary;
public import dmd.funcsem: overloadApply;
public import dmd.globals: global;
public import dmd.id: Id;
public import dmd.root.string: toDString;
public import dmd.sideeffect: hasSideEffect, isTrivialExp;
public import dmd.target: target;
public import dmd.typesem: hasPointers, isFloating, isIntegral, isReal,
    isUnsigned, nextOf, size, toDsymbol;
public import dmd.visitor.postorder: walkPostorder;
