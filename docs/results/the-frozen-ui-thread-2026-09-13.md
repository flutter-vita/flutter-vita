# The frozen UI thread: a lost wakeup on the marker barrier

**Question:** about every other benchmark run stopped inside a scene, on
vitaGL and on fvita_gles2 alike, with the screen still, the app answering
on 1339, and all four cores idle. The user had seen the same freeze on
vitaGL before the new layer existed. What stops?

## How the answer was got

Three things had to exist first, and they are now part of every dev build:

1. **A heartbeat through the UI thread.** The platform loop sends a method
   call on `flutter/navigation` once a second with a response handle. The
   framework answers an unknown method with null. The reply is a task back
   on the platform thread, so it depends on neither a frame nor a dart:io
   timer. Every stall report prints the reply age; no reply for 300 ms
   makes a `SLOW` report, for 20 s a `WATCHDOG` report into
   `ux0:data/flutter-vita/stall.txt`, twice, and at 30 s the app copies its
   log to `stall.log` and relaunches itself.
2. **Wait notes.** `templates/vita-app/waits.c` wraps the blocking kernel
   calls, `dart::ConditionVariable::WaitMicros`/`Wait` and
   `std::condition_variable::wait` at link time. Each records its caller and
   its stack pointer, nested, so the report can say `in dart-monitor
   0x82EDED8C from <VM function> > sema 0x401805C1 from pte` and scan the
   stack from a pointer that is live by construction. Without them the scan
   started 32 KB below the stack top and printed FreeType frames the UI
   thread had run minutes earlier.
3. **The bench resumes.** `bench-scene` and `bench-partial.json` let a
   relaunched gallery skip what it measured, mark the scene it died in as
   `interrupted`, and finish. bench.sh prints the scene as it changes,
   pulls the two files, and resolves the frames against the ELF it built.

The kernel's own way to read another thread's registers,
`sceKernelGetThreadContextForVM`, refuses from a user process (0x8002710B
through the SceLibKernel wrapper, 0x80020008 through the syscall, with and
without `sceKernelSuspendThreadForVM`). It is left in the report as the line
`regs refused`.

## What the report said

Build 20, fvita_gles2, scene `switch_fade`, 20 s after the last heartbeat
reply:

```
thr io.flutter.ui   wait sema 0x401805C1 ran 4%
  in (20909 ms) dart-monitor 0x82EDED8C from 81968C2B > sema 0x401805C1
  from 81968C2B  dart::ParallelMarkTask::RunEnteredIsolateGroup
thr pthread 0x401905D3  wait sema 0x401805C1 ran 4%
  in (20910 ms) dart-monitor 0x82EDED8C from 81968BEB > sema 0x401805C1
  from 81968BEB  dart::ParallelMarkTask::RunEnteredIsolateGroup
```

Two threads, the UI thread and a pool worker, parked on the same monitor
inside the parallel marker, at two different `barrier_->Sync()` calls 64
bytes apart. `ThreadBarrier::Sync` is a generation counter: the last thread
to arrive advances it and calls `NotifyAll`, the others loop on `Wait()`
until it moves. For the worker to be at the next `Sync`, the generation had
moved. For the UI thread to still be at the previous one, the broadcast had
not woken it. That is a lost wakeup in the condition variable, and the
barrier is the tightest user of broadcast in the VM.

The 4% each thread "ran" while parked is not the deadlock. pthreads-embedded
implements a blocked semaphore as a poll: `pte_osSemaphoreCancellablePend`
waits 500 µs, checks the cancel flag, waits again. Every parked pthread
wakes two thousand times a second. The `wait #` counters in the report
climbed by the same 8774 on all four parked threads between two samples five
seconds apart.

## The fix

`runtime/platform/synchronization_vita.cc` (Dart patch 0003, with 0002 and
0009 rerouted): `dart::Mutex` is a `SceKernelLwMutex`, `dart::ConditionVariable`
a `SceKernelLwCond` created against that mutex on its first wait. An
uncontended lock is an atomic in user memory; a broadcast is
`sceKernelSignalLwCondAll`, a kernel operation over the wait queue rather
than a protocol between threads. Dart's threads no longer go through pte for
their monitors at all, and no longer poll.

`std::condition_variable` in the engine (fml's `ConcurrentMessageLoop`, two
workers, and anything in Skia that blocks) still goes through pte and still
polls. That is the next item, not this one.

## After

Four full gallery runs on the kernel objects (builds 21 to 23, fvita_gles2)
and one on vitaGL: no scene interrupted, no `WATCHDOG` report. Before the
fix, three of the previous five runs had frozen.

The cost of the wrappers showed up on the way: builds 18 to 22 noted every
mutex lock, contended or not, and the UI thread's summed build time over the
suite went from 250 ms to 420 to 457 ms. A lightweight mutex is now tried
first and only a refused try is recorded; kernel mutexes are not wrapped.
Build 23 against build 14, the last one before any of this, fvita_gles2,
36 scenes:

| | build 14 | build 23 |
|---|---|---|
| worst-frame sum, ms | 3167 | 3033 |
| stall sum, ms | 9067 | 7650 |
| heaviest-build sum, ms | 2095 | 1503 |
| UI thread build sum, ms | 249.8 | 255.7 |
| raster sum, ms | 233.0 | 211.5 |

Same build, vitaGL: worst 3567, stall 11267, heaviest build 1625, raster
216.4. That pair is the parity table's fourth section.

## What this settles

- The freeze the user saw on vitaGL and on fvita_gles2 was the Dart runtime
  port's condition variable, under both. Neither GL layer was involved.
- Every parked pthread on this platform costs a syscall every 500 µs. Dart's
  threads are out of that now; fml's two `ConcurrentMessageLoop` workers and
  whatever else sleeps in `std::condition_variable` are still in it.
- A freeze from here on writes its own report and gets out of the way. The
  bench finishes with the scene marked, and `tools/diag.sh --resolve` turns
  the report into names.
