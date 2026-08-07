// Phase 0.5 Track A — the spike harness.
//
// One program that answers the questions no host machine and no emulator can:
//
//   A1  Does VM-domain executable memory actually work?   -> ADR-0005
//       What is the largest VM block, and the largest contiguous
//       sceKernelAllocMemBlock per memory type?
//   A2  What does a full-screen raster frame cost on this CPU?  -> ADR-0006/0007
//
// It is also the Phase 0 hello-world: running it at all proves the
// build -> deploy -> log loop exists.
//
// Results go to the screen AND to ux0:data/flutter-vita/spike.log, so they can
// be pulled off over FTP rather than transcribed from a photo.
//
// NOTE: this deliberately does NOT test executing a VM block *before*
// sceKernelOpenVMDomain. That would be the cleanest proof the domain toggle is
// enforced, but a fault there kills the process and we lose the log with it.
// Worth doing as a follow-up run once the safe results are banked.

#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/kernel/clib.h>
#include <psp2/power.h>
#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "debugScreen.h"

// The raster benchmarks need three ~2 MB buffers. The default newlib heap is
// not guaranteed to be generous, so ask for headroom explicitly.
unsigned int _newlib_heap_size_user = 64 * 1024 * 1024;

#define SCREEN_W 960
#define SCREEN_H 544
#define ALT_W    720
#define ALT_H    408

static SceUID g_log = -1;

static void lg(const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  psvDebugScreenPuts(buf);
  if (g_log >= 0) sceIoWrite(g_log, buf, strlen(buf));
}

static void log_open(void) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_log = sceIoOpen("ux0:data/flutter-vita/spike.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
}

static uint64_t now_us(void) { return sceKernelGetProcessTimeWide(); }

// ---------------------------------------------------------------- A1: VM domain

// Two tiny functions, hand-assembled, each returning a known constant.
// Dart's AOT backend emits ARM (A32), while VitaSDK defaults to Thumb, so both
// encodings are worth proving independently.
static const uint32_t arm_code[] = {
    0xE3A0002A,  // mov r0, #42
    0xE12FFF1E,  // bx  lr
};
static const uint16_t thumb_code[] = {
    0x2025,  // movs r0, #37
    0x4770,  // bx   lr
};

// Run 1 asked for 4096 B and got SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK_SIZE
// (0x80024B05) — VM blocks have a minimum/granularity larger than a page, which
// is documented nowhere. Find it, then use a legal size for the real test.
static SceSize find_min_vm_size(void) {
  static const SceSize candidates[] = {
      4096, 16384, 65536, 262144, 1048576, 4194304,
  };
  for (unsigned i = 0; i < sizeof candidates / sizeof *candidates; i++) {
    SceUID u = sceKernelAllocMemBlockForVM("probe_min", candidates[i]);
    lg("    %8u B -> %s\n", candidates[i],
       u >= 0 ? "ok" : (u == (SceUID)0x80024B05 ? "ILLEGAL_MEMBLOCK_SIZE" : "error"));
    if (u >= 0) {
      sceKernelFreeMemBlock(u);
      return candidates[i];
    }
  }
  return 0;
}

