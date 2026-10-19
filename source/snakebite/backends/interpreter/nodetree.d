module snakebite.backends.interpreter.nodetree;

// A function body runs as a tree of `Node` objects. A statement's nodes are
// built when the statement first runs, so a statement that never runs costs
// nothing. Scalar expressions return their value in a register, and a
// parent that knows the kind of a leaf child reads it inline. Everything the
// tree does not cover runs through `GenericStatement` and
// `GenericCondition`, which hand the dmd node to the evaluator.

private:

import dmd.declaration: VarDeclaration;
import dmd.expression: AssignExp, BinAssignExp, BinExp, CallExp, CastExp,
    DeclarationExp, Expression, IndexExp, PostExp, ThisExp;
import dmd.func: FuncDeclaration;
import dmd.location: Loc;
import dmd.mtype: Type;
import dmd.statement: Statement;
import snakebite.backends.checkplan: BoundsCheck;
import snakebite.backends.controlflow: ControlFlowState;
import snakebite.backends.interpreter.integeroperations: combine, shifted;
import snakebite.nativelayout: TypeFacts;
import std.meta: AliasSeq;
import std.traits: Select, isFloatingPoint;

// How a statement node ended. `generic` means the evaluator ran the
// statement and left a control transfer pending for the enclosing node to
// resolve.
package enum TreeFlow : ubyte { normal, break_, continue_, return_, generic }

package struct TreeRoot {
    private const(imported!"snakebite.backends.layout".FrameLayout)* _layout;
    private Node _body;

    package bool hasLayout(
        in imported!"snakebite.backends.layout".FrameLayout* layout,
    ) const {
        return _layout is layout;
    }

    package TreeFlow execute(ubyte* frame) {
        return _body.executeStmt(frame);
    }
}

package TreeRoot* rootOf(E)(
    E ev, Statement body_,
    const(imported!"snakebite.backends.layout".FrameLayout)* layout,
) {
    auto root = new TreeRoot;
    root._layout = layout;
    root._body = new Uninitialised!E(ev, body_, &root._body);
    return root;
}

// What a call node needs to know about its callee, decided once per
// function.
package struct TreeCallee {
    package FuncDeclaration function_;
    package const(imported!"snakebite.backends.layout".FrameLayout)* layout;
    package const(imported!"snakebite.backends.closureplan".ClosurePlan)*
        closurePlan;
    package TreeRoot* root;
    package Type returnType;
    package TypeFacts returnFacts;
    // Whether the frame meets the contract of `FrameStack.reserveFast`.
    package bool reservesFast;
}

package bool isScalar(E)(E ev, Type type) {
    return scalarOf(ev, type).kind != Scalar.Kind.none;
}

// Where a statement names the full expression it runs, so that a fault in
// it reports that expression's line. A statement that cannot fault does not
// need one, but this costs one store, and a node that decides what can
// fault could be wrong.
private struct Position {
    private const(void)** _slot;
    private const(void)* _root;

    public void note() {
        *_slot = _root;
    }
}

private abstract class Node {
    public long executeLong(ubyte* frame) { assert(0); }
    public double executeDouble(ubyte* frame) { assert(0); }
    public bool executeBool(ubyte* frame) { return executeLong(frame) != 0; }
    public ubyte* executeAddr(ubyte* frame) { assert(0); }
    public void executeVoid(ubyte* frame) { assert(0); }
    public TreeFlow executeStmt(ubyte* frame) { assert(0); }
    public bool runsAsStatement() { return false; }
    public void positionAt(Position position) { assert(0); }

    // The statement nodes that hold this node as their condition. A node
    // that is not a fused test is called through `NodeCondition`.
    public Loop forLoop(
        ControlFlowState* controlFlow, Node increment, Position position,
    ) {
        return new ForLoop!NodeCondition(
            controlFlow, NodeCondition(this), increment, position);
    }
    public Loop doLoop(ControlFlowState* controlFlow, Position position) {
        return new DoLoop!NodeCondition(
            controlFlow, NodeCondition(this), position);
    }
    public Branches ifThenElse(Position position) {
        return new IfThenElse!NodeCondition(NodeCondition(this), position);
    }

    // `flag && this`, where `flag` is a `bool` frame slot.
    public Node andFlag(size_t offset) {
        return new Tested!(FlagAnd!NodeCondition)(
            FlagAnd!NodeCondition(offset, NodeCondition(this)));
    }
}

private abstract class LongNode : Node {
    public override void executeVoid(ubyte* frame) { executeLong(frame); }
}

private abstract class DoubleNode : Node {
    public override bool executeBool(ubyte* frame) { return executeDouble(frame) != 0; }
    public override void executeVoid(ubyte* frame) { executeDouble(frame); }
}

private abstract class BoolNode : LongNode {
    public abstract override bool executeBool(ubyte* frame);
    public override long executeLong(ubyte* frame) { return executeBool(frame) ? 1 : 0; }
}

// The register type that carries a value of scalar type `T`, and the node
// base class that returns it.
private alias Carried(T) = Select!(isFloatingPoint!T, double, long);
private alias Typed(T) = Select!(isFloatingPoint!T, DoubleNode, LongNode);

// A class that is final calls its own `executeLong` directly, which a base
// class cannot, so a node that is often a condition says so itself.
private mixin template BoolFromLong() {
    public override bool executeBool(ubyte* frame) { return executeLong(frame) != 0; }
}

// The node is also a statement: the enclosing sequence runs it with no
// wrapper node.
private mixin template StatementForm(string method) {
    private Position _position;

    public override bool runsAsStatement() { return true; }
    public override void positionAt(Position position) {
        _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note;
        mixin(method ~ "(frame);");
        return TreeFlow.normal;
    }
}

private enum simpleOp(string op) = op == "+" || op == "-" || op == "*"
    || op == "&" || op == "|" || op == "^";
private enum shiftOp(string op) = op == "<<" || op == ">>" || op == ">>>";

// The operand kinds that the node of `op` on `T` is built for. A 32-bit
// operation has no 64-bit local operand: a 64-bit value reaches it through
// a cast.
private template operandsOf(string op, T) {
    static if (op == "+" || op == "-" || op == "*") {
        static if (is(T == int)) {
            public enum Kind[] lefts = intLeft;
            public enum Kind[] rights = intRight;
        } else static if (is(T == long)) {
            public enum Kind[] lefts = longLeft;
            public enum Kind[] rights = longRight;
        } else {
            public enum Kind[] lefts = onlyChild;
            public enum Kind[] rights = onlyChild;
        }
    } else {
        public enum Kind[] lefts = onlyChild;
        public enum Kind[] rights = onlyChild;
    }
}

// --- leaves -----------------------------------------------------------

private final class Constant(V) : Typed!V {
    private V _value;
    public this(V value) { _value = value; }
    static if (is(V == double))
        public override double executeDouble(ubyte*) { return _value; }
    else
        public override long executeLong(ubyte*) { return _value; }
}

private final class Local(T) : Typed!T {
    private size_t _offset;
    public this(size_t offset) { _offset = offset; }
    static if (isFloatingPoint!T)
        public override double executeDouble(ubyte* frame) {
            return *cast(T*) (frame + _offset);
        }
    else {
        public override long executeLong(ubyte* frame) {
            return *cast(T*) (frame + _offset);
        }
        mixin BoolFromLong;
    }
}

private final class Load(T) : Typed!T {
    private Node _address;
    public this(Node address) { _address = address; }
    static if (isFloatingPoint!T)
        public override double executeDouble(ubyte* frame) {
            return *cast(T*) _address.executeAddr(frame);
        }
    else {
        public override long executeLong(ubyte* frame) {
            return *cast(T*) _address.executeAddr(frame);
        }
        mixin BoolFromLong;
    }
}

// --- addresses --------------------------------------------------------

private final class LocalAddress : Node {
    private size_t _offset;
    public this(size_t offset) { _offset = offset; }
    public override ubyte* executeAddr(ubyte* frame) { return frame + _offset; }
}

// A parameter or local that holds the address of the storage it names.
private final class IndirectLocalAddress : Node {
    private size_t _offset;
    public this(size_t offset) { _offset = offset; }
    public override ubyte* executeAddr(ubyte* frame) {
        return *cast(ubyte**) (frame + _offset);
    }
}

private final class FieldOfAddress : Node {
    private Node _base;
    private size_t _offset;
    public this(Node base, size_t offset) { _base = base; _offset = offset; }
    public override ubyte* executeAddr(ubyte* frame) {
        return _base.executeAddr(frame) + _offset;
    }
}

private final class FieldOfPointer : Node {
    private Node _pointer;
    private size_t _offset;
    public this(Node pointer, size_t offset) { _pointer = pointer; _offset = offset; }
    public override ubyte* executeAddr(ubyte* frame) {
        return cast(ubyte*) _pointer.executeLong(frame) + _offset;
    }
}

private final class Dereference : Node {
    private Node _pointer;
    public this(Node pointer) { _pointer = pointer; }
    public override ubyte* executeAddr(ubyte* frame) {
        return cast(ubyte*) _pointer.executeLong(frame);
    }
}

private alias FailBounds = void delegate(
    in BoundsCheck, in Loc, scope const(void*)[],
);

