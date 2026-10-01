module ut.importc;


// A C file is a root module of a dub project (`sourceFiles`), and D code
// imports it as it imports a D module (ImportC). Each test states the exit
// status of the project's D `main`, which a compiled program gives natively.


import snakebite.backends: backendIdentity;
import std.array: replace;
import std.path: buildPath;
import ut;
import ut.backends;


static foreach (backend; Matrix!()) {
    @("importc.functionCalledFromD." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "function_called_from_d", `
            int add(int a, int b) { return a + b; }
        `, q{
            import CMOD;
            int main() { return add(40, 2); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read a C global, which is a mutable static variable"),
)) {
    @("importc.scalarAndArrayInitialisers." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "scalar_array_init", `
            int scalar = 5;
            double ratio = 0.5;
            int numbers[4] = {1, 2, 3};
            int inferred[] = {10, 20};
            int local(int x) {
                int a[2] = {x, 3};
                return a[0] + a[1];
            }
        `, q{
            import CMOD;
            int main() {
                const ok = scalar == 5 && ratio == 0.5
                    && numbers[0] == 1 && numbers[2] == 3 && numbers[3] == 0
                    && inferred.length == 2 && inferred[1] == 20
                    && local(4) == 7;
                return ok ? 42 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read a C global, which is a mutable static variable"),
)) {
    @("importc.structInitialisers." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "struct_init", `
            struct Point { int x; int y; };
            struct Line { struct Point from; struct Point to; };
            struct Point origin = {1, 2};
            struct Line line = {{1, 2}, {3, 4}};
            struct Line designated = {.to = {.y = 9}, .from = {.x = 7}};
            int sparse[5] = {[3] = 4, [1] = 2};
        `, q{
            import CMOD;
            int main() {
                const ok = origin.x == 1 && origin.y == 2
                    && line.to.x == 3 && line.to.y == 4
                    && designated.from.x == 7 && designated.from.y == 0
                    && designated.to.x == 0 && designated.to.y == 9
                    && sparse[1] == 2 && sparse[3] == 4 && sparse[4] == 0;
                return ok ? 42 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read a C global, which is a mutable static variable"),
)) {
    @("importc.stringAndPointerInitialisers." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "string_pointer_init", `
            const char *greeting = "hello";
            char buffer[8] = "abc";
            int target = 41;
            int *pointer = &target;
            int **pointerToPointer = &pointer;
            int *offset = &target;
        `, q{
            import CMOD;
            int main() {
                *pointer += 1;
                const ok = greeting[0] == 'h' && greeting[4] == 'o'
                    && greeting[5] == 0
                    && buffer[2] == 'c' && buffer[3] == 0
                    && **pointerToPointer == 42 && target == 42
                    && offset is pointer;
                return ok ? target : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read a C global, which is a mutable static variable"),
)) {
    @("importc.staticFunctionAndVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "static_members", `
            static int counter = 40;
            static int bump(void) { return ++counter; }
            int twice(void) { bump(); return bump(); }
        `, q{
            import CMOD;
            int main() { return twice(); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("importc.structByValueAndPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "struct_passing", `
            struct IntAndLong { int a; long b; };
            struct IntAndLong make(int a, long b) {
                struct IntAndLong p = {a, b};
                return p;
            }
            long sum(struct IntAndLong p) { return p.a + p.b; }
            void scale(struct IntAndLong *p, int factor) {
                p->a *= factor;
                p->b *= factor;
            }
        `, q{
            import CMOD;
            int main() {
                auto p = make(3, 4);
                scale(&p, 2);
                return cast(int) (sum(p) + sum(make(10, 18)));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("importc.enumAndTypedef." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "enum_typedef", `
            enum Colour { Red, Green = 10, Blue };
            typedef unsigned char byte_t;
            typedef struct { byte_t lo; byte_t hi; } BytePair;
            enum Colour pick(int i) { return i ? Blue : Green; }
            BytePair pack(byte_t lo, byte_t hi) {
                BytePair p = {lo, hi};
                return p;
            }
        `, q{
            import CMOD;
            int main() {
                const p = pack(20, 11);
                return pick(1) == Blue && pick(0) == Green && Red == 0
                    ? p.lo + p.hi + Blue : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("importc.controlFlow." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "control_flow", `
            int fall(int x) {
                int r = 0;
                switch (x) {
                case 1: r += 1;
                case 2: r += 2; break;
                case 3: r += 4;
                default: r += 8;
                }
                return r;
            }
            int jump(int n) {
                int i = 0;
                loop:
                if (i >= n) goto done;
                i += 2;
                goto loop;
                done:
                return i;
            }
            int commas(void) {
                int a, b;
                a = (b = 3, b + 4);
                return a;
            }
            int total(void) {
                int values[5] = {1, 2, 3, 4, 5};
                int *p = values;
                int sum = 0;
                for (int i = 0; i < 5; i++) sum += *(p + i);
                for (p = values + 4; p != values; p--) sum += *(p - 1);
                return sum;
            }
        `, q{
            import CMOD;
            int main() {
                const ok = fall(1) == 3 && fall(2) == 2 && fall(3) == 12
                    && fall(9) == 8 && jump(5) == 6 && commas() == 7
                    && total() == 25;
                return ok ? 42 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read a C global, which is a mutable static variable"),
)) {
    @("importc.compoundLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "compound_literal", `
            struct Point { int x; int y; };
            int norm1(struct Point p) { return p.x + p.y; }
            int viaLiteral(int a) {
                return norm1((struct Point){a, 2}) + (int[]){1, 2, 3}[2];
            }
            struct Point *global = &(struct Point){40, 2};
            int *array = (int[]){5, 6, 7};
            int viaAddress(void) {
                struct Point *p = &(struct Point){1, 41};
                p->x += 1;
                return p->x + p->y;
            }
        `, q{
            import CMOD;
            int main() {
                return viaLiteral(37) == 42 && global.x + global.y == 42
                    && array[2] == 7 && viaAddress() == 43
                    ? 42 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("importc.genericSelection." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "generic_selection", `
            #define KIND(x) _Generic((x), int: 1, double: 2, default: 3)
            int kinds(void) { return KIND(1) * 100 + KIND(1.0) * 10 + KIND('a'); }
        `, q{
            import CMOD;
            int main() { return kinds() == 121 ? 42 : 1; }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("importc.bitFields." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "bit_fields", `
            struct Flags {
                unsigned a : 3;
                unsigned b : 5;
                int c : 4;
            };
            struct Flags make(void) {
                struct Flags f = {5, 17, -2};
                f.a += 1;
                return f;
            }
            int sizeOfFlags(void) { return sizeof(struct Flags); }
        `, q{
            import CMOD;
            int main() {
                const f = make();
                return f.a == 6 && f.b == 17 && f.c == -2
                    && sizeOfFlags() == Flags.sizeof ? 42 : 1;
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE does not implement C-style variadic functions"),
)) {
    @("importc.variadicDefinedInC." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "variadic_c", `
            #include <stdarg.h>
            int sum(int count, ...) {
                va_list args;
                va_start(args, count);
                int total = 0;
                for (int i = 0; i < count; i++) total += va_arg(args, int);
                va_end(args);
                return total;
            }
        `, q{
            import CMOD;
            int main() { return sum(3, 10, 12, 20); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call `printf`, which has no source code"),
)) {
    @("importc.cCallsPrintf." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        // `printf` returns the count of characters written: "total 42\n".
        9.cProjectStatus!(backend, "c_printf", `
            #include <stdio.h>
            int report(int value) { return printf("total %d\n", value); }
        `, q{
            import CMOD;
            int main() { return report(42); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call `strlen`, which has no source code"),
)) {
    @("importc.systemHeader." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "system_header", `
            #include <string.h>
            int length(const char *text) { return (int) strlen(text); }
        `, q{
            import CMOD;
            int main() { return length("abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("importc.addressOfCFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        42.cProjectStatus!(backend, "function_pointer", `
            int triple(int x) { return 3 * x; }
        `, q{
            import CMOD;
            int main() {
                extern(C) int function(int) pointer = &triple;
                return pointer(14);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot resolve a C declaration to the D definition of the same symbol"),
)) {
    @("importc.cCallsBackD." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
    unittest {
        41.cProjectStatus!(backend, "callback_d", `
            extern int fromD(int);
            int viaC(int x) { return fromD(x) + 1; }
        `, q{
            import CMOD;
            extern(C) int fromD(int x) { return x * 2; }
            int main() { return viaC(20); }
        });
    }
}


// Every test shares one frontend, which merges C structs of the same name
// from different C files, so a struct tag is unique to its test unless the
// definitions agree.


// Builds a dub project whose `source/<name>.c` is `cSource` and whose
// `source/<name>_app.d` is `dSource` (`CMOD` there names the C module),
// and checks the exit status of the D `main`. Natively that is the program `dub build` makes.
// A module name is unique per test: every test shares one frontend.
private void cProjectStatus(backend, string name, string cSource, string dSource)(
    in int expected,
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    import snakebite.backends.backend: run;
    import snakebite.dependencyimage: defaultCompiler;
    import snakebite.execution: prepareProject;
    import std.process: Config, execute;

    enum moduleName = "importc_" ~ name ~ "_" ~ backend.stringof;
    const sandbox = Sandbox();
    sandbox.writeFile("app/dub.sdl", `
        name "importc_project"
        targetType "library"
        mainSourceFile "source/` ~ moduleName ~ `_app.d"
        sourceFiles "source/` ~ moduleName ~ `.c"
        configuration "unittest" {
            targetType "executable"
            targetName "importc_program"
        }
    `);
    sandbox.writeFile("app/source/" ~ moduleName ~ ".c", cSource);
    sandbox.writeFile("app/source/" ~ moduleName ~ "_app.d",
        "module " ~ moduleName ~ "_app;\n" ~ dSource.replace("CMOD", moduleName));
    const directory = sandbox.inSandboxPath("app");

    static if (is(backend == Native)) {
        const build = execute(
            ["dub", "build", "-q", "--config=unittest",
                "--compiler=" ~ defaultCompiler],
            null, Config.none, size_t.max, directory);
        build.status.shouldEqual(0, build.output);
        execute([directory.buildPath("importc_program")])
            .status.shouldEqual(expected, file, line);
    } else {
        auto project = prepareProject(directory).project;
        scope instance = new backend(project.program);
        run(instance, project.program).shouldEqual(expected, file, line);
    }
}
