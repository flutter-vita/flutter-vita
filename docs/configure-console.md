# Console setup

Everything between your computer and the console goes over Wi-Fi, through
a small Flutter app that stays on the console: the **bridge**. This page
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
PlayStation Mobile runtime (the usual tool is
[ShaRKF00D](https://github.com/Rinnegatamante/ShaRKF00D)). ShaRKF00D needs
the runtime with its 2.01 update installed first. It shows no screen and
closes when it has written the file. Without the file an app
starts, logs that the compiler is missing, and shows nothing.
`bootstrap-bridge.sh` below checks for the file and says so.

## 3. The network

Connect the console to the same Wi-Fi network as your computer. In
**Settings > Power Save Settings**, turn off automatic standby while you
develop: a console that goes to sleep takes its port with it, and from the
host that looks like an app that died.

## 4. Install the bridge

This is the one step that needs the console's IP address, and it needs it
once. Open VitaShell on the console and press **SELECT**: it starts an FTP
server and shows its address. Then, from the repository:

```sh
./tools/build-bridge.sh
./tools/bootstrap-bridge.sh 192.168.1.23
```

The script sends `bridge/app/build/vita/flutter_vita_bridge.vpk` to
`ux0:/` over that FTP server. Install it from VitaShell (open the file,
confirm), then start **Flutter Bridge** from the LiveArea. The
[releases](https://github.com/flutter-vita/flutter-vita/releases) carry
the same file, for a console set up before the toolchain. Its name is
`flutter-vita-bridge-<version>.vpk`. In release 0.1.0 it is
`flutter-vita-receiver-3.44.8_0.1.0.vpk`, from before the bridge had its
current name.

From now on the console announces itself as `fluttervita.local` whenever
the bridge or an app built with this toolchain runs, and no tool asks for
an address again.

```sh
flutter-vita doctor      # ends with the console it found
```

**If the name does not resolve** while the bridge is on the screen, the Mac
gets no multicast from the console. The Vita has a 2.4 GHz radio only. Many
routers do not send multicast between their 2.4 GHz and 5 GHz radios, so a
Mac on 5 GHz cannot find the console by name, although it can connect to the
console's address. Put the Mac on 2.4 GHz, or turn off IGMP snooping or
"multicast enhancement" on the router. `ux0:data/flutter-vita/mdns.txt` on the
card shows this case: `joined 1` and a rising `announced`, but `queries 0`.

## 5. What the bridge is

The bridge is title `FVTA00001`, listening on port 1341. It installs
apps (through the console's own installer service, so a new title needs
no VitaShell step), launches them, keeps their logs and crash dumps, and
shows all of it on its screen:

| Tab | What it shows |
|---|---|
| DEPLOY | The current install, byte by byte, and the app it launched. It starts empty each time the bridge opens; the previous session stays on the card as `ux0:data/flutter-vita/deploy.log.1` |
| LOGS | Logs of past runs, by title and build |
| CRASHES | Crash dumps on the card, with the thread that faulted |
| APPS | Installed titles; launch one |
| TESTS | The bench app's results, and the test and hardware results the gallery wrote |
| FILES | A file browser: images, WAV, AAC and MP3 play; a `.vpk` installs |

An app you deploy goes into slot `FVTA00002` by default and listens on
port 1339 while it runs. Only one of the two is on screen at a time: the
bridge launches the app and goes away; the app hands back to the
bridge when asked.

## 6. The two button chords

Both work in every app built without `--release`, without a network:

- **L + R + START, held for one second**: hand the console back to the
  bridge. This is the way home when the network is down or the app has
  stopped answering.
- **L + R + SELECT**: show or hide the debug strip
  ([Debug an app](debug-app.md)).

## 7. Updating the bridge

A running title cannot overwrite its own files, so the bridge is
replaced by a second, 50 KB title, the **updater** (`FVTA00009`):

```sh
./tools/selfupdate-bridge.sh
```

It builds the bridge, stages it on the card, launches the updater, which
copies the files over `FVTA00001` and relaunches it. The updater keeps the
previous bridge; start it with L held to put that one back.

Next: [Get started](get-started.md).
