#include "devserver.h"

#include <psp2/appmgr.h>
#include <psp2/bgapputil.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/sysmodule.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Defined by the app, not here. Weak, because this file also builds into the
// m1 spike, which has no bailout.c -- a hard reference would break that link
// for a command the spike does not need. Callers must check it.
__attribute__((weak)) void vita_bail_to_loader(const char* reason);

// sceNetInit wants a pool it owns for the lifetime of the stack. Static rather
// than malloc'd so a fragmented heap late in a run cannot fail the one thing
// that lets us recover remotely.
static char g_net_pool[16 * 1024];

static void (*g_log)(const char*) = NULL;

static const void* (*g_read_framebuffer)(unsigned int*, char*, unsigned int) =
    NULL;

static void (*g_tap)(int, int) = NULL;
static void (*g_overlay)(int) = NULL;

void dev_server_set_tap_handler(void (*tap)(int x, int y)) {
  g_tap = tap;
}

void dev_server_set_overlay_handler(void (*overlay)(int on)) {
  g_overlay = overlay;
}

// See devserver.h: the loader (ADR-0016) links this same server and needs a
// different port, three commands of its own, and a smaller surface.
static int g_port = DEVSERVER_PORT;
static int (*g_extra)(int, const char*, int*) = NULL;
static int g_minimal = 0;
static void (*g_ready)(void) = NULL;

void dev_server_set_port(int port) {
  g_port = port;
}

void dev_server_set_command_handler(
    int (*handle)(int sock, const char* line, int* stop)) {
  g_extra = handle;
}

void dev_server_set_minimal(int minimal) {
  g_minimal = minimal;
}

void dev_server_set_ready_handler(void (*ready)(void)) {
  g_ready = ready;
}

// Let go of the GPU before this process ends.
//
// Defined by the embedder when it is running the GL path, absent otherwise --
// hence weak. Every exit below launches another application and then calls
// sceKernelExitProcess, and under GL that leaves a live GXM context and queued
// flips pointing at memory the kernel is about to reclaim. The console locks
// up hard enough to need the power button; the PS button does not respond,
// because the shell composites through the same driver. See the note on
// flutter_vita_gpu_shutdown in vita_embedder.cc.
extern void flutter_vita_gpu_shutdown(void) __attribute__((weak));

static void release_gpu(void) {
  if (flutter_vita_gpu_shutdown != NULL) {
    flutter_vita_gpu_shutdown();
  }
}

void dev_server_set_framebuffer_source(
    const void* (*read_framebuffer)(unsigned int* size,
                                    char* describe,
                                    unsigned int describe_size)) {
  g_read_framebuffer = read_framebuffer;
}

// Defined next to the supervisor switch, used by `handoff` well above it.
static int read_loader_titleid(char* out, int max);

static void logf_(const char* fmt, ...) {
  if (g_log == NULL) return;
  char buf[256];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  g_log(buf);
}

// Reads one \n-terminated command. Returns the length, 0 on clean close, or
// negative on error. Strips a trailing \r so telnet and netcat both work.
static int recv_line(int sock, char* out, int max) {
  int n = 0;
  while (n < max - 1) {
    char c;
    const int r = sceNetRecv(sock, &c, 1, 0);
    if (r == 0) return 0;
    if (r < 0) return r;
    if (c == '\n') break;
    out[n++] = c;
  }
  if (n > 0 && out[n - 1] == '\r') n--;
  out[n] = '\0';
  return n;
}

static void send_str(int sock, const char* s) {
  sceNetSend(sock, s, strlen(s), 0);
}

void dev_server_send(int sock, const char* s) {
  send_str(sock, s);
}

void dev_server_log(const char* msg) {
  if (g_log != NULL) g_log(msg);
}

