module snakebite.ffi.call;


private:


// Calls the already-compiled function that `function_` declares.
//
// A declaration with no body is not a program to walk: the body is machine
// code in a library the host process already links, and druntime is not
// reimplemented here, so calling that code is the only way to run it. This
// is what every backend uses to do so.
//
// `arguments` are the addresses of each argument's native bytes, in
// declaration order, and the result is written to `returnPlace` in native
// layout - the same convention `Backend.call` uses, so a caller hands over
// slots it already has rather than marshalling anything.
//
// `returnPlace` may be `null` to discard the result, and must otherwise be
// exactly the return type's size.
//
// The linkage decides only the symbol's name, which dmd's own mangler
// supplies; how the arguments travel is the target's ABI, the same for
// every non-D linkage. A signature that ABI does not cover here throws,
// naming what it could not pass.
public void callCompiled(
    imported!"dmd.func".FuncDeclaration function_,
    void* returnPlace,
    scope const(void*)[] arguments,
) {
    import snakebite.ffi.abi: invoke, maxArguments, supported, word, writeWord;
    import snakebite.ffi.symbol: symbolAddress;
    import dmd.astenums: Tvoid, VarArg;
    import dmd.mangle: mangleExact;
    import std.conv: text;

    static if (!supported)
        throw new Exception(
            "ffi is implemented for the System V AMD64 ABI only",
        );
    else {
        auto type = function_.type.isTypeFunction;
        if (type is null)
            throw new Exception(
                text("ffi cannot call `", function_.toString,
                    "`: it is not a function"),
            );

        // A variadic callee is handed its arguments differently - on the
        // System V AMD64 ABI the caller must also report how many SSE
        // registers it used - so the fixed-arity call below would be the
        // wrong call, not merely an incomplete one.
        if (type.parameterList.varargs != VarArg.none)
            throw new Exception(
                text("ffi cannot call the variadic function `",
                    function_.toString, "`"),
            );

        if (arguments.length > maxArguments)
            throw new Exception(
                text("ffi cannot call `", function_.toString, "`: it takes ",
                    arguments.length, " arguments, and at most ",
                    maxArguments, " are passed in registers"),
            );

        auto address = symbolAddress(mangleExact(function_));
        if (address is null)
            throw new Exception(
                text("ffi cannot resolve the symbol `",
                    mangleExact(function_).text, "` declared by `",
                    function_.toString, "`: it is not in this process"),
            );

        size_t[maxArguments] words;
        foreach (i, argument; arguments)
            words[i] = word(type.parameterList[i].type, argument);

        const result = invoke(address, words[0 .. arguments.length]);

        // A `void` callee leaves the return register holding whatever it
        // last used it for, so reading it would be reading garbage.
        auto returnType = type.nextOf;
        if (returnPlace is null || returnType.ty == Tvoid)
            return;

        writeWord(returnType, result, returnPlace);
    }
}
