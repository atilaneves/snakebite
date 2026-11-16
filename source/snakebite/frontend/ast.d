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
some arguments (`toBasetype`, `size`) is not on the list: the frontend package
gives a function that is always safe (`snakebite.frontend.typefacts.baseType`,
`representationSize`).

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
public import dmd.dstruct: StructDeclaration;
public import dmd.dsymbol: Dsymbol;
public import dmd.dtemplate: TemplateDeclaration, TemplateInstance;
public import dmd.expression: AddAssignExp, AddExp, AddrExp, ArrayLiteralExp,
    AssertExp, AssignExp, AssocArrayLiteralExp, BinAssignExp, BinExp, CallExp,
    CastExp, CatAssignExp, CatDcharAssignExp, CatElemAssignExp, CatExp,
    ClassReferenceExp, CmpExp, CommaExp, CondExp, ConstructExp,
    DeclarationExp, DelegateExp, DeleteExp, DotVarExp, EqualExp, ErrorExp,
    Expression, FuncExp, HaltExp, IdentityExp, IndexExp, IntegerExp,
    LogicalExp, LoweredAssignExp, MinAssignExp, MinExp, NewExp, PostExp,
    RealExp, SliceExp, StringExp, StructLiteralExp, SymOffExp, ThisExp,
    ThrowExp, TupleExp, TypeidExp, UnaExp, VarExp, VectorExp;
public import dmd.func: FuncDeclaration;
public import dmd.identifier: Identifier;
public import dmd.init: ExpInitializer;
public import dmd.location: Loc;
public import dmd.mtype: Parameter, ParameterList, Type, TypeFunction;
public import dmd.rootobject: RootObject;
public import dmd.statement: BreakStatement, CaseStatement, Catch,
    CompoundStatement, ContinueStatement, DefaultStatement, DoStatement,
    ErrorStatement, ExpStatement, ForStatement, GotoCaseStatement,
    GotoDefaultStatement, GotoStatement, IfStatement, ImportStatement,
    LabelStatement, ReturnStatement, ScopeGuardStatement, ScopeStatement,
    Statement, SwitchErrorStatement, SwitchStatement, ThrowStatement,
    TryCatchStatement, TryFinallyStatement, UnrolledLoopStatement,
    WithStatement;
public import dmd.visitor: SemanticTimeTransitiveVisitor, StoppableVisitor,
    Visitor;
public import dmd.visitor.statement_rewrite_walker: StatementRewriteWalker;

// Enums and their members.
public import dmd.astenums: CHECKACTION, CHECKENABLE, FileType, LINK, STC,
    STMT, StorageClass, TRUST, TY, Taarray, Tarray, Tbool, Tchar, Tclass,
    Tcomplex80, Tdchar, Tdelegate, Terror, Tfloat32, Tfloat64, Tfloat80,
    Tfunction, Timaginary32, Timaginary64, Timaginary80, Tint16, Tint32,
    Tint64, Tint8, Tnoreturn, Tnull, Tpointer, Tsarray, Tstruct, Ttuple,
    Tuns16, Tuns32, Tuns64, Tuns8, Tvector, Tvoid, Twchar, VarArg;
public import dmd.errors: ErrorKind;
public import dmd.expression: MemorySet;
public import dmd.tokens: EXP, TOK;

// Not reviewed. Code outside the frontend package called these dmd functions,
// and read these dmd globals, directly when the boundary was made. Each one is
// to be shown safe with no lock by the rule above, or replaced by a function
// of the frontend package, and then removed from this block.
public import dmd.common.blake3: blake3;
public import dmd.ctfeexpr: emplaceExp;
public import dmd.dsymbolsem: apply, fillVtbl, followInstantiationContext,
    hasPointers, isAbstract, toAlias, toParentP;
public import dmd.dtemplate: getType, isDsymbol, isExpression, isTuple, isType;
public import dmd.errors: diagnostics;
public import dmd.expressionsem: isLvalue, toImaginary;
public import dmd.funcsem: needsClosure, overloadApply;
public import dmd.globals: global;
public import dmd.id: Id;
public import dmd.root.string: toDString;
public import dmd.sideeffect: hasSideEffect, isTrivialExp;
public import dmd.target: target;
public import dmd.typesem: hasPointers, isFloating, isIntegral, isReal,
    isUnsigned, nextOf, size, toDsymbol;
public import dmd.visitor.postorder: walkPostorder;
