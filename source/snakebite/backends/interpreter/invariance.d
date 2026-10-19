module snakebite.backends.interpreter.invariance;

// Throwaway prototype: records the facts the evaluator derives for each dmd
// node on every execution and counts disagreements with the first execution.
// Never allocates from the GC: the evaluator runs inside GC finalizers.
package:

import core.stdc.stdio: FILE, fopen, fprintf, fclose, snprintf;
import core.stdc.stdlib: getenv, malloc, calloc, free, realloc;
import core.stdc.string: memset, strlen, strdup;
import core.sys.posix.pthread;
import dmd.location: Loc;

struct Fact {
    ulong[12] w;
}

enum kinds = 512;
enum categories = 6; // fact, mode, parent, function, callee, other
enum exampleSize = 600;

struct Entry {
    const(void)* node;
    Fact[2] fact;
    ubyte seen;
    ulong[2] execs;
    const(void)* parent;
    int parentKind;
    Loc parentLoc;
    const(void)* function_;
    int kindIndex;
    Loc loc;
    ulong callee;
    bool hasCallee;
    bool initialized;
    bool sharedNode;
    char* text;
}

struct KindStats {
    ulong nodes, execs, factMis, modeMis, parentMis, funcMis, bothModes, calleeMis, factMisUnshared, ownTypeMis;
    ulong[12] wordMis;
}

__gshared Entry* tableData;
__gshared size_t tableCapacity, tableCount;
__gshared KindStats[kinds] stats;
__gshared char[exampleSize][categories][kinds] examples;
__gshared bool[categories][kinds] hasExample;
__gshared ulong[8] calleeForm;
__gshared pthread_mutex_t mutex;

shared static ~this() {
    dump;
}

struct StackState {
    const(void)** data;
    size_t length, capacity;
}
StackState stack;

void push(const(void)* node) {
    if (stack.length == stack.capacity) {
        stack.capacity = stack.capacity ? stack.capacity * 2 : 256;
        stack.data = cast(const(void)**) realloc(stack.data, stack.capacity * (void*).sizeof);
    }
    stack.data[stack.length++] = node;
}

void pop() { stack.length--; }
void barrier() { push(null); }
const(void)* parentOf() { return stack.length ? stack.data[stack.length - 1] : null; }

string enumName(E)(int value) {
    foreach (member; __traits(allMembers, E))
        if (value == cast(int) __traits(getMember, E, member))
            return member;
    return "?";
}

int kindIndex(bool isStatement, int kind) {
    return (isStatement ? 256 : 0) + (kind & 255);
}

const(char)* kindNameZ(int index) {
    import dmd.tokens: EXP;
    import dmd.astenums: STMT;
    static char[64][kinds] names;
    auto n = index >= 256 ? enumName!STMT(index - 256) : enumName!EXP(index);
    snprintf(names[index].ptr, 64, "%s:%.*s", index >= 256 ? "S".ptr : "E".ptr,
        cast(int) n.length, n.ptr);
    return names[index].ptr;
}

Entry* find(const(void)* node, bool create) {
    if (tableCapacity == 0 || tableCount * 2 >= tableCapacity)
        grow;
    size_t mask = tableCapacity - 1;
    size_t i = ((cast(size_t) node >> 3) * 0x9E3779B97F4A7C15UL >> 20) & mask;
    while (tableData[i].node !is null) {
        if (tableData[i].node is node)
            return &tableData[i];
        i = (i + 1) & mask;
    }
    if (!create)
        return null;
    tableData[i].node = node;
    tableCount++;
    return &tableData[i];
}

void grow() {
    auto old = tableData;
    const oldCapacity = tableCapacity;
    tableCapacity = oldCapacity ? oldCapacity * 2 : 1 << 16;
    tableData = cast(Entry*) calloc(tableCapacity, Entry.sizeof);
    tableCount = 0;
    foreach (i; 0 .. oldCapacity)
        if (old[i].node !is null) {
            auto e = find(old[i].node, true);
            *e = old[i];
        }
    free(old);
}