// Writes `size` bytes from the socket to `dest`, via a sibling temp file that is
// renamed into place only once every byte has arrived. A dropped connection
// mid-transfer therefore leaves the installed eboot.bin untouched -- which
// matters, because the alternative is reinstalling the vpk by hand.
static int cmd_upload(int sock, const char* dest, int size) {
  char tmp[256];
  snprintf(tmp, sizeof tmp, "%s.tmp", dest);
  sceIoRemove(tmp);

  SceUID fd = sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) {
    logf_("  [dev] cannot open %s: 0x%08X\n", tmp, (unsigned)fd);
    send_str(sock, "ERR open\n");
    return -1;
  }

  static char buf[32 * 1024];
  int remaining = size;
  while (remaining > 0) {
    const int want = remaining < (int)sizeof buf ? remaining : (int)sizeof buf;
    const int got = sceNetRecv(sock, buf, want, 0);
    if (got <= 0) {
      sceIoClose(fd);
      sceIoRemove(tmp);
      logf_("  [dev] upload aborted with %d of %d bytes left\n", remaining,
            size);
      send_str(sock, "ERR short\n");
      return -1;
    }
    if (sceIoWrite(fd, buf, got) != got) {
      sceIoClose(fd);
      sceIoRemove(tmp);
      send_str(sock, "ERR write\n");
      return -1;
    }
    remaining -= got;
  }
  sceIoClose(fd);

  // sceIoRename will not overwrite, so the old file goes first. This is the
  // only window where neither file is in place; it is a few milliseconds and
  // the .tmp is already complete on disc.
  sceIoRemove(dest);
  const int rr = sceIoRename(tmp, dest);
  if (rr < 0) {
    logf_("  [dev] rename failed: 0x%08X\n", (unsigned)rr);
    send_str(sock, "ERR rename\n");
    return -1;
  }

  logf_("  [dev] wrote %d bytes to %s\n", size, dest);
  send_str(sock, "OK\n");
  return 0;
}

static void cmd_log(int sock, const char* log_path) {
  SceUID fd = sceIoOpen(log_path, SCE_O_RDONLY, 0777);
  if (fd < 0) {
    send_str(sock, "ERR nolog\n");
    return;
  }
  static char buf[8 * 1024];
  int n;
  while ((n = sceIoRead(fd, buf, sizeof buf)) > 0) {
    sceNetSend(sock, buf, n, 0);
  }
  sceIoClose(fd);
}

