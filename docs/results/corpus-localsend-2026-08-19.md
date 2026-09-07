# localsend on the Vita: from hard fault to working discovery

2026-08-19. Device: PCH-2000, 192.168.0.32. Pin `fd8140b6` (v1.15.4, the last
release with no Rust in it).

localsend was the test apps app that scored worst — 75 lines of modernization just
to build — and it turned out to be the most useful, because it is the only one
that exercises `dart:io` past the point where a toy does. Four separate defects
came out of it, three of them mine.

## What broke, in order

### 1. A hard fault with no message, before any UI

`Platform.resolvedExecutable` → `File::ReadLink("/proc/self/exe")`. There is no
`/proc` here, so it fails every time, and `runtime/bin/file_linux.cc` stored the
`-1` in a `size_t`:

```c
size_t target_size = ReadLinkInto(pathname, target, kBufferSize);
if (target_size <= 0) { ... }        // SIZE_MAX sails straight past this
```

`SIZE_MAX` then reached `memmove`. Upstream never sees it because on Linux the
only caller passes a path that always exists. Fixed by making it `intptr_t`, and
by giving `Platform::ResolveExecutablePath` a real answer on this platform:
`app0:/eboot.bin`, the read-only mount of the installed .vpk and the ELF inside
it. localsend reads it to look for a `settings.json` sibling and decide whether
it is running in portable mode.

### 2. `NetworkInterface.list()` threw ENOSYS

The old implementation refused to enumerate, reasoning that an empty list would
be a lie. It was right about the empty list and wrong about the alternative:
localsend's discovery calls `NetworkInterface.list()` to choose a socket to bind,
the throw escaped into an isolate with no handler, and the app came up with its
entire transfer stack dead while the UI looked fine.

There is no `getifaddrs`, but there is nothing to enumerate — the console has one
connection, and `sceNetCtlInetGetInfo` reports its address. It now returns that
single interface as `wlan0`, index 1, IPv4 only.

### 3. The interface had no addresses — and the report was lying about it

`NetworkInterface.list()` then returned `wlan0` with an empty address list, which
the SDK's own list-building code cannot produce: it only creates an interface
object when an address survives the loopback and link-local filters.

It never was empty. **A list holding one empty string prints exactly like an
empty list** — `[''].toString()` is `[]` — so localsend's `ip: []` meant "one
address that stringified to nothing", and it read as "no addresses" for long
enough to send me after a wrong hypothesis about `sin_len` and a BSD-shaped
`sockaddr`. That hypothesis was tested and disproved before the real cause
turned up, which is the only reason it is worth writing down.

The cause was one line in the new `ListInterfaces`:

```c
RawAddr addr;
memset(&addr, 0, sizeof(addr));   // wrong
```

`RawAddr::size` is a member with a default initializer sitting *outside* the
union, and the `memset` zeroed it. Every `SocketAddress` built from that struct
called `getnameinfo` with `salen = 0`, which fails — and the constructor turns
that failure into an empty string rather than an error. Clearing only `addr.ss`
and setting `addr.size` fixes it.

The conformance app grew two probes for this, and they print the address *count*
next to the addresses, because the count is what the rendering hides.

### 4. Multicast join was stubbed

`MCAST_JOIN_GROUP` and `struct group_req` are the protocol-independent multicast
API from RFC 3678, and VitaSDK has neither — so `JoinMulticast` returned ENOSYS.
The note left there said sceNet does implement IPv4 multicast under the older BSD
names and that a real implementation only wanted a device to test against. It
does: `IP_ADD_MEMBERSHIP`, `IP_DROP_MEMBERSHIP` and `struct ip_mreq` are all in
its `<netinet/in.h>`. The join now uses those, selects the interface with
`INADDR_ANY` (there is exactly one), and reports `EAFNOSUPPORT` for IPv6, which
this device genuinely lacks.

## Where it landed

```
[INFO] [Multicast] Bind UDP multicast port (ip: [192.168.0.32], group: 224.0.0.167, port: 53317)
[INFO] [Server] Server started. (Port: 53317, HTTPS only)
[INFO] [Discovery] [DISCOVER/UDP] MacProbe (192.168.0.30, model: probe)
[INFO] [Multicast] Respond to announcement of MacProbe (192.168.0.30) with UDP because TCP failed
```

