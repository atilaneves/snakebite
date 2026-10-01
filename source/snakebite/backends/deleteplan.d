module snakebite.backends.deleteplan;


private:


import dmd.typesem: toBasetype;


// The single decision both backends use for a `DeleteExp`. The frontend
// rejects `delete` in user code, so the only `DeleteExp` that reaches a
// backend is the scope-exit destruction of a `scope` class variable
// (`dsymbolsem.d`, `callScopeDtor`), and `expressionsem.d` has already
// rejected every operand that is not a class or an interface. An
// interface operand points at the interface's own slot inside the
// object, so druntime's `_d_callinterfacefinalizer` finds the object
// from the slot's offset while `_d_callfinalizer` takes the object
// itself.
public struct DeletePlan {
    import dmd.expression: Expression;

    public enum Kind {
        classFinalizer,
        interfaceFinalizer,
    }

    public Kind kind;
    public Expression object;
}

public DeletePlan planDelete(imported!"dmd.expression".DeleteExp expression) {
    auto classType = expression.e1.type.toBasetype.isTypeClass;
    assert(classType !is null,
        "the frontend only deletes class and interface operands");

    return DeletePlan(
        classType.sym.isInterfaceDeclaration is null
            ? DeletePlan.Kind.classFinalizer
            : DeletePlan.Kind.interfaceFinalizer,
        expression.e1,
    );
}
