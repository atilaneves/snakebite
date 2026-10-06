// A shared object with C symbols that the tests of the symbol lookup and of
// the project image cache load. `bin/ut`'s build makes it; no test makes it.
int retainedAnswer(void) { return 381; }
int threadRetainedAnswer(void) { return 381; }
int snakebite_symbol_dual_definition_test(void) { return 511; }
int snakebite_symbol_independent_only_test(void) { return 522; }
#include <setjmp.h>

int snakebite_internal_setjmp_test(void) {
    jmp_buf buffer;
    int jumped = setjmp(buffer);
    if (jumped == 0)
        longjmp(buffer, 42);
    return jumped;
}
