module snakebite.backends.staticchain;


private:


import snakebite.backends.layout: FrameLayout;


// One step in walking a static chain outward from a nested function's own
// frame toward an owner further out: which pointer word holds the next
// context, and where to read it from.
public enum HopKind {
    // A closure's first word always links to the context it was built
    // from - `allocateClosure`'s own convention, shared by both backends.
    closureWord,
    // A non-closure function's hidden `this`/context parameter, at its
    // own frame offset.
    frameSlot,
    // A nested struct's own hidden context field (`vthis`), at its own
    // offset among that struct's declared fields.
    structField,
}

public struct Hop {
    public HopKind kind;
    // Meaningful for `frameSlot` and `structField`; always zero for
    // `closureWord`.
    public size_t offset;
}

// The ordered hops from `from`'s own frame to `to`'s context: `null` when
// `to` is not reachable from `from` (a nested struct with no context field,
// or a function with no hidden context parameter of its own). An empty,
// non-null result never occurs - `from is to` is each backend's own trivial
// case, answered from its own current-frame or current-closure address
// without walking anything, so callers only reach here once a walk is
// actually needed.
//
// `from` and `to` are dmd facts alone - the frame or heap-closure
// representation of any hop belongs to whichever backend folds this list
// into loads.
public Hop[] staticChainPath(
    imported!"dmd.func".FuncDeclaration from,
    imported!"dmd.func".FuncDeclaration to,
) {
    import snakebite.frontend.dmd.delegates: functionNeedsClosure;

    if (from is to)
        return null;

    const layout = FrameLayout.of(from);
    if (layout.hiddenThis.variable is null)
        return null;

    Hop[] hops = [Hop(HopKind.frameSlot, layout.hiddenThis.parameter.offset)];

    auto parent = from.toParent2();
    auto currentFunction = parent is null ? null : parent.isFuncDeclaration;
    auto currentStruct = parent is null ? null : parent.isStructDeclaration;

    while (currentFunction !is to) {
        if (currentStruct !is null) {
            if (!currentStruct.isNested() || currentStruct.vthis is null)
                return null;

            hops ~= Hop(HopKind.structField, currentStruct.vthis.offset);

            auto next = currentStruct.toParent2();
            currentFunction = next is null ? null : next.isFuncDeclaration;
            currentStruct = next is null ? null : next.isStructDeclaration;
            continue;
        }

        if (currentFunction is null)
            return null;

        if (functionNeedsClosure(currentFunction))
            hops ~= Hop(HopKind.closureWord, 0);
        else {
            const currentLayout = FrameLayout.of(currentFunction);
            if (currentLayout.hiddenThis.variable is null)
                return null;

            hops ~= Hop(
                HopKind.frameSlot,
                currentLayout.hiddenThis.parameter.offset,
            );
        }

        auto next = currentFunction.toParent2();
        currentFunction = next is null ? null : next.isFuncDeclaration;
        currentStruct = next is null ? null : next.isStructDeclaration;
    }

    return hops;
}
