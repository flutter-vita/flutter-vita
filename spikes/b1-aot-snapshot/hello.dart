// Phase 0.5 / B1 — pure-Dart AOT hello world.
//
// Deliberately NOT trivial: a bare `print` can be tree-shaken down to almost
// nothing, which would make the instructions-section measurement meaningless.
// This touches enough of the core libraries to produce a realistic floor for
// "smallest useful Dart program" on armv7.

int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);

void main() {
  print('hello from dart aot on armv7');

  final squares = <int>[for (var i = 1; i <= 5; i++) i * i];
  print('squares: $squares');

  final counts = <String, int>{};
  for (final word in 'the quick brown fox the lazy dog the end'.split(' ')) {
    counts[word] = (counts[word] ?? 0) + 1;
  }
  print('counts: $counts');

  print('fib(20) = ${fib(20)}');

  // Exercise the async machinery — the scheduler and microtask queue are among
  // the first things that will break on a hand-written Vita platform layer.
  Future<void>.delayed(Duration.zero, () => print('async tick ok'));
}
