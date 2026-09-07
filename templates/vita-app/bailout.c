// Turn a fatal error into a clean exit that returns to the receiver.
//
// The dev loop's real cost is not build time -- builds are twenty seconds --
// it is that a crash needs a person. The console puts up an error dialog, and
// somebody has to walk over, tap OK, find the receiver bubble and open it. That
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
// recover from: this launches the receiver and exits, and the next thing the
// developer sees is the receiver already listening. Both manual steps disappear
// for every failure the program can see coming.
//
// This is dev-loop infrastructure and belongs with the dev server. A shipping
// app links neither -- an app that relaunches a development receiver when it
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
#define VITA_LOADER_TITLEID "FVTA00001"
#endif

// Which receiver to bail out to, read the same way the dev server's `handoff`
// reads it -- ux0:data/flutter-vita/receiver.titleid, falling back to the
// compiled-in default. Duplicated here rather than shared, because this file
// runs after something has already gone wrong and deliberately depends on
// nothing but sceIo: a helper reached through the engine is a helper that can
// be part of the fault.
//
// Returns a pointer to a static buffer, valid until the next call.
static const char* receiver_titleid(void) {
  static char id[16];
  const SceUID fd =
      sceIoOpen("ux0:data/flutter-vita/receiver.titleid", SCE_O_RDONLY, 0777);
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

// Let go of the GPU before the process ends, when there is one to let go of.
//
// Weak: the embedder defines it only on the GL path. A crash exit that leaves
// a live GXM context and queued flips behind does not merely lose the app --
// it takes the shell's compositor with it, and the console needs the power
// button. That happened twice on 2026-08-22 through the dev server's handoff,
// which had the same omission for the same reason: this file was written when
// the app never touched the GPU.
//
// It is bounded, and it runs before the launch rather than between the launch
// and the exit -- the delay this file spent a day removing was in the latter
// position, where it costs a "close the current application?" prompt. Here
// there is no outgoing launch to race yet.
extern void flutter_vita_gpu_shutdown(void) __attribute__((weak));

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

  // 0xFFFFF rather than the documented 0x20000, matching what the receiver
  // itself uses to launch the app; it is the value known to work on this
  // console.
  if (flutter_vita_gpu_shutdown != NULL) {
    flutter_vita_gpu_shutdown();
  }

  {
    char uri[48];
    snprintf(uri, sizeof uri, "psgm:play?titleid=%s", receiver_titleid());
    sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  }

  // Exit immediately. Nothing may go between the launch and this line.
  //
  // There was a `sceKernelDelayThread(100 * 1000)` here, justified as "the
  // launch is asynchronous, exiting instantly has been known to race it, and a
  // tenth of a second costs nothing on a path that is already ending". The
  // tenth of a second cost a prompt on every single bail, which is the whole
  // thing this file exists to avoid, and the answer was already written down
  // in the receiver that does the same switch in the other direction:
  //
  //     Exit at once rather than lingering. The "close the current
  //     application?" prompt appears only because the outgoing app is still
  //     alive; launchers that switch silently exit straight after issuing the
  //     launch.
  //         -- receiver/src/main.c, cmd_launch
  //
  // The receiver launches an app on every deploy and has never prompted. This
  // did, on every bail, and the only difference was the sleep.
  //
  // There is nothing left to race, either: record() above already called
  // sceIoSyncByFd and sceIoClose, so the reason is on disk before the launch
  // is even requested. The delay was protecting a write that had already
  // completed.
  //
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
