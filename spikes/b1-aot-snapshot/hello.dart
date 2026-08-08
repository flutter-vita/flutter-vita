// M1 — pure-Dart AOT hello world for the Vita.
//
// Returns a checksum rather than relying only on output. Getting 6830 means the
// VM initialised, read the snapshot, allocated, ran the GC, and executed real
// Dart, and it says so even if nothing can print. A wrong total localises the
// failure: short by ~6765 implicates recursion, by 55 the list, and so on.
//
// It does print as well now -- `dart:vita` supplies the closure that
// `dart:_internal._printClosure` wants, so `print()` no longer throws. The
// checksum stays because it is the more precise signal of the two.
//
// Deliberately not trivial: a bare `return 42` would tree-shake to almost
// nothing and prove very little.
//
// No embedder shim here any more. It lives in `dart:vita`, which the harness
// can name outright; see docs/embedder-startup.md.

int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

/// Set by the microtask below; read by the harness *after* the queue drains.
/// Stays 0 if it never does.
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

  // Microtask queue. Completes during the drain, not here.
  Future<void>.microtask(() => _asyncMarker = 99);

  // A real timer, 50 ms out, so the platform hook is genuinely exercised.
  Future<void>.delayed(
      const Duration(milliseconds: 50), () => _delayedMarker = 42);

  return f + sumSquares + unique + the; // 6830
}
