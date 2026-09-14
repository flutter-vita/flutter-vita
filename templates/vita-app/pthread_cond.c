// pthread condition variables on the kernel's own, in place of the SDK's.
//
// VitaSDK's pthread is pthreads-embedded. Its condition variable is built from
// semaphores, its semaphore wait polls the kernel every 500 us so that it can
// be cancelled, and the construction lost a broadcast on 2026-09-13: two
// threads parked one generation apart on Dart's marker barrier, and the app
// froze with all four cores idle (docs/results/the-frozen-ui-thread-2026-09-13.md).
// Dart's own monitor moved to the kernel's lightweight mutex and condition
// that day. Everything that goes through std::condition_variable still came
// here: fml's ConcurrentMessageLoop and its two io.worker threads, the
// waitable events the shell blocks on, std::future.
//
// This file defines the six pthread_cond functions, so the linker never pulls
// the SDK's. Each condition is a kernel LwCond bound to a private LwMutex, the
// gate. A waiter takes the gate, releases the caller's mutex, and waits on the
// LwCond, which releases the gate atomically; a signaller takes the gate to
// signal. So a signal cannot fall between "released the caller's mutex" and
// "parked", which is the whole contract, and the caller's mutex stays
// whatever pthread_mutex_t the SDK gives us. No polling: a parked thread
// costs nothing until it is woken.
//
// pthread_cond_t is a pointer in this SDK and PTHREAD_COND_INITIALIZER is
// (pthread_cond_t)-1, which is what a static std::condition_variable holds
// until first use, so the object is made on first use with a compare-and-swap.
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <psp2/kernel/error.h>
#include <psp2/kernel/threadmgr.h>

struct pthread_cond_t_ {
  SceKernelLwMutexWork gate;
  SceKernelLwCondWork cond;
};

static struct pthread_cond_t_* cond_new(void) {
  struct pthread_cond_t_* p = malloc(sizeof *p);
  if (p == NULL) return NULL;
  memset(p, 0, sizeof *p);
  if (sceKernelCreateLwMutex(&p->gate, "pthread_cond", SCE_KERNEL_ATTR_THREAD_FIFO, 0, NULL) < 0) {
    free(p);
    return NULL;
  }
  if (sceKernelCreateLwCond(&p->cond, "pthread_cond", SCE_KERNEL_ATTR_THREAD_FIFO, &p->gate, NULL) < 0) {
    sceKernelDeleteLwMutex(&p->gate);
    free(p);
    return NULL;
  }
  return p;
}

static void cond_free(struct pthread_cond_t_* p) {
  sceKernelDeleteLwCond(&p->cond);
  sceKernelDeleteLwMutex(&p->gate);
  free(p);
}

// The object behind `c`, made on first use when `create` says so. NULL for a
// destroyed or never-initialised condition, which POSIX calls EINVAL.
static struct pthread_cond_t_* cond_get(pthread_cond_t* c, int create) {
  struct pthread_cond_t_* p = __atomic_load_n(c, __ATOMIC_ACQUIRE);
  if (p != PTHREAD_COND_INITIALIZER) return p;
  if (!create) return NULL;
  struct pthread_cond_t_* made = cond_new();
  if (made == NULL) return NULL;
  struct pthread_cond_t_* expected = PTHREAD_COND_INITIALIZER;
  if (__atomic_compare_exchange_n(c, &expected, made, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return made;
  cond_free(made);  // another thread got there first
  return expected;
}

int pthread_cond_init(pthread_cond_t* c, const pthread_condattr_t* attr) {
  (void)attr;  // process-shared and clock attributes have no meaning here
  struct pthread_cond_t_* p = cond_new();
  if (p == NULL) return ENOMEM;
  __atomic_store_n(c, p, __ATOMIC_RELEASE);
  return 0;
}

int pthread_cond_destroy(pthread_cond_t* c) {
  struct pthread_cond_t_* p = __atomic_exchange_n(c, NULL, __ATOMIC_ACQ_REL);
  if (p != NULL && p != PTHREAD_COND_INITIALIZER) cond_free(p);
  return 0;
}

// `timeout` in microseconds, or NULL for no limit.
static int cond_wait(pthread_cond_t* c, pthread_mutex_t* m, unsigned int* timeout) {
  struct pthread_cond_t_* p = cond_get(c, 1);
  if (p == NULL) return EINVAL;
  sceKernelLockLwMutex(&p->gate, 1, NULL);
  pthread_mutex_unlock(m);
  const int r = sceKernelWaitLwCond(&p->cond, timeout);
  sceKernelUnlockLwMutex(&p->gate, 1);
  pthread_mutex_lock(m);
  if (r >= 0) return 0;
  if ((unsigned int)r == SCE_KERNEL_ERROR_WAIT_TIMEOUT) return ETIMEDOUT;
  return EINVAL;
}

int pthread_cond_wait(pthread_cond_t* c, pthread_mutex_t* m) { return cond_wait(c, m, NULL); }

int pthread_cond_timedwait(pthread_cond_t* c, pthread_mutex_t* m, const struct timespec* abstime) {
  if (abstime == NULL) return EINVAL;
  // The deadline is CLOCK_REALTIME, as libstdc++ passes it. A deadline in
  // the past still goes through the wait, so a pending signal is consumed
  // the same way as with any other deadline.
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  long long us = (long long)(abstime->tv_sec - now.tv_sec) * 1000000LL +
                 (abstime->tv_nsec - now.tv_nsec) / 1000;
  if (us < 1) us = 1;
  // The kernel takes 32 bits of microseconds. A longer wait is cut at an
  // hour and returns 0: a spurious wakeup, which every caller re-checks.
  const long long kHour = 3600LL * 1000000LL;
  const int cut = us > kHour;
  unsigned int timeout = (unsigned int)(cut ? kHour : us);
  const int r = cond_wait(c, m, &timeout);
  return (r == ETIMEDOUT && cut) ? 0 : r;
}

int pthread_cond_signal(pthread_cond_t* c) {
  struct pthread_cond_t_* p = cond_get(c, 0);
  if (p == NULL) return 0;  // never waited on: nobody to wake
  sceKernelLockLwMutex(&p->gate, 1, NULL);
  sceKernelSignalLwCond(&p->cond);
  sceKernelUnlockLwMutex(&p->gate, 1);
  return 0;
}

int pthread_cond_broadcast(pthread_cond_t* c) {
  struct pthread_cond_t_* p = cond_get(c, 0);
  if (p == NULL) return 0;
  sceKernelLockLwMutex(&p->gate, 1, NULL);
  sceKernelSignalLwCondAll(&p->cond);
  sceKernelUnlockLwMutex(&p->gate, 1);
  return 0;
}
