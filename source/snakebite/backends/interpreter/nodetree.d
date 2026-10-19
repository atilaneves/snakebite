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
    DeclarationExp, EqualExp, Expression, IdentityExp, IndexExp, NewExp, PostExp,
    SliceExp, ThisExp;
import dmd.func: FuncDeclaration;
import dmd.location: Loc;
import dmd.mtype: Type;
import dmd.statement: Statement;
import snakebite.backends.aggregateinit: InitStep;
import snakebite.backends.checkplan: BoundsCheck;
import snakebite.backends.controlflow: ControlFlowState;
import snakebite.backends.fullexpression: FullExpressionScope;
import snakebite.backends.interpreter.faultslot:
    fastFrameLead, faultSlotOf;
import snakebite.backends.interpreter.integeroperations: combine, shifted;
import snakebite.backends.sliceplan: SlicePlan;
import snakebite.nativelayout: TypeFacts;
import snakebite.nativevalue: BitfieldAccess, CastLayout;
import std.meta: AliasSeq;
import std.traits: Select, isFloatingPoint;

// How a statement node ended. `generic` means the evaluator ran the
// statement and left a control transfer pending for the enclosing node to
// resolve.
package enum TreeFlow : ubyte { normal, break_, continue_, return_, generic }

// A function's tree, with what the evaluator's per-function fields hold while
// the function runs. A tree node reads none of those fields; the nodes that
// hand control to the evaluator set them first (`syncTree`).
package struct TreeRoot {
    private const(imported!"snakebite.backends.layout".FrameLayout)* _layout;
    private Node _body;
    package const(imported!"snakebite.backends.closureplan".ClosurePlan)*
        closurePlan;
    package Type returnType;
    package TypeFacts returnFacts;

    package const(imported!"snakebite.backends.layout".FrameLayout)* layout()
        const {
        return _layout;
    }

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
    E ev, FuncDeclaration function_, Statement body_,
    const(imported!"snakebite.backends.layout".FrameLayout)* layout,
) {
    import dmd.typesem: nextOf;

    auto root = new TreeRoot;
    root._layout = layout;
    root.closurePlan = ev.closurePlanOf(function_);
    root.returnType = function_.type.nextOf;
    root.returnFacts = ev.factsOf(root.returnType);
    root._body = new Uninitialised!E(ev, body_, &root._body, root);
    return root;
}

// What a call node needs to know about its callee, decided once per
// function.
package struct TreeCallee {
    package FuncDeclaration function_;
    package imported!"snakebite.backends.calls".CallSelection.Decision decision;
    package const(imported!"snakebite.backends.layout".FrameLayout)* layout;
    package TreeRoot* root;
    package TypeFacts returnFacts;
    // The bytes in front of the frame base, for its fault slot
    // (`frameLead`), and whether the reservation meets the contract of
    // `FrameStack.reserveFast` with `fastFrameLead` bytes in front.
    package size_t lead;
    package bool reservesFast;
}

// Where a variable of an enclosing function lives: the words to load from
// the running frame outward, then the offset in the context they reach.
// `indirect` is set when the slot holds the address of the storage.
package struct OuterVariable {
    package bool ok;
    package const(imported!"snakebite.backends.closureplan".Hop)[] hops;
    package size_t offset;
    package bool indirect;
}

package bool isScalar(E)(E ev, Type type) {
    return scalarOf(ev, type).kind != Scalar.Kind.none;
}

// Where a statement names the full expression it runs, so that a fault in
// it reports that expression's line: it stores the expression in the fault
// slot of its frame. A statement that cannot fault does not need one, but
// this costs one store, and a node that decides what can fault could be
// wrong.
private struct Position {
    private const(void)* _root;

    public void note(ubyte* frame) {
        *faultSlotOf(frame) = _root;
    }
}

package bool isSlice(Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;

    return type !is null && type.toBasetype.ty == TY.Tarray;
}

