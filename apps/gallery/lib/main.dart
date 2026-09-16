import 'package:audioplayers_vita/audioplayers_vita.dart';
import 'package:battery_plus_vita/battery_plus_vita.dart';
import 'package:camera_vita/camera_vita.dart';
import 'package:connectivity_plus_vita/connectivity_plus_vita.dart';
import 'package:device_info_plus_vita/device_info_plus_vita.dart';
import 'package:flutter/material.dart';
import 'package:path_provider_vita/path_provider_vita.dart';
import 'package:record_vita/record_vita.dart';
import 'package:sensors_plus_vita/sensors_plus_vita.dart';
import 'package:shared_preferences_vita/shared_preferences_vita.dart';

import 'bench/bench_page.dart';
import 'bench/runner.dart';
import 'conformance/conformance_tab.dart';
import 'hardware/hardware_tab.dart';
import 'hud.dart';
import 'panel_page.dart';
import 'results_tab.dart';

/// Everything this port is measured with, on one panel.
///
/// Five tabs on a rail down the left, the shape the receiver has. Panel is
/// what the port looks like, judged by eye. Scenes is the benchmark of
/// ADR-0017. Conformance is the probe suite that was its own app until
/// 2026-09-14. Hardware asks each piece of the console to answer. Results
/// reads the three result files back. Above all of them, the whole width,
/// a strip with what the console is doing this second (hud.dart); it stays
/// while a scene runs.
///
/// Three switches on the card start an unattended run on one tab and the run
/// writes a result file and a done marker: bench.on, conformance.on,
/// hardware.on. tools/bench.sh writes them.
void main() {
  // A positive control for the engine's log_message_callback. Dart print had
  // no destination on this port until 2026-08-24; if this line does not appear
  // in the log, nothing else in it about Dart is complete.
  print('gallery: dart print reaches the engine log');
  FlutterError.onError = (details) {
    print('gallery: FlutterError ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  // The two non-endorsed vita implementations the conformance probes use. A
  // non-endorsed implementation is not found automatically, so the app
  // registers it: the two lines ADR-0009 asks an app author for.
  PathProviderVita.registerWith();
  SharedPreferencesVita.registerWith();
  // The Hardware tabs check the console through these; the C halves are in
  // the packages, compiled into this app by build-vita-app.sh.
  BatteryPlusVita.registerWith();
  SensorsPlusVita.registerWith();
  DeviceInfoPlusVita.registerWith();
  ConnectivityPlusVita.registerWith();
  RecordVita.registerWith();
  AudioplayersVita.registerWith();
  CameraVita.registerWith();

  final autoBench = switchOn(kSwitchPath);
  final autoConformance = !autoBench && switchOn(kConformanceSwitchPath);
  final autoHardware =
      !autoBench && !autoConformance && switchOn(kHardwareSwitchPath);
  runApp(GalleryApp(
    autoBench: autoBench,
    autoConformance: autoConformance,
    autoHardware: autoHardware,
  ));
}

class GalleryApp extends StatelessWidget {
  const GalleryApp({
    super.key,
    this.autoBench = false,
    this.autoConformance = false,
    this.autoHardware = false,
  });

  final bool autoBench;
  final bool autoConformance;
  final bool autoHardware;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF4C8DFF),
          scaffoldBackgroundColor: const Color(0xFF10131A),
        ),
        home: Shell(
          initialTab: autoBench
              ? 1
              : autoConformance
                  ? 2
                  : autoHardware
                      ? 3
                      : 0,
          autoBench: autoBench,
          autoConformance: autoConformance,
          autoHardware: autoHardware,
        ),
      );
}

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.initialTab,
    required this.autoBench,
    required this.autoConformance,
    required this.autoHardware,
  });

  final int initialTab;
  final bool autoBench;
  final bool autoConformance;
  final bool autoHardware;

  @override
  State<Shell> createState() => _ShellState();
}

const _tabNames = [
  'PANEL',
  'SCENES',
  'CONFORMANCE',
  'HARDWARE',
  'CAMERAS',
  'MANUAL',
  'RESULTS',
];

class _ShellState extends State<Shell> with TickerProviderStateMixin {
  late int _tab = widget.initialTab;

  /// hud.off on the card: a strip that does nothing, for measuring what the
  /// live one costs. Read once; the switch is the host's.
  static final bool _hudFrozen = switchOn('$kDataDir/hud.off');

