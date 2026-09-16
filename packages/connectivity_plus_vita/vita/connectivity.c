// connectivity_plus on the Vita: SceNetCtl's view of the one link the
// console has, Wi-Fi (or the PS TV's Ethernet), read on demand.
//
// The embedder brings SceNet and SceNetCtl up for the dev server, so this
// file does not initialise them.
#include <fvita_plugin.h>

#include <psp2/net/netctl.h>

#include <string.h>

static int handle(const char* method, const char* body, size_t len, char* out, size_t cap) {
  (void)body;
  (void)len;
  if (strcmp(method, "check") != 0) return fvita_reply_err(out, cap, "unknown", method, 0);
  int state = -1;
  const int r = sceNetCtlInetGetState(&state);
  if (r < 0) return fvita_reply_err(out, cap, "failed", "sceNetCtlInetGetState", r);
  SceNetCtlInfo ip, ssid, rssi, device;
  memset(&ip, 0, sizeof ip);
  memset(&ssid, 0, sizeof ssid);
  memset(&rssi, 0, sizeof rssi);
  memset(&device, 0, sizeof device);
  const int up = state == SCE_NETCTL_STATE_CONNECTED;
  if (up) {
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_IP_ADDRESS, &ip);
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_SSID, &ssid);
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_RSSI_PERCENTAGE, &rssi);
    sceNetCtlInetGetInfo(SCE_NETCTL_INFO_GET_DEVICE, &device);
  }
  // device: 0 is the wireless adapter, 1 the PS TV's wired port.
  return fvita_reply_ok(out, cap,
                        "{\"state\":%d,\"connected\":%s,\"device\":%u,\"ip\":\"%s\",\"ssid\":\"%s\",\"rssi_pct\":%u}",
                        state, up ? "true" : "false", up ? device.device : 0u, up ? ip.ip_address : "",
                        up ? ssid.ssid : "", up ? rssi.rssi_percentage : 0u);
}

__attribute__((constructor)) static void reg(void) { fvita_channel_register("vita/connectivity", handle); }
