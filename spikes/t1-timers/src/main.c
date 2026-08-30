// T1 -- what a wait actually costs on this console.
//
// Every Dart timer on this port fires on a 200 ms grid whatever it asks for,
// and the gallery's timer_probe.dart has already shown the UI thread's message
// loop is not the reason: with vsync waking it every 16.7 ms the timers were
// still 200.0 ms. That leaves dart:io's event handler, which waits out every
// deadline in poll() -- and on VitaSDK poll() is sceNetEpollCreate,
// sceNetEpollControl per fd, sceNetEpollWait, sceNetEpollDestroy, all of it per
// call, with the timeout passed through as microseconds.
//
// That much is from the disassembly of libc.a. What it does not say is which
// step is slow, and the answer decides the fix. So this measures the primitives
// directly, with no Dart, no engine and nothing else running:
//
//   A  sceKernelDelayThread          the control. If this is not accurate,
//                                    nothing downstream can be.
//   B  poll(NULL, 0, ms)             nfds == 0 short-circuits to
//                                    sceKernelDelayThread -- so B differing
//                                    from A would mean the disassembly is wrong.
//   C  poll(&pfd, 1, ms)             the path dart:io actually takes.
//   D  sceNetEpollWait on a          C without the per-call create/destroy. If
//      persistent epoll              C is slow and D is not, the epoll churn is
//                                    the cost and the fix is to hold one open.
//   E  readiness latency             a thread writes one byte to a socketpair;
//                                    how long until a blocked poll() returns.
//                                    This is the one that decides whether a
//                                    socket can be used as a wakeup channel at
//                                    all -- if it cannot, the event handler
//                                    needs a different one.
//   F  create + destroy alone        how much of C is setup.
//
// Run 1 answered A to F and refuted the hypothesis: every timeout is exact,
// including poll()'s with a socket in the array, and the epoll churn is free.
// What is late is *readiness* -- a byte written to a socketpair took ~99 ms to
// wake a blocked poll(), and then self-synchronised to that, which is the 200 ms
// grid. That matters because dart:io's event handler learns "arm a timer" by
// reading its interrupt socketpair, so every registration pays one.
//
// Run 2 adds the questions that decide the fix:
//
//   E  poll, varying when the      is the wake "write plus ~100 ms" or "wait
//      write lands                 start plus ~200 ms"? The two say different
//                                  things about what is polling what.
//   G  blocking recv instead       is it the notification that is late, or is
//      of poll                     loopback delivery itself? Our own dev server
//                                  answers a ping promptly over blocking
//                                  sceNetRecv, so this should be fast -- and if
//                                  it is, a socket can still be a wakeup
//                                  channel, just not through epoll.
//   I  event flag                  the proposed replacement channel. E, G and H
//                                  all landed on the same ~200 ms tick whatever
//                                  primitive was used, so the problem is not
//                                  poll -- it is that the channel is a loopback
//                                  socket. This is the same primitive
//                                  message_loop_vita.cc already wakes on sixty
//                                  times a second, and the fix depends on it
//                                  being prompt, so it is measured rather than
//                                  assumed.
//   H  sceNetEpollWait directly    newlib's poll() builds a fresh epoll per
//      on sceNet sockets           call and goes through its own descriptor
//                                  table. H skips both. If H is prompt and E is
//                                  not, the wrapper is the problem and the
//                                  event handler can simply stop using it.
//
// The report goes to ux0:data/flutter-vita/t1.log and to the screen, and then
// the console is handed back to the loader, so a run costs no taps.

#include <psp2/appmgr.h>
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
#include <psp2/kernel/cpu.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>
#include <psp2/net/net.h>
#include <psp2/net/netctl.h>
#include <psp2/power.h>
#include <psp2/sysmodule.h>

#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "debugScreen.h"

#define printf psvDebugScreenPrintf

// sceNetInit wants a pool it owns for as long as the stack is up.
static char g_net_pool[1 * 1024 * 1024];
static SceUID g_log = -1;

static void lg(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  const int n = vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  printf("%s", buf);
  if (g_log >= 0 && n > 0) {
    sceIoWrite(g_log, buf, (SceSize)n);
  }
}

static int64_t now_us(void) {
  return (int64_t)sceKernelGetProcessTimeWide();
}

