module snakebite.backends.nodecoveragecontrols;

import snakebite.backends.nodecoverage;
import dmd.expression;
import dmd.statement;
import dmd.visitor: Visitor;

extern(C++) class ParentOnly: Visitor {
    alias visit = Visitor.visit;
    override void visit(BinAssignExp) {}
}

extern(C++) class Exact: ParentOnly {
    alias visit = ParentOnly.visit;
    override void visit(AddAssignExp) {}
}

extern(C++) class ModeVisitor(bool checked): Visitor {
    alias visit = Visitor.visit;
    static if (!checked)
        override void visit(AddAssignExp) {}
}

static assert(!hasExactVisit!(ParentOnly, AddAssignExp));
static assert(hasExactVisit!(Exact, AddAssignExp));
static assert(hasExactVisit!(ParentOnly, BinAssignExp));
static assert(!hasExactVisit!(Exact, BinAssignExp));
static assert(hasRuntimeVisit!(ParentOnly, AddAssignExp));
static assert(!hasRuntimeVisit!(Visitor, AddAssignExp));
static assert(!hasExactVisit!(Visitor, AddAssignExp));
static assert(hasExactVisit!(ModeVisitor!false, AddAssignExp));
static assert(!hasExactVisit!(ModeVisitor!true, AddAssignExp));
static assert(AssertForwardingRecords!ForwardedNodes);
static assert(AssertNodeUniverse!(NodeSet!FrontendNodes, NodeSet!VisitorNodes));

version (MissingLeaf)
    static assert(hasExactVisit!(ParentOnly, AddAssignExp),
        "node coverage: ParentOnly has no exact AddAssignExp visit");
version (CheckedMissing)
    static assert(hasExactVisit!(ModeVisitor!true, AddAssignExp),
        "node coverage: ModeVisitor!true has no exact AddAssignExp visit");
version (WrongTarget)
    static assert(AssertForwardingRecords!(Forward!(AddAssignExp, BinExp)));
version (ForwardCycle)
    static assert(AssertForwardingRecords!(Forward!(AddAssignExp, AddAssignExp)));
version (DuplicateRecord)
    static assert(AssertForwardingRecords!(
        Forward!(AddAssignExp, BinAssignExp),
        Forward!(AddAssignExp, BinAssignExp),
    ));
version (MissingClass)
    static assert(AssertNodeUniverse!(
        NodeSet!(Expression, Statement), NodeSet!VisitorNodes));
version (MissingVisit)
    static assert(AssertNodeUniverse!(
        NodeSet!FrontendNodes, NodeSet!(Expression, Statement)));

version (MissingTarget)
    static assert(hasRuntimeVisit!(Visitor, AddAssignExp),
        "node coverage: forwarding target has no exact BinAssignExp visit");

version (AddedModule) {
    import snakebite.backends.nodecoverageaddednode: AddedNode;

    static assert(AssertNodeUniverse!(
        NodeSet!(FrontendNodes, AddedNode), NodeSet!VisitorNodes));
}
