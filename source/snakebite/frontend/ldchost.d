/// The two answers that LDC's frontend takes from LLVM when it evaluates
/// `__traits(targetCPU)` and `__traits(targetHasFeature)`. Here the compiler
/// that builds this binary gives them, because the frontend must answer as
/// that compiler does.
module snakebite.frontend.ldchost;

private:

version (LDC):

import gen.ldctraits: Dstring;
import std.string: splitLines;

// The names of `ldc2 -mattr=help`, written by the build.
enum featureNames = import("snakebite_host_features.txt").splitLines;

static immutable hostCPU = __traits(targetCPU);

extern (C++) public Dstring traitsGetTargetCPU() {
    return Dstring(hostCPU.length, hostCPU.ptr);
}

extern (C++) public bool traitsTargetHasFeature(Dstring feature) {
    switch (feature.ptr[0 .. feature.length]) {
        static foreach (name; featureNames)
            case name: return __traits(targetHasFeature, name);
        default: return false;
    }
}