Verified from the other side as well: a multicast announcement sent from the Mac
is received by the Vita, and the Vita answers with its own DTO.

```
$ curl -sk https://192.168.0.32:53317/api/localsend/v2/info
{"alias":"Pretty Potato","version":"2.1","deviceModel":"Linux",
 "deviceType":"desktop","fingerprint":"783B167E…","download":false}
```

So localsend on the Vita runs its HTTPS server with a self-generated
certificate, announces itself, and is discoverable by other LocalSend peers.
An actual file transfer has not been run yet.

> **Done 2026-08-21, after one bug.** See the follow-up at the end: a transfer
> now completes end to end, and the blocker was `path_provider_vita` returning
> null for the downloads directory, not anything in the network stack.

## Still open

- **Rendering.** The Receive screen was 4.7 fps at 13% damage. `dmg%` alone does
  not predict frame rate — manga_reader holds 48 fps at 89% — so the raster cost
  inside the damaged region is still unattributed, and that is the number the
  GPU-backend decision turns on.
  **Answered 2026-08-21 — see the follow-up at the end of this file. Raster is
  97% of the frame.**
- `connectivity_plus` and `network_info_plus` raise MissingPluginException.
- The TCP leg of the announcement response fails and falls back to UDP. Harmless
  here, since the probe ran no server, but it has not been tested against a real
  peer.

---

# Follow-up 2026-08-21: the transfer works, and the raster cost is attributed

Two things were open above. Both are now answered, and one of them was answered
by the other's instrumentation.

## A real file transfer, end to end

**It failed, and the cause was not the network.** Reported as "I send something
to localsend from outside, nothing happens on the Vita, but the Vita *is*
discovered". Everything about that description was accurate and every obvious
suspect was wrong:

| Suspect | Result |
|---|---|
| Multicast discovery | Works — it is why the device appears in the sender's list |
| TCP accept on 53317 | Works — `nc` connects |
| **TLS handshake** | **Works.** `curl -k` completes in 0.24 s and gets `HTTP 200` from `/api/localsend/v2/info` |
| `/register` | Works, returns the device DTO |
| `prepare-upload` | **Hangs.** No status line, no body, connection held open |

The strong prior was TLS, because
[docs/phase-7-tls.md](../phase-7-tls.md) says in bold that **HTTPS does not
work**. That statement is about the *outbound* client handshake. This is the
*server* side, which is a different code path, and it works. Worth recording
plainly: the phase-7 conclusion should not be read as "no TLS on this port".

The actual fault, from the app's own log:

```
Unhandled Exception: Null check operator used on a null value
#0  getDefaultDestinationDirectory (localsend_app/util/native/directories.dart:29)
#1  ReceiveController._prepareUploadHandler (receive_controller.dart:216)
```

`directories.dart:29` is `Directory(Platform.environment['HOME']!)`.

The chain, which is worth following because every link is a design decision
made elsewhere in this project:

1. [ADR-0008](../adr/0008-app-visible-platform-identity.md) reports
   `TargetPlatform.linux`, so the function takes its **desktop** branch.
2. The desktop branch calls `path.getDownloadsDirectory()`.
3. `path_provider_vita` returned **null** for it, deliberately, on the
   documented reasoning that *"there is no Downloads folder, and no browser or
   mail client that would fill one"* and *"callers already handle null"*.
4. localsend does handle null — its fallback reads `Platform.environment['HOME']`.
5. `HOME` is unset on the Vita, so the `!` throws.
6. The exception escapes a shelf handler, so **no response is ever written**.
   The sender waits forever; the Vita shows nothing. Hence the symptom.

**Fixed in `path_provider_vita` rather than in localsend**, because a real path
means the desktop fallback is never entered by any app, not just this one:

```dart
@override
Future<String?> getDownloadsPath() => _ensure('ux0:downloads');
```

`ux0:downloads` is the device's own convention — it is what VitaShell downloads
into — so a received file lands where the user already looks. Unlike the other
paths in that package it is deliberately **not** keyed on the title id; a
downloads folder is a place people go looking, and burying it under a
nine-character id defeats the point.

Verified end to end against the rebuilt app:

