// A gallery with the benchmark and nothing else, for measuring the shell.
//
// Build it with:
//
//   ./tools/build-vita-app.sh samples/gallery \
//       --entry-point lib/bench_only.dart --title-id FVTA00002
//
// `main.dart` puts a running scene inside a Column under a strip and a
// Navigator, in a Stack whose other child is an IndexedStack of eight tabs
// behind an Offstage. On 2026-09-14 a scene owned the screen, and every small
// scene built about twice as fast as it does now
// ([the record](../../../docs/results/gallery-ui-thread-2026-09-23.md)).
//
// This entry point keeps the part that cannot go -- BenchPage stays mounted,
// because a State unmounted mid-run cannot make the next AnimationController
// -- and drops everything else. The difference between this and `main.dart`
// on the same scene is what the shell costs.
//
// It is a measuring instrument, not a product. Nothing ships it.
import 'package:flutter/material.dart';

import 'bench/bench_page.dart';
import 'bench/runner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  print('bench_only: the shell is one Stack');
  FlutterError.onError = (details) {
    print('bench_only: FlutterError ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  runApp(const _BenchOnlyApp());
}

class _BenchOnlyApp extends StatelessWidget {
  const _BenchOnlyApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        // The same theme as main.dart. A different one would change what the
        // scenes paint, and then the two builds would not compare.
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF4C8DFF),
          scaffoldBackgroundColor: const Color(0xFF10131A),
        ),
        home: const _Root(),
      );
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with TickerProviderStateMixin {
  final ValueNotifier<Widget?> _stage = ValueNotifier<Widget?>(null);
  final ValueNotifier<String?> _scene = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _stage.dispose();
    _scene.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ValueListenableBuilder<Widget?>(
            valueListenable: _stage,
            builder: (context, stage, bench) => Stack(
              fit: StackFit.expand,
              children: [
                Offstage(offstage: stage != null, child: bench),
                if (stage != null)
                  Material(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: stage,
                  ),
              ],
            ),
            child: BenchPage(
              stage: _stage,
              scene: _scene,
              vsync: this,
              autoRun: switchOn(kSwitchPath),
            ),
          ),
        ),
      );
}
