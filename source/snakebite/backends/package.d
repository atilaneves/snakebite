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


public enum BackendName {
    interpreter,
    bytecode,
    ctfe,
}


public enum validBackendNames = "interpreter, bytecode, ctfe";


public enum backendIdentity(BackendType) =
    is(BackendType == imported!"snakebite.backends.interpreter".Interpreter)
        ? BackendName.interpreter
        : is(BackendType == imported!"snakebite.backends.bytecode".Bytecode)
            ? BackendName.bytecode
            : BackendName.ctfe;


public bool parseBackendName(
    in string input,
    out BackendName backend,
) @safe pure nothrow {
    switch (input) with (BackendName) {
        case "interpreter":
            backend = interpreter;
            return true;
        case "bytecode":
            backend = bytecode;
            return true;
        case "ctfe":
            backend = ctfe;
            return true;
        default:
            return false;
    }
}


public Backend makeBackend(in BackendName name, Program program) {
    final switch (name) with (BackendName) {
        case interpreter:
            return new imported!"snakebite.backends.interpreter".Interpreter(program);
        case bytecode:
            return new imported!"snakebite.backends.bytecode".Bytecode(program);
        case ctfe:
            return new imported!"snakebite.backends.ctfe".Ctfe(program);
    }
}
