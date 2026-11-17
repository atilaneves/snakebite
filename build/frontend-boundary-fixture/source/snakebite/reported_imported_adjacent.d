module snakebite.reported_imported_adjacent;
auto f(T)(T t) { return imported!("dmd." "typesem").mutableOf(t); }