void example(int kind, int category, const(char)* text) {
    if (hasExample[kind][category])
        return;
    hasExample[kind][category] = true;
    snprintf(examples[kind][category].ptr, exampleSize, "%s", text);
}

const(char)* locz(Loc l) {
    return l.toChars;
}

void factText(char* buffer, size_t n, ref const Fact f) {
    snprintf(buffer, n, "[%llx %llx %llx %llx %llx %llx | %llu %llx %llx %llx %llx %llx]",
        f.w[0], f.w[1], f.w[2], f.w[3], f.w[4], f.w[5], f.w[6], f.w[7], f.w[8],
        f.w[9], f.w[10], f.w[11]);
}

void record(
    const(void)* node, bool isStatement, int kind, size_t mode,
    Loc loc, ref Fact fact, const(void)* function_, const(void)* parent,
    int parentKindIndex,
) {
    pthread_mutex_lock(&mutex);
    scope(exit) pthread_mutex_unlock(&mutex);
    const ki = kindIndex(isStatement, kind);
    auto s = &stats[ki];
    auto before = tableCount;
    auto entry = find(node, true);
    if (!entry.initialized) {
        entry.initialized = true;
        entry.kindIndex = ki;
        entry.loc = loc;
        entry.parent = parent;
        entry.parentKind = parentKindIndex;
        entry.parentLoc = loc;
        entry.function_ = function_;
        char[100] tb;
        tb[0] = 0;
        import core.memory: GC;
        if (!isStatement && !GC.inFinalizer)
            nodeText(tb.ptr, tb.length, node, isStatement);
        entry.text = strdup(tb.ptr);
        s.nodes++;
    }
    s.execs++;
    entry.execs[mode]++;
    const other = 1 - mode;
    char[300] a, b;
    char[600] text;
    if (!(entry.seen & (1 << mode))) {
        entry.seen |= 1 << mode;
        entry.fact[mode] = fact;
        if (entry.seen & (1 << other)) {
            s.bothModes++;
            if (entry.fact[other] != fact) {
                s.modeMis++;
                factText(a.ptr, a.length, entry.fact[other]);
                factText(b.ptr, b.length, fact);
                snprintf(text.ptr, text.length, "%s mode%d=%s mode%d=%s", locz(loc),
                    cast(int) other, a.ptr, cast(int) mode, b.ptr);
                example(ki, 1, text.ptr);
            }
        }
    } else if (entry.fact[mode] != fact) {
        s.factMis++;
        if (!entry.sharedNode && entry.parent is parent && entry.function_ is function_)
            s.factMisUnshared++;
        foreach (i; 0 .. 12)
            if (entry.fact[mode].w[i] != fact.w[i])
                s.wordMis[i]++;
        if ((entry.fact[mode].w[3] >> 8) != (fact.w[3] >> 8) || entry.fact[mode].w[4] != fact.w[4]
                || entry.fact[mode].w[5] != fact.w[5]) {
            s.ownTypeMis++;
            factText(a.ptr, a.length, entry.fact[mode]);
            factText(b.ptr, b.length, fact);
            snprintf(text.ptr, text.length, "%s first=%s now=%s", locz(loc), a.ptr, b.ptr);
            example(ki, 5, text.ptr);
        }
        factText(a.ptr, a.length, entry.fact[mode]);
        factText(b.ptr, b.length, fact);
        snprintf(text.ptr, text.length, "%s first=%s now=%s", locz(loc), a.ptr, b.ptr);
        example(ki, 0, text.ptr);
    }
    if (entry.parent !is parent) {
        s.parentMis++;
        auto q = entry.parent is null ? null : find(entry.parent, false);
        auto p = parent is null ? null : find(parent, false);
        snprintf(text.ptr, text.length, "%s parents %s@%s vs %s@%s", locz(loc),
            q ? kindNameZ(q.kindIndex) : "root".ptr,
            q ? locz(q.loc) : "-".ptr,
            p ? kindNameZ(p.kindIndex) : "root".ptr,
            p ? locz(p.loc) : "-".ptr);
        if (!hasExample[ki][2]) {
            const(char)* t1 = entry.text, t2 = q ? q.text : "", t3 = p ? p.text : "";
            const len = cast(int) strlen(text.ptr);
            snprintf(text.ptr + len, text.length - len, " node=`%s` first=`%s` now=`%s`", t1, t2, t3);
        }
        example(ki, 2, text.ptr);
        entry.parent = parent;
        entry.sharedNode = true;
    }
    if (entry.function_ !is function_) {
        s.funcMis++;
        if (!hasExample[ki][3]) {
            import dmd.func: FuncDeclaration;
            auto a_ = cast(FuncDeclaration) cast(void*) entry.function_;
            auto b_ = cast(FuncDeclaration) cast(void*) function_;
            snprintf(text.ptr, text.length, "%s first=%s (%s) now=%s (%s)", locz(loc),
                a_ is null ? "-".ptr : a_.toPrettyChars, a_ is null ? "-".ptr : a_.loc.toChars,
                b_ is null ? "-".ptr : b_.toPrettyChars, b_ is null ? "-".ptr : b_.loc.toChars);
            example(ki, 3, text.ptr);
        }
        entry.function_ = function_;
        entry.sharedNode = true;
    }
}

