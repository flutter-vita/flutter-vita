// The controller, for the strip's hotkey: `vita/pad`.
//
//   read                    the buttons and sticks now
//   waitChord {mask, ms}    returns when every button in `mask` is down
//                           (after they were all up first), or after `ms`
//
// The wait is one thread parked on a 30 ms poll instead of a Dart timer
// asking the channel several times a second: the registry gives a call up
// to 15 s, so the Dart side asks for 14 s at a time and one thread serves
// the whole app. The chord is reported once per press: the call first
// waits for the buttons to be up, so a chord held through a call does not
// toggle twice.
#include <fvita_plugin.h>

#include <psp2/ctrl.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#include <string.h>

static unsigned buttons_now(SceCtrlData* pad) {
  memset(pad, 0, sizeof *pad);
  sceCtrlPeekBufferPositive(0, pad, 1);
  return pad->buttons;
}

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  if (strcmp(method, "read") == 0) {
    SceCtrlData pad;
    const unsigned b = buttons_now(&pad);
    return fvita_reply_ok(out, cap, "{\"buttons\":%u,\"lx\":%u,\"ly\":%u,\"rx\":%u,\"ry\":%u}", b, pad.lx, pad.ly,
                          pad.rx, pad.ry);
  }
  if (strcmp(method, "waitChord") == 0) {
    const unsigned mask = (unsigned)fvita_json_int(body, len, "mask", 0);
    int ms = fvita_json_int(body, len, "ms", 14000);
    if (ms < 30) ms = 30;
    if (ms > 14000) ms = 14000;
    if (mask == 0) return fvita_reply_err(out, cap, "args", "mask is 0", 0);
    const SceUInt64 end = sceKernelGetProcessTimeWide() + (SceUInt64)ms * 1000;
    SceCtrlData pad;
    int released = (buttons_now(&pad) & mask) != mask;
    while (sceKernelGetProcessTimeWide() < end) {
      const unsigned b = buttons_now(&pad);
      if ((b & mask) == mask) {
        if (released) return fvita_reply_ok(out, cap, "{\"pressed\":true,\"buttons\":%u}", b);
      } else {
        released = 1;
      }
      sceKernelDelayThread(30 * 1000);
    }
    return fvita_reply_ok(out, cap, "{\"pressed\":false,\"buttons\":%u}", pad.buttons);
  }
  return fvita_reply_err(out, cap, "unknown", method, 0);
}

__attribute__((constructor)) static void reg(void) { fvita_channel_register("vita/pad", handle); }
