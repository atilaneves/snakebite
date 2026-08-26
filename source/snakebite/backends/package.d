module snakebite.backends;


public import snakebite.backends.backend;


private:


// Every backend, explicitly. The only module that knows them all; backends
// never import each other.
public alias Backends = imported!"std.meta".AliasSeq!(
    imported!"snakebite.backends.ctfe".Ctfe,
);
