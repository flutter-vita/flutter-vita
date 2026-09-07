// K1 -- does the Vita's overlay keyboard composite over vitaGL?
//
// This port types through sceImeDialog, which is a modal common dialog: it
// takes the whole screen and gives it back when you are done. That is why the
// embedder turns text input off entirely under GL.
//
// libime (SceIme) is the other one -- sceImeOpen / sceImeUpdate / sceImeClose,
// the overlay panel the console's own browser and messages app use. The system
// renders the keyboard over the bottom of the screen and the app keeps drawing
// underneath. mswlandi/vita-libime-sample shows it working under vita2d.
//
// We do not render with vita2d. The question is whether it works under vitaGL,
// and there is a specific reason to think it should: libime composites through
// the common-dialog path, and vitaGL runs sceCommonDialogUpdate in its swap --
// gated on `vgl_has_cdlg_support && has_commondialog` (gxm.c). The second is
// literally the argument to vglSwapBuffers, which the embedder hardcodes to
// GL_FALSE. The first is only cleared when vitaGL claims the CDIALOG memory
// pool for itself, and with vglInitExtended the size of that pool computes to
// zero, so it does not.
//
// So this brings vitaGL up exactly as the embedder does, opens libime, and
// swaps with GL_TRUE. Two coloured bands are drawn with GL so the capture can
// tell "keyboard over a live app" apart from "keyboard over a black screen" --
// the second would mean the system took the display and we are back where
// sceImeDialog left us.
//
// It also prints every IME event. SCE_IME_EVENT_OPEN carries the keyboard's
// rect, which is the number Flutter needs for viewInsets.bottom and the reason
// this is worth more than a yes/no.

#include <psp2/appmgr.h>
#include <psp2/common_dialog.h>
#include <psp2/display.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/libime.h>
#include <psp2/power.h>
#include <psp2/sysmodule.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <vitaGL.h>

#define WIDTH  960
#define HEIGHT 544

static SceUID g_log = -1;

static void lg(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (g_log >= 0 && n > 0) {
    sceIoWrite(g_log, buf, (SceSize)n);
  }
}

// libime wants a work buffer it owns and a text buffer to edit in place.
static SceUInt32 g_ime_work[SCE_IME_WORK_BUFFER_SIZE / sizeof(SceInt32)];
static SceWChar16 g_ime_text[SCE_IME_MAX_PREEDIT_LENGTH + SCE_IME_MAX_TEXT_LENGTH + 1];
static volatile int g_ime_open;
static volatile int g_ime_closed;
static volatile unsigned g_rect_w, g_rect_h, g_rect_x, g_rect_y;

// Enough to see whether text is coming back; not a real UTF-16 decoder.
static void utf16_ascii(const SceWChar16* in, char* out, int max) {
  int i = 0;
  for (; in != NULL && in[i] != 0 && i < max - 1; i++) {
    const SceWChar16 c = in[i];
    out[i] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
  }
  out[i] = '\0';
}

static void ime_handler(void* arg, const SceImeEventData* e) {
  (void)arg;
  switch (e->id) {
    case SCE_IME_EVENT_OPEN:
      g_ime_open = 1;
      g_rect_x = e->param.rect.x;
      g_rect_y = e->param.rect.y;
      g_rect_w = e->param.rect.width;
      g_rect_h = e->param.rect.height;
      lg("IME OPEN rect x=%u y=%u w=%u h=%u\n", (unsigned)e->param.rect.x,
         (unsigned)e->param.rect.y, (unsigned)e->param.rect.width,
         (unsigned)e->param.rect.height);
      break;
    case SCE_IME_EVENT_CHANGE_SIZE:
      g_rect_x = e->param.rect.x;
      g_rect_y = e->param.rect.y;
      g_rect_w = e->param.rect.width;
      g_rect_h = e->param.rect.height;
      lg("IME CHANGE_SIZE rect x=%u y=%u w=%u h=%u\n",
         (unsigned)e->param.rect.x, (unsigned)e->param.rect.y,
         (unsigned)e->param.rect.width, (unsigned)e->param.rect.height);
      break;
    case SCE_IME_EVENT_UPDATE_TEXT: {
      char ascii[64];
      utf16_ascii(g_ime_text, ascii, sizeof ascii);
      lg("IME UPDATE_TEXT caret=%u preedit=%u+%u editIdx=%u dLen=%d text='%s'\n",
         (unsigned)e->param.text.caretIndex,
         (unsigned)e->param.text.preeditIndex,
         (unsigned)e->param.text.preeditLength,
         (unsigned)e->param.text.editIndex,
         (int)e->param.text.editLengthChange, ascii);
      break;
    }
    case SCE_IME_EVENT_UPDATE_CARET:
      lg("IME UPDATE_CARET index=%u\n", (unsigned)e->param.caretIndex);
      break;
    case SCE_IME_EVENT_PRESS_ENTER:
      lg("IME PRESS_ENTER\n");
      break;
    case SCE_IME_EVENT_PRESS_CLOSE:
      lg("IME PRESS_CLOSE\n");
      sceImeClose();
      g_ime_closed = 1;
      break;
    default:
      lg("IME event id=%u\n", (unsigned)e->id);
      break;
  }
}

