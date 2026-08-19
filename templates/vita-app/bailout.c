// Turn a fatal error into a clean exit that returns to the loader.
//
// The dev loop's real cost is not build time -- builds are twenty seconds --
// it is that a crash needs a person. The console puts up an error dialog, and
// somebody has to walk over, tap OK, find the loader bubble and open it. That
// is two manual steps per crash, and a port under development produces many.
//
// Nothing can catch a hardware fault here. `excpmgr.h` exists only in
// `psp2kern`, newlib's `signal()` is not wired to data aborts, and a C++
// try/catch is irrelevant because a data abort is not an exception -- the
// kernel simply terminates the process. Catching one needs a kernel plugin,
// and taiHEN is deliberately not on the table (ADR-0011).
//
// But most crashes in a port are not wild pointers. They are **our own code
// discovering it cannot continue** and then failing badly: a NULL returned to
// a caller that cannot check it, a failed assertion, an allocation that came
// back empty. The crash found on 2026-08-15 was exactly that shape -- the
// emulated-TLS table knew it was out of slots and returned NULL anyway.
//
// Those paths do not have to become dialogs. A process that exits cleanly
// produces no dialog at all, so there is nothing to dismiss and nothing to
// recover from: this launches the loader and exits, and the next thing the
// developer sees is the loader already listening. Both manual steps disappear
// for every failure the program can see coming.
//
// This is dev-loop infrastructure and belongs with the dev server. A shipping
// app links neither -- an app that relaunches a development loader when it
// hits an assertion is obviously wrong -- and dropping this file from the
// build is all that takes.

#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/kernel/threadmgr.h>

#include <malloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "bailout.h"

#ifndef VITA_LOADER_TITLEID
#define VITA_LOADER_TITLEID "FVTA00003"
#endif

// Why we bailed, kept where the host can read it after the fact.
//
// Separate from the engine log on purpose: the log is written through the
// engine's own machinery, and the whole premise here is that something in the
// process has already gone wrong. This is two `sceIo` calls and no allocation.
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

// What memory looked like at the moment of the bail.
//
// Added after a localsend launch aborted with `abort()` and nothing else, which
// is a note saying "something went wrong" and no more. Two numbers separate the
// two failures this port actually has:
//
//   heap  -- the newlib arena, sized by _newlib_heap_size_user. Fills silently
//            while the budget still looks healthy; this is what ended runs
//            before the arena was raised to 160 MB.
//   user  -- the process budget from sceKernelGetFreeMemorySize. A large ELF
//            eats this before main() and no Dart-level number reflects it.
//
// mallinfo and sceKernelGetFreeMemorySize both walk kernel or allocator state
// that the abort may have corrupted, so this runs *after* the reason is already
// on disk. A truncated bailout.txt still names the failure.
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

void vita_bail_to_loader(const char* reason) {
  // Re-entry is a real possibility: the launch below can fail, and anything it
  // touches could abort again. A second pass would recurse until the stack ran
  // out, which is a worse ending than the one being avoided.
  static volatile int bailing = 0;
  if (__sync_lock_test_and_set(&bailing, 1)) {
    sceKernelExitProcess(1);
  }

  record(reason != NULL ? reason : "(no reason given)");
  record_memory();

  // 0xFFFFF rather than the documented 0x20000, matching what the loader
  // itself uses to launch the app; it is the value known to work on this
  // console.
  sceAppMgrLaunchAppByUri(0xFFFFF, "psgm:play?titleid=" VITA_LOADER_TITLEID);

  // The launch is asynchronous. Exiting instantly has been known to race it,
  // and a tenth of a second costs nothing on a path that is already ending.
  sceKernelDelayThread(100 * 1000);

  // Clean exit, which is the entire point: no fault, so no dialog, so no tap.
  // If the launch failed the console lands on LiveArea instead, which is still
  // one step better than an error dialog.
  sceKernelExitProcess(1);
}

// Overrides libc's, and that is why this works without rebuilding the engine:
// `abort` is an *undefined* symbol in libflutter_engine_vita.a -- the engine
// calls it and libc supplies it -- so a definition linked ahead of libc wins.
//
// It catches more than it looks like. Dart's OS::Abort() is
// `PrepareToAbort(); abort();`, so every FATAL, UNREACHABLE and failed runtime
// ASSERT in the VM arrives here, as does anything in Skia or the embedder that
// aborts. That is a large share of the ways this port actually dies.
void abort(void) {
  vita_bail_to_loader("abort()");
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
