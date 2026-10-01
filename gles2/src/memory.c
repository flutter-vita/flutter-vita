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
#include <psp2/kernel/threadmgr.h>
#include <stdlib.h>
#include <string.h>

#include "fvgl_internal.h"

static int g_garbage_count;
extern unsigned fvgl_stalls_previous_frame, fvgl_stalls_this_frame;

static size_t round_up(size_t n, size_t granule) {
  return (n + granule - 1) & ~(granule - 1);
}

// What this layer holds of each memory, block by block. The kernel reports
// the free totals; only the layer can say how much of the rest is its own and
// how much of that is waiting in the garbage list for the GPU.
static FvglStats g_live;

static void live_add(bool cdram, size_t bytes, int sign) {
  if (cdram) {
    g_live.cdram_blocks += (unsigned)sign;
    g_live.cdram_bytes += (unsigned)(sign * (long)bytes);
  } else {
    g_live.lpddr_blocks += (unsigned)sign;
    g_live.lpddr_bytes += (unsigned)(sign * (long)bytes);
  }
}

void fvgl_note_lpddr_fallback(void) { g_live.lpddr_fallbacks++; }

unsigned fvgl_us_queue_wait, fvgl_us_garbage, fvgl_us_memblock;

void fvgl_stats(FvglStats* out) {
  // Readers come from other threads than the one tearing the layer down:
  // the app's stats channel runs on its main thread once a second, and on
  // 2026-09-14 (the gallery's build 38, a relaunch) it read the frame_done
  // notification region after sceGxmTerminate had unmapped it, a data abort
  // in the teardown. While the layer is down a reader gets the last full
  // snapshot; `up` goes false 20 ms before anything is freed.
  static FvglStats last;
  if (!fvgl.up) {
    *out = last;
    return;
  }
  *out = g_live;
  out->stalls_previous_frame = fvgl_stalls_previous_frame;
  out->stalls_this_frame = fvgl_stalls_this_frame;
  out->shader_cache_hits = fvgl_shader_cache_hits;
  out->shader_cache_misses = fvgl_shader_cache_misses;
  out->subdata_into_used = fvgl_subdata_into_used_buffer;
  out->vertex_variants = fvgl_vertex_variants;
  out->fragment_variants = fvgl_fragment_variants;
  out->variants_uncached = fvgl_variants_uncached;
  out->us_queue_wait = fvgl_us_queue_wait;
  out->us_garbage = fvgl_us_garbage;
  out->us_memblock = fvgl_us_memblock;
  out->us_link = fvgl_us_link;
  out->us_cache_read = fvgl_us_cache_read;
  {
    extern unsigned fvgl_us_gpu_latency, fvgl_us_gpu_latency_max, fvgl_frames_flipped;
    extern unsigned fvgl_us_gpu_busy, fvgl_frames_gpu_done;
    out->us_gpu_latency = fvgl_us_gpu_latency;
    out->us_gpu_latency_max = fvgl_us_gpu_latency_max;
    out->frames_flipped = fvgl_frames_flipped;
    out->us_gpu_busy = fvgl_us_gpu_busy;
    out->frames_gpu_done = fvgl_frames_gpu_done;
  }
  out->garbage_pending = (unsigned)g_garbage_count;
  out->frame = fvgl.frame;
  out->frame_done = fvgl_gpu_completed_frame();
  fvgl_texture_stats(out);
  last = *out;
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
  const uint64_t t0 = fvgl_now_us();
  const SceUID uid = sceKernelAllocMemBlock("fvgl", type, (SceSize)size, NULL);
  if (uid < 0) {
    // Once per size, or a run out of CDRAM writes a line per texture.
    static unsigned said;
    if (said++ < 8) fvgl_log("memblock %u B kind %d: 0x%08X", (unsigned)size, kind, (unsigned)uid);
    if (kind == FVGL_MEM_CDRAM) g_live.cdram_failures++;
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
  live_add(kind == FVGL_MEM_CDRAM, size, 1);
  fvgl_us_memblock += (unsigned)(fvgl_now_us() - t0);
  if (uid_out) *uid_out = uid;
  return base;
}

void fvgl_mem_free(SceUID uid) {
  if (uid < 0) return;
  const uint64_t t0 = fvgl_now_us();
  void* base = NULL;
  if (sceKernelGetMemBlockBase(uid, &base) == 0) {
    SceKernelMemBlockInfo info = {.size = sizeof info};
    if (sceKernelGetMemBlockInfoByAddr(base, &info) == 0) {
      live_add(info.type == SCE_KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW, info.mappedSize, -1);
    }
    sceGxmUnmapMemory(base);
  }
  sceKernelFreeMemBlock(uid);
  fvgl_us_memblock += (unsigned)(fvgl_now_us() - t0);
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

// ---- deferred freeing ------------------------------------------------------

typedef struct Garbage {
  SceUID uid;
  SceGxmRenderTarget* target;
  uint32_t frame;
  int8_t usse;  // -1 none, 0 vertex, 1 fragment
} Garbage;

static Garbage* g_garbage;
static int g_garbage_cap;

static void garbage_push(SceUID uid, SceGxmRenderTarget* target, int8_t usse) {
  if (uid < 0 && !target) return;
  if (g_garbage_count == g_garbage_cap) {
    g_garbage_cap = g_garbage_cap ? g_garbage_cap * 2 : 64;
    g_garbage = realloc(g_garbage, sizeof(Garbage) * (size_t)g_garbage_cap);
  }
  g_garbage[g_garbage_count++] = (Garbage){uid, target, fvgl.frame, usse};
}

void fvgl_defer_free(SceUID uid) { garbage_push(uid, NULL, -1); }
void fvgl_defer_free_usse(bool fragment, SceUID uid) { garbage_push(uid, NULL, fragment ? 1 : 0); }
void fvgl_defer_destroy_target(SceGxmRenderTarget* target) { garbage_push(-1, target, -1); }

uint32_t fvgl_gpu_completed_frame(void) {
  return fvgl.frame_done ? *fvgl.frame_done : 0;
}

unsigned fvgl_stalls_previous_frame, fvgl_stalls_this_frame;

void fvgl_wait_for_frame(uint32_t frame) {
  if (fvgl_gpu_completed_frame() >= frame) return;
  if (frame >= fvgl.frame) {
    // The notification for this frame is not even queued yet.
    fvgl_stalls_this_frame++;
    fvgl_scene_end();
    sceGxmFinish(fvgl.gxm);
    *fvgl.frame_done = fvgl.frame - 1;
    return;
  }
  fvgl_stalls_previous_frame++;
  // The GPU is at most two frames behind; a frame is 16 ms at the display's
  // rate. Well beyond that something else is wrong and waiting hides it.
  for (int spins = 0; spins < 2000 && fvgl_gpu_completed_frame() < frame; spins++) {
    sceKernelDelayThread(100);
  }
  if (fvgl_gpu_completed_frame() < frame) fvgl_log("frame %u not done after 200 ms", frame);
}

void fvgl_collect_garbage(bool everything) {
  const uint64_t t0 = fvgl_now_us();
  const uint32_t done = fvgl_gpu_completed_frame();
  int kept = 0;
  for (int i = 0; i < g_garbage_count; i++) {
    Garbage* g = &g_garbage[i];
    // A block stamped with frame F was referenced by frame F at the latest,
    // so it is free once the GPU reports F done.
    if (everything || g->frame <= done) {
      if (g->target) sceGxmDestroyRenderTarget(g->target);
      else if (g->usse < 0) fvgl_mem_free(g->uid);
      else fvgl_usse_free(g->usse == 1, g->uid);
    } else {
      g_garbage[kept++] = *g;
    }
  }
  g_garbage_count = kept;
  if (everything) {
    free(g_garbage);
    g_garbage = NULL;
    g_garbage_cap = 0;
  }
  fvgl_us_garbage += (unsigned)(fvgl_now_us() - t0);
}

// ---- scratch -----------------------------------------------------------------
//
// One ring per display buffer. When the chain comes back to a display buffer
// the frame that last used its ring has been scanned out, and scanning out
// comes after rendering, so the ring is free to reuse.

enum { kScratchSize = 512 * 1024 };

typedef struct Scratch {
  SceUID uid;
  uint8_t* base;
  size_t used;
} Scratch;

static Scratch g_scratch[FVGL_MAX_DISPLAY_BUFFERS];
static int g_scratch_current;

int fvgl_scratch_init(void) {
  for (int i = 0; i < FVGL_MAX_DISPLAY_BUFFERS; i++) {
    g_scratch[i].uid = -1;
    g_scratch[i].base = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, kScratchSize, &g_scratch[i].uid);
    if (!g_scratch[i].base) return -1;
    g_scratch[i].used = 0;
  }
  g_scratch_current = 0;
  return 0;
}

void fvgl_scratch_shutdown(void) {
  for (int i = 0; i < FVGL_MAX_DISPLAY_BUFFERS; i++) {
    fvgl_mem_free(g_scratch[i].uid);
    g_scratch[i].uid = -1;
    g_scratch[i].base = NULL;
  }
}

void fvgl_scratch_reset(int display_index) {
  g_scratch_current = display_index;
  g_scratch[display_index].used = 0;
}

void* fvgl_scratch_alloc(size_t size, size_t align) {
  Scratch* s = &g_scratch[g_scratch_current];
  size_t start = (s->used + align - 1) & ~(align - 1);
  if (s->base && start + size <= kScratchSize) {
    s->used = start + size;
    return s->base + start;
  }
  // The ring is full for this frame: a block of its own, freed with the frame.
  SceUID uid = -1;
  void* p = fvgl_mem_alloc(FVGL_MEM_LPDDR_UNCACHED, size, &uid);
  if (p) fvgl_defer_free(uid);
  return p;
}

// ---- object tables ---------------------------------------------------------

unsigned fvgl_table_add(FvglTable* t, void* item) {
  if (t->count == t->cap) {
    t->cap = t->cap ? t->cap * 2 : 64;
    t->items = realloc(t->items, sizeof(void*) * (size_t)t->cap);
  }
  t->items[t->count++] = item;
  return t->count;  // names start at 1
}

void* fvgl_table_get(const FvglTable* t, unsigned name) {
  if (name == 0 || name > t->count) return NULL;
  return t->items[name - 1];
}

void fvgl_table_clear(FvglTable* t, unsigned name) {
  if (name == 0 || name > t->count) return;
  t->items[name - 1] = NULL;
}
