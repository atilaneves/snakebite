module snakebite.reported_imported_delimited;
auto f(T)(T t) { return imported!(q"(dmd.typesem)").mutableOf(t); }
