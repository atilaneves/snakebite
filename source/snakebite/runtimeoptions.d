// The druntime options of every host executable. Each host executable
// links all of `source`, so this one definition reaches every one of
// them; no main defines its own.
module snakebite.runtimeoptions;


private:


// Every host executable runs the dmd frontend, and its heap is mostly
// the AST, which lives until exit.
//
// `heapSizeFactor:4`: the default heap-to-used ratio (2.0) triggers a
// collection on almost every pool growth while the AST accumulates.
// Measured on `bin/ut` (3 runs each, default -j, `--DRT-gcopt=profile:1`):
// the default does 88 collections for 19.6 s of total GC time;
// `heapSizeFactor:4` does 76 for 17.3 s, a repeated wall-time win
// (paired runs, same load: -4 s to -9 s) with only a modest heap
// increase (287 MB -> 376 MB).
//
// `cleanup:none`: by default druntime collects the whole heap at exit,
// only to find garbage that the OS reclaims anyway. Measured on
// `bin/sb-repl --dub cerealed -c 1`: 205 ms from main returning to
// `exit_group`, 3 ms without that collection.
extern(C) public __gshared string[] rt_options = [
    "gcopt=heapSizeFactor:4 cleanup:none",
];
