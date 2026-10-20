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
    fastFrameLead, faultSlotOf, placeSlotOf;
import snakebite.backends.interpreter.integeroperations: combine, shifted;
import snakebite.ffi.load: callDirectWordsPair, extendWord, storeWordResult, WordPair;
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
    private Statements _statements;
    // The return statement of a function whose body is only that statement,
    // once it has run: a call that takes the value in a register runs it.
    private Node _soleReturn;
    package const(imported!"snakebite.backends.closureplan".ClosurePlan)*
        closurePlan;
    package Type returnType;
    package TypeFacts returnFacts;
    // The full expression that the builder is building.
    private Region* _region;

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
        return _statements.run(frame);
    }

    package bool hasSoleReturn() const {
        return _soleReturn !is null;
    }

    package long returnLong(ubyte* frame) {
        return _soleReturn.returnLong(frame);
    }

    package double returnDouble(ubyte* frame) {
        return _soleReturn.returnDouble(frame);
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
    auto statements = statementsOf(body_);
    auto nodes = new Node[statements.length];
    foreach (i, one; statements)
        nodes[i] = new Uninitialised!E(ev, one, &nodes[i], root);
    root._statements = Statements(nodes);
    return root;
}

// The nodes of the full expression that the builder is building whose work
// depends on how the expression ends.
private struct Region {
    // Whether the expression is a part of the expression around it.
    public enum Nesting { outermost, nested }

    public Region* outer;
    public Materialise[] materialised;
    // The expression has temporaries that the evaluator's lifetime owns.
    public bool scoped;
}

// A full expression that the builder built, and what it needs when it runs.
private struct Built {
    public Node node;
    public bool scoped;
    public Materialise[] materialised;
}

// Builds a full expression with `build`. The `Materialise` nodes of an
// expression whose temporaries the evaluator's lifetime owns take their
// storage from it. Those of a `nested` expression that the lifetime does not
// own last as long as the enclosing expression.
private Built buildRegion(E)(
    E ev, in Region.Nesting nesting, scope Node delegate() build,
) {
    const nested = nesting == Region.Nesting.nested;
    auto root = ev._treeRoot;
    Region region;
    region.outer = nested ? root._region : null;
    auto saved = root._region;
    root._region = &region;
    scope (exit) root._region = saved;
    auto node = build();
    if (node is null)
        return Built.init;
    if (region.scoped)
        foreach (one; region.materialised)
            one._scoped = true;
    else if (nested)
        region.outer.materialised ~= region.materialised;
    return Built(node, region.scoped, region.materialised);
}

// The node of a statement or a condition whose full expression `built` is:
// it gives back the storage of the expression's rvalues, or runs it in the
// evaluator's lifetime, when the expression ends.
private Node endingAt(E)(
    E ev, in Built built, Expression expression,
    in FullExpressionScope.Position where,
) {
    if (built.scoped)
        return new Scoped!E(ev, cast() built.node, expression, where,
            positionOf(ev, expression));
    if (built.materialised.length != 0)
        return new FrameRelease(
            ev, cast() built.node, cast(Materialise[]) built.materialised);
    return cast() built.node;
}

// What a callee writes at the place that its call gives it: a value of at
// most two words, a struct or a static array, or the address of the result
// of a function that returns `ref`.
package enum CalleeResult : ubyte { value, aggregate, reference }

// What a call node needs to know about its callee, decided once per
// function.
package struct TreeCallee {
    import snakebite.backends.calls: CallSelection;
    import snakebite.backends.layout: FrameLayout;
    import snakebite.ffi.plan: CallPlan;

    package FuncDeclaration function_;
    package CallSelection.Decision decision;
    package const(FrameLayout)* layout;
    package TreeRoot* root;
    // The slots that a call fills in the frame, in the order that it fills
    // them, and the bytes that it reserves for the frame. They are the
    // parameters of the layout, and more for a variadic callee: the cursor
    // of the extra arguments and the `TypeInfo` tuple of a guest callee; the
    // tuple, the parameters and each extra argument of one call site for a
    // host callee, after the frame of its layout.
    package const(FrameLayout.Parameter)[] slots;
    // How many of the slots are declared parameters, which come first. The
    // call site of an indirect call agrees on it with the callee.
    package size_t declared;
    package size_t frameSize;
    // The plan of a native callee, made for one call site when the callee is
    // variadic. Null when the call site makes it.
    package const(CallPlan)* plan;
    package TypeFacts returnFacts;
    package CalleeResult result;
    // The bytes in front of the frame base, for its fault slot
    // (`frameLead`), and whether the reservation meets the contract of
    // `FrameStack.reserveFast` with `fastFrameLead` bytes in front.
    package size_t lead;
    package bool reservesFast;
    // What the body of the callee is, found when a call node first binds it.
    package CalleeShape shape;
    // Whether a native callee is a direct word call, found when a call node
    // first binds it.
    package DirectWordCall direct;
}

// The body of a function when it is a getter (`return this.field;`), a
// setter (`this.field = parameter;`), or only a `return`.
package struct CalleeShape {
    package enum Kind : ubyte { unexamined, other, soleReturn, getter, setter }

    package Kind kind;
    // The field of an accessor: where it is in the receiver and how wide.
    package size_t offset;
    package size_t size;
    package bool isUnsigned;
    package bool isFloating;
    package const(void)* position;
}