static void test_vm_domain(void) {
  lg("\n== A1: VM domain executable memory ==\n");

  lg("  minimum legal VM block size:\n");
  SceSize size = find_min_vm_size();
  if (size == 0) {
    lg("  FAIL  no legal VM block size found up to 4 MiB\n");
    return;
  }
  lg("  using %u B for the execution test\n", size);

  SceUID uid = sceKernelAllocMemBlockForVM("spike_vm", size);
  if (uid < 0) {
    lg("  FAIL  sceKernelAllocMemBlockForVM -> 0x%08X\n", uid);
    lg("  (0x80024B05 = ILLEGAL_MEMBLOCK_SIZE, anything else is a real failure)\n");
    return;
  }
  lg("  alloc %u B                    ok (uid 0x%08X)\n", size, uid);

  void *base = NULL;
  int r = sceKernelGetMemBlockBase(uid, &base);
  if (r < 0 || !base) {
    lg("  FAIL  sceKernelGetMemBlockBase -> 0x%08X\n", r);
    return;
  }
  lg("  base                          %p\n", base);

  // Domain closed: the block should be writable here.
  memcpy(base, arm_code, sizeof arm_code);
  memcpy((uint8_t *)base + 64, thumb_code, sizeof thumb_code);
  lg("  wrote code while domain closed ok\n");

  r = sceKernelOpenVMDomain();
  lg("  sceKernelOpenVMDomain         0x%08X\n", r);

  r = sceKernelSyncVMDomain(uid, base, size);
  lg("  sceKernelSyncVMDomain         0x%08X\n", r);

  // Bit 0 clear -> ARM state. Bit 0 set -> Thumb state. BLX honours it.
  int (*fn_arm)(void) = (int (*)(void))(uintptr_t)base;
  int a = fn_arm();
  lg("  call ARM   code -> %d %s\n", a, a == 42 ? "(expected 42) PASS" : "MISMATCH");

  int (*fn_thumb)(void) = (int (*)(void))(((uintptr_t)base + 64) | 1u);
  int t = fn_thumb();
  lg("  call Thumb code -> %d %s\n", t, t == 37 ? "(expected 37) PASS" : "MISMATCH");

  sceKernelCloseVMDomain();
  sceKernelFreeMemBlock(uid);

  if (a == 42 && t == 37)
    lg("  => VM domain execution WORKS. ADR-0005 Option B is viable.\n");
  else
    lg("  => VM domain execution FAILED. Snapshot must be baked in.\n");
}

// ------------------------------------------------------- A1: allocation limits

// Largest size that still allocates, by doubling then bisecting.
static SceSize probe_vm_max(void) {
  SceSize lo = 4096, hi = 64u * 1024 * 1024, best = 0;
  while (lo <= hi) {
    SceSize mid = lo + (hi - lo) / 2;
    mid &= ~0xFFFu;  // 4 KiB granularity, per the docs
    if (mid < 4096) break;
    SceUID u = sceKernelAllocMemBlockForVM("probe", mid);
    if (u >= 0) {
      best = mid;
      sceKernelFreeMemBlock(u);
      lo = mid + 4096;
    } else {
      hi = mid - 4096;
    }
  }
  return best;
}

static SceSize probe_block_max(SceKernelMemBlockType type) {
  SceSize lo = 1u << 20, hi = 512u << 20, best = 0;
  while (lo <= hi) {
    SceSize mid = lo + (hi - lo) / 2;
    mid &= ~0xFFFFFu;  // 1 MiB steps; plenty of resolution for a budget probe
    if (mid < (1u << 20)) break;
    SceUID u = sceKernelAllocMemBlock("probe", type, mid, NULL);
    if (u >= 0) {
      best = mid;
      sceKernelFreeMemBlock(u);
      lo = mid + (1u << 20);
    } else {
      hi = mid - (1u << 20);
    }
  }
  return best;
}

static void test_limits(void) {
  lg("\n== A1: allocation limits ==\n");

  SceSize vm = probe_vm_max();
  lg("  largest VM block              %u B  (%.2f MiB)\n", vm, vm / 1048576.0);
  lg("     documented cap is 16 MiB; counter app needs 2.11 MiB\n");

  struct { const char *name; SceKernelMemBlockType t; } types[] = {
      {"USER_MAIN_RW        ", SCE_KERNEL_MEMBLOCK_TYPE_USER_MAIN_RW},
      {"USER_MAIN_PHYCONT_RW", SCE_KERNEL_MEMBLOCK_TYPE_USER_MAIN_PHYCONT_RW},
      {"USER_CDRAM_RW       ", SCE_KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW},
  };
  for (unsigned i = 0; i < sizeof types / sizeof *types; i++) {
    SceSize s = probe_block_max(types[i].t);
    lg("  %s  %4u MiB\n", types[i].name, s >> 20);
  }
  lg("     Dart's heap wants large contiguous regions; if the biggest\n");
  lg("     single block is small, virtual_memory_vita.cc gets much harder.\n");
}

// -------------------------------------------------------------- A2: raster cost

// Run 1 reported fill at 7.96 GB/s — above the Vita's 3.2 GB/s theoretical
// bandwidth, i.e. impossible. -O2 collapsed ten identical fills into one.
// The value now varies per call and a memory barrier sits between reps, so the
// compiler cannot prove the stores are redundant.
#define BARRIER() __asm__ __volatile__("" ::: "memory")

static void bench_fill(uint32_t *dst, size_t px, uint32_t v) {
  for (size_t i = 0; i < px; i++) dst[i] = v;
  BARRIER();
}

