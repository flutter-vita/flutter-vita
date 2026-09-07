// Why ScePromoterUtil will not load for us, when it loads for everyone else.
//
// VitaShell, VitaDB Downreceiver and NeoVitaDB all register fresh title ids on
// this console. We cannot: sceSysmoduleLoadModuleInternal(0x80000024) returns
// SCE_KERNEL_ERROR_MODULEMGR_NO_LIB (0x8002D003). That has been measured three
// times -- under UNSAFE, in both spellings, and from the 91 KB C receiver as well
// as the 14 MB Flutter one, which is what rules out a memory budget. See
// experiments/vita-tooling/README.md and ADR-0016.
//
// Every one of those measurements was of our own code failing. None compared
// against a working implementation, and the tooling notes already carry the
// lesson that applies: "check your own build flags before concluding the
// platform forbids something. Four measurements were correct and the conclusion
// drawn from them was still wrong, because the variable under test was one we
// had set ourselves." That was written about the safe-self mistake. This experiment
// exists because the shape may be repeating.
//
// It reports a code for every route instead of stopping at the first refusal:
//
//   A  IsLoadedInternal first    if the module is already resident, NO_LIB from
//                                a load means something other than we assumed
//   B  LoadModuleInternal        the call the receiver makes, for the baseline
//   C  WithArg, NULL option      what most homebrew passes. Ours returns
//                                INVALID_MEMORY_ACCESS for NULL, which is
//                                itself odd and worth pinning down
//   D  WithArg, real option      the spelling the receiver ended up using
//   E  after DestroyOtherApp     some homebrew frees the other app first
//   F  IsLoaded again            state after all of the above
//
// THE RULE IN HERE: never call a scePromoterUtility* function unless a load
// returned success. A Vita import stub for a module that is not resident is
// address zero, not a function that fails, and that exact mistake has produced
// a prefetch abort at PC 0 twice in this project -- once by accident and once
// deliberately, in the belief that a failed load could be survived.

#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/promoterutil.h>
#include <psp2/sysmodule.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "debugScreen.h"

#define printf psvDebugScreenPrintf

static SceUID g_log = -1;

static void lg(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  printf("%s", buf);
  if (g_log >= 0 && n > 0) {
    sceIoWrite(g_log, buf, (SceSize)n);
  }
}

// 0x8002D003 is the one we keep getting; the rest are here so a different
// refusal is readable on the panel rather than a bare hex code.
static const char* modulemgr_name(int r) {
  switch ((unsigned)r) {
    case 0x8002D000u: return "START_FAILED";
    case 0x8002D001u: return "STOP_FAIL";
    case 0x8002D002u: return "IN_USE";
    case 0x8002D003u: return "NO_LIB";
    case 0x8002D004u: return "SYSCALL_REG";
    case 0x8002D005u: return "NOMEM_LIB";
    case 0x8002D006u: return "NOMEM_STUB";
    case 0x8002D007u: return "NOMEM_SELF";
    case 0x80022005u: return "INVALID_MEMORY_ACCESS";
    default:          return r >= 0 ? "ok" : "?";
  }
}

static void report(const char* what, int r) {
  lg("%-26s 0x%08X  %s\n", what, (unsigned)r, modulemgr_name(r));
}

