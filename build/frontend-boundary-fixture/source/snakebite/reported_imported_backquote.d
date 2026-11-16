module snakebite.reported_imported_backquote;
auto f(T)(T t) { return imported!(`dmd.typesem`).mutableOf(t); }
