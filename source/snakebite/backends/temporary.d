module snakebite.backends.temporary;


private:

import dmd.astenums: STC;


// DMD records the destructor expression on the temporary declaration. Both
// runtime backends use this predicate before they add their own execution
// record, so ownership and explicit `nodtor` transfers have one definition.
public bool ownsTemporaryDestructor(
    imported!"dmd.declaration".VarDeclaration variable,
    imported!"dmd.expression".DeclarationExp declaration,
    imported!"dmd.expression".Expression root,
) {
    return declaration !is root
        && (variable.storage_class & STC.temp)
        && variable.edtor !is null
        && !(variable.storage_class & STC.nodtor);
}