// The five durations the Dart probe asks for, so the two reports line up.
static const int kMs[] = {1, 8, 16, 33, 100};
#define N_MS ((int)(sizeof kMs / sizeof kMs[0]))
#define REPS 5

// One row of the table: five requested durations, five measured means.
static void row(const char* label, int64_t (*wait_us)(int ms)) {
  lg("%-12s", label);
  for (int i = 0; i < N_MS; i++) {
    int64_t total = 0;
    for (int r = 0; r < REPS; r++) {
      total += wait_us(kMs[i]);
    }
    lg(" %d->%.1f", kMs[i], (double)total / REPS / 1000.0);
  }
  lg("\n");
}

static int64_t wait_delaythread(int ms) {
  const int64_t t0 = now_us();
  sceKernelDelayThread((SceUInt)(ms * 1000));
  return now_us() - t0;
}

static int64_t wait_poll_empty(int ms) {
  const int64_t t0 = now_us();
  poll(NULL, 0, ms);
  return now_us() - t0;
}

// A socketpair end nothing ever writes to, so poll can only return by timing
// out. Set up once in main and left open for the whole run.
static int g_pair[2] = {-1, -1};

static int64_t wait_poll_one(int ms) {
  struct pollfd pfd;
  pfd.fd = g_pair[0];
  pfd.events = POLLIN;
  pfd.revents = 0;
  const int64_t t0 = now_us();
  poll(&pfd, 1, ms);
  return now_us() - t0;
}

// A sceNet socket registered with an epoll that is created once, so the wait is
// measured without the create/destroy poll() does on every call. It is a UDP
// socket bound to nothing, which cannot become readable.
static SceUID g_epoll = -1;

static int64_t wait_epoll(int ms) {
  SceNetEpollEvent evs[4];
  memset(evs, 0, sizeof evs);
  const int64_t t0 = now_us();
  sceNetEpollWait(g_epoll, evs, 4, ms * 1000);
  return now_us() - t0;
}

static int64_t wait_create_destroy(int ms) {
  (void)ms;
  const int64_t t0 = now_us();
  const SceUID e = sceNetEpollCreate("t1-churn", 0);
  if (e >= 0) {
    sceNetEpollDestroy(e);
  }
  return now_us() - t0;
}

// --- E: how long after a write does a blocked poll() come back ---------------

static volatile int64_t g_wrote_us;
static int g_notify_delay_ms = 100;
// 0 writes the newlib socketpair, 1 the sceNet pair. Read by the notifier
// thread, set by the caller before it starts.
static int g_notify_scenet;

// A sceNet-level loopback TCP pair, made the long way round: no newlib fd, no
// __vita_fd_grab, no poll() wrapper. [0] is the accepted end, [1] the client.
static int g_snpair[2] = {-1, -1};

static SceUID g_flag = -1;
#define FLAG_BIT 1u

// The event-flag counterpart of the notifier: same shape, different channel.
static int flag_notifier(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  sceKernelDelayThread((SceUInt)(g_notify_delay_ms * 1000));
  g_wrote_us = now_us();
  sceKernelSetEventFlag(g_flag, FLAG_BIT);
  return 0;
}

static int notifier(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  sceKernelDelayThread((SceUInt)(g_notify_delay_ms * 1000));
  const char b = 'x';
  g_wrote_us = now_us();
  if (g_notify_scenet) {
    sceNetSend(g_snpair[1], &b, 1, 0);
  } else {
    send(g_pair[1], &b, 1, 0);
  }
  return 0;
}

