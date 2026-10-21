/* The ELF image that `snakebite.backends.guestmodules` registers a guest
 * program's `ModuleInfo` records under. druntime keys a registration by the
 * address of a slot that lies inside an ELF image, so each registration
 * needs an image of its own; this one holds nothing else. It has no D
 * module, so no compiler registers a second set of records for it. The
 * build makes it with the system C compiler and links its bytes into every
 * target (`registry_image_amd64.S`), so no compiler runs at run time.
 *
 * The image holds no code, and the build removes the empty code section, so
 * it has no executable segment. When druntime removes a registration, it
 * reads the first word of every block in the GC heap that has a finalizer,
 * once for each executable segment of the image. Another thread can then be
 * between `GC.malloc` and the copy of the initial bytes of a class instance,
 * and the first word of that block can hold anything.
 */
void *snakebite_registry_slot;
