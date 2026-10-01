module snakebite.backends.slicecopy;


private:


// What dmd's glue layer (`e2ir.d`) checks before `to[] = from[]` copies:
// the lengths are equal and the two do not overlap. Both arguments are
// native dynamic arrays whose `length` counts elements of `elementSize`
// bytes, which is why they are `void[]` only for their layout.
public bool slicesConform(
    in void[] to,
    in void[] from,
    in size_t elementSize,
) @trusted nothrow @nogc pure {
    if (to.length != from.length)
        return false;

    const bytes = to.length * elementSize;
    const toStart = cast(size_t) to.ptr;
    const fromStart = cast(size_t) from.ptr;

    return toStart + bytes <= fromStart || fromStart + bytes <= toStart;
}

// The copy with no check, which is all dmd compiles where bounds are not
// checked: `to.length` elements.
public void copyUnchecked(
    void[] to,
    in void[] from,
    in size_t elementSize,
) @trusted nothrow @nogc {
    import core.stdc.string: memcpy;

    memcpy(to.ptr, from.ptr, to.length * elementSize);
}