static void bench_blend(uint32_t *dst, const uint32_t *src, size_t px) {
  // Naive per-pixel source-over. A crude stand-in for what Skia does when
  // compositing a layer; not a Skia number, but it brackets one.
  for (size_t i = 0; i < px; i++) {
    uint32_t s = src[i], d = dst[i];
    uint32_t a = s >> 24, ia = 255u - a;
    uint32_t rb = ((((s & 0x00FF00FFu) * a) + ((d & 0x00FF00FFu) * ia)) >> 8) & 0x00FF00FFu;
    uint32_t g  = ((((s & 0x0000FF00u) * a) + ((d & 0x0000FF00u) * ia)) >> 8) & 0x0000FF00u;
    dst[i] = 0xFF000000u | rb | g;
  }
  BARRIER();
}

#define REPS 10

static void bench_at(int w, int h, uint32_t *a, uint32_t *b) {
  const size_t px = (size_t)w * h;
  const size_t bytes = px * 4;
  uint64_t t0, dt;

  lg("  %dx%d  (%.2f MB/frame)\n", w, h, bytes / 1048576.0);

  t0 = now_us();
  for (int i = 0; i < REPS; i++) { memcpy(b, a, bytes); BARRIER(); }
  dt = now_us() - t0;
  double memcpy_ms = dt / 1000.0 / REPS;
  lg("    memcpy   %7.2f ms/frame   %6.1f fps   %5.0f MB/s\n", memcpy_ms,
     1000.0 / memcpy_ms, (bytes * 2 / 1048576.0) / (memcpy_ms / 1000.0));

  t0 = now_us();
  for (int i = 0; i < REPS; i++) bench_fill(b, px, 0xFF2050C0u + (uint32_t)i);
  dt = now_us() - t0;
  double fill_ms = dt / 1000.0 / REPS;
  lg("    fill     %7.2f ms/frame   %6.1f fps\n", fill_ms, 1000.0 / fill_ms);

  t0 = now_us();
  for (int i = 0; i < REPS; i++) bench_blend(b, a, px);
  dt = now_us() - t0;
  double blend_ms = dt / 1000.0 / REPS;
  lg("    blend    %7.2f ms/frame   %6.1f fps\n", blend_ms, 1000.0 / blend_ms);

  // The floor for a full-screen software frame: rasterise once, then blit.
  double floor_ms = fill_ms + memcpy_ms;
  lg("    floor (fill+blit) %5.2f ms -> %.1f fps before Skia does anything\n",
     floor_ms, 1000.0 / floor_ms);
}

static void test_raster(void) {
  lg("\n== A2: raster cost ==\n");

  uint32_t *a = malloc(SCREEN_W * SCREEN_H * 4);
  uint32_t *b = malloc(SCREEN_W * SCREEN_H * 4);
  if (!a || !b) {
    lg("  FAIL  could not allocate benchmark buffers\n");
    free(a); free(b);
    return;
  }
  for (size_t i = 0; i < SCREEN_W * SCREEN_H; i++) a[i] = 0x80304060u | (uint32_t)i;

  const int clocks[] = {333, 444};
  for (unsigned c = 0; c < sizeof clocks / sizeof *clocks; c++) {
    int rc = scePowerSetArmClockFrequency(clocks[c]);
    int got = scePowerGetArmClockFrequency();
    lg("\n  --- CPU %d MHz (requested %d, rc 0x%08X) ---\n", got, clocks[c], rc);
    bench_at(SCREEN_W, SCREEN_H, a, b);
    bench_at(ALT_W, ALT_H, a, b);
  }

  free(a);
  free(b);
}

// ------------------------------------------------------------------------ main

int main(void) {
  psvDebugScreenInit();
  log_open();

  lg("flutter-vita  Phase 0.5 Track A probe\n");
  lg("=====================================\n");
  lg("log -> ux0:data/flutter-vita/spike.log\n");

  test_vm_domain();
  test_limits();
  test_raster();

  lg("\ndone. press START to exit.\n");
  if (g_log >= 0) sceIoClose(g_log);

  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);
  for (;;) {
    sceCtrlPeekBufferPositive(0, &pad, 1);
    if (pad.buttons & SCE_CTRL_START) break;
    sceKernelDelayThread(50 * 1000);
  }

  sceKernelExitProcess(0);
  return 0;
}
