module ut.backends.interpreter.classes;


import ut;
import snakebite.backends.backend: Program;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// A class linked into this process whose fully qualified name a guest
// class below shares: this module's name is the guest module's name.
public class Twin {
    public int value() {
        return 1;
    }
}


// A guest class and a native class can have the same fully qualified
// name - a root module that is also linked into the host, which is what
// running a project's own tests over its own modules produces. Which of
// the two an object belongs to is its own `TypeInfo_Class`'s identity,
// not that name: a native object's virtual call must run the native
// override even once the interpreter has built the guest twin's own
// runtime type. The native instance is a `scope` one so that this
// module links no allocation hook instance for `Twin` - the guest's own
// `new` would otherwise find that hook by name and build a native
// object rather than a guest one.
@("sameNameNativeClassIsNotTheGuestOne")
@Tags(Interpreter.stringof)
unittest {
    auto module_ = parseSnippet(q{
        module ut.backends.interpreter.classes;

        class Twin {
            int value() {
                return 2;
            }
        }

        int guestValue() {
            return new Twin().value;
        }

        int valueOf(Twin twin) {
            return twin.value;
        }
    });
    auto backend = new Interpreter(Program([module_]));

    int result;
    backend.call(findFunction(module_, "guestValue"), &result, []);
    result.should == 2;

    scope Twin native = new Twin;
    backend.call(findFunction(module_, "valueOf"), &result, [&native]);
    result.should == 1;
}
