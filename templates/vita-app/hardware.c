// The hardware checks behind the gallery's Hardware tab that no pub package
// covers: storage, the clock, the controls, the touch panels, and the
// console's own volume.
//
// One channel, `vita/hardware`, registered with plugin.c like any plugin's
// (fvita_plugin.h): the method name, the raw body, and a buffer for the
// reply envelope. The Dart side decides what a pass is; this side reports
// what the hardware said.
//
// The battery, the sensors, the network, the microphone, the speaker and
// the cameras were here until 2026-09-16; they are the Vita packages under
// plugins/ now (battery_plus_vita, sensors_plus_vita, connectivity_plus_vita,
// record_vita, audioplayers_vita, camera_vita, device_info_plus_vita), and
// the gallery checks them through the pub packages an app would use.
//
// Built only when the app's pubspec says `hardware_checks: true`
// (build-vita-app.sh passes HARDWARE_CHECKS=ON to the template). Dev-loop
// infrastructure: a shipping app never includes it.
#include "fvita_plugin.h"

#include <psp2/appmgr.h>
#include <psp2/avconfig.h>
#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/rtc.h>
#include <psp2/touch.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- replies ---------------------------------------------------------------
// plugin.c's helpers under the names this file grew up with.

#define reply_ok fvita_reply_ok
#define body_int fvita_json_int

static int reply_err(char* out, size_t cap, const char* what, int code) {
  return fvita_reply_err(out, cap, "failed", what, code);
}

static void hw_log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void hw_log(const char* fmt, ...) {
  char line[160];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  fvita_log("hardware", "%s", line);
}

// ---- storage and the clock ----------------------------------------------------

static int check_storage(char* out, size_t cap) {
  const char* devs[] = {"ux0:", "ur0:", "uma0:", "imc0:"};
  char items[512];
  int n = 0;
  for (size_t i = 0; i < sizeof devs / sizeof devs[0]; i++) {
    uint64_t max = 0, free = 0;
    const int r = sceAppMgrGetDevInfo(devs[i], &max, &free);
    if (r < 0) continue;  // a mount that is not there
    n += snprintf(items + n, sizeof items - (size_t)n, "%s\"%s\":{\"free_mb\":%llu,\"total_mb\":%llu}", n ? "," : "",
                  devs[i], (unsigned long long)(free >> 20), (unsigned long long)(max >> 20));
  }
  return reply_ok(out, cap, "{%s}", items);
}

static int check_clock(char* out, size_t cap) {
  SceDateTime t;
  memset(&t, 0, sizeof t);
  const int r = sceRtcGetCurrentClockLocalTime(&t);
  if (r < 0) return reply_err(out, cap, "sceRtcGetCurrentClockLocalTime", r);
  SceRtcTick net;
  net.tick = 0;
  const int nr = sceRtcGetCurrentNetworkTick(&net);
  return reply_ok(out, cap, "{\"local\":\"%04d-%02d-%02d %02d:%02d:%02d\",\"network_tick_ok\":%s,\"uptime_s\":%llu}",
                  t.year, t.month, t.day, t.hour, t.minute, t.second, nr >= 0 ? "true" : "false",
                  (unsigned long long)(sceKernelGetProcessTimeWide() / 1000000ULL));
}

// ---- controls and touch ----------------------------------------------------

static int check_controls(char* out, size_t cap) {
  SceCtrlData pad;
  memset(&pad, 0, sizeof pad);
  const int r = sceCtrlPeekBufferPositive(0, &pad, 1);
  if (r < 0) return reply_err(out, cap, "sceCtrlPeekBufferPositive", r);
  return reply_ok(out, cap, "{\"buttons\":%u,\"lx\":%u,\"ly\":%u,\"rx\":%u,\"ry\":%u}", pad.buttons, pad.lx, pad.ly,
                  pad.rx, pad.ry);
}

// One sample of both panels: how many contacts, and where the first is.
static int check_touch(char* out, size_t cap) {
  // The back panel is off until an app asks for it; the embedder only asks
  // for the front.
  sceTouchSetSamplingState(SCE_TOUCH_PORT_BACK, SCE_TOUCH_SAMPLING_STATE_START);
  SceTouchData front, back;
  memset(&front, 0, sizeof front);
  memset(&back, 0, sizeof back);
  const int rf = sceTouchPeek(SCE_TOUCH_PORT_FRONT, &front, 1);
  const int rb = sceTouchPeek(SCE_TOUCH_PORT_BACK, &back, 1);
  if (rf < 0) return reply_err(out, cap, "sceTouchPeek front", rf);
  if (rb < 0) return reply_err(out, cap, "sceTouchPeek back", rb);
  return reply_ok(out, cap,
                  "{\"front\":%u,\"front_x\":%d,\"front_y\":%d,\"back\":%u,\"back_x\":%d,\"back_y\":%d}",
                  front.reportNum, front.reportNum ? front.report[0].x : -1, front.reportNum ? front.report[0].y : -1,
                  back.reportNum, back.reportNum ? back.report[0].x : -1, back.reportNum ? back.report[0].y : -1);
}

// ---- the console's volume ----------------------------------------------------

// The console's own volume, 0 to 30, read and (with `set`) changed: a tone
// through a console turned down is silent, and a check must say which it
// was. Build 47 found the console at 0/30, which is why nobody heard
// builds 30 to 46. The Dart side raises it for a tone and puts it back.
static int check_volume(char* out, size_t cap, int set) {
  int vol = -1;
  const int r = sceAVConfigGetSystemVol(&vol);
  if (r < 0) return reply_err(out, cap, "sceAVConfigGetSystemVol", r);
  int sr = 0;
  if (set >= 0 && set <= 30 && set != vol) {
    sr = sceAVConfigSetSystemVol(set);
    hw_log("volume: %d/30 -> %d: 0x%08X", vol, set, (unsigned)sr);
  }
  return reply_ok(out, cap, "{\"vol\":%d,\"was\":%d,\"set_result\":%d}", sr >= 0 && set >= 0 ? set : vol, vol, sr);
}

// ---- dispatch --------------------------------------------------------------

static int dispatch(const char* method, const char* body, size_t body_len, char* out, size_t cap) {
  if (strcmp(method, "storage") == 0) return check_storage(out, cap);
  if (strcmp(method, "clock") == 0) return check_clock(out, cap);
  if (strcmp(method, "controls") == 0) return check_controls(out, cap);
  if (strcmp(method, "touch") == 0) return check_touch(out, cap);
  if (strcmp(method, "volume") == 0) return check_volume(out, cap, body_int(body, body_len, "set", -1));
  return snprintf(out, cap, "[\"unknown\",\"no such check: %s\",null]", method);
}

__attribute__((constructor)) static void register_hardware(void) {
  fvita_channel_register("vita/hardware", dispatch);
}
