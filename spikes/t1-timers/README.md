# T1 — what a wait costs

One `.vpk`, no Dart and no engine, that times the primitives dart:io's event
handler is built on. It was written to find out why **every Dart timer on this
port fired on a 200 ms grid** (see
[the localsend result](../../docs/results/localsend-gl-2026-08-25.md)), and it
refuted two hypotheses before landing on the answer.

## Build and run

```bash
./build.sh
VITA_HOST=<ip> ../../tools/deploy.sh --vpk build/flutter_vita_t1.vpk --no-launch
```

Then `launch` on the receiver. The spike runs for about five seconds, writes
`ux0:data/flutter-vita/t1.log`, and hands the console back to the receiver, so a
run costs no taps. Title ID is `FVTA00002`, the same slot every app deploys
into — installing this replaces whatever app is there, which is fine and
expected.

## What it found, 2026-08-25

**Every timeout is exact.** This is the part that ruled out the obvious
suspects: `poll()` on this SDK is `sceNetEpollCreate` + `sceNetEpollControl` +
`sceNetEpollWait` + `sceNetEpollDestroy`, all per call, and none of that costs
anything measurable.

```
mean of 5, milliseconds, requested->actual

A delay      1->1.2 8->8.1 16->16.1 33->33.2 100->100.2   sceKernelDelayThread
B poll n=0   1->1.2 8->8.2 16->16.2 33->33.1 100->100.1   poll(), nfds == 0
C poll n=1   1->1.1 8->8.1 16->16.1 33->33.1 100->100.1   poll(), one socket
D epollwait  1->1.1 8->8.1 16->16.1 33->33.1 100->100.1   persistent epoll
F create+del 0.0                                          epoll churn per call
```

**Readiness is not.** A byte written to a socketpair reaches a waiting reader
~197 ms after the wait *began*, wherever in that window the write lands — and
it makes no difference which primitive is waiting:

```
latency from the write to the wait returning, 5 samples, ms

E poll w=50    0.20 141.22 149.30 149.36 149.28   write at 50 ms  -> ~199 total
E poll w=100   98.93  99.45  99.22  99.32  99.33   write at 100 ms -> ~199 total
E poll w=150   46.34  46.66  46.68  46.67  46.69   write at 150 ms -> ~197 total
G recv w=100   92.50  96.75  96.75  96.76  96.76   blocking recv(), no poll
H epoll w=100   0.15  88.98  96.66  96.70  96.64   sceNetEpollWait, sceNet fds
H recv w=100   92.44  96.72  96.75  96.75  96.77   sceNetRecv, no newlib at all
I flag w=100    0.03   0.03   0.03   0.03   0.03   sceKernelSetEventFlag
```

Three readings fall out of that table.

1. **It is the loopback interface, not poll and not epoll.** G, H-epoll and
   H-recv are the same number to a tenth of a millisecond, and H goes through
   no newlib and no `poll()` wrapper at all. Only WiFi sockets are prompt --
   this project's own dev server answers a ping over `sceNetRecv` immediately.
2. **The grid is anchored at the start of the wait**, not at the write: moving
   the write from 50 to 150 ms moves the latency down by exactly as much, and
   the total stays at ~197. The loop then self-synchronises, which is why the
   first sample of each row is fast and every later one is not.
3. **An event flag is 3,000x faster** and is the fix. It is the same primitive
   `message_loop_vita.cc` already wakes the UI thread on sixty times a second.

The consequence for the port is in
[eventhandler_vita.cc](../../patches/dart-sdk/0010-runtime-bin-for-vita.patch):
dart:io learned "arm a timer at T" by reading a **loopback socketpair**, so
every timer registration paid one tick. `Future.delayed(33 ms)` took 200 ms,
and localsend's spinner — which asks for 30 fps in a `while (true)` loop — ran
at 5.00.

After the fix: `33 ms -> 34.2 ms`, and localsend at ~30 fps.

## Why this is a spike and not a test

It installs over whatever is in `FVTA00002` and it hands the console away when
it finishes. Keep it for the next time a wait on this console does something
inexplicable; do not put it in a loop.
