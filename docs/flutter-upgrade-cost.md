# What upgrading Flutter costs, and what it buys

The pin is [VERSIONS.md](../VERSIONS.md) and moving it is an explicit project,
never routine maintenance ([ADR-0002](adr/0002-skia-not-impeller.md)). This
document is what makes that decision cheap: a **procedure for pricing an
upgrade before committing to it**, and the priced answer for the upgrade
currently on the table.

Price the upgrade *first*. The measurement below took under an hour and
changed the decision.

---

## The procedure

Everything here is read-only. It touches no vendored tree and needs no build.

**1. Get both trees reachable from one checkout.** Flutter is a monorepo now,
so a full clone at the candidate tag carries the engine source *and* the
history back to the current pin. Not the tools' own SDK in
`~/.flutter-vita/flutter/`: that one is the pinned version only.

```bash
git clone https://github.com/flutter/flutter.git /tmp/flutter-candidate
cd /tmp/flutter-candidate && git checkout <candidate>
git rev-list --count <current-framework-rev>..HEAD
```

The Dart SDK is not in that checkout — it is a DEPS entry. The vendored trees
are shallow (depth 1), but the commit is fetchable:

```bash
cd third_party/sdk && git fetch --depth=1 origin <candidate-dart-rev>
```

That is enough to diff two trees even though neither has history.

**2. Ask only about files our commits own.** The total commit count is
noise. The number that matters is how many of *our* files upstream moved. Our
files are the ones our commits touch, so the fork answers directly — each fork
starts at an import commit, and everything above it is ours:

```bash
cd third_party/flutter/engine/src/flutter/third_party/dart
git diff --name-only $(git rev-list --max-parents=0 HEAD) HEAD
```

Intersect that with `git diff --name-only <old> <new>`. Per commit, not in
aggregate — a series where one commit absorbs all the churn is a very different
job from one where every commit does.

**3. Check the ABI surface explicitly.** `shell/platform/embedder/embedder.h`
is the contract the embedder is compiled against. A **reordered or inserted
enumerator, or a struct that changed size**, is the failure mode that produces
a crash pointing nowhere near the cause. Diff it and read every hunk; there are
never many.

**4. Check the integration points the patches assume still exist.** For this
port that is the software rasterizer and the partial-repaint hook
([ADR-0007](adr/0007-enable-partial-repaint-in-software-path.md)). A patch that
applies cleanly to a function upstream has since restructured is worse than one
that conflicts.

**5. Diff DEPS for the other vendored pins.** Skia, BoringSSL and abseil each
carry their own patch and each moves independently of Flutter.

---

## Priced: 3.44.8 → 3.47.0 (measured 2026-08-19)

| | Current pin | Candidate |
|---|---|---|
| Flutter | 3.44.8, channel `stable` | 3.47.0, channel **`[user-branch]`**, branch `flutter-3.47-candidate.0` |
| Framework | `058e0af2` | `4cf24164` |
| Engine | `0cd61071` | `5f776256` |
| Dart | `d684a576` (3.12.2) | `da6595cd` (3.13.0) |

1,358 commits apart. Framework source: 97 files, +3,983 / −1,371.

**3.47.0 is a release candidate, not a stable release.** The channel field says
`[user-branch]` and `CHANGELOG.md` has no 3.45, 3.46 or 3.47 section at all.

### The engine half is nearly free

Of the **44 files the engine patch series owns, 6 changed** — all GN build
files, **+45 / −14 in total**.

| Patch | Files owned | Churned upstream |
|---|---|---|
| 0001-gn-vita-toolchain | 6 | 2 — `build/config/BUILDCONFIG.gn`, `tools/gn` |
| 0002-fml-for-vita | 13 | **0** |
| 0003-engine-sources-for-vita | 11 | 2 — `lib/gpu/BUILD.gn`, `lib/ui/BUILD.gn` |
| 0004-m2-link-check | 3 | 1 — `shell/platform/embedder/BUILD.gn` |
| 0005-skia-target-for-vita | 1 | 1 — `skia/BUILD.gn` |
| 0006-vita-fonts | 4 | **0** |
| 0007-boringssl-no-asm-for-vita | 1 | **0** |
| 0008-partial-repaint-in-the-software-path | 5 | **0** |

