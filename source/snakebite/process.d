// Runtime setup every snakebite host executable shares. Each one links
// this module, so druntime reads these options in each of them: the
// shared druntime finds `rt_options` through the executable's dynamic
// symbol table.
module snakebite.process;


private:


// `gc`: the frontend allocates like dmd does (`snakebite.gc`).
// `cleanup:none`: no collection at exit. The process is about to end and
// the OS takes its memory back; a final collection only costs time.
// `heapSizeFactor:4`: fewer collections. A collection costs about the
// same however little is in the GC heap: a host process registers
// large root ranges (guest frame stacks, callback pools, the loaded
// images' data), and every collection scans them. Measured on `bin/ut
// ut.backends ut.ffi ut.repl ut.frontend` (`--DRT-gcopt=profile:1`): 89
// collections and 35.5 s of GC time with the default factor, 68 and
// 19.1 s with 4.
extern(C) public __gshared string[] rt_options = [
    "gcopt=gc:" ~ imported!"snakebite.gc".gcName
        ~ " cleanup:none heapSizeFactor:4",
];