  /// The benchmark scene being measured, or null. While one is mounted it
  /// takes the content area: the rail goes, the strip stays. The tabs stay
  /// in the tree behind it (Offstage, so they cost no layout and no paint):
  /// the Scenes tab owns the run, and a State that is unmounted mid-run
  /// cannot make the next AnimationController. Build 30 did that, and every
  /// animated scene threw "Null check operator used on a null value" from
  /// State.context.
  final ValueNotifier<Widget?> _stage = ValueNotifier<Widget?>(null);

  /// The scene's name while one runs, for the strip.
  final ValueNotifier<String?> _scene = ValueNotifier<String?>(null);

  /// The hardware checks, one suite behind three tabs.
  late final HardwareSuite _hardware =
      HardwareSuite(autoRun: widget.autoHardware);

  @override
  void dispose() {
    _stage.dispose();
    _scene.dispose();
    _hardware.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Its own layer: the strip repaints once a second and a scene
              // underneath must not be repainted with it.
              RepaintBoundary(
                child: HudStrip(
                  frozen: _hudFrozen,
                  leading: ValueListenableBuilder<String?>(
                    valueListenable: _scene,
                    builder: (context, scene, _) => _StripTitle(
                      tab: _tabNames[_tab],
                      scene: scene,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1, color: Color(0xFF262B36)),
              Expanded(
                // A Navigator of its own, so a route a scene pushes lands
                // here, under the strip, rather than over the whole screen.
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => ValueListenableBuilder<Widget?>(
                      valueListenable: _stage,
                      builder: (context, stage, tabs) => Stack(
                        fit: StackFit.expand,
                        children: [
                          Offstage(offstage: stage != null, child: tabs),
                          if (stage != null)
                            // Material, not Scaffold. ListTile and
                            // CircleAvatar reach for Material.of(context)!,
                            // which in release is a null check on nothing
                            // and takes the run down once per frame. A bare
                            // Material is one background rect; a Scaffold
                            // would add furniture the scene would then be
                            // measured painting.
                            Material(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: stage,
                            ),
                        ],
                      ),
                      child: _tabs(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _tabs() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Rail(current: _tab, onPick: (i) => setState(() => _tab = i)),
          const VerticalDivider(width: 1, color: Color(0xFF262B36)),
          Expanded(
            // Every tab stays built: a run on one keeps going while another
            // is looked at, and a result stays on its tab. IndexedStack keeps
            // the hidden tabs' animations going too (Visibility.maintain),
            // which is the panel's spinner drawing 60 frames a second behind
            // whatever is shown; TickerMode stops that. The Scenes run is
            // not affected: its controller ticks on this State's provider.
            child: IndexedStack(
              index: _tab,
              children: [
                for (var i = 0; i < _tabNames.length; i++)
                  TickerMode(enabled: i == _tab, child: _tabBody(i)),
              ],
            ),
          ),
        ],
      );

  Widget _tabBody(int i) => switch (i) {
        0 => const PanelTab(),
        1 => BenchPage(
            stage: _stage,
            scene: _scene,
            vsync: this,
            autoRun: widget.autoBench,
          ),
        2 => ConformanceTab(autoRun: widget.autoConformance),
        3 => HardwareTab(suite: _hardware, group: HardwareGroup.auto),
        4 => HardwareTab(suite: _hardware, group: HardwareGroup.camera),
        5 => HardwareTab(suite: _hardware, group: HardwareGroup.person),
        _ => const ResultsTab(),
      };
}

class _StripTitle extends StatelessWidget {
  const _StripTitle({required this.tab, required this.scene});
  final String tab;
  final String? scene;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(
          children: [
            const FlutterLogo(size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                scene == null ? tab : '$tab  ·  $scene',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE6EAF2),
                ),
              ),
            ),
          ],
        ),
      );
}

/// The tabs, down the left. The receiver's shape: a landscape panel has
/// width to spare and no height to spare, and a 44 px row is a target a
/// thumb hits without aiming.
class _Rail extends StatelessWidget {
  const _Rail({required this.current, required this.onPick});
  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Container(
        width: 150,
        color: const Color(0xFF161A23),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _tabNames.length; i++)
              _RailItem(
                label: _tabNames[i],
                selected: i == current,
                onTap: () => onPick(i),
              ),
          ],
        ),
      );
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4C8DFF);
    final colour = selected ? accent : const Color(0xFF9AA4B8);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 44,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            height: 1.0,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
            color: colour,
          ),
        ),
      ),
    );
  }
}