// What the display controller is actually scanning -- not our own copy of it.
// A capture of memory we wrote proves we wrote it; this proves what is on the
// panel, which is the whole question when something else is compositing.
static void dump_framebuffer(const char* path) {
  SceDisplayFrameBuf fb;
  memset(&fb, 0, sizeof fb);
  fb.size = sizeof fb;
  const int r = sceDisplayGetFrameBuf(&fb, SCE_DISPLAY_SETBUF_NEXTFRAME);
  if (r < 0 || fb.base == NULL) {
    lg("dump: sceDisplayGetFrameBuf 0x%08X base=%p\n", (unsigned)r, fb.base);
    return;
  }
  const SceUID fd = sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  if (fd < 0) {
    lg("dump: cannot open %s (0x%08X)\n", path, (unsigned)fd);
    return;
  }
  sceIoWrite(fd, fb.base, (SceSize)(fb.pitch * fb.height * 4));
  sceIoClose(fd);
  lg("dump: %s %ux%u pitch=%u\n", path, (unsigned)fb.width, (unsigned)fb.height,
     (unsigned)fb.pitch);
}

static void handoff(void) {
  char titleid[16] = "FVTA00004";
  const SceUID fd =
      sceIoOpen("ux0:data/flutter-vita/receiver.titleid", SCE_O_RDONLY, 0777);
  if (fd >= 0) {
    char buf[32] = {0};
    const int n = sceIoRead(fd, buf, sizeof buf - 1);
    sceIoClose(fd);
    for (int i = 0; i < n; i++) {
      if (buf[i] == '\n' || buf[i] == '\r' || buf[i] == ' ') { buf[i] = '\0'; break; }
    }
    if (buf[0] != '\0') snprintf(titleid, sizeof titleid, "%s", buf);
  }
  lg("handing off to %s\n", titleid);
  if (g_log >= 0) { sceIoClose(g_log); g_log = -1; }
  sceKernelDelayThread(500 * 1000);
  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", titleid);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  sceKernelExitProcess(0);
}

int main(void) {
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_log = sceIoOpen("ux0:data/flutter-vita/k1.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  scePowerSetArmClockFrequency(444);
  scePowerSetBusClockFrequency(222);
  lg("K1: libime over vitaGL\n");

  // Easy to miss, and the sample's README credits someone with spotting it:
  // without this sceImeOpen fails.
  const int mod = sceSysmoduleLoadModule(SCE_SYSMODULE_IME);
  lg("sceSysmoduleLoadModule(IME) = 0x%08X\n", (unsigned)mod);

  // The embedder's parameters exactly, so a result here transfers.
  const GLboolean up = vglInitExtended(0x100000, WIDTH, HEIGHT,
                                       120 * 1024 * 1024,
                                       SCE_GXM_MULTISAMPLE_NONE);
  const char* ver = (const char*)glGetString(GL_VERSION);
  lg("vglInitExtended = %d, GL_VERSION = %s\n", (int)up, ver ? ver : "(null)");
  if (ver == NULL) {
    lg("no GL context -- stopping\n");
    handoff();
    return 1;
  }

  memset(g_ime_text, 0, sizeof g_ime_text);
  SceImeParam param;
  sceImeParamInit(&param);
  param.supportedLanguages = SCE_IME_LANGUAGE_ENGLISH;
  param.languagesForced = SCE_FALSE;
  param.type = SCE_IME_TYPE_DEFAULT;
  param.option = SCE_IME_OPTION_NO_ASSISTANCE;
  param.inputTextBuffer = g_ime_text;
  param.maxTextLength = SCE_IME_MAX_TEXT_LENGTH;
  param.handler = ime_handler;
  param.filter = NULL;
  param.initialText = NULL;
  param.arg = NULL;
  param.work = g_ime_work;
  const SceInt32 opened = sceImeOpen(&param);
  lg("sceImeOpen = 0x%08X\n", (unsigned)opened);

  // Two bands, drawn with nothing but clears and a scissor -- no shaders, no
  // vertex buffers, nothing that could fail for its own reasons and be
  // mistaken for the keyboard not compositing.
  glEnable(GL_SCISSOR_TEST);

  const int kFrames = 60 * 14;
  for (int f = 0; f < kFrames; f++) {
    glScissor(0, 0, WIDTH, HEIGHT);
    glClearColor(0.05f, 0.05f, 0.08f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // Top band moves, so a frozen capture is distinguishable from a live one.
    const int y = HEIGHT - 120 - (f % 60);
    glScissor(60, y, WIDTH - 120, 90);
    glClearColor(0.10f, 0.75f, 0.65f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // Bottom band sits where the keyboard should land, so the capture shows
    // which one is on top.
    glScissor(0, 0, WIDTH, 220);
    glClearColor(0.85f, 0.30f, 0.20f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // Every frame while the IME is open, exactly as the sample does.
    if (!g_ime_closed) {
      sceImeUpdate();
    }

    // GL_TRUE is the entire point: it is `has_commondialog` in vitaGL's swap.
    vglSwapBuffers(GL_TRUE);

    if (f == 60 * 6) {
      dump_framebuffer("ux0:data/flutter-vita/k1-shot.raw");
    }
  }

  lg("done: ime_open=%d closed=%d rect=%u,%u %ux%u\n", g_ime_open, g_ime_closed,
     g_rect_x, g_rect_y, g_rect_w, g_rect_h);
  if (!g_ime_closed) {
    sceImeClose();
  }
  handoff();
  return 0;
}
