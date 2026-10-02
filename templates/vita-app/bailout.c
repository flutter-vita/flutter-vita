// Turn a fatal error into a clean exit that returns to the bridge.
//
// A crash needs a person: the console puts up an error dialog, and somebody has
// to tap OK, find the bridge bubble and open it. Nothing here can catch a
// hardware fault -- excpmgr.h is psp2kern only, newlib's signal() is not wired
// to data aborts, and catching one needs a kernel plugin (ADR-0011).
//
// But most crashes in a port are our own code discovering it cannot continue: a
// NULL returned to a caller that cannot check it, a failed assertion, an empty
// allocation. Those do not have to become dialogs. This launches the bridge
// and exits cleanly, so there is nothing to dismiss.
//
// Dev-loop infrastructure. A shipping app drops this file from the build.

#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/kernel/threadmgr.h>

#include <malloc.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "bailout.h"

#ifndef VITA_LOADER_TITLEID
#define VITA_LOADER_TITLEID "FVTA00001"
#endif

// Which bridge to bail out to, read the same way the dev server's `handoff`
// reads it. Duplicated rather than shared: this runs after something has
// already gone wrong, so it depends on nothing but sceIo. Returns a static
// buffer.
static const char* bridge_titleid(void) {
  static char id[16];
  const SceUID fd =
      sceIoOpen("ux0:data/flutter-vita/bridge.titleid", SCE_O_RDONLY, 0777);
  if (fd < 0) return VITA_LOADER_TITLEID;
  char buf[16];
  const int n = sceIoRead(fd, buf, sizeof buf - 1);
  sceIoClose(fd);
  if (n < 9) return VITA_LOADER_TITLEID;
  for (int i = 0; i < 9; i++) {
    if (buf[i] <= ' ') return VITA_LOADER_TITLEID;
  }
  memcpy(id, buf, 9);
  id[9] = '\0';
  return id;
}

// Why we bailed, kept where the host can read it after the fact. Separate from
// the engine log: that is written through engine machinery, and the premise
// here is that something in the process has already gone wrong.
static void record(const char* reason) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  const SceUID fd = sceIoOpen("ux0:data/flutter-vita/bailout.txt",
                              SCE_O_WRONLY | SCE_O_CREAT | SCE_O_APPEND, 0777);
  if (fd < 0) return;
  sceIoWrite(fd, reason, strlen(reason));
  sceIoWrite(fd, "\n", 1);
  sceIoSyncByFd(fd, 0);
  sceIoClose(fd);
}

// What memory looked like at the moment of the bail. Added after a launch
// aborted with `abort()` and nothing else. Two numbers separate the two failures
// this port has: `heap`, the newlib arena sized by _newlib_heap_size_user, and
// `user`, the process budget from sceKernelGetFreeMemorySize, which a large ELF
// eats before main().
//
// Both walk state the abort may have corrupted, so this runs after the reason is
// already on disk.
static void record_memory(void) {
  struct mallinfo mi = mallinfo();
  SceKernelFreeMemorySizeInfo mem;
  mem.size = sizeof(mem);
  const int ok = sceKernelGetFreeMemorySize(&mem) >= 0;

  char msg[192];
  snprintf(msg, sizeof msg,
           "  heap %uK used of %uK arena, free user %dK cdram %dK phycont %dK",
           (unsigned)(mi.uordblks / 1024), (unsigned)(mi.arena / 1024),
           ok ? mem.size_user / 1024 : -1, ok ? mem.size_cdram / 1024 : -1,
           ok ? mem.size_phycont / 1024 : -1);
  record(msg);
}

// Let go of the GPU before the process ends, when there is one to let go of.
// Weak: the embedder defines it only on the GL path.
//
// A crash exit that leaves a live GXM context and queued flips behind takes the
// shell's compositor with it, and the console needs the power button. That
// happened twice on 2026-08-22 through the dev server's handoff. It runs before
// the launch, not between the launch and the exit.
extern void flutter_vita_gpu_shutdown(void) __attribute__((weak));
extern void flutter_vita_log_flush(void) __attribute__((weak));

