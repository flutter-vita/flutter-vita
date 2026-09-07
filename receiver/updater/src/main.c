// The receiver's updater: the one app whose job is to replace the receiver.
//
// A running title cannot write its own directory. app0: is the read-only mount
// of ux0:app/<own id>, so every attempt is 0x8001000D, and the receiver can
// install anything on this console except a new receiver.
//
// This is that path as its own title. No engine, no network, no protocol: the
// receiver stages the new build onto the card with `put`, launches this, and
// this copies the staged tree over ux0:app/<target> and launches it back.
//
// eboot.bin is written last, after every asset, because a half-written eboot is
// the one file that cannot be recovered from the console itself. The eboot it
// replaces is copied to ux0:data/flutter-vita/receiver-backup first, so a build
// that boots into nothing is one L-trigger away from the build that worked.
//
// The staging directory:
//
//   ux0:data/flutter-vita/receiver-update/manifest.txt   target + file list
//   ux0:data/flutter-vita/receiver-update/files/<rel>    the payload

#include <psp2/appmgr.h>
#include <psp2/ctrl.h>
#include <psp2/io/dirent.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <stdio.h>
#include <string.h>

#include "debugScreen.h"

#define printf psvDebugScreenPrintf

#define STAGE_DIR "ux0:data/flutter-vita/receiver-update"
#define MANIFEST STAGE_DIR "/manifest.txt"
#define PAYLOAD STAGE_DIR "/files"
#define BACKUP_DIR "ux0:data/flutter-vita/receiver-backup"

#define SELF_TITLEID "FVTA00009"
#define LOADER_TITLEID "FVTA00001"
#define MAX_FILES 64
#define COPY_BUF (256 * 1024)

static char g_target[16];
static char g_files[MAX_FILES][160];
static int g_count;

static char g_buf[COPY_BUF];

// A pause long enough to read, on a screen with no other way to say anything.
static void hold(int seconds) {
  sceKernelDelayThread((SceUInt)seconds * 1000 * 1000);
}

static int mkparents(char* path) {
  for (char* p = strchr(path, '/'); p != NULL; p = strchr(p + 1, '/')) {
    *p = '\0';
    sceIoMkdir(path, 0777);
    *p = '/';
  }
  return 0;
}

