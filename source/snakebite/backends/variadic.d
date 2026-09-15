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
