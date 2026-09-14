// The hardware checks behind the gallery's Hardware tab.
//
// One function the embedder calls for every message on the `vita/hardware`
// channel (JSONMethodCodec): the method name, the raw body, and a buffer for
// the reply envelope, `[result]` for success or `[code, message, details]`
// for an error. Each method is one piece of the console: a camera, the
// microphone, the motion sensors, a touch panel, the battery. The Dart side
// decides what a pass is; this side reports what the hardware said.
//
// Built only when the app's pubspec says `hardware_checks: true`
// (build-vita-app.sh passes HARDWARE_CHECKS=ON to the template), because it
// links five stub libraries an ordinary app has no use for. Dev-loop
// infrastructure: a shipping app never includes it.
//
// Everything here runs on the platform thread, the one that drains platform
// messages. A check that needs time (a second of tone, a camera frame) blocks
// that thread for that long, which is acceptable for a test tab and would
// not be for an app.
#include <psp2/appmgr.h>
#include <psp2/audioin.h>
#include <psp2/audioout.h>
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

static int reply_ok(char* out, size_t cap, const char* fmt, ...) {
  int n = snprintf(out, cap, "[");
  va_list ap;
  va_start(ap, fmt);
  n += vsnprintf(out + n, cap - (size_t)n, fmt, ap);
  va_end(ap);
  if ((size_t)n + 2 > cap) return -1;
  out[n++] = ']';
  out[n] = '\0';
  return n;
}

static int reply_err(char* out, size_t cap, const char* what, int code) {
  return snprintf(out, cap, "[\"failed\",\"%s: 0x%08X\",null]", what, (unsigned)code);
}

// A line in the app log, written now. stderr is the engine's log file,
// unbuffered, so a check that never comes back still leaves its last step.
static void hw_log(const char* fmt, ...) {
  char line[160];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(line, sizeof line, fmt, ap);
  va_end(ap);
  fprintf(stderr, "hardware: %s\n", line);
}