private final class IndexDynamic(A, I) : Node {
    private FailBounds _fail;
    private IndexExp _expression;
    private A _array;
    private I _index;
    private size_t _stride;
    public this(FailBounds fail, IndexExp expression, A array, I index, size_t stride) {
        _fail = fail; _expression = expression; _array = array; _index = index;
        _stride = stride;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        const index = cast(size_t) _index.value(frame);
        auto array = _array.address(frame);
        const length = *cast(size_t*) array;
        if (index >= length)
            fail(index, length);
        return *cast(ubyte**) (array + size_t.sizeof) + index * _stride;
    }
    // Out of line, so that the check costs the fast path no register.
    pragma(inline, false)
    private void fail(size_t index, size_t length) {
        _fail(BoundsCheck.index, _expression.loc,
            [cast(const(void)*) &index, cast(const(void)*) &length]);
    }
}

private final class IndexStatic : Node {
    private FailBounds _fail;
    private IndexExp _expression;
    private Node _array;
    private Node _index;
    private size_t _stride;
    private size_t _length;
    public this(FailBounds fail, IndexExp expression, Node array, Node index,
            size_t stride, size_t length) {
        _fail = fail; _expression = expression; _array = array; _index = index;
        _stride = stride; _length = length;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        const index = cast(size_t) _index.executeLong(frame);
        if (index >= _length)
            fail(index);
        return _array.executeAddr(frame) + index * _stride;
    }
    pragma(inline, false)
    private void fail(size_t index) {
        auto length = _length;
        _fail(BoundsCheck.index, _expression.loc,
            [cast(const(void)*) &index, cast(const(void)*) &length]);
    }
}

private final class IndexPointer : Node {
    private Node _pointer;
    private Node _index;
    private size_t _stride;
    public this(Node pointer, Node index, size_t stride) {
        _pointer = pointer; _index = index; _stride = stride;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        auto pointer = cast(ubyte*) _pointer.executeLong(frame);
        const index = cast(size_t) _index.executeLong(frame);
        return pointer + index * _stride;
    }
}

// --- operands ---------------------------------------------------------
// A parent reads a leaf child through an operand struct, which holds the
// leaf's data in the parent: the call to the child is gone.

private struct ChildOperand(V, N = Node) {
    public N node;
    public V value(ubyte* frame) {
        static if (is(V == double))
            return node.executeDouble(frame);
        else
            return node.executeLong(frame);
    }
}

private struct LocalOperand(T) {
    public size_t offset;
    public Carried!T value(ubyte* frame) { return *cast(T*) (frame + offset); }
}

private struct ConstantOperand(V) {
    public V constant;
    public V value(ubyte*) { return constant; }
}

private struct ChildAddress {
    public Node node;
    public ubyte* address(ubyte* frame) { return node.executeAddr(frame); }
}

private struct FrameAddress {
    public size_t offset;
    public ubyte* address(ubyte* frame) { return frame + offset; }
}

// The address of an operation's target: a frame slot, or the address a node
// computes.
private struct Target {
    public Node node;
    public size_t offset;
    public ubyte* address(ubyte* frame) {
        return node is null ? frame + offset : node.executeAddr(frame);
    }
}

// What the builder knows about a child node, to choose its operand struct.
private struct Operand {
    public enum Kind : ubyte { child, localInt, localLong, localDouble, constant }

    public Kind kind;
    public Node node;
    public size_t offset;
    public long integer;
    public double floating;
}

private alias Kind = Operand.Kind;

private Operand operandOf(Node node) {
    if (auto leaf = cast(Constant!long) node)
        return Operand(Kind.constant, node, 0, leaf._value);
    if (auto leaf = cast(Constant!double) node)
        return Operand(Kind.constant, node, 0, 0, leaf._value);
    if (auto leaf = cast(Local!int) node)
        return Operand(Kind.localInt, node, leaf._offset);
    if (auto leaf = cast(Local!long) node)
        return Operand(Kind.localLong, node, leaf._offset);
    if (auto leaf = cast(Local!double) node)
        return Operand(Kind.localDouble, node, leaf._offset);
    return Operand(Kind.child, node);
}

private template OperandType(Kind kind, V) {
    static if (kind == Kind.child)
        public alias OperandType = ChildOperand!V;
    else static if (kind == Kind.localInt)
        public alias OperandType = LocalOperand!int;
    else static if (kind == Kind.localLong)
        public alias OperandType = LocalOperand!long;
    else static if (kind == Kind.localDouble)
        public alias OperandType = LocalOperand!double;
    else
        public alias OperandType = ConstantOperand!V;
}

private Op makeOperand(Op)(in Operand operand) {
    static if (is(Op == ChildOperand!V, V))
        return Op(cast() operand.node);
    else static if (is(Op == ConstantOperand!V, V)) {
        static if (is(V == double))
            return Op(operand.floating);
        else
            return Op(operand.integer);
    } else
        return Op(operand.offset);
}

// The operand kinds that a node is built for. A child of another kind is
// read through its node.
private enum Kind[] onlyChild = [Kind.child];
private enum Kind[] intLeft = [Kind.child, Kind.localInt];
private enum Kind[] intRight = [Kind.child, Kind.localInt, Kind.constant];
private enum Kind[] longLeft = [Kind.child, Kind.localInt, Kind.localLong];
private enum Kind[] longRight = [
    Kind.child, Kind.localInt, Kind.localLong, Kind.constant,
];
private enum Kind[] unsignedLeft = [Kind.child, Kind.localLong];
private enum Kind[] unsignedRight = [
    Kind.child, Kind.localLong, Kind.constant,
];
private enum Kind[] doubleLeft = [
    Kind.child, Kind.localDouble, Kind.constant,
];
private enum Kind[] doubleComparedLeft = [Kind.child, Kind.localDouble];

private bool has(in Kind[] kinds, in Kind kind) {
    foreach (candidate; kinds)
        if (candidate == kind)
            return true;
    return false;
}

// Calls `make!(L, R)(left, right, args)`, with the operand structs that
// match the kinds of `left` and `right`, when the kinds are in `lefts` and
// `rights`. Two constants make no node: the left one is read as a child.
private Node fuse(alias make, V, Kind[] lefts, Kind[] rights, Args...)(
    Operand left, Operand right, Args args,
) {
    if (!lefts.has(left.kind)
            || (left.kind == Kind.constant && right.kind == Kind.constant))
        left.kind = Kind.child;
    if (!rights.has(right.kind))
        right.kind = Kind.child;
    static foreach (lk; lefts)
        static foreach (rk; rights)
            static if (lk != Kind.constant || rk != Kind.constant)
                if (left.kind == lk && right.kind == rk)
                    return make!(OperandType!(lk, V), OperandType!(rk, V))(
                        makeOperand!(OperandType!(lk, V))(left),
                        makeOperand!(OperandType!(rk, V))(right), args);
    assert(0, "an operand kind outside the fused kinds");
}

// --- arithmetic -------------------------------------------------------

// The operation of a binary or compound assignment node, with what it needs
// besides its two operands.
private struct Operation(string op) {
    static if (shiftOp!op)
        public imported!"snakebite.backends.shifts".ShiftPlan plan;
    else static if (!simpleOp!op) {
        public TypeFacts leftFacts;
        public TypeFacts rightFacts;
    }

    public ulong apply(in long a, in long b) const {
        static if (shiftOp!op)
            return shifted(a, b, plan);
        else static if (simpleOp!op)
            return cast(ulong) mixin("a " ~ op ~ " b");
        else
            return combine!op(a, b, leftFacts, rightFacts);
    }
}

// `e` keeps its own type: a compound assignment plans its shift differently
// from a plain shift.
private Operation!op operationOf(string op, E, B : BinExp)(E ev, B e) {
    import snakebite.backends.shifts: shiftPlan;

    static if (shiftOp!op)
        return Operation!op(shiftPlan(e));
    else static if (simpleOp!op)
        return Operation!op();
    else
        return Operation!op(ev.factsOf(e.e1.type), ev.factsOf(e.e2.type));
}

private final class IntegerBinary(string op, T, L, R) : LongNode {
    private L _left;
    private R _right;
    private Operation!op _operation;
    public this(L left, R right, Operation!op operation) {
        _left = left; _right = right; _operation = operation;
    }
    public override long executeLong(ubyte* frame) {
        const a = _left.value(frame);
        const b = _right.value(frame);
        return cast(T) _operation.apply(a, b);
    }
    mixin BoolFromLong;
}

private final class FloatBinary(string op, T, L, R) : DoubleNode {
    private L _left;
    private R _right;
    public this(L left, R right) { _left = left; _right = right; }
    public override double executeDouble(ubyte* frame) {
        const a = _left.value(frame);
        const b = _right.value(frame);
        return mixin("cast(T) a " ~ op ~ " cast(T) b");
    }
}

private final class IntegerUnary(string op, T) : LongNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override long executeLong(ubyte* frame) {
        return cast(T) mixin(op ~ "_operand.executeLong(frame)");
    }
}

private final class FloatNegate : DoubleNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override double executeDouble(ubyte* frame) {
        return -_operand.executeDouble(frame);
    }
}

private final class Not : BoolNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override bool executeBool(ubyte* frame) { return !_operand.executeBool(frame); }
}

private final class Truth : BoolNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override bool executeBool(ubyte* frame) { return _operand.executeBool(frame); }
}

