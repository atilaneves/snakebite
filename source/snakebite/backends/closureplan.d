module snakebite.backends.closureplan;


private:


import snakebite.backends.layout: ClosureLayout, FrameLayout;


public struct Hop {
    public enum Kind {
        closureWord,
        frameSlot,
        structField,
        contextPairWord,
    }

    public Kind kind;
    public size_t offset;
}

public struct ClosurePlan {
    import snakebite.backends.layout: ClosureLayout;
    import dmd.func: FuncDeclaration;

    public bool needsClosure;
    public ClosureLayout layout;

    public static ClosurePlan of(FuncDeclaration function_) {
        import snakebite.frontend.dmd.delegates:
            functionNeedsClosure;

        const needed = functionNeedsClosure(function_);
        return ClosurePlan(
            needed,
            needed ? ClosureLayout.of(function_) : ClosureLayout.init,
        );
    }

    // The hops from the value of `function_`'s hidden `this` slot to its
    // receiver: none for a function with one context, and word 0 of the
    // pair for one with two.
    public static Hop[] receiverHops(FuncDeclaration function_) {
        import snakebite.backends.dualcontext: DualContext;
        import snakebite.frontend.dmd.delegates: isDualContext;

        return isDualContext(function_)
            ? [Hop(Hop.Kind.contextPairWord,
                DualContext.receiverWord * size_t.sizeof)]
            : null;
    }

    public static Hop[] staticChainPath(
        FuncDeclaration from,
        FuncDeclaration to,
    ) {
        import dmd.aggregate: AggregateDeclaration;
        import snakebite.backends.dualcontext:
            fieldTowards, parentTowards, wordTowards;
        import snakebite.frontend.dmd.delegates: isDualContext;

        if (from is to)
            return null;

        const layout = FrameLayout.of(from);
        if (layout.hiddenThis.variable is null)
            return null;

        Hop[] hops = [Hop(Hop.Kind.frameSlot,
            layout.hiddenThis.parameter.offset)];

        if (isDualContext(from))
            hops ~= Hop(Hop.Kind.contextPairWord, from.wordTowards(to));

        auto parent = from.parentTowards(to);
        auto currentFunction = parent is null ? null : parent.isFuncDeclaration;
        auto currentAggregate =
            parent is null ? null : parent.isAggregateDeclaration;

        while (currentFunction !is to) {
            if (currentAggregate !is null) {
                if (!currentAggregate.isNested()
                        || currentAggregate.vthis is null)
                    return null;

                hops ~= Hop(Hop.Kind.structField,
                    currentAggregate.fieldTowards(to));

                auto next = currentAggregate.parentTowards(to);
                currentFunction = next is null
                    ? null : next.isFuncDeclaration;
                currentAggregate = next is null
                    ? null : next.isAggregateDeclaration;
                continue;
            }

            if (currentFunction is null)
                return null;

            if (of(currentFunction).needsClosure)
                hops ~= Hop(Hop.Kind.closureWord, 0);
            else {
                const currentLayout = FrameLayout.of(currentFunction);
                if (currentLayout.hiddenThis.variable is null)
                    return null;

                hops ~= Hop(
                    Hop.Kind.frameSlot,
                    currentLayout.hiddenThis.parameter.offset,
                );
            }

            if (isDualContext(currentFunction))
                hops ~= Hop(Hop.Kind.contextPairWord,
                    currentFunction.wordTowards(to));

            auto next = currentFunction.parentTowards(to);
            currentFunction = next is null ? null : next.isFuncDeclaration;
            currentAggregate =
                next is null ? null : next.isAggregateDeclaration;
        }

        return hops;
    }
}
