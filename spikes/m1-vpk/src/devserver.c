#include "devserver.h"

#include <psp2/appmgr.h>
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

// sceNetInit wants a pool it owns for the lifetime of the stack. Static rather
// than malloc'd so a fragmented heap late in a run cannot fail the one thing
// that lets us recover remotely.
static char g_net_pool[16 * 1024];

static void (*g_log)(const char*) = NULL;

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

    if (strcmp(line, "ping") == 0) {
      send_str(sock, "pong\n");
    } else if (strcmp(line, "log") == 0) {
      cmd_log(sock, log_path);
      return 0;  // close so the reader sees EOF
    } else if (strncmp(line, "upload ", 7) == 0) {
      const int size = atoi(line + 7);
      if (size <= 0 || size > 64 * 1024 * 1024) {
        send_str(sock, "ERR size\n");
        continue;
      }
      cmd_upload(sock, eboot_path, size);
    } else if (strcmp(line, "relaunch") == 0) {
      send_str(sock, "OK relaunching\n");
      sceNetSocketClose(sock);
      logf_("  [dev] relaunching\n");
      sceKernelDelayThread(200 * 1000);  // let the socket drain
      sceAppMgrLoadExec("app0:eboot.bin", NULL, NULL);
      // Only reached if LoadExec refused.
      logf_("  [dev] sceAppMgrLoadExec returned -- relaunch refused\n");
      return 1;
    } else if (strcmp(line, "exit") == 0) {
      send_str(sock, "OK\n");
      return 1;
    } else if (n > 0) {
      send_str(sock, "ERR unknown (ping|log|upload <n>|relaunch|exit)\n");
    }
  }
}

int dev_server_run(void (*log_line)(const char* msg),
                   const char* log_path,
                   const char* eboot_path) {
  g_log = log_line;

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
    logf_("  [dev] listening on %s:%d\n", info.ip_address, DEVSERVER_PORT);
  } else {
    logf_("  [dev] listening on port %d (no IP yet)\n", DEVSERVER_PORT);
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
  addr.sin_port = sceNetHtons(DEVSERVER_PORT);
  if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
      sceNetListen(srv, 2) < 0) {
    logf_("  [dev] bind/listen on %d failed\n", DEVSERVER_PORT);
    sceNetSocketClose(srv);
    return -1;
  }

  // Non-blocking accept so the pad stays responsive: START must keep working
  // even when the network is down, which on this device it regularly is.
  sceNetSetsockopt(srv, SCE_NET_SOL_SOCKET, SCE_NET_SO_NBIO, &one, sizeof one);

  SceCtrlData pad;
  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG);

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