private final class AndAnd : BoolNode {
    private Node _left;
    private Node _right;
    public this(Node left, Node right) { _left = left; _right = right; }
    public override bool executeBool(ubyte* frame) {
        return _left.executeBool(frame) && _right.executeBool(frame);
    }
}

private final class OrOr : BoolNode {
    private Node _left;
    private Node _right;
    public this(Node left, Node right) { _left = left; _right = right; }
    public override bool executeBool(ubyte* frame) {
        return _left.executeBool(frame) || _right.executeBool(frame);
    }
}

// Whether evaluating an operand can fault, which it can when it is a node.
private enum operandMayFault(O) = is(O == ChildOperand!(V, N), V, N);

// A test of two operands, which a loop or an `if` can hold in place of the
// node that evaluates it.
private struct IntegerTest(string op, bool unsigned, L, R) {
    public enum mayFault = operandMayFault!L || operandMayFault!R;

    public L left;
    public R right;

    public bool test(ubyte* frame) {
        const a = left.value(frame);
        const b = right.value(frame);
        static if (unsigned)
            return mixin("cast(ulong) a " ~ op ~ " cast(ulong) b");
        else
            return mixin("a " ~ op ~ " b");
    }
}

private struct FloatTest(string op, L, R) {
    public enum mayFault = operandMayFault!L || operandMayFault!R;

    public L left;
    public R right;

    public bool test(ubyte* frame) {
        const a = left.value(frame);
        const b = right.value(frame);
        return mixin("a " ~ op ~ " b");
    }
}

// `flag && right`, where `flag` is a `bool` frame slot.
private struct FlagAnd(T) {
    public enum mayFault = T.mayFault;

    public size_t offset;
    public T right;

    public bool test(ubyte* frame) {
        return *cast(ubyte*) (frame + offset) != 0 && right.test(frame);
    }
}

// The node that evaluates a test, which a loop or an `if` can hold in its
// place.
private final class Tested(T) : BoolNode {
    private T _test;
    public this(T test) { _test = test; }
    public override bool executeBool(ubyte* frame) { return _test.test(frame); }
    public override Loop forLoop(
        ControlFlowState* controlFlow, Node increment, Position position,
    ) {
        return new ForLoop!T(controlFlow, _test, increment, position);
    }
    public override Loop doLoop(
        ControlFlowState* controlFlow, Position position,
    ) {
        return new DoLoop!T(controlFlow, _test, position);
    }
    public override Branches ifThenElse(Position position) {
        return new IfThenElse!T(_test, position);
    }
    // A comparison of an `int` local does not become a bigger test than that.
    static if (is(T == IntegerTest!(op, false, LocalOperand!int, R), string op, R))
        public override Node andFlag(size_t offset) {
            return new Tested!(FlagAnd!T)(FlagAnd!T(offset, _test));
        }
}

private alias IntegerCompare(string op, bool unsigned, L, R)
    = Tested!(IntegerTest!(op, unsigned, L, R));
private alias FloatCompare(string op, L, R) = Tested!(FloatTest!(op, L, R));

// --- casts ------------------------------------------------------------

private final class ClassUpcast : LongNode {
    private Node _operand;
    private long _offset;
    public this(Node operand, long offset) { _operand = operand; _offset = offset; }
    public override long executeLong(ubyte* frame) {
        const value = _operand.executeLong(frame);
        return value == 0 ? 0 : value + _offset;
    }
}

private final class Wrap(T) : LongNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override long executeLong(ubyte* frame) {
        return cast(T) _operand.executeLong(frame);
    }
    mixin BoolFromLong;
}

private final class IntegerToFloat(Source, Dest) : DoubleNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override double executeDouble(ubyte* frame) {
        return cast(Dest) cast(Source) _operand.executeLong(frame);
    }
}

private final class FloatToInteger(T) : LongNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override long executeLong(ubyte* frame) {
        return cast(T) _operand.executeDouble(frame);
    }
}

private final class FloatWidth(T) : DoubleNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override double executeDouble(ubyte* frame) {
        return cast(T) _operand.executeDouble(frame);
    }
}

// --- stores -----------------------------------------------------------

private final class Store(T, A, V) : Typed!T {
    private A _address;
    private V _value;
    public this(A address, V value) { _address = address; _value = value; }
    static if (isFloatingPoint!T) {
        public override double executeDouble(ubyte* frame) {
            auto address = _address.address(frame);
            const T value = cast(T) _value.value(frame);
            *cast(T*) address = value;
            return value;
        }
        mixin StatementForm!"executeDouble";
    } else {
        public override long executeLong(ubyte* frame) {
            auto address = _address.address(frame);
            const T value = cast(T) _value.value(frame);
            *cast(T*) address = value;
            return value;
        }
        mixin StatementForm!"executeLong";
    }
}

// `target op= step` on an integral target of 32 or 64 bits.
private final class IntegerOpAssign(string op, T, A, S) : LongNode {
    private A _target;
    private S _step;
    private Operation!op _operation;
    public this(A target, S step, Operation!op operation) {
        _target = target; _step = step; _operation = operation;
    }
    public override long executeLong(ubyte* frame) {
        auto target = cast(T*) _target.address(frame);
        const b = _step.value(frame);
        const long a = *target;
        const T result = cast(T) _operation.apply(a, b);
        *target = result;
        return result;
    }
    mixin StatementForm!"executeLong";
}

private final class FloatOpAssign(string op, T) : DoubleNode {
    private Target _target;
    private Node _step;
    public this(Target target, Node step) { _target = target; _step = step; }
    public override double executeDouble(ubyte* frame) {
        auto target = cast(T*) _target.address(frame);
        const b = _step.executeDouble(frame);
        const T result = mixin("cast(T) *target " ~ op ~ " cast(T) b");
        *target = result;
        return result;
    }
    mixin StatementForm!"executeDouble";
}

// `target++` and `target--`: the value is the old one.
private final class PostStep(T, long delta) : LongNode {
    private Target _target;
    public this(Target target) { _target = target; }
    public override long executeLong(ubyte* frame) {
        auto target = cast(T*) _target.address(frame);
        const T old = *target;
        *target = cast(T) (old + delta);
        return old;
    }
    mixin StatementForm!"executeLong";
}

// --- statements -------------------------------------------------------

private final class ExpressionStatement : Node {
    private Node _expression;
    private Position _position;
    public this(Node expression, Position position) {
        _expression = expression; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note;
        _expression.executeVoid(frame);
        return TreeFlow.normal;
    }
}

private Node statementOf(Node expression, Position position) {
    if (!expression.runsAsStatement)
        return new ExpressionStatement(expression, position);
    expression.positionAt(position);
    return expression;
}

// A statement that does nothing but end with `flow`.
private final class Jump(TreeFlow flow) : Node {
    public override TreeFlow executeStmt(ubyte*) { return flow; }
}

// The statements of a block, or of a loop body, in the order they run. Ends
// at the first statement that does not finish normally.
private struct Statements {
    public Node[] nodes;

    public TreeFlow run(ubyte* frame) {
        foreach (node; nodes) {
            const flow = node.executeStmt(frame);
            if (flow != TreeFlow.normal)
                return flow;
        }
        return TreeFlow.normal;
    }
}

private final class Sequence : Node {
    private Statements _statements;
    public this(Node[] children) { _statements = Statements(children); }
    public override TreeFlow executeStmt(ubyte* frame) {
        return _statements.run(frame);
    }
}

// A sequence of a few statements, whose children are fields.
private final class ShortSequence(size_t length) : Node {
    private Node[length] _children;
    public override TreeFlow executeStmt(ubyte* frame) {
        static foreach (i; 0 .. length - 1) {{
            const flow = _children[i].executeStmt(frame);
            if (flow != TreeFlow.normal)
                return flow;
        }}
        return _children[length - 1].executeStmt(frame);
    }
}

private abstract class Branches : Node {
    protected Node _then;
    protected Node _else;
}

private final class IfThenElse(C) : Branches {
    private C _condition;
    private Position _position;
    public this(C condition, Position position) {
        _condition = condition; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note;
        if (_condition.test(frame))
            return _then.executeStmt(frame);
        if (_else !is null)
            return _else.executeStmt(frame);
        return TreeFlow.normal;
    }
}

// The condition of a loop that has none.
private struct Always {
    public enum mayFault = false;

    public bool test(ubyte*) { return true; }
}

private struct NodeCondition {
    public enum mayFault = true;

    public Node node;

    public bool test(ubyte* frame) { return node.executeBool(frame); }
}

// A loop holds the statements of its body, not a node that runs them.
private abstract class Loop : Node {
    protected Statements _body;
}

private final class ForLoop(C) : Loop {
    private ControlFlowState* _controlFlow;
    private C _condition;
    private Node _increment;
    private Position _position;
    public this(
        ControlFlowState* controlFlow, C condition, Node increment,
        Position position,
    ) {
        _controlFlow = controlFlow; _condition = condition;
        _increment = increment; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        for (;;) {
            static if (C.mayFault)
                _position.note;
            if (!_condition.test(frame))
                break;
            const flow = _body.run(frame);
            if (flow != TreeFlow.normal) {
                bool exit;
                const result = afterBody(flow, _controlFlow, exit);
                if (exit)
                    return result;
            }
            if (_increment !is null)
                _increment.executeStmt(frame);
        }
        return TreeFlow.normal;
    }
}

