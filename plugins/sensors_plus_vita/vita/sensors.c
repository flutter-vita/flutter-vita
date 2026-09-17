// sensors_plus on the Vita: the accelerometer and the gyroscope through
// SceMotion, read on demand.
//
// `start` turns sampling on, `read` returns the latest raw sample, `stop`
// turns sampling off. The raw sensors (sceMotionGetSensorState), not the
// fused state: the fused state gave zeros for acceleration and angular
// velocity on gallery build 30, a minute after sampling started.
//
// Units as the console gives them: the accelerometer in g (1.00 at rest),
// the gyro as SceMotion reports angular velocity; the Dart side scales the
// accelerometer to m/s^2. The console has no magnetometer an app can read
// as a vector, and no barometer.
#include <fvita_plugin.h>

#include <psp2/motion.h>

#include <string.h>

static int g_sampling;

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  (void)body;
  (void)len;
  if (strcmp(method, "start") == 0) {
    if (!g_sampling) {
      const int r = sceMotionStartSampling();
      if (r < 0 && r != (int)SCE_MOTION_ERROR_ALREADY_SAMPLING) return fvita_reply_err(out, cap, "failed", "sceMotionStartSampling", r);
      g_sampling = 1;
    }
    return fvita_reply_ok(out, cap, "true");
  }
  if (strcmp(method, "stop") == 0) {
    if (g_sampling) sceMotionStopSampling();
    g_sampling = 0;
    return fvita_reply_ok(out, cap, "true");
  }
  if (strcmp(method, "read") == 0) {
    if (!g_sampling) return fvita_reply_err(out, cap, "state", "read before start", 0);
    SceMotionSensorState s;
    memset(&s, 0, sizeof s);
    const int r = sceMotionGetSensorState(&s, 1);
    if (r < 0) return fvita_reply_err(out, cap, "failed", "sceMotionGetSensorState", r);
    return fvita_reply_ok(out, cap,
                          "{\"ax\":%.5f,\"ay\":%.5f,\"az\":%.5f,\"gx\":%.5f,\"gy\":%.5f,\"gz\":%.5f,\"t\":%llu,"
                          "\"counter\":%u}",
                          s.accelerometer.x, s.accelerometer.y, s.accelerometer.z, s.gyro.x, s.gyro.y, s.gyro.z,
                          (unsigned long long)s.hostTimestamp, s.counter);
  }
  return fvita_reply_err(out, cap, "unknown", method, 0);
}

__attribute__((constructor)) static void reg(void) { fvita_channel_register("vita/sensors", handle); }
