module snakebite.backends.argumentflow;


private:

import snakebite.nativevalue: TypeFacts;
import snakebite.sharedtable: SharedTable;


// The part of one argument that decides which register the System V x86-64
// convention puts it in: how wide it is and which kind of register takes it.
// Anything that is not a scalar or a pointer is `other`: the flow below does
// not know how many registers it takes.
package struct Shape {
    package enum Class : ubyte { integer, sse, other }

    package size_t size;
    package uint alignment;
    package Class class_;

    package TypeFacts facts() const {
        return TypeFacts(size, alignment, false, false);
    }
}


// The parameters of a function type as the frame layout and the convention
// see them, without the context of a delegate. Two functions with equal
// signatures have equal frame offsets for each parameter. `intern` returns
// one object for equal signatures, so a call compares pointers.
package struct Signature {
    package enum Variadic : ubyte { none, c, d }

    package Shape[] parameters;
    package Variadic variadic;

    package static const(Signature)* intern(
        in Shape[] parameters, in Variadic variadic,
    ) {
        auto signature = Signature(parameters.dup, variadic);
        if (auto found = signature in _signatures)
            return found;
        return _signatures.insert(signature, signature);
    }
}

private __gshared SharedTable!(Signature, Signature) _signatures;


// Where a call from the type of a value to a function that the value holds
// puts each argument, and where the function reads each parameter from. The
// two types can differ, because a cast changes the type of the value and not
// the function. The caller puts argument N in the next register of its class
// (or on the stack when the registers are used), and the callee reads its
// parameter M from the register of that class with the same number, so a
// parameter reads the argument that has the same register, and not the
// argument that has the same position.
//
// The callee gets the low bytes of the argument. A parameter with no argument
// in its register is not defined on native code. A C-variadic callee reads
// the arguments that no named parameter reads as its variadic arguments.
//
// A parameter that is not a scalar or a pointer takes no register in this
// model. Such a parameter is matched by position and class only, so the
// arguments after it can be wrong when the types classify it differently.
package struct ArgumentFlow {
    private enum integerRegisters = 6;
    private enum floatingRegisters = 8;

    // The parameters of the type of the value, and the arguments that follow
    // them (the variadic arguments of the call).
    package const(Shape)[] declared;
    package const(Shape)[] surplus;
    // The named parameters of the callee.
    package const(Shape)[] callee;
    // Both sides pass a context first, in an integer register.
    package bool context;

    package size_t argumentCount() const {
        return declared.length + surplus.length;
    }

    package Shape argumentAt(in size_t index) const {
        return index < declared.length
            ? declared[index] : surplus[index - declared.length];
    }

    // The argument that the callee parameter `parameter` reads, or
    // `size_t.max` when no argument is in its register.
    package size_t sourceOf(in size_t parameter) const {
        const wanted = locate(callee, null, parameter);
        foreach (index; 0 .. argumentCount)
            if (locate(declared, surplus, index) == wanted)
                return index;
        return size_t.max;
    }

    // The arguments that no named parameter reads, in order.
    package size_t[] unread() const {
        auto result = new size_t[](argumentCount);
        size_t count;
        foreach (index; 0 .. argumentCount) {
            bool isRead;
            foreach (parameter; 0 .. callee.length)
                isRead = isRead || sourceOf(parameter) == index;
            if (!isRead)
                result[count++] = index;
        }
        return result[0 .. count];
    }

    private struct Location {
        enum Kind : ubyte { integer, floating, stack, other }

        Kind kind;
        size_t index;
    }

    private Location locate(
        in Shape[] first, in Shape[] second, in size_t position,
    ) const {
        size_t integers = context ? 1 : 0;
        size_t floats;
        size_t stack;
        const shapeAt = (in size_t index) =>
            index < first.length ? first[index] : second[index - first.length];

        foreach (index; 0 .. position)
            final switch (shapeAt(index).class_) with (Shape.Class) {
            case integer:
                if (integers < integerRegisters)
                    ++integers;
                else
                    ++stack;
                break;
            case sse:
                if (floats < floatingRegisters)
                    ++floats;
                else
                    ++stack;
                break;
            case other:
                break;
            }

        final switch (shapeAt(position).class_) with (Shape.Class) {
        case integer:
            return integers < integerRegisters
                ? Location(Location.Kind.integer, integers)
                : Location(Location.Kind.stack, stack);
        case sse:
            return floats < floatingRegisters
                ? Location(Location.Kind.floating, floats)
                : Location(Location.Kind.stack, stack);
        case other:
            return Location(Location.Kind.other, position);
        }
    }
}
