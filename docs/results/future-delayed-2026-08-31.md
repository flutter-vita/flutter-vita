# Future.delayed(1 ms) costs 2.4 ms, and upstream Dart asked for that

The last unexplained number from the POLLOUT work. Once a zero-duration timer
came down to 217 us with eight sockets open, `Future.delayed(1 ms)` stood out at
2,524 us and nothing accounted for the gap.

It is not a Vita defect. Stock `timer_impl.dart` adds a millisecond to every
non-zero timer, on every platform, on purpose.

## The ladder

Six durations, 50 iterations each, from the conformance app:

| asked | measured | excess |
|------:|---------:|-------:|
| 0 ms | 217 us | +217 |
| 1 ms | 2,455 us | +1,455 |
| 2 ms | 3,328 us | +1,328 |
| 4 ms | 5,686 us | +1,686 |
| 8 ms | 9,350 us | +1,350 |
| 16 ms | 17,386 us | +1,386 |

The shape is the whole answer. A flat surcharge of about 1.4 ms on every
non-zero duration rules out both of the other candidates before any code is
read: a granularity floor would put 1 ms and 2 ms on the same number, and
arithmetic that scaled wrongly would show the excess growing with the duration.
Neither does. Something adds a constant.

Two more probes narrow it further:

| probe | mean |
|-------|-----:|
| `Future.delayed(1ms) x200` | 2,531 us |
| `Timer(1ms) x200` | 2,578 us |
| `Future.delayed(0) x200` | 363 us |
| `Timer(0) x200` | 331 us |

`Future.delayed` and a bare `Timer` agree to within noise at both durations, so
the Completer and Future that `Future.delayed` allocates cost about 30 us and
are not it. The surcharge belongs to the timer path.

## What it was not

**The wait.** `experiments/t1-timers` section M measures the primitive dart:io's
event handler blocks on when no socket is registered:

    M waitflag   1->1.0  8->8.0  16->16.0  33->33.0  100->100.0

`sceKernelWaitEventFlag` with a microsecond timeout is exact to the tenth of a
millisecond the table prints, and more accurate than `sceKernelDelayThread`,
which section A has at `1->1.2`. Nothing to reclaim there.

**The wait primitive in general.** With a socket open the handler waits in
`poll()` sliced at 8 ms instead, an entirely different mechanism, and
`Future.delayed(1ms), TCP open` measures 2,389 us. The same surcharge under a
different wait is not a property of either wait.

**The cross-thread hop.** Section K puts an event-flag round trip between two
threads at 39 us, and section I puts a flag wake at 0.03 ms. The registration
path is an in-memory queue under a mutex plus `sceKernelSetEventFlag`; it is not
the socketpair whose ~97 ms readiness latency section E measures, and has not
been since the Vita backend was written.

## What it is

`sdk/lib/_internal/vm/lib/timer_impl.dart`, unpatched, identical in both Dart
trees:

```dart
// Add one because DateTime.now() is assumed to round down
// to nearest millisecond, not up, so that time + duration is before
// duration milliseconds from now. Using microsecond timers like
// Stopwatch allows detecting that the timer fires early.
int now = VMLibraryHooks.timerMillisecondClock();
int wakeupTime = (milliSeconds == 0) ? now : (now + 1 + milliSeconds);
```

Every non-zero timer is armed for one millisecond later than it asked for, as an
upstream guard against firing early on a clock that truncates. Zero is special
cased and pays nothing, which is why `Timer(0)` at 217 us looked like the
baseline it is not.

On top of that, `TimerUtils::GetCurrentMonotonicMillis()` truncates microseconds
to milliseconds, and both the deadline and the handler's `millis = deadline -
now` are computed from it. That adds a uniform 0 to 1 ms. The remaining ~200 us
is the round trip, which `Timer(0)` measures directly.

    1 (upstream) + 0..1 (truncation) + 0.2 (round trip) = 1.2 to 2.2 ms

against a measured 1.33 to 1.69 across the ladder. The two truncations partly
cancel, which is why the middle of that range is where every rung lands.

The distribution says the same thing without any model. `Future.delayed(1ms)
x200` reports p50 2,319 and p90 2,741 -- an excess spanning roughly 1.0 to 1.7
ms, which is one fixed millisecond plus a sub-millisecond spread, and not
anything with a tail.

## So

Nothing to fix here, and the reason to write it down is that it looks like
something to fix. A Flutter app on this console pays the same millisecond a
Flutter app on Linux pays. `Timer(Duration.zero)` is the only timer that
bypasses the event handler entirely, so it is the wrong baseline to compare
anything against -- which is what made this look like a Vita problem for a week.

Closed. The port's timer path is now accounted for end to end:

- a zero-duration timer, 217 us, isolate-local
- a non-zero timer, its duration plus ~1.4 ms, of which 1 ms is upstream's
- the event handler's wait, exact
- and the storm that used to sit on top of all of it, fixed in 838e65b