// What the fault handler reads when the load or the store of an accessor
// faults: the accessor, and the full expression that it runs.
package struct AccessSite {
    package FuncDeclaration function_;
    package const(void)* position;
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
    // A return statement gives its value to the caller in a register.
    public long returnLong(ubyte* frame) { assert(0); }
    public double returnDouble(ubyte* frame) { assert(0); }
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

// The value at `PointerAddress(slot, offset)`.
private final class LoadField(T) : Typed!T {
    private size_t _slot;
    private size_t _offset;
    public this(size_t slot, size_t offset) { _slot = slot; _offset = offset; }
    static if (isFloatingPoint!T)
        public override double executeDouble(ubyte* frame) {
            return *cast(T*) (*cast(ubyte**) (frame + _slot) + _offset);
        }
    else {
        public override long executeLong(ubyte* frame) {
            return *cast(T*) (*cast(ubyte**) (frame + _slot) + _offset);
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

// A pointer held in a frame slot, and a constant offset from it: a `ref`
// parameter or a local that holds the address of the storage it names, the
// field of such storage, and the field of a pointer or an object held in a
// local.
private final class PointerAddress : Node {
    private size_t _slot;
    private size_t _offset;
    public this(size_t slot, size_t offset) { _slot = slot; _offset = offset; }
    public override ubyte* executeAddr(ubyte* frame) {
        return *cast(ubyte**) (frame + _slot) + _offset;
    }
}

// A variable of an enclosing function: the static chain's words from the
// running frame, then the variable's offset.
private final class OuterAddress : Node {
    import snakebite.backends.closureplan: Hop;

    private const(Hop)[] _hops;
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

// A variable in static storage, or a field of one. The address is resolved
// when the node is built; a thread-local variable's is the copy of the
// thread whose evaluator owns the tree.
private final class GlobalAddress : Node {
    private ubyte* _address;
    public this(ubyte* address) { _address = address; }
    public override ubyte* executeAddr(ubyte*) { return _address; }
}

private final class LoadGlobal(T) : Typed!T {
    private T* _address;
    public this(ubyte* address) { _address = cast(T*) address; }
    static if (isFloatingPoint!T)
        public override double executeDouble(ubyte*) { return *_address; }
    else {
        public override long executeLong(ubyte*) { return *_address; }
        mixin BoolFromLong;
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

// `baseFirst` reads the array before the index (`readsIndexAfterBase`, or a
// `$`). `dollar` stores the length in the frame slot of `$` before the index
// runs; the bounds check reads the length again after it.
private final class IndexDynamic(A, I, bool baseFirst = false,
        bool dollar = false) : Node {
    static assert(baseFirst || !dollar, "`$` needs the array first");
    private FailBounds _fail;
    private TreeRoot* _root;
    private IndexExp _expression;
    private A _array;
    private I _index;
    private size_t _stride;
    private size_t _dollar;
    public this(FailBounds fail, TreeRoot* root, IndexExp expression, A array,
            I index, size_t stride, size_t dollarOffset) {
        _fail = fail; _root = root; _expression = expression; _array = array;
        _index = index; _stride = stride; _dollar = dollarOffset;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        static if (baseFirst) {
            auto array = _array.address(frame);
            static if (dollar)
                *cast(size_t*) (frame + _dollar) = *cast(size_t*) array;
            const index = cast(size_t) _index.value(frame);
        } else {
            const index = cast(size_t) _index.value(frame);
            auto array = _array.address(frame);
        }
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

private final class IndexStatic(A, I, bool baseFirst = false) : Node {
    private FailBounds _fail;
    private TreeRoot* _root;
    private IndexExp _expression;
    private A _array;
    private I _index;
    private size_t _stride;
    private size_t _length;
    public this(FailBounds fail, TreeRoot* root, IndexExp expression,
            A array, I index, size_t stride, size_t length) {
        _fail = fail; _root = root; _expression = expression; _array = array;
        _index = index; _stride = stride; _length = length;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        static if (baseFirst) {
            auto array = _array.address(frame);
            const index = cast(size_t) _index.value(frame);
            if (index >= _length)
                fail(frame, index);
            return array + index * _stride;
        } else {
            const index = cast(size_t) _index.value(frame);
            if (index >= _length)
                fail(frame, index);
            return _array.address(frame) + index * _stride;
        }
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

// Two words that stay the same for the life of the program: a string
// literal, an aggregate's initializer image, a delegate with no context.
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

// A cast whose result is zero whatever its operand is, as a cast of
// `typeof(null)` is: the operand runs for its effect only.
private final class ZeroAfter : LongNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override long executeLong(ubyte* frame) {
        _operand.executeVoid(frame);
        return 0;
    }
}

// The same, for a result of two words: a dynamic array or a delegate.
private final class ZeroPairAfter : SliceNode {
    private Node _operand;
    public this(Node operand) { _operand = operand; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        _operand.executeVoid(frame);
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
// evaluator does. `dollar` stores the length in the frame slot of `$` before
// the bounds run.
private final class SliceOf(SliceSource source, bool dollar) : SliceNode {
    static assert(source != SliceSource.pointer || !dollar,
        "a pointer has no length for `$`");
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
    private size_t _dollar;
    public this(FailBounds fail, TreeRoot* root, SliceExp expression,
            Node base, Node lower, Node upper, size_t stride,
            size_t staticLength, in SlicePlan plan, size_t dollarOffset) {
        _fail = fail; _root = root; _expression = expression; _base = base; _lower = lower;
        _upper = upper; _stride = stride; _staticLength = staticLength;
        _checkOrder = plan.checkOrder; _checkUpper = plan.checkUpper;
        _reportsLength = plan.reportsSourceLength; _dollar = dollarOffset;
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
        static if (dollar)
            *cast(size_t*) (frame + _dollar) = length;
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

// `to[] = from[]`: the target slice runs first, then the source. The lengths
// must be equal and the two must not overlap, which the failure plan of the
// bounds check decides what to do about.
private final class SliceCopy : SliceNode {
    private FailBounds _fail;
    private TreeRoot* _root;
    private Loc _loc;
    private Node _to;
    private Node _from;
    private size_t _elementSize;
    public this(FailBounds fail, TreeRoot* root, in Loc loc, Node to,
            Node from, size_t elementSize) {
        _fail = fail; _root = root; _loc = loc; _to = to; _from = from;
        _elementSize = elementSize;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        import snakebite.backends.slicecopy: copyUnchecked, slicesConform;

        SliceValue to = void, from = void;
        _to.executeInto(frame, cast(ubyte*) &to);
        _from.executeInto(frame, cast(ubyte*) &from);
        auto target = to.pointer[0 .. to.length];
        const source = from.pointer[0 .. from.length];
        if (!slicesConform(target, source, _elementSize))
            _fail(_root, frame, BoundsCheck.sliceCopy, _loc, null);
        copyUnchecked(target, source, _elementSize);
        *cast(SliceValue*) dest = to;
    }
}

// `to[] = value` for a scalar element of type `T`: the target slice runs
// first, then `value`, once, before any element changes. Then `a[] = a[0]`
// fills with the old first element.
private final class SliceFill(T) : SliceNode {
    private Node _to;
    private Node _value;
    public this(Node to, Node value) { _to = to; _value = value; }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        SliceValue to = void;
        _to.executeInto(frame, cast(ubyte*) &to);
        static if (isFloatingPoint!T)
            const value = cast(T) _value.executeDouble(frame);
        else
            const value = cast(T) _value.executeLong(frame);
        (cast(T*) to.pointer)[0 .. to.length] = value;
        *cast(SliceValue*) dest = to;
    }
}

// `to[] = value` for an element that is a struct, a static array or a value
// of two words: the order is that of `SliceFill`, and each element gets a
// copy of the bytes of `value`.
private final class SliceFillBytes : SliceNode {
    private imported!"snakebite.framestack".FrameStack* _frames;
    private Node _to;
    private Node _value;
    private size_t _size;
    private uint _alignment;
    public this(
        imported!"snakebite.framestack".FrameStack* frames, Node to,
        Node value, in TypeFacts facts,
    ) {
        _frames = frames; _to = to; _value = value;
        _size = facts.size; _alignment = facts.alignment;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        import core.stdc.string: memcpy;

        SliceValue to = void;
        _to.executeInto(frame, cast(ubyte*) &to);
        auto storage = FrameGuard(_frames);
        auto value = _frames.reserve(_size, _alignment);
        _value.executeInto(frame, value);
        foreach (i; 0 .. to.length)
            memcpy(to.pointer + i * _size, value, _size);
        *cast(SliceValue*) dest = to;
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

// The element of a dynamic array that is not an lvalue. `dollar` stores the
// length in the frame slot of `$` before the index runs.
private final class IndexValue(bool dollar) : Node {
    private FailBounds _fail;
    private TreeRoot* _root;
    private IndexExp _expression;
    private Node _array;
    private Node _index;
    private size_t _stride;
    private size_t _dollar;
    public this(FailBounds fail, TreeRoot* root, IndexExp expression,
            Node array, Node index, size_t stride, size_t dollarOffset) {
        _fail = fail; _root = root; _expression = expression; _array = array; _index = index;
        _stride = stride; _dollar = dollarOffset;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        SliceValue value = void;
        _array.executeInto(frame, cast(ubyte*) &value);
        static if (dollar)
            *cast(size_t*) (frame + _dollar) = value.length;
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

// A value of type `T` in storage that a pointer held in a frame slot points
// to.
private struct FieldOperand(T) {
    public size_t slot;
    public size_t offset;
    public Carried!T value(ubyte* frame) {
        return *cast(T*) (*cast(ubyte**) (frame + slot) + offset);
    }
}

private struct ChildAddress {
    public Node node;
    public ubyte* address(ubyte* frame) { return node.executeAddr(frame); }
}

private struct FrameAddress {
    public size_t offset;
    public ubyte* address(ubyte* frame) { return frame + offset; }
}

// The address of storage that a pointer held in a frame slot points to,
// `offset` bytes in.
private struct PointerSlotAddress {
    public size_t slot;
    public size_t offset;
    public ubyte* address(ubyte* frame) {
        return *cast(ubyte**) (frame + slot) + offset;
    }
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
    public enum Kind : ubyte {
        child, localInt, localLong, localDouble, constant,
        fieldInt, fieldLong, fieldDouble,
        childAddress, frameAddress, pointerAddress,
    }

    public Kind kind;
    public Node node;
    // The frame slot of a local, of a frame address, or of the pointer that
    // a field or a pointer address holds.
    public size_t offset;
    public long integer;
    public double floating;
    public size_t fieldOffset;

    // The kind that reads the operand through its node.
    public Kind demoted() const {
        return kind >= Kind.childAddress ? Kind.childAddress : Kind.child;
    }

    // Reads the operand with no operand struct, for a consumer whose number of
    // operands is not known when it is compiled.
    public long readLong(ubyte* frame) {
        final switch (kind) with (Kind) {
            case localInt: return *cast(int*) (frame + offset);
            case localLong: return *cast(long*) (frame + offset);
            case constant: return integer;
            case fieldInt: return *cast(int*) fieldAt(frame);
            case fieldLong: return *cast(long*) fieldAt(frame);
            case child: return node.executeLong(frame);
            case localDouble, fieldDouble, childAddress, frameAddress,
                pointerAddress:
                assert(0);
        }
    }

    public double readDouble(ubyte* frame) {
        final switch (kind) with (Kind) {
            case localDouble: return *cast(double*) (frame + offset);
            case constant: return floating;
            case fieldDouble: return *cast(double*) fieldAt(frame);
            case child: return node.executeDouble(frame);
            case localInt, localLong, fieldInt, fieldLong, childAddress,
                frameAddress, pointerAddress:
                assert(0);
        }
    }

    public ubyte* readAddress(ubyte* frame) {
        final switch (kind) with (Kind) {
            case frameAddress: return frame + offset;
            case pointerAddress: return fieldAt(frame);
            case childAddress: return node.executeAddr(frame);
            case child, localInt, localLong, localDouble, constant,
                fieldInt, fieldLong, fieldDouble:
                assert(0);
        }
    }

    // The operand that reads `node` when it runs.
    public static Operand through(Node node) {
        return Operand(Kind.child, node);
    }

    public static Operand throughAddress(Node node) {
        return Operand(Kind.childAddress, node);
    }

    public static Operand constantLong(Node node, long value) {
        auto operand = Operand(Kind.constant, node);
        operand.integer = value;
        return operand;
    }

    public static Operand constantDouble(Node node, double value) {
        auto operand = Operand(Kind.constant, node);
        operand.floating = value;
        return operand;
    }

    public static Operand local(Kind kind, Node node, size_t offset) {
        auto operand = Operand(kind, node);
        operand.offset = offset;
        return operand;
    }

    public static Operand field(
        Kind kind, Node node, size_t slot, size_t fieldOffset,
    ) {
        auto operand = Operand(kind, node);
        operand.offset = slot;
        operand.fieldOffset = fieldOffset;
        return operand;
    }

    private ubyte* fieldAt(ubyte* frame) {
        return *cast(ubyte**) (frame + offset) + fieldOffset;
    }
}

private alias Kind = Operand.Kind;

private Operand operandOf(Node node) {
    if (auto leaf = cast(Constant!long) node)
        return Operand.constantLong(node, leaf._value);
    if (auto leaf = cast(Constant!double) node)
        return Operand.constantDouble(node, leaf._value);
    if (auto leaf = cast(Local!int) node)
        return Operand.local(Kind.localInt, node, leaf._offset);
    if (auto leaf = cast(Local!long) node)
        return Operand.local(Kind.localLong, node, leaf._offset);
    if (auto leaf = cast(Local!double) node)
        return Operand.local(Kind.localDouble, node, leaf._offset);
    if (auto leaf = cast(LoadField!int) node)
        return Operand.field(Kind.fieldInt, node, leaf._slot, leaf._offset);
    if (auto leaf = cast(LoadField!long) node)
        return Operand.field(Kind.fieldLong, node, leaf._slot, leaf._offset);
    if (auto leaf = cast(LoadField!double) node)
        return Operand.field(Kind.fieldDouble, node, leaf._slot, leaf._offset);
    return Operand.through(node);
}

private Operand addressOperandOf(Node node) {
    if (auto address = cast(LocalAddress) node)
        return Operand.local(Kind.frameAddress, node, address._offset);
    if (auto address = cast(PointerAddress) node)
        return Operand.field(Kind.pointerAddress, node, address._slot,
            address._offset);
    return Operand.throughAddress(node);
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
    else static if (kind == Kind.fieldInt)
        public alias OperandType = FieldOperand!int;
    else static if (kind == Kind.fieldLong)
        public alias OperandType = FieldOperand!long;
    else static if (kind == Kind.fieldDouble)
        public alias OperandType = FieldOperand!double;
    else static if (kind == Kind.childAddress)
        public alias OperandType = ChildAddress;
    else static if (kind == Kind.frameAddress)
        public alias OperandType = FrameAddress;
    else static if (kind == Kind.pointerAddress)
        public alias OperandType = PointerSlotAddress;
    else
        public alias OperandType = ConstantOperand!V;
}

private Op makeOperand(Op)(in Operand operand) {
    static if (is(Op == ChildOperand!V, V))
        return Op(cast() operand.node);
    else static if (is(Op == ChildAddress))
        return Op(cast() operand.node);
    else static if (is(Op == FieldOperand!T, T) || is(Op == PointerSlotAddress))
        return Op(operand.offset, operand.fieldOffset);
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

// The kinds of the operands of a test. A field is read in the test too.
private enum Kind[] testLeft = [
    Kind.child, Kind.localInt, Kind.localLong, Kind.fieldInt, Kind.fieldLong,
];
private enum Kind[] testRight = [
    Kind.child, Kind.localInt, Kind.localLong, Kind.fieldInt, Kind.fieldLong,
    Kind.constant,
];
private enum Kind[] unsignedTestLeft = [
    Kind.child, Kind.localLong, Kind.fieldLong,
];
private enum Kind[] unsignedTestRight = [
    Kind.child, Kind.localLong, Kind.fieldLong, Kind.constant,
];
private enum Kind[] doubleTestLeft = [
    Kind.child, Kind.localDouble, Kind.fieldDouble,
];
private enum Kind[] doubleTestRight = [
    Kind.child, Kind.localDouble, Kind.fieldDouble, Kind.constant,
];

// The kinds of the address that a store or an index reads its storage at.
private enum Kind[] addressKinds = [
    Kind.childAddress, Kind.frameAddress, Kind.pointerAddress,
];
private enum Kind[] indexKinds = [
    Kind.child, Kind.localInt, Kind.localLong, Kind.fieldInt, Kind.fieldLong,
];
private enum Kind[] staticIndexKinds = [
    Kind.child, Kind.localInt, Kind.localLong, Kind.fieldInt, Kind.fieldLong,
    Kind.constant,
];

// The kinds of the value that a store or a return of a `T` reads. A narrower
// integer or a `float` has the operand of a cast in front of every operand but
// a constant, which is a child.
private template valueKinds(T) {
    static if (is(T == long))
        public enum Kind[] valueKinds = [
            Kind.child, Kind.constant, Kind.localInt, Kind.localLong,
            Kind.fieldInt, Kind.fieldLong,
        ];
    else static if (is(T == int) || is(T == uint))
        public enum Kind[] valueKinds = [
            Kind.child, Kind.constant, Kind.localInt, Kind.fieldInt,
        ];
    else static if (is(T == double))
        public enum Kind[] valueKinds = [
            Kind.child, Kind.constant, Kind.localDouble, Kind.fieldDouble,
        ];
    else
        public enum Kind[] valueKinds = [Kind.child, Kind.constant];
}

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
        left.kind = left.demoted;
    if (!rights.has(right.kind))
        right.kind = right.demoted;
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

// Whether evaluating an operand can fault, which it can when it is a node or
// reads through a pointer.
private enum operandMayFault(O) = is(O == ChildOperand!(V, N), V, N)
    || is(O == FieldOperand!T, T);

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

// A value whose bytes are all zero, of `size` bytes.
private final class ZeroInto : Node {
    private size_t _size;
    public this(size_t size) { _size = size; }
    public override void executeInto(ubyte*, ubyte* dest) {
        import core.stdc.string: memset;

        memset(dest, 0, _size);
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

// A static array field whose elements all hold the one value.
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

// An object that `new` made, with the steps that initialise it run at its
// address.
private final class Initialised : LongNode {
    private Node _object;
    private Node[] _steps;
    public this(Node object, Node[] steps) { _object = object; _steps = steps; }
    public override long executeLong(ubyte* frame) {
        const object = _object.executeLong(frame);
        foreach (step; _steps)
            step.executeInto(frame, cast(ubyte*) object);
        return object;
    }
}

// An expression that runs among the steps that initialise an object.
private final class EffectStep : Node {
    private Node _effect;
    public this(Node effect) { _effect = effect; }
    public override void executeInto(ubyte* frame, ubyte*) {
        _effect.executeVoid(frame);
    }
}

// The storage that a placement `new` names. A class object there starts as
// the initial image of its class.
private final class PlacedObject : LongNode {
    private Node _place;
    private const(void)[] _image;
    public this(Node place, const(void)[] image) {
        _place = place; _image = image;
    }
    public override long executeLong(ubyte* frame) {
        import core.stdc.string: memcpy;

        auto object = _place.executeAddr(frame);
        if (_image.length != 0)
            memcpy(object, _image.ptr, _image.length);
        return cast(long) object;
    }
}

// A class object in the frame, as a `scope` class or a `new` of a `scope`
// variable's initialiser has: it lasts as long as the call does.
private final class FrameObject(E) : LongNode {
    private E _ev;
    private size_t _size;
    private uint _alignment;
    private const(void)[] _image;
    public this(E ev, size_t size, uint alignment, const(void)[] image) {
        _ev = ev; _size = size; _alignment = alignment; _image = image;
    }
    public override long executeLong(ubyte*) {
        import core.stdc.string: memcpy;

        auto object = _ev._frames.reserve(_size, _alignment);
        memcpy(object, _image.ptr, _image.length);
        return cast(long) object;
    }
}

// The hidden context field of a nested class made with an outer object: the
// object, moved to the view of the class the nested class is declared in.
private final class ContextFromValue : Node {
    private size_t _offset;
    private Node _value;
    private long _adjustment;
    public this(size_t offset, Node value, long adjustment) {
        _offset = offset; _value = value; _adjustment = adjustment;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        *cast(long*) (dest + _offset) = _value.executeLong(frame) + _adjustment;
    }
}

// The hidden context field of an aggregate made in a function: the running
// frame, or the frame of an enclosing function, reached through the static
// chain.
private final class FrameContextStore : Node {
    import snakebite.backends.closureplan: Hop;

    private size_t _offset;
    private const(Hop)[] _hops;
    public this(size_t offset, const(Hop)[] hops) {
        _offset = offset; _hops = hops;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        *cast(ubyte**) (dest + _offset) = contextAlong(frame, _hops);
    }
}

// The context that `hops` reach from `frame` along the static chain. A
// context that a hop finds null stays null.
private ubyte* contextAlong(
    ubyte* frame, const(imported!"snakebite.backends.closureplan".Hop)[] hops,
) {
    auto context = frame;
    foreach (hop; hops) {
        if (context is null)
            break;
        context = *cast(ubyte**) (context + hop.offset);
    }
    return context;
}

// The hidden context field of a nested aggregate whose context the
// evaluator finds: the context of the running call.
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

// A struct or static array rvalue whose address the parent needs: the
// receiver of a call (`a.plus(h).minus(v)`), the struct of a field that is
// read (`f().x`). Its storage lasts until the full expression ends. In a
// full expression whose temporaries the evaluator's lifetime owns
// (`Scoped`), the lifetime gives the storage, as it does to the evaluator's
// own rvalues; otherwise the frame stack does, and the statement or the
// condition that holds the node gives it back (`FrameRelease`). That node
// reserves the storage of all the rvalues of the expression before the
// expression runs, so that no frame of a call in the expression ends below
// the storage of a later rvalue: the node has a fixed `_offset` in the area.
private final class Materialise : Node {
    private ubyte** _area;
    private imported!"snakebite.backends.interpreter.temporarylifetime"
        .TemporaryLifetime* _temporaries;
    private Node _value;
    private size_t _size;
    private uint _alignment;
    private size_t _offset;
    private bool _scoped;
    public this(E)(E ev, Node value, in TypeFacts facts) {
        _area = &ev._rvalueArea; _temporaries = &ev._temporaries;
        _value = value; _size = facts.size; _alignment = facts.alignment;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        auto place = _scoped
            ? _temporaries.reserveValue(_size, _alignment)
            : *_area + _offset;
        _value.executeInto(frame, place);
        return place;
    }
}

// A statement or a condition whose full expression holds a `Materialise`
// node: it reserves the storage of the rvalues of the expression when the
// expression starts, and the frame stack goes back to its height before the
// expression when the expression ends. The area of the enclosing expression
// of a caller comes back too, since a callee runs its own expressions
// inside the expression of the caller.
private final class FrameRelease : BoolNode {
    private imported!"snakebite.framestack".FrameStack* _frames;
    private ubyte** _area;
    private Node _inner;
    private size_t _size;
    private uint _alignment = 1;
    public this(E)(E ev, Node inner, Materialise[] rvalues) {
        _frames = &ev._frames; _area = &ev._rvalueArea; _inner = inner;
        foreach (one; rvalues) {
            _size = (_size + one._alignment - 1) / one._alignment
                * one._alignment;
            one._offset = _size;
            _size += one._size;
            if (one._alignment > _alignment)
                _alignment = one._alignment;
        }
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        auto storage = Area(_frames, _area, _size, _alignment);
        return _inner.executeStmt(frame);
    }
    public override bool executeBool(ubyte* frame) {
        auto storage = Area(_frames, _area, _size, _alignment);
        return _inner.executeBool(frame);
    }
}

// The storage of the rvalues of one full expression, which ends with it.
private struct Area {
    private imported!"snakebite.framestack".FrameStack* _frames;
    private ubyte** _area;
    private ubyte* _outer;
    private imported!"snakebite.framestack".FrameStack.Mark _mark;

    @disable this();
    @disable this(this);

    public this(
        imported!"snakebite.framestack".FrameStack* frames, ubyte** area,
        in size_t size, in uint alignment,
    ) {
        _frames = frames; _area = area; _outer = *area; _mark = frames.mark;
        *area = frames.reserve(size, alignment);
    }

    ~this() {
        *_area = _outer;
        _frames.release(_mark);
    }
}

// A full expression with temporaries that the evaluator's lifetime owns: a
// temporary whose destructor runs when the expression ends, or one that a
// variable that the expression declares keeps (`Initialization`). It runs
// as the evaluator runs a full expression, with the destructors that dmd
// gives, and as the first one of a call: an expression of the caller that
// is still running does not own its temporaries.
private final class Scoped(E) : BoolNode {
    private E _ev;
    private TreeRoot* _root;
    private Node _inner;
    private Expression _expression;
    private FullExpressionScope.Position _where;
    private Position _position;
    public this(
        E ev, Node inner, Expression expression,
        in FullExpressionScope.Position where, Position position,
    ) {
        _ev = ev; _root = ev._treeRoot; _inner = inner;
        _expression = expression; _where = where; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        TreeFlow flow;
        run(frame, { flow = _inner.executeStmt(frame); });
        return flow;
    }
    public override bool executeBool(ubyte* frame) {
        bool result;
        run(frame, { result = _inner.executeBool(frame); });
        return result;
    }
    private void run(ubyte* frame, scope void delegate() evaluate) {
        auto ev = _ev;
        // A destructor runs through the evaluator, which reads the fields of
        // the running call.
        ev.handOver(_root, frame, {
            ev._temporaries.withNestedCall(false, {
                ev.withExpressionOf(frame, _where, _expression, evaluate);
            });
        });
    }
}

// A condition whose full expression ends by reading its result after the
// destructors of its temporaries ran (`readsLvalueAfterEnd`): the
// expression finds the address of the result, and the truth of the value
// there is tested after the expression ends.
private final class ScopedTruth(E) : BoolNode {
    private Scoped!E _scope;
    private imported!"snakebite.nativelayout".TypeFacts.Truth _truth;
    public this(Scoped!E scope_, Type type) {
        import snakebite.nativelayout: truthFacts;

        _scope = scope_; _truth = truthFacts(type);
    }
    public override bool executeBool(ubyte* frame) {
        import snakebite.nativelayout: isTrueAt;

        ubyte* address;
        _scope.run(frame, { address = _scope._inner.executeAddr(frame); });
        return isTrueAt(address, _truth);
    }
}

// A return statement whose full expression ends by reading its result after
// the destructors of its temporaries ran (`readsLvalueAfterEnd`): the
// expression finds the address of the result, and the value there is
// copied to the place of the result after the expression ends. A caller
// that discards the result still has the value read, because the read can
// fault.
private final class ScopedReturn(E) : Node {
    private E _ev;
    private Scoped!E _scope;
    private size_t _size;
    private uint _alignment;
    public this(E ev, Scoped!E scope_, in TypeFacts facts) {
        _ev = ev; _scope = scope_;
        _size = facts.size; _alignment = facts.alignment;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        import core.stdc.string: memcpy;

        _scope._position.note(frame);
        ubyte* address;
        _scope.run(frame, { address = _scope._inner.executeAddr(frame); });
        auto scratch = FrameGuard(&_ev._frames);
        auto place = cast(ubyte*) *placeSlotOf(frame);
        if (place is null)
            place = _ev._frames.reserve(_size, _alignment);
        if (place !is address)
            memcpy(place, address, _size);
        return TreeFlow.return_;
    }
}

// The initialisation of a variable whose lifetime the evaluator's
// temporaries decide: a temporary that dmd gives a destructor, or a
// variable that can point into the temporaries of its initialiser, whose
// storage it keeps until the call ends. `store` writes the value into the
// variable.
private final class Initialization(E) : Node {
    private E _ev;
    private VarDeclaration _variable;
    private DeclarationExp _declaration;
    private Node _address;
    private Node _store;
    private bool _retains;
    public this(
        E ev, VarDeclaration variable, DeclarationExp declaration,
        Node address, Node store, bool retains,
    ) {
        _ev = ev; _variable = variable; _declaration = declaration;
        _address = address; _store = store; _retains = retains;
    }
    public override void executeVoid(ubyte* frame) {
        auto base = _address.executeAddr(frame);
        auto temporaries = &_ev._temporaries;
        if (_retains)
            temporaries.initializeRetaining(_variable, _declaration, base, {
                _store.executeVoid(frame);
            });
        else
            temporaries.initialize(_variable, _declaration, base, {
                _store.executeVoid(frame);
            });
    }
}

// `target = value` for a struct or a static array. A construction writes
// the value at the target; an assignment writes it to storage of its own
// first, because the value can read the target (`v = v.swapped`), as
// `executeAssignment` decides for every backend. The target is resolved
// before the value runs, as `StorageResolver` does.
private final class AggregateStore : Node {
    private imported!"snakebite.framestack".FrameStack* _frames;
    private Node _target;
    private Node _value;
    private size_t _size;
    private uint _alignment;
    private bool _construction;
    public this(
        imported!"snakebite.framestack".FrameStack* frames, Node target,
        Node value, in TypeFacts facts, bool construction,
    ) {
        _frames = frames; _target = target; _value = value;
        _size = facts.size; _alignment = facts.alignment;
        _construction = construction;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        return store(frame);
    }
    public override void executeVoid(ubyte* frame) {
        store(frame);
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        import core.stdc.string: memmove;

        auto target = store(frame);
        if (target !is dest)
            memmove(dest, target, _size);
    }
    private ubyte* store(ubyte* frame) {
        import core.stdc.string: memcpy;
        import snakebite.backends.assignment: executeAssignment;

        auto target = _target.executeAddr(frame);
        auto storage = FrameGuard(_frames);
        executeAssignment!(ubyte*)(_construction, target, _size, _alignment,
            (size, alignment) => _frames.reserve(size, cast(uint) alignment),
            (value) { _value.executeInto(frame, value); },
            (value) { memcpy(target, value, _size); });
        return target;
    }
}

// A struct or static array value whose result nobody reads, which still has
// a place to be written to.
private final class DiscardedAggregate : Node {
    private imported!"snakebite.framestack".FrameStack* _frames;
    private Node _value;
    private size_t _size;
    private uint _alignment;
    public this(
        imported!"snakebite.framestack".FrameStack* frames, Node value,
        in TypeFacts facts,
    ) {
        _frames = frames; _value = value;
        _size = facts.size; _alignment = facts.alignment;
    }
    public override void executeVoid(ubyte* frame) {
        auto storage = FrameGuard(_frames);
        _value.executeInto(frame, _frames.reserve(_size, _alignment));
    }
}

// The result of a function that returns `ref` is the address of the operand.
private final class ReturnReference : Node {
    private Node _address;
    private Position _position;
    public this(Node address, Position position) {
        _address = address; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        *cast(ubyte**) *placeSlotOf(frame) = _address.executeAddr(frame);
        return TreeFlow.return_;
    }
}

private final class ReturnAggregate(E) : Node {
    private E _ev;
    private Node _value;
    private Position _position;
    private size_t _size;
    private uint _alignment;
    public this(
        E ev, Node value, Position position, in TypeFacts facts,
    ) {
        _ev = ev; _value = value; _position = position;
        _size = facts.size; _alignment = facts.alignment;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        if (auto place = *placeSlotOf(frame))
            _value.executeInto(frame, cast(ubyte*) place);
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
    public override ubyte* executeAddr(ubyte* frame) {
        _first.executeVoid(frame);
        return _second.executeAddr(frame);
    }
    public override void executeVoid(ubyte* frame) {
        _first.executeVoid(frame);
        _second.executeVoid(frame);
    }
}

// A value the evaluator makes, for a delegate whose making is not the
// tree's to decide: one with a receiver or with a pair of contexts.
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

// A delegate to a nested function or a literal: the context of the function
// it is nested in, reached from the running frame through the static chain,
// and a function word resolved when the node is built. A context that a hop
// finds null stays null: such a delegate does not capture, so its context is
// never read.
private final class FrameDelegate : SliceNode {
    import snakebite.backends.closureplan: Hop;

    private const(Hop)[] _hops;
    private void* _function;
    public this(const(Hop)[] hops, void* function_) {
        _hops = hops; _function = function_;
    }
    public override void executeInto(ubyte* frame, ubyte* dest) {
        import snakebite.nativelayout:
            delegateContextOffset, delegateFunctionOffset;

        *cast(ubyte**) (dest + delegateContextOffset)
            = contextAlong(frame, _hops);
        *cast(void**) (dest + delegateFunctionOffset) = _function;
    }
}

// The address at `start`, then for each offset the word loaded at the address
// plus that offset: the `this` of a function, read through its slot and the
// pair of a function with two contexts.
private final class LoadChain : Node {
    private Node _start;
    private const(size_t)[] _loads;
    public this(Node start, const(size_t)[] loads) {
        _start = start; _loads = loads;
    }
    public override ubyte* executeAddr(ubyte* frame) {
        auto address = _start.executeAddr(frame);
        foreach (offset; _loads)
            address = *cast(ubyte**) (address + offset);
        return address;
    }
}

// The extra arguments of a call of a guest variadic callee, in storage laid
// out as its cursor reads them (`VariadicLayout`). The call evaluates this
// node into the callee's frame, so the storage sits on the frame stack above
// that frame and the call gives both back together. The value is the address
// of the storage, which the cursor of the callee holds.
private final class VariadicExtras : LongNode {
    import snakebite.backends.interpreter.walker: VariadicCallPlan;
    import snakebite.framestack: FrameStack;

    private FrameStack* _frames;
    private const(VariadicCallPlan)* _plan;
    private Operand[] _args;
    private ArgumentWriter[] _writers;
    public this(E)(E ev, SiteArguments extras, typeof(_plan) plan) {
        _frames = &ev._frames; _plan = plan;
        _args = argumentOperands(extras.nodes, extras.modes);
        _writers = writersOf(_args, extras.modes);
    }
    public override long executeLong(ubyte* frame) {
        const layout = &_plan.layout;
        auto storage = _frames.reserve(layout.size, layout.alignment);
        layout.initialize(storage);
        foreach (i, ref arg; _args)
            _writers[i](arg, frame, storage + layout.offsets[i]);
        return cast(long) storage;
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

private final class ReturnValue(T, V) : Node {
    private V _value;
    private Position _position;
    public this(V value, Position position) {
        _value = value; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        const T value = cast(T) _value.value(frame);
        if (auto place = *placeSlotOf(frame))
            *cast(T*) place = value;
        return TreeFlow.return_;
    }

    static if (isFloatingPoint!T) {
        public override double returnDouble(ubyte* frame) {
            _position.note(frame);
            return cast(T) _value.value(frame);
        }
    } else {
        public override long returnLong(ubyte* frame) {
            _position.note(frame);
            return cast(T) _value.value(frame);
        }
    }
}

private final class ReturnSlice : Node {
    private Node _value;
    private Position _position;
    public this(Node value, Position position) {
        _value = value; _position = position;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        _position.note(frame);
        if (auto place = *placeSlotOf(frame))
            _value.executeInto(frame, cast(ubyte*) place);
        else
            _value.executeVoid(frame);
        return TreeFlow.return_;
    }
}

// A `try` statement runs through the evaluator's own `runTryCatch` and
// `runTryFinally`, so that the tree and the evaluator catch, unwind and
// run cleanups by the same rules. Its body, handlers and `finally` body are
// tree statements.
private final class Catching(E) : Node {
    private E _ev;
    private imported!"dmd.statement".TryCatchStatement _statement;
    private Node _body;
    private Node[] _handlers;
    // Where each clause's variable is in the frame, or `noVariable`.
    private size_t[] _variables;
    public enum noVariable = size_t.max;

    public this(E ev, imported!"dmd.statement".TryCatchStatement statement) {
        _ev = ev; _statement = statement;
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        return _ev.runTryCatch(_statement, () => _body.executeStmt(frame),
            (catch_, guest) => handle(frame, catch_, guest));
    }
    private TreeFlow handle(
        ubyte* frame, imported!"dmd.statement".Catch catch_, Throwable guest,
    ) {
        foreach (i, clause; *_statement.catches)
            if (clause is catch_) {
                if (_variables[i] != noVariable)
                    *cast(void**) (frame + _variables[i]) = cast(void*) guest;
                return _handlers[i].executeStmt(frame);
            }
        assert(0, "the evaluator selects a clause of the statement");
    }
}

private final class Finally(E) : Node {
    private E _ev;
    private imported!"dmd.statement".TryFinallyStatement _statement;
    private typeof(E.init.finallyPlanOf(null)) _plan;
    private TreeRoot* _root;
    private Node _body;
    private Node _finally;

    public this(E ev, imported!"dmd.statement".TryFinallyStatement statement) {
        _ev = ev; _statement = statement; _root = ev._treeRoot;
        _plan = ev.finallyPlanOf(statement);
    }
    public override TreeFlow executeStmt(ubyte* frame) {
        return _ev.runTryFinally(_statement, _plan,
            () => _body.executeStmt(frame), () => cleanup(frame));
    }
    private TreeFlow cleanup(ubyte* frame) {
        const flow = _finally.executeStmt(frame);
        // A `goto` to a label in the `finally` body: the tree cannot start
        // a body at a label.
        if (flow == TreeFlow.generic && _ev._controlFlow.hasGoto)
            return _ev.resumeCleanup(_root, frame, _statement.finalbody);
        return flow;
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
// `aggregate` is a struct or a static array, whose bytes fill the slot.
private enum Argument : ubyte {
    i8, i16, i32, i64, f32, f64, address, pair, aggregate,
}

// The arguments of a call site: the node of each one, how it is passed, and
// the bytes that it fills in its parameter slot.
private struct SiteArguments {
    import dmd.astenums: StorageClass;

    public Node[] nodes;
    public Argument[] modes;
    public size_t[] sizes;
    // How many of the arguments fill declared parameters, which come first.
    public size_t declared;

    public void append(Node node, Argument mode, size_t size) {
        nodes ~= node;
        modes ~= mode;
        sizes ~= size;
    }

    // Appends the node of `argument` for a parameter of `parameterType` with
    // `storageClass`; false when the tree does not build it.
    public bool build(E)(
        E ev, Type parameterType, StorageClass storageClass,
        Expression argument,
    ) {
        Node node;
        Argument mode;
        size_t size;
        if (!buildArgument(ev, parameterType, storageClass, argument, node,
                mode, size))
            return false;
        append(node, mode, size);
        return true;
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

// A native call that the plan shows to be zero to three word arguments in
// the first integer registers and no result or an integer result of 1, 2, 4
// or 8 bytes or of two words (16 bytes): the site calls the target with the
// words itself, and skips the plan's own work (`directWordCallTarget`). The
// context of the callee is its first word. It is decided once for each
// callee.
private struct DirectWordCall {
    public enum State : ubyte { unexamined, other, direct }

    // How a site reads the word of one argument: as it is, from its low
    // bytes extended as the plan says, as the bytes of an aggregate, or as
    // the address that a `ref` parameter or a context takes.
    public enum Read : ubyte { word, extended, aggregate, address }

    public State state;
    private const(void)* _target;
    private ubyte[3] _order;
    // How the low bytes of a parameter's word extend to 64 bits.
    private imported!"snakebite.ffi.load".Load[3] _loads;
    private size_t _resultWidth;

    // Examines the call of `callee` through `plan`. A word whose width is
    // not the load width of the plan, a result whose size is not the
    // `resultWidth` of the plan, or temporaries that the callee keeps make
    // it not one. The context and a `ref` parameter are an address.
    public void decide(
        const(imported!"snakebite.ffi.plan".CallPlan)* plan,
        in TreeCallee* callee,
    ) {
        import snakebite.ffi.load: Load, loadWidth;
        import snakebite.ffi.plan: directWordCallTarget;

        state = State.other;
        const layout = callee.layout;
        if (plan is null || layout.retainsTemporaries)
            return;
        size_t resultWidth, count;
        Load[3] loads;
        const target = directWordCallTarget(
            plan, _order, loads, resultWidth, count);
        const context = layout.hiddenThis.variable !is null ? 1 : 0;
        if (target is null || count != context + callee.slots.length
                || callee.returnFacts.size != resultWidth)
            return;
        if (context != 0 && loadWidth(loads[0]) != size_t.sizeof)
            return;
        foreach (i, parameter; callee.slots) {
            const width = parameter.isRef
                ? size_t.sizeof : parameter.facts.size;
            if (width != loadWidth(loads[context + i]))
                return;
        }
        _loads = loads;
        _target = target;
        _resultWidth = resultWidth;
        state = State.direct;
    }

    // How a site reads an argument that it passes as `mode`. The plan of a
    // direct word call has no floating or two-word parameter.
    public static Read readOf(in Argument mode) {
        import snakebite.internalfailure: internalFailure;

        final switch (mode) with (Argument) {
            case i64: return Read.word;
            case i8, i16, i32: return Read.extended;
            case aggregate: return Read.aggregate;
            case address: return Read.address;
            case f32, f64, pair:
                internalFailure("a direct word call has an argument that is "
                    ~ "not one word");
        }
    }

    // The word of parameter `parameter`, read from `arg` as `read` says.
    pragma(inline, true)
    public ulong wordOf(
        ref Operand arg, in Read read, in size_t parameter, ubyte* frame,
    ) const {
        final switch (read) with (Read) {
            case word:
                return arg.readLong(frame);
            case extended:
                return extendWord(arg.readLong(frame), _loads[parameter]);
            case aggregate:
                ulong bytes;
                arg.node.executeInto(frame, cast(ubyte*) &bytes);
                return bytes;
            case address:
                return cast(ulong) arg.readAddress(frame);
        }
    }

    // Whether the plan passes each parameter in the register of its index.
    public bool inOrder() const {
        return _order == [0, 1, 2];
    }

    // Calls the target with the words of the parameters, on the base of
    // the native stack, as every call of native code is.
    pragma(inline, true)
    public WordPair call(bool inOrder, E)(E ev, ref const ulong[3] words) const {
        if (!ev.onBaseStack)
            return callOnBase(ev, words);
        static if (inOrder) {
            const first = words[0], second = words[1], third = words[2];
        } else {
            const first = words[_order[0]], second = words[_order[1]],
                third = words[_order[2]];
        }
        try
            return callDirectWordsPair(_target, first, second, third);
        catch (Throwable thrown)
            ev.rethrowFromNative(thrown);
    }

    pragma(inline, false)
    private WordPair callOnBase(E)(E ev, ref const ulong[3] words) const {
        WordPair result;
        ev.crossNative({
            result = callDirectWordsPair(
                _target, words[_order[0]], words[_order[1]],
                words[_order[2]]);
        });
        return result;
    }
}

// The direct word call of `callee`, which `plan` runs, or null when the
// callee has none.
private const(DirectWordCall)* directWordCallOf(
    TreeCallee* callee, const(imported!"snakebite.ffi.plan".CallPlan)* plan,
) {
    auto direct = &callee.direct;
    if (direct.state == DirectWordCall.State.unexamined)
        direct.decide(plan, callee);
    return direct.state == DirectWordCall.State.direct ? direct : null;
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
    public const(DirectWordCall)* direct;
}

// What a call node does for one callee in place of a general call: the
// field access of a getter or a setter, or the run of a body that is one
// `return`, whose value comes back in a register. It belongs to the node
// and the callee together. The node makes it once; the one field that
// changes afterwards is `root`, which is found when the callee has run.
private struct FastCallee {
    public enum Kind : ubyte { getter, setter, soleReturn, plain }

    public Kind kind;
    public TreeCallee* callee;

    // The access of a getter or a setter.
    public size_t offset;
    public size_t size;
    public bool isUnsigned;
    public bool isFloating;
    public AccessSite site;
    public Argument mode;
    // For a body that is one `return`, the tree whose value comes back in
    // a register. The tree of the callee does not exist until the callee
    // has run once, so `root` is found then.
    public TreeRoot* root;

    // For a body: the bytes of the reservation, lead included, where the
    // context word goes (`size_t.max` for none), and how each argument goes
    // into its slot.
    public size_t reservation;
    public size_t contextOffset;
    public ArgumentStep[] steps;
}

// How a call evaluates one argument into its parameter slot in the frame of
// one callee.
private struct ArgumentStep {
    public ArgumentWriter write;
    public size_t offset;
    public Operand operand;
}

// What every call node does once it has chosen its callee: the fields that
// say how the site passes its arguments and takes its result, the callee's
// frame, the arguments evaluated into the parameter slots, and the run.
private mixin template CalleeEntry(E) {
    private E _ev;
    private CallExp _site;
    private Operand[] _args;
    private Argument[] _modes;
    private size_t[] _sizes;
    private size_t _resultSize;
    private bool _resultUnsigned;
    // What the callee writes at the place that the site gives it.
    private CalleeResult _result;
    private TreeRoot* _root;
    // The function whose tree holds this site: the running function again
    // when the callee returns.
    private FuncDeclaration _caller;
    private ArgumentWriter[] _writers;

    private void takeArguments(SiteArguments arguments) {
        _args = argumentOperands(arguments.nodes, arguments.modes);
        _modes = arguments.modes;
        _sizes = arguments.sizes;
        _caller = _ev._function;
        _writers = writersOf(_args, _modes);
    }

    // Whether `callee` takes the arguments of this site and gives its result.
    private bool takesArguments(in TreeCallee* callee) const {
        if (callee.slots.length != _modes.length || callee.result != _result)
            return false;
        foreach (i, parameter; callee.slots)
            if (parameter.isRef != (_modes[i] == Argument.address)
                    || parameter.facts.size != _sizes[i])
                return false;
        return _resultSize == 0 || callee.returnFacts.size == _resultSize;
    }

    private Selection selectionOf(TreeCallee* callee) {
        import snakebite.backends.calls: CallSelection;

        const decision = CallSelection.atCallSite(callee.decision, _site);
        if (decision.route != CallSelection.Route.native)
            return Selection(callee, decision.route, null);
        const plan = callee.plan !is null
            ? callee.plan : _ev._plans.of(callee.function_);
        return Selection(callee, decision.route, plan,
            directWordCallOf(callee, plan));
    }

    // Reserves the frame of `callee`, which the caller's guard gives back,
    // and evaluates the arguments of this site into it. Every run of a
    // guest or native callee at a node starts here.
    pragma(inline, true)
    private ubyte* placeArguments(
        in TreeCallee* callee, size_t hidden, ubyte* frame,
    ) {
        auto ev = _ev;
        const layout = callee.layout;
        const size = callee.frameSize;
        // A frame of small alignment has the same lead whatever it is.
        size_t lead = fastFrameLead;
        auto base = callee.reservesFast
            ? ev._frames.reserveFast(size + lead, fastFrameLead) : null;
        if (base is null) {
            lead = callee.lead;
            base = ev._frames.reserve(size + lead, cast(uint) lead);
        }
        base += lead;
        *faultSlotOf(base) = null;
        if (layout.hiddenThis.variable !is null)
            *cast(size_t*) (base + layout.hiddenThis.parameter.offset)
                = hidden;
        // `takesArguments` made the three lengths equal.
        auto parameters = callee.slots.ptr;
        auto writers = _writers.ptr;
        foreach (i, ref arg; _args)
            writers[i](arg, frame, base + parameters[i].offset);
        return base;
    }

    // Runs `callee` with `hidden` as its context word, the arguments taken
    // from the caller's `frame`.
    pragma(inline, true)
    private void enter(
        in Selection selection, size_t hidden, ubyte* frame, void* result,
    ) {
        auto ev = _ev;
        auto callee = selection.callee;
        auto calleeFrame = FrameGuard(&ev._frames);
        auto base = placeArguments(callee, hidden, frame);
        runCall(selection, base, result, /* nested */ false, frame);
    }

    // Runs `callee` as `enter` does, with the result written at `dest`. A
    // callee whose result has a slot for its place in the frame takes
    // `dest` there, as `executeRaw` gives it.
    private void enterInto(
        in Selection selection, size_t hidden, ubyte* frame, ubyte* dest,
    ) {
        auto ev = _ev;
        auto callee = selection.callee;
        auto calleeFrame = FrameGuard(&ev._frames);
        auto base = placeArguments(callee, hidden, frame);
        auto place = callee.layout.returnPlace.bind(&ev._frames, base, dest);
        // A callee whose variable aliases the place of the result arms the
        // record of the caller for that place, unless the call is nested.
        const aliased = callee.layout.returnPlace.offset != size_t.max;
        runCall(selection, base, place, aliased, frame);
    }

    // Runs the callee as a call of its own for the temporaries when the
    // caller says so (`nested`) or when a variable of the callee keeps
    // temporaries. `frame` is the frame of the caller.
    private void runCall(
        in Selection selection, ubyte* base, void* result, in bool nested,
        ubyte* frame,
    ) {
        if (nested || selection.callee.layout.retainsTemporaries)
            runRetaining(selection, base, result, frame);
        else
            run(selection, base, result, frame);
    }

    // Runs `callee` as a call of its own for the temporaries
    // (`withNestedCall`), with slots of its own when a variable of the
    // callee keeps temporaries. The closure sits in a frame of its own, so
    // the frame of `enter` carries none.
    pragma(inline, false)
    private void runRetaining(
        in Selection selection, ubyte* base, void* result, ubyte* frame,
    ) {
        _ev._temporaries.withNestedCall(
            selection.callee.layout.retainsTemporaries, {
                run(selection, base, result, frame);
            });
    }

    private void run(
        in Selection selection, ubyte* base, void* result, ubyte* frame,
    ) {
        import snakebite.backends.calls: CallSelection;

        auto callee = cast(TreeCallee*) selection.callee;
        final switch (selection.route) with (CallSelection.Route) {
            case guest:
                _ev.runTreeCallee(callee, base, result, _caller, frame);
                break;
            case native, builtin:
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

// What a direct or virtual call node does to choose its callee: the
// receiver, which is the context word of the callee, the callee of the last
// vtable that the site met, and the original path for a call that the tree
// does not run. The node has `chose`, which `meet` calls with the callee
// that a new vtable gives.
private mixin template Dispatch(E) {
    private FuncDeclaration _method;
    private Operand _receiver;
    private bool _hasReceiver;
    private bool _virtual;
    private bool _receiverIsAddress;
    private Selection _selected;
    private const(void)* _vtable;

    private void takeReceiver(
        FuncDeclaration method, Node receiver, bool receiverIsAddress,
        bool virtual,
    ) {
        _method = method;
        _hasReceiver = receiver !is null;
        if (_hasReceiver)
            _receiver = receiverIsAddress
                ? addressOperandOf(receiver) : operandOf(receiver);
        _receiverIsAddress = receiverIsAddress; _virtual = virtual;
    }

    public final bool matches(TreeCallee* callee) {
        if (_virtual && callee.decision.route != _selected.route)
            return false;
        // The receiver is the context word, and only a callee with one takes it.
        if (_hasReceiver != (callee.layout.hiddenThis.variable !is null))
            return false;
        return takesArguments(callee);
    }

    // Runs the receiver, which is the word the callee takes as its context.
    pragma(inline, true)
    private size_t runReceiver(ubyte* frame) {
        if (!_hasReceiver)
            return 0;
        return _receiverIsAddress
            ? cast(size_t) _receiver.readAddress(frame)
            : cast(size_t) _receiver.readLong(frame);
    }

    // A virtual site met a vtable that it has no callee for: false when
    // the original path must run the call.
    pragma(inline, false)
    private bool meet(
        const(void)* vtable, size_t receiver, ref Selection selected,
    ) {
        auto callee = _ev.virtualTreeCalleeOf(_method, cast(void*) receiver);
        if (callee is null || !matches(callee))
            return false;
        selected = selectionOf(callee);
        _selected = selected;
        chose(callee, selected);
        _vtable = vtable;
        return true;
    }

    pragma(inline, false)
    private void originalPath(ubyte* frame, void* result, size_t receiver) {
        auto ev = _ev;
        ev.handOver(_root, frame, {
            ev._executeMethodCall(_site, result, _method, cast(void*) receiver);
        });
    }

    // The callee of this run once the receiver ran, in `_selected`. False
    // when the original path must run the call.
    pragma(inline, true)
    private bool resolve(size_t receiver) {
        if (!_virtual)
            return true;
        if (receiver == 0)
            return false;
        const vtable = *cast(const(void)**) receiver;
        if (vtable is _vtable)
            return true;
        auto selected = _selected;
        return meet(vtable, receiver, selected);
    }

    // The node that runs this site when it is not virtual and its callee is
    // a direct word call, null otherwise. It reads each word from its
    // operand, the receiver first, and gives the callee no frame.
    public final Node nativeWordCall() {
        import snakebite.internalfailure: internalFailure;

        auto direct = _selected.direct;
        if (_virtual || direct is null)
            return null;
        switch (_hasReceiver + _args.length) {
            case 0: return nativeWordCallOf!0(direct);
            case 1: return nativeWordCallOf!1(direct);
            case 2: return nativeWordCallOf!2(direct);
            case 3: return nativeWordCallOf!3(direct);
            default:
                internalFailure("a direct word call has more than three "
                    ~ "words");
        }
    }

    private Node nativeWordCallOf(size_t count)(
        const(DirectWordCall)* direct,
    ) {
        Operand[count] operands;
        DirectWordCall.Read[count] reads;
        static if (count > 0) {
            const first = _hasReceiver ? 1 : 0;
            if (_hasReceiver) {
                operands[0] = _receiver;
                reads[0] = readOfReceiver;
            }
            foreach (i, mode; _modes) {
                operands[first + i] = _args[i];
                reads[first + i] = DirectWordCall.readOf(mode);
            }
        }
        if (direct.inOrder)
            return new NativeWordCall!(E, count, true)(
                _ev, direct, operands, reads, _resultSize, _resultUnsigned);
        return new NativeWordCall!(E, count, false)(
            _ev, direct, operands, reads, _resultSize, _resultUnsigned);
    }

    private DirectWordCall.Read readOfReceiver() const {
        return _receiverIsAddress
            ? DirectWordCall.Read.address : DirectWordCall.Read.word;
    }

    // Runs the direct word call of the callee with `receiver`, which ran
    // already, as its first word when the site has one.
    private void runDirect(
        const(DirectWordCall)* direct, size_t receiver, ubyte* frame,
    ) {
        ulong[3] words = 0;
        const first = _hasReceiver ? 1 : 0;
        words[0] = receiver;
        foreach (i, ref arg; _args)
            words[first + i] = direct.wordOf(
                arg, DirectWordCall.readOf(_modes[i]), first + i, frame);
        direct.call!false(_ev, words);
    }
}

// A direct or virtual call with scalar, `ref`, dynamic array, delegate,
// struct or static array parameters, and a scalar, dynamic array or no
// result. The callee is a guest function, a native function or a builtin.
// It pushes the callee frame, evaluates each argument into its parameter
// slot, and runs the callee: a guest callee's node tree, or the native call
// through its plan.
private final class Call(E) : Node {
    mixin CalleeEntry!E;
    mixin Dispatch!E;

    // The fast form of each callee this site has met, null for none.
    private FastCallee*[TreeCallee*] _fasts;
    // The fast form of the callee in `_selected`. The two change together,
    // with no code between that could run this site again.
    private FastCallee* _fast;

    public this(E ev, CallExp site, FuncDeclaration method, Node receiver,
            bool receiverIsAddress, bool virtual, SiteArguments arguments,
            size_t resultSize, bool resultUnsigned) {
        _ev = ev; _site = site;
        takeReceiver(method, receiver, receiverIsAddress, virtual);
        takeArguments(arguments);
        _resultSize = resultSize;
        _resultUnsigned = resultUnsigned;
        _root = ev._treeRoot;
    }

    public final void bind(TreeCallee* callee) {
        _selected = selectionOf(callee);
        _fast = fastFormOf(callee, _selected);
    }

    private void chose(TreeCallee* callee, in Selection selected) {
        _fast = fastFormOf(callee, selected);
    }

    // The node that does the work of this site when its one callee is an
    // accessor, null otherwise. It stands in for this node in the tree, so
    // an access pays for no choice of callee: this node only runs the call
    // for a null receiver.
    public final Node accessor() {
        auto fast = _fast;
        if (_virtual || fast is null)
            return null;
        final switch (fast.kind) with (FastCallee.Kind) {
            case getter:
                return byScalarOf!makeGetter(fast, this);
            case setter:
                return byScalarOf!makeSetter(fast, this);
            case soleReturn, plain:
                return null;
        }
    }

    // The fast form of `callee` at this site, which the site makes once.
    private FastCallee* fastFormOf(TreeCallee* callee, in Selection selected) {
        FastCallee* fast;
        if (auto found = callee in _fasts) {
            fast = *found;
        } else {
            fast = fastOf(callee, selected);
            _fasts[callee] = fast;
        }
        return fast;
    }

    // How this site runs `callee` in place of a general call, or null.
    private FastCallee* fastOf(TreeCallee* callee, in Selection selected) {
        import snakebite.backends.calls: CallSelection;

        if (selected.route != CallSelection.Route.guest)
            return null;
        auto ev = _ev;
        if (callee.shape.kind == CalleeShape.Kind.unexamined)
            examine(ev, callee);
        const shape = callee.shape;
        auto fast = new FastCallee;
        fast.callee = callee;
        final switch (shape.kind) with (CalleeShape.Kind) {
            case unexamined:
                assert(0, "examine leaves no callee unexamined");
            case other:
                return bodyOf(fast, callee, BodyKind.plain);
            case getter, setter:
                fast.kind = shape.kind == getter
                    ? FastCallee.Kind.getter : FastCallee.Kind.setter;
                fast.offset = shape.offset;
                fast.size = shape.size;
                fast.isUnsigned = shape.isUnsigned;
                fast.isFloating = shape.isFloating;
                fast.site = AccessSite(callee.function_, shape.position);
                if (_modes.length != 0)
                    fast.mode = _modes[0];
                return fast;
            case soleReturn:
                return bodyOf(fast, callee, BodyKind.soleReturn);
        }
    }

    // A callee with the plain kind of frame runs with its arguments in the
    // slots of `fast`. When it is only a `return` with a result that fits a
    // register, the value can come back in a register.
    private FastCallee* bodyOf(
        FastCallee* fast, TreeCallee* callee, BodyKind bodyKind,
    ) {
        if (!callee.reservesFast || callee.layout.retainsTemporaries)
            return null;
        fast.kind = bodyKind == BodyKind.soleReturn && _resultSize != 0
                && _resultSize <= size_t.sizeof
            ? FastCallee.Kind.soleReturn : FastCallee.Kind.plain;
        fast.reservation = callee.frameSize + fastFrameLead;
        const hiddenThis = callee.layout.hiddenThis;
        fast.contextOffset = hiddenThis.variable is null
            ? size_t.max : hiddenThis.parameter.offset;
        // `takesArguments` made the three lengths equal.
        fast.steps = new ArgumentStep[_args.length];
        foreach (i, ref step; fast.steps)
            step = ArgumentStep(_writers[i], callee.slots[i].offset, _args[i]);
        return fast;
    }

    private enum BodyKind : bool { plain, soleReturn }

    // The general call once `resolve` has run: the callee in `_selected`, or
    // the original path when `resolve` found none.
    pragma(inline, true)
    private void finishCall(
        bool resolved, size_t receiver, ubyte* frame, void* result,
    ) {
        if (!resolved) {
            originalPath(frame, result, receiver);
            return;
        }
        // A copy: the arguments can run this site again and select another
        // callee.
        auto selected = _selected;
        enter(selected, receiver, frame, result);
    }

    // The forms of a call: the fast form of the callee when it has one,
    // the general call otherwise. Nothing between the choice of the callee
    // and its run evaluates user code except the arguments, which only read
    // `fast` and `callee`. A getter whose receiver is null, a setter in a
    // form that has no store, and a sole return whose tree has not run yet
    // take the general call or the run of the body.
    public override long executeLong(ubyte* frame) {
        const receiver = runReceiver(frame);
        const resolved = resolve(receiver);
        auto fast = _fast;
        if (resolved && fast !is null) {
            final switch (fast.kind) with (FastCallee.Kind) {
                case getter:
                    if (receiver != 0)
                        return loadLong(fast, receiver);
                    break;
                case setter:
                    break;
                case soleReturn:
                    if (returnsInRegister(fast))
                        return enterLong(fast, receiver, frame);
                    goto case plain;
                case plain:
                    return runLong(fast, receiver, frame);
            }
        }
        return generalLong(resolved, receiver, frame);
    }

    public override double executeDouble(ubyte* frame) {
        const receiver = runReceiver(frame);
        const resolved = resolve(receiver);
        auto fast = _fast;
        if (resolved && fast !is null) {
            final switch (fast.kind) with (FastCallee.Kind) {
                case getter:
                    if (receiver != 0)
                        return loadDouble(fast, receiver);
                    break;
                case setter:
                    break;
                case soleReturn:
                    if (returnsInRegister(fast))
                        return enterDouble(fast, receiver, frame);
                    goto case plain;
                case plain:
                    return runDouble(fast, receiver, frame);
            }
        }
        return generalDouble(resolved, receiver, frame);
    }

    public override void executeVoid(ubyte* frame) {
        const receiver = runReceiver(frame);
        const resolved = resolve(receiver);
        auto fast = _fast;
        if (resolved && fast !is null) {
            final switch (fast.kind) with (FastCallee.Kind) {
                case getter:
                    break;
                case setter:
                    if (receiver != 0) {
                        store(fast, receiver, frame);
                        return;
                    }
                    break;
                case soleReturn, plain:
                    runVoid(fast, receiver, frame);
                    return;
            }
        }
        generalVoid(resolved, receiver, frame);
    }

    public override void executeInto(ubyte* frame, ubyte* dest) {
        const receiver = runReceiver(frame);
        SliceValue buffer = void;
        const resolved = resolve(receiver);
        auto fast = _fast;
        if (resolved && fast !is null) {
            final switch (fast.kind) with (FastCallee.Kind) {
                case getter, setter:
                    break;
                case soleReturn, plain:
                    runPlain(fast, receiver, frame, &buffer);
                    *cast(SliceValue*) dest = buffer;
                    return;
            }
        }
        finishCall(resolved, receiver, frame, &buffer);
        *cast(SliceValue*) dest = buffer;
    }

    pragma(inline, false)
    private double generalDouble(bool resolved, size_t receiver, ubyte* frame) {
        ulong[2] buffer;
        finishCall(resolved, receiver, frame, buffer.ptr);
        return floatingResult(buffer);
    }

    pragma(inline, false)
    private void generalVoid(bool resolved, size_t receiver, ubyte* frame) {
        ulong[2] buffer;
        finishCall(resolved, receiver, frame, buffer.ptr);
    }

    pragma(inline, false)
    private long generalLong(bool resolved, size_t receiver, ubyte* frame) {
        ulong[2] buffer;
        finishCall(resolved, receiver, frame, buffer.ptr);
        return extendResult(buffer[0], _resultSize, _resultUnsigned);
    }

    // The access of a getter: one load at the receiver plus the offset of
    // the field. A null receiver never comes here: the callee runs it and
    // reports the fault in the callee, so the access itself cannot fault.
    private long loadLong(FastCallee* fast, size_t receiver) {
        const place = receiver + fast.offset;
        auto site = &fast.site;
        switch (fast.size) {
            case 1:
                return fast.isUnsigned
                    ? cast(long) loadField!ubyte(_ev, site, place)
                    : cast(long) loadField!byte(_ev, site, place);
            case 2:
                return fast.isUnsigned
                    ? cast(long) loadField!ushort(_ev, site, place)
                    : cast(long) loadField!short(_ev, site, place);
            case 4:
                return fast.isUnsigned
                    ? cast(long) loadField!uint(_ev, site, place)
                    : cast(long) loadField!int(_ev, site, place);
            default:
                return loadField!long(_ev, site, place);
        }
    }

    private double loadDouble(FastCallee* fast, size_t receiver) {
        const place = receiver + fast.offset;
        return fast.size == 4
            ? loadField!float(_ev, &fast.site, place)
            : loadField!double(_ev, &fast.site, place);
    }

    // The access of a setter: the argument runs after the receiver, then
    // one store at the receiver plus the offset of the field.
    private void store(FastCallee* fast, size_t receiver, ubyte* frame) {
        ulong bits;
        final switch (fast.mode) with (Argument) {
            case i8, i16, i32, i64:
                bits = _args[0].readLong(frame);
                break;
            case f32: {
                const value = cast(float) _args[0].readDouble(frame);
                bits = *cast(const(uint)*) &value;
                break;
            }
            case f64: {
                const value = _args[0].readDouble(frame);
                bits = *cast(const(ulong)*) &value;
                break;
            }
            case address, pair, aggregate:
                assert(0, "a setter takes a scalar by value");
        }
        const place = receiver + fast.offset;
        auto site = &fast.site;
        switch (fast.size) {
            case 1:
                storeField!ubyte(_ev, site, place, cast(ubyte) bits);
                break;
            case 2:
                storeField!ushort(_ev, site, place, cast(ushort) bits);
                break;
            case 4:
                storeField!uint(_ev, site, place, cast(uint) bits);
                break;
            default:
                storeField!ulong(_ev, site, place, bits);
                break;
        }
    }

    // Whether the tree of the callee has its return statement: the callee
    // has run once.
    private bool returnsInRegister(FastCallee* fast) {
        if (fast.root is null) {
            auto root = fast.callee.root;
            if (root is null || !root.hasSoleReturn)
                return false;
            fast.root = root;
        }
        return true;
    }

    // Runs a callee that the register form does not cover: the frame, the
    // arguments, and the callee's tree, with the result in `result`. No
    // selection is copied and no route is chosen.
    pragma(inline, true)
    private void runPlain(
        FastCallee* fast, size_t receiver, ubyte* frame, void* result,
    ) {
        auto ev = _ev;
        auto calleeFrame = FrameGuard(&ev._frames);
        auto base = placeFast(fast, receiver, frame);
        ev.runTreeCallee(fast.callee, base, result, _caller, frame);
    }

    // Reserves the frame of the callee of `fast` and evaluates the
    // arguments of this site into it, as `placeArguments` does, with the
    // steps that `fast` holds.
    pragma(inline, true)
    private ubyte* placeFast(FastCallee* fast, size_t receiver, ubyte* frame) {
        static assert(fastFrameLead == 16);
        auto base = _ev._frames.reserveAligned16(fast.reservation)
            + fastFrameLead;
        *faultSlotOf(base) = null;
        if (fast.contextOffset != size_t.max)
            *cast(size_t*) (base + fast.contextOffset) = receiver;
        foreach (ref step; fast.steps)
            step.write(step.operand, frame, base + step.offset);
        return base;
    }

    pragma(inline, true)
    private long runLong(FastCallee* fast, size_t receiver, ubyte* frame) {
        ulong[2] buffer = void;
        runPlain(fast, receiver, frame, buffer.ptr);
        return extendResult(buffer[0], _resultSize, _resultUnsigned);
    }

    pragma(inline, true)
    private double runDouble(FastCallee* fast, size_t receiver, ubyte* frame) {
        ulong[2] buffer = void;
        runPlain(fast, receiver, frame, buffer.ptr);
        return floatingResult(buffer);
    }

    pragma(inline, true)
    private void runVoid(FastCallee* fast, size_t receiver, ubyte* frame) {
        ulong[2] buffer = void;
        runPlain(fast, receiver, frame, buffer.ptr);
    }

    pragma(inline, true)
    private long enterLong(FastCallee* fast, size_t receiver, ubyte* frame) {
        auto ev = _ev;
        auto calleeFrame = FrameGuard(&ev._frames);
        auto base = placeFast(fast, receiver, frame);
        return ev.runTreeValue!long(
            fast.root, fast.callee.function_, base, _caller, frame);
    }

    pragma(inline, true)
    private double enterDouble(FastCallee* fast, size_t receiver, ubyte* frame) {
        auto ev = _ev;
        auto calleeFrame = FrameGuard(&ev._frames);
        auto base = placeFast(fast, receiver, frame);
        return ev.runTreeValue!double(
            fast.root, fast.callee.function_, base, _caller, frame);
    }
}

// A non-virtual call of a native function that is a direct word call, with
// `count` words: the receiver, when the call has one, and the arguments. The
// words go to the target in the order of the registers, with no copy into a
// callee frame. `inOrder` says that the plan passes each parameter in the
// register of its index.
private final class NativeWordCall(E, size_t count, bool inOrder) : Node {
    private E _ev;
    private const(DirectWordCall)* _direct;
    private Operand[count] _operands;
    private DirectWordCall.Read[count] _reads;
    private size_t _resultSize;
    private bool _resultUnsigned;

    public this(
        E ev, const(DirectWordCall)* direct, Operand[count] operands,
        DirectWordCall.Read[count] reads, size_t resultSize,
        bool resultUnsigned,
    ) {
        _ev = ev; _direct = direct; _operands = operands; _reads = reads;
        _resultSize = resultSize; _resultUnsigned = resultUnsigned;
    }

    pragma(inline, true)
    private WordPair invoke(ubyte* frame) {
        ulong[3] words = 0;
        static foreach (i; 0 .. count)
            words[i] = _direct.wordOf(_operands[i], _reads[i], i, frame);
        return _direct.call!inOrder(_ev, words);
    }

    public override long executeLong(ubyte* frame) {
        return extendResult(invoke(frame).low, _resultSize, _resultUnsigned);
    }

    // The result of a function that returns `ref`.
    public override ubyte* executeAddr(ubyte* frame) {
        return cast(ubyte*) invoke(frame).low;
    }

    public override void executeVoid(ubyte* frame) {
        invoke(frame);
    }

    public override void executeInto(ubyte* frame, ubyte* dest) {
        storeWordResult(invoke(frame), _resultSize, dest);
    }
}

// A direct or virtual call whose result is a struct or a static array. The
// callee writes the result at the place that the parent gives it
// (`executeInto`); the call has no form that gives a value in a register.
private final class AggregateCall(E) : Node {
    mixin CalleeEntry!E;
    mixin Dispatch!E;

    private uint _alignment;

    public this(E ev, CallExp site, FuncDeclaration method, Node receiver,
            bool receiverIsAddress, bool virtual, SiteArguments arguments,
            in TypeFacts result) {
        _ev = ev; _site = site;
        takeReceiver(method, receiver, receiverIsAddress, virtual);
        takeArguments(arguments);
        _resultSize = result.size; _alignment = result.alignment;
        _result = CalleeResult.aggregate;
        _root = ev._treeRoot;
    }

    public final void bind(TreeCallee* callee) {
        _selected = selectionOf(callee);
    }

    private void chose(TreeCallee*, in Selection) {}

    public override void executeInto(ubyte* frame, ubyte* dest) {
        const receiver = runReceiver(frame);
        if (!resolve(receiver)) {
            originalPath(frame, dest, receiver);
            return;
        }
        // A copy: the arguments can run this site again and select another
        // callee.
        auto selected = _selected;
        enterInto(selected, receiver, frame, dest);
    }

    // A discarded result still has a place, as compiled D gives it one.
    public override void executeVoid(ubyte* frame) {
        auto scratch = FrameGuard(&_ev._frames);
        executeInto(frame, _ev._frames.reserve(_resultSize, _alignment));
    }
}

// A direct or virtual call of a function that returns `ref`. The callee
// writes the address of its result, which the node yields (`executeAddr`);
// a parent that needs the value reads it there.
private final class ReferenceCall(E) : Node {
    mixin CalleeEntry!E;
    mixin Dispatch!E;

    public this(E ev, CallExp site, FuncDeclaration method, Node receiver,
            bool receiverIsAddress, bool virtual, SiteArguments arguments) {
        _ev = ev; _site = site;
        takeReceiver(method, receiver, receiverIsAddress, virtual);
        takeArguments(arguments);
        _resultSize = size_t.sizeof;
        _result = CalleeResult.reference;
        _root = ev._treeRoot;
    }

    public final void bind(TreeCallee* callee) {
        _selected = selectionOf(callee);
    }

    private void chose(TreeCallee*, in Selection) {}

    public override ubyte* executeAddr(ubyte* frame) {
        const receiver = runReceiver(frame);
        if (!resolve(receiver))
            return originalAddress(frame, receiver);
        // A copy: the arguments can run this site again and select another
        // callee.
        auto selected = _selected;
        ubyte* address;
        enter(selected, receiver, frame, &address);
        return address;
    }

    public override void executeVoid(ubyte* frame) {
        executeAddr(frame);
    }

    // The original path, which gives the address of the result.
    pragma(inline, false)
    private ubyte* originalAddress(ubyte* frame, size_t receiver) {
        auto ev = _ev;
        ubyte* address;
        ev.handOver(_root, frame, {
            address = cast(ubyte*) ev._executeMethodCall(
                _site, null, _method, cast(void*) receiver).address;
        });
        return address;
    }
}

// The call of a constructor: on a struct lvalue (`field.this(args)`), on
// the struct literal of `S(args)`, on a class object (`super.this(args)`),
// or on the allocation of `new`. It yields its receiver, the object that it
// constructed: the address of a struct (`executeAddr`), or the class
// reference or the pointer that `new` gives (`executeLong`). As every
// constructor call does (`constructTemporary`), it suspends the destructor
// of a temporary that it constructs until the constructor returns.
//
// A record of the temporaries names a struct temporary, which a constructor
// reaches only through the address of its receiver. A callee that the
// interpreter runs is a call of its own for the temporaries, so that a
// constructor that it calls on the same storage (another constructor of the
// struct, the constructor of a field at offset 0) does not take over the
// record of this one. On the direct native path the callee makes no
// temporaries, and a callback into guest code opens its own nested call. A
// class object and the allocation of `new` are never a temporary, so their
// callee is a call of its own only when a variable of it keeps temporaries.
private final class ConstructorCall(E) : Node {
    mixin CalleeEntry!E;
    mixin Dispatch!E;

    public this(E ev, CallExp site, FuncDeclaration constructor,
            Node receiver, bool receiverIsAddress, SiteArguments arguments) {
        import snakebite.frontend.dmd.functions: typeFunctionOf;

        _ev = ev; _site = site;
        takeReceiver(constructor, receiver, receiverIsAddress,
            /* virtual */ false);
        takeArguments(arguments);
        // A struct constructor returns `ref this`, a class constructor
        // `this`.
        _result = typeFunctionOf(constructor).isRef
            ? CalleeResult.reference : CalleeResult.value;
        _root = ev._treeRoot;
    }

    public final void bind(TreeCallee* callee) {
        _selected = selectionOf(callee);
    }

    private void chose(TreeCallee*, in Selection) {}

    public override long executeLong(ubyte* frame) {
        return construct(frame);
    }

    public override ubyte* executeAddr(ubyte* frame) {
        return cast(ubyte*) construct(frame);
    }

    public override void executeVoid(ubyte* frame) {
        construct(frame);
    }

    // Runs the constructor and returns its receiver.
    private size_t construct(ubyte* frame) {
        import snakebite.backends.temporary: constructTemporary;

        auto ev = _ev;
        const receiver = runReceiver(frame);
        auto object = cast(void*) receiver;
        // A copy: the arguments can run this site again.
        auto selected = _selected;
        constructTemporary(_method,
            { ev._temporaries.suspendConstructor(object); },
            {
                if (selected.direct !is null) {
                    runDirect(selected.direct, receiver, frame);
                    return;
                }
                // The callee writes its receiver, which is the result.
                ulong[2] result = void;
                auto calleeFrame = FrameGuard(&ev._frames);
                auto base = placeArguments(selected.callee, receiver, frame);
                runCall(selected, base, result.ptr, _receiverIsAddress, frame);
            },
            { ev._temporaries.armConstructor(object); });
        return receiver;
    }
}

// Calls `make!T(call, offset)` for the type `T` of the field of an accessor.
private Node byScalarOf(alias make, E)(FastCallee* fast, Call!E call) {
    if (fast.isFloating)
        return fast.size == 4
            ? make!float(call, fast.offset, &fast.site)
            : make!double(call, fast.offset, &fast.site);
    TypeFacts facts;
    facts.size = fast.size;
    facts.isUnsigned = fast.isUnsigned;
    return byIntegral!make(facts, call, fast.offset, &fast.site);
}

private Node makeGetter(T, E)(Call!E call, size_t offset, AccessSite* site) {
    return call._receiverIsAddress
        ? new Getter!(E, T, true)(call, offset, site)
        : new Getter!(E, T, false)(call, offset, site);
}

private Node makeSetter(T, E)(Call!E call, size_t offset, AccessSite* site) {
    return call._receiverIsAddress
        ? new Setter!(E, T, true)(call, offset, site)
        : new Setter!(E, T, false)(call, offset, site);
}

// The load or the store of an accessor, with the evaluator told which
// accessor runs: the access is the one instruction that can fault, and the
// fault is the accessor's.
private T loadField(T, E)(E ev, AccessSite* site, size_t place) {
    import core.atomic: MemoryOrder, atomicStore;

    atomicStore!(MemoryOrder.raw)(ev._access, site);
    const value = *cast(const(T)*) place;
    atomicStore!(MemoryOrder.raw)(ev._access, null);
    return value;
}

private void storeField(T, E)(E ev, AccessSite* site, size_t place, T value) {
    import core.atomic: MemoryOrder, atomicStore;

    atomicStore!(MemoryOrder.raw)(ev._access, site);
    *cast(T*) place = value;
    atomicStore!(MemoryOrder.raw)(ev._access, null);
}

// The call of a getter at a site that has one callee, as one load at the
// receiver plus the offset of the field. A null receiver takes the general
// call, which reports the fault in the callee.
private final class Getter(E, T, bool receiverIsAddress) : Typed!T {
    private E _ev;
    private Call!E _call;
    private Operand _receiver;
    private size_t _offset;
    private AccessSite* _site;

    // The node stands in for a non-virtual site, which always has its callee.
    private enum nonVirtual = true;

    public this(Call!E call, size_t offset, AccessSite* site) {
        _ev = call._ev; _call = call; _receiver = call._receiver;
        _offset = offset; _site = site;
    }

    static if (isFloatingPoint!T) {
        public override double executeDouble(ubyte* frame) {
            const receiver = receiverOn(frame);
            if (receiver == 0)
                return _call.generalDouble(nonVirtual, receiver, frame);
            return loadField!T(_ev, _site, receiver + _offset);
        }
    } else {
        public override long executeLong(ubyte* frame) {
            const receiver = receiverOn(frame);
            if (receiver == 0)
                return _call.generalLong(nonVirtual, receiver, frame);
            return loadField!T(_ev, _site, receiver + _offset);
        }
    }

    private size_t receiverOn(ubyte* frame) {
        static if (receiverIsAddress)
            return cast(size_t) _receiver.readAddress(frame);
        else
            return cast(size_t) _receiver.readLong(frame);
    }
}

// The call of a setter at a site that has one callee: the receiver runs,
// then the argument, then one store of the width of the field. A null
// receiver takes the general call before the argument runs, which runs it
// once there.
private final class Setter(E, T, bool receiverIsAddress) : Node {
    private E _ev;
    private Call!E _call;
    private Operand _receiver;
    private Operand _argument;
    private size_t _offset;
    private AccessSite* _site;

    // The node stands in for a non-virtual site, which always has its callee.
    private enum nonVirtual = true;

    public this(Call!E call, size_t offset, AccessSite* site) {
        _ev = call._ev; _call = call; _receiver = call._receiver;
        _argument = call._args[0]; _offset = offset; _site = site;
    }

    public override void executeVoid(ubyte* frame) {
        static if (receiverIsAddress)
            const receiver = cast(size_t) _receiver.readAddress(frame);
        else
            const receiver = cast(size_t) _receiver.readLong(frame);
        if (receiver == 0) {
            _call.generalVoid(nonVirtual, receiver, frame);
            return;
        }
        static if (isFloatingPoint!T)
            const value = cast(T) _argument.readDouble(frame);
        else
            const value = cast(T) _argument.readLong(frame);
        storeField!T(_ev, _site, receiver + _offset, value);
    }
}

// Finds what the body of `callee` is, once, the first time a call node binds
// it. A getter or a setter is only recognised when the accessor reads or
// writes its field as the tree would, with no check of the receiver.
private void examine(E)(E ev, TreeCallee* callee) {
    import dmd.astenums: STC, TY;
    import dmd.expression: ThisExp;
    import dmd.tokens: EXP;
    import dmd.typesem: nextOf, toBasetype;

    callee.shape.kind = CalleeShape.Kind.other;
    auto function_ = callee.function_;
    auto statements = statementsOf(function_.fbody);
    if (statements.length != 1)
        return;
    auto only = statements[0];
    // The field of `this` that `expression` names, or null.
    VarDeclaration receiverField(Expression expression) {
        auto dot = expression.isDotVarExp;
        if (dot is null)
            return null;
        auto receiver = dot.e1.isThisExp;
        if (receiver is null
                || receiver.var !is null && receiver.var !is function_.vthis)
            return null;
        const kind = dot.e1.type.toBasetype.ty;
        auto field = dot.var.isVarDeclaration;
        if (kind != TY.Tclass && kind != TY.Tstruct || field is null
                || field.isBitFieldDeclaration !is null || field.isDataseg)
            return null;
        return field;
    }
    if (auto returned = only.isReturnStatement) {
        if (returned.exp is null || returned.fesFunc !is null
                || returned.caseDim != 0)
            return;
        callee.shape.kind = CalleeShape.Kind.soleReturn;
        static if (!E.nullCheckedEvaluator) {
            // The access of a getter runs no arguments.
            auto field = receiverField(returned.exp);
            if (field is null || callee.slots.length != 0)
                return;
            const scalar = scalarOf(ev, field.type);
            const result = scalarOf(ev, function_.type.nextOf);
            if (scalar.kind == Scalar.Kind.none || scalar.kind != result.kind
                    || scalar.facts.size != result.facts.size
                    || scalar.facts.isUnsigned != result.facts.isUnsigned)
                return;
            callee.shape = CalleeShape(CalleeShape.Kind.getter, field.offset,
                scalar.facts.size, scalar.facts.isUnsigned,
                scalar.kind == Scalar.Kind.floating,
                cast(const(void)*) returned.exp);
        }
        return;
    }
    static if (!E.nullCheckedEvaluator) {
        auto effect = only.isExpStatement;
        if (effect is null || effect.exp is null
                || effect.exp.op != EXP.assign
                || function_.type.nextOf.toBasetype.ty != TY.Tvoid
                || function_.parameters is null
                || function_.parameters.length != 1
                || callee.slots.length != 1 || callee.slots[0].isRef)
            return;
        auto assignment = effect.exp.isAssignExp;
        auto field = receiverField(assignment.e1);
        auto written = assignment.e2.isVarExp;
        auto parameter = (*function_.parameters)[0];
        if (field is null || written is null || written.var !is parameter
                || (parameter.storage_class & (STC.lazy_ | STC.out_)) != 0)
            return;
        const scalar = scalarOf(ev, field.type);
        const given = scalarOf(ev, parameter.type);
        if (scalar.kind == Scalar.Kind.none || scalar.kind != given.kind
                || scalar.facts.size != given.facts.size
                || scalar.facts.size != callee.slots[0].facts.size)
            return;
        callee.shape = CalleeShape(CalleeShape.Kind.setter, field.offset,
            scalar.facts.size, scalar.facts.isUnsigned,
            scalar.kind == Scalar.Kind.floating,
            cast(const(void)*) effect.exp);
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
// `result` is what the callee writes: a value of at most two words, a
// struct or a static array at the place that the parent gives
// (`executeInto`), or the address of the result of a function that returns
// `ref`, which the node yields (`executeAddr`).
private final class IndirectCall(E, CalleeResult result) : Node {
    mixin CalleeEntry!E;

    private Node _target;
    private bool _viaDelegate;
    private size_t _declared;
    // The function that this site last called, and its callee when the tree
    // runs it.
    private FuncDeclaration _function;
    private Selection _selected;
    static if (result == CalleeResult.aggregate)
        private uint _alignment;

    public this(E ev, CallExp site, Node target, bool viaDelegate,
            SiteArguments arguments, in TypeFacts facts,
            bool resultUnsigned) {
        _ev = ev; _site = site; _target = target; _viaDelegate = viaDelegate;
        takeArguments(arguments);
        _declared = arguments.declared;
        _resultSize = facts.size;
        _resultUnsigned = resultUnsigned;
        static if (result == CalleeResult.aggregate)
            _alignment = facts.alignment;
        _result = result;
        _root = ev._treeRoot;
    }

    private void invoke(ubyte* frame, void* place) {
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
            ev.handOver(_root, frame, {
                // The original path gives the address of a `ref` result
                // apart from the place.
                static if (result == CalleeResult.reference)
                    *cast(void**) place = ev._executeCallThroughValue(_site,
                        null, cast(void*) target.function_,
                        cast(void*) target.context, _viaDelegate).address;
                else
                    ev._executeCallThroughValue(_site, place,
                        cast(void*) target.function_,
                        cast(void*) target.context, _viaDelegate);
            });
            return;
        }
        static if (result == CalleeResult.aggregate)
            enterInto(selected, target.context + adjustment, frame,
                cast(ubyte*) place);
        else
            enter(selected, target.context + adjustment, frame, place);
    }

    // The callee for `function_` that this tree runs, null when it runs
    // none.
    private Selection selectionFor(FuncDeclaration function_) {
        auto definition = _ev._callSelection.definitionOf(
            function_, (declaration) => _ev._program.linkedFunctionOf(declaration));
        auto callee = _ev.treeCalleeOf(definition);
        // The slots of a variadic shape are not declared parameters, so a
        // callee and a site agree on which slots are declared.
        if (callee is null || callee.declared != _declared
                || !takesArguments(callee))
            return Selection.init;
        return selectionOf(callee);
    }

    static if (result == CalleeResult.aggregate) {
        public override void executeInto(ubyte* frame, ubyte* dest) {
            invoke(frame, dest);
        }

        // A discarded result still has a place, as compiled D gives it one.
        public override void executeVoid(ubyte* frame) {
            auto scratch = FrameGuard(&_ev._frames);
            invoke(frame, _ev._frames.reserve(_resultSize, _alignment));
        }
    } else static if (result == CalleeResult.reference) {
        public override ubyte* executeAddr(ubyte* frame) {
            ubyte* address;
            invoke(frame, &address);
            return address;
        }

        public override void executeVoid(ubyte* frame) {
            executeAddr(frame);
        }
    } else {
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
}

// The operands that evaluate `args` into parameter slots as `modes` say.
private Operand[] argumentOperands(Node[] args, Argument[] modes) {
    auto operands = new Operand[args.length];
    foreach (i, arg; args)
        final switch (modes[i]) with (Argument) {
            case address:
                operands[i] = addressOperandOf(arg);
                break;
            case pair, aggregate:
                operands[i] = Operand.through(arg);
                break;
            case i8, i16, i32, i64, f32, f64:
                operands[i] = operandOf(arg);
                break;
        }
    return operands;
}

// Evaluates an argument into its parameter slot at `place`. Each argument
// of a site has its own, chosen once by how the argument is passed and how
// its operand reads.
private alias ArgumentWriter = void function(
    ref Operand argument, ubyte* frame, ubyte* place);

private ArgumentWriter[] writersOf(in Operand[] args, in Argument[] modes) {
    auto writers = new ArgumentWriter[args.length];
    foreach (i, ref arg; args)
        writers[i] = writerOf(modes[i], arg.kind);
    return writers;
}

private ArgumentWriter writerOf(in Argument mode, in Kind kind) {
    import std.traits: EnumMembers;

    final switch (mode) {
        static foreach (m; EnumMembers!Argument) {
            case m:
                final switch (kind) {
                    static foreach (k; EnumMembers!Kind) {
                        case k:
                            static if (has(argumentKinds!m, k))
                                return &writeArgument!(m, k);
                            else
                                assert(0, "argumentOperands gives no "
                                    ~ "operand of this kind for this mode");
                    }
                }
        }
    }
}

// The operand kinds that `argumentOperands` gives for an argument passed as
// `mode`.
private template argumentKinds(Argument mode) {
    static if (mode == Argument.address)
        public enum Kind[] argumentKinds = addressKinds;
    else static if (mode == Argument.pair || mode == Argument.aggregate)
        public enum Kind[] argumentKinds = onlyChild;
    else static if (mode == Argument.f32 || mode == Argument.f64)
        public enum Kind[] argumentKinds = valueKinds!double;
    else
        public enum Kind[] argumentKinds = valueKinds!long;
}

private void writeArgument(Argument mode, Kind kind)(
    ref Operand argument, ubyte* frame, ubyte* place,
) {
    with (Argument) {
        static if (mode == pair || mode == aggregate)
            argument.node.executeInto(frame, place);
        else static if (mode == address)
            *cast(ubyte**) place = makeOperand!(OperandType!(kind, long))(
                argument).address(frame);
        else {
            static if (mode == i8)
                alias T = ubyte;
            else static if (mode == i16)
                alias T = ushort;
            else static if (mode == i32)
                alias T = uint;
            else static if (mode == i64)
                alias T = ulong;
            else static if (mode == f32)
                alias T = float;
            else
                alias T = double;
            static if (isFloatingPoint!T)
                alias V = double;
            else
                alias V = long;
            *cast(T*) place = cast(T) makeOperand!(OperandType!(kind, V))(
                argument).value(frame);
        }
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
    private Operand[] _args;
    private ArgumentWriter[] _writers;
    private size_t _resultSize;
    private bool _resultUnsigned;

    public this(
        typeof(_entry) entry, SiteArguments arguments,
        size_t resultSize, bool resultUnsigned,
    ) {
        _entry = entry;
        _args = argumentOperands(arguments.nodes, arguments.modes);
        _writers = writersOf(_args, arguments.modes);
        _resultSize = resultSize; _resultUnsigned = resultUnsigned;
    }

    private void invoke(ubyte* frame, void* result) {
        ulong[maxArguments] values;
        const(void)*[maxArguments] pointers;
        foreach (i, ref arg; _args) {
            // `buildIntrinsicCall` takes only value arguments.
            auto place = cast(ubyte*) &values[i];
            _writers[i](arg, frame, place);
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

    // `BuiltinOp` gives a value; a builtin that returns `ref` gives an
    // address.
    if (function_.fbody !is null || function_.isThis !is null
            || call.e1.isCommaExp !is null
            || typeFunctionOf(function_).isRef)
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
    SiteArguments arguments;
    if (!buildArguments(ev, typeFunctionOf(function_), call.arguments, arguments))
        return null;
    foreach (mode; arguments.modes)
        if (mode == Argument.address || mode == Argument.pair
                || mode == Argument.aggregate)
            return null;
    return new BuiltinOp(decision.builtinEntry, arguments,
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
        // `typeof(null)` is a word whose only value is zero.
        case Tpointer, Tclass, Tnull:
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

// The address of a variable that is not in the running frame: one in static
// storage, or one of an enclosing function. Null when the tree does not
// reach it.
private Node buildNonFrameAddress(E)(E ev, VarDeclaration variable) {
    import snakebite.frontend.dmd.delegates: isCtfeVariable;

    // `__ctfe` has no parent, and asking dmd where it lives reports that as
    // an error.
    if (variable !is null && !isCtfeVariable(variable) && variable.isDataseg)
        return new GlobalAddress(ev.staticAddressOf(variable));
    return buildOuterAddress(ev, variable);
}

private Node buildVariableAddress(E)(E ev, VarDeclaration variable) {
    const slot = slotOf(ev, variable);
    if (!slot.ok)
        return buildNonFrameAddress(ev, variable);
    return slot.indirect
        ? new PointerAddress(slot.offset, 0)
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
            return new PointerAddress(slot.offset, 0);
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
                        : pointerTarget(pointer, field.offset);
                }
            }
            auto base = buildAddress(ev, dot.e1);
            return base is null ? null : fieldOfAddress(base, field.offset);
        }
        case star: {
            static if (E.nullCheckedEvaluator)
                return null;
            else {
                auto pointer = buildValue(ev, expression.isPtrExp.e1);
                return pointer is null ? null : pointerTarget(pointer, 0);
            }
        }
        case index:
            return buildIndexAddress(ev, expression.isIndexExp);
        case question:
            return buildConditional!(buildAddress!E, ConditionalAddress)(
                ev, expression.isCondExp);
        case comma: {
            auto comma = expression.isCommaExp;
            auto first = buildEffect(ev, comma.e1);
            auto second = buildAddress(ev, comma.e2);
            return first is null || second is null
                ? null : new Comma(first, second);
        }
        case call: {
            // A call that returns `ref` gives an address of its own.
            auto call = expression.isCallExp;
            if (returnsReference(call))
                return buildCall(ev, call);
            if (!isAggregate(expression.type))
                return null;
            return materialise(ev, buildCall(ev, call), expression.type);
        }
        case structLiteral:
            return materialise(ev,
                buildStructLiteral(ev, expression.isStructLiteralExp),
                expression.type);
        case assign, construct, blit:
            // The assignment gives the address of its target.
            return isAggregate(expression.type)
                ? buildAggregateStore(ev, cast(AssignExp) expression) : null;
        default:
            return null;
    }
}

// The address of the rvalue that `value` writes, for the full expression
// that the builder builds.
private Node materialise(E)(E ev, Node value, Type type) {
    return value is null ? null : materialiseFacts(ev, value, ev.factsOf(type));
}

private Node materialiseFacts(E)(E ev, Node value, in TypeFacts facts) {
    import snakebite.internalfailure: internalFailure;

    auto region = ev._treeRoot._region;
    if (region is null)
        internalFailure("an rvalue needs an address outside a full expression");
    auto node = new Materialise(ev, value, facts);
    region.materialised ~= node;
    return node;
}

// Whether `call` returns `ref`, so that its node gives the address of the
// result (`executeAddr`), as a struct constructor does.
private bool returnsReference(CallExp call) {
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    auto type = typeFunctionOf(call);
    return type !is null && type.isRef;
}

private Node buildIndexAddress(E)(E ev, IndexExp indexed) {
    import dmd.astenums: TY;
    import snakebite.frontend.storage: readsIndexAfterBase;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: nextOf, toBasetype;

    auto element = ev.factsOf(indexed.e1.type.toBasetype.nextOf);
    auto position = buildValue(ev, indexed.e2);
    if (position is null)
        return null;
    const dollar = dollarSlot(ev, indexed.lengthVar);
    switch (indexed.e1.type.toBasetype.ty) with (TY) {
        case Tarray: {
            auto array = buildAddress(ev, indexed.e1);
            if (array is null) {
                auto value = buildSlice(ev, indexed.e1);
                if (value is null)
                    return null;
                if (dollar.ok)
                    return new IndexValue!true(&ev.failTreeBounds,
                        ev._treeRoot, indexed, value, position, element.size,
                        dollar.offset);
                return new IndexValue!false(&ev.failTreeBounds, ev._treeRoot,
                    indexed, value, position, element.size, noDollar);
            }
            return indexOfArray(ev, indexed, array, position, element.size,
                dollar);
        }
        // dmd folds the `$` of a static array into its length.
        case Tsarray: {
            assert(!dollar.ok, "the `$` of a static array is a constant");
            auto array = buildAddress(ev, indexed.e1);
            if (array is null)
                return null;
            const length = cast(size_t) indexed.e1.type.toBasetype
                .isTypeSArray.dim.toInteger;
            // An array that is read first has calls or effects, so its
            // address is a node.
            if (readsIndexAfterBase(indexed))
                return fuse!(MakeIndex!(IndexStatic, true).make, long,
                    [Kind.childAddress], staticIndexKinds)(
                    Operand.throughAddress(array), operandOf(position),
                    &ev.failTreeBounds, ev._treeRoot, indexed, element.size,
                    length);
            return fuse!(MakeIndex!(IndexStatic, false).make, long,
                addressKinds, staticIndexKinds)(
                addressOperandOf(array), operandOf(position),
                &ev.failTreeBounds, ev._treeRoot, indexed, element.size,
                length);
        }
        case Tpointer: {
            assert(indexed.lengthVar is null, "a pointer has no `$`");
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

// The factory of an index node for `fuse`.
private template MakeIndex(alias Index, Flags...) {
    public Node make(A, I, Args...)(A array, I index, Args args) {
        return new Index!(A, I, Flags)(args[0], args[1], args[2], array,
            index, args[3 .. $]);
    }
}

// The `$` offset of a node that stores no `$`: the node never reads it.
private enum size_t noDollar = 0;

// The frame slot of the `$` of an index or a slice (`LocalsCollector`). It is
// not `ok` when there is no `$`, or when dmd folds `$` into a constant.
private Slot dollarSlot(E)(E ev, VarDeclaration dollar) {
    const slot = slotOf(ev, dollar);
    assert(!slot.ok || !slot.indirect, "`$` is a value local");
    return slot;
}

// The array of an index with `$` is read first, as the shared storage
// resolver does.
private Node indexOfArray(E)(E ev, IndexExp indexed, Node array,
        Node position, size_t stride, in Slot dollar) {
    import snakebite.frontend.storage: readsIndexAfterBase;

    if (dollar.ok)
        return fuse!(MakeIndex!(IndexDynamic, true, true).make, long,
            [Kind.childAddress], indexKinds)(
            Operand.throughAddress(array), operandOf(position),
            &ev.failTreeBounds, ev._treeRoot, indexed, stride, dollar.offset);
    // An array that is read first has calls or effects, so its address is
    // a node.
    if (indexed.lengthVar !is null || readsIndexAfterBase(indexed))
        return fuse!(MakeIndex!(IndexDynamic, true).make, long,
            [Kind.childAddress], indexKinds)(
            Operand.throughAddress(array), operandOf(position),
            &ev.failTreeBounds, ev._treeRoot, indexed, stride, noDollar);
    return fuse!(MakeIndex!(IndexDynamic, false).make, long, addressKinds,
        indexKinds)(
        addressOperandOf(array), operandOf(position), &ev.failTreeBounds,
        ev._treeRoot, indexed, stride, noDollar);
}

// The address of a field of the storage at `base`, the address of the field
// of the pointer or object that `pointer` yields, and the storage that it
// points to (`offset` 0). An address that is a frame slot, or a pointer held
// in one, plus a constant, is one node.
private Node fieldOfAddress(Node base, size_t offset) {
    if (auto frame = cast(LocalAddress) base)
        return new LocalAddress(frame._offset + offset);
    if (auto indirect = cast(PointerAddress) base)
        return new PointerAddress(indirect._slot, indirect._offset + offset);
    if (auto global = cast(GlobalAddress) base)
        return new GlobalAddress(global._address + offset);
    return new FieldOfAddress(base, offset);
}

private Node pointerTarget(Node pointer, size_t offset) {
    if (auto local = cast(Local!long) pointer)
        return new PointerAddress(local._offset, offset);
    return offset == 0
        ? new Dereference(pointer) : new FieldOfPointer(pointer, offset);
}

// The node that reads a `scalar` at `address`.
private Node loadOf(Node address, in Scalar scalar) {
    static Node at(T)(Node address) {
        if (auto frame = cast(LocalAddress) address)
            return new Local!T(frame._offset);
        if (auto indirect = cast(PointerAddress) address)
            return new LoadField!T(indirect._slot, indirect._offset);
        if (auto global = cast(GlobalAddress) address)
            return new LoadGlobal!T(global._address);
        return new Load!T(address);
    }
    if (scalar.kind == Scalar.Kind.floating)
        return byFloating!at(scalar.facts, address);
    return byIntegral!at(scalar.facts, address);
}

private Node loadSlice(Node address) {
    if (auto frame = cast(LocalAddress) address)
        return new LocalSlice(frame._offset);
    return new LoadSlice(address);
}

private enum wordScalar = Scalar(
    Scalar.Kind.integral, TypeFacts(size_t.sizeof, size_t.sizeof, true, true));

private Node buildLoad(E)(E ev, Expression expression, Node address) {
    const scalar = scalarOf(ev, expression.type);
    if (address is null || scalar.kind == Scalar.Kind.none)
        return null;
    return loadOf(address, scalar);
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
    auto type = typeFunctionOf(function_);

    // A function that returns `ref` gives an address, whatever the type of
    // its result; a constructor gives its receiver.
    const isConstructor = function_.isCtorDeclaration !is null;
    const resultIsAddress = type.isRef || isConstructor;
    const isVoid = call.type.toBasetype.ty == TY.Tvoid;
    const resultIsSlice = isSlice(call.type);
    const resultIsAggregate = isAggregate(call.type);
    const result = resultIsAddress || isVoid || resultIsSlice
            || resultIsAggregate
        ? Scalar() : scalarOf(ev, call.type);
    if (!resultIsAddress && !isVoid && !resultIsSlice && !resultIsAggregate
            && result.kind == Scalar.Kind.none)
        return null;

    // The receiver of a member function, which is its hidden argument.
    Node receiver;
    bool receiverIsAddress, virtual;
    if (function_.isThis !is null) {
        auto found = receiverOf(call, function_);
        final switch (found.kind) with (CallReceiver.Kind) {
            case classValue:
                receiver = buildValue(ev, found.expression);
                virtual = call.readsVtable(function_);
                break;
            case aggregateAddress:
                receiver = buildAddress(ev, found.expression);
                receiverIsAddress = true;
                break;
            case implicitThis:
                receiver = buildThisValue(ev, ev._function.vthis);
                receiverIsAddress = true;
                break;
            case enclosing:
                assert(0, "a member function has a receiver");
        }
        if (receiver is null)
            return null;
    }

    // A virtual call meets its callee when it runs.
    TreeCallee* callee;
    if (!virtual) {
        callee = ev.treeCalleeAt(function_, call, call.arguments);
        if (callee is null)
            return null;
        // The hidden argument of a nested function is the context of the
        // function that it is nested in.
        if (function_.isThis is null
                && callee.layout.hiddenThis.variable !is null) {
            receiver = buildCalleeContext(ev, call, function_);
            receiverIsAddress = true;
            if (receiver is null)
                return null;
        }
    }
    SiteArguments arguments;
    // A virtual call meets only guest callees (`Dispatch.matches`).
    if (!buildArguments(ev, type, call.arguments, arguments,
            callee is null ? Extras.packed : extrasFor(callee)))
        return null;

    if (isConstructor)
        return bound(callee, new ConstructorCall!E(ev, call, function_,
            receiver, receiverIsAddress, arguments));
    if (type.isRef) {
        auto node = new ReferenceCall!E(ev, call, function_, receiver,
            receiverIsAddress, virtual, arguments);
        if (virtual)
            return node;
        if (bound(callee, node) is null)
            return null;
        if (auto native = node.nativeWordCall)
            return native;
        return node;
    }
    if (resultIsAggregate) {
        auto node = new AggregateCall!E(ev, call, function_, receiver,
            receiverIsAddress, virtual, arguments, ev.factsOf(call.type));
        return virtual ? node : bound(callee, node);
    }
    auto node = new Call!E(ev, call, function_, receiver, receiverIsAddress,
        virtual, arguments,
        isVoid ? 0 : resultIsSlice ? SliceValue.sizeof : result.facts.size,
        result.facts.isUnsigned);
    if (!virtual) {
        if (!node.matches(callee))
            return null;
        node.bind(callee);
        if (auto accessor = node.accessor)
            return accessor;
        if (auto native = node.nativeWordCall)
            return native;
    }
    return node;
}

// `node`, a call that is not virtual, bound to `callee`; null when the tree
// does not run the callee at this site.
private Node bound(N)(TreeCallee* callee, N node) {
    if (!node.matches(callee))
        return null;
    node.bind(callee);
    return node;
}

// The `this` of the function whose hidden `this` is `variable`, as the
// evaluator reads it (`thisValueOf`): the address of a struct or the class
// reference, which the node yields as an address. A function with two
// contexts reaches it through its pair.
private Node buildThisValue(E)(E ev, VarDeclaration variable) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.backends.closureplan: ClosurePlan;
    import snakebite.frontend.dmd.delegates: outerFunctionOf;

    auto slot = buildVariableAddress(ev, variable);
    if (slot is null)
        return null;
    auto owner = outerFunctionOf(variable);
    const hops = owner is null ? null : ClosurePlan.receiverHops(owner);
    if (hops.length == 0)
        return variable.type.toBasetype.ty == TY.Tclass
            ? new LoadChain(slot, [0]) : slot;
    size_t[] loads = [0];
    foreach (hop; hops)
        loads ~= hop.offset;
    return new LoadChain(slot, loads);
}

// The context that a call of the nested function `callee` hands over, as
// the evaluator finds it (`contextValueOf`), which the node yields as an
// address. Null when the tree does not reach it.
private Node buildCalleeContext(E)(E ev, CallExp call, FuncDeclaration callee) {
    import snakebite.backends.dualcontext: ContextSource;
    import snakebite.internalfailure: internalFailure;

    const source = *ev.calleeContextPlanOf(call, callee);
    final switch (source.kind) with (ContextSource.Kind) {
        case none:
            return new GlobalAddress(null);
        case frame: {
            auto owner = cast() source.function_;
            // A function that runs as a tree has no closure (`runNodeTree`),
            // so its own context is its frame.
            if (owner is ev._function)
                return new LocalAddress(0);
            const hops = ev.staticChainTo(owner);
            if (hops is null)
                internalFailure("a direct call's enclosing function is on "
                    ~ "the static chain");
            return new OuterAddress(OuterVariable(true, hops, 0, false));
        }
        case receiver:
            assert(0, "a nested callee's context is the frame of a function "
                ~ "(`nestedContextOwnerOf`)");
        case overrider: {
            // The word that holds the receiver in the view of the overridden
            // function's class lives as long as the full expression of the
            // call, and the context is the address that finds it at
            // `slotOffset`.
            auto receiver = buildThisValue(ev, ev._function.vthis);
            if (receiver is null)
                return null;
            auto word = materialiseFacts(ev,
                new FieldStore!size_t(0, new AddressValue(
                    fieldOfAddress(receiver, source.receiverAdjustment))),
                TypeFacts.pointer);
            return fieldOfAddress(word, -source.slotOffset);
        }
    }
}

// A call through a function pointer or a delegate: null when the value of
// the callee is outside what the tree reads.
private Node buildIndirectCall(E)(E ev, CallExp call) {
    import dmd.astenums: TY;
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
    if (target is null || type is null)
        return null;

    if (type.isRef) {
        SiteArguments arguments;
        if (!buildArguments(ev, type, call.arguments, arguments))
            return null;
        return new IndirectCall!(E, CalleeResult.reference)(ev, call, target,
            viaDelegate, arguments, TypeFacts.pointer,
            /* resultUnsigned */ true);
    }
    const isVoid = call.type.toBasetype.ty == TY.Tvoid;
    const resultIsSlice = isSlice(call.type);
    const resultIsAggregate = isAggregate(call.type);
    const result = isVoid || resultIsSlice || resultIsAggregate
        ? Scalar() : scalarOf(ev, call.type);
    if (!isVoid && !resultIsSlice && !resultIsAggregate
            && result.kind == Scalar.Kind.none)
        return null;

    SiteArguments arguments;
    if (!buildArguments(ev, type, call.arguments, arguments))
        return null;
    if (resultIsAggregate)
        return new IndirectCall!(E, CalleeResult.aggregate)(ev, call, target,
            viaDelegate, arguments, ev.factsOf(call.type),
            /* resultUnsigned */ false);
    TypeFacts facts;
    facts.size = isVoid ? 0 : resultIsSlice ? SliceValue.sizeof : result.facts.size;
    return new IndirectCall!(E, CalleeResult.value)(ev, call, target,
        viaDelegate, arguments, facts, result.facts.isUnsigned);
}

// How a variadic call passes its extra arguments: in storage whose address
// is the cursor of a guest callee (`VariadicExtras`), or each in a slot of
// its own for a callee that host code runs.
private enum Extras : ubyte { packed, separate }

// How a call of `callee` passes its extra arguments.
private Extras extrasFor(in TreeCallee* callee) {
    import snakebite.backends.calls: CallSelection;

    return callee.decision.route == CallSelection.Route.guest
        ? Extras.packed : Extras.separate;
}

// The nodes of the arguments of a call of `type`, in the order of the slots
// that the callee takes them in (`TreeCallee.slots`), and how each one is
// passed. False when one is outside the supported kinds.
private bool buildArguments(E)(
    E ev, imported!"dmd.mtype".TypeFunction type,
    imported!"dmd.arraytypes".Expressions* arguments, out SiteArguments site,
    in Extras extras = Extras.packed,
) {
    import dmd.astenums: VarArg;
    import snakebite.ffi: CallAdapter;
    import snakebite.internalfailure: internalFailure;

    auto parameters = type.parameterList;
    const variadic = parameters.varargs == VarArg.variadic;
    // dmd gives a D variadic call the `TypeInfo` tuple of its extra
    // arguments as its first argument.
    const typesIndex = type.isDstyleVariadic ? 0 : size_t.max;
    const firstDeclared = typesIndex == 0 ? 1 : 0;
    const firstExtra = firstDeclared + parameters.length;
    // A call of a K&R function type can pass more arguments than the type
    // declares: the original call path runs it.
    if (parameters.varargs == VarArg.KRvariadic)
        return false;
    if (variadic ? arguments.length < firstExtra
            : arguments.length != parameters.length)
        internalFailure("dmd checks the arity of a call");

    if (variadic && extras == Extras.separate && typesIndex == 0) {
        auto hidden = CallAdapter.Arguments.of(type, arguments).hiddenArgument;
        auto tuple = buildValue(ev, hidden.expression);
        if (tuple is null)
            return false;
        if (hidden.readsField)
            site.append(new LoadSlice(
                    new FieldOfPointer(tuple, hidden.fieldOffset)),
                Argument.pair, hidden.fieldFacts.size);
        else
            site.append(tuple, Argument.i64, size_t.sizeof);
    }
    foreach (i; 0 .. parameters.length) {
        auto parameter = parameters[i];
        if (!site.build(ev, parameter.type, parameter.storageClass,
                (*arguments)[firstDeclared + i]))
            return false;
    }
    site.declared = parameters.length;
    if (!variadic)
        return true;

    final switch (extras) with (Extras) {
        case packed: {
            SiteArguments packed;
            foreach (extra; (*arguments)[firstExtra .. $])
                if (!packed.build(ev, extra.type, 0, extra))
                    return false;
            site.append(new VariadicExtras(ev, packed,
                    ev.variadicCallPlanOf(arguments, firstExtra)),
                Argument.i64, size_t.sizeof);
            if (typesIndex == 0) {
                auto tuple = buildValue(ev, (*arguments)[typesIndex]);
                if (tuple is null)
                    return false;
                site.append(tuple, Argument.i64, size_t.sizeof);
            }
            return true;
        }
        case separate:
            foreach (extra; (*arguments)[firstExtra .. $])
                if (!site.build(ev, extra.type, 0, extra))
                    return false;
            return true;
    }
}

// The node of `argument` for a parameter of `parameterType` with
// `storageClass`, and how it is passed. False when it is outside the
// supported kinds.
private bool buildArgument(E)(
    E ev, Type parameterType, imported!"dmd.astenums".StorageClass storageClass,
    Expression argument, out Node node, out Argument mode, out size_t size,
) {
    import dmd.astenums: STC;

    if ((storageClass & STC.lazy_) != 0)
        return false;
    if ((storageClass & (STC.ref_ | STC.out_)) != 0) {
        mode = Argument.address;
        size = size_t.sizeof;
        node = buildAddress(ev, argument);
    } else if (isSlice(parameterType)) {
        if (!isSlice(argument.type))
            return false;
        mode = Argument.pair;
        size = SliceValue.sizeof;
        node = buildSlice(ev, argument);
    } else if (isDelegate(parameterType)) {
        if (!isDelegate(argument.type))
            return false;
        mode = Argument.pair;
        size = SliceValue.sizeof;
        node = buildDelegate(ev, argument);
    } else if (isAggregate(parameterType)) {
        size = ev.factsOf(parameterType).size;
        if (!isAggregate(argument.type) || ev.factsOf(argument.type).size != size)
            return false;
        mode = Argument.aggregate;
        node = buildAggregate(ev, argument);
    } else {
        const declared = scalarOf(ev, parameterType);
        const given = scalarOf(ev, argument.type);
        if (declared.kind == Scalar.Kind.none
                || given.kind != declared.kind
                || given.facts.size != declared.facts.size)
            return false;
        if (declared.kind == Scalar.Kind.floating)
            mode = declared.facts.size == 4 ? Argument.f32 : Argument.f64;
        else switch (declared.facts.size) {
            case 1: mode = Argument.i8; break;
            case 2: mode = Argument.i16; break;
            case 4: mode = Argument.i32; break;
            case 8: mode = Argument.i64; break;
            default: assert(0, "an integral scalar is 1, 2, 4 or 8 bytes");
        }
        size = declared.facts.size;
        node = buildValue(ev, argument);
    }
    return node !is null;
}

package bool isDelegate(Type type) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;

    return type !is null && type.toBasetype.ty == TY.Tdelegate;
}

// The node that yields the delegate `expression` as two words, or null when
// the tree does not cover the expression.
private Node buildDelegate(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;

    if (!isDelegate(expression.type))
        return null;
    switch (expression.op) with (EXP) {
        case variable: {
            auto declaration = expression.isVarExp.var.isVarDeclaration;
            const slot = slotOf(ev, declaration);
            if (!slot.ok) {
                auto outer = buildNonFrameAddress(ev, declaration);
                return outer is null ? null : new LoadSlice(outer);
            }
            return slot.indirect
                ? new LoadSlice(new PointerAddress(slot.offset, 0))
                : new LocalSlice(slot.offset);
        }
        case dotVariable, star, index: {
            auto address = buildAddress(ev, expression);
            return address is null ? null : loadSlice(address);
        }
        case call: {
            // The value of a `ref` result, read at its address.
            auto call = expression.isCallExp;
            if (!returnsReference(call))
                return null;
            auto address = buildCall(ev, call);
            return address is null ? null : loadSlice(address);
        }
        case null_:
            return new NullSlice;
        case assign, construct, blit:
            return buildPairStore(ev, cast(AssignExp) expression);
        case function_: {
            import snakebite.frontend.dmd.delegates: delegateTargetOf;

            return buildMadeDelegate(ev, expression, delegateTargetOf(
                expression.isFuncExp.fd, expression.type));
        }
        case delegate_: {
            import snakebite.frontend.dmd.delegates: delegateTargetOf;

            auto made = expression.isDelegateExp;
            return buildMadeDelegate(ev, expression, delegateTargetOf(
                made.func, expression.type, made.e1, made.vthis2));
        }
        case question:
            return buildConditional!(buildDelegate!E, ConditionalInto)(
                ev, expression.isCondExp);
        case cast_:
            return buildDelegateCast(ev, expression.isCastExp);
        default:
            return null;
    }
}

// A cast to a delegate: of another delegate, which keeps both words, or of
// `typeof(null)`.
private Node buildDelegateCast(E)(E ev, CastExp castExp) {
    import snakebite.internalfailure: internalFailure;
    import snakebite.nativevalue: CastKind;

    if (castExp.lowering !is null)
        return buildDelegate(ev, castExp.lowering);
    const plan = *ev._shared.facts.castOf(castExp);
    final switch (plan.kind) with (CastKind) {
        case copy:
            return buildDelegate(ev, castExp.e1);
        case zero:
            return buildZeroPair(ev, castExp.e1);
        case classReference:
        case integralToFloat:
        case floatToIntegral:
        case floatToPointer:
        case pointerToFloat:
        case floatWidth:
        case complexToReal:
        case complexToImaginary:
        case complexToIntegral:
        case complexWidth:
        case realToComplex:
        case integralToComplex:
        case imaginaryToComplex:
        case sarrayToSlice:
        case sarrayToPointer:
        case sliceToPointer:
        case pointerToArray:
        case pointerToIntegral:
        case delegateToPointer:
        case reinterpretSlice:
        case narrow:
        case widenSigned:
        case widenUnsigned:
        case truth:
            internalFailure("a cast to a delegate copies a delegate or is of `null`");
    }
}

// A delegate literal or `&nested`: the context of the function that the
// target is nested in, as the evaluator's `storeDelegateValue` finds it, and
// the target's function word. A delegate with a receiver or with a pair of
// contexts is made by the evaluator.
private Node buildMadeDelegate(E)(
    E ev, Expression expression,
    imported!"snakebite.frontend.dmd.delegates".DelegateTarget target,
) {
    import snakebite.frontend.dmd.delegates: isDualContext;
    import snakebite.internalfailure: internalFailure;

    if (target.function_ is null)
        internalFailure("a delegate expression names a function and has a "
            ~ "delegate type");
    if (target.receiver !is null || isDualContext(target.function_))
        return new EvaluatedPair!E(ev, expression);
    auto function_ = ev.functionAddressOf(target.function_);
    if (!target.needsContext)
        return constantDelegate(function_);
    // A function that runs as a tree has no closure (`runNodeTree`), so its
    // own context is its frame: no hops.
    if (target.contextOwner is ev._function)
        return new FrameDelegate(/* hops */ null, function_);
    const hops = ev.staticChainTo(target.contextOwner);
    return hops is null
        ? constantDelegate(function_) : new FrameDelegate(hops, function_);
}

private Node constantDelegate(void* function_) {
    import snakebite.nativelayout:
        delegateContextOffset, delegateFunctionOffset;

    SliceValue value;
    auto bytes = cast(ubyte*) &value;
    *cast(void**) (bytes + delegateContextOffset) = null;
    *cast(void**) (bytes + delegateFunctionOffset) = function_;
    return new ConstantSlice(value);
}

// The node that yields the dynamic array `expression`, or null when the
// tree does not cover the expression.
private Node buildSlice(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;

    if (!isSlice(expression.type))
        return null;
    switch (expression.op) with (EXP) {
        case variable: {
            // `__traits(initSymbol, T)`: the image of the aggregate's
            // initializer, which stays put for the life of the program.
            if (auto symbol = expression.isVarExp.var.isSymbolDeclaration) {
                const initial = ev._runtimeTypes.initializer(
                    symbol.dsym.isAggregateDeclaration);
                return new ConstantSlice(SliceValue(
                    initial.length, cast(ubyte*) initial.ptr));
            }
            auto declaration = expression.isVarExp.var.isVarDeclaration;
            const slot = slotOf(ev, declaration);
            if (!slot.ok) {
                auto outer = buildNonFrameAddress(ev, declaration);
                return outer is null ? null : new LoadSlice(outer);
            }
            return slot.indirect
                ? new LoadSlice(new PointerAddress(slot.offset, 0))
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
        case call: {
            auto call = expression.isCallExp;
            if (!returnsReference(call))
                return buildCall(ev, call);
            auto address = buildCall(ev, call);
            return address is null ? null : new LoadSlice(address);
        }
        case new_:
            return buildNew(ev, expression.isNewExp);
        case cast_:
            return buildSliceCast(ev, expression.isCastExp);
        case comma:
            return buildComma(ev, expression.isCommaExp, &buildSlice!E);
        case assign, construct, blit: {
            auto assignment = cast(AssignExp) expression;
            if (auto target = assignment.e1.isSliceExp)
                return buildSliceAssignment(ev, assignment, target);
            return buildPairStore(ev, assignment);
        }
        default:
            return null;
    }
}

// Whether a store of a scalar or of two words writes to `target`: a
// variable, a field, an element, the target of a pointer, or the result of
// a call that returns `ref`.
private bool isStoreTarget(Expression target) {
    if (auto call = target.isCallExp)
        return returnsReference(call);
    return target.isDotVarExp !is null || target.isVarExp !is null
        || target.isIndexExp !is null || target.isPtrExp !is null;
}

// An assignment to a slice. A slice that dmd typed as a static array is the
// place of its elements and stays with the evaluator. dmd marks `a[] = v`
// with `blockAssign` exactly when it cast `v` to the element type: `v` fills
// every element. Every other one copies the elements of the array on the
// right side.
private Node buildSliceAssignment(E)(
    E ev, AssignExp assignment, SliceExp target,
) {
    import dmd.expression: MemorySet;
    import dmd.typesem: nextOf, toBasetype;
    import snakebite.backends.sliceplan: planSlice;

    if (planSlice(target).yieldsStaticArray
            || (assignment.isConstructExp !is null
                && assignment.isConstructExp.lowering !is null))
        return null;
    auto to = buildSliceOf(ev, target);
    if (to is null)
        return null;
    auto element = assignment.type.toBasetype.nextOf;
    if (assignment.memset == MemorySet.blockAssign)
        return buildSliceFill(ev, to, element, assignment.e2);
    auto from = buildSlice(ev, assignment.e2);
    if (from is null)
        return null;
    return new SliceCopy(&ev.failTreeBounds, ev._treeRoot, assignment.loc,
        to, from, ev.factsOf(element).size);
}

// `to[] = value`, where `value` has the type `element`. A scalar element is
// carried in a register; any other element is a copy of the bytes of
// `value`.
private Node buildSliceFill(E)(E ev, Node to, Type element, Expression value) {
    const scalar = scalarOf(ev, element);
    final switch (scalar.kind) with (Scalar.Kind) {
        case integral, floating: {
            if (scalarOf(ev, value.type).kind != scalar.kind
                    || ev.factsOf(value.type).size != scalar.facts.size)
                return null;
            auto node = buildValue(ev, value);
            if (node is null)
                return null;
            static Node make(T)(Node to, Node value) {
                return new SliceFill!T(to, value);
            }
            return scalar.kind == floating
                ? byFloating!make(scalar.facts, to, node)
                : byWidth!make(scalar.facts, to, node);
        }
        case none: {
            auto node = isAggregate(element)
                ? buildAggregateFor(ev, element, value)
                : buildPair(ev, element, value);
            return node is null ? null : new SliceFillBytes(
                &ev._frames, to, node, ev.factsOf(element));
        }
    }
}

// Calls `make!T(args)` for the unsigned integral type of the width of
// `facts`, for a node that only moves the bits of a value.
private Node byWidth(alias make, Args...)(in TypeFacts facts, Args args) {
    switch (facts.size) {
        case 1: return make!ubyte(args);
        case 2: return make!ushort(args);
        case 4: return make!uint(args);
        case 8: return make!ulong(args);
        default: assert(0, "an integral scalar is 1, 2, 4 or 8 bytes");
    }
}

// A store of a dynamic array or a delegate.
private Node buildPairStore(E)(E ev, AssignExp e) {
    if (bindsReference(ev, e)
            || (e.isConstructExp !is null && e.isConstructExp.lowering !is null)
            || !isStoreTarget(e.e1))
        return null;
    auto value = buildPair(ev, e.e1.type, e.e2);
    if (value is null)
        return null;
    if (auto variable = e.e1.isVarExp) {
        const slot = slotOf(ev, variable.var.isVarDeclaration);
        if (slot.ok && !slot.indirect)
            return storeSlice(frameSlot(slot.offset), value);
    }
    auto address = buildAddress(ev, e.e1);
    return address is null
        ? null : storeSlice(addressOperandOf(address), value);
}

// A value of two words, a dynamic array or a delegate, of type `target`.
private Node buildPair(E)(E ev, Type target, Expression value) {
    if (isSlice(target))
        return isSlice(value.type) ? buildSlice(ev, value) : null;
    if (isDelegate(target))
        return isDelegate(value.type) ? buildDelegate(ev, value) : null;
    return null;
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
    if (plan.yieldsStaticArray)
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
    const dollar = dollarSlot(ev, expression.lengthVar);
    Node make(SliceSource source)(
        FailBounds fail, TreeRoot* root, SliceExp expression, Node base,
        Node lower, Node upper, size_t stride, size_t staticLength,
        in SlicePlan plan,
    ) {
        static if (source != SliceSource.pointer)
            if (dollar.ok)
                return new SliceOf!(source, true)(fail, root, expression,
                    base, lower, upper, stride, staticLength, plan,
                    dollar.offset);
        return new SliceOf!(source, false)(fail, root, expression, base,
            lower, upper, stride, staticLength, plan, noDollar);
    }
    switch (sourceType.ty) with (TY) {
        case Tarray: {
            auto base = buildSlice(ev, expression.e1);
            return base is null ? null : make!(SliceSource.slice)(
                &ev.failTreeBounds, ev._treeRoot, expression, base, lower, upper, stride,
                0, plan);
        }
        case Tpointer: {
            assert(expression.lengthVar is null, "a pointer has no `$`");
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
    import snakebite.internalfailure: internalFailure;
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
        case zero:
            return buildZeroPair(ev, castExp.e1);
        default:
            return null;
    }
}

// A cast to a value of two words that is zero: only `typeof(null)` casts to
// one.
private Node buildZeroPair(E)(E ev, Expression operand) {
    auto value = buildValue(ev, operand);
    return value is null ? null : new ZeroPairAfter(value);
}

// `new` yields the object it made. Its storage is the call of the hook that
// dmd lowered it to, the place of a placement `new`, or a frame temporary;
// `driveInit` decides the order of what follows at the object: its hidden
// contexts, then its constructor call or the fields given in order. The
// value of `new int(1)` fills the new storage as a field at offset 0 does.
private Node buildNew(E)(E ev, NewExp expression) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.backends.aggregateinit: AggregateInitPlan, driveInit,
        NewPlan, planClassContext, planNew, planPositionalFields;

    auto plan = planNew(expression);
    auto storage = buildNewStorage(ev, expression, plan);
    if (storage is null)
        return null;

    AggregateInitPlan initialisation;
    final switch (plan.objectKind) with (NewPlan.ObjectKind) {
        case class_:
            initialisation = planClassContext(expression);
            break;
        case struct_:
            initialisation = planPositionalFields(
                expression.newtype.toBasetype.isTypeStruct.sym,
                expression.member is null ? expression.arguments : null);
            break;
        case scalar: {
            const stores = expression.type.toBasetype.ty == TY.Tpointer
                && expression.arguments !is null
                && expression.arguments.length != 0;
            if (!stores)
                return storage;
            assert(expression.arguments.length == 1,
                "dmd rejects more than one argument for a scalar `new`");
            auto value = buildFieldValue(ev, 0, expression.newtype,
                (*expression.arguments)[0]);
            return value is null ? null : new Initialised(storage, [value]);
        }
    }

    auto hooks = NewInitHooks!E(ev);
    Node call;
    driveInit(hooks, initialisation, expression.member !is null, {
        if (plan.argumentPrefix !is null) {
            auto prefix = buildEffect(ev, plan.argumentPrefix);
            if (prefix is null)
                return;
            hooks.steps ~= new EffectStep(prefix);
        }
        call = buildConstructorCall(ev, expression,
            hooks.steps.length == 0 ? storage : new Initialised(storage, hooks.steps));
    });
    if (expression.member !is null)
        return call;
    if (hooks.failed)
        return null;
    return hooks.steps.length == 0 ? storage : new Initialised(storage, hooks.steps);
}

// The tree hooks of `driveInit`: each step appends its node, and a step that
// the tree does not build, where the evaluator falls back, is recorded.
private struct NewInitHooks(E) {
    import snakebite.backends.aggregateinit: InitStep;

    E ev;
    Node[] steps;
    bool failed;

    void applyVthis(InitStep step) {
        steps ~= buildVthisStep(ev, step);
    }

    void applyValue(InitStep step) {
        append(buildInitStep(ev, step));
    }

    void applyBitfield(InitStep step) {
        append(buildInitStep(ev, step));
    }

    void applyBroadcast(InitStep step) {
        append(buildInitStep(ev, step));
    }

    private void append(Node node) {
        if (node is null)
            failed = true;
        else
            steps ~= node;
    }
}

// The storage of the object that `new` makes, before `driveInit`.
private Node buildNewStorage(E)(
    E ev, NewExp expression,
    imported!"snakebite.backends.aggregateinit".NewPlan plan,
) {
    import dmd.typesem: toBasetype;
    import snakebite.backends.aggregateinit: NewPlan;

    final switch (plan.destination) with (NewPlan.Destination) {
        case lowering:
            // dmd lowers every heap `new` in code that runs.
            if (expression.lowering is null)
                return null;
            return isSlice(expression.lowering.type)
                ? buildSlice(ev, expression.lowering)
                : buildValue(ev, expression.lowering);
        case placement: {
            auto place = buildAddress(ev, plan.placement);
            if (place is null)
                return null;
            return new PlacedObject(place,
                plan.objectKind == NewPlan.ObjectKind.class_
                    ? classImageOf(ev, expression) : null);
        }
        case stack: {
            assert(plan.objectKind == NewPlan.ObjectKind.class_,
                "only a class object lives in the frame");
            auto declaration = expression.newtype.toBasetype.isTypeClass.sym;
            return new FrameObject!E(ev, declaration.structsize,
                declaration.alignsize == 0 ? 1 : declaration.alignsize,
                classImageOf(ev, expression));
        }
    }
}

// The initial bytes of an object of the class that `expression` makes.
private const(void)[] classImageOf(E)(E ev, NewExp expression) {
    import dmd.typesem: toBasetype;

    return ev._shared.classRuntimeInfo(
        expression.newtype.toBasetype.isTypeClass.sym).m_init;
}

// The hidden context of a nested aggregate. A nested class made with an
// outer object (`outer.new Inner`) takes that object, seen as the class it
// is nested in. Otherwise it is the context of the symbol the aggregate was
// made in: the frame of this function or of one that encloses it, or one
// that the evaluator finds.
private Node buildVthisStep(E)(E ev, InitStep step) {
    import snakebite.backends.dualcontext: ContextSource, contextSourceOf;

    if (step.source !is null) {
        auto value = buildValue(ev, step.source);
        return value is null
            ? new ContextStore!E(ev, step)
            : new ContextFromValue(step.offset, value, step.sourceAdjustment);
    }
    const source = contextSourceOf(ev._function, step.contextOwner);
    final switch (source.kind) with (ContextSource.Kind) {
        case none:
            return new FieldStore!long(step.offset, new Constant!long(0));
        case frame: {
            if (source.function_ is ev._function)
                return new FrameContextStore(step.offset, null);
            const hops = ev.staticChainTo(cast() source.function_);
            return hops is null
                ? new ContextStore!E(ev, step)
                : new FrameContextStore(step.offset, hops);
        }
        case receiver, overrider:
            return new ContextStore!E(ev, step);
    }
}

// The constructor of `new`, called on the allocation.
private Node buildConstructorCall(E)(E ev, NewExp expression, Node allocation) {
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    auto constructor = ev._callSelection.definitionOf(
        expression.member,
        (declaration) => ev._program.linkedFunctionOf(declaration));
    auto type = typeFunctionOf(constructor);
    if (expression.arguments is null)
        return null;
    auto callee = ev.treeCalleeAt(constructor, expression, expression.arguments);
    if (callee is null)
        return null;
    SiteArguments arguments;
    if (!buildArguments(ev, type, expression.arguments, arguments,
            extrasFor(callee)))
        return null;
    return bound(callee, new ConstructorCall!E(ev, null, constructor,
        allocation, /* receiverIsAddress */ false, arguments));
}

// The effect of `expression`, whatever its type, or null.
private Node buildEffect(E)(E ev, Expression expression) {
    import dmd.astenums: TY;
    import dmd.tokens: EXP;
    import dmd.typesem: toBasetype;

    if (auto declaration = expression.isDeclarationExp)
        return buildDeclaration(ev, declaration);
    // A discarded `ref` result is an address that nothing reads, as in
    // compiled code, whatever the type of the result.
    if (expression.op == EXP.call && returnsReference(expression.isCallExp))
        return buildCall(ev, expression.isCallExp);
    if (isSlice(expression.type))
        return buildSlice(ev, expression);
    if (isDelegate(expression.type))
        return buildDelegate(ev, expression);
    if (isAggregate(expression.type))
        return buildAggregateEffect(ev, expression);
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
        Node build() {
            const splits = one.op == EXP.andAnd || one.op == EXP.orOr
                || one.op == EXP.not;
            if (splits)
                return buildBranches(ev, one, where);
            return buildTruth(ev, one);
        }
        auto node = where == FullExpressionScope.Position.logicalOperand
            ? buildLogicalOperand(ev, one, &build) : build();
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

// The right operand of `&&` or `||`, which is a full expression of its own
// (`FullExpressionScope.Position.logicalOperand`), built by `build`.
private Node buildLogicalOperand(E)(
    E ev, Expression operand, scope Node delegate() build,
) {
    enum where = FullExpressionScope.Position.logicalOperand;
    auto built = buildRegion(ev, Region.Nesting.nested, build);
    if (built.node is null)
        return null;
    if (readsAfterEnd(built, where, operand))
        return buildTruthAfterEnd(ev, operand, where, Region.Nesting.nested);
    if (built.scoped)
        return new Scoped!E(
            ev, built.node, operand, where, positionOf(ev, operand));
    return built.node;
}

// The truth of the condition `expression` at `where`, whose full expression
// reads its result after the destructors of its temporaries ran
// (`readsLvalueAfterEnd`). The node runs the expression itself, so the
// statement does not wrap it.
private Node buildTruthAfterEnd(E)(
    E ev, Expression expression, in FullExpressionScope.Position where,
    in Region.Nesting nesting,
) {
    auto lvalue = FullExpressionScope.lvalueOf(expression);
    auto built = buildRegion(ev, nesting, () => buildAddress(ev, lvalue));
    if (built.node is null || !built.scoped)
        return null;
    return new ScopedTruth!E(new Scoped!E(ev, built.node, expression, where,
        positionOf(ev, expression)), expression.type);
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

    // A call whose result is a struct or a static array has no value in a
    // register. The value of a `ref` result is read at its address.
    if (expression.op == EXP.call) {
        auto call = expression.isCallExp;
        if (returnsReference(call))
            return buildLoad(ev, expression, buildCall(ev, call));
        return isAggregate(expression.type) ? null : buildCall(ev, call);
    }

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
                return loadOf(address, wordScalar);
            auto value = buildSlice(ev, array);
            return value is null ? null : new SliceWord(value, lengthOffset);
        }
        case variable: {
            auto declaration = expression.isVarExp.var.isVarDeclaration;
            const slot = slotOf(ev, declaration);
            if (!slot.ok)
                return buildLoad(ev, expression,
                    buildNonFrameAddress(ev, declaration));
            if (slot.indirect)
                return buildLoad(ev, expression,
                    new PointerAddress(slot.offset, 0));
            return scalar.kind == Scalar.Kind.floating
                ? byFloating!(New!Local)(scalar.facts, slot.offset)
                : byIntegral!(New!Local)(scalar.facts, slot.offset);
        }
        case this_, super_: {
            // `super` is `this` with the type of the base class; dmd's
            // `SuperExp` is a `ThisExp`.
            auto variable = thisVariable(ev, cast(ThisExp) expression);
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
            auto right = buildLogicalOperand(
                ev, logical.e2, () => buildTruth(ev, logical.e2));
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
            return new Constant!long(cast(long) cast(size_t)
                ev.functionAddressOf(expression.isFuncExp.fd));
        case symbolOffset: {
            // `&variable`, `&function` or the address of a `TypeInfo`.
            import snakebite.frontend.storage: typeInfoObjectOf;

            if (scalar.kind != Scalar.Kind.integral)
                return null;
            auto symbol = expression.isSymOffExp;
            if (auto function_ = symbol.var.isFuncDeclaration)
                return new Constant!long(cast(long) (cast(size_t)
                    ev.functionAddressOf(function_) + symbol.offset));
            if (auto typeInfo = symbol.var.isTypeInfoDeclaration)
                return new Constant!long(cast(long) (cast(size_t) cast(void*)
                    typeInfoObjectOf(typeInfo, *ev._runtimeTypes)
                    + symbol.offset));
            auto place = buildVariableAddress(ev, symbol.var.isVarDeclaration);
            if (place is null)
                return null;
            return new AddressValue(symbol.offset == 0
                ? place : fieldOfAddress(place, cast(size_t) symbol.offset));
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
        return fuse!(same, long, testLeft, testRight)(
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
    import snakebite.internalfailure: internalFailure;
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
        case zero:
            return scalar.kind == integral ? new ZeroAfter(operand) : null;
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
        return loadOf(fieldOfAddress(address, pointerOffset), wordScalar);
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

// The left operand is read before the right one runs. dmd does this and ldc
// reads the left operand last: `x < (x = 10)` with `int x = 1` is true with
// dmd and false with ldc. snakebite follows dmd, the host compiler of `bin/ut`.
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
            return fuse!(signed, long, testLeft, testRight)(
                operandOf(left), operandOf(right));
        else
            return plan.facts.isUnsigned
                ? fuse!(unsigned, long, unsignedTestLeft, unsignedTestRight)(
                    operandOf(left), operandOf(right))
                : fuse!(signed, long, testLeft, testRight)(
                    operandOf(left), operandOf(right));
    }
    if (plan.kind == ComparisonPlan.Kind.floating
            && scalarOf(ev, e.e1.type).kind == Scalar.Kind.floating) {
        static Node build(L, R)(L l, R r) {
            return new FloatCompare!(op, L, R)(FloatTest!(op, L, R)(l, r));
        }
        return ev.factsOf(e.e1.type).size == 8
            ? fuse!(build, double, doubleTestLeft, doubleTestRight)(
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
            target = Target(new PointerAddress(slot.offset, 0));
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
                return fuseStep!(make, long, steps)(
                    operandOf(step), FrameAddress(target.offset), operation);
            }
        }
        return new IntegerOpAssign!(op, T, Target, ChildOperand!long)(
            target, ChildOperand!long(step), operation);
    }
}

// `make!S(step, args)`, for the operand struct `S` of `step`, when its kind
// is in `steps`.
private Node fuseStep(alias make, V, Kind[] steps, Args...)(
    Operand step, Args args,
) {
    if (!steps.has(step.kind))
        step.kind = step.demoted;
    static foreach (kind; steps)
        if (step.kind == kind)
            return make!(OperandType!(kind, V))(
                makeOperand!(OperandType!(kind, V))(step), args);
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
            || !isStoreTarget(e.e1))
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
        if (slot.ok && !slot.indirect)
            return storeTo(target, frameSlot(slot.offset), value);
    }
    auto address = buildAddress(ev, e.e1);
    return address is null
        ? null : storeTo(target, addressOperandOf(address), value);
}

// The operand that is the frame slot at `offset`.
private Operand frameSlot(size_t offset) {
    return Operand.local(Kind.frameAddress, null, offset);
}

private Node storeTo(in Scalar target, Operand address, Node value) {
    static Node storeOf(T)(Operand address, Node value) {
        static Node make(A, S)(A address, S value) {
            return new Store!(T, A, S)(address, value);
        }
        static if (isFloatingPoint!T)
            alias V = double;
        else
            alias V = long;
        return fuse!(make, V, addressKinds, valueKinds!T)(
            address, operandOf(value));
    }
    if (target.kind == Scalar.Kind.floating) {
        if (target.facts.size == 8 && address.kind == Kind.frameAddress)
            if (auto fused = storeFusedDouble(
                    value, FrameAddress(address.offset)))
                return fused;
        return byFloating!storeOf(target.facts, address, value);
    }
    return byIntegral!storeOf(target.facts, address, value);
}

// A dynamic array stored to the storage at `address`.
private Node storeSlice(Operand address, Node value) {
    static Node make(A)(A address, Node value) {
        return new StoreSlice!A(address, value);
    }
    return fuseStep!(make, long, addressKinds)(address, value);
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
    // A variable in static storage is initialised once, before the program
    // reaches its declaration.
    if (variable.isDataseg)
        return new Jump!(TreeFlow.normal);
    if (variable._init is null || variable._init.isVoidInitializer !is null)
        return new Jump!(TreeFlow.normal);
    auto initializer = variable._init.isExpInitializer;
    if (initializer is null)
        return null;
    const materialised = ev._treeRoot._region.materialised.length;
    auto node = buildInitializer(ev, variable, declaration, initializer);
    return node is null ? null
        : initializationOf(ev, variable, declaration, node, materialised);
}

// The initialisation `store` of `variable`, which the evaluator's
// temporaries run when they decide its lifetime: dmd gave the temporary a
// destructor, or the variable can point into rvalues of its initialiser
// that have storage, which the variable keeps (`canRetainTemporaries`).
// `materialised` is the number of such rvalues before the initialiser.
private Node initializationOf(E)(
    E ev, VarDeclaration variable, DeclarationExp declaration, Node store,
    in size_t materialised,
) {
    import snakebite.backends.temporary: hasTemporaryDestructor;

    auto region = ev._treeRoot._region;
    const slot = ev._layout.slotOf(variable);
    const retains = slot !is null && slot.retainsTemporaries
        && region.materialised.length > materialised;
    if (!retains && !hasTemporaryDestructor(variable))
        return store;
    if (ev.isRefStorage(variable))
        return null;
    auto address = buildVariableAddress(ev, variable);
    if (address is null)
        return null;
    region.scoped = true;
    return statementOf(
        new Initialization!E(ev, variable, declaration, address, store, retains),
        positionOf(ev, declaration));
}

private Node buildInitializer(E)(
    E ev, VarDeclaration variable, DeclarationExp declaration,
    imported!"dmd.init".ExpInitializer initializer,
) {
    import snakebite.nativelayout: initializerRunsForEffect, initializerValueOf;

    if (ev.isRefStorage(variable)
            && !initializerRunsForEffect(initializer, variable))
        return buildReferenceBinding(
            ev, variable, initializerValueOf(initializer),
            positionOf(ev, declaration));
    const scalar = scalarOf(ev, variable.type);
    const variableIsPair = isSlice(variable.type) || isDelegate(variable.type);
    const variableIsAggregate = isAggregate(variable.type);
    if (scalar.kind == Scalar.Kind.none && !variableIsPair
            && !variableIsAggregate)
        return null;
    if (initializerRunsForEffect(initializer, variable)) {
        auto effect = buildEffect(ev, initializer.exp);
        return effect is null
            ? null : statementOf(effect, positionOf(ev, declaration));
    }
    auto value = initializerValueOf(initializer);
    const slot = slotOf(ev, variable);
    if (!slot.ok || ev.isRefStorage(variable))
        return null;
    if (variableIsAggregate) {
        import dmd.astenums: TY;
        import dmd.typesem: toBasetype;

        // A copy with a postblit is `(variable = value).__postblit()`, which
        // constructs the variable for its effect.
        if (value.type.toBasetype.ty == TY.Tvoid) {
            auto effect = buildEffect(ev, value);
            return effect is null
                ? null : statementOf(effect, positionOf(ev, declaration));
        }
        // The storage of a variable that is the result of its function is
        // the place of the result, whose address the slot holds.
        const facts = ev.factsOf(variable.type);
        auto node = buildAggregateFor(ev, variable.type, value);
        if (node is null)
            return null;
        Node target = slot.indirect
            ? new PointerAddress(slot.offset, 0) : new LocalAddress(slot.offset);
        return statementOf(
            new AggregateStore(&ev._frames, target, node, facts,
                /* construction */ true),
            positionOf(ev, declaration));
    }
    if (slot.indirect)
        return null;
    if (variableIsPair) {
        auto node = buildPair(ev, variable.type, value);
        return node is null ? null : statementOf(
            storeSlice(frameSlot(slot.offset), node),
            positionOf(ev, declaration));
    }
    if (scalarOf(ev, value.type).kind != scalar.kind
            || ev.factsOf(value.type).size != scalar.facts.size)
        return null;
    auto node = buildValue(ev, value);
    if (node is null)
        return null;
    return statementOf(storeTo(scalar, frameSlot(slot.offset), node),
        positionOf(ev, declaration));
}

// A struct or a static array: a value of its own bytes, which is not a
// register scalar or a slice.
package bool isAggregate(Type type) {
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
        case call:
            // The value of a `ref` result is copied from its address.
            if (returnsReference(expression.isCallExp))
                goto case this_;
            return buildCall(ev, expression.isCallExp);
        case assign, construct, blit:
            return buildAggregateStore(ev, cast(AssignExp) expression);
        case variable:
            // `S.init`: the bytes of the type's initial value.
            if (auto symbol = expression.isVarExp.var.isSymbolDeclaration) {
                if (symbol.type.isTypeStruct is null)
                    return null;
                return new ImageInto((cast(const(ubyte)[]) ev._nativeData
                    .initialValue(expression.type, expression.loc)).idup);
            }
            goto case this_;
        case this_, dotVariable, star, index: {
            auto address = buildAddress(ev, expression);
            return address is null ? null : new AggregateCopy(
                address, ev.factsOf(expression.type).size);
        }
        default:
            return null;
    }
}

// The struct or static array `value` of the type `target`, or null. dmd
// writes the value of a struct whose initial value is all zero bits, and of
// a static array of such structs, as the integer 0 (`getInitExp`;
// `dsymbolsem.d` for a declaration with no initializer), as in
// `s = 0, s.this(args)`.
private Node buildAggregateFor(E)(E ev, Type target, Expression value) {
    import dmd.expressionsem: toInteger;

    const size = ev.factsOf(target).size;
    if (value.isIntegerExp !is null && !isAggregate(value.type)) {
        assert(value.toInteger == 0, "dmd writes only an all-zero aggregate as an integer");
        return new ZeroInto(size);
    }
    if (!isAggregate(value.type) || ev.factsOf(value.type).size != size)
        return null;
    return buildAggregate(ev, value);
}

// `target = value` for a struct or a static array.
private Node buildAggregateStore(E)(E ev, AssignExp e) {
    if (bindsReference(ev, e)
            || (e.isConstructExp !is null && e.isConstructExp.lowering !is null)
            || !isAggregate(e.e1.type))
        return null;
    const facts = ev.factsOf(e.e1.type);
    auto target = buildAddress(ev, e.e1);
    auto value = buildAggregateFor(ev, e.e1.type, e.e2);
    if (target is null || value is null)
        return null;
    return new AggregateStore(
        &ev._frames, target, value, facts, e.isConstructExp !is null);
}

// The effect of the struct or static array `expression`.
private Node buildAggregateEffect(E)(E ev, Expression expression) {
    import dmd.tokens: EXP;

    switch (expression.op) with (EXP) {
        case call:
            return buildCall(ev, expression.isCallExp);
        case assign, construct, blit:
            return buildAggregateStore(ev, cast(AssignExp) expression);
        case comma:
            return buildComma(ev, expression.isCommaExp, &buildEffect!E);
        case question:
            return buildConditional!(buildEffect!E, ConditionalVoid)(
                ev, expression.isCondExp);
        default: {
            auto value = buildAggregate(ev, expression);
            return value is null ? null : new DiscardedAggregate(
                &ev._frames, value, ev.factsOf(expression.type));
        }
    }
}

private Node buildStructLiteral(E)(E ev, imported!"dmd.expression".StructLiteralExp literal) {
    import snakebite.nativelayout: isStoredLiteral;

    const facts = ev.factsOf(literal.type);
    if (literal.useStaticInit)
        return new ImageInto(
            (cast(const(ubyte)[]) ev._nativeData.initialValue(
                literal.type, literal.loc)).idup);
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
            return buildVthisStep(ev, step);
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

    Node optionalChild(Statement inner, Node* where) {
        return inner is null ? new Jump!(TreeFlow.normal) : child(inner, where);
    }

    // The nodes of the statements that `inner` runs in order, built on
    // first execution.
    Node[] children(Statement inner) {
        auto nodes = new Node[statementsOf(inner).length];
        foreach (i, one; statementsOf(inner))
            nodes[i] = child(one, &nodes[i]);
        return nodes;
    }

    // A condition is a full expression of its own on each evaluation.
    Node condition(Expression expression) {
        enum where = FullExpressionScope.Position.condition;
        auto built = buildRegion(
            ev, Region.Nesting.outermost, () => buildTruth(ev, expression));
        auto node = built.node is null ? null
            : readsAfterEnd(built, where, expression)
                ? buildTruthAfterEnd(
                    ev, expression, where, Region.Nesting.outermost)
                : endingAt(ev, built, expression, where);
        return node is null ? new GenericCondition!E(ev, expression) : node;
    }

    // The node of the full expression `expression`, which runs as a
    // statement.
    Node effect(
        Expression expression, in FullExpressionScope.Position where,
        scope Node delegate() build,
    ) {
        auto built = buildRegion(ev, Region.Nesting.outermost, build);
        return built.node is null ? null : endingAt(ev, built, expression, where);
    }

    switch (statement.stmt) with (STMT) {
        case Compound, CompoundDeclaration: {
            import dmd.statement: CompoundStatement;

            auto inner = statementsOf(statement);
            if (inner.length == 0)
                return new Jump!(TreeFlow.normal);
            if (inner.length == 1)
                return buildStatement(ev, inner[0], slot);
            static foreach (count; AliasSeq!(2, 3))
                if (inner.length == count) {
                    auto sequence = new ShortSequence!count;
                    foreach (i, one; inner)
                        sequence._children[i] = child(one, &sequence._children[i]);
                    return sequence;
                }
            return new Sequence(children(statement));
        }
        case Scope: {
            auto scoped = statement.isScopeStatement;
            if (scoped.statement is null)
                return new Jump!(TreeFlow.normal);
            return buildStatement(ev, scoped.statement, slot);
        }
        // dmd makes a destructor call that a scope ends a `DtorExp`
        // statement, which runs as the expression statement it is.
        case Exp, DtorExp: {
            import dmd.statement: ExpStatement;

            auto expression = (cast(ExpStatement) statement).exp;
            if (expression is null)
                return new Jump!(TreeFlow.normal);
            enum where = FullExpressionScope.Position.expressionStatement;
            if (auto declaration = expression.isDeclarationExp) {
                auto node = effect(expression, where,
                    () => buildDeclaration(ev, declaration));
                return node is null ? generic() : node;
            }
            auto node = effect(expression, where, () {
                auto value = buildEffect(ev, expression);
                return value is null
                    ? null : statementOf(value, positionOf(ev, expression));
            });
            return node is null ? generic() : node;
        }
        case If: {
            auto conditional = statement.isIfStatement;
            final switch (ifPlan(conditional).kind) with (IfPlan.Kind) {
                case ctfeBlock:
                    // `__ctfe` is false at run time.
                    return conditional.elsebody is null
                        ? new Jump!(TreeFlow.normal)
                        : buildStatement(ev, conditional.elsebody, slot);
                case condition:
                    break;
            }
            if (conditional.ifbody is null)
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
                step = effect(loop.increment,
                    FullExpressionScope.Position.loopIncrement, () {
                        auto value = buildEffect(ev, loop.increment);
                        return value is null ? null
                            : statementOf(value, positionOf(ev, loop.increment));
                    });
                if (step is null)
                    return generic();
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
        // dmd rewrites a scope guard in a block into a `try` statement. One
        // that is a whole `catch` handler stays, and runs nothing.
        case ScopeGuard:
            return new Jump!(TreeFlow.normal);
        case TryCatch: {
            auto tried = statement.isTryCatchStatement;
            auto node = new Catching!E(ev, tried);
            foreach (catch_; *tried.catches) {
                auto variable = Catching!E.noVariable;
                if (catch_.var !is null) {
                    const where = slotOf(ev, catch_.var);
                    if (!where.ok || where.indirect)
                        return generic();
                    variable = where.offset;
                }
                node._variables ~= variable;
            }
            node._body = optionalChild(tried._body, &node._body);
            node._handlers = new Node[tried.catches.length];
            foreach (i, catch_; *tried.catches)
                node._handlers[i] = optionalChild(
                    catch_.handler, &node._handlers[i]);
            return node;
        }
        case TryFinally: {
            auto tried = statement.isTryFinallyStatement;
            auto node = new Finally!E(ev, tried);
            node._body = optionalChild(tried._body, &node._body);
            node._finally = optionalChild(tried.finalbody, &node._finally);
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

// The statements that `statement` runs in order: those of a block, with the
// statements of the blocks and scopes inside it in place, or the statement
// itself. A block or scope has no cleanup of its own: what a destructor or
// `scope(exit)` runs is a statement that stays whole in the list.
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
                    inner ~= statementsOf(candidate);
            return inner;
        }
        default:
            return [statement];
    }
}

private Node buildReturn(E)(E ev, imported!"dmd.statement".ReturnStatement returned) {
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    Node generic() {
        return new GenericStatement!E(ev, returned);
    }

    if (returned.fesFunc !is null || returned.caseDim != 0)
        return generic();
    if (returned.exp is null)
        return new Jump!(TreeFlow.return_);
    enum where = FullExpressionScope.Position.returnOperand;
    Node value;
    auto built = buildRegion(ev, Region.Nesting.outermost,
        () => buildReturnOperand(ev, returned, value));
    if (built.node is null)
        return generic();
    if (readsAfterEnd(built, where, returned.exp)
            && !typeFunctionOf(ev._function).isRef) {
        auto after = buildReturnAfterEnd(ev, returned.exp);
        return after is null ? generic() : after;
    }
    auto node = endingAt(ev, built, returned.exp, where);
    const only = statementsOf(ev._function.fbody);
    if (node is value && only.length == 1 && only[0] is returned)
        ev._treeRoot._soleReturn = node;
    return node;
}

// The return statement of `returned.exp`, or null when the tree does not
// cover it. `value` is set to the node when it is one that can give a
// scalar result in a register.
private Node buildReturnOperand(E)(
    E ev, imported!"dmd.statement".ReturnStatement returned, out Node value,
) {
    import dmd.astenums: TY;
    import dmd.typesem: toBasetype;
    import snakebite.frontend.dmd.functions: typeFunctionOf;

    if (typeFunctionOf(ev._function).isRef) {
        auto address = buildAddress(ev, returned.exp);
        return address is null ? null : new ReturnReference(
            address, positionOf(ev, returned.exp));
    }
    if (ev._type.toBasetype.ty == TY.Tvoid) {
        // `return f();` in a function without a result: `f` runs, then the
        // function ends.
        auto effect = buildEffect(ev, returned.exp);
        if (effect is null)
            return null;
        auto sequence = new ShortSequence!2;
        sequence._children[0] = statementOf(effect, positionOf(ev, returned.exp));
        sequence._children[1] = new Jump!(TreeFlow.return_);
        return sequence;
    }
    if (isSlice(ev._type)) {
        if (!isSlice(returned.exp.type))
            return null;
        auto slice = buildSlice(ev, returned.exp);
        return slice is null ? null : new ReturnSlice(
            slice, positionOf(ev, returned.exp));
    }
    if (isAggregate(ev._type)) {
        if (!isAggregate(returned.exp.type))
            return null;
        auto aggregate = buildAggregate(ev, returned.exp);
        return aggregate is null ? null : new ReturnAggregate!E(
            ev, aggregate, positionOf(ev, returned.exp), ev.factsOf(ev._type));
    }
    const scalar = scalarOf(ev, ev._type);
    if (scalar.kind == Scalar.Kind.none
            || scalarOf(ev, returned.exp.type).kind != scalar.kind
            || ev.factsOf(returned.exp.type).size != scalar.facts.size)
        return null;
    auto operand = buildValue(ev, returned.exp);
    if (operand is null)
        return null;
    static Node make(T)(Node v, Position p) {
        static Node returning(S)(S value, Position p) {
            return new ReturnValue!(T, S)(value, p);
        }
        static if (isFloatingPoint!T)
            alias V = double;
        else
            alias V = long;
        return fuseStep!(returning, V, valueKinds!T)(operandOf(v), p);
    }
    auto position = positionOf(ev, returned.exp);
    value = scalar.kind == Scalar.Kind.floating
        ? byFloating!make(scalar.facts, operand, position)
        : byIntegral!make(scalar.facts, operand, position);
    return value;
}

// The return of `operand`, whose full expression reads its result after
// the destructors of its temporaries ran (`readsLvalueAfterEnd`).
private Node buildReturnAfterEnd(E)(E ev, Expression operand) {
    enum where = FullExpressionScope.Position.returnOperand;
    auto built = buildRegion(ev, Region.Nesting.outermost,
        () => buildAddress(ev, FullExpressionScope.lvalueOf(operand)));
    if (built.node is null || !built.scoped)
        return null;
    return new ScopedReturn!E(ev, new Scoped!E(ev, built.node, operand,
        where, positionOf(ev, operand)), ev.factsOf(ev._type));
}

// Whether the full expression `built` at `where` reads its result
// `expression` after its destructors ran: the evaluator runs it.
private bool readsAfterEnd(
    in Built built, in FullExpressionScope.Position where,
    Expression expression,
) {
    return built.scoped
        && FullExpressionScope.readsLvalueAfterEnd(where, expression);
}
