module imagea_load;

import snakebite.backends.bytecode.imagea: loadImageBundleA, runImageA;
import std.conv: to;
import std.stdio: writeln;
import snakebite.ffi.plan;

int main(string[] args) {
    const functions = loadImageBundleA(args[1]);
    const result = runImageA(functions[0], args[2].to!ulong, args[3].to!ulong);
    writeln(result);
    if (args.length > 5 && args[5] == "typeinfo") {
        assert(functions.length == 2);
        const info = cast(TypeInfo) cast(void*) runImageA(functions[1], 0, 0);
        assert(info is cast(TypeInfo) cast(void*) runImageA(functions[1], 7, 11));
        assert(*cast(const(ulong)*) info.initializer.ptr == 73);
        assert(info.toString.length != 0);
    }
    return result == args[4].to!ulong ? 0 : 1;
}
