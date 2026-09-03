import std.stdio: writeln, stderr;
import std.meta: AliasSeq;
import std.array: join;

static import cerealed;
static import unit_threaded;
static import tests.multidimensional_array;
static import tests.compile_time;
static import tests.property;
static import tests.utils;

alias allModules = AliasSeq!(
    cerealed,
    unit_threaded,
    tests.multidimensional_array,
    tests.compile_time,
    tests.property,
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
