module snakebite.reported_imported_comment;
auto f(T)(T t) {
    return imported /* a */ ! // b
        /+ c /+ nested +/ d +/ ( /* e */ "dmd.typesem" /* f */ ).mutableOf(t);
}
