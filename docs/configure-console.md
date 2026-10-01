# Console setup

Everything between your computer and the console goes over Wi-Fi, through
a small Flutter app that stays on the console: the **receiver**. This page
takes a console from stock homebrew to one that answers `fluttervita.local`.
You do it once.

## 1. Homebrew

The console needs a homebrew enabler and VitaShell:

- Firmware 3.60 or 3.65: HENkaku (or Enso, which makes it permanent).
- Firmware 3.65 to 3.74: h-encore² and the same VitaShell.

The homebrew community's guides cover this; nothing here is specific to
Flutter. No kernel plugin is needed at any point: this port uses none
([ADR-0011](adr/0011-crash-recovery-without-taihen.md)).

## 2. The shader compiler

Every app draws through the GPU, and the GPU wants Sony's shader compiler,
`libshacccg.suprx`, at `ur0:data/libshacccg.suprx`. It is not part of the
firmware and not in this repository; the community extracts it from the
PlayStation Mobile runtime (the usual tool is ShaRKF00D). Without it an app
starts, logs that the compiler is missing, and shows nothing.
`bootstrap-receiver.sh` below checks for the file and says so.

## 3. The network

Connect the console to the same Wi-Fi network as your computer. In
**Settings > Power Save Settings**, turn off automatic standby while you
develop: a console that goes to sleep takes its port with it, and from the
host that looks like an app that died.

## 4. Install the receiver

This is the one step that needs the console's IP address, and it needs it
once. Open VitaShell on the console and press **SELECT**: it starts an FTP
server and shows its address. Then, from the repository:

```sh
./tools/build-receiver.sh
./tools/bootstrap-receiver.sh 192.168.1.23
```

The script sends `receiver/app/build/vita/flutter_vita_receiver.vpk` to
`ux0:/` over that FTP server. Install it from VitaShell (open the file,
confirm), then start **Flutter Vita Receiver** from the LiveArea. The
[releases](https://github.com/flutter-vita/flutter-vita/releases) carry
the same file as `flutter-vita-receiver-<version>.vpk`, for a console set
up before the toolchain.

From now on the console announces itself as `fluttervita.local` whenever
the receiver or an app built with this toolchain runs, and no tool asks for
an address again.

```sh
flutter-vita doctor      # ends with the console it found
```

## 5. What the receiver is

The receiver is title `FVTA00001`, listening on port 1341. It installs
apps (through the console's own installer service, so a new title needs
no VitaShell step), launches them, keeps their logs and crash dumps, and
shows all of it on its screen:

| Tab | What it shows |
|---|---|
| DEPLOY | The current install, byte by byte, and the app it launched. It starts empty each time the receiver opens; the previous session stays on the card as `ux0:data/flutter-vita/deploy.log.1` |
| LOGS | Logs of past runs, by title and build |
| CRASHES | Crash dumps on the card, with the thread that faulted |
| APPS | Installed titles; launch one |
| TESTS | The bench app's results, and the test and hardware results the gallery wrote |
| FILES | A file browser: images, WAV, AAC and MP3 play; a `.vpk` installs |

An app you deploy goes into slot `FVTA00002` by default and listens on
port 1339 while it runs. Only one of the two is on screen at a time: the
receiver launches the app and goes away; the app hands back to the
receiver when asked.

## 6. The two button chords

Both work in every app built without `--release`, without a network:

- **L + R + START, held for one second**: hand the console back to the
  receiver. This is the way home when the network is down or the app has
  stopped answering.
- **L + R + SELECT**: show or hide the debug strip
  ([Debug an app](debug-app.md)).

## 7. Updating the receiver

A running title cannot overwrite its own files, so the receiver is
replaced by a second, 50 KB title, the **updater** (`FVTA00009`):

```sh
./tools/selfupdate-receiver.sh
```

It builds the receiver, stages it on the card, launches the updater, which
copies the files over `FVTA00001` and relaunches it. The updater keeps the
previous receiver; start it with L held to put that one back.

Next: [Get started](get-started.md).