// What a loop does after its body ends with `flow`: `exit` is set when the
// loop ends, and the result is the flow that leaves it.
private TreeFlow afterBody(
    in TreeFlow flow, ControlFlowState* controlFlow, out bool exit,
) {
    exit = false;
    if (flow == TreeFlow.break_) {
        exit = true;
        return TreeFlow.normal;
    }
    if (flow == TreeFlow.return_) {
        exit = true;
        return flow;
    }
    if (flow == TreeFlow.generic && controlFlow.leavesLoop(null)) {
        exit = true;
        return controlFlow.hasTransfer ? TreeFlow.generic : TreeFlow.normal;
    }
    return TreeFlow.normal;
}

private final class DoLoop(C) : Loop {
    private ControlFlowState* _controlFlow;
    private C _condition;
    private Position _position;
    public this(
        ControlFlowState* controlFlow, C condition, Position position,
    ) {
        _controlFlow = controlFlow; _condition = condition;
        _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        do {
            const flow = _body.run(frame);
            if (flow != TreeFlow.normal) {
                bool exit;
                const result = afterBody(flow, _controlFlow, exit);
                if (exit)
                    return result;
            }
            static if (C.mayFault)
                _position.note;
        } while (_condition.test(frame));
        return TreeFlow.normal;
    }
}

private final class ReturnValue(T) : Node {
    private void** _place;
    private Node _value;
    private Position _position;
    public this(void** place, Node value, Position position) {
        _place = place; _value = value; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note;
        static if (isFloatingPoint!T)
            const T value = cast(T) _value.executeDouble(frame);
        else
            const T value = cast(T) _value.executeLong(frame);
        if (*_place !is null)
            *cast(T*) (*_place) = value;
        return TreeFlow.return_;
    }
}

private final class GenericStatement(E) : Node {
    private E _ev;
    private Statement _statement;
    public this(E ev, Statement statement) { _ev = ev; _statement = statement; }
    public override TreeFlow executeStmt(ubyte*) {
        // The evaluator runs the statement as it runs one outside the tree:
        // with no expression named until the statement opens one.
        *_ev._temporaries.rootSlot = null;
        _statement.accept(_ev);
        return _ev._controlFlow.hasTransfer ? TreeFlow.generic : TreeFlow.normal;
    }
}

private final class GenericCondition(E) : BoolNode {
    private E _ev;
    private Expression _condition;
    public this(E ev, Expression condition) { _ev = ev; _condition = condition; }
    public override bool executeBool(ubyte*) { return _ev.conditionHolds(_condition); }
}

// Builds its statement's node on first execution and replaces itself in the
// parent's slot.
private final class Uninitialised(E) : Node {
    private E _ev;
    private Statement _statement;
    private Node* _slot;
    public this(E ev, Statement statement, Node* slot) {
        _ev = ev; _statement = statement; _slot = slot;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        auto node = buildStatement(_ev, _statement, _slot);
        *_slot = node;
        return node.executeStmt(frame);
    }
}

// --- calls ------------------------------------------------------------

private enum Argument : ubyte { i8, i16, i32, i64, f32, f64 }

private size_t sizeOf(Argument mode) {
    final switch (mode) with (Argument) {
        case i8: return 1;
        case i16: return 2;
        case f32, i32: return 4;
        case f64, i64: return 8;
    }
}

// Gives the frame stack back to the position it had when this was made.
private struct FrameGuard {
    private imported!"snakebite.framestack".FrameStack* _stack;
    private size_t _mark;

    @disable this();
    @disable this(this);

    public this(imported!"snakebite.framestack".FrameStack* stack) {
        _stack = stack;
        _mark = stack.mark;
    }

    ~this() {
        _stack.release(_mark);
    }
}

// A direct or virtual call of a guest function with scalar parameters and
// result. It pushes the callee frame, evaluates each argument into its
// parameter slot, and runs the callee's node tree.
private final class Call(E) : Node {
    private E _ev;
    private CallExp _site;
    private FuncDeclaration _method;
    private Node _receiver;
    private Node[] _args;
    private Argument[] _modes;
    private size_t _resultSize;
    private bool _resultUnsigned;
    private bool _virtual;
    private bool _receiverIsAddress;
    private TreeCallee* _callee;
    private const(void)* _vtable;

    public this(E ev, CallExp site, FuncDeclaration method, Node receiver,
            bool receiverIsAddress, bool virtual, Node[] args,
            Argument[] modes, size_t resultSize, bool resultUnsigned) {
        _ev = ev; _site = site; _method = method; _receiver = receiver;
        _receiverIsAddress = receiverIsAddress; _virtual = virtual;
        _args = args; _modes = modes; _resultSize = resultSize;
        _resultUnsigned = resultUnsigned;
    }

    public final bool matches(TreeCallee* callee) {
        auto layout = callee.layout;
        if (layout.parameters.length != _modes.length)
            return false;
        foreach (i, parameter; layout.parameters)
            if (parameter.isRef || parameter.facts.size != sizeOf(_modes[i]))
                return false;
        return _resultSize == 0 || callee.returnFacts.size == _resultSize;
    }

    private void invoke(ubyte* frame, ulong* result) {
        auto ev = _ev;
        auto callee = _callee;
        size_t receiver;
        if (_receiver !is null) {
            receiver = _receiverIsAddress
                ? cast(size_t) _receiver.executeAddr(frame)
                : cast(size_t) _receiver.executeLong(frame);
            if (_virtual) {
                if (receiver == 0) {
                    ev._executeMethodCall(_site, result, _method, null);
                    return;
                }
                const vtable = *cast(const(void)**) receiver;
                if (vtable !is _vtable) {
                    callee = ev.virtualTreeCalleeOf(
                        _method, cast(void*) receiver);
                    if (callee is null || !matches(callee)) {
                        ev._executeMethodCall(
                            _site, result, _method, cast(void*) receiver);
                        return;
                    }
                    _callee = callee;
                    _vtable = vtable;
                }
            }
        }

        const layout = callee.layout;
        auto calleeFrame = FrameGuard(&ev._frames);
        auto base = callee.reservesFast
            ? ev._frames.reserveFast(layout.size, layout.alignment) : null;
        if (base is null)
            base = ev._frames.reserve(layout.size, layout.alignment);
        if (layout.hiddenThis.variable !is null)
            *cast(size_t*) (base + layout.hiddenThis.parameter.offset)
                = receiver;
        foreach (i, node; _args) {
            auto place = base + layout.parameters[i].offset;
            final switch (_modes[i]) with (Argument) {
                case i8:
                    *cast(ubyte*) place = cast(ubyte) node.executeLong(frame);
                    break;
                case i16:
                    *cast(ushort*) place = cast(ushort) node.executeLong(frame);
                    break;
                case i32:
                    *cast(uint*) place = cast(uint) node.executeLong(frame);
                    break;
                case i64:
                    *cast(ulong*) place = node.executeLong(frame);
                    break;
                case f32:
                    *cast(float*) place = node.executeDouble(frame);
                    break;
                case f64:
                    *cast(double*) place = node.executeDouble(frame);
                    break;
            }
        }
        if (layout.retainsTemporaries)
            ev._temporaries.withNestedCall(layout.retainsTemporaries, {
                ev.runTreeCallee(callee, base, result);
            });
        else
            ev.runTreeCallee(callee, base, result);
    }

    public override long executeLong(ubyte* frame) {
        ulong buffer;
        invoke(frame, &buffer);
        switch (_resultSize) {
            case 1:
                return _resultUnsigned
                    ? cast(long) cast(ubyte) buffer : cast(long) cast(byte) buffer;
            case 2:
                return _resultUnsigned
                    ? cast(long) cast(ushort) buffer
                    : cast(long) cast(short) buffer;
            case 4:
                return _resultUnsigned
                    ? cast(long) cast(uint) buffer : cast(long) cast(int) buffer;
            default:
                return buffer;
        }
    }

    public override double executeDouble(ubyte* frame) {
        ulong buffer;
        invoke(frame, &buffer);
        return _resultSize == 4
            ? *cast(float*) &buffer : *cast(double*) &buffer;
    }

    public override void executeVoid(ubyte* frame) {
        ulong buffer;
        invoke(frame, &buffer);
    }
}

// --- the builder ------------------------------------------------------
// Each function returns null for an expression the tree does not cover.

private struct Scalar {
    public enum Kind : ubyte { none, integral, floating }

    public Kind kind;
    public TypeFacts facts;
}

private Scalar scalarOf(E)(E ev, Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;

    if (type is null)
        return Scalar();
    switch (type.toBasetype.ty) with (TY) {
        case Tbool, Tint8, Tuns8, Tint16, Tuns16, Tint32, Tuns32, Tint64,
                Tuns64, Tchar, Twchar, Tdchar:
            return Scalar(Scalar.Kind.integral, ev.factsOf(type));
        case Tpointer, Tclass:
            return Scalar(Scalar.Kind.integral,
                TypeFacts(size_t.sizeof, size_t.sizeof, true, true));
        case Tfloat32, Tfloat64:
            return Scalar(Scalar.Kind.floating, ev.factsOf(type));
        default:
            return Scalar();
    }
}

