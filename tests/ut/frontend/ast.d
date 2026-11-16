module ut.frontend.ast;


// Code outside the frontend package takes its dmd names from
// `snakebite.frontend.ast`. A dmd function that can make, merge or mangle a
// type is not there, so such code cannot call it with no frontend lock: it
// calls it through `inFrontend`, which takes the lock.
static foreach (name; ["mutableOf", "unSharedOf", "addMod", "merge2",
        "pointerTo", "mangleToBuffer"])
    static assert(!__traits(compiles,
            mixin("{ import snakebite.frontend.ast: ", name, "; }")),
        name ~ " must be reached through inFrontend, not imported");

// A node type is there, so the assertions above fail for the name, not for
// the import.
static assert(__traits(compiles, { import snakebite.frontend.ast: Type; }));
