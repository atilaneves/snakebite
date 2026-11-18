module ut.backends.bytecode.relocation;


import ut.backends;
import snakebite.backends.bytecode.inspection: handlerRoleMismatches;
import snakebite.backends.bytecode.vm:
    registerFormsWithChangedRoles, specialisedHandlersWithoutRoles;


// Handlers are rewritten after emission, and a rewritten handler has to keep
// the roles of the original: the compiler asks about the original and the
// loader of an image about the final one.
@("relocation.everySpecialisedHandlerHasRoles")
unittest {
    specialisedHandlersWithoutRoles.should == 0;
}

// The compiler records the addresses of a function before it swaps an
// operation for its register form, and the loader of an image reads the roles
// of the form.
@("relocation.registerFormsKeepTheRolesOfTheOriginal")
unittest {
    registerFormsWithChangedRoles.should == 0;
}

// The handlers that no specialisation covers are registered by hand.
@("relocation.handRegisteredHandlersHaveRoles")
unittest {
    handlerRoleMismatches.should == string[].init;
}