// One connection, one or more commands. Returns 1 if the caller should stop
// serving (exit or relaunch), 0 to keep going.
static int serve(int sock, const char* log_path, const char* eboot_path) {
  char line[256];
  for (;;) {
    const int n = recv_line(sock, line, sizeof line);
    if (n <= 0) return 0;

    // The product's own commands run first, so they can also shadow a
    // built-in rather than only extend the set.
    if (g_extra != NULL) {
      int stop = 0;
      if (g_extra(sock, line, &stop)) {
        if (stop) return 1;
        continue;
      }
    }

    // In minimal mode everything outside the deploy and debug loop is refused
    // -- see dev_server_set_minimal. The list is spelled out here rather than
    // deleted from the dispatch below because both products link the same
    // file, and an app under development still wants the whole thing.
    if (g_minimal && strcmp(line, "ping") != 0 && strcmp(line, "probe") != 0 &&
        strcmp(line, "log") != 0 && strncmp(line, "get ", 4) != 0 &&
        strncmp(line, "put ", 4) != 0 && strcmp(line, "shot") != 0 &&
        strcmp(line, "shotinfo") != 0) {
      send_str(sock, "ERR not served here (ping|probe|log|get|put|shot"
                     "|shotinfo|ls|stage|install|launch|promote)\n");
      continue;
    }

    if (strcmp(line, "ping") == 0) {
      send_str(sock, "pong\n");
    } else if (strcmp(line, "log") == 0) {
      cmd_log(sock, log_path);
      return 0;  // close so the reader sees EOF
    } else if (strncmp(line, "upload ", 7) == 0) {
      // Measured, not assumed: ux0:app/<own titleid> is ENOENT from inside this
      // app's sandbox (it is mounted as app0:, read-only), and while the app
      // runs the directory is locked against every other process too -- BGFTP
      // gets 550 on it. So a running app can never replace its own eboot.bin,
      // by any route. Deploying means: exit, upload over BGFTP, launch.
      send_str(sock,
               "ERR cannot self-update: ux0:app/<self> is ENOENT in-sandbox "
               "and locked while running. Use ./dev.sh deploy\n");
      return 0;
    } else if (strncmp(line, "get ", 4) == 0) {
      // Stream a file back and close. This is what lets crash dumps and logs be
      // pulled without an FTP server: BGFTP is deliberately not part of this
      // loop, so the loop must be able to diagnose itself.
      SceUID gf = sceIoOpen(line + 4, SCE_O_RDONLY, 0777);
      if (gf < 0) {
        char m[192];
        snprintf(m, sizeof m, "ERR open 0x%08X %s\n", (unsigned)gf, line + 4);
        send_str(sock, m);
        return 0;
      }
      static char gbuf[32 * 1024];
      int gn;
      while ((gn = sceIoRead(gf, gbuf, sizeof gbuf)) > 0) {
        int off = 0;
        while (off < gn) {
          const int w = sceNetSend(sock, gbuf + off, gn - off, 0);
          if (w <= 0) break;
          off += w;
        }
      }
      sceIoClose(gf);
      return 0;  // close so the reader sees EOF
    } else if (strcmp(line, "probe") == 0) {
      // ux0:app/<self> may be read-only from inside the app's own sandbox, or
      // locked because the running binary lives there. BGFTP writes it happily
      // from another process, so the difference matters and is worth measuring
      // rather than assuming.
      static const char* const dirs[] = {
          "ux0:data/flutter-vita", "ux0:app/FVTA00002", "ux0:data", "ux0:",
          "ur0:data", NULL};
      for (int i = 0; dirs[i] != NULL; i++) {
        char path[256], msg[320];
        snprintf(path, sizeof path, "%s/.fvita_probe", dirs[i]);
        SceUID fd = sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC,
                              0777);
        if (fd >= 0) {
          sceIoWrite(fd, "x", 1);
          sceIoClose(fd);
          sceIoRemove(path);
          snprintf(msg, sizeof msg, "WRITABLE  %s\n", dirs[i]);
        } else {
          snprintf(msg, sizeof msg, "no (0x%08X)  %s\n", (unsigned)fd,
                   dirs[i]);
        }
        send_str(sock, msg);
      }
      return 0;
    } else if (strncmp(line, "put ", 4) == 0) {
      // put <size> <path>. M1 is an UNSAFE self too, so it can write ux0:app --
      // which is how a new *loader* gets installed. Each app can now replace
      // the other, and no FTP server is involved in either direction.
      char* sp = strchr(line + 4, ' ');
      if (sp == NULL) { send_str(sock, "ERR put <size> <path>\n"); return 0; }
      *sp = '\0';
      const int size = atoi(line + 4);
      const char* path = sp + 1;
      if (size < 0 || size > 64 * 1024 * 1024) { send_str(sock, "ERR size\n"); return 0; }
      char tmp[256];
      snprintf(tmp, sizeof tmp, "%s.tmp", path);
      sceIoRemove(tmp);
      SceUID fd = sceIoOpen(tmp, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
      if (fd < 0) {
        char m[192];
        snprintf(m, sizeof m, "ERR open 0x%08X %s\n", (unsigned)fd, tmp);
        send_str(sock, m);
        return 0;
      }
      static char pbuf[32 * 1024];
      int left = size;
      while (left > 0) {
        const int want = left < (int)sizeof pbuf ? left : (int)sizeof pbuf;
        const int got = sceNetRecv(sock, pbuf, want, 0);
        if (got <= 0) { sceIoClose(fd); sceIoRemove(tmp); send_str(sock, "ERR short\n"); return 0; }
        sceIoWrite(fd, pbuf, got);
        left -= got;
      }
      sceIoClose(fd);
      // Rename only after the whole file has landed, so a dropped transfer
      // cannot leave a half-written binary in place.
      sceIoRemove(path);
      const int rr = sceIoRename(tmp, path);
      char m[192];
      if (rr < 0) snprintf(m, sizeof m, "ERR rename 0x%08X\n", (unsigned)rr);
      else snprintf(m, sizeof m, "OK %d -> %s\n", size, path);
      send_str(sock, m);
    } else if (strcmp(line, "bail") == 0 || strcmp(line, "abort") == 0) {
      // Exercise the crash-recovery path on demand.
      //
      // `bail` takes the clean route deliberately; `abort` goes through libc's
      // abort(), which is the symbol the app overrides, so it also proves the
      // override is actually linked rather than merely compiled. Both should
      // look identical from here: the socket closes, no dialog appears on the
      // panel, and the loader answers within a few seconds.
      //
      // A recovery mechanism nobody can trigger is a recovery mechanism nobody
      // knows is broken. This one is checkable in ten seconds from the host.
      send_str(sock, "OK bailing to the loader\n");
      sceNetSocketClose(sock);
      logf_("  [dev] bail requested\n");
      // Not before abort(): a deliberate abort is testing the crash path, and
      // quiescing the GPU first would make it a different test.
      if (line[0] != 'a') {
        release_gpu();
      }
      sceKernelDelayThread(200 * 1000);
      if (line[0] == 'a') {
        abort();
      }
      if (vita_bail_to_loader != NULL) {
        vita_bail_to_loader("requested over the dev server");
      }
      sceKernelExitProcess(1);
      for (;;) {
        sceKernelDelayThread(1000 * 1000);
      }
    } else if (strncmp(line, "handoff", 7) == 0 &&
               (line[7] == '\0' || line[7] == ' ')) {
      // The other half of the loop. We cannot replace our own eboot.bin, and
      // while we run nobody else can either -- so hand control to the loader,
      // which can do both once we are gone. It launches us back afterwards.
      //
      // Which loader is not a constant any more. It used to be FVTA00003 and
      // nothing else, which was true right up until that slot was emptied and
      // every handoff started launching a title that did not exist -- the
      // shell falls back to something, so the failure looks like a puzzle
      // rather than an error. Resolution order: the argument, then
      // loader.titleid, then the historical default. The file is there so a
      // console whose loader has moved can be corrected with one `put`,
      // without rebuilding and reinstalling every app on it.
      char loader[16];
      if (line[7] == ' ' && line[8] != '\0') {
        snprintf(loader, sizeof loader, "%s", line + 8);
      } else if (!read_loader_titleid(loader, sizeof loader)) {
        snprintf(loader, sizeof loader, "%s", DEVSERVER_DEFAULT_LOADER);
      }
      char msg[64];
      snprintf(msg, sizeof msg, "OK handing off to %s\n", loader);
      send_str(sock, msg);
      sceNetSocketClose(sock);
      logf_("  [dev] handing off to %s\n", loader);
      release_gpu();
      sceKernelDelayThread(200 * 1000);
      char uri[64];
      snprintf(uri, sizeof uri, "psgm:play?titleid=%s", loader);
      sceAppMgrLaunchAppByUri(0xFFFFF, uri);
      // Exit immediately. Lingering here is what produced the "close the
      // current application?" prompt: the shell only asks because we are still
      // running. Launchers that switch silently (HEXFlow, RetroFlow) all exit
      // straight after issuing the launch.
      sceKernelExitProcess(0);
      for (;;) {
        sceKernelDelayThread(1000 * 1000);
      }
    } else if (strcmp(line, "relaunch") == 0) {
      send_str(sock, "OK relaunching\n");
      sceNetSocketClose(sock);
      logf_("  [dev] relaunching\n");
      release_gpu();
      sceKernelDelayThread(200 * 1000);  // let the socket drain
      sceAppMgrLoadExec("app0:eboot.bin", NULL, NULL);
      // Only reached if LoadExec refused.
      logf_("  [dev] sceAppMgrLoadExec returned -- relaunch refused\n");
      return 1;
    } else if (strcmp(line, "shot") == 0 || strcmp(line, "shotinfo") == 0) {
      // Raw framebuffer, no header, so the host can wrap it in a PNG.
      //
      // `shotinfo` returns only the description line, which is the part that
      // says whether the capture means anything: if the pointer the display
      // controller holds is not the one the app drew into, then the pixels
      // below are real but nobody is looking at them.
      char describe[192];
      describe[0] = '\0';
      unsigned int size = 0;
      const void* pixels =
          g_read_framebuffer == NULL
              ? NULL
              : g_read_framebuffer(&size, describe, sizeof describe);

      if (line[4] == 'i') {  // shotinfo
        send_str(sock, describe[0] != '\0' ? describe : "ERR no framebuffer\n");
      } else if (pixels == NULL || size == 0) {
        send_str(sock, "ERR no framebuffer\n");
      } else {
        // Straight out the socket. sceNetSend can short-write on a 2 MB
        // payload, so loop -- a partial frame decodes as a skewed image, which
        // looks like a rendering bug rather than a truncated transfer.
        const char* p = (const char*)pixels;
        unsigned int sent = 0;
        while (sent < size) {
          const int n = sceNetSend(sock, p + sent, size - sent, 0);
          if (n <= 0) {
            break;
          }
          sent += (unsigned int)n;
        }
        logf_("  [dev] shot %u/%u bytes\n", sent, size);
      }
      return 0;
    } else if (strncmp(line, "tap ", 4) == 0) {
      int x = 0, y = 0;
      if (sscanf(line + 4, "%d %d", &x, &y) != 2) {
        send_str(sock, "ERR tap <x> <y>\n");
      } else if (g_tap == NULL) {
        send_str(sock, "ERR no tap handler\n");
      } else {
        g_tap(x, y);
        char m[64];
        snprintf(m, sizeof m, "OK tap %d %d\n", x, y);
        send_str(sock, m);
      }
    } else if (strncmp(line, "overlay ", 8) == 0) {
      // Turn the debug HUD off for a screenshot, and back on afterwards.
      //
      // Worth a command rather than a rebuild: the HUD sits on top of the app,
      // so every capture taken for documentation has it in the corner, and the
      // only alternatives are relinking with the overlay compiled out or
      // cropping the picture afterwards.
      if (g_overlay == NULL) {
        send_str(sock, "ERR no overlay handler\n");
      } else if (strcmp(line + 8, "on") == 0) {
        g_overlay(1);
        send_str(sock, "OK overlay on\n");
      } else if (strcmp(line + 8, "off") == 0) {
        g_overlay(0);
        send_str(sock, "OK overlay off\n");
      } else {
        send_str(sock, "ERR overlay on|off\n");
      }
    } else if (strcmp(line, "crash") == 0) {
      // Deliberately fault, to get a crash dump out of a process that is not
      // crashing.
      //
      // A hang is the one failure the log cannot describe: it says what
      // happened last, never what everything is currently blocked on. The
      // dump does -- it carries every thread's PC, which is exactly the
      // question a deadlock poses. m3 hung inside FlutterEngineRun after
      // starting its threads and there was no other way to see where.
      //
      // Kept out of the way of ordinary use: nothing sends this by accident,
      // and the alternative was waiting for a fault that may never come.
      send_str(sock, "OK faulting\n");
      *(volatile unsigned int*)0 = 0xDEAD;
      return 1;  // not reached
    } else if (n > 0) {
    send_str(sock, "ERR unknown (ping|probe|log|get|put|shot|shotinfo|"
                                    "tap <x> <y>|overlay on|off|handoff [titleid]|relaunch|"
                                    "crash|exit)\n");
    }
  }
}