// The first integer after `"key":` in the JSON body, or `dflt`. The bodies
// here are `{"method":"x","args":{"which":1}}`, which is all this needs.
static int body_int(const char* body, size_t len, const char* key, int dflt) {
  char pat[48];
  snprintf(pat, sizeof pat, "\"%s\":", key);
  const size_t pl = strlen(pat);
  for (size_t i = 0; i + pl < len; i++) {
    if (memcmp(body + i, pat, pl) == 0) return atoi(body + i + pl);
  }
  return dflt;
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

// A second of 440 Hz through the main port at 48 kHz, stereo. Blocks for the
// second; sceAudioOutOutput waits for the previous grain, which is the clock.
static int check_audio_tone(char* out, size_t cap) {
  enum { kRate = 48000, kGrain = 960, kSeconds = 1 };
  const int port = sceAudioOutOpenPort(SCE_AUDIO_OUT_PORT_TYPE_MAIN, kGrain, kRate, SCE_AUDIO_OUT_MODE_STEREO);
  if (port < 0) return reply_err(out, cap, "sceAudioOutOpenPort", port);
  int vol[2] = {SCE_AUDIO_OUT_MAX_VOL / 2, SCE_AUDIO_OUT_MAX_VOL / 2};
  sceAudioOutSetVolume(port, SCE_AUDIO_VOLUME_FLAG_L_CH | SCE_AUDIO_VOLUME_FLAG_R_CH, vol);
  static int16_t buf[kGrain * 2];
  unsigned phase = 0;
  const unsigned grains = kRate / kGrain * kSeconds;
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  int r = 0;
  for (unsigned g = 0; g < grains && r >= 0; g++) {
    for (int i = 0; i < kGrain; i++) {
      // A gentle fade at both ends so the speaker does not click.
      const unsigned n = g * kGrain + (unsigned)i;
      float env = 1.0f;
      if (n < 2400) env = n / 2400.0f;
      if (n > grains * kGrain - 2400) env = (grains * kGrain - n) / 2400.0f;
      const int16_t s = (int16_t)(sinf(2.0f * 3.14159265f * 440.0f * phase / kRate) * 12000.0f * env);
      buf[i * 2] = s;
      buf[i * 2 + 1] = s;
      phase++;
    }
    r = sceAudioOutOutput(port, buf);
  }
  sceAudioOutOutput(port, NULL);  // drain
  const unsigned took_ms = (unsigned)((sceKernelGetProcessTimeWide() - t0) / 1000);
  sceAudioOutReleasePort(port);
  if (r < 0) return reply_err(out, cap, "sceAudioOutOutput", r);
  return reply_ok(out, cap, "{\"port\":%d,\"rate\":%d,\"grains\":%u,\"took_ms\":%u}", port, kRate, grains, took_ms);
}

// ---- audio out: a file through sceAvPlayer --------------------------------

static void* av_alloc(void* arg, uint32_t alignment, uint32_t size) {
  (void)arg;
  return memalign(alignment, size);
}
static void av_free(void* arg, void* ptr) {
  (void)arg;
  free(ptr);
}
static void* av_alloc_frame(void* arg, uint32_t alignment, uint32_t size) {
  (void)arg;
  return memalign(alignment < 0x40 ? 0x40 : alignment, size);
}
static void av_free_frame(void* arg, void* ptr) {
  (void)arg;
  free(ptr);
}

// Plays the whole file, up to `max_ms`, and reports what the decoder said
// about it. The system's player decodes MP3 and AAC; the app ships one.
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
  int r = sceAvPlayerAddSource(h, path);
  if (r < 0) {
    sceAvPlayerClose(h);
    return reply_err(out, cap, "sceAvPlayerAddSource", r);
  }
  int port = -1;
  unsigned frames = 0, channels = 0, rate = 0, bytes = 0;
  const uint64_t t0 = sceKernelGetProcessTimeWide();
  while (sceAvPlayerIsActive(h)) {
    if ((sceKernelGetProcessTimeWide() - t0) / 1000 > max_ms) break;
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
      port = sceAudioOutOpenPort(SCE_AUDIO_OUT_PORT_TYPE_MAIN, grain, (int)rate,
                                 channels == 1 ? SCE_AUDIO_OUT_MODE_MONO : SCE_AUDIO_OUT_MODE_STEREO);
      if (port < 0) {
        sceAvPlayerStop(h);
        sceAvPlayerClose(h);
        return reply_err(out, cap, "sceAudioOutOpenPort(file)", port);
      }
      int vol[2] = {SCE_AUDIO_OUT_MAX_VOL / 2, SCE_AUDIO_OUT_MAX_VOL / 2};
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
  if (frames == 0) return reply_err(out, cap, "no audio frame decoded", 0);
  return reply_ok(out, cap, "{\"frames\":%u,\"channels\":%u,\"rate\":%u,\"bytes\":%u,\"took_ms\":%u}", frames,
                  channels, rate, bytes, took_ms);
}

// ---- microphone ------------------------------------------------------------

// Half a second from the microphone: the peak and the RMS, so the tab can say
// whether the room was silent or someone spoke.
static int check_mic(char* out, size_t cap) {
  enum { kRate = 16000, kGrain = 256, kGrains = 31 };  // ~0.5 s
  const int port = sceAudioInOpenPort(SCE_AUDIO_IN_PORT_TYPE_VOICE, kGrain, kRate, SCE_AUDIO_IN_PARAM_FORMAT_S16_MONO);
  if (port < 0) return reply_err(out, cap, "sceAudioInOpenPort", port);
  static int16_t buf[kGrain];
  int peak = 0;
  double sq = 0;
  unsigned n = 0;
  int r = 0;
  for (int g = 0; g < kGrains && r >= 0; g++) {
    r = sceAudioInInput(port, buf);
    if (r < 0) break;
    for (int i = 0; i < kGrain; i++) {
      const int v = abs(buf[i]);
      if (v > peak) peak = v;
      sq += (double)buf[i] * buf[i];
      n++;
    }
  }
  sceAudioInReleasePort(port);
  if (r < 0) return reply_err(out, cap, "sceAudioInInput", r);
  const double rms = n ? sqrt(sq / n) : 0;
  return reply_ok(out, cap, "{\"port\":%d,\"rate\":%d,\"samples\":%u,\"peak\":%d,\"rms\":%.0f,\"muted\":%s}", port, kRate, n,
                  peak, rms, sceAudioInGetStatus(SCE_AUDIO_IN_GETSTATUS_MUTE) > 0 ? "true" : "false");
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
  if (strcmp(method, "audioTone") == 0) return check_audio_tone(out, cap);
  if (strcmp(method, "audioFile") == 0) {
    return check_audio_file(out, cap, "app0:/flutter_assets/assets/hardware/tone.mp3",
                            (unsigned)body_int(body, body_len, "max_ms", 4000));
  }
  if (strcmp(method, "mic") == 0) return check_mic(out, cap);
  if (strcmp(method, "camera") == 0) return check_camera(out, cap, body_int(body, body_len, "which", 0));
  return snprintf(out, cap, "[\"unknown\",\"no such check: %s\",null]", method);
}

// Every check runs on a thread of its own, with a deadline. The channel
// handler that calls this is the platform thread, and a check that blocks
// in the system -- sceCameraRead waiting for a frame that never comes, on
// 2026-09-14 -- would block every channel message after it, and the Dart
// side's own timeout can do nothing about it. On the deadline the caller
// gets an error and the thread is left where it is: its buffers are its own,
// so whatever it writes later lands nowhere the caller reads.
typedef struct HardwareJob {
  char method[32];
  char* body;
  size_t body_len;
  char* out;
  size_t cap;
  int rc;
} HardwareJob;

static int job_thread(SceSize args, void* argp) {
  (void)args;
  HardwareJob* j = *(HardwareJob**)argp;
  j->rc = dispatch(j->method, j->body, j->body_len, j->out, j->cap);
  return 0;
}

int flutter_vita_hardware_call(const char* method, const char* body, size_t body_len, char* out, size_t cap) {
  if (method == NULL || out == NULL || cap < 64) return -1;
  HardwareJob* j = calloc(1, sizeof *j);
  if (j == NULL) return -1;
  snprintf(j->method, sizeof j->method, "%s", method);
  j->body_len = body != NULL ? body_len : 0;
  j->body = malloc(j->body_len + 1);
  j->out = malloc(cap);
  if (j->body == NULL || j->out == NULL) {
    free(j->body);
    free(j->out);
    free(j);
    return -1;
  }
  if (j->body_len) memcpy(j->body, body, j->body_len);
  j->body[j->body_len] = '\0';
  j->cap = cap;
  j->out[0] = '\0';
  const SceUID th = sceKernelCreateThread("fvita-hardware", job_thread, 0x10000100, 0x10000, 0, 0, NULL);
  if (th < 0) {
    free(j->body);
    free(j->out);
    free(j);
    return snprintf(out, cap, "[\"thread\",\"%s: sceKernelCreateThread 0x%08X\",null]", method, (unsigned)th);
  }
  sceKernelStartThread(th, sizeof j, &j);
  SceUInt timeout = 15 * 1000 * 1000;
  if (sceKernelWaitThreadEnd(th, NULL, &timeout) < 0) {
    // Abandoned, buffers and all; the thread frees nothing.
    return snprintf(out, cap, "[\"timeout\",\"%s: no answer in 15 s\",null]", method);
  }
  sceKernelDeleteThread(th);
  const int rc = j->rc;
  snprintf(out, cap, "%s", j->out);
  free(j->body);
  free(j->out);
  free(j);
  return rc;
}
