module ut.backends.staticchain;


import ut;
import dmd.dsymbol: Dsymbol;
import dmd.func: FuncDeclaration;
import dmd.statement: Statement;
import snakebite.backends.staticchain: Hop, HopKind, staticChainPath;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// `staticChainPath` is a pure function of two `FuncDeclaration`s, decided
// once and read by both backends the way `ut.backends.casts` pins
// `classify`'s `CastExp` counterpart. A local function or struct declared
// directly inside a function body reaches dmd's semantic pass as a
// `DeclarationExp` wrapped in an `ExpStatement`, the same shape a local
// variable declaration takes; this walk follows that shape down to the
// declaration under test.
private Dsymbol findLocal(Statement statement, in string name) {
    if (statement is null)
        return null;

    if (auto compound = statement.isCompoundStatement) {
        if (compound.statements is null)
            return null;

        foreach (child; *compound.statements) {
            if (auto found = findLocal(child, name))
                return found;
        }
        return null;
    }

    auto expStatement = statement.isExpStatement;
    if (expStatement is null || expStatement.exp is null)
        return null;

    auto declaration = expStatement.exp.isDeclarationExp;
    if (declaration is null)
        return null;

    if (declaration.declaration.ident.toString == name)
        return declaration.declaration;

    if (auto nestedFunction = declaration.declaration.isFuncDeclaration)
        return findLocal(nestedFunction.fbody, name);

    if (auto nestedStruct = declaration.declaration.isStructDeclaration) {
        if (nestedStruct.members is null)
            return null;

        foreach (member; *nestedStruct.members) {
            if (member.ident !is null && member.ident.toString == name)
                return member;

            if (auto method = member.isFuncDeclaration)
                if (auto found = findLocal(method.fbody, name))
                    return found;
        }
    }

    return null;
}

private struct Nesting {
    FuncDeclaration outer;
    FuncDeclaration target;
}

private Nesting nestingOf(string body_, in string outerName, in string name) {
    auto module_ = parseSnippet(body_);
    auto outer = findFunction(module_, outerName);
    assert(outer !is null,
        "No function `" ~ outerName ~ "` in the guest program");

    auto found = findLocal(outer.fbody, name);
    assert(found !is null,
        "No local `" ~ name ~ "` found in `" ~ outerName ~ "`");

    auto target = found.isFuncDeclaration;
    assert(target !is null, "`" ~ name ~ "` is not a function");
    return Nesting(outer, target);
}


@("directNesting.oneFrameSlotHop")
unittest {
    auto nesting = nestingOf(q{
        int outer() {
            int x = 1;
            int inner() { return x; }
            return inner();
        }
    }, "outer", "inner");

    const path = staticChainPath(nesting.target, nesting.outer);

    path.length.should == 1;
    path[0].kind.should == HopKind.frameSlot;
}


@("nestedStructMethod.frameSlotThenStructFieldHop")
unittest {
    // `m`'s own hidden `this` is its `S` receiver, so the first hop only
    // reaches the receiver - the second hop crosses `S.vthis`, the
    // context `S`'s own instance captured when `S()` built it, to reach
    // `outer`.
    auto nesting = nestingOf(q{
        int outer() {
            int x = 1;
            struct S {
                int m() { return x; }
            }
            return S().m();
        }
    }, "outer", "m");

    const path = staticChainPath(nesting.target, nesting.outer);

    path.length.should == 2;
    path[0].kind.should == HopKind.frameSlot;
    path[1].kind.should == HopKind.structField;
}


@("closureCrossing.frameSlotThenClosureWordHop")
unittest {
    // `next` escapes `middle` by address (`return &next;`), so dmd's own
    // escape analysis gives `middle` a heap closure rather than an
    // ordinary frame - `leaf`, a sibling nested function reading `outer`'s
    // own local, crosses that closure's own first word to get past
    // `middle` on its way out, instead of a second frame slot.
    auto nesting = nestingOf(q{
        int delegate() outer() {
            int x = 1;
            int delegate() middle() {
                int y = 2;
                int leaf() { return x; }
                int next() { return y; }
                auto discard = leaf();
                return &next;
            }
            auto d = middle();
            return d;
        }
    }, "outer", "leaf");

    const path = staticChainPath(nesting.target, nesting.outer);

    path.length.should == 2;
    path[0].kind.should == HopKind.frameSlot;
    path[1].kind.should == HopKind.closureWord;
}


@("sameFunction.noPath")
unittest {
    auto nesting = nestingOf(q{
        int outer() {
            int x = 1;
            int inner() { return x; }
            return inner();
        }
    }, "outer", "inner");

    (staticChainPath(nesting.outer, nesting.outer) is null).should == true;
}
