/* Fallback definition of `dmd.astenums.Edition.init` - see
 * `source/dmd/iasm/package.d`'s own comment for why one is needed at
 * all: dmd:lexer 2.113.0 references `Edition.init` without always
 * emitting it.
 *
 * Whether `dmd:frontend`'s own `astenums.d` ends up linked - and so
 * emits the real, strong `_D3dmd8astenums7Edition6__initZ` itself - is
 * decided per target by ordinary "does anything else in this link need
 * a symbol only that object provides" archive pulling, which can change
 * whenever unrelated code elsewhere in the same translation unit
 * changes what it references, with no relation to this shim at all. A
 * plain (`pragma(mangle)`-declared) D global cannot be marked weak, so
 * whenever the real definition also gets linked, two strong
 * definitions of the same symbol collide at link time. Assembling this
 * one as `.weak` - like the FFI call stub and the interpreter's
 * native-stack switch are assembled rather than declared in D, for
 * their own reasons - lets the real definition win silently whenever
 * it is present, and this one stand in exactly as before whenever it
 * is not.
 */

#if !(defined(__x86_64__) && defined(__linux__))
#error "_D3dmd8astenums7Edition6__initZ fallback is implemented for Linux x86-64 only"
#endif

    .section .data._D3dmd8astenums7Edition6__initZ,"aw",@progbits
    .weak   _D3dmd8astenums7Edition6__initZ
    .type   _D3dmd8astenums7Edition6__initZ, @object
    .align  2
    .size   _D3dmd8astenums7Edition6__initZ, 2
_D3dmd8astenums7Edition6__initZ:
    .short  2023

    .section .note.GNU-stack,"",@progbits