// Calls `make!T(args)` for the integral type of `facts`. A 64-bit value is
// carried as `long` whatever its signedness: the node treats its bits alike.
private Node byIntegral(alias make, Args...)(in TypeFacts facts, Args args) {
    switch (facts.size) {
        case 1: return facts.isUnsigned ? make!ubyte(args) : make!byte(args);
        case 2: return facts.isUnsigned ? make!ushort(args) : make!short(args);
        case 4: return facts.isUnsigned ? make!uint(args) : make!int(args);
        case 8: return make!long(args);
        default: assert(0, "an integral scalar is 1, 2, 4 or 8 bytes");
    }
}

// The same, for a node that gives a 64-bit unsigned value a type of its own.
private Node byExactIntegral(alias make, Args...)(
    in TypeFacts facts, Args args,
) {
    if (facts.size == 8 && facts.isUnsigned)
        return make!ulong(args);
    return byIntegral!make(facts, args);
}

// The same for the integral types of less than 64 bits.
private Node byNarrow(alias make, Args...)(in TypeFacts facts, Args args) {
    switch (facts.size) {
        case 1: return facts.isUnsigned ? make!ubyte(args) : make!byte(args);
        case 2: return facts.isUnsigned ? make!ushort(args) : make!short(args);
        case 4: return facts.isUnsigned ? make!uint(args) : make!int(args);
        default: assert(0, "a narrow integral scalar is 1, 2 or 4 bytes");
    }
}

// The same for the integral types of 32 and 64 bits, the widths that the
// arithmetic nodes handle. Null for a narrower one.
private Node byWide(alias make, Args...)(in TypeFacts facts, Args args) {
    switch (facts.size) {
        case 4: return facts.isUnsigned ? make!uint(args) : make!int(args);
        case 8: return make!long(args);
        default: return null;
    }
}

private Node byFloating(alias make, Args...)(in TypeFacts facts, Args args) {
    switch (facts.size) {
        case 4: return make!float(args);
        case 8: return make!double(args);
        default: assert(0, "a floating scalar is 4 or 8 bytes");
    }
}

// The factory of `Class!T`, for `byIntegral` and its siblings.
private template New(alias Class) {
    public Node New(T, Args...)(Args args) { return new Class!T(args); }
}

private struct Slot {
    public bool ok;
    public size_t offset;
    public bool indirect;
}

private Slot slotOf(E)(E ev, VarDeclaration variable) {
    import dmd.astenums: STC;
    import snakebite.frontend.dmd.delegates: isCtfeVariable;

    if (variable is null || isCtfeVariable(variable) || variable.isDataseg
            || variable.isSymbolDeclaration !is null
            || (variable.storage_class & STC.lazy_) != 0)
        return Slot();
    const slot = ev._layout.slotOf(variable);
    if (slot is null)
        return Slot();
    return Slot(true, slot.offset, slot.isRef || slot.isReturnPlace);
}

private VarDeclaration thisVariable(E)(E ev, ThisExp expression) {
    import snakebite.backends.closureplan: ClosurePlan;
    import snakebite.frontend.dmd.delegates: outerFunctionOf;

    auto variable = expression.var is null
        ? cast() ev._layout.hiddenThis.variable : expression.var;
    if (variable is null)
        return null;
    auto owner = outerFunctionOf(variable);
    if (owner !is null && ClosurePlan.receiverHops(owner).length != 0)
        return null;
    return variable;
}

private Node buildAddress(E)(E ev, Expression expression) {
    import dmd.astenums: TY;
    import dmd.tokens: EXP;
    import dmd.typesem: toBasetype;

    switch (expression.op) with (EXP) {
        case variable: {
            const slot = slotOf(ev, expression.isVarExp.var.isVarDeclaration);
            if (!slot.ok)
                return null;
            return slot.indirect
                ? new IndirectLocalAddress(slot.offset)
                : new LocalAddress(slot.offset);
        }
        case this_: {
            auto variable = thisVariable(ev, expression.isThisExp);
            const slot = slotOf(ev, variable);
            if (!slot.ok || expression.type.toBasetype.ty != TY.Tstruct)
                return null;
            return new IndirectLocalAddress(slot.offset);
        }
        case dotVariable: {
            auto dot = expression.isDotVarExp;
            auto field = dot.var.isVarDeclaration;
            if (field is null || field.isBitFieldDeclaration !is null)
                return null;
            const baseKind = dot.e1.type.toBasetype.ty;
            if (baseKind == TY.Tclass || baseKind == TY.Tpointer) {
                static if (E.nullCheckedEvaluator)
                    return null;
                else {
                    auto pointer = buildValue(ev, dot.e1);
                    return pointer is null ? null
                        : new FieldOfPointer(pointer, field.offset);
                }
            }
            auto base = buildAddress(ev, dot.e1);
            return base is null ? null : new FieldOfAddress(base, field.offset);
        }
        case star: {
            static if (E.nullCheckedEvaluator)
                return null;
            else {
                auto pointer = buildValue(ev, expression.isPtrExp.e1);
                return pointer is null ? null : new Dereference(pointer);
            }
        }
        case index:
            return buildIndexAddress(ev, expression.isIndexExp);
        default:
            return null;
    }
}

private Node buildIndexAddress(E)(E ev, IndexExp indexed) {
    import dmd.astenums: TY;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf, toBasetype;

    if (indexed.lengthVar !is null)
        return null;
    auto element = ev.factsOf(indexed.e1.type.toBasetype.nextOf);
    auto position = buildValue(ev, indexed.e2);
    if (position is null)
        return null;
    switch (indexed.e1.type.toBasetype.ty) with (TY) {
        case Tarray: {
            auto array = buildAddress(ev, indexed.e1);
            if (array is null)
                return null;
            return indexOfArray(ev, indexed, array, position, element.size);
        }
        case Tsarray: {
            auto array = buildAddress(ev, indexed.e1);
            return array is null ? null : new IndexStatic(
                &ev.failArrayBounds, indexed, array, position, element.size,
                cast(size_t) indexed.e1.type.toBasetype.isTypeSArray
                    .dim.toInteger);
        }
        case Tpointer: {
            static if (E.nullCheckedEvaluator)
                return null;
            else {
                auto pointer = buildValue(ev, indexed.e1);
                return pointer is null ? null : new IndexPointer(
                    pointer, position, element.size);
            }
        }
        default:
            return null;
    }
}

private Node indexOfArray(E)(E ev, IndexExp indexed, Node array,
        Node position, size_t stride) {
    auto index = operandOf(position);
    if (index.kind == Kind.constant)
        index.kind = Kind.child;
    auto frameArray = cast(LocalAddress) array;
    static foreach (kind; AliasSeq!(Kind.child, Kind.localInt, Kind.localLong))
        if (index.kind == kind) {
            alias I = OperandType!(kind, long);
            auto i = makeOperand!I(index);
            if (frameArray !is null)
                return new IndexDynamic!(FrameAddress, I)(
                    &ev.failArrayBounds, indexed,
                    FrameAddress(frameArray._offset), i, stride);
            return new IndexDynamic!(ChildAddress, I)(
                &ev.failArrayBounds, indexed, ChildAddress(array), i, stride);
        }
    assert(0, "an operand kind outside the index kinds");
}

private Node buildLoad(E)(E ev, Expression expression, Node address) {
    const scalar = scalarOf(ev, expression.type);
    if (address is null || scalar.kind == Scalar.Kind.none)
        return null;
    if (scalar.kind == Scalar.Kind.floating)
        return byFloating!(New!Load)(scalar.facts, address);
    return byIntegral!(New!Load)(scalar.facts, address);
}

private Node buildCall(E)(E ev, CallExp call) {
    import dmd.astenums: STC, TY;
    import dmd.typesem: toBasetype;
    import snakebite.backends.calls: CallSelection;
    import snakebite.frontend.dmd.dispatch: CallReceiver, readsVtable,
        receiverOf;
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    if (call.f is null || call.vthis2 !is null || call.e1.isCommaExp !is null
            || call.arguments is null)
        return null;
    CallSelection.ScalarConstant constant;
    if (ev._callSelection.foldedScalarIntrinsic(call, constant))
        return null;
    auto function_ = ev._callSelection.definitionOf(
        call.f, (declaration) => ev._program.linkedFunctionOf(declaration));
    auto type = typeFunctionOf(function_);

    const isVoid = call.type.toBasetype.ty == TY.Tvoid;
    const result = isVoid ? Scalar() : scalarOf(ev, call.type);
    if (!isVoid && result.kind == Scalar.Kind.none)
        return null;

    Node receiver;
    bool receiverIsAddress, virtual;
    if (function_.isThis !is null) {
        auto found = receiverOf(call, function_);
        switch (found.kind) with (CallReceiver.Kind) {
            case classValue:
                receiver = buildValue(ev, found.expression);
                virtual = call.readsVtable(function_);
                break;
            case aggregateAddress:
                receiver = buildAddress(ev, found.expression);
                receiverIsAddress = true;
                break;
            default:
                return null;
        }
        if (receiver is null)
            return null;
    }

    auto parameters = type.parameterList;
    if (call.arguments.length != parameters.length)
        return null;
    auto args = new Node[parameters.length];
    auto modes = new Argument[parameters.length];
    foreach (i; 0 .. parameters.length) {
        auto parameter = parameters[i];
        auto argument = (*call.arguments)[i];
        const declared = scalarOf(ev, parameter.type);
        const given = scalarOf(ev, argument.type);
        if ((parameter.storageClass & (STC.ref_ | STC.out_ | STC.lazy_)) != 0
                || declared.kind == Scalar.Kind.none
                || given.kind != declared.kind
                || given.facts.size != declared.facts.size)
            return null;
        if (declared.kind == Scalar.Kind.floating)
            modes[i] = declared.facts.size == 4 ? Argument.f32 : Argument.f64;
        else switch (declared.facts.size) {
            case 1: modes[i] = Argument.i8; break;
            case 2: modes[i] = Argument.i16; break;
            case 4: modes[i] = Argument.i32; break;
            case 8: modes[i] = Argument.i64; break;
            default: assert(0, "an integral scalar is 1, 2, 4 or 8 bytes");
        }
        args[i] = buildValue(ev, argument);
        if (args[i] is null)
            return null;
    }

    auto node = new Call!E(ev, call, function_, receiver, receiverIsAddress,
        virtual, args, modes, isVoid ? 0 : result.facts.size,
        result.facts.isUnsigned);
    if (!virtual) {
        auto callee = ev.treeCalleeOf(function_);
        if (callee is null || !node.matches(callee))
            return null;
        node._callee = callee;
    }
    return node;
}