```
POST /api/localsend/v2/prepare-upload
  -> HTTP 200 {"sessionId":"2a2f3c87-…","files":{"f1":"fae0f8c6-…"}}
POST /api/localsend/v2/upload?sessionId=…&fileId=f1&token=…
  -> HTTP 200 {}
[INFO] [ReceiveController] Saved …
get ux0:downloads/hello-from-mac.txt
  -> hello from the mac!!!!!
```

**localsend receives files on a PlayStation Vita.** Discovery, TLS, the v2
protocol handshake and the write all work.

Two notes for whoever reads this next. The premise in `path_provider_vita` was
not merely unlucky — *"callers already handle null"* is the kind of claim that
should be tested against a caller before it is written down, and the test apps
existed precisely to test it. And this is the second time the Linux identity
has produced an **early, fatal** failure rather than a late catchable one, which
is the pattern
[platform-identity-options.md](../platform-identity-options.md) named as its
sharper revisit trigger.

## Raster cost, attributed

The open item said the raster cost inside the damaged region was unattributed
and that it was the number the GPU decision turns on. The engine now times the
raster pass separately from the present, and the answer is not ambiguous:

```
localsend, Receive screen:
FRAMES active 60 @ 205034 us = 4.87 fps (raster 199559 us = 97%, blit 1278 us = 0%, dmg 13%)
```

**Raster is 97% of the frame.** The blit is 0.6% — partial repaint
([ADR-0007](../adr/0007-enable-partial-repaint-in-software-path.md)) is working
exactly as designed and copying only the 13% that changed. The UI thread —
Dart build and layout, everything left after raster and blit — is about 3%.

For contrast, from the same build on flutter_manga_reader:

| App / screen | dmg | raster | blit |
|---|---|---|---|
| manga_reader, idle | 0% | 704 us | 2 us |
| manga_reader, library | **5%** | **13,933 us** | 553 us |
| manga_reader, scrolling | **89%** | **13,965 us** | 9,713 us |
| localsend, Receive | 13% | **199,559 us** | 1,278 us |

Read the middle two rows together: **5% damage and 89% damage cost the same
raster.** Eighteen times the area, identical cost. The blit tracks area
faithfully (553 us against 9,713 us) because a memcpy is honest about how many
bytes it moves. Raster does not, because area is not work.

### What is inside localsend's 13%

One widget, and it is worth naming precisely because it makes the general point:

```dart
Transform.rotate(               // RotatingWidget, ticking at 30 fps
  child: ColorFiltered(         // forces a saveLayer
    colorFilter: ColorFilter.mode(primary, BlendMode.srcATop),
    child: Assets.img.logo512.image(width: 200, height: 200),  // 512 -> 200
  ),
)
```

Every frame: allocate an offscreen layer, resample a 512×512 PNG down to
200×200 through a rotation matrix, apply a colour filter, composite. Nothing
can be cached because the rotation changes each tick.

Measured by removing only the `ColorFiltered` and rebuilding:

| Variant | raster | share of frame |
|---|---|---|
| As shipped | ~199,000 us | 97% |
| `ColorFiltered` removed | ~110,000 us | 62–65% |

So the colour filter is about **half** the cost and the rotated downscale is
the other half. Both are single-pass operations on any GPU.

### What this settles

**The bottleneck is the raster pass, not the UI thread and not the present.**
A GPU backend addresses 97% of the frame time on this screen; the UI thread it
would not help is 3%. That is as clear as this question is going to get, and it
is the evidence [ADR-0003](../adr/0003-software-rendering-first.md)'s revisit
was waiting for.

**One honest caveat, which does not change the conclusion but bounds it.**
localsend's headline number is dominated by a single pathological widget. A
GPU fixes it; so would deleting one `ColorFiltered`. The general claim this run
supports is narrower and more useful than "Flutter is slow on Vita": *the
software rasterizer's cost is driven by what is drawn, not how much*, and the
operations that hurt it — saveLayer, filters, rotated resampling — are exactly
the ones hardware does for free. manga_reader's 5%-costs-as-much-as-89% pair is
the cleaner evidence for that, because nothing pathological is involved.

## Still open

- `connectivity_plus` and `network_info_plus` still raise MissingPluginException.
- Send *from* the Vita has not been tested; only receive.
- `getDownloadsPath` is the only path in `path_provider_vita` that is not
  title-id keyed. If a second app writes there, that is intended, but nothing
  yet tests two apps sharing it.