Not one line of C++ we patch in the engine moved.

**The ABI check passes.** `embedder.h` gained 17 lines, all additive:

- `kFlutterPointerDeviceKindInvertedStylus` is **appended after** `Trackpad`.
  The enum starts at `kFlutterPointerDeviceKindMouse = 1`, so every existing
  value keeps its number — `Touch` is still 2.
- A new standalone `FlutterPointerStylusButtons` enum, referenced by nothing we
  pass.
- One doc comment.

No struct changed size. This is the class of change that has bitten this
project before; this time it did not fire.

**The integration points are untouched.** `gpu_surface_software.cc`,
`gpu_surface_software_delegate.h`, `embedder_surface_software.{cc,h}`: byte
identical. `shell/common/rasterizer.cc` changed (+51 / −10) but grepping that
diff for `FrameDamage|damage|ComputeClipRect|supports_partial` returns **zero
hits**, so patch 0008 slots in where it always did.

### The Dart half is where the money is

Of the **67 files the Dart patch series owns in the Dart tree, 24 changed**,
+855 / −812. **Eight of the ten patches** have churn in files they own.

(67, not 68: patch 0005 owns a `BUILD.gn` belonging to the nested **zlib**
repo, not Dart's root one. Intersecting owned paths against a Dart-tree diff
matches those two by name — a trap worth knowing, since several patches in
this series apply to nested DEPS repos rather than the tree they sit beside.)

| Patch | Files owned | Churned | The expensive ones |
|---|---|---|---|
| 0001-add-vita-host-and-target-os | 3 | 1 | |
| 0002-route-vita-through-platform-dispatch | 8 | 1 | |
| 0003-vita-platform-implementations | 8 | **0** | clean |
| 0004-gn-vita-toolchain | 7 | 3 | `build/config/compiler/BUILD.gn` (69 lines) |
| 0005-zlib-no-armv8-on-vita | 1 | **0** | nested zlib repo, whose pin does not move |
| 0006-newlib-portability-fixes | 6 | 5 | `dart.cc` (353), `ffi_dynamic_library.cc` (344), `image_snapshot.cc` (192) |
| 0007-vmlibraryhooks-entry-point | 1 | 1 | |
| 0008-dart-vita-embedder-library | 3 | 2 | `sdk/lib/libraries.json` (299 lines) |
| 0009-vita-emulated-tls | 2 | 1 | |
| 0010-runtime-bin-for-vita | 29 | **10** | `runtime/bin/BUILD.gn` (122), the socket files |

`ffi_dynamic_library.cc` is load-bearing —
[ADR-0013](adr/0013-ffi-needs-static-linking.md) turns on it — and it is one of
the three biggest rewrites in the set.

### One change breaks compilation outright

`runtime/bin/socket_base.h`: `InterfaceSocketAddress` gained a **required
fourth constructor parameter**, `prefix_length`.

```c
  InterfaceSocketAddress(const RawAddr& addr,
                         const char* interface_name,
                         intptr_t interface_index,
                         intptr_t prefix_length)   // new, not defaulted
```

Our `SocketBase::ListInterfaces` is a **full replacement** of the POSIX one
(it reads `sceNetCtlInetGetInfo` instead of walking `getifaddrs`), and it calls
that constructor. After the upgrade it does not compile. The fix is small —
`sceNetCtlInetGetInfo` returns a netmask, so the prefix length is a popcount —
but it has to be written, and it lands on
[the code fixed on 2026-08-19](results/corpus-localsend-2026-08-19.md) to make
localsend discover peers.

Upstream also restructured the same function around a new
`RawAddr::FromInet4or6` helper, so the patch conflicts as well as breaks.

Two smaller notes from the same area, both benign:

- `LookupAddress` now calls `inet_pton` and `inet_aton` to reject legacy
  dotted-quad forms. **VitaSDK declares both** in `arpa/inet.h`, so this ports.
- A real upstream bug fix next door: `flags &= MSG_CMSG_CLOEXEC` became
  `flags |= MSG_CMSG_CLOEXEC` in `ReceiveMessage`. We do not use `SCM_RIGHTS`.

### The other vendored pins

