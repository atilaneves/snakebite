module snakebite.backends;


public import snakebite.backends.backend;


private:


// Every backend, explicitly. The only module that knows them all; backends
// never import each other.
public alias Backends = imported!"std.meta".AliasSeq!(
    imported!"snakebite.backends.bytecode".Bytecode,
    imported!"snakebite.backends.ctfe".Ctfe,
    imported!"snakebite.backends.interpreter".Interpreter,
);
