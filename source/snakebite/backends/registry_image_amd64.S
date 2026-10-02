/* The bytes of `registry_slot.c`, built as a shared object by the build, for
 * `snakebite.backends.guestmodules` to load. `registry_slot.so` is found
 * through the include path of the assembler.
 */
    .section .rodata
    .globl snakebite_registry_image_start
    .globl snakebite_registry_image_end
snakebite_registry_image_start:
    .incbin "registry_slot.so"
snakebite_registry_image_end:

    .section .note.GNU-stack,"",@progbits