Only **Skia moves** (`e9ed4fc9` → `8df24be6`), so our Skia commit
([flutter-vita/skia](https://github.com/flutter-vita/skia)) needs re-validating
against a tree we have not diffed: rebase it onto the new import. **BoringSSL,
abseil and zlib do not move at all** in this window, so those three forks are
free — including the zlib change, which was Dart patch 0005 before the forks.

---

## What the upgrade buys

| Change | Value to this port |
|---|---|
| `DrawDiffRoundRect` → `DrawRoundRect` optimization (#186203) in `display_list` | The only plausible software-raster win in the whole range. **Unmeasured**, and it fires only where that primitive is actually drawn |
| Text layout work in `painting`/`paragraph.dart` | Possible latent fixes. This port supplies its own font manager ([the commit `txt: a font manager for the Vita`](https://github.com/flutter-vita/flutter/commits/vita-3.44.8)), so it could go either way |
| Inverted-stylus and stylus-button input | **Nothing.** The Vita has no stylus |
| `widget_inspector` improvements | **Nothing.** Needs a debug VM service this port does not run |
| 336 files, +13,110 lines of Impeller | **Nothing.** [ADR-0002](adr/0002-skia-not-impeller.md) — we are Skia software raster |

That last row is the whole story in one number. Upstream's engine effort in
this window went to Impeller at **13,110 insertions across 336 files**. The
Skia path we actually execute got **5 insertions across 2 files**.

And the workaround that motivated
[ADR-0008](adr/0008-app-visible-platform-identity.md) is still required:
`defaultTargetPlatform` still throws `Unknown platform` for an unrecognised OS
in 3.47.0.

## What the upgrade costs

| Cost | Detail |
|---|---|
| **It is a release candidate** | `[user-branch]` / `flutter-3.47-candidate.0`, no changelog entries. Pinning it trades a stable base for an unproven one |
| **It discards the ardera reference point** | The 3.44.8 pin exists because [ardera](https://github.com/ardera/flutter-engine-binaries-for-arm) ships prebuilt arm32 binaries at that exact commit — third-party proof the engine cross-compiles to armv7. Past it, "Vita bug" and "arm32 bug" become indistinguishable |
| **Eight of ten Dart patches need rework** | Including the three largest rewrites, and `ffi_dynamic_library.cc` which ADR-0013 depends on |
| **One guaranteed compile break** | `InterfaceSocketAddress`'s new 4th parameter, in the code that makes localsend work |
| **Skia patch needs re-validation** | Skia's pin moves; BoringSSL, abseil and zlib do not |
| **The SDK-hash trap fires again** | Re-pinning makes `gen_snapshot` bake a mismatched verification hash. Known and fixable, but it [already cost a day once](results/corpus-build-failures-2026-08-19.md) |
| **A full revalidation cycle** | Engine build, both Dart trees, 21 patches across six repos, conformance baseline, five test apps |

## Verdict, 2026-08-19: do not upgrade

Not because the cost is prohibitive — the engine half is genuinely cheap — but
because **nothing in the range addresses the measured bottleneck**.

That bottleneck is raster cost *inside* the damaged region: localsend's Receive
screen runs at 4.7 fps with only 13% of the screen damaged, while manga_reader
holds 48 fps at 89% — so `dmg%` does not predict frame rate and the cost
underneath it is still unattributed
([test apps-localsend-2026-08-19](results/corpus-localsend-2026-08-19.md),
[test apps-run-2026-08-19](results/corpus-run-2026-08-19.md)). No
framework release fixes a software rasterizer that is too slow per pixel on a
333 MHz ARM. The candidates for that are a GPU backend or finding what is
expensive in that region — not a version bump.

**Revisit when a 3.4x goes stable**, not when the tip moves. Re-run the
procedure above at that point; it is about an hour, and it prices the job
before you are committed to it. Two findings will still hold and are worth
carrying forward:

- The **engine** patch series ages very well. Nothing but GN files has moved in
  1,358 commits. Its stability is not the risk.
- The **Dart** patch series ages badly, and `runtime/bin` is the worst of it.
  If the patch surface is ever going to be reduced, that is where the reduction
  pays for itself.

## Sources

Every number above came from a command in the procedure, run on 2026-08-19
against a Flutter 3.47.0 checkout (framework + engine) and a shallow fetch of
`da6595cd` into `third_party/sdk` (Dart).
