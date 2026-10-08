module ut.frontend.functions;


import snakebite.frontend.compiler: parseSnippet, withCompilerLock;
import snakebite.frontend.dmd.functions: findFunction;
import ut;


// An is-expression can test an invalid instance without rejecting the module.
@("findFunction.skipsFailedSpeculativeInstance")
unittest {
    auto module_ = parseSnippet(q{
        template Probe(T) {
            int ghost() { return T.noSuchMember; }
        }
        enum ignored = is(Probe!int == module);
        void main() {}
    });

    withCompilerLock({
        (findFunction(module_, "ghost") is null).should == true;
        (findFunction(module_, "main") !is null).should == true;
    });
}
