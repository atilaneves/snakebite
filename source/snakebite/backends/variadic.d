module snakebite.backends.variadic;

private:

import core.internal.vararg.sysv_x64: __va_list_tag;
import snakebite.nativelayout: TypeFacts, alignUp;

// Guest calls have no native argument registers to save. A native va_list
// with exhausted register areas reads all extra arguments from its overflow
// area. The normal druntime va_arg implementation consumes these bytes.
package struct VariadicLayout {
    package alias Cursor = __va_list_tag;
    package size_t[] offsets;
    package size_t size = Cursor.sizeof;
    package uint alignment = Cursor.alignof;
    package size_t argumentsOffset;

    package static VariadicLayout of(in TypeFacts[] arguments) {
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

    package void initialize(ubyte* storage) const {
        auto cursor = cast(Cursor*) storage;
        *cursor = Cursor.init;
        cursor.stack_args = storage + argumentsOffset;
    }
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
}

public size_t nativeCursorSize() {
    import core.internal.vararg.sysv_x64: __va_list_tag;
    return __va_list_tag.sizeof;
}
