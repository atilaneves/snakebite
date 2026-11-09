module ut.backends.bytecode.imagea;

import ut;
import snakebite.backends.bytecode.imagea:
    saveImageA, loadImageA, runImageA, saveImageBundleA, loadImageBundleA;
import snakebite.backends.bytecode.compiler: Bytecode;
import snakebite.backends.bytecode.vm: Function;
import snakebite.backends.backend: Program, Owned;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.file: write, remove;
import std.path: buildPath;
import std.conv: text;
import ut.backends: Matrix, shouldBeRetOf, Omit, Ctfe, Because;
import std.array: join, replace;
import std.range: repeat;
import std.algorithm.searching: count, countUntil;

// Static pointer initializers retain the backing object. The union gives
// the stored descriptors the same native layout as D slices, without CTFE
// making separate literal values for slices of a static array.
private enum dataSource = q{
    static immutable char[7] backing = "abcdef\0";
    union StoredSlice {
        struct Descriptor { size_t length; immutable(char)* ptr; }
        Descriptor descriptor;
        string value;
    }
    struct Views {
        StoredSlice full;
        StoredSlice interior;
        immutable(char)* alias_;
    }
    static immutable Views views = Views(
        StoredSlice(StoredSlice.Descriptor(6, backing.ptr)),
        StoredSlice(StoredSlice.Descriptor(4, backing.ptr + 2)), backing.ptr + 2);
    ulong arithmetic(ulong x, ulong y) {
        auto data = views;
        auto full = data.full.value;
        auto interior = data.interior.value;
        if (full.length != 6 || interior.length != 4
                || full.ptr + 2 !is interior.ptr
                || data.alias_ !is interior.ptr)
            return 0;
        return full.ptr[x % 6] * 1000UL + interior.ptr[y % 4] * 10UL
            + data.alias_[y % 4];
    }
};

private enum nativeSource = "import core.stdc.string: strlen;" ~
    dataSource.replace("return full.ptr[x % 6]", q{
        const fullLength = strlen(full.ptr);
        const interiorLength = strlen(interior.ptr);
        if (fullLength != 6 || interiorLength != 4)
            return 0;
        return fullLength * 1_000_000UL + interiorLength * 100_000UL
            + full.ptr[x % 6]
    });

private enum realSource = q{
    ulong arithmetic(ulong x, ulong y) {
        real value = x;
        return cast(ulong) (value + 1.5L);
    }
};

private enum floatSource = "" ~ realSource.replace("real", "float").replace("1.5L", "1.5f");
private enum doubleSource = "" ~ realSource.replace("real", "double").replace("1.5L", "1.5");

private enum endSource = q{
    static immutable ubyte[3] backing = [1, 2, 3];
    static immutable end = backing.ptr + 3;
    ulong arithmetic(ulong x, ulong y) { return end - backing.ptr; }
};

// Pointer-sized backing storage can end at the next pooled allocation's start.
private enum adjacentEndSource = "" ~ endSource
    .replace("ubyte[3]", "ubyte[8]")
    .replace("[1, 2, 3]", "[1, 2, 3, 4, 5, 6, 7, 8]")
    .replace("+ 3", "+ 8");

private enum regressionSource(string fixture) = fixture == "real" ? realSource
    : fixture == "float" ? floatSource : fixture == "double" ? doubleSource
    : fixture == "adjacentEnd" ? adjacentEndSource : endSource;
private enum regressionExpected(string fixture) = fixture == "end" ? 3UL : 8UL;

static foreach (fixture; ["real", "float", "double", "end", "adjacentEnd"]) {
    static foreach (Backend; Matrix!()) {
        @("imageA." ~ fixture ~ "Fixture." ~ Backend.stringof)
        unittest {
            regressionExpected!fixture.shouldBeRetOf!(Backend,
                regressionSource!fixture, "arithmetic", 7UL, 11UL);
        }
    }

    @("imageA." ~ fixture ~ "RoundTrip")
    unittest {
        import core.sys.posix.unistd: getpid;
        import core.memory: GC;
        auto module_ = parseSnippet(regressionSource!fixture);
        auto backend = Owned!Bytecode(Program([module_]));
        const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
        const path = buildPath("/tmp/opencode", text("image-a-", fixture, "-", getpid(), ".sbc"));
        write(path, saveImageBundleA([compiled]));
        scope(exit) remove(path);
        const loaded = loadImageBundleA(path);
        GC.collect;
        runImageA(loaded[0], 7, 11).should == regressionExpected!fixture;
        static if (fixture == "real" || fixture == "float" || fixture == "double") {
            write(path, saveImageA(*compiled));
            const direct = loadImageA(path);
            GC.collect;
            runImageA(direct, 7, 11).should == regressionExpected!fixture;
        }
    }
}

