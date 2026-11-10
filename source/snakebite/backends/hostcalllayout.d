module snakebite.backends.hostcalllayout;

// No frontend import here: the bytecode VM imports this module and must
// compile without the DMD frontend import paths.

private:

import snakebite.exception: SnakebiteException;

// Where a host caller writes the arguments of a compiled function: the
// frame offset and width of each declared parameter, of the hidden `this`
// and of the C-variadic cursor and types. It holds no frontend data, so a
// compiled function carries it.
package struct HostCallLayout {
    package struct Argument {
        package size_t offset;
        package size_t width;
    }

    // How errors name the function.
    package string name;
    package Argument[] parameters;
    package bool hasHiddenThis;
    package Argument hiddenThis;
    // `size_t.max` unless the function reads that variadic slot.
    package size_t variadicCursor = size_t.max;
    package size_t variadicTypes = size_t.max;

    package void checkArgumentCount(
        in size_t argumentCount, in string backendName,
    ) const {
        checkArgumentCountRule(
            argumentCount, parameters.length, hasHiddenThis, name,
            backendName);
    }
}

// The one host-to-guest argument-count rule, shared by both backends'
// one entry point apiece (a program's top-level `Backend.call` and a
// callback's re-entry send `args` through the same check): the count
// must be one slot per declared parameter, plus one more when there is
// a hidden `this` - that slot holds the context word's own address,
// first, the same as `CallPlan.call` and a callback's own `addresses`
// already order it. A count short by exactly that one slot gets the
// specific "no context" message; every other mismatch gets the generic
// one. `backendName` names the caller in both messages. `name` is read
// only to build a message.
package void checkArgumentCountRule(
    in size_t argumentCount, in size_t declared, in bool hasHiddenThis,
    lazy const(char)[] name, in string backendName,
) {
    import std.conv: text;

    const required = declared + (hasHiddenThis ? 1 : 0);
    if (argumentCount == required)
        return;

    if (hasHiddenThis && argumentCount == declared)
        throw new SnakebiteException(
            text(backendName, " cannot run `", name,
                "`: the host passed no context for its hidden `this`"),
        );

    throw new SnakebiteException(
        text(backendName, " expected ", required,
            " host-to-guest argument(s) for `", name, "`, got ",
            argumentCount),
    );
}
