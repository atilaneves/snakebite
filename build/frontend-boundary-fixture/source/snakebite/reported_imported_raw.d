module snakebite.reported_imported_raw;
auto f(T)(T t) { return imported!(r"dmd.typesem").mutableOf(t); }
