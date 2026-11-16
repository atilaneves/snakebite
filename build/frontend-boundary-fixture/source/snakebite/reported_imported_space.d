module snakebite.reported_imported_space;
auto f(T)(T t) { return imported ! ( "dmd.typesem" ) .mutableOf(t); }