static int make_scenet_pair(void) {
  const int srv =
      sceNetSocket("t1-srv", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
  if (srv < 0) {
    return -1;
  }
  SceNetSockaddrIn addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_len = sizeof addr;
  addr.sin_family = SCE_NET_AF_INET;
  addr.sin_port = sceNetHtons(0);
  addr.sin_addr.s_addr = sceNetHtonl(0x7F000001);
  unsigned int alen = sizeof addr;
  if (sceNetBind(srv, (SceNetSockaddr*)&addr, sizeof addr) < 0 ||
      sceNetGetsockname(srv, (SceNetSockaddr*)&addr, &alen) < 0 ||
      sceNetListen(srv, 1) < 0) {
    sceNetSocketClose(srv);
    return -1;
  }
  const int cli =
      sceNetSocket("t1-cli", SCE_NET_AF_INET, SCE_NET_SOCK_STREAM, 0);
  if (cli < 0) {
    sceNetSocketClose(srv);
    return -1;
  }
  if (sceNetConnect(cli, (SceNetSockaddr*)&addr, sizeof addr) < 0) {
    sceNetSocketClose(srv);
    sceNetSocketClose(cli);
    return -1;
  }
  const int acc = sceNetAccept(srv, NULL, NULL);
  sceNetSocketClose(srv);
  if (acc < 0) {
    sceNetSocketClose(cli);
    return -1;
  }
  g_snpair[0] = acc;
  g_snpair[1] = cli;
  return 0;
}

// Starts the notifier and returns its thread id, or a negative error.
static SceUID start_notifier(int delay_ms, int scenet) {
  g_wrote_us = 0;
  g_notify_delay_ms = delay_ms;
  g_notify_scenet = scenet;
  const SceUID th =
      sceKernelCreateThread("t1-notify", notifier, 0x40, 0x4000, 0, 0, NULL);
  if (th >= 0) {
    sceKernelStartThread(th, 0, NULL);
  }
  return th;
}

static void end_notifier(SceUID th) {
  sceKernelWaitThreadEnd(th, NULL, NULL);
  sceKernelDeleteThread(th);
}

// Milliseconds from the write to the wait returning, or a negative marker.
static void report_sample(int64_t back, int ok) {
  if (!ok || g_wrote_us == 0) {
    lg(" miss");
  } else {
    lg(" %.2f", (double)(back - g_wrote_us) / 1000.0);
  }
}

// `timeout` is passed straight to poll: -1 to block, or a number of ms well
// past the write, so the two cases can be told apart. sceNetEpollWait is given
// -1000 us for the blocking case and might not read that as "forever".
static void readiness(const char* label, int timeout, int delay_ms) {
  lg("%-14s", label);
  for (int r = 0; r < 5; r++) {
    const SceUID th = start_notifier(delay_ms, 0);
    if (th < 0) {
      lg(" thread 0x%08X", (unsigned)th);
      break;
    }
    struct pollfd pfd;
    pfd.fd = g_pair[0];
    pfd.events = POLLIN;
    pfd.revents = 0;
    const int n = poll(&pfd, 1, timeout);
    const int64_t back = now_us();
    report_sample(back, n > 0);
    char drain[8];
    recv(g_pair[0], drain, sizeof drain, 0);
    end_notifier(th);
  }
  lg(" ms\n");
}

// G: the same event, waited on with a blocking recv rather than poll.
static void blocking_recv(const char* label, int delay_ms) {
  lg("%-14s", label);
  for (int r = 0; r < 5; r++) {
    const SceUID th = start_notifier(delay_ms, 0);
    if (th < 0) {
      lg(" thread 0x%08X", (unsigned)th);
      break;
    }
    char drain[8];
    const int n = (int)recv(g_pair[0], drain, sizeof drain, 0);
    report_sample(now_us(), n > 0);
    end_notifier(th);
  }
  lg(" ms\n");
}

// H: sceNetEpollWait on sceNet sockets, with no newlib wrapper anywhere.
static void scenet_readiness(const char* label, int delay_ms, int use_epoll) {
  lg("%-14s", label);
  SceUID ep = -1;
  if (use_epoll) {
    ep = sceNetEpollCreate("t1-h", 0);
    SceNetEpollEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.events = SCE_NET_EPOLLIN;
    ev.data.fd = g_snpair[0];
    if (ep < 0 ||
        sceNetEpollControl(ep, SCE_NET_EPOLL_CTL_ADD, g_snpair[0], &ev) < 0) {
      lg(" epoll setup failed\n");
      return;
    }
  }
  for (int r = 0; r < 5; r++) {
    const SceUID th = start_notifier(delay_ms, 1);
    if (th < 0) {
      lg(" thread 0x%08X", (unsigned)th);
      break;
    }
    int ok;
    if (use_epoll) {
      SceNetEpollEvent evs[4];
      memset(evs, 0, sizeof evs);
      ok = sceNetEpollWait(ep, evs, 4, 5 * 1000 * 1000) > 0;
    } else {
      char drain[8];
      ok = sceNetRecv(g_snpair[0], drain, sizeof drain, 0) > 0;
    }
    report_sample(now_us(), ok);
    if (use_epoll) {
      char drain[8];
      sceNetRecv(g_snpair[0], drain, sizeof drain, 0);
    }
    end_notifier(th);
  }
  lg(" ms\n");
  if (ep >= 0) {
    sceNetEpollDestroy(ep);
  }
}

static void flag_readiness(const char* label, int delay_ms) {
  lg("%-14s", label);
  g_flag = sceKernelCreateEventFlag("t1-flag", 0, 0, NULL);
  if (g_flag < 0) {
    lg(" create failed 0x%08X\n", (unsigned)g_flag);
    return;
  }
  for (int r = 0; r < 5; r++) {
    sceKernelClearEventFlag(g_flag, ~FLAG_BIT);
    g_wrote_us = 0;
    g_notify_delay_ms = delay_ms;
    const SceUID th = sceKernelCreateThread("t1-flagnotify", flag_notifier,
                                            0x40, 0x4000, 0, 0, NULL);
    if (th < 0) {
      lg(" thread 0x%08X", (unsigned)th);
      break;
    }
    sceKernelStartThread(th, 0, NULL);
    unsigned int out = 0;
    SceUInt timeout = 5 * 1000 * 1000;
    const int rc = sceKernelWaitEventFlag(g_flag, FLAG_BIT, SCE_EVENT_WAITOR,
                                          &out, &timeout);
    report_sample(now_us(), rc >= 0);
    end_notifier(th);
  }
  lg(" ms\n");
  sceKernelDeleteEventFlag(g_flag);
  g_flag = -1;
}

// --- J/K: what a cross-thread round trip costs -------------------------------
//
// Dart's thread pool -- and so every _IOService._dispatch, which is how dart:io
// runs an async file call *and* every TLS filter cycle -- parks its workers on
// a pthread condition variable, because runtime/platform/synchronization.h maps
// MutexImpl and ConditionVariableImpl straight onto pthread_mutex_t and
// pthread_cond_t. That was the obvious mapping and nobody had priced it here.
//
// It is worth pricing because this console has already surprised us twice on
// exactly this axis: loopback delivery runs on a ~200 ms tick (see E and H
// above) while an event flag lands in 0.03 ms (I). If the condvar sits nearer
// the first number than the second, then every async dart:io call on this port
// is paying it twice -- once to wake the worker, once to wake the isolate.
//
// Measured on hardware: an `await file.length()` costs 5823 us where the same
// call made synchronously costs 780 us, and 1 MB of HTTPS takes 7.9 s against
// plain HTTP's 0.6 s over the same socket. Both are round-trip bound, and this
// is the round trip.
//
// A ping-pong rather than a one-shot, because the one-shot measures thread
// startup along with the wake, and it is the steady-state cost that is being
// paid hundreds of times per megabyte.

#define PP_ITERS 200

static pthread_mutex_t g_pp_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pp_cond_main = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_pp_cond_work = PTHREAD_COND_INITIALIZER;
static int g_pp_turn;  // 0 = main runs next, 1 = worker runs next

static void* pp_worker(void* arg) {
  (void)arg;
  for (int i = 0; i < PP_ITERS; i++) {
    pthread_mutex_lock(&g_pp_mutex);
    while (g_pp_turn != 1) {
      pthread_cond_wait(&g_pp_cond_work, &g_pp_mutex);
    }
    g_pp_turn = 0;
    pthread_cond_signal(&g_pp_cond_main);
    pthread_mutex_unlock(&g_pp_mutex);
  }
  return NULL;
}

static int64_t condvar_pingpong(void) {
  g_pp_turn = 0;
  pthread_t th;
  if (pthread_create(&th, NULL, pp_worker, NULL) != 0) {
    return -1;
  }
  const int64_t t0 = now_us();
  for (int i = 0; i < PP_ITERS; i++) {
    pthread_mutex_lock(&g_pp_mutex);
    g_pp_turn = 1;
    pthread_cond_signal(&g_pp_cond_work);
    while (g_pp_turn != 0) {
      pthread_cond_wait(&g_pp_cond_main, &g_pp_mutex);
    }
    pthread_mutex_unlock(&g_pp_mutex);
  }
  const int64_t dt = now_us() - t0;
  pthread_join(th, NULL);
  return dt / PP_ITERS;
}

static SceUID g_pp_flag_main = -1;
static SceUID g_pp_flag_work = -1;

static int pp_flag_worker(SceSize args, void* argp) {
  (void)args;
  (void)argp;
  for (int i = 0; i < PP_ITERS; i++) {
    unsigned int out = 0;
    SceUInt timeout = 5 * 1000 * 1000;
    sceKernelWaitEventFlag(g_pp_flag_work, FLAG_BIT,
                           SCE_EVENT_WAITOR | SCE_EVENT_WAITCLEAR, &out,
                           &timeout);
    sceKernelSetEventFlag(g_pp_flag_main, FLAG_BIT);
  }
  return 0;
}

static int64_t flag_pingpong(void) {
  g_pp_flag_main = sceKernelCreateEventFlag("t1-pp-main", 0, 0, NULL);
  g_pp_flag_work = sceKernelCreateEventFlag("t1-pp-work", 0, 0, NULL);
  if (g_pp_flag_main < 0 || g_pp_flag_work < 0) {
    return -1;
  }
  const SceUID th = sceKernelCreateThread("t1-pp-flag", pp_flag_worker, 0x40,
                                          0x4000, 0, 0, NULL);
  if (th < 0) {
    return -1;
  }
  sceKernelStartThread(th, 0, NULL);
  const int64_t t0 = now_us();
  for (int i = 0; i < PP_ITERS; i++) {
    sceKernelSetEventFlag(g_pp_flag_work, FLAG_BIT);
    unsigned int out = 0;
    SceUInt timeout = 5 * 1000 * 1000;
    sceKernelWaitEventFlag(g_pp_flag_main, FLAG_BIT,
                           SCE_EVENT_WAITOR | SCE_EVENT_WAITCLEAR, &out,
                           &timeout);
  }
  const int64_t dt = now_us() - t0;
  sceKernelWaitThreadEnd(th, NULL, NULL);
  sceKernelDeleteThread(th);
  sceKernelDeleteEventFlag(g_pp_flag_main);
  sceKernelDeleteEventFlag(g_pp_flag_work);
  g_pp_flag_main = g_pp_flag_work = -1;
  return dt / PP_ITERS;
}

// --- L: what an idle poll() loop costs the thread beside it -------------------
//
// Written while a Dart app holding one socket was paying seven times as much
// for every async gap as one holding none: 200 sequential Timer(Duration.zero)
// round trips cost 517 us each with no socket open and 3731 us each with one.
// The answer turned out to be a POLLOUT storm from socket_patch.dart's event
// mask, and this section is how the platform was cleared on the way there.
// Nothing on the timer path accounted for it. A zero-duration timer posts _ZERO_EVENT to the isolate's own
// port and never reaches the platform, so the event handler does not deliver
// it, and instrumenting the event handler's timer queue during the slow case
// printed nothing at all.
//
// What a socket does change is what the event handler's *thread* is doing. With
// none registered it parks on an event flag indefinitely. With one it wakes
// every kInterruptSliceUs -- 8 ms -- rebuilds its pollfd array, calls poll(),
// and sleeps again. So: can a neighbour thread waking on an 8 ms cadence cost
// another thread milliseconds per wake? That is not a question about Dart and
// does not need Dart to answer it.
//
// 3731 us is also close to half of 8 ms, which is the mean wait for a uniformly
// distributed next tick. The earlier attempt to test that moved
// kInterruptSliceUs to 1 ms, saw 3691 us, and cleared the slice. A 1% move is
// not what cutting the slice eightfold should produce, and this session had
// already caught one stale engine shipping under a fresh label, so the slice
// was asked again here, in a binary small enough to be certain of. It was
// innocent: 39 and 60 us in every case, at every slice. The cost was never on
// this side of the port.
//
// Four backgrounds against the same two round trips:
//
//   L0  nothing            the control, and the same number J and K reported
//   L1  a thread sleeping  any thread on a cadence, with no poll and no network
//       on the cadence     stack anywhere near it
//   L2  a thread in poll   the event handler, reproduced
//   L3  L2 at other        does the cost follow the slice? Half the slice means
//       slices             the mechanism is "wait for the next tick", and the
//                          fix is four characters in eventhandler_vita.cc
//
// Both round trips, because Dart pays both: the VM thread pool parks its
// workers on a condvar, and the message loop wakes on an event flag.
//
// The core mask and priority of every thread involved get printed too. Nothing
// in this port has ever set an affinity, which means every thread inherits one
// mask, and if that mask is a single core then a neighbour on a cadence is not
// a neighbour at all -- it is the same CPU.

static volatile int g_bg_stop;
static volatile long g_bg_wakeups;
static volatile int g_bg_affinity;
static volatile int g_bg_prio;
static int g_bg_slice_ms;
static int g_bg_poll;  // 1 = poll() on an idle socket, 0 = sceKernelDelayThread
static int g_bg_pair[2] = {-1, -1};

static void* bg_worker(void* arg) {
  (void)arg;
  g_bg_affinity = sceKernelGetThreadCpuAffinityMask(sceKernelGetThreadId());
  g_bg_prio = sceKernelGetThreadCurrentPriority();
  while (!g_bg_stop) {
    if (g_bg_poll) {
      struct pollfd pfd;
      pfd.fd = g_bg_pair[0];
      pfd.events = POLLIN;
      pfd.revents = 0;
      poll(&pfd, 1, g_bg_slice_ms);
    } else {
      sceKernelDelayThread((SceUInt)g_bg_slice_ms * 1000);
    }
    g_bg_wakeups++;
  }
  return NULL;
}

// A pthread, not a sceKernel thread, because that is what dart:io's event
// handler is: Thread::Start goes to thread_linux.cc, which VitaSDK maps onto
// pthread-embedded. Priority and stack come out wherever that puts them, which
// is the point.
static void background_case(const char* label, int use_poll, int slice_ms) {
  pthread_t th;
  int running = 0;
  g_bg_stop = 0;
  g_bg_wakeups = 0;
  g_bg_affinity = 0;
  g_bg_prio = 0;
  g_bg_poll = use_poll;
  g_bg_slice_ms = slice_ms;
  if (slice_ms > 0) {
    if (pthread_create(&th, NULL, bg_worker, NULL) != 0) {
      lg("%-14s pthread_create failed\n", label);
      return;
    }
    running = 1;
    sceKernelDelayThread(50 * 1000);  // let it settle into its cadence
  }
  const int64_t flag_us = flag_pingpong();
  const int64_t cond_us = condvar_pingpong();
  g_bg_stop = 1;
  if (running) {
    pthread_join(th, NULL);
  }
  lg("%-14s flag %6lld us   condvar %6lld us", label, (long long)flag_us,
     (long long)cond_us);
  if (running) {
    // The wakeup count is the honesty check on the background thread. A poll()
    // that returns immediately instead of waiting out its slice shows up here
    // as a count far above the round-trip time divided by the slice, and would
    // mean L2 measured a spin rather than a cadence.
    lg("   %ld wakeups, core 0x%05X, prio %d", g_bg_wakeups,
       (unsigned)g_bg_affinity, g_bg_prio);
  }
  lg("\n");
}

static void background_section(void) {
  lg("\nL: a neighbour thread on a cadence, %d round trips each\n\n", PP_ITERS);
  lg("this thread: core 0x%05X, prio %d\n\n",
     (unsigned)sceKernelGetThreadCpuAffinityMask(sceKernelGetThreadId()),
     sceKernelGetThreadCurrentPriority());

  // Its own pair rather than g_pair, which E and G have been writing to. A
  // leftover unread byte would make every poll() return at once and quietly
  // turn L2 into a spin test.
  if (socketpair(AF_INET, SOCK_STREAM, 0, g_bg_pair) < 0) {
    g_bg_pair[0] = g_bg_pair[1] = -1;
  }

  background_case("L0 nothing", 0, 0);
  background_case("L1 delay 8ms", 0, 8);
  if (g_bg_pair[0] >= 0) {
    background_case("L2 poll 8ms", 1, 8);
    background_case("L3 poll 1ms", 1, 1);
    background_case("L3 poll 33ms", 1, 33);
    close(g_bg_pair[0]);
    close(g_bg_pair[1]);
    g_bg_pair[0] = g_bg_pair[1] = -1;
  } else {
    lg("no socketpair -- L2 and L3 skipped\n");
  }
}

// --- handoff -----------------------------------------------------------------

static void handoff(void) {
  char titleid[16] = "FVTA00004";
  const SceUID fd =
      sceIoOpen("ux0:data/flutter-vita/loader.titleid", SCE_O_RDONLY, 0777);
  if (fd >= 0) {
    char buf[32] = {0};
    const int n = sceIoRead(fd, buf, sizeof buf - 1);
    sceIoClose(fd);
    for (int i = 0; i < n; i++) {
      if (buf[i] == '\n' || buf[i] == '\r' || buf[i] == ' ') {
        buf[i] = '\0';
        break;
      }
    }
    if (buf[0] != '\0') {
      snprintf(titleid, sizeof titleid, "%s", buf);
    }
  }
  lg("\nhanding off to %s\n", titleid);
  if (g_log >= 0) {
    sceIoClose(g_log);
    g_log = -1;
  }
  sceKernelDelayThread(1500 * 1000);
  char uri[64];
  snprintf(uri, sizeof uri, "psgm:play?titleid=%s", titleid);
  sceAppMgrLaunchAppByUri(0xFFFFF, uri);
  sceKernelExitProcess(0);
}

int main(void) {
  psvDebugScreenInit();
  sceIoMkdir("ux0:data", 0777);
  sceIoMkdir("ux0:data/flutter-vita", 0777);
  g_log = sceIoOpen("ux0:data/flutter-vita/t1.log",
                    SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);

  // The same clocks the engine runs at, so a number here means the same thing
  // it would mean in an app.
  scePowerSetArmClockFrequency(444);
  scePowerSetBusClockFrequency(222);

  lg("T1: what a wait costs\n\n");

  if (sceSysmoduleLoadModule(SCE_SYSMODULE_NET) < 0) {
    lg("SCE_SYSMODULE_NET failed to load -- nothing below can run\n");
    handoff();
    return 1;
  }
  SceNetInitParam np;
  np.memory = g_net_pool;
  np.size = sizeof g_net_pool;
  np.flags = 0;
  const int ni = sceNetInit(&np);
  if (ni < 0 && ni != (int)0x80410103 /* EBUSY */) {
    lg("sceNetInit failed: 0x%08X\n", (unsigned)ni);
    handoff();
    return 1;
  }
  sceNetCtlInit();

  if (socketpair(AF_INET, SOCK_STREAM, 0, g_pair) < 0) {
    lg("socketpair failed -- C and E cannot run\n");
    g_pair[0] = g_pair[1] = -1;
  }

  if (make_scenet_pair() < 0) {
    lg("sceNet loopback pair failed -- H cannot run\n");
  }

  const int udp = sceNetSocket("t1-udp", SCE_NET_AF_INET, SCE_NET_SOCK_DGRAM, 0);
  g_epoll = sceNetEpollCreate("t1-epoll", 0);
  if (udp >= 0 && g_epoll >= 0) {
    SceNetEpollEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.events = SCE_NET_EPOLLIN;
    ev.data.fd = udp;
    sceNetEpollControl(g_epoll, SCE_NET_EPOLL_CTL_ADD, udp, &ev);
  } else {
    lg("epoll setup failed (udp=0x%08X epoll=0x%08X) -- D skipped\n",
       (unsigned)udp, (unsigned)g_epoll);
  }

  lg("mean of %d, milliseconds, requested->actual\n\n", REPS);
  row("A delay", wait_delaythread);
  row("B poll n=0", wait_poll_empty);
  if (g_pair[0] >= 0) {
    row("C poll n=1", wait_poll_one);
  }
  if (g_epoll >= 0) {
    row("D epollwait", wait_epoll);
  }
  row("F create+del", wait_create_destroy);

  lg("\nlatency from the write to the wait returning, 5 samples, ms\n\n");
  if (g_pair[0] >= 0) {
    // Three write times against one wait. If the answer tracks the write, the
    // notification costs ~100 ms; if it tracks the start of the wait, the wait
    // is re-checking on a grid and the number will fall as the write moves
    // later.
    readiness("E poll w=50", -1, 50);
    readiness("E poll w=100", -1, 100);
    readiness("E poll w=150", -1, 150);
    blocking_recv("G recv w=100", 100);
  }
  if (g_snpair[0] >= 0) {
    scenet_readiness("H epoll w=100", 100, 1);
    scenet_readiness("H recv w=100", 100, 0);
  } else {
    lg("no sceNet pair -- H skipped\n");
  }
  flag_readiness("I flag w=100", 100);

  lg("\ncross-thread round trip, %d iterations\n\n", PP_ITERS);
  lg("J condvar     %lld us each\n", (long long)condvar_pingpong());
  lg("K flag        %lld us each\n", (long long)flag_pingpong());

  background_section();

  lg("\ndone\n");
  handoff();
  return 0;
}
