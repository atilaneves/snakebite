module snakebite.reported_after_paren_string;
enum s = q"(a " quote (nested) )"; import dmd.typesem: mutableOf;
