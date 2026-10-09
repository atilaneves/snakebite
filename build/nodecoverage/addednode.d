module snakebite.backends.nodecoverageaddednode;

import dmd.expression: Expression;
import dmd.location: Loc;
import dmd.tokens: EXP;

// A new module can add a runtime-family class without a Visitor overload.
extern(C++) abstract class AddedNode: Expression {
    extern(D) this(Loc loc) {
        super(loc, EXP.int64);
    }
}
