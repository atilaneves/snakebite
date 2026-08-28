import std.stdio: writeln;
import std.meta: AliasSeq;

static import rt_simple;
static import rt_simple.cereal;
static import unit_threaded;
static import ut.property;

alias allModules = AliasSeq!(
    rt_simple,
    rt_simple.cereal,
    unit_threaded,
    ut.property,
);

shared static this() {
    import core.runtime: Runtime;

    Runtime.moduleUnitTester = () => true;
}

int main() {
    size_t total;
    size_t failed;
    static foreach (module_; allModules)
        runModuleTests!module_(total, failed);

    writeln(total, " test(s) run, ", failed, " failed.");
    return failed == 0 ? 0 : 1;
}

private void runModuleTests(alias module_)(ref size_t total, ref size_t failed) {
    alias tests = __traits(getUnitTests, module_);
    total += tests.length;

    static foreach (test; tests) {
        try
            test();
        catch (Throwable)
            ++failed;
    }
}