// The node that yields `expression`'s scalar value.
private Node buildValue(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;
    import snakebite.backends.logical: LogicalPlan, logicalPlan;
    import snakebite.nativelayout: loadIntegral;
    import snakebite.nativevalue: loadFloating;

    if (expression.op == EXP.call)
        return buildCall(ev, expression.isCallExp);

    const scalar = scalarOf(ev, expression.type);
    if (scalar.kind == Scalar.Kind.none)
        return null;

    switch (expression.op) with (EXP) {
        case int64: {
            if (scalar.kind != Scalar.Kind.integral)
                return null;
            align(8) ubyte[8] buffer;
            ev._nativeData.write(expression.type, scalar.facts, expression,
                buffer.ptr);
            return new Constant!long(loadIntegral(
                buffer.ptr, scalar.facts.size, !scalar.facts.isUnsigned));
        }
        case float64: {
            if (scalar.kind != Scalar.Kind.floating)
                return null;
            align(8) ubyte[8] buffer;
            ev._nativeData.write(expression.type, scalar.facts, expression,
                buffer.ptr);
            return new Constant!double(loadFloating(
                buffer.ptr, scalar.facts.size));
        }
        case null_:
            return scalar.kind == Scalar.Kind.integral
                ? new Constant!long(0) : null;
        case arrayLength: {
            auto address = buildAddress(ev, expression.isArrayLengthExp.e1);
            return address is null || scalar.kind != Scalar.Kind.integral
                || scalar.facts.size != size_t.sizeof
                ? null : new Load!size_t(address);
        }
        case variable: {
            const slot = slotOf(ev, expression.isVarExp.var.isVarDeclaration);
            if (!slot.ok)
                return null;
            if (slot.indirect)
                return buildLoad(ev, expression,
                    new IndirectLocalAddress(slot.offset));
            return scalar.kind == Scalar.Kind.floating
                ? byFloating!(New!Local)(scalar.facts, slot.offset)
                : byIntegral!(New!Local)(scalar.facts, slot.offset);
        }
        case this_: {
            const slot = slotOf(ev, thisVariable(ev, expression.isThisExp));
            if (!slot.ok || scalar.kind != Scalar.Kind.integral)
                return null;
            return new Local!long(slot.offset);
        }
        case dotVariable, star, index:
            return buildLoad(ev, expression, buildAddress(ev, expression));
        case cast_:
            return buildCast(ev, expression.isCastExp, scalar);
        case add: return buildBinary!"+"(ev, expression.isBinExp, scalar);
        case min: return buildBinary!"-"(ev, expression.isBinExp, scalar);
        case mul: return buildBinary!"*"(ev, expression.isBinExp, scalar);
        case div: return buildBinary!"/"(ev, expression.isBinExp, scalar);
        case mod: return buildBinary!"%"(ev, expression.isBinExp, scalar);
        case and: return buildBinary!"&"(ev, expression.isBinExp, scalar);
        case or: return buildBinary!"|"(ev, expression.isBinExp, scalar);
        case xor: return buildBinary!"^"(ev, expression.isBinExp, scalar);
        case leftShift: return buildBinary!"<<"(ev, expression.isBinExp, scalar);
        case rightShift: return buildBinary!">>"(ev, expression.isBinExp, scalar);
        case unsignedRightShift:
            return buildBinary!">>>"(ev, expression.isBinExp, scalar);
        case lessThan: return buildCompare!"<"(ev, expression.isBinExp);
        case lessOrEqual: return buildCompare!"<="(ev, expression.isBinExp);
        case greaterThan: return buildCompare!">"(ev, expression.isBinExp);
        case greaterOrEqual: return buildCompare!">="(ev, expression.isBinExp);
        case equal:
            return expression.isEqualExp.lowering !is null
                ? null : buildCompare!"=="(ev, expression.isBinExp);
        case notEqual:
            return expression.isEqualExp.lowering !is null
                ? null : buildCompare!"!="(ev, expression.isBinExp);
        case andAnd, orOr: {
            auto logical = expression.isLogicalExp;
            const plan = logicalPlan(logical);
            if (plan.right != LogicalPlan.Right.value || !plan.hasValue)
                return null;
            auto left = buildValue(ev, logical.e1);
            auto right = buildValue(ev, logical.e2);
            if (left is null || right is null)
                return null;
            if (!plan.andAnd)
                return new OrOr(left, right);
            if (auto flag = cast(Local!ubyte) left)
                return right.andFlag(flag._offset);
            return new AndAnd(left, right);
        }
        case not: {
            auto operand = buildValue(ev, expression.isNotExp.e1);
            return operand is null ? null : new Not(operand);
        }
        case negate: {
            auto operand = buildValue(ev, expression.isNegExp.e1);
            if (operand is null)
                return null;
            if (scalar.kind == Scalar.Kind.floating)
                return new FloatNegate(operand);
            return byWide!(unaryOf!"-")(scalar.facts, operand);
        }
        case tilde: {
            auto operand = buildValue(ev, expression.isComExp.e1);
            if (operand is null || scalar.kind != Scalar.Kind.integral)
                return null;
            return byWide!(unaryOf!"~")(scalar.facts, operand);
        }
        case addAssign:
            return buildOpAssign!"+"(ev, expression.isBinAssignExp, scalar);
        case minAssign:
            return buildOpAssign!"-"(ev, expression.isBinAssignExp, scalar);
        case mulAssign:
            return buildOpAssign!"*"(ev, expression.isBinAssignExp, scalar);
        case divAssign:
            return buildOpAssign!"/"(ev, expression.isBinAssignExp, scalar);
        case modAssign:
            return buildOpAssign!"%"(ev, expression.isBinAssignExp, scalar);
        case andAssign:
            return buildOpAssign!"&"(ev, expression.isBinAssignExp, scalar);
        case orAssign:
            return buildOpAssign!"|"(ev, expression.isBinAssignExp, scalar);
        case xorAssign:
            return buildOpAssign!"^"(ev, expression.isBinAssignExp, scalar);
        case leftShiftAssign:
            return buildOpAssign!"<<"(ev, expression.isBinAssignExp, scalar);
        case rightShiftAssign:
            return buildOpAssign!">>"(ev, expression.isBinAssignExp, scalar);
        case unsignedRightShiftAssign:
            return buildOpAssign!">>>"(ev, expression.isBinAssignExp, scalar);
        case plusPlus: return buildPost!1(ev, expression.isPostExp, scalar);
        case minusMinus: return buildPost!(-1)(ev, expression.isPostExp, scalar);
        case assign, construct, blit:
            return buildStore(ev, cast(AssignExp) expression, scalar);
        default:
            return null;
    }
}

private template unaryOf(string op) {
    public Node unaryOf(T)(Node operand) { return new IntegerUnary!(op, T)(operand); }
}

private Node buildCast(E)(E ev, CastExp castExp, in Scalar scalar) {
    import snakebite.nativevalue: CastKind;

    if (castExp.lowering !is null)
        return null;
    enum integral = Scalar.Kind.integral;
    enum floating = Scalar.Kind.floating;
    const source = scalarOf(ev, castExp.e1.type);
    if (source.kind == Scalar.Kind.none)
        return null;
    const plan = *ev._shared.facts.castOf(castExp);
    auto operand = buildValue(ev, castExp.e1);
    if (operand is null)
        return null;
    with (CastKind) switch (plan.kind) {
        case copy, narrow, widenSigned, widenUnsigned:
            if (source.kind != integral || scalar.kind != integral)
                return null;
            if (scalar.facts.size == 8)
                return operand;
            return byNarrow!(New!Wrap)(scalar.facts, operand);
        case classReference:
            return new ClassUpcast(operand, plan.referenceOffset);
        case truth:
            return scalar.kind == integral ? new Truth(operand) : null;
        case integralToFloat:
            if (source.kind != integral || scalar.kind != floating)
                return null;
            static Node toFloat(Dest)(Node o, bool unsigned) {
                return unsigned
                    ? new IntegerToFloat!(ulong, Dest)(o)
                    : new IntegerToFloat!(long, Dest)(o);
            }
            return byFloating!toFloat(
                scalar.facts, operand, source.facts.isUnsigned);
        case floatToIntegral:
            if (source.kind != floating || scalar.kind != integral)
                return null;
            return byExactIntegral!(New!FloatToInteger)(scalar.facts, operand);
        case floatWidth:
            if (source.kind != floating || scalar.kind != floating)
                return null;
            return byFloating!(New!FloatWidth)(scalar.facts, operand);
        default:
            return null;
    }
}

