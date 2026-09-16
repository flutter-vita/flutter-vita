# Apps

## `gallery/` — committed

Everything this port is measured with, on one panel, five tabs:

- **Panel**: what the port *looks like*, judged by eye. A widget either looks
  right or it does not, and no app can assess that about itself.
- **Scenes**: the benchmark of [ADR-0017](../docs/adr/0017-the-gallery-becomes-the-benchmark.md),
  36 scenes, driven by `tools/bench.sh`.
- **Conformance**: what this port can actually do, one probe per capability
  (78 of them), measured on hardware rather than assumed. Its own app until
  2026-09-14. Probes are ordered safest-first, so that a native crash still
  tells you something: everything above the first missing row passed. The
  journal `ux0:data/flutter-vita/conformance.txt` survives the process; the
  resume file skips the probe that killed the last attempt.
- **Hardware**, **Cameras**, **Manual**: does each piece of the console
  answer, and with what. One suite of checks on three tabs. Hardware runs by
  itself: the console (`device_info_plus`), the battery (`battery_plus`),
  storage, the clock, Wi-Fi (`connectivity_plus`), HTTP over TLS, the motion
  sensors (`sensors_plus`), the speaker and the microphone (`audioplayers`
  plays a 1 kHz WAV made in Dart while `record` records; the recording
  decides), an AAC asset through `AssetSource`. Cameras shows a frame from
  each through `camera`'s image stream. Manual needs a person: buttons and
  sticks, the back touch panel, the keyboard. The pub packages are the ones
  an app would use, each with its Vita implementation from `packages/`
  registered in `main.dart`; the C halves live in the packages and are
  compiled into this app (ADR-0020). What no package covers is a method on
  `vita/hardware`, `templates/vita-app/hardware.c`, compiled in because this
  app's pubspec says `hardware_checks: true`. A check a person has to judge
  ends in the `EYE` state.
- **Results**: the last run of each suite, read back from the card.

Above every tab a strip shows what the console is doing this second: frames
per second and UI/raster time from the framework's own `FrameTiming`; the four
cores, GPU busy, the battery's temperature and charge, free memory from the
embedder over `vita/stats`. The strip is not drawn while a Scene runs.

Three switches on the card start an unattended run and the run writes a
result file and a done marker the host waits for: `bench.on`
(`bench-result.json`, `bench-done`), `conformance.on`, `hardware.on`.
`tools/bench.sh --suite scenes|conformance|hardware|all` writes them.

## `test-apps/` — checkouts gitignored, manifest committed

Real third-party apps, cloned for bug-finding — the bugs the conformance app
structurally cannot find, because it was written by the people who wrote the
engine. Checkouts are disposable; `test-apps/manifest.txt` is not, because a bug
found in an app you cannot name again is a bug you cannot regression-test.

Five apps, one per axis, and one of them is a plugin-free **control** that must
pass. Without it, five failures cannot tell a broken port from a broken
harness. All five share one title id -- `FVTA00002`, because it is already registered --
and the deliverable is a patch series
under `patches/test-apps/` — no third-party source enters this repository, and
lines-changed-to-first-frame is the score rather than pass/fail.

See [ADR-0012](../docs/adr/0012-test-apps-as-measurement-instrument.md) for how
it is run and what it is allowed to conclude, and
[ADR-0013](../docs/adr/0013-ffi-needs-static-linking.md) for the test an app has
to pass to be admitted at all.
