module snakebite.backends.assignment;

private:

// D assignment evaluates its value before it publishes bytes to the target.
// Backends provide the storage and byte operations because their execution
// mechanisms are different, but the ordering is one shared rule. The
// callbacks are `scope`, so a backend that passes lambdas allocates no
// closure for them: an assignment can run where the host cannot allocate.
public auto executeAssignment(Target)(
    in bool construction,
    Target target,
    size_t size,
    size_t alignment,
    scope Target delegate(size_t, size_t) reserve,
    scope void delegate(Target) evaluate,
    scope void delegate(Target) publish,
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
