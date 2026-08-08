// vitantp_kernel — the one thing that has to live in kernel space.
//
// Setting the Vita's clock is kernel-only: psp2/rtc.h exposes
// sceRtcGetCurrentTick but no setter, and only psp2kern has
// ksceRtcSetCurrentTick. Everything else about time sync — DNS, the NTP
// exchange, retries — is ordinary user code and stays out here.
//
// This module is deliberately tiny and does no I/O of its own. It is loaded on
// demand with taiLoadStartKernelModuleForUser, used, and unloaded again, so it
// never appears in ur0:tai/config.txt and cannot affect boot. A fault here
// costs a power cycle, not a bricked console.

#include <psp2kern/kernel/modulemgr.h>
#include <psp2kern/kernel/rtc.h>

// The Vita counts microseconds from 0001-01-01, Unix from 1970-01-01. This is
// the gap, and getting it wrong is the difference between the right time and a
// clock two millennia out.
#define UNIX_EPOCH_IN_VITA_TICKS 62135596800000000ULL

int vitaNtpKernelGetApiVersion(void) {
  return 1;
}

// Returns 0 on success. `unix_seconds` is a normal Unix timestamp (UTC).
int vitaNtpKernelSetUnixTime(unsigned int unix_seconds) {
  // Refuse anything implausible rather than trusting a packet off the network:
  // a corrupted reply should not be able to set the clock to 1970 or to the
  // year 2200. 1.7e9 is 2023-11, 2.1e9 is 2036-07.
  if (unix_seconds < 1700000000u || unix_seconds > 2100000000u) {
    return -1;
  }
  SceRtcTick tick;
  tick.tick = UNIX_EPOCH_IN_VITA_TICKS +
              (unsigned long long)unix_seconds * 1000000ULL;
  return ksceRtcSetCurrentTick(&tick);
}

int module_start(SceSize argc, const void *args) {
  (void)argc;
  (void)args;
  return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argc, const void *args) {
  (void)argc;
  (void)args;
  return SCE_KERNEL_STOP_SUCCESS;
}

// Declared after module_start and with the matching prototype, as every
// working kernel module in the wild does it. The previous version declared
// `void _start()` ahead of the definition, aliasing a function of a different
// type.
int _start(SceSize argc, const void *args)
    __attribute__((weak, alias("module_start")));
