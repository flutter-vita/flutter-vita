# Phase 5 — the capability audit, run

**2026-08-14, on hardware.** Raw journal:
[`results/conformance-2026-08-14.txt`](results/conformance-2026-08-14.txt).

**28 of 31 probes pass.** `runtime/bin` was ported in Phase 2 to make the engine
link, and the honest expectation was that much of it had never worked. Most of
it does.

## The headline

**Networking works.** DNS resolves, raw TCP connects, and an `HttpClient` GET
returns `HTTP 200` from the open internet. `eventhandler_vita.cc` on
`sceNetEpoll` had never been executed before today and it is correct.

**The filesystem works.** Every operation `path_provider` and
`shared_preferences` need: reading and stat-ing under `app0:`, and mkdir,
write, read-back, append, list, rename and delete under `ux0:data/`.

Together those are the top two items on the capability roadmap, and both are
substantially done rather than substantially missing. Phases 6 and 7 shrink
from "port a subsystem" to "fix four specific things".

## Results

| Group | Probe | | Detail |
|---|---|---|---|
| dart | async/Future, Timer, DateTime | **pass** | |
| platform | operatingSystem | **pass** | `linux` — exactly as [ADR-0008](adr/0008-app-visible-platform-identity.md) intends |
| platform | version | **pass** | `3.12.2` |
| platform | numberOfProcessors | **pass\*** | **`-1`** — wrong, see below |
| platform | pathSeparator | **pass** | `/` |
| platform | localHostname | **pass** | `localhost` |
| platform | environment | **pass** | 0 vars |
| platform | resolvedExecutable | **pass\*** | **`Platform_ResolvedExecutableName`** — a placeholder, see below |
| platform | script | **pass** | `app0%3A/main.dart` |
| fs | `Directory.current` | **pass** | `app0:` |
| fs | app0 exists / list / read / stat | **pass** | 9 entries; `icudtl.dat` 862304 B |
| fs | mkdir, write, read back, append | **pass** | under `ux0:data/flutter-vita` |
| fs | list, rename, delete | **pass** | |
| fs | `Directory.systemTemp` | **pass\*** | **`/tmp`** — does not exist |
| fs | `createTempSync` | **FAIL** | `PathNotFoundException` — consequence of the above |
| net | `ServerSocket.bind` | **pass** | got port 52226 |
| net | DNS lookup | **pass** | `104.20.23.154` |
| net | TCP connect | **pass** | `1.1.1.1:80` |
| net | HTTP GET | **pass** | **`HTTP 200`** |
| net | HTTPS GET | **FAIL** | **`Secure Sockets unsupported on this platform`** |
| process | `Process.run` refuses | **pass** | clean `ProcessException`, as designed |
| io | print / stderr | **FAIL** | `Failed to get type of stdio handle (fd 2)` |

`pass*` means the call succeeded and returned something wrong. Those are worse
than failures, because nothing reports them.

## The four things to fix

### 1. TLS is off by build configuration, not by certificates

`Invalid argument(s): Secure Sockets unsupported on this platform` is the error
`secure_socket_unsupported.cc` raises. So the archive question raised while
planning this phase is answered: **both `secure_socket_filter.o` and
`secure_socket_unsupported.o` are archived, and the unsupported one is winning.**

This is good news. The prediction was that HTTPS would fail at certificate
verification, because Dart reads trust roots from `/etc/ssl/certs` and there is
no such path here — a problem needing a CA bundle shipped and loaded. Instead it
fails before any of that, for a reason that is a GN configuration change.

The certificate problem is still ahead; it is simply not what is failing now.
Fix the build first, then find out.

### 2. `Directory.systemTemp` returns `/tmp`, which does not exist

Inherited from `platform_linux.cc`. Everything downstream of it fails —
`createTempSync` here, and in real apps anything caching to a temp directory.
Should be a real writable path under `ux0:data/`.

### 3. `numberOfProcessors` returns −1

`cpuinfo_vita.cc` never learned the answer. The Vita has 4 Cortex-A9 cores. Dart
sizes thread pools from this, so −1 is not cosmetic.

### 4. `resolvedExecutable` returns the literal string `Platform_ResolvedExecutableName`

A placeholder that escaped into a return value — the name of the native entry
point, returned instead of being called. Harmless until something tries to use
it as a path.

## Two findings about the harness itself

**Dart's `print` never reaches the log.** `Failed to get type of stdio handle
(fd 2)` confirms the `_reent` concern in the embedder's `OpenLog`: `freopen` on
the main thread does not rebind stdio for the UI thread where Dart runs. **Any
future debugging that assumes `print` works is debugging nothing.** The journal
file exists because of this.

**The app crashes after `== run complete ==`.** Every probe finished and the
journal closed cleanly, then the process died before it could be screenshotted.
That is a teardown crash, unrelated to any probe, and it is unexplained. Not
chased here — it does not affect the results, and the first run's crash dump was
`.tmp`-truncated so there is no reason to expect a usable one.

## What this changes

The design assumption behind the journal file — that a crash takes the screen
with it — was proved twice over. It also means the **screen is not a sufficient
reporting channel for anything that might crash**, which is most things worth
testing.

Phase 6 (filesystem) is now three small fixes rather than a port. Phase 7
(networking) is one build-configuration change plus whatever certificates turn
out to need. Both are much smaller than
[the roadmap](roadmap-capabilities.md) assumed, and that is because the
measurement was cheaper than the guessing would have been.