// Start the crash supervisor: eboot2.bin, as a background application.
//
// A background process is not the foreground app, so it outlives this one
// dying. That is what lets a crash be recovered without someone walking to the
// console and tapping the loader -- which is the actual limit on how fast this
// port can be debugged, since builds take twenty seconds and a human does not.
//
// Two things about the argument, both of which cost days. The mode is 0:
// VitaSDK's header says "must be 1" and defines INVALID_ARG as 0x80106502,
// while Sony's own header says 0 and 0x80106501, and 0x80106501 is exactly what
// mode 1 returned on every boot. And the app directory must contain
// sce_sys/param2.sfo, a second manifest describing eboot2.bin, or the call
// cannot succeed whatever mode is passed.
//
// Failure is logged and ignored. Losing the supervisor costs a tap per crash,
// which is where this started; it is not a reason to take the app down.
//
// Off unless switched on, because a failed start is not silent: the shell puts
// "could not find app" on the panel at every launch, in front of the app. The
// switch is a file rather than a build flag so that flipping it costs one
// `put` instead of a rebuild and a 12 MB upload -- and it reads the file's
// *contents*, not its existence, because turning it back off would otherwise
// need a delete, which the loader currently installed on the device cannot do.
//
//   echo -n 1 > on  &&  dev.sh put on ux0:data/flutter-vita/supervisor.on
// Which title `handoff` hands to. One line, no newline needed:
//
//   printf 'put 9 ux0:data/flutter-vita/loader.titleid\nFVTA00004' | nc <ip> 1339
//
// Returns 0 when the file is absent or does not hold nine plausible
// characters, so a truncated or half-written file falls back rather than
// launching something arbitrary.
static int read_loader_titleid(char* out, int max) {
  const SceUID fd =
      sceIoOpen("ux0:data/flutter-vita/loader.titleid", SCE_O_RDONLY, 0777);
  if (fd < 0) return 0;
  char buf[16];
  const int n = sceIoRead(fd, buf, sizeof buf - 1);
  sceIoClose(fd);
  if (n < 9) return 0;
  buf[9] = '\0';
  for (int i = 0; i < 9; i++) {
    if (buf[i] <= ' ') return 0;
  }
  snprintf(out, max, "%s", buf);
  return 1;
}

