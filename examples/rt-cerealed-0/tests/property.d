module tests.property;

import cerealed;
import unit_threaded;
import std.meta: AliasSeq;


static foreach(T; AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong,
                            float, double,
                            char, wchar, dchar,
                            ubyte[], ushort[], int[], long[], float[], double[]))
@("roundtrip." ~ T.stringof)
unittest {
    check!((T val) => val.cerealise.decerealise!T == val);
}


@("nonzero dynamic array roundtrip")
@safe unittest {
    const original = [ubyte(17), ubyte(31), ubyte(47)];
    auto cerealiser = Cerealiser();
    cerealiser.grain(original);

    assert(cerealiser.bytes.length == size_t.sizeof + original.length);
    const decoded = cerealiser.bytes.decerealise!(ubyte[]);
    assert(decoded == original);
}


@("array with non-default length type")
@safe unittest {
    check!((ubyte[] arr) {
        if(arr.length > ubyte.max) {
            return true;
        }
        auto enc = Cerealiser();
        enc.grain!ubyte(arr);
        enc.bytes.length.shouldEqual(arr.length + ubyte.sizeof);
        auto dec = Decerealiser(enc.bytes);
        ubyte[] arr2;
        dec.grain!ubyte(arr2);
        return arr2 == arr;
    });
}
