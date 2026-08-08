// M1 — pure-Dart AOT hello world for the Vita.
//
// Deliberately returns a checksum instead of printing. In the VM, `print` is
// routed through `_printClosure` in dart:_internal, which defaults to
// `_unsupportedPrint` and *throws* until an embedder installs one --
// runtime/bin does that, and this port excludes runtime/bin. So a printing
// hello world would throw on its first statement, with no working output to
// explain why.
//
// A checksum needs no plumbing at all: the C harness reads it back through
// Dart_Invoke + Dart_IntegerToInt64 and prints it with the debug-screen path
// Track A already proved. Getting 6830 means the VM initialised, loaded the
// snapshot out of a VM domain block, allocated, ran the GC, and executed real
// Dart. Print wiring can follow once something is known to run.
//
// Also deliberately not trivial: a bare `return 42` would tree-shake to almost
// nothing and prove very little.

import 'dart:ffi';
import 'dart:isolate';

// The embedder shim. It lives in the root library because that is the library
// the harness can name without knowing a file URI -- Dart_SetFfiNativeResolver
// is per-library, and the snapshot bakes in absolute host paths for everything
// else. In a real embedder this belongs in its own library, alongside the timer
// hooks; see docs/embedder-startup.md.
//
// FFI natives, not Dart_SetNativeResolver: that resolver runs at snapshot time
// and we use a stock gen_snapshot. Dart_SetFfiNativeResolver is a runtime call
// and works in AOT. The SDK uses this same Handle-passing shape itself, e.g.
// @Native<Void Function(Handle)> in concurrent_patch.dart.
@Native<Void Function(Handle)>(symbol: 'vita_dart_print')
external void _vitaPrint(Object line);

/// Handed to `dart:_internal._printClosure` by the harness, which is what
/// `print()` dispatches through. Until an embedder sets it, print throws.
@pragma('vm:entry-point')
void Function(String) getPrintClosure() => (String line) => _vitaPrint(line);

// The timer hooks. dart:isolate already contains the whole timer scheduler
// (timer_impl.dart is `part` of isolate_patch.dart), so nothing here implements
// timers -- these only supply the two platform primitives it is missing.
// See docs/embedder-startup.md.

@Native<Int64 Function()>(symbol: 'vita_monotonic_ms')
external int _vitaMonotonicMs();

@Native<Void Function(Handle, Int64)>(symbol: 'vita_schedule_wakeup')
external void _vitaScheduleWakeup(Object sendPort, int wakeupTime);

/// For `VMLibraryHooks.timerMillisecondClock`. Must share an epoch with the
/// `wakeupTime` values handed to the hook below -- `_Timer` computes one from
/// the other.
@pragma('vm:entry-point')
int Function() getTimerClock() => () => _vitaMonotonicMs();

/// For `VMLibraryHooks.eventHandlerSendData`. `_Timer` calls this to ask the
/// platform to wake the isolate at [wakeupTime], or to cancel with -1
/// (`_NO_TIMER`). Zero-duration timers never reach here -- dart:isolate handles
/// those itself by posting `_ZERO_EVENT` straight to its own port.
@pragma('vm:entry-point')
void Function(Object?, SendPort, int) getEventHandlerSendData() =>
    (Object? sender, SendPort port, int wakeupTime) =>
        _vitaScheduleWakeup(port, wakeupTime);

int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

/// Set by the async path below; read by the harness *after* Dart_RunLoop.
/// Stays 0 if the microtask queue never drains — which is exactly the failure
/// a hand-written condvar and timer layer is most likely to produce.
int _asyncMarker = 0;

@pragma('vm:entry-point')
int asyncMarker() => _asyncMarker;

/// Set by a real (non-zero) timer, so it only becomes 42 if the whole
/// timerFactory -> _Timer -> eventHandlerSendData -> Dart_PostCObject ->
/// message loop round trip works. A zero-duration delay would not test it:
/// dart:isolate short-circuits those without ever calling the platform hook.
int _delayedMarker = 0;

@pragma('vm:entry-point')
int delayedMarker() => _delayedMarker;

@pragma('vm:entry-point')
int main() {
  // First real output from Dart on this device. Until now every failure past
  // Dart_Invoke surfaced as a wrong number.
  print('hello from Dart, running AOT on a PlayStation Vita');

  // Recursion: ~13k calls, so stack handling and GetCurrentStackBounds.
  final f = fib(20); // 6765

  // Heap allocation and iteration: the GC and virtual_memory_vita.cc.
  final squares = <int>[for (var i = 1; i <= 5; i++) i * i];
  final sumSquares = squares.reduce((a, b) => a + b); // 55

  // Strings, hashing, map growth: more allocation churn.
  final counts = <String, int>{};
  for (final word in 'the quick brown fox the lazy dog the end'.split(' ')) {
    counts[word] = (counts[word] ?? 0) + 1;
  }
  final unique = counts.length; // 7
  final the = counts['the']!; // 3

  // Microtask queue. Completes during Dart_RunLoop, not here.
  //
  // Was Future.delayed(Duration.zero), which is a *timer*, not a microtask --
  // it goes through VMLibraryHooks.timerFactory and threw "Timer interface not
  // supported" because no embedder installs one. Future.microtask goes through
  // _ScheduleImmediate._closure instead, which the harness now installs.
  // Timers remain unimplemented and are tracked separately; Flutter will need
  // them, a microtask smoke test does not.
  Future<void>.microtask(() => _asyncMarker = 99);

  // A real timer, 50 ms out, so the platform hook is genuinely exercised.
  Future<void>.delayed(const Duration(milliseconds: 50),
      () => _delayedMarker = 42);

  // 6765 + 55 + 7 + 3 = 6830. A wrong total localises the failure: too small by
  // ~6765 implicates recursion, by 55 the list, and so on.
  return f + sumSquares + unique + the;
}
