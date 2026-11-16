module snakebite.clean_comments_and_strings;
enum a = "import dmd.typesem;"; enum b = `imported!"dmd.x"`; enum c = r"import dmd.a;";
// import dmd.typesem;
/* import dmd.typesem; */
/+ import dmd.typesem; /+ import dmd.x; +/ import dmd.y; +/
enum d = q"(import dmd.typesem;)"; enum e = q"EOS
import dmd.typesem;
EOS";
enum f = imported!"std.stdio".stdout; enum g = "dmd.typesem"; enum h = imported!("std." "file").exists;
import std.stdio;