static int supervisor_enabled(void) {
  const SceUID fd =
      sceIoOpen("ux0:data/flutter-vita/supervisor.on", SCE_O_RDONLY, 0777);
  if (fd < 0) return 0;
  char c = '0';
  const int n = sceIoRead(fd, &c, 1);
  sceIoClose(fd);
  return n == 1 && c == '1';
}

static void start_supervisor(void) {
  // Never for the loader. The supervisor's job is to relaunch the loader when
  // an app dies; a loader that starts one is asking to be recovered to itself,
  // and the two would contend for the same background title id besides.
  // ADR-0016 decision 8.
  if (g_minimal) return;
  if (!supervisor_enabled()) return;
  const int mod = sceSysmoduleLoadModule(SCE_SYSMODULE_BG_APP_UTIL);
  if (mod < 0) {
    logf_("  [dev] bgapputil module 0x%08X\n", (unsigned)mod);
    return;
  }
  const int r = sceBgAppUtilStartBgApp(0);
  // Already running is the normal case after the first launch: the supervisor
  // survives the app, so every launch after the first finds it there.
  logf_("  [dev] supervisor start 0x%08X\n", (unsigned)r);
}

int dev_server_run(void (*log_line)(const char* msg),
                   const char* log_path,
                   const char* eboot_path) {
  g_log = log_line;

  start_supervisor();

  if (sceSysmoduleLoadModule(SCE_SYSMODULE_NET) < 0) {
    logf_("  [dev] SCE_SYSMODULE_NET failed to load\n");
    return -1;
  }
  SceNetInitParam np;
  np.memory = g_net_pool;
  np.size = sizeof g_net_pool;
  np.flags = 0;
  // Already-initialised is fine; anything else is not.
  const int ni = sceNetInit(&np);
  if (ni < 0 && ni != (int)0x80410103 /* SCE_NET_ERROR_EBUSY */) {
    logf_("  [dev] sceNetInit failed: 0x%08X\n", (unsigned)ni);
    return -1;
  }
  sceNetCtlInit();

  SceNetCtlInfo info;
  if (sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_IP_ADDRESS, &info) >= 0) {
    logf_("  [dev] listening on %s:%d\n", info.ip_address, g_port);
  } else {
    logf_("  [dev] listening on port %d (no IP yet)\n", g_port);
  }

  const int srv = sceNetSocket("fvita-dev", SCE_NET_AF_INET,
                               SCE_NET_SOCK_STREAM, 0);
  if (srv < 0) {
    logf_("  [dev] socket failed: 0x%08X\n", (unsigned)srv);
    return -1;
  }
  int one = 1;
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_REUSEADDR, &one,
                   sizeof one);

  SceNetSockaddrIn addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = SCE_NET_AF_INET;
  addr.sin_addr.s_addr = sceNetHtonl(SCE_NET_INADDR_ANY);
  addr.sin_port = sceNetHtons(g_port);
  if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
      sceNetListen(srv, 2) < 0) {
    logf_("  [dev] bind/listen on %d failed\n", g_port);
    sceNetSocketClose(srv);
    return -1;
  }

  // Non-blocking accept so the pad stays responsive: START must keep working
  // even when the network is down, which on this device it regularly is.
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &one, sizeof one);

  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);

  // Everything the network needs is up. Anything registered here can now call
  // into SceNet and SceNetCtl, which before this point are unresolved stubs
  // rather than functions that fail politely.
  if (g_ready != NULL) g_ready();

  for (;;) {
    const int c = sceNetAccept(srv, NULL, NULL);
    if (c >= 0) {
      // Blocking for the conversation itself; a half-sent upload should wait,
      // not spin.
      int zero = 0;
      sceNetSetsockopt(c, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &zero,
                       sizeof zero);
      const int stop = serve(c, log_path, eboot_path);
      sceNetSocketClose(c);
      if (stop) {
        sceNetSocketClose(srv);
        return 0;
      }
      continue;
    }

    sceCtrlPeekBufferPositive(0, &pad, 1);
    if (pad.buttons & SCE_CTRL_START) {
      logf_("  [dev] START pressed, shutting down\n");
      sceNetSocketClose(srv);
      return 0;
    }
    sceKernelDelayThread(30 * 1000);
  }
}