// Returns the byte count, or a negative sce error. The destination's parents
// are created; the destination itself is truncated.
static int copy_file(const char* src, const char* dst) {
  const SceUID in = sceIoOpen(src, SCE_O_RDONLY, 0777);
  if (in < 0) return in;

  char parents[192];
  snprintf(parents, sizeof parents, "%s", dst);
  mkparents(parents);

  const SceUID out =
      sceIoOpen(dst, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (out < 0) {
    sceIoClose(in);
    return out;
  }

  int total = 0;
  for (;;) {
    const int n = sceIoRead(in, g_buf, sizeof g_buf);
    if (n < 0) { total = n; break; }
    if (n == 0) break;
    const int w = sceIoWrite(out, g_buf, n);
    if (w != n) { total = w < 0 ? w : -1; break; }
    total += n;
  }
  sceIoClose(out);
  sceIoClose(in);
  return total;
}

static int file_size(const char* path) {
  SceIoStat st;
  if (sceIoGetstat(path, &st) < 0) return -1;
  return (int)st.st_size;
}

// One `key value` per line. Unknown keys are ignored rather than fatal: the
// receiver that writes this file is updated more often than the app that reads
// it, and a manifest from a newer receiver must not brick the older updater.
static int read_manifest(void) {
  const SceUID fd = sceIoOpen(MANIFEST, SCE_O_RDONLY, 0777);
  if (fd < 0) return 0;
  static char text[MAX_FILES * 168];
  const int n = sceIoRead(fd, text, sizeof text - 1);
  sceIoClose(fd);
  if (n <= 0) return 0;
  text[n] = '\0';

  char* p = text;
  while (*p != '\0') {
    char* nl = strchr(p, '\n');
    if (nl != NULL) *nl = '\0';
    if (strncmp(p, "target ", 7) == 0) {
      snprintf(g_target, sizeof g_target, "%s", p + 7);
    } else if (strncmp(p, "file ", 5) == 0 && g_count < MAX_FILES) {
      snprintf(g_files[g_count], sizeof g_files[g_count], "%s", p + 5);
      g_count++;
    }
    if (nl == NULL) break;
    p = nl + 1;
  }
  return g_count;
}

static int looks_like_titleid(const char* s) {
  if (strlen(s) != 9) return 0;
  for (int i = 0; i < 4; i++) {
    if (s[i] < 'A' || s[i] > 'Z') return 0;
  }
  for (int i = 4; i < 9; i++) {
    if (s[i] < '0' || s[i] > '9') return 0;
  }
  return 1;
}

// The only way out of this app.
//
// Never `return`, never sceKernelExitProcess on its own: either drops the
// console on the LiveArea home screen, which answers no port and cannot be
// driven from the network. Whatever went wrong, the right end state is the
// receiver running, because the receiver is the thing that can be talked to.
static void launch(const char* titleid) {
  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", titleid);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  // Exit at once rather than lingering: the "close the current application?"
  // prompt appears only because the outgoing app is still alive.
  sceKernelExitProcess(0);
}

// `titleid` first, the receiver second. They are the same id in every ordinary
// run; they differ only when someone pointed this at another title and that
// title is the thing that will not start.
static void give_up(const char* titleid, int seconds) {
  hold(seconds);
  if (titleid != NULL && titleid[0] != '\0') launch(titleid);
  launch(LOADER_TITLEID);
}

// Put the eboot that was running back. Called when the new one could not be
// written in full, and from the L-trigger escape hatch.
static int restore(const char* titleid) {
  char backup[192], live[192];
  snprintf(backup, sizeof backup, "%s/%s-eboot.bin", BACKUP_DIR, titleid);
  snprintf(live, sizeof live, "ux0:app/%s/eboot.bin", titleid);
  const int want = file_size(backup);
  if (want <= 0) {
    printf("  no backup at %s\n", backup);
    return -1;
  }
  printf("  restoring %d bytes\n", want);
  const int got = copy_file(backup, live);
  if (got != want) {
    printf("  RESTORE FAILED (%d of %d)\n", got, want);
    return -1;
  }
  return 0;
}

int main(void) {
  psvDebugScreenInit();
  printf("\n  Flutter Vita receiver updater\n\n");

  if (read_manifest() == 0 || g_target[0] == '\0') {
    printf("  nothing staged.\n");
    hold(2);
    // Nothing to do is not an error: this app is in the bubble list, and
    // tapping it should hand the console back rather than sit there.
    launch(LOADER_TITLEID);
  }

  if (!looks_like_titleid(g_target) || strcmp(g_target, SELF_TITLEID) == 0) {
    printf("  refusing target '%s'\n", g_target);
    give_up(NULL, 8);
  }

  char appdir[64];
  snprintf(appdir, sizeof appdir, "ux0:app/%s", g_target);
  SceIoStat st;
  if (sceIoGetstat(appdir, &st) < 0) {
    printf("  %s is not installed\n", appdir);
    give_up(NULL, 8);
  }

  SceCtrlData pad;
  memset(&pad, 0, sizeof pad);
  sceCtrlPeekBufferPositive(0, &pad, 1);
  if ((pad.buttons & SCE_CTRL_LTRIGGER) != 0) {
    printf("  L held: restoring the previous %s\n\n", g_target);
    if (restore(g_target) == 0) {
      printf("\n  restored. launching %s\n", g_target);
      hold(2);
      launch(g_target);
    }
    give_up(g_target, 10);
  }

  printf("  target   %s\n", g_target);
  printf("  files    %d\n\n", g_count);

  // The eboot is copied last and separately; everything else goes first, so a
  // failure among the assets leaves the old eboot running against old assets
  // rather than a new eboot against half of them.
  int eboot = -1;
  for (int i = 0; i < g_count; i++) {
    if (strcmp(g_files[i], "eboot.bin") == 0) { eboot = i; continue; }
    char src[224], dst[224];
    snprintf(src, sizeof src, "%s/%s", PAYLOAD, g_files[i]);
    snprintf(dst, sizeof dst, "ux0:app/%s/%s", g_target, g_files[i]);
    const int want = file_size(src);
    const int got = copy_file(src, dst);
    printf("  %-46s %10d\n", g_files[i], got);
    if (got != want) {
      // Negative is an sce error and the hex is the diagnostic: 0x8001000D is
      // a safe self being told it may not write there, which is what the
      // first build of this app spent a deploy doing in silence.
      if (got < 0) {
        printf("\n  FAILED on %s: 0x%08X\n", g_files[i], (unsigned)got);
      } else {
        printf("\n  FAILED on %s (%d of %d)\n", g_files[i], got, want);
      }
      printf("  the old %s is untouched. launching it.\n", g_target);
      hold(15);
      launch(g_target);
    }
  }

  if (eboot >= 0) {
    char src[224], dst[224], backup[192];
    snprintf(src, sizeof src, "%s/eboot.bin", PAYLOAD);
    snprintf(dst, sizeof dst, "ux0:app/%s/eboot.bin", g_target);
    snprintf(backup, sizeof backup, "%s/%s-eboot.bin", BACKUP_DIR, g_target);

    // The eboot about to be replaced is the one that just launched this app,
    // so it is known to boot. That is the whole value of the backup, and it is
    // why it is taken here rather than kept from some earlier build.
    sceIoMkdir("ux0:data/flutter-vita", 0777);
    sceIoMkdir(BACKUP_DIR, 0777);
    printf("\n  backing up the running eboot\n");
    const int have = file_size(dst);
    const int kept = copy_file(dst, backup);
    if (kept != have) {
      printf("  could not back it up (%d of %d, 0x%08X). stopping.\n", kept,
             have, (unsigned)kept);
      hold(15);
      launch(g_target);
    }

    const int want = file_size(src);
    printf("  writing eboot.bin (%d bytes)\n", want);
    const int got = copy_file(src, dst);
    if (got != want) {
      printf("\n  SHORT WRITE (%d of %d). rolling back.\n", got, want);
      if (restore(g_target) == 0) {
        printf("  rolled back.\n");
        hold(6);
        launch(g_target);
      }
      printf("\n  %s may not boot. Hold L on the next run of this\n", g_target);
      printf("  app to try the backup again.\n");
      give_up(g_target, 20);
    }
    printf("  ok\n");
  }

  // Removed only now. Until this point a power cut leaves the manifest in
  // place and the next run redoes the copy, which is the safe direction.
  sceIoRemove(MANIFEST);

  printf("\n  done. launching %s\n", g_target);
  hold(2);
  launch(g_target);
  return 0;
}
