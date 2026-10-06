/* The ELF image that `snakebite.backends.guestmodules` registers a guest
 * program's `ModuleInfo` records under. druntime keys a registration by the
 * address of a slot that lies inside an ELF image, so each registration
 * needs an image of its own; this one holds nothing else. It has no D
 * module, so no compiler registers a second set of records for it. It has
 * no code: when a registration ends, druntime runs the finalizers of every
 * code segment of the image, and that search is not safe while another
 * thread makes an object (`SnakebiteGC.runFinalizers`). The
 * build makes it with the system C compiler and links its bytes into every
 * target (`registry_image_amd64.S`), so no compiler runs at run time.
 */
void *snakebite_registry_slot;