private template binaryOf(string op) {
    public Node binaryOf(T)(Node left, Node right, Operation!op operation) {
        static Node make(L, R)(L l, R r, Operation!op o) {
            return new IntegerBinary!(op, T, L, R)(l, r, o);
        }
        alias kinds = operandsOf!(op, T);
        return fuse!(make, long, kinds.lefts, kinds.rights)(
            operandOf(left), operandOf(right), operation);
    }
}

private Node buildBinary(string op, E)(E ev, BinExp e, in Scalar scalar) {
    import snakebite.backends.arithmetic: ArithmeticPlan, arithmeticPlan;

    const plan = arithmeticPlan(e);
    if (plan.kind == ArithmeticPlan.Kind.integral
            && scalar.kind == Scalar.Kind.integral) {
        auto left = buildValue(ev, e.e1);
        auto right = buildValue(ev, e.e2);
        if (left is null || right is null)
            return null;
        return byWide!(binaryOf!op)(
            scalar.facts, left, right, operationOf!op(ev, e));
    }
    static if (op == "+" || op == "-" || op == "*" || op == "/") {
        if (plan.kind == ArithmeticPlan.Kind.floating
                && scalar.kind == Scalar.Kind.floating) {
            auto left = buildValue(ev, e.e1);
            auto right = buildValue(ev, e.e2);
            if (left is null || right is null)
                return null;
            static Node make(T)(Node l, Node r) {
                static Node build(L, R)(L a, R b) {
                    return new FloatBinary!(op, T, L, R)(a, b);
                }
                static if (is(T == double))
                    return fuse!(build, double, doubleLeft, doubleLeft)(
                        operandOf(l), operandOf(r));
                else
                    return fuse!(build, double, onlyChild, onlyChild)(
                        operandOf(l), operandOf(r));
            }
            return byFloating!make(scalar.facts, left, right);
        }
    }
    return null;
}

private Node buildCompare(string op, E)(E ev, BinExp e) {
    import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;

    const plan = comparisonPlan(e);
    auto left = buildValue(ev, e.e1);
    auto right = buildValue(ev, e.e2);
    if (left is null || right is null)
        return null;
    if (plan.kind == ComparisonPlan.Kind.integral) {
        if (scalarOf(ev, e.e1.type).kind != Scalar.Kind.integral)
            return null;
        static Node signed(L, R)(L l, R r) {
            return new IntegerCompare!(op, false, L, R)(IntegerTest!(op, false, L, R)(l, r));
        }
        static Node unsigned(L, R)(L l, R r) {
            return new IntegerCompare!(op, true, L, R)(IntegerTest!(op, true, L, R)(l, r));
        }
        // Equal values have equal bits whatever the signedness.
        static if (op == "==" || op == "!=")
            return fuse!(signed, long, longLeft, longRight)(
                operandOf(left), operandOf(right));
        else
            return plan.facts.isUnsigned
                ? fuse!(unsigned, long, unsignedLeft, unsignedRight)(
                    operandOf(left), operandOf(right))
                : fuse!(signed, long, longLeft, longRight)(
                    operandOf(left), operandOf(right));
    }
    if (plan.kind == ComparisonPlan.Kind.floating
            && scalarOf(ev, e.e1.type).kind == Scalar.Kind.floating) {
        static Node build(L, R)(L l, R r) {
            return new FloatCompare!(op, L, R)(FloatTest!(op, L, R)(l, r));
        }
        return ev.factsOf(e.e1.type).size == 8
            ? fuse!(build, double, doubleComparedLeft, doubleLeft)(
                operandOf(left), operandOf(right))
            : fuse!(build, double, onlyChild, onlyChild)(
                operandOf(left), operandOf(right));
    }
    return null;
}

// The target of a compound assignment or increment: a frame slot, or the
// address of other storage.
private bool targetOf(E)(E ev, Expression expression, out Target target) {
    if (auto variable = expression.isVarExp) {
        const slot = slotOf(ev, variable.var.isVarDeclaration);
        if (!slot.ok)
            return false;
        if (slot.indirect)
            target = Target(new IndirectLocalAddress(slot.offset));
        else
            target = Target(null, slot.offset);
        return true;
    }
    auto address = buildAddress(ev, expression);
    if (address is null)
        return false;
    target = Target(address);
    return true;
}

private template opAssignOf(string op) {
    public Node opAssignOf(T)(Target target, Node step, Operation!op operation) {
        alias steps = operandsOf!(op, T).rights;
        static if (steps.length > 1) {
            if (target.node is null) {
                static Node make(S, A)(S s, A a, Operation!op o) {
                    return new IntegerOpAssign!(op, T, A, S)(a, s, o);
                }
                return fuseStep!(make, steps)(
                    operandOf(step), FrameAddress(target.offset), operation);
            }
        }
        return new IntegerOpAssign!(op, T, Target, ChildOperand!long)(
            target, ChildOperand!long(step), operation);
    }
}

// `make!S(step, args)`, for the operand struct `S` of `step`, when its kind
// is in `steps`.
private Node fuseStep(alias make, Kind[] steps, Args...)(
    Operand step, Args args,
) {
    if (!steps.has(step.kind))
        step.kind = Kind.child;
    static foreach (kind; steps)
        if (step.kind == kind)
            return make!(OperandType!(kind, long))(
                makeOperand!(OperandType!(kind, long))(step), args);
    assert(0, "an operand kind outside the step kinds");
}

private Node buildOpAssign(string op, E)(E ev, BinAssignExp e, in Scalar scalar) {
    import snakebite.backends.arithmetic: ArithmeticPlan, arithmeticPlan;
    import snakebite.frontend.storage: compoundTarget;

    if (compoundTarget(e) !is e.e1)
        return null;
    const plan = arithmeticPlan(e);
    auto step = buildValue(ev, e.e2);
    if (step is null)
        return null;
    Target target;
    if (!targetOf(ev, e.e1, target))
        return null;
    if (plan.kind == ArithmeticPlan.Kind.integral
            && scalar.kind == Scalar.Kind.integral
            && scalarOf(ev, e.e2.type).kind == Scalar.Kind.integral) {
        const operationFacts = ev.factsOf(e.e1.type);
        if (operationFacts.size != scalar.facts.size
                || operationFacts.isUnsigned != scalar.facts.isUnsigned)
            return null;
        return byWide!(opAssignOf!op)(
            scalar.facts, target, step, operationOf!op(ev, e));
    }
    static if (op == "+" || op == "-" || op == "*" || op == "/") {
        if (plan.kind == ArithmeticPlan.Kind.floating
                && scalar.kind == Scalar.Kind.floating
                && scalarOf(ev, e.e2.type).kind == Scalar.Kind.floating) {
            static Node make(T)(Target t, Node s) {
                return new FloatOpAssign!(op, T)(t, s);
            }
            return byFloating!make(scalar.facts, target, step);
        }
    }
    return null;
}

private Node buildPost(long delta, E)(E ev, PostExp e, in Scalar scalar) {
    import snakebite.backends.arithmetic: ArithmeticPlan, arithmeticPlan;

    const plan = arithmeticPlan(e);
    if (plan.kind != ArithmeticPlan.Kind.integral
            || scalar.kind != Scalar.Kind.integral)
        return null;
    Target target;
    if (!targetOf(ev, e.e1, target))
        return null;
    static Node make(T)(Target t) { return new PostStep!(T, delta)(t); }
    return byWide!make(scalar.facts, target);
}

private Node buildStore(E)(E ev, AssignExp e, in Scalar scalar) {
    if ((e.isConstructExp !is null && e.isConstructExp.lowering !is null)
            || e.e1.isDotVarExp is null
            && e.e1.isVarExp is null && e.e1.isIndexExp is null
            && e.e1.isPtrExp is null)
        return null;
    const target = scalarOf(ev, e.e1.type);
    if (target.kind != scalar.kind || target.kind == Scalar.Kind.none
            || scalarOf(ev, e.e2.type).kind != target.kind
            || ev.factsOf(e.e2.type).size != target.facts.size)
        return null;
    auto value = buildValue(ev, e.e2);
    if (value is null)
        return null;
    if (auto variable = e.e1.isVarExp) {
        const slot = slotOf(ev, variable.var.isVarDeclaration);
        if (!slot.ok)
            return null;
        if (!slot.indirect)
            return storeToFrame(target, slot.offset, value);
    }
    auto address = buildAddress(ev, e.e1);
    return address is null ? null : storeToAddress(target, address, value);
}

private Node storeOf(T, A, Value)(A address, Value value) {
    return new Store!(T, A, Value)(address, value);
}