int main(void) {
  psvDebugScreenInit();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_log = sceIoOpen("ux0:data/flutter-vita/promoter.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  lg("ScePromoterUtil: every route, with its code\n\n");

  int loaded = 0;

  const int a = sceSysmoduleIsLoadedInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  report("A IsLoadedInternal", a);
  if (a == 0) {
    loaded = 1;  // 0 means loaded for the IsLoaded family.
  }

  const int b = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  report("B LoadModuleInternal", b);
  if (b >= 0) loaded = 1;

  const int c = sceSysmoduleLoadModuleInternalWithArg(
      SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL, 0, NULL, NULL);
  report("C WithArg, NULL option", c);
  if (c >= 0) loaded = 1;

  int inner = 0;
  SceSysmoduleOpt opt;
  memset(&opt, 0, sizeof opt);
  opt.result = &inner;
  const int d = sceSysmoduleLoadModuleInternalWithArg(
      SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL, 0, NULL, &opt);
  report("D WithArg, real option", d);
  lg("%-26s 0x%08X  (the module's own result)\n", "  D inner", (unsigned)inner);
  if (d >= 0) loaded = 1;

  // Some homebrew frees the other app before promoting. Harmless here: there is
  // no other app, this experiment having been launched from the receiver.
  const int e0 = sceAppMgrDestroyOtherApp();
  report("E DestroyOtherApp", e0);
  const int e1 = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  report("E LoadModuleInternal", e1);
  if (e1 >= 0) loaded = 1;

  report("F IsLoadedInternal", sceSysmoduleIsLoadedInternal(
                                   SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL));

  // G: is the refusal about the promoter, or about us?
  //
  // Run 1 said NO_LIB on every route, and IsLoaded said UNLOADED rather than an
  // error -- so the id is valid and the service answers about it happily. That
  // leaves two very different worlds. If this process cannot load *any*
  // internal sysmodule, the problem is our build or our authid and the promoter
  // is a bystander. If the others load and only the promoter refuses, it is a
  // permission attached to that one module, and the thing to compare against is
  // VitaShell's binary rather than our own.
  //
  // Loaded and left loaded: unloading a sysmodule another part of the system is
  // using is a worse idea than leaking one in an experiment that exits.
  // Run 2 died here, inside the first of these, with the section header written
  // and no result line after it. That was PAF -- the shell's own UI framework,
  // which was a poor choice for a benign control: it pulls dependencies and
  // expects to be initialised by something that is not us.
  //
  // The name now goes to the log *before* the call, so a crash names the module
  // that caused it rather than leaving a blank. PAF is out of this list
  // entirely: the plain load faults, and section H loads it the way it is meant
  // to be loaded.
  //
  // The crash is itself a result worth keeping: the promoter answers NO_LIB
  // immediately, while PAF got far enough into loading to fault. Whatever stops
  // the promoter, it is not that this process is refused every internal
  // sysmodule out of hand.
  static const struct { const char* name; SceSysmoduleInternalModuleId id; }
      others[] = {
          {"JPEG_ARM", SCE_SYSMODULE_INTERNAL_JPEG_ARM},
          {"INI_FILE_PROCESSOR", SCE_SYSMODULE_INTERNAL_INI_FILE_PROCESSOR},
          {"DBUTIL", SCE_SYSMODULE_INTERNAL_DBUTIL},
      };
  lg("\nG other internal sysmodules, same call:\n");
  for (int i = 0; i < (int)(sizeof others / sizeof others[0]); i++) {
    lg("  %-24s trying...\n", others[i].name);
    const int r = sceSysmoduleLoadModuleInternal(others[i].id);
    char label[48];
    snprintf(label, sizeof label, "  %s", others[i].name);
    report(label, r);
  }

  // H: the sequence a working implementation actually uses.
  //
  // Everything above measures our own code failing, which is what the last
  // three attempts did too. VitaShell installs fresh title ids on this console,
  // and its package_installer.c does one thing first that we never did:
  //
  //     res = loadScePaf();
  //     if (res < 0) return res;
  //     res = sceSysmoduleLoadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
  //
  // NO_LIB then means exactly what it says. The promoter imports from PAF, PAF
  // is not resident in our process, so the promoter's library cannot be linked
  // and the load is refused. It was never a permission -- it was a dependency,
  // and the error has been naming it since the first measurement in August.
  //
  // No taiHEN and no kernel module anywhere in that path, which keeps this
  // inside the standing rule.
  //
  // PAF wants an argument block, and it is not optional: the plain
  // sceSysmoduleLoadModuleInternal(PAF) is what faulted twice above. The magic
  // numbers are VitaShell's verbatim -- 0x180000 is the heap it is being given.
  // Note buf[0] is a *size*, not flags, which is why zeroing a SceSysmoduleOpt
  // and only filling in `result` was never going to be the same call.
  lg("\n");
  {
    static uint32_t argp[] = {0x180000, (uint32_t)-1, (uint32_t)-1, 1,
                              (uint32_t)-1, (uint32_t)-1};
    int paf_result = -1;
    uint32_t buf[4];
    buf[0] = sizeof buf;
    buf[1] = (uint32_t)&paf_result;
    buf[2] = (uint32_t)-1;
    buf[3] = (uint32_t)-1;
    lg("H loadScePaf              trying...\n");
    const int paf = sceSysmoduleLoadModuleInternalWithArg(
        SCE_SYSMODULE_INTERNAL_PAF, sizeof argp, argp,
        (const SceSysmoduleOpt*)buf);
    report("H loadScePaf", paf);
    lg("%-26s 0x%08X  (PAF's own result)\n", "  H paf inner",
       (unsigned)paf_result);
    if (paf >= 0) {
      const int h = sceSysmoduleLoadModuleInternal(
          SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL);
      report("H PROMOTER after PAF", h);
      if (h >= 0) loaded = 1;
    }
  }

  lg("\n");
  if (!loaded) {
    // Not a formality. Calling in from here is a jump to zero.
    lg("no route loaded the module -- not calling into it.\n");
    lg("An unresolved import stub is address 0, not a function that fails.\n");
  } else {
    lg("a route loaded it. Init:\n");
    const int init = scePromoterUtilityInit();
    report("  scePromoterUtilityInit", init);
    if (init >= 0) {
      // Read-only, and about a title that certainly exists, so this asks "does
      // the promoter work for us" without installing anything.
      int exists = -1;
      const int chk = scePromoterUtilityCheckExist("FVTA00002", &exists);
      report("  CheckExist FVTA00002", chk);
      lg("%-26s %d\n", "    exists", exists);
      report("  scePromoterUtilityExit", scePromoterUtilityExit());
    }
    report("  unload PROMOTER",
           sceSysmoduleUnloadModuleInternal(SCE_SYSMODULE_INTERNAL_PROMOTER_UTIL));
    // Run 4 reached "done" and then rebooted the console. VitaShell unloads PAF
    // when it has finished and this did not, which is the only difference left
    // between the two once the load itself succeeded. Exiting a process with
    // PAF still resident is the suspect, so both come out in reverse order --
    // and the unload spelling is WithArg, like the load.
    uint32_t ubuf = 0;
    report("  unload PAF",
           sceSysmoduleUnloadModuleInternalWithArg(
               SCE_SYSMODULE_INTERNAL_PAF, 0, NULL,
               (const SceSysmoduleOpt*)&ubuf));
  }

  lg("\ndone\n");
  // The log stays open through the hold. Run 6 closed it here, before the
  // heartbeat loop, so the absence of "still here" lines on the card said
  // nothing at all about how long the experiment survived -- which was the one thing
  // that run existed to find out.

  // Deliberately does NOT hand back. Read this before "fixing" it.
  //
  // Run 4 reached "done" and rebooted the console. The suspect was PAF being
  // left resident, because that is the one thing VitaShell does that this did
  // not. Run 5 unloaded both modules -- 0x00000000 from each, logged above --
  // and rebooted anyway. So the unload was innocent and the reboot is not about
  // what is resident when we finish.
  //
  // What is left is finishing at all. The handoff this used to do here is
  // sceAppMgrLaunchAppByUri followed by sceKernelExitProcess, and experiments/t1-
  // timers has run that exact sequence many times without ever rebooting
  // anything. The only new variable is that PAF has been in this process.
  //
  // That distinction decides whether any of this is usable, because the two
  // things that will actually call the promoter -- VitaShell, and our receiver --
  // are both long-lived. Neither exits afterwards. If sitting here forever is
  // stable, the reboot is an artefact of an experiment tidying up after itself and
  // the receiver is unaffected.
  //
  // So it holds instead, and somebody taps the receiver. One tap to learn whether
  // a whole capability is safe to use is a good trade.
  lg("\nholding, not exiting. The reboot happens after this point.\n");
  lg("Open the receiver when you have read this.\n");
  // Two minutes of heartbeat, then quiet. Long enough to prove it survived
  // well past the point run 5 died at, short enough not to fill the card while
  // the console sits on a screen nobody is watching.
  for (int i = 0;; i++) {
    if (i <= 30) {
      lg("still here, %d s\n", i * 10);
      // Flushed by closing and reopening: a heartbeat that is still sitting in
      // a buffer when the console goes down is not a heartbeat.
      if (g_log >= 0) {
        sceIoClose(g_log);
        g_log = sceIoOpen("ux0:data/flutter-vita/promoter.log",
                          SCE_O_WRONLY | SCE_O_APPEND, 0777);
      }
    }
    // "Shut down" and "crashed" look identical from the network, and this
    // console suspends on its own after a few minutes with nobody touching it.
    // Holding the auto-suspend timer off makes the difference legible: if it
    // goes down now, it went down, and the heartbeat above says when.
    sceKernelPowerTick(SCE_KERNEL_POWER_TICK_DISABLE_AUTO_SUSPEND);
    sceKernelPowerTick(SCE_KERNEL_POWER_TICK_DISABLE_OLED_OFF);
    sceKernelDelayThread(10 * 1000 * 1000);
  }
  return 0;
}