void recordCallee(const(void)* call, int form, const(void)* callee, Loc loc) {
    pthread_mutex_lock(&mutex);
    scope(exit) pthread_mutex_unlock(&mutex);
    auto e = find(call, true);
    if (!e.hasCallee) {
        e.hasCallee = true;
        e.callee = cast(ulong) callee;
    } else if (e.callee != cast(ulong) callee) {
        e.callee = cast(ulong) callee;
        calleeForm[form]++;
        char[300] text;
        snprintf(text.ptr, text.length, "form%d %s", form, locz(loc));
        example(kindIndex(false, cast(int) imported!"dmd.tokens".EXP.call), 4, text.ptr);
    }
}


void dump() {
    auto path = getenv("INV_OUT");
    if (path is null)
        return;
    pthread_mutex_lock(&mutex);
    auto f = fopen(path, "a");
    if (f is null)
        return;
    ulong nodes, execs;
    foreach (k; 0 .. kinds) {
        auto s = stats[k];
        if (s.execs == 0 && !hasExample[k][4])
            continue;
        nodes += s.nodes;
        execs += s.execs;
        fprintf(f, "K\t%s\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\n",
            kindNameZ(k), s.nodes, s.execs, s.factMis, s.modeMis, s.parentMis,
            s.funcMis, s.bothModes, s.factMisUnshared);
        fprintf(f, "O\t%s\t%llu\n", kindNameZ(k), s.ownTypeMis);
        fprintf(f, "W\t%s", kindNameZ(k));
        foreach (i; 0 .. 12)
            fprintf(f, "\t%llu", s.wordMis[i]);
        fprintf(f, "\n");
        foreach (c; 0 .. categories)
            if (hasExample[k][c])
                fprintf(f, "X\t%s\t%d\t%s\n", kindNameZ(k), c, examples[k][c].ptr);
    }
    foreach (form, n; calleeForm)
        if (n)
            fprintf(f, "C\t%d\t%llu\n", cast(int) form, n);
    fprintf(f, "T\t%llu\t%llu\n", nodes, execs);
    fclose(f);
    pthread_mutex_unlock(&mutex);
}

void nodeText(char* buffer, size_t n, const(void)* node, bool isStatement) {
    import dmd.expression: Expression;
    import dmd.statement: Statement;
    const(char)* t = isStatement
        ? (cast(Statement) cast(void*) node).toChars : (cast(Expression) cast(void*) node).toChars;
    snprintf(buffer, n, "%s", t);
}
