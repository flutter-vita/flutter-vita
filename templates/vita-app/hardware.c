// The hardware checks behind the gallery's Hardware tab.
//
// One channel, `vita/hardware`, registered with plugin.c like any plugin's
// (fvita_plugin.h): the method name, the raw body, and a buffer for the
// reply envelope. Each method is one piece of the console: a camera, the
// microphone, the motion sensors, a touch panel, the battery. The Dart side
// decides what a pass is; this side reports what the hardware said.
//
// Built only when the app's pubspec says `hardware_checks: true`
// (build-vita-app.sh passes HARDWARE_CHECKS=ON to the template), because it
// links six stub libraries an ordinary app has no use for. Dev-loop
// infrastructure: a shipping app never includes it.
//
// Every check runs on a thread of its own and answers from it (plugin.c);
// the platform thread, the one that drains platform messages, only starts
// it. Two checks asked for together run together, which the microphone
// recording the speaker depends on.
#include "fvita_plugin.h"

#include <psp2/appmgr.h>
#include <psp2/audioin.h>
#include <psp2/audioout.h>
#include <psp2/avconfig.h>
#include <psp2/avplayer.h>
#include <psp2/camera.h>
#include <psp2/ctrl.h>
#include <psp2/io/fcntl.h>
#include <psp2/kernel/clib.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/motion.h>
#include <psp2/net/netctl.h>
#include <psp2/power.h>
#include <psp2/rtc.h>
#include <psp2/sysmodule.h>
#include <psp2/touch.h>

#include <malloc.h>
#include <math.h>
#include <stdarg.h>
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

// ---- battery, storage, clock, network, model --------------------------------

static int check_battery(char* out, size_t cap) {
  const int t = scePowerGetBatteryTemp();
  return reply_ok(out, cap,
                  "{\"pct\":%d,\"charging\":%s,\"temp_c\":%d.%02d,\"volt_mv\":%d,"
                  "\"remaining_min\":%d,\"capacity_mah\":%d,\"full_mah\":%d,"
                  "\"arm_mhz\":%d,\"bus_mhz\":%d,\"gpu_mhz\":%d}",
                  scePowerGetBatteryLifePercent(), scePowerIsBatteryCharging() ? "true" : "false", t / 100,
                  abs(t % 100), scePowerGetBatteryVolt(), scePowerGetBatteryLifeTime(),
                  scePowerGetBatteryRemainCapacity(), scePowerGetBatteryFullCapacity(),
                  scePowerGetArmClockFrequency(), scePowerGetBusClockFrequency(), scePowerGetGpuClockFrequency());
}

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

static int check_network(char* out, size_t cap) {
  int state = -1;
  const int r = sceNetCtlInetGetState(&state);
  if (r < 0) return reply_err(out, cap, "sceNetCtlInetGetState", r);
  SceNetCtlInfo ip, ssid, rssi, device;
  memset(&ip, 0, sizeof ip);
  memset(&ssid, 0, sizeof ssid);
  memset(&rssi, 0, sizeof rssi);
  memset(&device, 0, sizeof device);
  const bool up = state == SCE_NETCTL_STATE_CONNECTED;
  if (up) {
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_IP_ADDRESS, &ip);
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_SSID, &ssid);
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_RSSI_PERCENTAGE, &rssi);
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_DEVICE, &device);
  }
  return reply_ok(out, cap, "{\"state\":%d,\"connected\":%s,\"ip\":\"%s\",\"ssid\":\"%s\",\"rssi_pct\":%u,\"device\":%u}",
                  state, up ? "true" : "false", up ? ip.ip_address : "", up ? ssid.ssid : "",
                  up ? rssi.rssi_percentage : 0u, up ? device.device : 0u);
}

