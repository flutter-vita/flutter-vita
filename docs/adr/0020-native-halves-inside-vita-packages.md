# ADR-0020: A Vita package carries its own C, and the set grows to ten

**Status:** Accepted; amends ADR-0009's pinned set
**Date:** 2026-09-16

## Context

ADR-0009 pinned three non-endorsed Vita implementations, all pure Dart:
`path_provider_vita`, `shared_preferences_vita`, `url_launcher_vita`. It also
said the set grows only after the survey moves.

The gallery's Hardware tab moved it first. The tab checks the console's
parts: battery, sensors, network, microphone, speaker, cameras. Until this
date every check was a method on one channel, `vita/hardware`, answered by
`templates/vita-app/hardware.c`, which the template compiled into the app
when its pubspec said `hardware_checks: true`. That worked and proved
nothing an app author could use: an app does not talk to `vita/hardware`,
it depends on `battery_plus` and calls `Battery().batteryLevel`. The ask on
2026-09-16 was that the checks run on the Flutter side, through the pub
packages an app would use.

A pub package's Vita implementation needs C for these parts (ScePower,
SceMotion, SceNetCtl, SceAudioIn, SceAudioOut, sceAvPlayer, SceCamera). A
Dart package cannot ship a `.so` here (ADR-0004: one static ELF), and the
template cannot know every package's sources in advance.

## Decision

1. **A Vita package may carry its native half.** A package with a
   `vita/plugin.cmake` appends its C sources to `PLUGIN_SOURCES` and its stub
   libraries to `PLUGIN_LIBS`; `tools/build-vita-app.sh` finds those files
   through the app's `package_config.json` and passes them to the template as
   `VITA_PLUGINS`. The C is compiled into the app's ELF with the app.

2. **One method channel per plugin, `vita/<name>`, JSONMethodCodec.** The
   embedder hands every `vita/...` channel it does not answer itself to the
   weak `flutter_vita_channel_call`; `templates/vita-app/plugin.c` defines it,
   finds the handler the plugin registered with `fvita_channel_register` from
   a constructor, and runs it on a thread of its own with a 15 s watchdog.
   `fvita_plugin.h` is the whole API a plugin's C sees: register, reply,
   read an argument, log, base64.

3. **The pinned set is ten.** To ADR-0009's three: `battery_plus_vita`,
   `sensors_plus_vita`, `device_info_plus_vita`, `connectivity_plus_vita`,
   `record_vita`, `audioplayers_vita`, `camera_vita`. Each implements the
   package's platform interface as far as the console goes and says where
   it stops in its class comment (no magnetometer, no barometer, no video
   recording, no MP3, no network audio source, one AAC player at a time).

4. **`hardware.c` keeps what no package covers**: storage, the clock, the
   controls, the touch panels, the console's own volume. The gallery's
   checks go through the packages for everything else.

## What the first build showed

Gallery build 61, 2026-09-16: eleven checks pass through the packages,
the back camera by eye (the console lies face down), three checks wait for
a person. The speaker plays a WAV made in Dart through `BytesSource` and an
AAC asset through `AssetSource`; `record` hears the tone at +76 dB over
the room; `camera`'s image stream delivers 320x240 frames at about seven a
second, the base64 through the JSON codec being the cost.

## Consequences

- The maintenance commitment grows from three upstreams to ten. Each is a
  platform-interface implementation, the stable half of a federated
  plugin; the app-facing halves move more often and do not concern us.
- A plugin's C runs in the app's process, on threads the registry makes.
  A handler that blocks past 15 s is abandoned, not killed; its memory
  stays with it.
- Frames and audio cross the channel as base64 in JSON. A 320x240 frame is
  410 KB of text and 100 ms of the UI thread on the console. A binary
  codec on `vita/*` channels is the next step when a preview needs more
  than seven frames a second.
- `device_info_plus` casts to `LinuxDeviceInfo` on the console
  (ADR-0008: the linux identity stays), so `VitaDeviceInfo` is one, with the
  console's facts in its fields and more under `data`.
- The survey in `tools/plugin-survey` was not re-run for this; the seven
  came from the Hardware tab's needs, not from the knee. The tool stays
  the instrument for the next extension.

## Revisit trigger

A package that needs more than one channel, a binary codec, or a thread
model the registry does not give it. Or the survey showing a package in a
third of blocked apps that is not among the ten.

## Related

- [ADR-0009](0009-plugins-via-non-endorsed-vita-implementations.md) — the mechanism and the first three
- [ADR-0004](0004-static-single-binary.md) — why the C is compiled in, not loaded
- [ADR-0008](0008-app-visible-platform-identity.md) — the linux identity `device_info_plus` sees
