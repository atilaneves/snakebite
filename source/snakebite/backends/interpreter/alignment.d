module snakebite.backends.interpreter.alignment;


private:


// dmd's default field-alignment rule (`aggregate.alignmember`, the same
// one it uses to lay out a struct's fields), rather than reimplementing
// it: no generic round-up-to-alignment helper exists anywhere else in the
// dmd frontend sources. Parameter frame offsets are ordinarily assigned
// far downstream of this, in dmd's machine-code backend, which this
// project does not use - laying out frames here is unavoidable, not a
// case of redoing work dmd already did for us at this stage.
package size_t alignUp(in size_t offset, in uint alignment) {
    import dmd.aggregate: alignmember;

    return alignmember(defaultAlignment, alignment, cast(uint) offset);
}

// `alignmember` takes a `structalign_t` for cases with an explicit
// `align(N)`; there is none here, so `defaultAlignment` is always the
// type's own natural alignment - and it is built once at module load,
// not on every call, since this runs on every parameter offset and every
// frame stack push.
private imported!"dmd.astenums".structalign_t defaultAlignment;

shared static this() {
    defaultAlignment.setDefault;
}