private enum typeInfoSource = q{
    struct Saved { ulong value = 73; }
    struct WithPointer { immutable(char)* pointer = "saved".ptr; }
    enum SavedEnum : ulong { value = 29 }
    ulong metadata(ulong x, ulong y) { return cast(ulong) cast(void*) typeid(Saved); }
    ulong arithmetic(ulong x, ulong y) {
        auto first = typeid(Saved);
        auto second = typeid(Saved);
        auto pointer = typeid(Saved*);
        auto array = typeid(Saved[3]);
        auto constant = typeid(const(Saved));
        auto enumeration = typeid(SavedEnum);
        auto integerPointer = typeid(int*);
        auto initial = cast(const(WithPointer)*) typeid(WithPointer).m_init.ptr;
        if (first !is second || pointer.m_next !is first || array.value !is first
                || array.len != 3 || first.m_align != Saved.alignof
                || first.m_init.length != Saved.sizeof || first.mangledName.length == 0
                || constant.base !is first || integerPointer.m_next !is typeid(int)
                || typeid(immutable(Saved)).base !is first
                || typeid(shared(Saved)).base !is first
                || enumeration.base !is typeid(ulong) || enumeration.name.length == 0
                || enumeration.m_init.length != ulong.sizeof
                || *cast(const(ulong)*) enumeration.m_init.ptr != 29
                || initial.pointer[0] != 's' || initial.pointer[4] != 'd'
                || typeid(WithPointer).m_RTInfo is null)
            return 0;
        return *cast(const(ulong)*) first.m_init.ptr + x + y;
    }
};

static foreach (Backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not implement TypeInfo_Pointer.m_next"),
)) {
    @("imageA.typeInfoFixture." ~ Backend.stringof)
    unittest {
        91UL.shouldBeRetOf!(Backend, typeInfoSource, "arithmetic", 7UL, 11UL);
    }
}