private abstract class Node {
    public long executeLong(ubyte* frame) { assert(0); }
    public double executeDouble(ubyte* frame) { assert(0); }
    public bool executeBool(ubyte* frame) { return executeLong(frame) != 0; }
    public ubyte* executeAddr(ubyte* frame) { assert(0); }
    public void executeVoid(ubyte* frame) { assert(0); }
    // Writes a dynamic array value (length, then pointer) to `dest`.
    public void executeInto(ubyte* frame, ubyte* dest) { assert(0); }
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
        _position.note(frame);
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

// A variable of an enclosing function: the static chain's words from the
// running frame, then the variable's offset.
private final class OuterAddress : Node {
    private const(imported!"snakebite.backends.closureplan".Hop)[] _hops;
    private size_t _offset;
    private bool _indirect;
    public this(OuterVariable variable) {
        _hops = variable.hops; _offset = variable.offset;
        _indirect = variable.indirect;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        auto context = frame;
        foreach (hop; _hops)
            context = *cast(ubyte**) (context + hop.offset);
        auto address = context + _offset;
        return _indirect ? *cast(ubyte**) address : address;
    }
}

// `&lvalue`: the address as a pointer value.
private final class AddressValue : LongNode {
    private Node _address;
    public this(Node address) { _address = address; }
    public override long executeLong(ubyte* frame) {
        return cast(long) _address.executeAddr(frame);
    }
    mixin BoolFromLong;
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
    TreeRoot*, ubyte*, in BoundsCheck, in Loc, scope const(void*)[],
);

private final class IndexDynamic(A, I) : Node {
    private FailBounds _fail;
    private TreeRoot* _root;
    private IndexExp _expression;
    private A _array;
    private I _index;
    private size_t _stride;
    public this(FailBounds fail, TreeRoot* root, IndexExp expression, A array,
            I index, size_t stride) {
        _fail = fail; _root = root; _expression = expression; _array = array;
        _index = index; _stride = stride;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        const index = cast(size_t) _index.value(frame);
        auto array = _array.address(frame);
        const length = *cast(size_t*) array;
        if (index >= length)
            fail(frame, index, length);
        return *cast(ubyte**) (array + size_t.sizeof) + index * _stride;
    }
    // Out of line, so that the check costs the fast path no register.
    pragma(inline, false)
    private void fail(ubyte* frame, size_t index, size_t length) {
        _fail(_root, frame, BoundsCheck.index, _expression.loc,
            [cast(const(void)*) &index, cast(const(void)*) &length]);
    }
}

private final class IndexStatic : Node {
    private FailBounds _fail;
    private TreeRoot* _root;
    private IndexExp _expression;
    private Node _array;
    private Node _index;
    private size_t _stride;
    private size_t _length;
    public this(FailBounds fail, TreeRoot* root, IndexExp expression,
            Node array, Node index, size_t stride, size_t length) {
        _fail = fail; _root = root; _expression = expression; _array = array;
        _index = index; _stride = stride; _length = length;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        const index = cast(size_t) _index.executeLong(frame);
        if (index >= _length)
            fail(frame, index);
        return _array.executeAddr(frame) + index * _stride;
    }
    pragma(inline, false)
    private void fail(ubyte* frame, size_t index) {
        auto length = _length;
        _fail(_root, frame, BoundsCheck.index, _expression.loc,
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

// --- dynamic arrays ---------------------------------------------------
// A dynamic array value is a length and a pointer, in the native layout. A
// node of one writes that pair to `dest`. It reads every operand before it
// writes, so `dest` can be the place of one of the operands.

private struct SliceValue {
    public size_t length;
    public ubyte* pointer;
}

private enum lengthOffset = imported!"snakebite.nativelayout".arrayLengthOffset;
private enum pointerOffset = imported!"snakebite.nativelayout".arrayPointerOffset;
static assert(SliceValue.length.offsetof == lengthOffset
    && SliceValue.pointer.offsetof == pointerOffset
    && SliceValue.sizeof == imported!"snakebite.nativelayout".arrayValueSize);

private abstract class SliceNode : Node {
    public override void executeVoid(ubyte* frame) {
        SliceValue discarded = void;
        executeInto(frame, cast(ubyte*) &discarded);
    }
}

private final class LocalSlice : SliceNode {
    private size_t _offset;
    public this(size_t offset) { _offset = offset; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        *cast(SliceValue*) dest = *cast(SliceValue*) (frame + _offset);
    }
}

private final class LoadSlice : SliceNode {
    private Node _address;
    public this(Node address) { _address = address; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        SliceValue value = *cast(SliceValue*) _address.executeAddr(frame);
        *cast(SliceValue*) dest = value;
    }
}

// A string literal: its length and the address of its code units, which
// stay put for the life of the program.
private final class ConstantSlice : SliceNode {
    private SliceValue _value;
    public this(SliceValue value) { _value = value; }
    public override void executeInto(ubyte*, ubyte* dest) {
        *cast(SliceValue*) dest = _value;
    }
}

private final class NullSlice : SliceNode {
    public override void executeInto(ubyte*, ubyte* dest) {
        *cast(SliceValue*) dest = SliceValue.init;
    }
}

// One word of a dynamic array that is not an lvalue: `f().length`,
// `f().ptr`.
private final class SliceWord : LongNode {
    private Node _slice;
    private size_t _offset;
    public this(Node slice, size_t offset) { _slice = slice; _offset = offset; }
    public override long executeLong(ubyte* frame) {
        SliceValue value = void;
        _slice.executeInto(frame, cast(ubyte*) &value);
        return *cast(size_t*) (cast(ubyte*) &value + _offset);
    }
    mixin BoolFromLong;
}

// The truth of a dynamic array: the shared truth decision names the words,
// and one of them is not zero.
private final class SliceTruth : BoolNode {
    private Node _slice;
    private size_t _first;
    private size_t _second;

    public this(Node slice, Type type) {
        import snakebite.nativelayout: truthFacts;

        const truth = truthFacts(type);
        _slice = slice;
        _first = truth.offset;
        _second = truth.secondOffset;
    }

    public override bool executeBool(ubyte* frame) {
        SliceValue value = void;
        _slice.executeInto(frame, cast(ubyte*) &value);
        const bytes = cast(const(ubyte)*) &value;
        return *cast(const(size_t)*) (bytes + _first) != 0
            || *cast(const(size_t)*) (bytes + _second) != 0;
    }
}

// `x is y` on dynamic arrays: both words equal.
private final class SliceIdentity(bool negate) : BoolNode {
    private Node _left;
    private Node _right;
    public this(Node left, Node right) { _left = left; _right = right; }
    public override bool executeBool(ubyte* frame) {
        SliceValue left = void;
        SliceValue right = void;
        _left.executeInto(frame, cast(ubyte*) &left);
        _right.executeInto(frame, cast(ubyte*) &right);
        const same = left.length == right.length && left.pointer is right.pointer;
        return negate ? !same : same;
    }
}

// `a == b` on dynamic arrays whose elements compare as their bytes: equal
// lengths and equal element bytes.
private final class SliceEquality(bool negate) : BoolNode {
    private Node _left;
    private Node _right;
    private size_t _elementSize;
    public this(Node left, Node right, size_t elementSize) {
        _left = left;
        _right = right;
        _elementSize = elementSize;
    }
    public override bool executeBool(ubyte* frame) {
        import core.stdc.string: memcmp;

        SliceValue left = void;
        SliceValue right = void;
        _left.executeInto(frame, cast(ubyte*) &left);
        _right.executeInto(frame, cast(ubyte*) &right);
        const bytes = left.length * _elementSize;
        const same = left.length == right.length
            && (bytes == 0 || memcmp(left.pointer, right.pointer, bytes) == 0);
        return negate ? !same : same;
    }
}

// `x is y` on floating point values compares their bits.
private final class FloatIdentity(bool negate, T, L, R) : BoolNode {
    private L _left;
    private R _right;
    public this(L left, R right) { _left = left; _right = right; }
    public override bool executeBool(ubyte* frame) {
        const T left = cast(T) _left.value(frame);
        const T right = cast(T) _right.value(frame);
        static if (T.sizeof == 4)
            const same = *cast(const(uint)*) &left == *cast(const(uint)*) &right;
        else
            const same = *cast(const(ulong)*) &left == *cast(const(ulong)*) &right;
        return negate ? !same : same;
    }
}

private enum SliceSource : ubyte { slice, pointer, staticArray }

// `base[lower .. upper]`. The base is read before the bounds, as the
// evaluator does.
private final class SliceOf(SliceSource source) : SliceNode {
    private FailBounds _fail;
    private TreeRoot* _root;
    private SliceExp _expression;
    private Node _base;
    private Node _lower;
    private Node _upper;
    private size_t _stride;
    private size_t _staticLength;
    private bool _checkOrder;
    private bool _checkUpper;
    private bool _reportsLength;
    public this(FailBounds fail, TreeRoot* root, SliceExp expression,
            Node base, Node lower, Node upper, size_t stride,
            size_t staticLength, in SlicePlan plan) {
        _fail = fail; _root = root; _expression = expression; _base = base; _lower = lower;
        _upper = upper; _stride = stride; _staticLength = staticLength;
        _checkOrder = plan.checkOrder; _checkUpper = plan.checkUpper;
        _reportsLength = plan.reportsSourceLength;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        ubyte* base;
        size_t length;
        static if (source == SliceSource.slice) {
            SliceValue value = void;
            _base.executeInto(frame, cast(ubyte*) &value);
            base = value.pointer;
            length = value.length;
        } else static if (source == SliceSource.pointer)
            base = cast(ubyte*) _base.executeLong(frame);
        else {
            base = _base.executeAddr(frame);
            length = _staticLength;
        }
        const lower = _lower is null ? size_t(0) : cast(size_t) _lower.executeLong(frame);
        const upper = _upper is null ? length : cast(size_t) _upper.executeLong(frame);
        if (_checkOrder && upper < lower || _checkUpper && upper > length)
            fail(frame, lower, upper, length);
        *cast(SliceValue*) dest = SliceValue(upper - lower, base + lower * _stride);
    }
    pragma(inline, false)
    private void fail(ubyte* frame, size_t lower, size_t upper,
            size_t length) {
        const reported = _reportsLength ? length : 0;
        _fail(_root, frame, BoundsCheck.slice, _expression.loc,
            [cast(const(void)*) &lower, cast(const(void)*) &upper,
                cast(const(void)*) &reported]);
    }
}

// A cast between dynamic arrays of elements of different sizes keeps the
// bytes: the shared cast operation scales the length.
private final class ReinterpretSlice : SliceNode {
    private Node _operand;
    private CastLayout _layout;

    public this(
        Node operand, CastLayout layout,
    ) {
        _operand = operand; _layout = layout;
    }

    public override void executeInto(ubyte* frame, ubyte* dest) {
        import snakebite.nativevalue: applyCast;

        SliceValue value = void;
        _operand.executeInto(frame, cast(ubyte*) &value);
        applyCast(_layout, &value, dest);
    }
}

private final class StaticArrayToSlice : SliceNode {
    private Node _address;
    private size_t _length;
    public this(Node address, size_t length) { _address = address; _length = length; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        *cast(SliceValue*) dest = SliceValue(_length, _address.executeAddr(frame));
    }
}

// The element of a dynamic array that is not an lvalue.
private final class IndexValue : Node {
    private FailBounds _fail;
    private TreeRoot* _root;
    private IndexExp _expression;
    private Node _array;
    private Node _index;
    private size_t _stride;
    public this(FailBounds fail, TreeRoot* root, IndexExp expression,
            Node array, Node index, size_t stride) {
        _fail = fail; _root = root; _expression = expression; _array = array; _index = index;
        _stride = stride;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        SliceValue value = void;
        _array.executeInto(frame, cast(ubyte*) &value);
        const index = cast(size_t) _index.executeLong(frame);
        if (index >= value.length)
            fail(frame, index, value.length);
        return value.pointer + index * _stride;
    }
    pragma(inline, false)
    private void fail(ubyte* frame, size_t index, size_t length) {
        _fail(_root, frame, BoundsCheck.index, _expression.loc,
            [cast(const(void)*) &index, cast(const(void)*) &length]);
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

private final class Truth : BoolNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override bool executeBool(ubyte* frame) { return _operand.executeBool(frame); }
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

// `left && right`, `left || right` and `!operand` as tests: the branch form
// of a condition, which a loop or an `if` holds in place of a node that
// evaluates it.
private struct AndTest {
    public enum mayFault = true;

    public Node left;
    public Node right;

    public bool test(ubyte* frame) {
        return left.executeBool(frame) && right.executeBool(frame);
    }
}

private struct OrTest {
    public enum mayFault = true;

    public Node left;
    public Node right;

    public bool test(ubyte* frame) {
        return left.executeBool(frame) || right.executeBool(frame);
    }
}

private struct NotTest {
    public enum mayFault = true;

    public Node operand;

    public bool test(ubyte* frame) { return !operand.executeBool(frame); }
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

// A `ref` variable bound to the address of other storage.
private final class BindReference : Node {
    private size_t _offset;
    private Node _address;
    public this(size_t offset, Node address) {
        _offset = offset; _address = address;
    }
    public override void executeVoid(ubyte* frame) {
        *cast(ubyte**) (frame + _offset) = _address.executeAddr(frame);
    }
}

// A dynamic array stored to a frame slot or to the address of other storage.
private final class StoreSlice(A) : SliceNode {
    private A _address;
    private Node _value;
    public this(A address, Node value) { _address = address; _value = value; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        auto address = _address.address(frame);
        SliceValue value = void;
        _value.executeInto(frame, cast(ubyte*) &value);
        *cast(SliceValue*) address = value;
        *cast(SliceValue*) dest = value;
    }
    public override void executeVoid(ubyte* frame) {
        auto address = _address.address(frame);
        _value.executeInto(frame, address);
    }
    mixin StatementForm!"executeVoid";
}

// `test ? first : second`, which runs the one branch the test selects.
private final class ConditionalLong : LongNode {
    private Node _test;
    private Node _first;
    private Node _second;
    public this(Node test, Node first, Node second) {
        _test = test; _first = first; _second = second;
    }
    public override long executeLong(ubyte* frame) {
        return _test.executeBool(frame)
            ? _first.executeLong(frame) : _second.executeLong(frame);
    }
    mixin BoolFromLong;
}

private final class ConditionalDouble : DoubleNode {
    private Node _test;
    private Node _first;
    private Node _second;
    public this(Node test, Node first, Node second) {
        _test = test; _first = first; _second = second;
    }
    public override double executeDouble(ubyte* frame) {
        return _test.executeBool(frame)
            ? _first.executeDouble(frame) : _second.executeDouble(frame);
    }
}

private final class ConditionalAddress : Node {
    private Node _test;
    private Node _first;
    private Node _second;
    public this(Node test, Node first, Node second) {
        _test = test; _first = first; _second = second;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        return _test.executeBool(frame)
            ? _first.executeAddr(frame) : _second.executeAddr(frame);
    }
}

private final class ConditionalVoid : Node {
    private Node _test;
    private Node _first;
    private Node _second;
    public this(Node test, Node first, Node second) {
        _test = test; _first = first; _second = second;
    }
    public override void executeVoid(ubyte* frame) {
        if (_test.executeBool(frame))
            _first.executeVoid(frame);
        else
            _second.executeVoid(frame);
    }
}

// A conditional whose branches write a slice, delegate or aggregate into `dest`.
private final class ConditionalInto : SliceNode {
    private Node _test;
    private Node _first;
    private Node _second;
    public this(Node test, Node first, Node second) {
        _test = test; _first = first; _second = second;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        if (_test.executeBool(frame))
            _first.executeInto(frame, dest);
        else
            _second.executeInto(frame, dest);
    }
}

// --- struct values ----------------------------------------------------

// A struct or static array value is written into the bytes at `dest`, as a
// slice is.

// A value whose bytes are known when the node is built.
private final class ImageInto : Node {
    private immutable(ubyte)[] _image;
    public this(immutable(ubyte)[] image) { _image = image; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        dest[0 .. _image.length] = _image[];
    }
}

private final class AggregateCopy : Node {
    private Node _address;
    private size_t _size;
    public this(Node address, size_t size) { _address = address; _size = size; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        import core.stdc.string: memmove;

        auto source = _address.executeAddr(frame);
        if (source !is dest)
            memmove(dest, source, _size);
    }
}

// A value that fills the field at `offset` of the struct at `dest`.
private final class IntoOffset : Node {
    private size_t _offset;
    private Node _value;
    public this(size_t offset, Node value) { _offset = offset; _value = value; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        _value.executeInto(frame, dest + _offset);
    }
}

private final class FieldStore(T) : Node {
    private size_t _offset;
    private Node _value;
    public this(size_t offset, Node value) { _offset = offset; _value = value; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        static if (isFloatingPoint!T)
            const T value = cast(T) _value.executeDouble(frame);
        else
            const T value = cast(T) _value.executeLong(frame);
        *cast(T*) (dest + _offset) = value;
    }
}

// A static array field that every element of which is the one value.
private final class FieldBroadcast(T) : Node {
    private size_t _offset;
    private size_t _count;
    private Node _value;
    public this(size_t offset, size_t count, Node value) {
        _offset = offset; _count = count; _value = value;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        static if (isFloatingPoint!T)
            const T value = cast(T) _value.executeDouble(frame);
        else
            const T value = cast(T) _value.executeLong(frame);
        (cast(T*) (dest + _offset))[0 .. _count] = value;
    }
}

private final class BitfieldStore : Node {
    private size_t _offset;
    private BitfieldAccess _access;
    private Node _value;
    public this(size_t offset, in BitfieldAccess access, Node value) {
        _offset = offset; _access = access; _value = value;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        const value = _value.executeLong(frame);
        _access.store(dest + _offset, cast(ulong) value);
    }
}

// The hidden context field of a nested struct: the evaluator reads the
// context of the running call.
private final class ContextStore(E) : Node {
    private E _ev;
    private InitStep _step;
    private TreeRoot* _root;
    public this(E ev, InitStep step) {
        _ev = ev; _step = step; _root = ev._treeRoot;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        _ev.syncTree(_root, frame);
        _ev.applyVthisStep(_step, dest);
    }
}

private final class StructLiteral : Node {
    private Node[] _steps;
    private size_t _size;
    private bool _zeroFill;
    public this(Node[] steps, size_t size, bool zeroFill) {
        _steps = steps; _size = size; _zeroFill = zeroFill;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        if (_zeroFill)
            dest[0 .. _size] = 0;
        foreach (step; _steps)
            step.executeInto(frame, dest);
    }
}

// The result of a function that returns `ref` is the address of the operand.
private final class ReturnReference : Node {
    private void** _place;
    private Node _address;
    private Position _position;
    public this(void** place, Node address, Position position) {
        _place = place; _address = address; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        *cast(ubyte**) *_place = _address.executeAddr(frame);
        return TreeFlow.return_;
    }
}

private final class ReturnAggregate(E) : Node {
    private E _ev;
    private void** _place;
    private Node _value;
    private Position _position;
    private size_t _size;
    private uint _alignment;
    public this(
        E ev, Node value, Position position, in TypeFacts facts,
    ) {
        _ev = ev; _place = &ev._place; _value = value; _position = position;
        _size = facts.size; _alignment = facts.alignment;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        if (*_place !is null)
            _value.executeInto(frame, cast(ubyte*) *_place);
        else {
            // The caller discarded the result, but the operand still runs.
            auto scratch = _ev._frames.push(_size, _alignment);
            _value.executeInto(frame, scratch.base);
        }
        return TreeFlow.return_;
    }
}

// `first, second`: `first` runs for its effect, and the node yields
// `second` in whichever form the parent asks for.
private final class Comma : Node {
    private Node _first;
    private Node _second;
    public this(Node first, Node second) { _first = first; _second = second; }
    public override long executeLong(ubyte* frame) {
        _first.executeVoid(frame);
        return _second.executeLong(frame);
    }
    public override bool executeBool(ubyte* frame) {
        _first.executeVoid(frame);
        return _second.executeBool(frame);
    }
    public override double executeDouble(ubyte* frame) {
        _first.executeVoid(frame);
        return _second.executeDouble(frame);
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        _first.executeVoid(frame);
        _second.executeInto(frame, dest);
    }
    public override void executeVoid(ubyte* frame) {
        _first.executeVoid(frame);
        _second.executeVoid(frame);
    }
}

// A leaf the evaluator evaluates, for a value whose making is not the tree's
// to decide: a function address, a delegate literal.
private final class EvaluatedWord(E) : LongNode {
    private E _ev;
    private Expression _expression;
    private TreeRoot* _root;
    public this(E ev, Expression expression) {
        _ev = ev; _expression = expression; _root = ev._treeRoot;
    }
    public override long executeLong(ubyte* frame) {
        size_t value;
        _ev.evaluateTreeValue(_root, frame, _expression, &value);
        return value;
    }
    mixin BoolFromLong;
}

private final class EvaluatedPair(E) : SliceNode {
    private E _ev;
    private Expression _expression;
    private TreeRoot* _root;
    public this(E ev, Expression expression) {
        _ev = ev; _expression = expression; _root = ev._treeRoot;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        _ev.evaluateTreeValue(_root, frame, _expression, dest);
    }
}

// --- statements -------------------------------------------------------

private final class ExpressionStatement : Node {
    private Node _expression;
    private Position _position;
    public this(Node expression, Position position) {
        _expression = expression; _position = position;
    }
    public override void executeVoid(ubyte* frame) {
        _expression.executeVoid(frame);
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
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
    static if (flow == TreeFlow.normal)
        public override void executeVoid(ubyte*) {}
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
        _position.note(frame);
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
                _position.note(frame);
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
                _position.note(frame);
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
        _position.note(frame);
        static if (is(T == SliceValue)) {
            if (*_place !is null)
                _value.executeInto(frame, cast(ubyte*) *_place);
            else
                _value.executeVoid(frame);
        } else {
            static if (isFloatingPoint!T)
                const T value = cast(T) _value.executeDouble(frame);
            else
                const T value = cast(T) _value.executeLong(frame);
            if (*_place !is null)
                *cast(T*) (*_place) = value;
        }
        return TreeFlow.return_;
    }
}

private final class GenericStatement(E) : Node {
    private E _ev;
    private Statement _statement;
    private TreeRoot* _root;
    public this(E ev, Statement statement) {
        _ev = ev; _statement = statement; _root = ev._treeRoot;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _ev.syncTree(_root, frame);
        // The evaluator runs the statement as it runs one outside the tree:
        // with no expression named until the statement opens one.
        *faultSlotOf(frame) = null;
        _statement.accept(_ev);
        return _ev._controlFlow.hasTransfer ? TreeFlow.generic : TreeFlow.normal;
    }
}

private final class GenericCondition(E) : BoolNode {
    private E _ev;
    private Expression _condition;
    private FullExpressionScope.Position _position;
    private TreeRoot* _root;
    public this(
        E ev, Expression condition,
        in FullExpressionScope.Position position
            = FullExpressionScope.Position.condition,
    ) {
        _ev = ev; _condition = condition; _position = position;
        _root = ev._treeRoot;
    }
    public override bool executeBool(ubyte* frame) {
        _ev.syncTree(_root, frame);
        return _ev.conditionHolds(_condition, _position);
    }
}

// Builds its statement's node on first execution and replaces itself in the
// parent's slot.
private final class Uninitialised(E) : Node {
    private E _ev;
    private Statement _statement;
    private Node* _slot;
    private TreeRoot* _root;
    public this(E ev, Statement statement, Node* slot, TreeRoot* root) {
        _ev = ev; _statement = statement; _slot = slot; _root = root;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        // Building reads the function's layout and return type from the
        // evaluator, and the nodes it makes name this tree.
        _ev.syncTree(_root, frame);
        auto outer = _ev._treeRoot;
        _ev._treeRoot = _root;
        scope(exit) _ev._treeRoot = outer;
        auto node = buildStatement(_ev, _statement, _slot);
        *_slot = node;
        return node.executeStmt(frame);
    }
}

// --- calls ------------------------------------------------------------

// `pair` is a value of two words: a dynamic array or a delegate.
private enum Argument : ubyte { i8, i16, i32, i64, f32, f64, address, pair }

private size_t sizeOf(Argument mode) {
    final switch (mode) with (Argument) {
        case i8: return 1;
        case i16: return 2;
        case f32, i32: return 4;
        case f64, i64, address: return 8;
        case pair: return SliceValue.sizeof;
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

// A native call that the plan shows to be one to three word arguments in
// the first integer registers and an integer result of 1, 2, 4 or 8 bytes
// or of two words (16 bytes): the node calls the target with the words
// itself, and skips the plan's own work (`directWordCallTarget`).
private struct DirectWordCall {
    private alias Load = imported!"snakebite.ffi.load".Load;

    private const(void)* _target;
    private ubyte[3] _order;
    private Load[3] _loads;
    private size_t _resultWidth;

    // Whether the call of `callee` through `plan` is one. A receiver, a `ref`
    // parameter, a parameter whose size is not the load width of its word, or
    // a result whose size is not the `resultWidth` of the plan is not.
    public bool decide(
        const(imported!"snakebite.ffi.plan".CallPlan)* plan,
        in TreeCallee* callee,
    ) {
        import snakebite.ffi.load: loadWidth;
        import snakebite.ffi.plan: directWordCallTarget;

        _target = null;
        const layout = callee.layout;
        if (plan is null || layout.hiddenThis.variable !is null)
            return false;
        size_t resultWidth, count;
        const target = directWordCallTarget(
            plan, _order, _loads, resultWidth, count);
        if (target is null || count != layout.parameters.length
                || callee.returnFacts.size != resultWidth)
            return false;
        foreach (i, parameter; layout.parameters)
            if (parameter.isRef || parameter.facts.size != loadWidth(_loads[i]))
                return false;
        _target = target;
        _resultWidth = resultWidth;
        return true;
    }

    public bool decided() const { return _target !is null; }

    public void run(E)(
        E ev, in TreeCallee* callee, const(ubyte)* base, void* place,
    ) const {
        import snakebite.ffi.load: callDirectWords, loadWord;

        ulong[3] words;
        foreach (i, parameter; callee.layout.parameters)
            words[i] = loadWord(base + parameter.offset, _loads[i]);
        const target = _target, order = _order, width = _resultWidth;
        ev.crossNative({
            callDirectWords(
                target, words[order[0]], words[order[1]], words[order[2]],
                width, place);
        });
    }
}

// A callee that a call node chose, with how the site runs it. Run by run it
// is passed by value: a call in an argument can reach the same node again
// and choose another callee, so a node field must not carry it past the
// evaluation of the arguments.
private struct Selection {
    public TreeCallee* callee;
    public imported!"snakebite.backends.calls".CallSelection.Route route;
    public const(imported!"snakebite.ffi.plan".CallPlan)* plan;
    // Set when the call is a direct word call.
    public DirectWordCall* direct;
}

// What every call node does once it has chosen its callee: the fields that
// say how the site passes its arguments and takes its result, the callee's
// frame, the arguments evaluated into the parameter slots, and the run.
private mixin template CalleeEntry(E) {
    private E _ev;
    private CallExp _site;
    private Node[] _args;
    private Argument[] _modes;
    private size_t _resultSize;
    private bool _resultUnsigned;
    private TreeRoot* _root;

    // Whether `callee` takes the arguments of this site and gives its result.
    private bool takesArguments(in TreeCallee* callee) const {
        auto layout = callee.layout;
        if (layout.parameters.length != _modes.length)
            return false;
        foreach (i, parameter; layout.parameters)
            if (parameter.isRef != (_modes[i] == Argument.address)
                    || parameter.facts.size != sizeOf(_modes[i]))
                return false;
        return _resultSize == 0 || callee.returnFacts.size == _resultSize;
    }

    private Selection selectionOf(TreeCallee* callee) {
        import snakebite.backends.calls: CallSelection;

        const decision = CallSelection.atCallSite(callee.decision, _site);
        return Selection(callee, decision.route,
            decision.route == CallSelection.Route.native
                ? _ev._plans.of(callee.function_) : null);
    }

    // Runs `callee` with `hidden` as its context word, the arguments taken
    // from the caller's `frame`.
    private void enter(
        in Selection selection, size_t hidden, ubyte* frame, void* result,
    ) {
        auto ev = _ev;
        auto callee = selection.callee;
        const layout = callee.layout;
        auto calleeFrame = FrameGuard(&ev._frames);
        // A frame of small alignment has the same lead whatever it is.
        size_t lead = fastFrameLead;
        auto base = callee.reservesFast
            ? ev._frames.reserveFast(layout.size + lead, fastFrameLead) : null;
        if (base is null) {
            lead = callee.lead;
            base = ev._frames.reserve(layout.size + lead, cast(uint) lead);
        }
        base += lead;
        *faultSlotOf(base) = null;
        if (layout.hiddenThis.variable !is null)
            *cast(size_t*) (base + layout.hiddenThis.parameter.offset)
                = hidden;
        foreach (i, node; _args)
            storeArgument(node, _modes[i], frame, base + layout.parameters[i].offset);
        if (layout.retainsTemporaries)
            ev._temporaries.withNestedCall(layout.retainsTemporaries, {
                run(selection, base, result);
            });
        else
            run(selection, base, result);
    }

    private void run(in Selection selection, ubyte* base, void* result) {
        import snakebite.backends.calls: CallSelection;

        auto callee = cast(TreeCallee*) selection.callee;
        final switch (selection.route) with (CallSelection.Route) {
            case guest:
                _ev.runTreeCallee(callee, base, result);
                break;
            case native:
                if (selection.direct !is null)
                    selection.direct.run(_ev, callee, base, result);
                else
                    _ev.runHostCallee(callee, selection.plan, base, result);
                break;
            case builtin:
                _ev.runHostCallee(callee, selection.plan, base, result);
                break;
            case vaStart, vaCopy, alloca:
                assert(0, "makeTreeCallee yields no callee for this route");
        }
    }

    private double floatingResult(in ulong[2] buffer) const {
        return _resultSize == 4
            ? *cast(const(float)*) buffer.ptr : *cast(const(double)*) buffer.ptr;
    }
}

// A direct or virtual call with scalar, `ref` or dynamic array parameters,
// and a scalar, dynamic array or no result. The callee is a guest function,
// a native function or a builtin. It pushes the callee frame, evaluates each
// argument into its parameter slot, and runs the callee: a guest callee's
// node tree, or the native call through its plan.
private final class Call(E) : Node {
    mixin CalleeEntry!E;

    private FuncDeclaration _method;
    private Node _receiver;
    private bool _virtual;
    private bool _receiverIsAddress;
    // A constructor call yields the object it constructed.
    private bool _yieldsReceiver;
    private Selection _selected;
    private DirectWordCall _direct;
    private const(void)* _vtable;

    public this(E ev, CallExp site, FuncDeclaration method, Node receiver,
            bool receiverIsAddress, bool virtual, Node[] args,
            Argument[] modes, size_t resultSize, bool resultUnsigned,
            bool yieldsReceiver) {
        _ev = ev; _site = site; _method = method; _receiver = receiver;
        _receiverIsAddress = receiverIsAddress; _virtual = virtual;
        _args = args; _modes = modes; _resultSize = resultSize;
        _resultUnsigned = resultUnsigned; _yieldsReceiver = yieldsReceiver;
        _root = ev._treeRoot;
    }

    public final bool matches(TreeCallee* callee) {
        if (_virtual && callee.decision.route != _selected.route)
            return false;
        // The receiver is the context word, and only a callee with one takes it.
        if ((_receiver !is null) != (callee.layout.hiddenThis.variable !is null))
            return false;
        return takesArguments(callee);
    }

    public final void bind(TreeCallee* callee) {
        import snakebite.backends.calls: CallSelection;

        _selected = selectionOf(callee);
        if (!_virtual && _selected.route == CallSelection.Route.native
                && _direct.decide(_selected.plan, callee))
            _selected.direct = &_direct;
    }

    // Returns the receiver of the call, 0 when there is none.
    private size_t invoke(ubyte* frame, void* result) {
        auto ev = _ev;
        size_t receiver;
        if (_receiver !is null)
            receiver = _receiverIsAddress
                ? cast(size_t) _receiver.executeAddr(frame)
                : cast(size_t) _receiver.executeLong(frame);
        // Read after the receiver runs: it can run this site again.
        auto selected = _selected;
        if (_receiver !is null) {
            if (_virtual) {
                if (receiver == 0) {
                    ev.syncTree(_root, frame);
                    ev._executeMethodCall(_site, result, _method, null);
                    return receiver;
                }
                const vtable = *cast(const(void)**) receiver;
                if (vtable !is _vtable) {
                    auto callee = ev.virtualTreeCalleeOf(
                        _method, cast(void*) receiver);
                    if (callee is null || !matches(callee)) {
                        ev.syncTree(_root, frame);
                        ev._executeMethodCall(
                            _site, result, _method, cast(void*) receiver);
                        return receiver;
                    }
                    selected = selectionOf(callee);
                    _selected = selected;
                    _vtable = vtable;
                }
            }
        }
        enter(selected, receiver, frame, result);
        return receiver;
    }

    public override long executeLong(ubyte* frame) {
        ulong[2] buffer;
        const receiver = invoke(frame, _yieldsReceiver ? null : buffer.ptr);
        return _yieldsReceiver
            ? receiver
            : extendResult(buffer[0], _resultSize, _resultUnsigned);
    }

    public override double executeDouble(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
        return floatingResult(buffer);
    }

    public override void executeInto(ubyte* frame, ubyte* dest) {
        SliceValue buffer = void;
        invoke(frame, &buffer);
        *cast(SliceValue*) dest = buffer;
    }

    public override void executeVoid(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
    }
}

// The two words of a delegate, in the native layout.
private struct DelegateValue {
    public size_t context;
    public size_t function_;
}

static assert(DelegateValue.context.offsetof
        == imported!"snakebite.nativelayout".delegateContextOffset
    && DelegateValue.function_.offsetof
        == imported!"snakebite.nativelayout".delegateFunctionOffset
    && DelegateValue.sizeof == imported!"snakebite.nativelayout".delegateValueSize);

// A call through a function pointer or a delegate, with the same parameter
// and result kinds as `Call`. The target is a callback address, which the
// shared decode (`guestFunctionOf`) turns into the guest function and the
// adjustment of its context. A host target, a null one, and a guest callee
// that `Call` could not run stay with the evaluator, which has the fault for
// the null one and the foreign-function barrier for the others.
private final class IndirectCall(E) : Node {
    mixin CalleeEntry!E;

    private Node _target;
    private bool _viaDelegate;
    // The function that this site last called, and its callee when the tree
    // runs it.
    private FuncDeclaration _function;
    private Selection _selected;

    public this(E ev, CallExp site, Node target, bool viaDelegate,
            Node[] args, Argument[] modes, size_t resultSize,
            bool resultUnsigned) {
        _ev = ev; _site = site; _target = target; _viaDelegate = viaDelegate;
        _args = args; _modes = modes; _resultSize = resultSize;
        _resultUnsigned = resultUnsigned;
        _root = ev._treeRoot;
    }

    private void invoke(ubyte* frame, void* result) {
        auto ev = _ev;
        DelegateValue target = void;
        if (_viaDelegate) {
            _target.executeInto(frame, cast(ubyte*) &target);
        } else {
            target.context = 0;
            target.function_ = _target.executeLong(frame);
        }
        ptrdiff_t adjustment;
        auto function_ = ev.guestFunctionOf(
            cast(const(void)*) target.function_, adjustment);
        if (function_ !is _function) {
            _selected = function_ is null
                ? Selection.init : selectionFor(function_);
            _function = function_;
        }
        const selected = _selected;
        if (selected.callee is null) {
            ev.syncTree(_root, frame);
            ev._executeCallThroughValue(_site, result,
                cast(void*) target.function_, cast(void*) target.context,
                _viaDelegate);
            return;
        }
        enter(selected, target.context + adjustment, frame, result);
    }

    // The callee for `function_` that this tree runs, null when it runs
    // none.
    private Selection selectionFor(FuncDeclaration function_) {
        auto definition = _ev._callSelection.definitionOf(
            function_, (declaration) => _ev._program.linkedFunctionOf(declaration));
        auto callee = _ev.treeCalleeOf(definition);
        if (callee is null || !takesArguments(callee))
            return Selection.init;
        return selectionOf(callee);
    }

    public override long executeLong(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
        return extendResult(buffer[0], _resultSize, _resultUnsigned);
    }

    public override double executeDouble(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
        return floatingResult(buffer);
    }

    public override void executeInto(ubyte* frame, ubyte* dest) {
        SliceValue buffer = void;
        invoke(frame, &buffer);
        *cast(SliceValue*) dest = buffer;
    }

    public override void executeVoid(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
    }
}

// Evaluates `node` into the parameter slot `place` as `mode` says.
private void storeArgument(Node node, Argument mode, ubyte* frame, ubyte* place) {
    final switch (mode) with (Argument) {
        case i8: *cast(ubyte*) place = cast(ubyte) node.executeLong(frame); break;
        case i16: *cast(ushort*) place = cast(ushort) node.executeLong(frame); break;
        case i32: *cast(uint*) place = cast(uint) node.executeLong(frame); break;
        case i64: *cast(ulong*) place = node.executeLong(frame); break;
        case f32: *cast(float*) place = node.executeDouble(frame); break;
        case f64: *cast(double*) place = node.executeDouble(frame); break;
        case address: *cast(ubyte**) place = node.executeAddr(frame); break;
        case pair: node.executeInto(frame, place); break;
    }
}

// The integer result of `size` bytes in `word`, extended to a `long`.
private long extendResult(ulong word, size_t size, bool isUnsigned) {
    switch (size) {
        case 1: return isUnsigned ? cast(long) cast(ubyte) word : cast(long) cast(byte) word;
        case 2: return isUnsigned ? cast(long) cast(ushort) word : cast(long) cast(short) word;
        case 4: return isUnsigned ? cast(long) cast(uint) word : cast(long) cast(int) word;
        default: return word;
    }
}

// `core.math.sqrt` and `core.math.fabs` on a `float` or `double`: the host
// operation on the operand's value, with no call.
private final class FloatIntrinsic(T, string name) : DoubleNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override double executeDouble(ubyte* frame) {
        import core.math: fabs, sqrt;

        const value = cast(T) _operand.executeDouble(frame);
        return mixin(name ~ "(value)");
    }
}

// A call of a declaration that the host code generator inlines, with by
// value scalar arguments and a scalar or no result: the wrapper of the
// shared builtin table reads the argument values where they are and writes
// the result. There is no frame, no argument slots and no call plan.
private final class BuiltinOp : Node {
    private enum maxArguments = 4;

    private imported!"snakebite.backends.builtins".BuiltinCall _entry;
    private Node[] _args;
    private Argument[] _modes;
    private size_t _resultSize;
    private bool _resultUnsigned;

    public this(
        typeof(_entry) entry, Node[] args, Argument[] modes,
        size_t resultSize, bool resultUnsigned,
    ) {
        _entry = entry; _args = args; _modes = modes;
        _resultSize = resultSize; _resultUnsigned = resultUnsigned;
    }

    private void invoke(ubyte* frame, void* result) {
        ulong[maxArguments] values;
        const(void)*[maxArguments] pointers;
        foreach (i, node; _args) {
            // `buildIntrinsicCall` takes only value arguments.
            auto place = cast(ubyte*) &values[i];
            storeArgument(node, _modes[i], frame, place);
            pointers[i] = place;
        }
        _entry(result, pointers.ptr, _args.length);
    }

    public override long executeLong(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
        return extendResult(buffer[0], _resultSize, _resultUnsigned);
    }

    public override double executeDouble(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
        return _resultSize == 4
            ? *cast(float*) buffer.ptr : *cast(double*) buffer.ptr;
    }

    public override void executeVoid(ubyte* frame) {
        ulong[2] buffer;
        invoke(frame, buffer.ptr);
    }
}

// The node of a call that the host runs as one operation: `sqrt` and `fabs`
// of a `float` or `double` computed in place, any other declaration the host
// code generator inlines through its builtin wrapper. Null for any other
// call.
private Node buildIntrinsicCall(E)(E ev, CallExp call, FuncDeclaration function_) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.backends.calls: CallSelection;
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    const selected = ev._callSelection.floatIntrinsicOf(call, function_);
    if (selected != CallSelection.FloatIntrinsic.none) {
        const ty = call.type.toBasetype.ty;
        auto argument = (*call.arguments)[0];
        if ((ty != TY.Tfloat32 && ty != TY.Tfloat64)
                || argument.type.toBasetype.ty != ty)
            return null;
        auto operand = buildValue(ev, argument);
        if (operand is null)
            return null;
        const single = ty == TY.Tfloat32;
        final switch (selected) with (CallSelection.FloatIntrinsic) {
            case none: assert(0, "checked above");
            case sqrt:
                return single ? new FloatIntrinsic!(float, "sqrt")(operand)
                    : new FloatIntrinsic!(double, "sqrt")(operand);
            case fabs:
                return single ? new FloatIntrinsic!(float, "fabs")(operand)
                    : new FloatIntrinsic!(double, "fabs")(operand);
        }
    }

    if (function_.fbody !is null || function_.isThis !is null
            || call.e1.isCommaExp !is null)
        return null;
    auto callee = ev.treeCalleeOf(function_);
    if (callee is null)
        return null;
    const decision = CallSelection.atCallSite(callee.decision, call);
    if (decision.route != CallSelection.Route.builtin
            || decision.destinationParameter != size_t.max
            || call.arguments.length > BuiltinOp.maxArguments)
        return null;
    const isVoid = call.type.toBasetype.ty == TY.Tvoid;
    const result = isVoid ? Scalar() : scalarOf(ev, call.type);
    if (!isVoid && result.kind == Scalar.Kind.none)
        return null;
    Node[] args;
    Argument[] modes;
    if (!buildArguments(ev, typeFunctionOf(function_), call.arguments, args, modes))
        return null;
    foreach (mode; modes)
        if (mode == Argument.address || mode == Argument.pair)
            return null;
    return new BuiltinOp(decision.builtinEntry, args, modes,
        isVoid ? 0 : result.facts.size, result.facts.isUnsigned);
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

// The address of a variable of an enclosing function, or null.
private Node buildOuterAddress(E)(E ev, VarDeclaration variable) {
    import dmd.astenums: STC;
    import snakebite.frontend.dmd.delegates: isCtfeVariable;

    if (variable is null || isCtfeVariable(variable)
            || variable.isSymbolDeclaration !is null
            || (variable.storage_class & STC.lazy_) != 0)
        return null;
    const outer = ev.outerVariableOf(variable);
    return outer.ok ? new OuterAddress(outer) : null;
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

private Node buildVariableAddress(E)(E ev, VarDeclaration variable) {
    const slot = slotOf(ev, variable);
    if (!slot.ok)
        return buildOuterAddress(ev, variable);
    return slot.indirect
        ? new IndirectLocalAddress(slot.offset)
        : new LocalAddress(slot.offset);
}

private Node buildAddress(E)(E ev, Expression expression) {
    import dmd.astenums: TY;
    import dmd.tokens: EXP;
    import dmd.typesem: toBasetype;

    switch (expression.op) with (EXP) {
        case variable:
            return buildVariableAddress(
                ev, expression.isVarExp.var.isVarDeclaration);
        case this_: {
            auto variable = thisVariable(ev, expression.isThisExp);
            const slot = slotOf(ev, variable);
            if (expression.type.toBasetype.ty != TY.Tstruct)
                return null;
            if (!slot.ok)
                return buildOuterAddress(ev, variable);
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
        case question:
            return buildConditional!(buildAddress!E, ConditionalAddress)(
                ev, expression.isCondExp);
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
            if (array is null) {
                auto value = buildSlice(ev, indexed.e1);
                return value is null ? null : new IndexValue(
                    &ev.failTreeBounds, ev._treeRoot, indexed, value, position,
                    element.size);
            }
            return indexOfArray(ev, indexed, array, position, element.size);
        }
        case Tsarray: {
            auto array = buildAddress(ev, indexed.e1);
            return array is null ? null : new IndexStatic(
                &ev.failTreeBounds, ev._treeRoot, indexed, array, position,
                element.size,
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
                    &ev.failTreeBounds, ev._treeRoot, indexed,
                    FrameAddress(frameArray._offset), i, stride);
            return new IndexDynamic!(ChildAddress, I)(
                &ev.failTreeBounds, ev._treeRoot, indexed,
                ChildAddress(array), i, stride);
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

// Constructing a reference variable binds it to the address on the right
// instead of storing a value through it.
private bool bindsReference(E)(E ev, AssignExp e) {
    auto variable = e.e1.isVarExp;
    return e.isConstructExp !is null && variable !is null
        && ev.isRefStorage(variable.var.isVarDeclaration);
}

// A call node: its argument nodes by parameter kind. Null when the call is
// outside what `Call` runs.
private Node buildCall(E)(E ev, CallExp call) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.backends.calls: CallSelection;
    import snakebite.frontend.dmd.dispatch: CallReceiver, readsVtable,
        receiverOf;
    import snakebite.frontend.dmd.functions: typeFunctionOf, unresolvedCalleeOf;

    if (call.vthis2 !is null || call.e1.isCommaExp !is null
            || call.arguments is null)
        return null;
    if (call.f is null)
        return unresolvedCalleeOf(call) is null
            ? buildIndirectCall(ev, call) : null;
    CallSelection.ScalarConstant constant;
    if (ev._callSelection.foldedScalarIntrinsic(call, constant))
        return null;
    auto function_ = ev._callSelection.definitionOf(
        call.f, (declaration) => ev._program.linkedFunctionOf(declaration));
    if (auto intrinsic = buildIntrinsicCall(ev, call, function_))
        return intrinsic;
    // A constructor call keeps the lifetime handling of the original path,
    // except where `new` makes it (`buildConstructorCall`).
    if (function_.isCtorDeclaration !is null)
        return null;
    auto type = typeFunctionOf(function_);

    const isVoid = call.type.toBasetype.ty == TY.Tvoid;
    const resultIsSlice = isSlice(call.type);
    const result = isVoid || resultIsSlice ? Scalar() : scalarOf(ev, call.type);
    if (!isVoid && !resultIsSlice && result.kind == Scalar.Kind.none)
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

    Node[] args;
    Argument[] modes;
    if (!buildArguments(ev, type, call.arguments, args, modes))
        return null;

    auto node = new Call!E(ev, call, function_, receiver, receiverIsAddress,
        virtual, args, modes,
        isVoid ? 0 : resultIsSlice ? SliceValue.sizeof : result.facts.size,
        result.facts.isUnsigned,
        ev.resultIsReceiver(function_));
    if (!virtual) {
        auto callee = ev.treeCalleeOf(function_);
        if (callee is null || !node.matches(callee))
            return null;
        node.bind(callee);
    }
    return node;
}

// A call through a function pointer or a delegate: null when the value of
// the callee is outside what the tree reads, or the call is variadic.
private Node buildIndirectCall(E)(E ev, CallExp call) {
    import dmd.astenums: TY, VarArg;
    import dmd.typesem: nextOf, toBasetype;
    import snakebite.backends.calls: isIndirectDelegateCall;

    auto callee = call.e1;
    const viaDelegate = isIndirectDelegateCall(callee.type);
    Node target;
    imported!"dmd.mtype".TypeFunction type;
    if (viaDelegate) {
        type = callee.type.toBasetype.nextOf.isTypeFunction;
        target = buildDelegate(ev, callee);
    } else {
        // dmd calls a function pointer as `(*pointer)(arguments)`.
        auto dereference = callee.isPtrExp;
        if (dereference is null)
            return null;
        type = dereference.type.isTypeFunction;
        target = buildValue(ev, dereference.e1);
    }
    if (target is null || type is null
            || type.parameterList.varargs != VarArg.none)
        return null;

    const isVoid = call.type.toBasetype.ty == TY.Tvoid;
    const resultIsSlice = isSlice(call.type);
    const result = isVoid || resultIsSlice ? Scalar() : scalarOf(ev, call.type);
    if (!isVoid && !resultIsSlice && result.kind == Scalar.Kind.none)
        return null;

    Node[] args;
    Argument[] modes;
    if (!buildArguments(ev, type, call.arguments, args, modes))
        return null;
    return new IndirectCall!E(ev, call, target, viaDelegate, args, modes,
        isVoid ? 0 : resultIsSlice ? SliceValue.sizeof : result.facts.size,
        result.facts.isUnsigned);
}

// The nodes of the arguments of a call of `type`, one for each parameter,
// and how each one is passed. False when one is outside the supported kinds.
private bool buildArguments(E)(
    E ev, imported!"dmd.mtype".TypeFunction type,
    imported!"dmd.arraytypes".Expressions* arguments, out Node[] args,
    out Argument[] modes,
) {
    import dmd.astenums: STC;

    auto parameters = type.parameterList;
    if (arguments.length != parameters.length)
        return false;
    args = new Node[parameters.length];
    modes = new Argument[parameters.length];
    foreach (i; 0 .. parameters.length) {
        auto parameter = parameters[i];
        auto argument = (*arguments)[i];
        if ((parameter.storageClass & STC.lazy_) != 0)
            return false;
        if ((parameter.storageClass & (STC.ref_ | STC.out_)) != 0) {
            modes[i] = Argument.address;
            args[i] = buildAddress(ev, argument);
        } else if (isSlice(parameter.type)) {
            if (!isSlice(argument.type))
                return false;
            modes[i] = Argument.pair;
            args[i] = buildSlice(ev, argument);
        } else if (isDelegate(parameter.type)) {
            if (!isDelegate(argument.type))
                return false;
            modes[i] = Argument.pair;
            args[i] = buildDelegate(ev, argument);
        } else {
            const declared = scalarOf(ev, parameter.type);
            const given = scalarOf(ev, argument.type);
            if (declared.kind == Scalar.Kind.none
                    || given.kind != declared.kind
                    || given.facts.size != declared.facts.size)
                return false;
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
        }
        if (args[i] is null)
            return false;
    }
    return true;
}

package bool isDelegate(Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;

    return type !is null && type.toBasetype.ty == TY.Tdelegate;
}

// The node that yields the delegate `expression` as two words, or null when
// the tree does not cover the expression. A delegate literal, `&nested` and
// `&object.method` are made by the evaluator: it decides the context and the
// callback address of the function.
private Node buildDelegate(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;

    if (!isDelegate(expression.type))
        return null;
    switch (expression.op) with (EXP) {
        case variable: {
            auto declaration = expression.isVarExp.var.isVarDeclaration;
            const slot = slotOf(ev, declaration);
            if (!slot.ok) {
                auto outer = buildOuterAddress(ev, declaration);
                return outer is null ? null : new LoadSlice(outer);
            }
            return slot.indirect
                ? new LoadSlice(new IndirectLocalAddress(slot.offset))
                : new LocalSlice(slot.offset);
        }
        case dotVariable, star, index: {
            auto address = buildAddress(ev, expression);
            return address is null ? null : new LoadSlice(address);
        }
        case null_:
            return new NullSlice;
        case function_, delegate_:
            return new EvaluatedPair!E(ev, expression);
        case question:
            return buildConditional!(buildDelegate!E, ConditionalInto)(
                ev, expression.isCondExp);
        default:
            return null;
    }
}

// The node that yields the dynamic array `expression`, or null when the
// tree does not cover the expression.
private Node buildSlice(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;

    if (!isSlice(expression.type))
        return null;
    switch (expression.op) with (EXP) {
        case variable: {
            auto declaration = expression.isVarExp.var.isVarDeclaration;
            const slot = slotOf(ev, declaration);
            if (!slot.ok) {
                auto outer = buildOuterAddress(ev, declaration);
                return outer is null ? null : new LoadSlice(outer);
            }
            return slot.indirect
                ? new LoadSlice(new IndirectLocalAddress(slot.offset))
                : new LocalSlice(slot.offset);
        }
        case question:
            return buildConditional!(buildSlice!E, ConditionalInto)(
                ev, expression.isCondExp);
        case dotVariable, star, index: {
            auto address = buildAddress(ev, expression);
            return address is null ? null : new LoadSlice(address);
        }
        case null_:
            return new NullSlice;
        case string_: {
            SliceValue value;
            ev._nativeData.write(expression.type, ev.factsOf(expression.type),
                expression, cast(ubyte*) &value);
            return new ConstantSlice(value);
        }
        case slice:
            return buildSliceOf(ev, expression.isSliceExp);
        case call:
            return buildCall(ev, expression.isCallExp);
        case new_:
            return buildNew(ev, expression.isNewExp);
        case cast_:
            return buildSliceCast(ev, expression.isCastExp);
        case comma:
            return buildComma(ev, expression.isCommaExp, &buildSlice!E);
        case assign, construct, blit:
            return buildSliceStore(ev, cast(AssignExp) expression);
        default:
            return null;
    }
}

private Node buildSliceStore(E)(E ev, AssignExp e) {
    if (bindsReference(ev, e)
            || (e.isConstructExp !is null && e.isConstructExp.lowering !is null)
            || e.e1.isDotVarExp is null && e.e1.isVarExp is null
                && e.e1.isIndexExp is null && e.e1.isPtrExp is null
            || !isSlice(e.e1.type))
        return null;
    auto value = buildSlice(ev, e.e2);
    if (value is null)
        return null;
    if (auto variable = e.e1.isVarExp) {
        const slot = slotOf(ev, variable.var.isVarDeclaration);
        if (!slot.ok)
            return null;
        if (!slot.indirect)
            return new StoreSlice!FrameAddress(FrameAddress(slot.offset), value);
    }
    auto address = buildAddress(ev, e.e1);
    return address is null
        ? null : new StoreSlice!ChildAddress(ChildAddress(address), value);
}

// `first, second`: `second` is built by `buildSecond`.
private Node buildComma(E)(
    E ev, imported!"dmd.expression".CommaExp comma,
    Node function(E, Expression) buildSecond,
) {
    auto first = buildEffect(ev, comma.e1);
    auto second = buildSecond(ev, comma.e2);
    return first is null || second is null ? null : new Comma(first, second);
}

private Node buildSliceOf(E)(E ev, SliceExp expression) {
    import dmd.astenums: TY;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf, toBasetype;
    import snakebite.backends.sliceplan: planSlice;

    const plan = planSlice(expression);
    if (plan.yieldsStaticArray || expression.lengthVar !is null)
        return null;
    Node lower, upper;
    if (expression.lwr !is null) {
        lower = buildValue(ev, expression.lwr);
        if (lower is null)
            return null;
    }
    if (expression.upr !is null) {
        upper = buildValue(ev, expression.upr);
        if (upper is null)
            return null;
    }
    auto sourceType = expression.e1.type.toBasetype;
    const stride = ev.factsOf(sourceType.nextOf).size;
    static Node make(SliceSource source)(
        FailBounds fail, TreeRoot* root, SliceExp expression, Node base,
        Node lower, Node upper, size_t stride, size_t staticLength,
        in SlicePlan plan,
    ) {
        return new SliceOf!source(fail, root, expression, base, lower, upper,
            stride, staticLength, plan);
    }
    switch (sourceType.ty) with (TY) {
        case Tarray: {
            auto base = buildSlice(ev, expression.e1);
            return base is null ? null : make!(SliceSource.slice)(
                &ev.failTreeBounds, ev._treeRoot, expression, base, lower, upper, stride,
                0, plan);
        }
        case Tpointer: {
            static if (E.nullCheckedEvaluator)
                return null;
            else {
                auto base = buildValue(ev, expression.e1);
                return base is null ? null : make!(SliceSource.pointer)(
                    &ev.failTreeBounds, ev._treeRoot, expression, base, lower, upper,
                    stride, 0, plan);
            }
        }
        case Tsarray: {
            auto base = buildAddress(ev, expression.e1);
            return base is null ? null : make!(SliceSource.staticArray)(
                &ev.failTreeBounds, ev._treeRoot, expression, base, lower, upper, stride,
                cast(size_t) sourceType.isTypeSArray.dim.toInteger, plan);
        }
        default:
            return null;
    }
}

// A cast whose result is a dynamic array.
private Node buildSliceCast(E)(E ev, CastExp castExp) {
    import snakebite.backends.casts: layoutOf;
    import snakebite.nativevalue: CastKind;

    if (castExp.lowering !is null)
        return buildSlice(ev, castExp.lowering);
    const plan = *ev._shared.facts.castOf(castExp);
    with (CastKind) switch (plan.kind) {
        case copy:
            return isSlice(castExp.e1.type) ? buildSlice(ev, castExp.e1) : null;
        case reinterpretSlice: {
            if (!isSlice(castExp.e1.type))
                return null;
            auto operand = buildSlice(ev, castExp.e1);
            return operand is null
                ? null : new ReinterpretSlice(operand, layoutOf(plan));
        }
        case sarrayToSlice: {
            auto address = buildAddress(ev, castExp.e1);
            return address is null
                ? null : new StaticArrayToSlice(address, plan.staticLength);
        }
        default:
            return null;
    }
}

// `new` yields the object it allocated. The allocation is the call of the
// hook that dmd lowered it to. An object that needs more than that has its
// constructor called on the allocation; a nested context, fields given in
// order and the value of `new int(1)` stay with the evaluator.
private Node buildNew(E)(E ev, NewExp expression) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.backends.aggregateinit: NewPlan, planClassContext,
        planNew, planPositionalFields;

    const plan = planNew(expression);
    if (plan.destination != NewPlan.Destination.lowering
            || expression.lowering is null || plan.argumentPrefix !is null
            || expression.thisexp !is null)
        return null;
    auto allocation = isSlice(expression.lowering.type)
        ? buildSlice(ev, expression.lowering)
        : buildValue(ev, expression.lowering);
    if (allocation is null)
        return null;

    auto newtype = expression.newtype.toBasetype;
    const aggregate = newtype.ty == TY.Tclass || newtype.ty == TY.Tstruct;
    if (!aggregate) {
        // `new int(1)` also stores its argument.
        const stores = expression.type.toBasetype.ty == TY.Tpointer
            && expression.arguments !is null && expression.arguments.length != 0;
        return stores ? null : allocation;
    }

    const contextSteps = newtype.ty == TY.Tclass
        ? planClassContext(expression).steps.length : 0;
    if (contextSteps != 0)
        return null;
    if (expression.member !is null)
        return buildConstructorCall(ev, expression, allocation);
    const fieldSteps = newtype.ty == TY.Tstruct
        ? planPositionalFields(
            newtype.isTypeStruct.sym, expression.arguments).steps.length : 0;
    return fieldSteps == 0 ? allocation : null;
}

// The constructor of `new`, called on the allocation.
private Node buildConstructorCall(E)(E ev, NewExp expression, Node allocation) {
    import dmd.astenums: VarArg;
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    auto constructor = ev._callSelection.definitionOf(
        expression.member,
        (declaration) => ev._program.linkedFunctionOf(declaration));
    auto type = typeFunctionOf(constructor);
    if (expression.arguments is null || type.parameterList.varargs != VarArg.none)
        return null;
    Node[] args;
    Argument[] modes;
    if (!buildArguments(ev, type, expression.arguments, args, modes))
        return null;
    auto node = new Call!E(ev, null, constructor, allocation,
        /* receiverIsAddress */ false, /* virtual */ false, args, modes,
        /* resultSize */ 0, /* resultUnsigned */ false,
        ev.resultIsReceiver(constructor));
    auto callee = ev.treeCalleeOf(constructor);
    if (callee is null || !node.matches(callee))
        return null;
    node.bind(callee);
    return node;
}

// The effect of `expression`, whatever its type, or null.
private Node buildEffect(E)(E ev, Expression expression) {
    import dmd.astenums: TY;
    import dmd.tokens: EXP;
    import dmd.typesem: toBasetype;

    if (auto declaration = expression.isDeclarationExp)
        return buildDeclaration(ev, declaration);
    if (isSlice(expression.type))
        return buildSlice(ev, expression);
    if (expression.type !is null && expression.type.toBasetype.ty == TY.Tvoid) {
        if (expression.op == EXP.question)
            return buildConditional!(buildEffect!E, ConditionalVoid)(
                ev, expression.isCondExp);
        return expression.op == EXP.call
            ? buildCall(ev, expression.isCallExp) : null;
    }
    return buildValue(ev, expression);
}

// The node that tests the truth of `expression`, as a condition does.
private Node buildTruth(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;
    import snakebite.backends.plaincondition: isPlainCondition;

    if (expression.op == EXP.comma)
        return buildComma(ev, expression.isCommaExp, &buildTruth!E);
    if (isSlice(expression.type)) {
        auto slice = buildSlice(ev, expression);
        return slice is null ? null : new SliceTruth(slice, expression.type);
    }
    const splits = expression.op == EXP.andAnd || expression.op == EXP.orOr
        || expression.op == EXP.not;
    if (splits && isPlainCondition(expression))
        return buildBranches(ev, expression, FullExpressionScope.Position.condition);
    return buildValue(ev, expression);
}

// The node of a condition that makes no temporary of its own, so that each
// operand of `&&`, `||` and `!` can be a test of its own: an operand that
// the tree does not build goes to the evaluator as a full expression, as it
// does inside the evaluator's own `&&`.
private Node buildBranches(E)(
    E ev, Expression expression, in FullExpressionScope.Position position,
) {
    import dmd.tokens: EXP;

    Node operand(Expression one, in FullExpressionScope.Position where) {
        const splits = one.op == EXP.andAnd || one.op == EXP.orOr
            || one.op == EXP.not;
        if (splits)
            return buildBranches(ev, one, where);
        auto node = buildTruth(ev, one);
        return node is null ? new GenericCondition!E(ev, one, where) : node;
    }

    if (expression.op == EXP.not)
        return new Tested!NotTest(NotTest(
            operand(expression.isNotExp.e1, position)));
    auto logical = expression.isLogicalExp;
    return logicalOf(
        expression.op == EXP.andAnd,
        operand(logical.e1, position),
        operand(logical.e2, FullExpressionScope.Position.logicalOperand));
}

private Node logicalOf(in bool andAnd, Node left, Node right) {
    if (!andAnd)
        return new Tested!OrTest(OrTest(left, right));
    if (auto flag = cast(Local!ubyte) left)
        return right.andFlag(flag._offset);
    return new Tested!AndTest(AndTest(left, right));
}

// The node that yields `expression`'s scalar value.
private Node buildValue(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;
    import snakebite.backends.logical: LogicalPlan, logicalPlan;
    import snakebite.frontend.storage: typeInfoAddressedBy;
    import snakebite.nativelayout: isStaticStructAddress, loadIntegral;
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
            auto array = expression.isArrayLengthExp.e1;
            if (scalar.kind != Scalar.Kind.integral
                    || scalar.facts.size != size_t.sizeof)
                return null;
            auto address = buildAddress(ev, array);
            if (address !is null)
                return new Load!size_t(address);
            auto value = buildSlice(ev, array);
            return value is null ? null : new SliceWord(value, lengthOffset);
        }
        case variable: {
            auto declaration = expression.isVarExp.var.isVarDeclaration;
            const slot = slotOf(ev, declaration);
            if (!slot.ok)
                return buildLoad(ev, expression,
                    buildOuterAddress(ev, declaration));
            if (slot.indirect)
                return buildLoad(ev, expression,
                    new IndirectLocalAddress(slot.offset));
            return scalar.kind == Scalar.Kind.floating
                ? byFloating!(New!Local)(scalar.facts, slot.offset)
                : byIntegral!(New!Local)(scalar.facts, slot.offset);
        }
        case this_: {
            auto variable = thisVariable(ev, expression.isThisExp);
            const slot = slotOf(ev, variable);
            if (scalar.kind != Scalar.Kind.integral)
                return null;
            if (!slot.ok) {
                // The `this` of an enclosing method, read by a nested function.
                auto outer = buildOuterAddress(ev, variable);
                return outer is null ? null : new Load!size_t(outer);
            }
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
            return buildEquality!false(ev, expression.isEqualExp);
        case notEqual:
            return buildEquality!true(ev, expression.isEqualExp);
        case andAnd, orOr: {
            auto logical = expression.isLogicalExp;
            const plan = logicalPlan(logical);
            if (plan.right != LogicalPlan.Right.value || !plan.hasValue)
                return null;
            auto left = buildTruth(ev, logical.e1);
            auto right = buildTruth(ev, logical.e2);
            if (left is null || right is null)
                return null;
            return logicalOf(plan.andAnd, left, right);
        }
        case not: {
            auto operand = buildTruth(ev, expression.isNotExp.e1);
            return operand is null ? null : new Tested!NotTest(NotTest(operand));
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
        case new_:
            return buildNew(ev, expression.isNewExp);
        case function_:
            return scalar.kind == Scalar.Kind.integral
                ? new EvaluatedWord!E(ev, expression) : null;
        case symbolOffset: {
            // `&variable`. A function or a variable in static storage has
            // an address that symbol resolution decides.
            if (scalar.kind != Scalar.Kind.integral)
                return null;
            auto symbol = expression.isSymOffExp;
            auto variable = symbol.var.isVarDeclaration;
            auto place = variable is null
                ? null : buildVariableAddress(ev, variable);
            if (place is null)
                return new EvaluatedWord!E(ev, expression);
            return new AddressValue(symbol.offset == 0
                ? place : new FieldOfAddress(place, cast(size_t) symbol.offset));
        }
        case address: {
            // The address of a static struct literal or of a type's
            // `TypeInfo` is a constant that the evaluator resolves.
            auto addressed = expression.isAddrExp;
            if (scalar.kind != Scalar.Kind.integral
                    || isStaticStructAddress(addressed)
                    || addressed.typeInfoAddressedBy(*ev._runtimeTypes) !is null)
                return null;
            auto location = buildAddress(ev, addressed.e1);
            return location is null ? null : new AddressValue(location);
        }
        case typeid_: {
            import dmd.dtemplate: isExpression, isType;

            if (auto object = isExpression(expression.isTypeidExp.obj))
                return buildTypeidOf(ev, object, scalar);
            auto type = isType(expression.isTypeidExp.obj);
            if (type is null || scalar.kind != Scalar.Kind.integral)
                return null;
            return new Constant!long(cast(long) cast(size_t) cast(void*)
                ev._runtimeTypes.get(type));
        }
        case comma:
            return buildComma(ev, expression.isCommaExp, &buildValue!E);
        case question: {
            auto conditional = expression.isCondExp;
            bool differs(Expression arm) {
                return scalarOf(ev, arm.type).kind != scalar.kind
                    || ev.factsOf(arm.type).size != scalar.facts.size;
            }
            if (differs(conditional.e1) || differs(conditional.e2))
                return null;
            return scalar.kind == Scalar.Kind.floating
                ? buildConditional!(buildValue!E, ConditionalDouble)(
                    ev, conditional)
                : buildConditional!(buildValue!E, ConditionalLong)(
                    ev, conditional);
        }
        case identity: return buildIdentity!false(ev, expression.isIdentityExp);
        case notIdentity: return buildIdentity!true(ev, expression.isIdentityExp);
        default:
            return null;
    }
}

// `test ? first : second`, with `buildBranch` building each branch and `Result` the node.
private Node buildConditional(alias buildBranch, Result, E)(
    E ev, imported!"dmd.expression".CondExp e,
) {
    auto test = buildTruth(ev, e.econd);
    auto first = buildBranch(ev, e.e1);
    auto second = buildBranch(ev, e.e2);
    if (test is null || first is null || second is null)
        return null;
    return new Result(test, first, second);
}

// `typeid(object)`: the class information the object's vtable points to.
// The vtable of an object of an interface type has the interface's own
// information in between.
private Node buildTypeidOf(E)(E ev, Expression object, in Scalar scalar) {
    import snakebite.backends.classinfo: typeidLoadCount;

    static if (E.nullCheckedEvaluator)
        return null;
    else {
        if (scalar.kind != Scalar.Kind.integral)
            return null;
        auto node = buildValue(ev, object);
        if (node is null)
            return null;
        foreach (i; 0 .. typeidLoadCount(object))
            node = new Load!size_t(new Dereference(node));
        return node;
    }
}

private Node buildIdentity(bool negate, E)(E ev, IdentityExp e) {
    import snakebite.backends.identity: identityPlan;

    // `is` compares bits: the plan says how many, and which operands need
    // no compare. The nodes below serve the widths they can carry.
    const plan = identityPlan(e);
    if (plan.staticArray || plan.skipCompare)
        return null;
    if (plan.width == SliceValue.sizeof) {
        auto left = buildSlice(ev, e.e1);
        auto right = buildSlice(ev, e.e2);
        if (left !is null && right !is null)
            return new SliceIdentity!negate(left, right);
        return null;
    }
    auto left = buildValue(ev, e.e1);
    auto right = buildValue(ev, e.e2);
    if (left is null || right is null)
        return null;
    if (cast(DoubleNode) left is null && cast(DoubleNode) right is null) {
        // The same bits are the same value whatever the signedness.
        static Node same(L, R)(L l, R r) {
            enum op = negate ? "!=" : "==";
            return new IntegerCompare!(op, false, L, R)(
                IntegerTest!(op, false, L, R)(l, r));
        }
        return fuse!(same, long, longLeft, longRight)(
            operandOf(left), operandOf(right));
    }
    if (cast(DoubleNode) left is null || cast(DoubleNode) right is null)
        return null;
    static Node bits(T)(Node l, Node r) {
        static Node build(L, R)(L a, R b) {
            return new FloatIdentity!(negate, T, L, R)(a, b);
        }
        return fuse!(build, double, onlyChild, onlyChild)(
            operandOf(l), operandOf(r));
    }
    switch (plan.width) {
        case float.sizeof: return bits!float(left, right);
        case double.sizeof: return bits!double(left, right);
        default: return null;
    }
}

private template unaryOf(string op) {
    public Node unaryOf(T)(Node operand) { return new IntegerUnary!(op, T)(operand); }
}

private Node buildCast(E)(E ev, CastExp castExp, in Scalar scalar) {
    import snakebite.nativevalue: CastKind;

    if (castExp.lowering !is null)
        return buildValue(ev, castExp.lowering);
    enum integral = Scalar.Kind.integral;
    enum floating = Scalar.Kind.floating;
    const plan = *ev._shared.facts.castOf(castExp);
    if (isSlice(castExp.e1.type))
        return buildSliceToScalar(ev, castExp, plan.kind, scalar);
    const source = scalarOf(ev, castExp.e1.type);
    if (source.kind == Scalar.Kind.none)
        return null;
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

// A cast of a dynamic array to its truth or to its pointer.
private Node buildSliceToScalar(E)(
    E ev, CastExp castExp, in imported!"snakebite.nativevalue".CastKind kind,
    in Scalar scalar,
) {
    import snakebite.nativevalue: CastKind;

    auto slice = buildSlice(ev, castExp.e1);
    if (slice is null || scalar.kind != Scalar.Kind.integral)
        return null;
    if (kind == CastKind.truth)
        return new SliceTruth(slice, castExp.e1.type);
    if (kind != CastKind.sliceToPointer)
        return null;
    if (auto address = buildAddress(ev, castExp.e1))
        return new Load!size_t(new FieldOfAddress(address, pointerOffset));
    return new SliceWord(slice, pointerOffset);
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

// `==` and `!=`: dmd's lowering (a call to `__equals`) where it made one;
// otherwise dynamic arrays compared as bytes, or a scalar compare.
private Node buildEquality(bool negate, E)(E ev, EqualExp e) {
    import snakebite.backends.comparison: ComparisonPlan, comparisonPlan;

    if (e.lowering !is null)
        return buildValue(ev, e.lowering);
    const plan = comparisonPlan(e);
    if (plan.kind == ComparisonPlan.Kind.dynamicArray
            || plan.kind == ComparisonPlan.Kind.staticArray) {
        auto left = buildArrayOperand(ev, e.e1);
        auto right = buildArrayOperand(ev, e.e2);
        if (left is null || right is null)
            return null;
        return new SliceEquality!negate(left, right, plan.elementSize);
    }
    return buildCompare!(negate ? "!=" : "==")(ev, e);
}

// An operand of an array comparison as a dynamic array value: a static
// array is its address and its length.
private Node buildArrayOperand(E)(E ev, Expression operand) {
    import dmd.astenums: TY;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: toBasetype;

    auto type = operand.type.toBasetype;
    if (type.ty != TY.Tsarray)
        return buildSlice(ev, operand);
    auto address = buildAddress(ev, operand);
    return address is null ? null : new StaticArrayToSlice(
        address, cast(size_t) type.isTypeSArray.dim.toInteger);
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
    if (bindsReference(ev, e))
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
    return Position(cast(const(void)*) root);
}

// The statement that a declaration is: one for each runtime variable it
// declares. A declaration of an alias, a type, a template or a manifest
// constant has nothing to run.
private Node buildDeclaration(E)(E ev, DeclarationExp declaration) {
    import snakebite.backends.declaration: forEachRuntimeVariable;

    Node[] nodes;
    bool covered = true;
    forEachRuntimeVariable(declaration.declaration, (variable) {
        if (!covered)
            return;
        auto node = buildVariable(ev, variable, declaration);
        if (node is null)
            covered = false;
        else
            nodes ~= node;
    });
    if (!covered)
        return null;
    if (nodes.length == 0)
        return new Jump!(TreeFlow.normal);
    if (nodes.length == 1)
        return nodes[0];
    return new Sequence(nodes);
}

private Node buildVariable(E)(
    E ev, VarDeclaration variable, DeclarationExp declaration) {
    import snakebite.nativelayout: initializerRunsForEffect, initializerValueOf;

    if (variable.isDataseg)
        return null;
    if (variable._init is null || variable._init.isVoidInitializer !is null)
        return new Jump!(TreeFlow.normal);
    auto initializer = variable._init.isExpInitializer;
    if (initializer is null)
        return null;
    if (ev.isRefStorage(variable)
            && !initializerRunsForEffect(initializer, variable))
        return buildReferenceBinding(
            ev, variable, initializerValueOf(initializer),
            positionOf(ev, declaration));
    const scalar = scalarOf(ev, variable.type);
    const variableIsSlice = isSlice(variable.type);
    if (scalar.kind == Scalar.Kind.none && !variableIsSlice)
        return null;
    if (initializerRunsForEffect(initializer, variable)) {
        auto effect = buildEffect(ev, initializer.exp);
        return effect is null
            ? null : statementOf(effect, positionOf(ev, declaration));
    }
    auto value = initializerValueOf(initializer);
    const slot = slotOf(ev, variable);
    if (!slot.ok || slot.indirect || ev.isRefStorage(variable))
        return null;
    if (variableIsSlice) {
        if (!isSlice(value.type))
            return null;
        auto node = buildSlice(ev, value);
        return node is null ? null : statementOf(
            new StoreSlice!FrameAddress(FrameAddress(slot.offset), node),
            positionOf(ev, declaration));
    }
    if (scalarOf(ev, value.type).kind != scalar.kind
            || ev.factsOf(value.type).size != scalar.facts.size)
        return null;
    auto node = buildValue(ev, value);
    if (node is null)
        return null;
    return statementOf(storeToFrame(scalar, slot.offset, node),
        positionOf(ev, declaration));
}

// A struct or a static array: a value of its own bytes, which is not a
// register scalar or a slice.
private bool isAggregate(Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;

    if (type is null)
        return false;
    const kind = type.toBasetype.ty;
    return kind == TY.Tstruct || kind == TY.Tsarray;
}

// The node that writes the value of the struct or static array `expression`
// where `executeInto` says. Null when the tree does not cover the
// expression.
private Node buildAggregate(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;

    if (!isAggregate(expression.type))
        return null;
    switch (expression.op) with (EXP) {
        case structLiteral:
            return buildStructLiteral(ev, expression.isStructLiteralExp);
        case arrayLiteral:
            return buildArrayLiteral(ev, expression.isArrayLiteralExp);
        case question:
            return buildConditional!(buildAggregate!E, ConditionalInto)(
                ev, expression.isCondExp);
        case comma:
            return buildComma(ev, expression.isCommaExp, &buildAggregate!E);
        case variable, this_, dotVariable, star, index: {
            auto address = buildAddress(ev, expression);
            return address is null ? null : new AggregateCopy(
                address, ev.factsOf(expression.type).size);
        }
        default:
            return null;
    }
}

private Node buildStructLiteral(E)(E ev, imported!"dmd.expression".StructLiteralExp literal) {
    import snakebite.nativelayout: isStoredLiteral;

    const facts = ev.factsOf(literal.type);
    if (literal.useStaticInit)
        return new ImageInto(
            cast(immutable(ubyte)[]) ev._nativeData.initialValue(
                literal.type, literal.loc).idup);
    if (isStoredLiteral(literal)) {
        auto image = new ubyte[facts.size];
        ev._nativeData.write(literal.type, facts, literal, image.ptr);
        return new ImageInto(cast(immutable) image);
    }
    auto plan = *ev._shared.facts.structLiteralOf(literal);
    Node[] steps;
    foreach (step; plan.steps) {
        auto node = buildInitStep(ev, step);
        if (node is null)
            return null;
        steps ~= node;
    }
    return new StructLiteral(steps, facts.size, plan.zeroFill);
}

// `[a, b, c]` as a static array: each element fills its own place. The
// literal is written where the caller wants the result, with no staging
// area, because only a return operand or a field of one reaches here.
private Node buildArrayLiteral(E)(
    E ev, imported!"dmd.expression".ArrayLiteralExp literal,
) {
    import snakebite.backends.arrayliteral: ArrayLiteralPlan, planArrayLiteral;
    import snakebite.nativelayout: isStoredLiteral;

    auto plan = planArrayLiteral(literal, ev._function);
    assert(plan.result == ArrayLiteralPlan.Result.value,
        "a static array literal is a value");
    if (isStoredLiteral(literal)) {
        auto image = new ubyte[ev.factsOf(literal.type).size];
        ev._nativeData.write(
            literal.type, ev.factsOf(literal.type), literal, image.ptr);
        return new ImageInto(cast(immutable) image);
    }
    Node[] steps;
    foreach (i; 0 .. plan.count) {
        auto node = buildFieldValue(
            ev, i * plan.elementFacts.size, plan.elementType, literal[i]);
        if (node is null)
            return null;
        steps ~= node;
    }
    return new StructLiteral(steps, plan.bytes, false);
}

private Node buildInitStep(E)(E ev, InitStep step) {
    final switch (step.kind) with (InitStep.Kind) {
        case vthis:
            return new ContextStore!E(ev, step);
        case value:
            return buildFieldValue(ev, step.offset, step.type, step.source);
        case bitfield: {
            const scalar = scalarOf(ev, step.type);
            if (scalar.kind != Scalar.Kind.integral
                    || scalarOf(ev, step.source.type).kind != scalar.kind)
                return null;
            auto value = buildValue(ev, step.source);
            return value is null ? null : new BitfieldStore(
                step.offset, *ev._shared.facts.bitfieldOf(step.field), value);
        }
        case broadcast: {
            const scalar = scalarOf(ev, step.type);
            if (scalar.kind == Scalar.Kind.none)
                return null;
            auto value = buildValue(ev, step.source);
            if (value is null)
                return null;
            static Node make(T)(size_t offset, size_t count, Node v) {
                return new FieldBroadcast!T(offset, count, v);
            }
            return scalar.kind == Scalar.Kind.floating
                ? byFloating!make(scalar.facts, step.offset, step.count, value)
                : byIntegral!make(scalar.facts, step.offset, step.count, value);
        }
    }
}

private Node buildFieldValue(E)(
    E ev, in size_t offset, Type type, Expression source,
) {
    if (isSlice(type)) {
        if (!isSlice(source.type))
            return null;
        auto slice = buildSlice(ev, source);
        return slice is null ? null : new IntoOffset(offset, slice);
    }
    if (isAggregate(type)) {
        auto value = buildAggregate(ev, source);
        return value is null ? null : new IntoOffset(offset, value);
    }
    const scalar = scalarOf(ev, type);
    if (scalar.kind == Scalar.Kind.none
            || scalarOf(ev, source.type).kind != scalar.kind
            || ev.factsOf(source.type).size != scalar.facts.size)
        return null;
    auto value = buildValue(ev, source);
    if (value is null)
        return null;
    static Node make(T)(size_t offset, Node v) {
        return new FieldStore!T(offset, v);
    }
    return scalar.kind == Scalar.Kind.floating
        ? byFloating!make(scalar.facts, offset, value)
        : byIntegral!make(scalar.facts, offset, value);
}

// A `ref` variable holds the address of the storage it names, whatever the
// type of that storage is.
private Node buildReferenceBinding(E)(
    E ev, VarDeclaration variable, Expression value, Position position,
) {
    const slot = slotOf(ev, variable);
    if (!slot.ok)
        return null;
    auto address = buildAddress(ev, value);
    return address is null
        ? null : statementOf(new BindReference(slot.offset, address), position);
}

private Node buildStatement(E)(E ev, Statement statement, Node* slot) {
    import dmd.astenums: STMT;
    import dmd.tokens: EXP;
    import snakebite.backends.ifplan: IfPlan, ifPlan;

    Node generic() {
        return new GenericStatement!E(ev, statement);
    }

    Node child(Statement inner, Node* where) {
        return new Uninitialised!E(ev, inner, where, ev._treeRoot);
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
        auto node = buildTruth(ev, expression);
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
            auto node = buildEffect(ev, expression);
            return node is null
                ? generic() : statementOf(node, positionOf(ev, expression));
        }
        case If: {
            auto conditional = statement.isIfStatement;
            if (ifPlan(conditional).kind != IfPlan.Kind.condition
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
        case Import:
            return new Jump!(TreeFlow.normal);
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
    if (typeFunctionOf(ev._function).isRef) {
        auto address = buildAddress(ev, returned.exp);
        return address is null ? generic() : new ReturnReference(
            &ev._place, address, positionOf(ev, returned.exp));
    }
    if (ev._type.toBasetype.ty == TY.Tvoid) {
        // `return f();` in a function without a result: `f` runs, then the
        // function ends.
        auto effect = buildEffect(ev, returned.exp);
        if (effect is null)
            return generic();
        auto sequence = new ShortSequence!2;
        sequence._children[0] = statementOf(effect, positionOf(ev, returned.exp));
        sequence._children[1] = new Jump!(TreeFlow.return_);
        return sequence;
    }
    if (isSlice(ev._type)) {
        if (!isSlice(returned.exp.type))
            return generic();
        auto slice = buildSlice(ev, returned.exp);
        return slice is null
            ? generic() : new ReturnValue!SliceValue(
                &ev._place, slice, positionOf(ev, returned.exp));
    }
    if (isAggregate(ev._type)) {
        if (!isAggregate(returned.exp.type))
            return generic();
        auto value = buildAggregate(ev, returned.exp);
        return value is null ? generic() : new ReturnAggregate!E(
            ev, value, positionOf(ev, returned.exp), ev.factsOf(ev._type));
    }
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
