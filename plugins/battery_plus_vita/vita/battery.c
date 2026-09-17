// battery_plus on the Vita: ScePower, read on demand.
//
// One method, `status`, with everything the console says about its battery;
// the Dart side derives the level, the state and the stream from it.
#include <fvita_plugin.h>

#include <psp2/power.h>

#include <string.h>

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  (void)body;
  (void)len;
  if (strcmp(method, "status") != 0) return fvita_reply_err(out, cap, "unknown", method, 0);
  const int pct = scePowerGetBatteryLifePercent();
  return fvita_reply_ok(out, cap,
                        "{\"level\":%d,\"charging\":%s,\"online\":%s,\"low\":%s,\"minutes\":%d,\"temp_c\":%.1f,"
                        "\"volt_mv\":%d}",
                        pct < 0 ? -1 : pct, scePowerIsBatteryCharging() ? "true" : "false",
                        scePowerIsPowerOnline() ? "true" : "false", scePowerIsLowBattery() ? "true" : "false",
                        scePowerGetBatteryLifeTime(), scePowerGetBatteryTemp() / 100.0, scePowerGetBatteryVolt());
}

__attribute__((constructor)) static void reg(void) { fvita_channel_register("vita/battery", handle); }
