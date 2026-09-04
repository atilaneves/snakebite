import std.stdio: writeln, stderr;
import std.meta: AliasSeq;
import std.array: join;

static import cerealed;
static import cerealed.attrs;
static import cerealed.scopebuffer;
static import cerealed.traits;
static import unit_threaded;
static import tests.bugs;
static import tests.cerealiser_impl;
static import tests.classes;
static import tests.multidimensional_array;
static import tests.compile_time;
static import tests.decode;
static import tests.encode;
static import tests.encode_decode;
static import tests.enums;
static import tests.example;
static import tests.nested;
static import tests.pointers;
static import tests.protocol_unit;
static import tests.property;
static import tests.range;
static import tests.reset;
static import tests.static_array;
static import tests.structs;
static import tests.utils;

alias allModules = AliasSeq!(
    cerealed,
    cerealed.attrs,
    cerealed.scopebuffer,
    cerealed.traits,
    unit_threaded,
    tests.bugs,
    tests.cerealiser_impl,
    tests.classes,
    tests.multidimensional_array,
    tests.compile_time,
    tests.decode,
    tests.encode,
    tests.encode_decode,
    tests.enums,
    tests.example,
    tests.nested,
    tests.pointers,
    tests.protocol_unit,
    tests.property,
    tests.range,
    tests.reset,
    tests.static_array,
    tests.structs,
    tests.utils,
);

shared static this() {
    import core.runtime: Runtime;

    Runtime.moduleUnitTester = () => true;
}

int main() {
    size_t total;
    size_t failed;
    string[] messages;
    static foreach (module_; allModules)
        runModuleTests!module_(total, failed, messages);

    writeln(total, " test(s) run, ", failed, " failed.");
    if(messages.length) stderr.writeln(messages.join("------\n"));
    return failed == 0 ? 0 : 1;
}

private void runModuleTests(alias module_)(ref size_t total, ref size_t failed, ref string[] messages) {
    alias tests = __traits(getUnitTests, module_);
    total += tests.length;

    static foreach (test; tests) {
        try
            test();
        catch (Throwable t) {
            messages ~= t.msg;
            ++failed;
        }
    }
}