private Node storeToFrame(in Scalar target, size_t offset, Node value) {
    auto address = FrameAddress(offset);
    if (target.kind == Scalar.Kind.floating) {
        if (target.facts.size == 8)
            if (auto fused = storeFusedDouble(value, address))
                return fused;
        if (auto leaf = cast(Constant!double) value)
            return byFloating!storeOf(
                target.facts, address, ConstantOperand!double(leaf._value));
        return byFloating!storeOf(
            target.facts, address, ChildOperand!double(value));
    }
    if (auto leaf = cast(Constant!long) value)
        return byIntegral!storeOf(
            target.facts, address, ConstantOperand!long(leaf._value));
    return byIntegral!storeOf(target.facts, address, ChildOperand!long(value));
}

private Node storeToAddress(in Scalar target, Node node, Node value) {
    auto address = ChildAddress(node);
    if (target.kind == Scalar.Kind.floating)
        return byFloating!storeOf(
            target.facts, address, ChildOperand!double(value));
    if (auto leaf = cast(Constant!long) value)
        return byIntegral!storeOf(
            target.facts, address, ConstantOperand!long(leaf._value));
    return byIntegral!storeOf(target.facts, address, ChildOperand!long(value));
}

// A store of a fused double operation: the operation's node is called
// directly, because its class is final.
private Node storeFusedDouble(Node value, FrameAddress address) {
    static foreach (op; AliasSeq!("+", "-", "*", "/"))
        static foreach (lk; AliasSeq!(Kind.child, Kind.localDouble, Kind.constant))
            static foreach (rk; AliasSeq!(
                    Kind.child, Kind.localDouble, Kind.constant))
                static if ((lk != Kind.child || rk != Kind.child)
                        && (lk != Kind.constant || rk != Kind.constant)) {{
                    alias B = FloatBinary!(op, double,
                        OperandType!(lk, double), OperandType!(rk, double));
                    if (auto binary = cast(B) value)
                        return new Store!(double, FrameAddress,
                            ChildOperand!(double, B))(
                            address, ChildOperand!(double, B)(binary));
                }}
    return null;
}

private Position positionOf(E)(E ev, Expression root) {
    return Position(ev._temporaries.rootSlot, cast(const(void)*) root);
}

private Node buildDeclaration(E)(E ev, DeclarationExp declaration) {
    import snakebite.nativelayout: initializerRunsForEffect, initializerValueOf;

    auto variable = declaration.declaration.isVarDeclaration;
    if (variable is null || variable.isDataseg)
        return null;
    if (variable._init is null || variable._init.isVoidInitializer !is null)
        return new Jump!(TreeFlow.normal);
    auto initializer = variable._init.isExpInitializer;
    if (initializer is null)
        return null;
    const scalar = scalarOf(ev, variable.type);
    if (scalar.kind == Scalar.Kind.none)
        return null;
    if (initializerRunsForEffect(initializer, variable)) {
        auto effect = buildValue(ev, initializer.exp);
        return effect is null
            ? null : statementOf(effect, positionOf(ev, declaration));
    }
    auto value = initializerValueOf(initializer);
    const slot = slotOf(ev, variable);
    if (!slot.ok || slot.indirect || ev.isRefStorage(variable)
            || scalarOf(ev, value.type).kind != scalar.kind
            || ev.factsOf(value.type).size != scalar.facts.size)
        return null;
    auto node = buildValue(ev, value);
    if (node is null)
        return null;
    return statementOf(storeToFrame(scalar, slot.offset, node),
        positionOf(ev, declaration));
}

private Node buildStatement(E)(E ev, Statement statement, Node* slot) {
    import dmd.astenums: STMT;
    import dmd.tokens: EXP;
    import snakebite.backends.ifplan: IfPlan, ifPlan;

    Node generic() {
        return new GenericStatement!E(ev, statement);
    }

    Node child(Statement inner, Node* where) {
        return new Uninitialised!E(ev, inner, where);
    }

    // The nodes of the statements that `inner` runs in order, built on
    // first execution.
    Node[] children(Statement inner) {
        auto nodes = new Node[statementsOf(inner).length];
        foreach (i, one; statementsOf(inner))
            nodes[i] = child(one, &nodes[i]);
        return nodes;
    }

    Node condition(Expression expression) {
        auto node = buildValue(ev, expression);
        return node is null ? new GenericCondition!E(ev, expression) : node;
    }

    switch (statement.stmt) with (STMT) {
        case Compound, CompoundDeclaration: {
            import dmd.statement: CompoundStatement;

            auto compound = cast(CompoundStatement) statement;
            if (compound.statements is null)
                return new Jump!(TreeFlow.normal);
            auto inner = statementsOf(compound);
            static foreach (count; AliasSeq!(2, 3))
                if (inner.length == count) {
                    auto sequence = new ShortSequence!count;
                    foreach (i, one; inner)
                        sequence._children[i] = child(one, &sequence._children[i]);
                    return sequence;
                }
            return new Sequence(children(compound));
        }
        case Scope: {
            auto scoped = statement.isScopeStatement;
            if (scoped.statement is null)
                return new Jump!(TreeFlow.normal);
            return child(scoped.statement, slot);
        }
        case Exp: {
            auto expression = statement.isExpStatement.exp;
            if (expression is null)
                return new Jump!(TreeFlow.normal);
            if (auto declaration = expression.isDeclarationExp) {
                auto node = buildDeclaration(ev, declaration);
                return node is null ? generic() : node;
            }
            if (expression.op != EXP.call && (expression.type is null
                    || scalarOf(ev, expression.type).kind == Scalar.Kind.none))
                return generic();
            auto node = buildValue(ev, expression);
            return node is null
                ? generic() : statementOf(node, positionOf(ev, expression));
        }
        case If: {
            auto conditional = statement.isIfStatement;
            if (conditional.param !is null
                    || ifPlan(conditional).kind != IfPlan.Kind.condition
                    || conditional.ifbody is null)
                return generic();
            auto node = condition(conditional.condition).ifThenElse(
                positionOf(ev, conditional.condition));
            node._then = child(conditional.ifbody, &node._then);
            if (conditional.elsebody !is null)
                node._else = child(conditional.elsebody, &node._else);
            return node;
        }
        case For: {
            auto loop = statement.isForStatement;
            Node test;
            if (loop.condition !is null)
                test = condition(loop.condition);
            Node step;
            if (loop.increment !is null) {
                step = buildValue(ev, loop.increment);
                if (step is null)
                    return generic();
                step = statementOf(step, positionOf(ev, loop.increment));
            }
            // dmd moves the initialiser out of every `for` before it runs.
            assert(loop._init is null);
            auto node = test is null
                ? new ForLoop!Always(&ev._controlFlow, Always(), step, Position())
                : test.forLoop(&ev._controlFlow, step,
                    positionOf(ev, loop.condition));
            node._body = Statements(children(loop._body));
            return node;
        }
        case Do: {
            auto loop = statement.isDoStatement;
            auto node = condition(loop.condition).doLoop(
                &ev._controlFlow, positionOf(ev, loop.condition));
            node._body = Statements(children(loop._body));
            return node;
        }
        case Break:
            return statement.isBreakStatement.ident is null
                ? new Jump!(TreeFlow.break_) : generic();
        case Continue:
            return statement.isContinueStatement.ident is null
                ? new Jump!(TreeFlow.continue_) : generic();
        case Return:
            return buildReturn(ev, statement.isReturnStatement);
        default:
            return generic();
    }
}

// The statements that `statement` runs in order: a block's own, or the
// statement itself.
private Statement[] statementsOf(Statement statement) {
    import dmd.astenums: STMT;
    import dmd.statement: CompoundStatement;

    if (statement is null)
        return null;
    switch (statement.stmt) with (STMT) {
        case Scope:
            return statementsOf(statement.isScopeStatement.statement);
        case Compound, CompoundDeclaration: {
            Statement[] inner;
            auto compound = cast(CompoundStatement) statement;
            if (compound.statements !is null)
                foreach (candidate; *compound.statements)
                    if (candidate !is null)
                        inner ~= candidate;
            return inner;
        }
        default:
            return [statement];
    }
}

private Node buildReturn(E)(E ev, imported!"dmd.statement".ReturnStatement returned) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    Node generic() {
        return new GenericStatement!E(ev, returned);
    }

    if (returned.fesFunc !is null || returned.caseDim != 0)
        return generic();
    if (returned.exp is null)
        return new Jump!(TreeFlow.return_);
    if (typeFunctionOf(ev._function).isRef
            || ev._type.toBasetype.ty == TY.Tvoid)
        return generic();
    const scalar = scalarOf(ev, ev._type);
    if (scalar.kind == Scalar.Kind.none
            || scalarOf(ev, returned.exp.type).kind != scalar.kind
            || ev.factsOf(returned.exp.type).size != scalar.facts.size)
        return generic();
    auto value = buildValue(ev, returned.exp);
    if (value is null)
        return generic();
    static Node make(T)(void** place, Node v, Position p) {
        return new ReturnValue!T(place, v, p);
    }
    auto position = positionOf(ev, returned.exp);
    return scalar.kind == Scalar.Kind.floating
        ? byFloating!make(scalar.facts, &ev._place, value, position)
        : byIntegral!make(scalar.facts, &ev._place, value, position);
}
