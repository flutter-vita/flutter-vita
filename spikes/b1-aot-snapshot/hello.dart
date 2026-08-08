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

int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

/// Set by the async path below; read by the harness *after* Dart_RunLoop.
/// Stays 0 if the microtask queue never drains — which is exactly the failure
/// a hand-written condvar and timer layer is most likely to produce.
int _asyncMarker = 0;

@pragma('vm:entry-point')
int asyncMarker() => _asyncMarker;

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

  // 6765 + 55 + 7 + 3 = 6830. A wrong total localises the failure: too small by
  // ~6765 implicates recursion, by 55 the list, and so on.
  return f + sumSquares + unique + the;
}
