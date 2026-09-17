// device_info_plus on the Vita: what the kernel says about the console.
#include <fvita_plugin.h>

#include <psp2/appmgr.h>
#include <psp2/kernel/modulemgr.h>
#include <psp2/kernel/sysmem.h>
#include <psp2/power.h>

#include <string.h>

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  (void)body;
  (void)len;
  if (strcmp(method, "info") != 0) return fvita_reply_err(out, cap, "unknown", method, 0);
  SceKernelSystemSwVersion sw;
  memset(&sw, 0, sizeof sw);
  sw.size = sizeof sw;
  sceKernelGetSystemSwVersion(&sw);
  // 0x10000 is a Vita, 0x20000 the PS TV: no cameras, no touch panels, no
  // motion sensors, a television for a screen.
  const int model = sceKernelGetModel();
  char title[16] = "";
  sceAppMgrAppParamGetString(0, 12, title, sizeof title);
  return fvita_reply_ok(out, cap,
                        "{\"model\":\"%s\",\"model_code\":%d,\"firmware\":\"%s\",\"title_id\":\"%s\",\"cores\":4,"
                        "\"arm_mhz\":%d,\"bus_mhz\":%d,\"gpu_mhz\":%d}",
                        model == 0x20000 ? "PlayStation TV" : "PlayStation Vita", model, sw.versionString, title,
                        scePowerGetArmClockFrequency(), scePowerGetBusClockFrequency(), scePowerGetGpuClockFrequency());
}

__attribute__((constructor)) static void reg(void) { fvita_channel_register("vita/device", handle); }
