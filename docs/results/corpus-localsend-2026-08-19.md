# localsend on the Vita: from hard fault to working discovery

2026-08-19. Device: PCH-2000, 192.168.0.32. Pin `fd8140b6` (v1.15.4, the last
release with no Rust in it).

localsend was the corpus app that scored worst — 75 lines of modernization just
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

## Still open

- **Rendering.** The Receive screen was 4.7 fps at 13% damage. `dmg%` alone does
  not predict frame rate — manga_reader holds 48 fps at 89% — so the raster cost
  inside the damaged region is still unattributed, and that is the number the
  GPU-backend decision turns on.
- `connectivity_plus` and `network_info_plus` raise MissingPluginException.
- The TCP leg of the announcement response fails and falls back to UDP. Harmless
  here, since the probe ran no server, but it has not been tested against a real
  peer.
