module snakebite.backends.assignment;

private:

// D assignment evaluates its value before it publishes bytes to the target.
// Backends provide the storage and byte operations because their execution
// mechanisms are different, but the ordering is one shared rule.
public auto executeAssignment(Target, alias reserve, alias evaluate,
    alias publish)(
    in bool construction,
    Target target,
    size_t size,
    size_t alignment,
) {
    if (construction) {
        evaluate(target);
        return target;
    }
    auto value = reserve(size, alignment);
    evaluate(value);
    publish(value);
    return value;
}
