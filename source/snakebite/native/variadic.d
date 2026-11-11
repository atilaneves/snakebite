module snakebite.native.variadic;

private:

import core.internal.vararg.sysv_x64: __va_list_tag;
import snakebite.native.value: TypeFacts, alignUp;

// Compiled code starts a `va_list` again from the state its prologue saved.
// A cursor is followed by a copy of its first state for the same purpose.
// `save` writes that copy and `restore` reads it; a backend that builds a
// cursor with its own instructions takes `offset` and `size` from here.
package(snakebite) struct FirstState {
    package(snakebite) alias Cursor = __va_list_tag;
    package(snakebite) enum offset = Cursor.sizeof;
    package(snakebite) enum size = Cursor.sizeof;

    package(snakebite) static void save(Cursor* cursor) nothrow @nogc {
        *(cursor + 1) = *cursor;
    }

    package(snakebite) static void restore(Cursor* cursor) nothrow @nogc {
        *cursor = *(cursor + 1);
    }
}

// Guest calls have no native argument registers to save. A native va_list
// with exhausted register areas reads all extra arguments from its overflow
// area. The normal druntime va_arg implementation consumes these bytes.
package(snakebite) struct VariadicLayout {
    package(snakebite) alias Cursor = __va_list_tag;
    package(snakebite) size_t[] offsets;
    package(snakebite) size_t size = FirstState.offset + FirstState.size;
    package(snakebite) uint alignment = Cursor.alignof;
    package(snakebite) size_t argumentsOffset;

    package(snakebite) static VariadicLayout of(in TypeFacts[] arguments) {
        VariadicLayout result;
        foreach (facts; arguments)
            if (facts.alignment > result.alignment)
                result.alignment = facts.alignment;
        result.argumentsOffset = alignUp(result.size, result.alignment);
        result.size = result.argumentsOffset;
        foreach (facts; arguments) {
            const alignment = facts.alignment < 8 ? 8 : facts.alignment;
            const offset = alignUp(result.size, alignment);
            result.offsets ~= offset;
            result.size = offset + alignUp(facts.size, 8);
        }
        return result;
    }

    package(snakebite) void initialize(ubyte* storage) const {
        auto cursor = cast(Cursor*) storage;
        *cursor = Cursor.init;
        cursor.stack_args = storage + argumentsOffset;
        FirstState.save(cursor);
    }
}

// What compiled code does for `core.stdc.stdarg.va_start`: the intrinsic
// ignores its last named parameter and makes `list` the function's own
// cursor, restored to its first state.
public void startVariadic(void* list, void* cursor) nothrow @nogc {
    FirstState.restore(cast(__va_list_tag*) cursor);
    *cast(void**) list = cursor;
}

public void initializeNativeCursor(
    void* storage,
    uint integerOffset,
    uint floatingOffset,
    void* overflowArea,
    void* registerArea,
) {
    import core.internal.vararg.sysv_x64: __va_list_tag;

    auto cursor = cast(__va_list_tag*) storage;
    *cursor = __va_list_tag.init;
    cursor.offset_regs = integerOffset;
    cursor.offset_fpregs = floatingOffset;
    cursor.stack_args = overflowArea;
    cursor.reg_args = registerArea;
    FirstState.save(cursor);
}

public size_t nativeCursorSize() {
    import core.internal.vararg.sysv_x64: __va_list_tag;
    return FirstState.offset + FirstState.size;
}
