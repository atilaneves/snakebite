module snakebite.reported_imported_raw_bang;
auto f(T)(T t) { return imported!r"dmd.typesem".mutableOf(t); }
