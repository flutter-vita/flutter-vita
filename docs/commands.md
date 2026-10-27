# Commands

`flutter-vita` lives in [`cli/`](../cli); put that directory on your `PATH`
or call `./cli/flutter-vita`. Every command finds the console by itself,
as `fluttervita.local`; `--host IP` skips the lookup and `--subnet
192.168.1` sweeps another /24.

| Command | What it does |
|---|---|
| `doctor` | Finds or installs VitaSDK, then checks the engine artifact, the embedder submodule, `gen_snapshot` for this host, the Flutter SDK, and finds the console. Each failing line prints its fix. |
| `version`, `--version` | The tool's release from `versions.json`, git's description of the checkout when it has moved past the tag, and the Flutter, engine and embedder releases it builds against. The bridge's footer shows the same build string. |
| `precache` | Downloads the engine release named in `versions.json` from the fork's releases, checks its sha256 and unpacks it to `out/artifacts/`. `--force` replaces one that is there. `build` runs it on its own when the artifact is missing. |
| `devices` | Sweeps the subnet for consoles and says what each one is running: the bridge, or an app. |
| `build <app>` | Builds an app directory into `<app>/build/vita/<name>.vpk`. |
| `install <app\|vpk>` | Builds if given a directory, hands the console to the bridge if an app is running, installs, launches. |
| `run <app>` | `install`, then prints the app's log as it arrives. |
| `logs` | The running app's log, whole. |
| `screenshot [file]` | The panel as a PNG, with the descriptor of what the display controller is scanning (which says the pixels are on the screen, not only in memory). |
| `tap <x> <y>` | A touch at that point, in the 960x544 panel's pixels. |

## Options

| Option | Commands | Meaning |
|---|---|---|
| `--host IP` | all | Skip discovery. |
| `--subnet 192.168.1` | `devices` | Sweep a different /24. |
| `--name "App Name"` | `build`, `install`, `run` | The LiveArea name. Overrides `vita.name` in `pubspec.yaml`. |
| `--title-id FVTA00002` | `build`, `install`, `run` | The slot to build for and install into. Overrides `vita.title_id`. |
| `--debug` | `build`, `install`, `run` | The default, said out loud: the dev server, the debug strip, the fallback to the bridge. |
| `--release` | `build`, `install`, `run` | None of those. What you ship. [Release an app](release-app.md). |

## The scripts underneath

The CLI runs the scripts in [`tools/`](../tools); they take more options
than the CLI exposes, and each has its usage at the top of the file.

| Script | Use |
|---|---|
| `tools/build-vita-app.sh <app>` | The build: Dart to kernel, kernel to an AOT snapshot, snapshot plus engine to an ELF, ELF to a `.vpk`. `--extra-source`, `--define`, `--entry-point`, `--flutter DIR`, `--engine DIR`. |
| `tools/deploy.sh <app>` | Build, install, launch through the bridge, with a progress readout. `--no-build` reuses the last `.vpk`. |
| `tools/install-vpk.sh <vpk>` | Install one `.vpk` through the bridge. |
| `tools/pull.sh <port> <path> <file>` | Copy one file from the card, compare it with its size, and copy again when it is short. The scripts pull results and crash dumps with it. |
| `tools/analyse-crash.sh <elf>` | Pull the newest crash dump and symbolicate it against the app's ELF. [Debug an app](debug-app.md#crashes). |
| `tools/build-bridge.sh` | Build the bridge. `--scratch` builds a second one, `FVTA00004` on port 1342, to try a bridge change without touching the one that deploys. |
| `tools/bootstrap-bridge.sh <address>` | Put the bridge on a console that has none, over VitaShell's FTP. Once. |
| `tools/selfupdate-bridge.sh` | Replace the bridge on the console through the updater title. |
| `tools/suite.sh tests\|hardware\|all` | Run the gallery's tests or hardware checks unattended and print the verdict. The benchmark is [flutter-vita-bench](https://github.com/flutter-vita/flutter-vita-bench), with its own `tool/bench.sh`. |
| `tools/panel.sh` | Drive the bridge's screen from the host: `tab files`, `shot out.png`, `select`, `back`. |
| `tools/engine-tree.sh --apply\|--verify\|--list` | The engine tree, for engine builds: `--apply` puts the fork's branch into it, `--verify` checks the tree and the five dependency forks, `--list` prints their commits. |
| `tools/package-engine.sh` | Turn an engine build into the artifact tarball. |
| `tools/publish-engine.sh [--dry-run\|--check]` | Publish the engine build as an **engine release** and pin it in `versions.json`. `--check` downloads the pinned engine as `precache` does. [release.md](release.md) |
| `tools/publish-release.sh <tag> [--dry-run]` | Publish a **tool release**: the tag, the Bridge `.vpk`, the archive for the Homebrew cask, the embedder tag when it moved, and the cask. [release.md](release.md) |

## The app's own port

While an app built without `--release` runs, it serves a line protocol on
port 1339 that the CLI and the scripts speak. It is plain text over TCP,
one command per connection, so `nc` works too:

```sh
printf 'ping\n' | nc -4 -w 5 fluttervita.local 1339
```

| Command | Reply |
|---|---|
| `ping` | `pong <role> <title id> <port> <bridge title id>` |
| `log` | The whole log |
| `shot`, `shotinfo` | The frame as raw pixels; the display descriptor |
| `tap <x> <y>`, `swipe <x0> <y0> <x1> <y1> <steps>` | A touch, a drag |
| `overlay on\|off` | Show or hide the debug strip |
| `get <path>`, `put <size> <path>`, `ls <dir>`, `rm <path>` | Files on the card |
| `stat <path>` | The size of one file: `<bytes> file`. `tools/pull.sh` compares a `get` with it |
| `diag` | Memory, threads, the display, in one page |
| `handoff [titleid]` | Launch the bridge (or another title) and exit |
| `relaunch` | Exit and start again |

Use `-4`: without it every connection waits five seconds for an IPv6 answer
the console never gives.
