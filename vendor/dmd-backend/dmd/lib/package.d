// Minimal stub for dmd.lib to satisfy linker references from dmd.glue.
// generateCodeAndWrite only uses Library when writeLibrary=true; DmdCodegen
// always passes writeLibrary=false, so these methods are unreachable at runtime.
module dmd.lib;

import dmd.common.outbuffer;
import dmd.errorsink;
import dmd.location;
import dmd.target : Target;

class Library
{
    const(char)[] lib_ext;
    const(char)[] filename;
    ErrorSink eSink;

    static Library factory(
        Target.ObjectFormat of,
        const char[] lib_ext,
        ErrorSink eSink,
    ) {
        assert(false, "dmd.lib.Library.factory: writeLibrary path must not be reached");
    }

    abstract void addObject(const(char)[] module_name, const ubyte[] buf);

    abstract void writeLibToBuffer(ref OutBuffer libbuf);

    final void setFilename(const char[] filename) {
        this.filename = filename;
    }
}
