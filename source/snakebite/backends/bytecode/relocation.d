module snakebite.backends.bytecode.relocation;


private:


import snakebite.native.address: Target;
public import snakebite.native.classification;


// What a compiled function needs to know about every word that holds an
// address of this process. A stored image has to load into a process whose
// addresses differ, so each such word names the thing it points at. This
// module imports nothing of the frontend: the VM compiles without it.
//
// A word that holds code of the host executable (the handler of an
// instruction, the entry of a builtin call, the action of a halting check) has
// no `Reloc`: the compiler writes it and the file holds it as a distance from
// one handler, and a field of that kind says so with `hostCode`.

public struct Reloc {
    public Place place;
    public Target target;
}

static assert(Reloc.sizeof == 56, "a function keeps one Reloc for each address");


// Calls `visit` with each field of `record` that holds an address, and its
// word.
public void eachRelocated(T)(
    ref const T record, scope void delegate(in Relocated, size_t) visit,
) {
    import std.traits: FieldNameTuple, Unqual;

    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        alias Field = typeof(T.tupleof[index]);
        static if (is(typeof(classification) == Relocated)) {
            static assert(Field.sizeof == size_t.sizeof);
            visit(classification,
                cast(size_t) cast(const(void)*) record.tupleof[index]);
        }
        else static if (is(typeof(classification) == Plain)
                && isClassified!(Unqual!Field))
            eachRelocated(record.tupleof[index], visit);
    }}
}

// The word of the field of `record` that is relocated at `field`, or null
// when `record` has no such field.
public inout(size_t)* relocatedWord(T)(
    ref inout T record, in Place.Field field,
) {
    import std.traits: FieldNameTuple, Unqual;

    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        alias Field = typeof(T.tupleof[index]);
        static if (is(typeof(classification) == Relocated)) {
            if (classification.field == field)
                return cast(inout(size_t)*) &record.tupleof[index];
        } else static if (is(typeof(classification) == Plain)
                && isClassified!(Unqual!Field)) {
            if (auto word = relocatedWord(record.tupleof[index], field))
                return word;
        }
    }}
    return null;
}
