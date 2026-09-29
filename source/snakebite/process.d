// Runtime setup every snakebite host executable shares. Each one links
// this module, so druntime reads these options in each of them: the
// shared druntime finds `rt_options` through the executable's dynamic
// symbol table.
module snakebite.process;


private:


// `gc`: the frontend allocates like dmd does (`snakebite.gc`).
// `cleanup:none`: no collection at exit. The process is about to end and
// the OS takes its memory back; a final collection only costs time.
extern(C) public __gshared string[] rt_options = [
    "gcopt=gc:" ~ imported!"snakebite.gc".gcName ~ " cleanup:none",
];