@("imageA.typeInfoRoundTrip")
unittest {
    import core.sys.posix.unistd: getpid;
    import core.memory: GC;
    auto module_ = parseSnippet(typeInfoSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    const metadata = backend.compileImageFunction(findFunction(module_, "metadata"));
    const path = buildPath("/tmp/opencode", text("image-a-typeinfo-", getpid(), ".sbc"));
    write(path, saveImageBundleA([compiled, metadata]));
    scope(exit) remove(path);
    const loaded = loadImageBundleA(path);
    GC.collect;
    runImageA(loaded[0], 7, 11).should == 91UL;
    const info = cast(TypeInfo) cast(void*) runImageA(loaded[1], 0, 0);
    (info is cast(TypeInfo) cast(void*) runImageA(loaded[1], 7, 11)).should == true;
    (*cast(const(ulong)*) info.initializer.ptr).should == 73UL;
    (info.toString.length > 0).should == true;
}

@("imageA.missingTypeInfoBinding")
unittest {
    import core.sys.posix.unistd: getpid;
    auto module_ = parseSnippet(typeInfoSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    auto bytes = saveImageBundleA([compiled]);
    enum symbol = "_D15TypeInfo_Struct6__vtblZ";
    const offset = bytes.countUntil(cast(const(ubyte)[]) symbol);
    (offset >= 0).should == true;
    bytes[offset + symbol.length - 1] = 'Q';
    const path = buildPath("/tmp/opencode", text("image-a-typeinfo-missing-", getpid(), ".sbc"));
    write(path, bytes);
    scope(exit) remove(path);
    loadImageBundleA(path).shouldThrowWithMessage(
        "image A cannot resolve process symbol: " ~ symbol[0 .. $ - 1] ~ "Q");
}

static foreach (Backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not permit reading an overlapping union field"),
)) {
    @("imageA.dataFixture." ~ Backend.stringof)
    unittest {
        99122UL.shouldBeRetOf!(Backend, dataSource, "arithmetic", 7UL, 11UL);
    }

    @("imageA.nativeFixture." ~ Backend.stringof)
    unittest {
        6499122UL.shouldBeRetOf!(Backend, nativeSource, "arithmetic", 7UL, 11UL);
    }
}

// Long bodies keep the direct callees deferred, rather than copied into callers.
private enum directSource =
    "ulong leaf(ulong x, ulong y) { ulong a = x + y;"
    ~ "a = (a + y) * 3UL - x;".repeat(80).join
    ~ "return a;}"
    ~ "ulong middle(ulong x, ulong y) { ulong a = leaf(x, y) + leaf(y, x);"
    ~ "a += y;".repeat(80).join ~ "return a;}" ~ q{
    ulong arithmetic(ulong x, ulong y) { return middle(x, y) + middle(y, x); }
};

private ulong directExpected(ulong x, ulong y) {
    ulong a = x + y, b = y + x;
    foreach (i; 0 .. 80) {
        a = (a + y) * 3UL - x;
        b = (b + x) * 3UL - y;
    }
    return 2 * (a + b) + 80 * (x + y);
}

// A cycle must name the same loaded Function, not append another copy forever.
private enum recursiveSource =
    "ulong recurse(ulong x, ulong y) { if (x == 0) return y;"
    ~ "y += 1;".repeat(80).join
    ~ "return recurse(x - 1, y); }"
    ~ "ulong arithmetic(ulong x, ulong y) { return recurse(x, y); }";

static foreach (Backend; Matrix!()) {
    @("imageA.recursiveFixture." ~ Backend.stringof)
    unittest {
        571UL.shouldBeRetOf!(Backend, recursiveSource, "arithmetic", 7UL, 11UL);
    }
}

@("imageA.recursiveRoundTrip")
unittest {
    import core.sys.posix.unistd: getpid;
    auto module_ = parseSnippet(recursiveSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    const path = buildPath("/tmp/opencode", text("image-a-cycle-", getpid(), ".sbc"));
    write(path, saveImageBundleA([compiled]));
    scope(exit) remove(path);
    const loaded = loadImageBundleA(path);
    runImageA(loaded[0], 7, 11).should == 571UL;
    runImageA(loaded[0], 0, 11).should == 11UL;
}

// The child exits after save. It never enters a guest function.
public int saveFixture(in string path, in string fixture) {
    import snakebite.frontend.compiler: initialize, Snippets;
    import std.stdio: writeln;
    initialize(Snippets.yes);
    const source = fixture == "direct" ? directSource
        : fixture == "data" ? dataSource
        : fixture == "native" ? nativeSource
        : fixture == "typeinfo" ? typeInfoSource
        : fixture == "real" ? realSource
        : fixture == "float" ? floatSource
        : fixture == "double" ? doubleSource
        : fixture == "end" ? endSource
        : fixture == "adjacentEnd" ? adjacentEndSource
        : fixture == "recursive" ? recursiveSource : q{
        ulong arithmetic(ulong x, ulong y) {
            ulong a = x + y; ulong b = a * 3UL;
            ulong c = b - x; return c + y;
        }
    };
    auto module_ = parseSnippet(source);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    const before = backend.compilationStatistics.cacheMisses;
    const(Function)*[] roots = [compiled];
    if (fixture == "typeinfo")
        roots ~= backend.compileImageFunction(findFunction(module_, "metadata"));
    write(path, saveImageBundleA(roots));
    const after = backend.compilationStatistics.cacheMisses;
    if (fixture == "direct" || fixture == "recursive")
        assert(after > before);
    writeln("compiled_before=", before, " compiled_after=", after,
        " guest_executions=0 expected=", fixture == "direct"
            ? directExpected(7, 11) : fixture == "recursive" ? 571UL
            : fixture == "data" ? 99122UL
            : fixture == "native" ? 6499122UL
            : fixture == "typeinfo" ? 91UL
            : fixture == "real" || fixture == "float" || fixture == "double"
                || fixture == "adjacentEnd" ? 8UL
            : fixture == "end" ? 3UL : 58UL);
    return 0;
}

@("imageA.dataRoundTrip")
unittest {
    import core.sys.posix.unistd: getpid;
    import core.memory: GC;
    auto module_ = parseSnippet(dataSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    const path = buildPath("/tmp/opencode", text("image-a-data-", getpid(), ".sbc"));
    auto bytes = saveImageBundleA([compiled]);
    const backing = cast(const(ubyte)[]) "abcdef\0";
    bytes.count(backing).should == 1;
    write(path, bytes);
    scope(exit) remove(path);
    const loaded = loadImageBundleA(path);
    GC.collect;
    foreach (x; 0UL .. 6)
        foreach (y; 0UL .. 4)
            runImageA(loaded[0], x, y).should ==
                (97UL + x) * 1000 + (99UL + y) * 11;
    const position = bytes.countUntil(backing);
    bytes[position + 3] = 'X';
    write(path, bytes);
    const changed = loadImageBundleA(path);
    runImageA(changed[0], 3, 1).should == 88_968UL;
}

@("imageA.nativeRoundTrip")
unittest {
    import core.sys.posix.unistd: getpid;
    auto module_ = parseSnippet(nativeSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    const path = buildPath("/tmp/opencode", text("image-a-native-", getpid(), ".sbc"));
    write(path, saveImageBundleA([compiled]));
    scope(exit) remove(path);
    const loaded = loadImageBundleA(path);
    foreach (x; 0UL .. 6)
        foreach (y; 0UL .. 4)
            runImageA(loaded[0], x, y).should ==
                6_400_000UL + (97UL + x) * 1000 + (99UL + y) * 11;
}

@("imageA.missingNativeSymbolAndTruncatedNativeImage")
unittest {
    import core.sys.posix.unistd: getpid;
    auto module_ = parseSnippet(nativeSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    auto bytes = saveImageBundleA([compiled]);
    const path = buildPath("/tmp/opencode", text("image-a-missing-", getpid(), ".sbc"));
    scope(exit) remove(path);
    write(path, bytes[0 .. $ - 1]);
    loadImageBundleA(path).shouldThrowWithMessage("image A truncated function");
    const offset = bytes.countUntil(cast(const(ubyte)[]) "strlen");
    (offset >= 0).should == true;
    bytes[offset .. offset + 6] = cast(const(ubyte)[]) "sbnone";
    write(path, bytes);
    loadImageBundleA(path).shouldThrowWithMessage(
        "image A cannot resolve process symbol: sbnone");
}

static foreach (Backend; Matrix!()) {
    @("imageA.directFixture." ~ Backend.stringof)
    unittest {
        directExpected(7, 11).shouldBeRetOf!(Backend, directSource,
            "arithmetic", 7UL, 11UL);
    }
}

@("imageA.deferredDirectRoundTrip")
unittest {
    import core.sys.posix.unistd: getpid;
    auto module_ = parseSnippet(directSource);
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    const before = backend.compilationStatistics.cacheMisses;
    const bytes = saveImageBundleA([compiled]);
    (backend.compilationStatistics.cacheMisses > before).should == true;
    const path = buildPath("/tmp/opencode", text("image-a-direct-", getpid(), ".sbc"));
    write(path, bytes);
    scope(exit) remove(path);
    const loaded = loadImageBundleA(path);
    loaded.length.should == 1;
    foreach (pair; [[7UL, 11UL], [0UL, 1UL], [ulong.max, 1UL]])
        runImageA(loaded[0], pair[0], pair[1]).should ==
            directExpected(pair[0], pair[1]);
}

static foreach (Backend; Matrix!()) {
    @("imageA.fixture." ~ Backend.stringof)
    unittest {
        58UL.shouldBeRetOf!(Backend, q{
            ulong arithmetic(ulong x, ulong y) {
                ulong a = x + y;
                ulong b = a * 3UL;
                ulong c = b - x;
                return c + y;
            }
        }, "arithmetic", 7UL, 11UL);
    }
}

@("imageA.noProcessAddressIsSaved")
unittest {
    auto module_ = parseSnippet(q{
        module imagea_address;
        __gshared ulong storage;
        ulong arithmetic(ulong x, ulong y) { return storage + x + y; }
    });
    auto backend = Owned!Bytecode(Program([module_]));
    const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
    saveImageA(*compiled).shouldThrowWithMessage(
        "image A instruction holds an address");
}

@("imageA.truncatedFile")
unittest {
    import core.sys.posix.unistd: getpid;
    const path = buildPath("/tmp/opencode", text("image-a-short-", getpid(), ".sbc"));
    write(path, cast(ubyte[]) [1, 2, 3]);
    scope(exit) remove(path);
    loadImageA(path).shouldThrowWithMessage("image A truncated header");
}

@("imageA.arithmeticRoundTrip")
unittest {
    import core.sys.posix.unistd: getpid;
    foreach (count; [0, 1, 16, 256]) {
        string source = text("module imagea", count,
            "; ulong arithmetic(ulong x, ulong y) {")
            ~ "ulong a = x + y; ulong b = a * 3UL; ulong c = b - x; a = c + y;";
        foreach (i; 0 .. count)
            source ~= "a = (a + y) * 3UL - x;";
        source ~= "return a;}";
        auto module_ = parseSnippet(source);
        auto backend = Owned!Bytecode(Program([module_]));
        const compiled = backend.compileImageFunction(findFunction(module_, "arithmetic"));
        const path = buildPath("/tmp/opencode", text("image-a-", getpid(), ".sbc"));
        scope(exit) remove(path);
        write(path, saveImageA(*compiled));
        const loaded = loadImageA(path);
        write(path, saveImageBundleA([compiled, compiled]));
        const bundle = loadImageBundleA(path);
        bundle.length.should == 2;
        foreach (pair; [[7UL, 11UL], [0UL, 1UL], [123UL, 456UL],
                [ulong.max, ulong.max]]) {
            const x = pair[0];
            const y = pair[1];
            ulong expected = (x + y) * 3UL - x + y;
            foreach (i; 0 .. count)
                expected = (expected + y) * 3UL - x;
            runImageA(*compiled, x, y).should == expected;
            runImageA(loaded, x, y).should == expected;
            foreach (ref function_; bundle)
                runImageA(function_, x, y).should == expected;
        }
    }
}
