// GPU memory: memblocks mapped for sceGxm.
//
// Three kinds, because the console has two memories and the GPU reads them at
// different speeds. CDRAM is the 128 MB next to the GPU and is where surfaces
// and textures go. LPDDR is main memory; uncached is right for data the CPU
// writes once and the GPU reads, cached for data the CPU reads back.
//
// Granules are the kernel's: 256 KiB for CDRAM, 4 KiB for LPDDR. Anything
// smaller is rounded up here, which is why small GL buffers must share blocks
// (a sub-allocator, when buffers.c arrives) rather than each take one.
#include <psp2/kernel/sysmem.h>
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static size_t round_up(size_t n, size_t granule) {
  return (n + granule - 1) & ~(granule - 1);
}

void* fvgl_mem_alloc(FvglMemKind kind, size_t size, SceUID* uid_out) {
  SceKernelMemBlockType type;
  size_t granule;
  switch (kind) {
    case FVGL_MEM_CDRAM:
      type = SCE_KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW;
      granule = 256 * 1024;
      break;
    case FVGL_MEM_LPDDR_CACHED:
      type = SCE_KERNEL_MEMBLOCK_TYPE_USER_RW;
      granule = 4 * 1024;
      break;
    default:
      type = SCE_KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE;
      granule = 4 * 1024;
      break;
  }
  size = round_up(size, granule);
  const SceUID uid = sceKernelAllocMemBlock("fvgl", type, (SceSize)size, NULL);
  if (uid < 0) {
    fvgl_log("memblock %u B kind %d: 0x%08X", (unsigned)size, kind, (unsigned)uid);
    return NULL;
  }
  void* base = NULL;
  sceKernelGetMemBlockBase(uid, &base);
  const int r = sceGxmMapMemory(base, (SceSize)size, SCE_GXM_MEMORY_ATTRIB_RW);
  if (r < 0) {
    fvgl_log("sceGxmMapMemory %u B: 0x%08X", (unsigned)size, (unsigned)r);
    sceKernelFreeMemBlock(uid);
    return NULL;
  }
  if (uid_out) *uid_out = uid;
  return base;
}

void fvgl_mem_free(SceUID uid) {
  if (uid < 0) return;
  void* base = NULL;
  if (sceKernelGetMemBlockBase(uid, &base) == 0) sceGxmUnmapMemory(base);
  sceKernelFreeMemBlock(uid);
}

void* fvgl_usse_alloc(bool fragment, size_t size, unsigned* usse_offset,
                      SceUID* uid_out) {
  size = round_up(size, 4 * 1024);
  const SceUID uid = sceKernelAllocMemBlock(
      "fvgl-usse", SCE_KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE, (SceSize)size, NULL);
  if (uid < 0) {
    fvgl_log("usse memblock %u B: 0x%08X", (unsigned)size, (unsigned)uid);
    return NULL;
  }
  void* base = NULL;
  sceKernelGetMemBlockBase(uid, &base);
  const int r = fragment
                    ? sceGxmMapFragmentUsseMemory(base, (SceSize)size, usse_offset)
                    : sceGxmMapVertexUsseMemory(base, (SceSize)size, usse_offset);
  if (r < 0) {
    fvgl_log("map %s usse %u B: 0x%08X", fragment ? "fragment" : "vertex",
             (unsigned)size, (unsigned)r);
    sceKernelFreeMemBlock(uid);
    return NULL;
  }
  if (uid_out) *uid_out = uid;
  return base;
}

void fvgl_usse_free(bool fragment, SceUID uid) {
  if (uid < 0) return;
  void* base = NULL;
  if (sceKernelGetMemBlockBase(uid, &base) == 0) {
    if (fragment) sceGxmUnmapFragmentUsseMemory(base);
    else sceGxmUnmapVertexUsseMemory(base);
  }
  sceKernelFreeMemBlock(uid);
}