// Which thread bailed, and from where. The gallery's build 30 left
// "abort()" and a memory line and nothing else: no log tail, no shutdown
// stages, and no way to tell the raster thread from the UI thread or a
// Skia abort from a Dart one. The thread's name says which; the caller's
// address, read against the .elf with tools/analyse-crash.sh, says whence.
static void record_where(const void* caller) {
  SceKernelThreadInfo info;
  memset(&info, 0, sizeof info);
  info.size = sizeof info;
  const int r = sceKernelGetThreadInfo(sceKernelGetThreadId(), &info);
  char msg[160];
  snprintf(msg, sizeof msg, "  on thread %s, called from 0x%08X",
           r >= 0 ? info.name : "(unknown)", (unsigned)(uintptr_t)caller);
  record(msg);
}

void vita_bail_to_loader(const char* reason) {
  vita_bail_to_loader_from(reason, __builtin_return_address(0));
}

void vita_bail_to_loader_from(const char* reason, const void* caller) {
  // Re-entry is a real possibility: the launch below can fail, and anything it
  // touches could abort again. A second pass would recurse until the stack ran
  // out, which is a worse ending than the one being avoided.
  static volatile int bailing = 0;
  if (__sync_lock_test_and_set(&bailing, 1)) {
    record("  bailed again while bailing; exiting");
    sceKernelExitProcess(1);
  }

  record(reason != NULL ? reason : "(no reason given)");
  record_memory();
  record_where(caller);

  // Each step leaves a line before it starts, so a step that never returns
  // names itself. 0xFFFFF rather than the documented 0x20000 for the
  // launch, matching what the bridge itself uses to launch the app; it
  // is the value known to work on this console.
  if (flutter_vita_gpu_shutdown != NULL) {
    record("  releasing the GPU");
    flutter_vita_gpu_shutdown();
  }
  // The engine log's last lines are in a ring until its writer thread gets
  // to them, and after the exit below nobody does.
  if (flutter_vita_log_flush != NULL) {
    record("  flushing the log");
    flutter_vita_log_flush();
  }
  record("  launching the bridge");

  {
    char uri[48];
    snprintf(uri, sizeof uri, "psgm:play?titleid=%s", bridge_titleid());
    sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  }

// Exit immediately. Nothing may go between the launch and this line.
//
// A `sceKernelDelayThread(100 * 1000)` used to sit here, to avoid racing the
// asynchronous launch. It cost a "close the current application?" prompt on
// every bail, because that prompt appears only while the outgoing app is still
// alive. The bridge launches an app on every deploy, exits at once, and has
// never prompted. There was nothing to race either: record() already called
// sceIoSyncByFd and sceIoClose.
//
// A clean exit means no fault, so no dialog, so no tap. If the launch failed the
// console lands on LiveArea, still better than an error dialog.
  sceKernelExitProcess(1);
}

// Overrides libc's, which works without rebuilding the engine: `abort` is an
// undefined symbol in libflutter_engine_vita.a, so a definition linked ahead of
// libc wins. Dart's OS::Abort() is `PrepareToAbort(); abort();`, so every FATAL,
// UNREACHABLE and failed ASSERT in the VM arrives here.
void abort(void) {
  vita_bail_to_loader_from("abort()", __builtin_return_address(0));
  // abort is [[noreturn]] and sceKernelExitProcess is not marked as such in
  // the VitaSDK headers, so the compiler cannot see that this is unreachable.
  for (;;) {
  }
}

void __assert_func(const char* file,
                   int line,
                   const char* func,
                   const char* expr) {
  char msg[256];
  snprintf(msg, sizeof msg, "assert: %s:%d %s: %s", file != NULL ? file : "?",
           line, func != NULL ? func : "?", expr != NULL ? expr : "?");
  vita_bail_to_loader(msg);
  for (;;) {
  }
}