static int check_model(char* out, size_t cap) {
  SceKernelSystemSwVersion sw;
  memset(&sw, 0, sizeof sw);
  sw.size = sizeof sw;
  sceKernelGetSystemSwVersion(&sw);
  // sceKernelGetModel: 0x10000 is a Vita, 0x20000 the PS TV, which has no
  // cameras, no touch panels, no motion sensors. The tab reads this first.
  return reply_ok(out, cap, "{\"model\":%d,\"firmware\":\"%s\",\"cores\":4}", sceKernelGetModel(), sw.versionString);
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

// ---- motion ----------------------------------------------------------------

// The raw sensors, not the fused state: on build 30 sceMotionGetState gave
// a basicOrientation and zeros for acceleration and angular velocity, a
// minute after sampling started. sceMotionGetSensorState is the
// accelerometer and the gyro as read, and the fused state still supplies
// the orientation.
static int check_motion(char* out, size_t cap) {
  static bool sampling;
  if (!sampling) {
    const int r = sceMotionStartSampling();
    if (r < 0) return reply_err(out, cap, "sceMotionStartSampling", r);
    sampling = true;
  }
  SceMotionSensorState raw;
  int r = -1;
  // The first records come a few samples after the start; up to a second.
  for (int i = 0; i < 20; i++) {
    memset(&raw, 0, sizeof raw);
    r = sceMotionGetSensorState(&raw, 1);
    if (r < 0) return reply_err(out, cap, "sceMotionGetSensorState", r);
    if (raw.accelerometer.x != 0 || raw.accelerometer.y != 0 || raw.accelerometer.z != 0) break;
    sceKernelDelayThread(50 * 1000);
  }
  SceMotionState st;
  memset(&st, 0, sizeof st);
  sceMotionGetState(&st);
  return reply_ok(out, cap,
                  "{\"accel\":[%.3f,%.3f,%.3f],\"gyro\":[%.3f,%.3f,%.3f],\"orientation\":[%.3f,%.3f,%.3f],"
                  "\"mag_stable\":%u,\"counter\":%u}",
                  raw.accelerometer.x, raw.accelerometer.y, raw.accelerometer.z, raw.gyro.x, raw.gyro.y, raw.gyro.z,
                  st.basicOrientation.x, st.basicOrientation.y, st.basicOrientation.z, st.magFieldStability,
                  raw.counter);
}

// ---- audio out: a tone -----------------------------------------------------

// `ms` of a sine at `hz` through the main port at 48 kHz, stereo, at the
// port's full volume. Blocks for the duration; sceAudioOutOutput waits for
// the previous grain, which is the clock. The first version played 440 Hz
// at a third of full scale and half volume, and nobody heard it: the
// console's speakers are small and roll off below the mid range. 1 kHz is
// what the loopback check asks for, and what the microphone's 16 kHz
// sampling resolves cleanly.
static int check_audio_tone(char* out, size_t cap, int hz, unsigned ms, int amp) {
  enum { kRate = 48000, kGrain = 960 };
  if (hz < 50 || hz > 8000) hz = 1000;
  if (ms < 100 || ms > 10000) ms = 1000;
  if (amp < 1000 || amp > 32000) amp = 24000;
  // The console's own volume, 0 to 30: a tone at full port volume through a
  // console turned down is silent, and the check must say which it was.
  int sysvol = -1;
  const int vr0 = sceAVConfigGetSystemVol(&sysvol);
  if (vr0 < 0) hw_log("tone: sceAVConfigGetSystemVol 0x%08X", (unsigned)vr0);
  // A console turned down cannot be tested. It is turned up to 12 for the
  // tone and put back after; the reply says so, and the person's own level
  // is not touched otherwise. Build 47 found the console at 0/30, which is
  // why nobody heard builds 30 to 46.
  int raised = 0;
  if (vr0 >= 0 && sysvol < 5) {
    const int sr = sceAVConfigSetSystemVol(12);
    hw_log("tone: console volume %d/30, set to 12 for the tone -> 0x%08X", sysvol, (unsigned)sr);
    raised = sr >= 0;
  }
  const int port = sceAudioOutOpenPort(SCE_AUDIO_OUT_PORT_TYPE_MAIN, kGrain, kRate, SCE_AUDIO_OUT_MODE_STEREO);
  hw_log("tone: port %d (%d Hz, %u ms, amp %d), console volume %d/30", port, hz, ms, amp, sysvol);
  if (port < 0) return reply_err(out, cap, "sceAudioOutOpenPort", port);
  int vol[2] = {SCE_AUDIO_OUT_MAX_VOL, SCE_AUDIO_OUT_MAX_VOL};
  const int vr = sceAudioOutSetVolume(port, SCE_AUDIO_VOLUME_FLAG_L_CH | SCE_AUDIO_VOLUME_FLAG_R_CH, vol);
  if (vr < 0) hw_log("tone: sceAudioOutSetVolume 0x%08X", (unsigned)vr);
  static int16_t buf[kGrain * 2];
  unsigned phase = 0;
  const unsigned grains = (unsigned)kRate * ms / 1000 / kGrain;
  const unsigned total = grains * kGrain, fade = 480;  // 10 ms
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  int r = 0;
  for (unsigned g = 0; g < grains && r >= 0; g++) {
    for (int i = 0; i < kGrain; i++) {
      // A short fade at both ends so the speaker does not click.
      const unsigned n = g * kGrain + (unsigned)i;
      float env = 1.0f;
      if (n < fade) env = n / (float)fade;
      if (n > total - fade) env = (total - n) / (float)fade;
      const int16_t v = (int16_t)(sinf(2.0f * 3.14159265f * (float)hz * phase / kRate) * (float)amp * env);
      buf[i * 2] = v;
      buf[i * 2 + 1] = v;
      phase++;
    }
    r = sceAudioOutOutput(port, buf);
  }
  sceAudioOutOutput(port, NULL);  // drain
  const unsigned took_ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
  sceAudioOutReleasePort(port);
  if (raised) sceAVConfigSetSystemVol(sysvol);
  hw_log("tone: %u grains in %u ms, last output 0x%08X", grains, took_ms, (unsigned)r);
  if (r < 0) return reply_err(out, cap, "sceAudioOutOutput", r);
  return reply_ok(out, cap,
                  "{\"port\":%d,\"rate\":%d,\"hz\":%d,\"amp\":%d,\"grains\":%u,\"took_ms\":%u,\"console_vol\":%d,"
                  "\"raised\":%s}",
                  port, kRate, hz, amp, grains, took_ms, sysvol, raised ? "true" : "false");
}

// ---- audio out: a file through sceAvPlayer --------------------------------

static void* av_alloc(void* arg, uint32_t alignment, uint32_t size) {
  (void)arg;
  // newlib's memalign refuses an alignment of 0 or one that is not a power
  // of two; the player asks with 0 for plain allocations.
  if (alignment < 16) alignment = 16;
  void* p = memalign(alignment, size);
  if (p == NULL) hw_log("avplayer: alloc %u align %u failed", size, alignment);
  return p;
}
static void av_free(void* arg, void* ptr) {
  (void)arg;
  free(ptr);
}
// Frame buffers: the decoders write them through hardware, so they come
// from physically contiguous memblocks, like the camera's. Heap memory
// here is the one thing builds 49 to 51 gave the player that it never
// complained about in words; it read the file's boxes and stopped.
enum { kAvFrames = 8 };
static struct {
  void* base;
  SceUID uid;
} g_av_frames[kAvFrames];
static void* av_alloc_frame(void* arg, uint32_t alignment, uint32_t size) {
  (void)arg;
  for (int i = 0; i < kAvFrames; i++) {
    if (g_av_frames[i].base != NULL) continue;
    const SceSize bytes = (size + 0xFFFFF) & ~0xFFFFFu;
    const SceUID uid = sceKernelAllocMemBlock("fvita-avframe", SCE_KERNEL_MEMBLOCK_TYPE_USER_MAIN_PHYCONT_NC_RW, bytes, NULL);
    void* base = NULL;
    if (uid >= 0) sceKernelGetMemBlockBase(uid, &base);
    hw_log("avplayer: frame alloc %u align %u -> %p (block 0x%08X, %u)", size, alignment, base, (unsigned)uid, bytes);
    if (base == NULL) return NULL;
    g_av_frames[i].base = base;
    g_av_frames[i].uid = uid;
    return base;
  }
  hw_log("avplayer: frame alloc %u: no slot", size);
  return NULL;
}
static void av_free_frame(void* arg, void* ptr) {
  (void)arg;
  for (int i = 0; i < kAvFrames; i++) {
    if (g_av_frames[i].base != ptr) continue;
    sceKernelFreeMemBlock(g_av_frames[i].uid);
    g_av_frames[i].base = NULL;
    return;
  }
}

// File I/O for the player through sceIo, and every call in the log. With
// the player's own I/O the m4a was accepted, the player went active and
// stopped 86 ms later with nothing decoded (build 49); what it could not
// do is not said anywhere, so this side does the reading.
static SceUID g_av_fd = -1;
static int av_open(void* p, const char* filename) {
  (void)p;
  g_av_fd = sceIoOpen(filename, SCE_O_RDONLY, 0);
  hw_log("avplayer: open %s -> 0x%08X", filename, (unsigned)g_av_fd);
  return g_av_fd >= 0 ? 0 : -1;
}
static int av_close(void* p) {
  (void)p;
  if (g_av_fd >= 0) sceIoClose(g_av_fd);
  g_av_fd = -1;
  return 0;
}
static int av_read_offset(void* p, uint8_t* buffer, uint64_t position, uint32_t length) {
  (void)p;
  if (g_av_fd < 0) return -1;
  sceIoLseek(g_av_fd, (SceOff)position, SCE_SEEK_SET);
  const int got = sceIoRead(g_av_fd, buffer, length);
  static int logged;
  if (logged < 4 || got < 0) {
    logged++;
    hw_log("avplayer: read %u at %llu -> %d", length, (unsigned long long)position, got);
  }
  return got;
}
static uint64_t av_size(void* p) {
  (void)p;
  if (g_av_fd < 0) return 0;
  const SceOff end = sceIoLseek(g_av_fd, 0, SCE_SEEK_END);
  sceIoLseek(g_av_fd, 0, SCE_SEEK_SET);
  hw_log("avplayer: size -> %llu", (unsigned long long)end);
  return (uint64_t)end;
}
// Event ids, from the player's documentation: 1 stop, 2 ready, 3 play,
// 4 pause, 5 buffering, 0x10 timed text, 0x20 warning (data: the code).
static void av_event(void* p, int32_t event, int32_t source, void* data) {
  (void)p;
  const char* name = event == 1   ? "stop"
                     : event == 2 ? "ready"
                     : event == 3 ? "play"
                     : event == 4 ? "pause"
                     : event == 5 ? "buffering"
                     : event == 0x20 ? "warning"
                                     : "?";
  hw_log("avplayer: event %d %s source %d data 0x%08X", (int)event, name, (int)source,
         data && event == 0x20 ? *(unsigned*)data : 0u);
}

// Plays the whole file, up to `max_ms`, and reports what the decoder said
// about it. The system's player decodes AAC in MP4; the app ships one.
static int check_audio_file(char* out, size_t cap, const char* path, unsigned max_ms) {
  static bool loaded;
  if (!loaded) {
    const int r = sceSysmoduleLoadModule(SCE_SYSMODULE_AVPLAYER);
    if (r < 0) return reply_err(out, cap, "sceSysmoduleLoadModule(AVPLAYER)", r);
    loaded = true;
  }
  SceAvPlayerInitData init;
  memset(&init, 0, sizeof init);
  init.memoryReplacement.allocate = av_alloc;
  init.memoryReplacement.deallocate = av_free;
  init.memoryReplacement.allocateTexture = av_alloc_frame;
  init.memoryReplacement.deallocateTexture = av_free_frame;
  init.fileReplacement.open = av_open;
  init.fileReplacement.close = av_close;
  init.fileReplacement.readOffset = av_read_offset;
  init.fileReplacement.size = av_size;
  init.eventReplacement.eventCallback = av_event;
  init.debugLevel = 3;
  init.basePriority = 0xA0;
  init.numOutputVideoFrameBuffers = 2;
  init.autoStart = SCE_TRUE;
  init.defaultLanguage = "en";
  const SceAvPlayerHandle h = sceAvPlayerInit(&init);
  // The handle is a pointer into this process's heap, and every user address
  // on this console is above 0x81000000: as an int it is negative. An error
  // is 0x80xxxxxx. Build 30 tested `h < 0`, took a good handle for an error
  // and left the player open.
  if (h == 0 || ((unsigned)h >> 24) == 0x80u) return reply_err(out, cap, "sceAvPlayerInit", h);
  // Both spellings of the app0 mount are tried, and then a copy under
  // ux0:data; build 45 had 0x806A0002 from AddSource on `app0:/...`, a
  // code the SDK header does not name, with the file present on the card.
  int r = sceAvPlayerAddSource(h, path);
  hw_log("avplayer: add %s -> 0x%08X", path, (unsigned)r);
  if (r < 0 && strncmp(path, "app0:/", 6) == 0) {
    char alt[256];
    snprintf(alt, sizeof alt, "app0:%s", path + 6);
    r = sceAvPlayerAddSource(h, alt);
    hw_log("avplayer: add %s -> 0x%08X", alt, (unsigned)r);
    if (r < 0) {
      const char* dot = strrchr(path, '.');
      char copy[96];
      snprintf(copy, sizeof copy, "ux0:data/flutter-vita/avplayer-test%s", dot ? dot : "");
      const SceUID in = sceIoOpen(path, SCE_O_RDONLY, 0);
      const SceUID outfd = sceIoOpen(copy, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
      if (in >= 0 && outfd >= 0) {
        static char chunk[16 * 1024];
        int got;
        while ((got = sceIoRead(in, chunk, sizeof chunk)) > 0) sceIoWrite(outfd, chunk, (SceSize)got);
      }
      if (in >= 0) sceIoClose(in);
      if (outfd >= 0) sceIoClose(outfd);
      r = sceAvPlayerAddSource(h, copy);
      hw_log("avplayer: add %s -> 0x%08X (copied: in %d out %d)", copy, (unsigned)r, in, outfd);
    }
  }
  if (r < 0) {
    sceAvPlayerClose(h);
    return reply_err(out, cap, "sceAvPlayerAddSource", r);
  }
  int port = -1;
  unsigned frames = 0, channels = 0, rate = 0, bytes = 0;
  bool was_active = false;
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  // The player opens the stream on its own thread: IsActive is false for a
  // while after AddSource, and a loop that tests it first leaves at once
  // with nothing decoded (build 48, the m4a). So the loop runs on the
  // clock, and ends when the player has been active and is no more.
  for (;;) {
    const unsigned ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
    if (ms > max_ms) break;
    const bool active = sceAvPlayerIsActive(h);
    if (active && !was_active) hw_log("avplayer: active after %u ms", ms);
    if (!active && was_active) break;
    was_active = was_active || active;
    if (!active) {
      sceKernelDelayThread(2000);
      continue;
    }
    SceAvPlayerFrameInfo f;
    memset(&f, 0, sizeof f);
    if (!sceAvPlayerGetAudioData(h, &f)) {
      sceKernelDelayThread(1000);
      continue;
    }
    if (port < 0) {
      channels = f.details.audio.channelCount;
      rate = f.details.audio.sampleRate;
      const int grain = (int)(f.details.audio.size / (2 * (channels ? channels : 1)));
      // The BGM port: the main port takes 48 kHz only (0x80260008 for the
      // 44.1 kHz file, build 52), the BGM port any rate from 8 to 48 kHz,
      // and music is what it is for.
      port = sceAudioOutOpenPort(SCE_AUDIO_OUT_PORT_TYPE_BGM, grain, (int)rate,
                                 channels == 1 ? SCE_AUDIO_OUT_MODE_MONO : SCE_AUDIO_OUT_MODE_STEREO);
      hw_log("avplayer: audio %u ch %u Hz, %u bytes a frame, grain %d -> port %d", channels, rate,
             f.details.audio.size, grain, port);
      if (port < 0) {
        sceAvPlayerStop(h);
        sceAvPlayerClose(h);
        return reply_err(out, cap, "sceAudioOutOpenPort(file)", port);
      }
      int vol[2] = {SCE_AUDIO_OUT_MAX_VOL, SCE_AUDIO_OUT_MAX_VOL};
      sceAudioOutSetVolume(port, SCE_AUDIO_VOLUME_FLAG_L_CH | SCE_AUDIO_VOLUME_FLAG_R_CH, vol);
    }
    sceAudioOutOutput(port, f.pData);
    frames++;
    bytes += f.details.audio.size;
  }
  if (port >= 0) {
    sceAudioOutOutput(port, NULL);
    sceAudioOutReleasePort(port);
  }
  const unsigned took_ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
  sceAvPlayerStop(h);
  sceAvPlayerClose(h);
  hw_log("avplayer: %u frames, %u ch %u Hz, %u bytes in %u ms%s", frames, channels, rate, bytes, took_ms,
         was_active ? "" : ", never active");
  if (frames == 0) return reply_err(out, cap, was_active ? "no audio frame decoded" : "player never became active", 0);
  return reply_ok(out, cap, "{\"frames\":%u,\"channels\":%u,\"rate\":%u,\"bytes\":%u,\"took_ms\":%u}", frames,
                  channels, rate, bytes, took_ms);
}

// ---- microphone ------------------------------------------------------------

// `ms` from the microphone, 16 kHz mono, written as a WAV the Dart side
// analyses, plus the peak and the RMS. The RAW port: the VOICE port (build
// 45 and before) opened, took 7936 samples and every one was zero, with
// the status word reading "muted"; the voice port is the one sceVoice
// feeds, and this app is not a voice chat.
static int check_mic(char* out, size_t cap, unsigned ms, const char* path) {
  enum { kRate = 16000 };
  if (ms < 100 || ms > 10000) ms = 1000;
  int grain = 256, type = SCE_AUDIO_IN_PORT_TYPE_RAW;
  int port = sceAudioInOpenPort(type, grain, kRate, SCE_AUDIO_IN_PARAM_FORMAT_S16_MONO);
  if (port < 0) {
    hw_log("mic: raw/256 0x%08X", (unsigned)port);
    grain = 512;
    port = sceAudioInOpenPort(type, grain, kRate, SCE_AUDIO_IN_PARAM_FORMAT_S16_MONO);
  }
  if (port < 0) {
    hw_log("mic: raw/512 0x%08X", (unsigned)port);
    grain = 256;
    type = SCE_AUDIO_IN_PORT_TYPE_VOICE;
    port = sceAudioInOpenPort(type, grain, kRate, SCE_AUDIO_IN_PARAM_FORMAT_S16_MONO);
  }
  hw_log("mic: port %d type %d grain %d, status(mute) %d", port, type, grain,
         sceAudioInGetStatus(SCE_AUDIO_IN_GETSTATUS_MUTE));
  if (port < 0) return reply_err(out, cap, "sceAudioInOpenPort", port);
  const unsigned grains = (unsigned)kRate * ms / 1000 / (unsigned)grain;
  const size_t bytes = (size_t)grains * (size_t)grain * 2;
  int16_t* pcm = malloc(bytes);
  if (pcm == NULL) {
    sceAudioInReleasePort(port);
    return reply_err(out, cap, "malloc(mic)", (int)bytes);
  }
  int peak = 0;
  double sq = 0;
  unsigned n = 0;
  int r = 0;
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  for (unsigned g = 0; g < grains && r >= 0; g++) {
    int16_t* buf = pcm + (size_t)g * (size_t)grain;
    r = sceAudioInInput(port, buf);
    if (r < 0) break;
    for (int i = 0; i < grain; i++) {
      const int v = abs(buf[i]);
      if (v > peak) peak = v;
      sq += (double)buf[i] * buf[i];
      n++;
    }
  }
  const unsigned took_ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
  const int status = sceAudioInGetStatus(SCE_AUDIO_IN_GETSTATUS_MUTE);
  sceAudioInReleasePort(port);
  hw_log("mic: %u samples in %u ms, peak %d, last input 0x%08X", n, took_ms, peak, (unsigned)r);
  if (r < 0) {
    free(pcm);
    return reply_err(out, cap, "sceAudioInInput", r);
  }
  // A canonical 44-byte PCM WAV header, little-endian like the console.
  const uint32_t data_bytes = n * 2;
  uint8_t hdr[44];
  memcpy(hdr, "RIFF", 4);
  const uint32_t riff = 36 + data_bytes;
  memcpy(hdr + 4, &riff, 4);
  memcpy(hdr + 8, "WAVEfmt ", 8);
  const uint32_t fmt_len = 16, rate = kRate, byte_rate = kRate * 2;
  const uint16_t pcm_tag = 1, channels = 1, block = 2, bits = 16;
  memcpy(hdr + 16, &fmt_len, 4);
  memcpy(hdr + 20, &pcm_tag, 2);
  memcpy(hdr + 22, &channels, 2);
  memcpy(hdr + 24, &rate, 4);
  memcpy(hdr + 28, &byte_rate, 4);
  memcpy(hdr + 32, &block, 2);
  memcpy(hdr + 34, &bits, 2);
  memcpy(hdr + 36, "data", 4);
  memcpy(hdr + 40, &data_bytes, 4);
  const SceUID fd = sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  int wrote = -1;
  if (fd >= 0) {
    wrote = sceIoWrite(fd, hdr, sizeof hdr);
    if (wrote == (int)sizeof hdr) wrote = sceIoWrite(fd, pcm, data_bytes);
    sceIoClose(fd);
  }
  free(pcm);
  if (wrote != (int)data_bytes) return reply_err(out, cap, "write mic wav", wrote < 0 ? wrote : fd);
  const double rms = n ? sqrt(sq / n) : 0;
  return reply_ok(out, cap,
                  "{\"port\":%d,\"type\":%d,\"rate\":%d,\"samples\":%u,\"peak\":%d,\"rms\":%.0f,\"status\":%d,"
                  "\"took_ms\":%u,\"path\":\"%s\"}",
                  port, type, kRate, n, peak, rms, status, took_ms, path);
}

// ---- cameras ---------------------------------------------------------------

// Mean and variance of the green channel over a 32x32 grid of samples: a
// covered lens is under 5, a room is in the hundreds.
static void camera_brightness(const void* frame, int w, int h, double* mean, double* var) {
  const uint8_t* px = frame;
  double sum = 0, sq = 0;
  unsigned n = 0;
  for (int y = 0; y < h; y += 8) {
    for (int x = 0; x < w; x += 10) {
      const double g = px[(y * w + x) * 4 + 1];
      sum += g;
      sq += g * g;
      n++;
    }
  }
  *mean = sum / n;
  *var = sq / n - *mean * *mean;
}

// One 320x240 ABGR frame from a camera, written to a file the Dart side
// decodes and shows. The reply carries a measure of the frame's variance, so
// an all-black frame from a covered lens reads as such without a person.
static int check_camera(char* out, size_t cap, int which) {
  enum { kW = 320, kH = 240, kBytes = kW * kH * 4 };
  const char* path = which == SCE_CAMERA_DEVICE_FRONT ? "ux0:data/flutter-vita/camera-front.rgba"
                                                       : "ux0:data/flutter-vita/camera-back.rgba";
  // The camera writes through the DMA engine, so the buffer must be a
  // kernel memblock that is physically contiguous. A plain user block is
  // not: sceCameraStart answered 0x80024003,
  // SCE_KERNEL_ERROR_VARANGE_IS_NOT_PHYSICAL_CONTINUOUS, on build 30. The
  // PHYCONT type is, in 1 MiB granules.
  const SceUID mb = sceKernelAllocMemBlock("fvita-camera", SCE_KERNEL_MEMBLOCK_TYPE_USER_MAIN_PHYCONT_NC_RW,
                                           (kBytes + 0xFFFFF) & ~0xFFFFF, NULL);
  if (mb < 0) return reply_err(out, cap, "sceKernelAllocMemBlock(camera)", mb);
  void* base = NULL;
  sceKernelGetMemBlockBase(mb, &base);
  memset(base, 0, kBytes);

  SceCameraInfo info;
  memset(&info, 0, sizeof info);
  info.size = sizeof info;
  info.priority = SCE_CAMERA_PRIORITY_SHARE;
  info.format = SCE_CAMERA_FORMAT_ABGR;
  info.resolution = SCE_CAMERA_RESOLUTION_320_240;
  info.framerate = SCE_CAMERA_FRAMERATE_30_FPS;
  info.width = kW;
  info.height = kH;
  info.range = 1;
  info.pitch = 0;
  info.sizeIBase = kBytes;
  info.pIBase = base;
  int r = sceCameraOpen(which, &info);
  hw_log("camera %d: open 0x%08X", which, (unsigned)r);
  if (r < 0) {
    sceKernelFreeMemBlock(mb);
    return reply_err(out, cap, "sceCameraOpen", r);
  }
  r = sceCameraStart(which);
  hw_log("camera %d: start 0x%08X", which, (unsigned)r);
  if (r < 0) {
    sceCameraClose(which);
    sceKernelFreeMemBlock(mb);
    return reply_err(out, cap, "sceCameraStart", r);
  }
  // The sensor's exposure takes most of a second to settle from the black
  // it starts at. Build 42 read ten times with mode 1 and had frame 4 after
  // 78 ms: a read returns the frame there is, it does not wait for a new
  // one, and frame 4 of a face-up console was black (mean 10 of 255). So
  // this reads until thirty new frames have come or 1.5 s has passed, and
  // logs the brightness along the way, so the settle shows in the log.
  SceCameraRead rd;
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  uint64_t last_frame = 0;
  unsigned new_frames = 0, reads = 0;
  double mean = 0, var = 0;
  while (r >= 0) {
    memset(&rd, 0, sizeof rd);
    rd.size = sizeof rd;
    rd.mode = 1;
    r = sceCameraRead(which, &rd);
    reads++;
    if (reads == 1 || r < 0) hw_log("camera %d: read -> 0x%08X frame %llu", which, (unsigned)r, (unsigned long long)rd.frame);
    if (r < 0) break;
    const unsigned ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
    if (rd.frame != last_frame) {
      last_frame = rd.frame;
      new_frames++;
      if (new_frames == 1 || new_frames == 5 || new_frames == 15 || new_frames == 30) {
        camera_brightness(base, kW, kH, &mean, &var);
        hw_log("camera %d: frame %llu at %u ms, mean %.1f sd %.1f", which, (unsigned long long)rd.frame, ms,
               mean, sqrt(var < 0 ? 0 : var));
      }
      if (new_frames >= 30) break;
    }
    if (ms > 1500) break;
    sceKernelDelayThread(4 * 1000);
  }
  const unsigned took_ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
  sceCameraStop(which);
  sceCameraClose(which);
  hw_log("camera %d: stopped after %u ms, %u reads, %u new frames", which, took_ms, reads, new_frames);
  if (r < 0) {
    sceKernelFreeMemBlock(mb);
    return reply_err(out, cap, "sceCameraRead", r);
  }
  camera_brightness(base, kW, kH, &mean, &var);
  const SceUID fd = sceIoOpen(path, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
  int wrote = -1;
  if (fd >= 0) {
    wrote = sceIoWrite(fd, base, kBytes);
    sceIoClose(fd);
  }
  sceKernelFreeMemBlock(mb);
  if (wrote != kBytes) return reply_err(out, cap, "write camera frame", wrote);
  return reply_ok(out, cap,
                  "{\"path\":\"%s\",\"width\":%d,\"height\":%d,\"frame\":%llu,\"frames\":%u,\"mean\":%.1f,"
                  "\"stddev\":%.1f,\"took_ms\":%u}",
                  path, kW, kH, (unsigned long long)rd.frame, new_frames, mean, sqrt(var < 0 ? 0 : var), took_ms);
}

// ---- dispatch --------------------------------------------------------------

static int dispatch(const char* method, const char* body, size_t body_len, char* out, size_t cap) {
  if (strcmp(method, "model") == 0) return check_model(out, cap);
  if (strcmp(method, "battery") == 0) return check_battery(out, cap);
  if (strcmp(method, "storage") == 0) return check_storage(out, cap);
  if (strcmp(method, "clock") == 0) return check_clock(out, cap);
  if (strcmp(method, "network") == 0) return check_network(out, cap);
  if (strcmp(method, "controls") == 0) return check_controls(out, cap);
  if (strcmp(method, "touch") == 0) return check_touch(out, cap);
  if (strcmp(method, "motion") == 0) return check_motion(out, cap);
  if (strcmp(method, "audioTone") == 0) {
    return check_audio_tone(out, cap, body_int(body, body_len, "hz", 1000), (unsigned)body_int(body, body_len, "ms", 1000),
                            body_int(body, body_len, "amp", 24000));
  }
  if (strcmp(method, "audioFile") == 0) {
    // {"file":"tone.m4a"}: a name under the app's assets/hardware.
    char name[64] = "tone.mp3";
    const char* key = "\"file\":\"";
    for (size_t i = 0; i + strlen(key) < body_len; i++) {
      if (memcmp(body + i, key, strlen(key)) == 0) {
        const char* v = body + i + strlen(key);
        size_t n = 0;
        while (v + n < body + body_len && v[n] != '"' && n + 1 < sizeof name) n++;
        memcpy(name, v, n);
        name[n] = '\0';
        break;
      }
    }
    char path[160];
    snprintf(path, sizeof path, "app0:/flutter_assets/assets/hardware/%s", name);
    return check_audio_file(out, cap, path, (unsigned)body_int(body, body_len, "max_ms", 4000));
  }
  if (strcmp(method, "mic") == 0) {
    return check_mic(out, cap, (unsigned)body_int(body, body_len, "ms", 1000), "ux0:data/flutter-vita/mic.wav");
  }
  if (strcmp(method, "camera") == 0) return check_camera(out, cap, body_int(body, body_len, "which", 0));
  return snprintf(out, cap, "[\"unknown\",\"no such check: %s\",null]", method);
}

__attribute__((constructor)) static void register_hardware(void) {
  fvita_channel_register("vita/hardware", dispatch);
}
