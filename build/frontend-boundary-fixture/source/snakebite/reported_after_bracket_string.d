module snakebite.reported_after_bracket_string;
enum s = q"[ " ]"; enum t = q"<\"<>>"; enum u = q"{ \" }"; import dmd.typesem: mutableOf;
