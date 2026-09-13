// Every thread says where it went to sleep. Dev builds only.
//
// The stall report in the engine (BuildDiag in vita_embedder.cc) lists each
// thread's state and scans its stack for return addresses, and the kernel
// gives it no stack pointer to start from -- sceKernelGetThreadStackFreeSize
// is not answered for threads pthread created, and the VM context hooks
// refuse (0x8002710B). Scanning the wrong region prints the thread's history
// instead of its present: on 2026-09-13 a frozen UI thread scanned as
// FreeType glyph code it had run minutes earlier.
//
// So the threads tell it. The blocking kernel calls are wrapped at link time
// (`-Wl,--wrap=sceKernelWaitSema` and the rest, in CMakeLists.txt) and each
// records, on the way in, the object it waits on, its caller, and its stack
// pointer at that moment. The report scans from that pointer, and every frame
// it finds above it is live by construction.
//
// A wrapper is a handful of stores and one thread-id syscall around the real
// call. The message loops pass through once per idle, Dart's monitors once
// per message.

#include <psp2/kernel/threadmgr.h>
#include <stdint.h>

void flutter_vita_wait_begin(int kind, unsigned object, uintptr_t sp,
                             uintptr_t caller);
void flutter_vita_wait_end(void);

static inline uintptr_t current_sp(void) {
  uintptr_t sp;
  __asm__ volatile("mov %0, sp" : "=r"(sp));
  return sp;
}

#define NOTE(kind, object)                                                     \
  flutter_vita_wait_begin((kind), (unsigned)(object), current_sp(),            \
                          (uintptr_t)__builtin_return_address(0))

// The kinds match WaitKindName in the embedder.
enum {
  kSema = 1, kEvf, kMutex, kLwMutex, kCond, kLwCond, kSignal, kDelay,
  kDartMonitor, kStdCondvar
};

// Two levels up from the kernel, the waits that name the reason.
//
// A thread parked in a Dart monitor reaches the kernel through pte's
// semaphore, and the wrapper above records pte as the caller. That says how
// it sleeps, not why. These record the VM function that asked: the wrap is on
// the mangled C++ symbol, which the linker treats like any other, and the
// return address is the VM call site because Monitor::WaitMicros and
// MonitorLocker::Wait are inline. The condition variable's address is the
// object, so two threads parked on the same one show the same number.
int __real__ZN4dart17ConditionVariable10WaitMicrosEPNS_5MutexEx(
    void* self, void* mutex, long long micros);
int __wrap__ZN4dart17ConditionVariable10WaitMicrosEPNS_5MutexEx(
    void* self, void* mutex, long long micros) {
  NOTE(kDartMonitor, (uintptr_t)self);
  const int r = __real__ZN4dart17ConditionVariable10WaitMicrosEPNS_5MutexEx(
      self, mutex, micros);
  flutter_vita_wait_end();
  return r;
}

int __real__ZN4dart17ConditionVariable4WaitEPNS_5MutexEx(void* self,
                                                        void* mutex,
                                                        long long millis);
int __wrap__ZN4dart17ConditionVariable4WaitEPNS_5MutexEx(void* self,
                                                        void* mutex,
                                                        long long millis) {
  NOTE(kDartMonitor, (uintptr_t)self);
  const int r =
      __real__ZN4dart17ConditionVariable4WaitEPNS_5MutexEx(self, mutex, millis);
  flutter_vita_wait_end();
  return r;
}

// fml's loops and thread pools sleep in std::condition_variable.
void __real__ZNSt18condition_variable4waitERSt11unique_lockISt5mutexE(
    void* self, void* lock);
void __wrap__ZNSt18condition_variable4waitERSt11unique_lockISt5mutexE(
    void* self, void* lock) {
  NOTE(kStdCondvar, (uintptr_t)self);
  __real__ZNSt18condition_variable4waitERSt11unique_lockISt5mutexE(self, lock);
  flutter_vita_wait_end();
}

int __real_sceKernelWaitSema(SceUID s, int n, SceUInt* t);
int __wrap_sceKernelWaitSema(SceUID s, int n, SceUInt* t) {
  NOTE(kSema, s);
  const int r = __real_sceKernelWaitSema(s, n, t);
  flutter_vita_wait_end();
  return r;
}

int __real_sceKernelWaitEventFlag(int e, unsigned bits, unsigned mode,
                                  unsigned* out, SceUInt* t);
int __wrap_sceKernelWaitEventFlag(int e, unsigned bits, unsigned mode,
                                  unsigned* out, SceUInt* t) {
  NOTE(kEvf, e);
  const int r = __real_sceKernelWaitEventFlag(e, bits, mode, out, t);
  flutter_vita_wait_end();
  return r;
}

// A lock is only a wait when somebody else holds it. Dart takes a monitor
// for every message and every safepoint transition, and noting each of those
// cost a third of the UI thread's time on 2026-09-13 (build 18 to 22 of the
// gallery). The try comes first, an atomic in user memory for a lightweight
// mutex, and only a refused try is recorded and waited for.
int __real_sceKernelLockLwMutex(SceKernelLwMutexWork* w, int n, unsigned* t);
int __wrap_sceKernelLockLwMutex(SceKernelLwMutexWork* w, int n, unsigned* t) {
  if (sceKernelTryLockLwMutex(w, n) >= 0) return 0;
  NOTE(kLwMutex, (uintptr_t)w);
  const int r = __real_sceKernelLockLwMutex(w, n, t);
  flutter_vita_wait_end();
  return r;
}

int __real_sceKernelWaitCond(SceUID c, unsigned* t);
int __wrap_sceKernelWaitCond(SceUID c, unsigned* t) {
  NOTE(kCond, c);
  const int r = __real_sceKernelWaitCond(c, t);
  flutter_vita_wait_end();
  return r;
}

int __real_sceKernelWaitLwCond(SceKernelLwCondWork* w, unsigned* t);
int __wrap_sceKernelWaitLwCond(SceKernelLwCondWork* w, unsigned* t) {
  NOTE(kLwCond, (uintptr_t)w);
  const int r = __real_sceKernelWaitLwCond(w, t);
  flutter_vita_wait_end();
  return r;
}

int __real_sceKernelWaitSignal(SceUInt32 unk, SceUInt32 delay, SceUInt32* t);
int __wrap_sceKernelWaitSignal(SceUInt32 unk, SceUInt32 delay, SceUInt32* t) {
  NOTE(kSignal, unk);
  const int r = __real_sceKernelWaitSignal(unk, delay, t);
  flutter_vita_wait_end();
  return r;
}

int __real_sceKernelDelayThread(SceUInt delay);
int __wrap_sceKernelDelayThread(SceUInt delay) {
  NOTE(kDelay, delay);
  const int r = __real_sceKernelDelayThread(delay);
  flutter_vita_wait_end();
  return r;
}
