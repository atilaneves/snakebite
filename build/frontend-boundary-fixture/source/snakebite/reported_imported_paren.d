module snakebite.reported_imported_paren;
auto f(T)(T t) { return imported!("dmd.typesem").mutableOf(t); }
