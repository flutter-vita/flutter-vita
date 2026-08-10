// A replacement for libgcc's emulated-TLS runtime.
//
// VitaSDK has no ELF TLS, so every `thread_local` compiles to a call to
// __emutls_get_address. libgcc's implementation is unusable here, in two
// different ways depending on how it is linked:
//
//   * By default __gthread_active_p() is false -- it is literally "is the
//     address of pthread_cancel non-null?", a *weak* reference, and weak
//     undefined references do not pull a member out of a static archive. So
//     libgcc takes its single-threaded path and every thread_local becomes ONE
//     SHARED GLOBAL across all threads. Measured: main set 111, a worker set
//     222, main then read 222.
//
//   * Forcing the symbol in with -u pthread_cancel flips it to the real
//     pthread path, and it crashes at startup, because emutls guards its table
//     with a *statically* initialised mutex and VitaSDK's pthread does not
//     support static mutex initialisers:
//
//         pthread_mutex_unlock:
//           ldr r3, [r0, #0]
//           ldr r1, [r3, #12]   <- data abort, r3 garbage
//
// __emutls_get_address is a plain ABI function, so defining it here overrides
// libgcc's for the whole link. That repairs every thread_local in the Dart
// runtime at once, rather than patching Thread::Current() and leaving the rest
// silently sharing state.
//
// Two properties matter, because Dart reads Thread::Current() from allocation
// slow paths, GC, and no-safepoint scopes:
//
//   * steady-state reads are allocation-free and lock-free -- a scan of a small
//     table plus an array index
//   * the lock is only taken when a thread is seen for the first time, or a
//     variable is first touched by a thread
//
// It also means no pthread involvement at all, so the uninitialised-mutex
// problem cannot recur.

#include <psp2/kernel/threadmgr.h>

#include <malloc.h>  // memalign, which newlib does not put in stdlib.h
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Matches libgcc's layout exactly (emutls.c). `word` and `pointer` are both
// 32-bit on this target, so the struct is 16 bytes.
struct __emutls_object {
  unsigned int size;
  unsigned int align;
  union {
    uintptr_t offset;  // 1-based index, 0 = not yet assigned
    void* ptr;
  } loc;
  void* templ;
};

// Dart uses a handful of threads (main, a worker or two, our timer and power
// threads). These are generous and cost 32 * 64 * 4 = 8 KiB of BSS.
#define EMUTLS_MAX_THREADS 32
#define EMUTLS_MAX_VARS 64

typedef struct {
  volatile int tid;  // 0 = free slot
  void* slots[EMUTLS_MAX_VARS];
} emutls_thread;

static emutls_thread g_threads[EMUTLS_MAX_THREADS];
static volatile int g_lock;
static unsigned int g_next_index = 1;

// A plain test-and-set spinlock. Deliberately not a pthread mutex: needing one
// initialised before first use is precisely what breaks libgcc's version here,
// and contention is near zero because the lock is only taken on first touch.
static void lock(void) {
  while (__sync_lock_test_and_set(&g_lock, 1)) {
    sceKernelDelayThread(100);
  }
}

static void unlock(void) {
  __sync_lock_release(&g_lock);
}

// Find this thread's slot array, creating it if needed. Reads scan without the
// lock, which is safe because entries are only ever added -- never moved or
// removed -- and `tid` is written last.
static emutls_thread* thread_slots(void) {
  const int tid = sceKernelGetThreadId();

  for (int i = 0; i < EMUTLS_MAX_THREADS; i++) {
    if (g_threads[i].tid == tid) return &g_threads[i];
  }

  lock();
  // Re-check: another thread may have raced us to a slot.
  for (int i = 0; i < EMUTLS_MAX_THREADS; i++) {
    if (g_threads[i].tid == tid) {
      unlock();
      return &g_threads[i];
    }
  }
  for (int i = 0; i < EMUTLS_MAX_THREADS; i++) {
    if (g_threads[i].tid == 0) {
      memset(g_threads[i].slots, 0, sizeof g_threads[i].slots);
      g_threads[i].tid = tid;  // published last, so a lock-free reader that
                               // sees the tid also sees a cleared array
      unlock();
      return &g_threads[i];
    }
  }
  unlock();
  return NULL;  // out of thread slots
}

void* __emutls_get_address(struct __emutls_object* obj) {
  emutls_thread* t = thread_slots();
  if (t == NULL) return NULL;

  uintptr_t index = obj->loc.offset;
  if (index == 0) {
    lock();
    index = obj->loc.offset;  // re-check under the lock
    if (index == 0) {
      index = g_next_index++;
      obj->loc.offset = index;
    }
    unlock();
  }
  if (index > EMUTLS_MAX_VARS) return NULL;  // out of variable slots

  void* p = t->slots[index - 1];
  if (p == NULL) {
    // First touch of this variable on this thread. The only allocating path,
    // and it happens once per (thread, variable).
    const size_t align = obj->align < sizeof(void*) ? sizeof(void*) : obj->align;
    p = memalign(align, obj->size);
    if (p == NULL) return NULL;
    if (obj->templ != NULL) {
      memcpy(p, obj->templ, obj->size);
    } else {
      memset(p, 0, obj->size);
    }
    t->slots[index - 1] = p;
  }
  return p;
}

// libgcc also exports these. They are only used by its own registration path,
// which we have replaced, but the symbols must exist if anything references
// them.
void __emutls_register_common(struct __emutls_object* obj,
                              unsigned int size,
                              unsigned int align,
                              void* templ) {
  if (obj->size < size) {
    obj->size = size;
    obj->templ = NULL;
  }
  if (obj->align < align) obj->align = align;
  if (templ != NULL && size == obj->size) obj->templ = templ;
}
