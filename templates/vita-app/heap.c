// newlib's malloc arena is carved out of the process budget once at startup and
// never grows. VitaSDK's default is small enough that long runs exhaust it while
// sceKernelGetFreeMemorySize still reports tens of MB free, because that counts
// the process budget and not the arena.
//
// Too large and the block cannot be allocated, so the app never launches. Too
// small and the arena fills mid-run. 160 MB leaves ~50 MB for the memblocks the
// engine allocates separately: the AOT snapshot's VM domain and Skia's surfaces.
unsigned int _newlib_heap_size_user = 160 * 1024 * 1024;
