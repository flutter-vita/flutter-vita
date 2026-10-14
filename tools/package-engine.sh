#!/usr/bin/env bash
# Package the built engine into something someone else can download.
#
# Building the engine for Vita costs a 12 GB gclient checkout, a patched tree,
# and ~30 minutes. This turns a finished build into a tarball an app developer
# can unpack and link against.
#
# Usage:  ./tools/package-engine.sh [--release TAG] [output-dir]
#
# --release names the tarball for the fork's release TAG, which is the engine
# commit's first eight characters (docs/release.md):
# flutter-engine-vita-<flutter>-<TAG>.tar.gz, and stamps TAG into
# MANIFEST.txt as `release`. tools/publish-engine.sh passes it. The unpacked
# directory keeps its plain name (flutter-engine-vita-<flutter>), which is
# what the tools look for.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENGINE_SRC="$ROOT/third_party/flutter/engine/src"
ENGINE_OUT="$ENGINE_SRC/out/vita_release"
OUT="$ROOT/out/artifacts"
RELEASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) OUT="$1"; shift ;;
  esac
done

: "${VITASDK:?Define VITASDK. See docs/dev-environment.md}"
export PATH="$VITASDK/bin:$PATH"

[ -d "$ENGINE_OUT/obj" ] || { echo "No engine build at $ENGINE_OUT" >&2; exit 1; }

# Refuse to package a build that is not finished.
#
# The archive is a directory scrape -- `find obj -name '*.o'` -- which cannot
# tell a current object from a stale one, and every stale object still links,
# packages and deploys. You get a working app that does not contain your change.
#
# It has happened twice:
#
#   1. `vpython3` missing from PATH. GN's actions for the Impeller flatbuffers
#      and Dart's version.cc failed with code=127, ninja stopped before
#      vita_embedder.o, and the previous object shipped.
#
#   2. Editing embedder.h and rebuilding only the obvious objects. That header
#      invalidates 1950 objects; four were rebuilt. FlutterSoftwareRendererConfig
#      had grown a field, so 1946 translation units disagreed about its size.
#
# `ninja -n` answers "is there work left" for the whole graph in a second.
if [ "${SKIP_FRESHNESS:-0}" != "1" ]; then
  # The *shipped* target, not `all`. GN's default target includes the JIT core
  # snapshots, which this port cannot build (ADR-0001), so checking `all` would
  # report work pending forever. This phony target is the embedder API plus
  # everything it links, which is what the archive below scrapes up.
  SHIP_TARGET="phony/flutter/shell/platform/embedder/vita_runtime"
  # depot_tools on PATH for the check too, not just for the build it tells you
  # to run. Without it `ninja -n` cannot resolve the host toolchain's generator
  # rules and reports 3096 pending steps on a tree it has just declared up to
  # date, which turns this guard into a wall.
  # grep -c prints 0 and exits 1 on no match, so `|| true`, not `|| echo 0`.
  PENDING="$( (cd "$ENGINE_SRC" && PATH="$HOME/depot_tools:$PATH" ninja -C out/vita_release -n "$SHIP_TARGET" 2>/dev/null | grep -c '^\[') || true)"
  if [ "${PENDING:-0}" -gt 0 ]; then
    echo "!! $PENDING build steps are still pending in $ENGINE_OUT" >&2
    echo "   Packaging now would archive stale objects, and stale objects link" >&2
    echo "   and run -- you would be measuring the previous build." >&2
    echo >&2
    echo "   Run:  PATH=\"\$HOME/depot_tools:\$PATH\" ninja -C $ENGINE_OUT $SHIP_TARGET" >&2
    echo "   (depot_tools is needed: the build shells out to vpython3.)" >&2
    echo >&2
    echo "   SKIP_FRESHNESS=1 to package anyway." >&2
    exit 1
  fi
fi

# Pins come from the build that produced these objects, not from versions.json.
# If the two ever disagree, the artifact is what actually shipped and the doc is
# what someone meant to ship -- so read the args.
read_arg() { grep -m1 "^$1 = " "$ENGINE_OUT/args.gn" | sed 's/.*= *//; s/"//g'; }
ENGINE_VERSION="$(read_arg engine_version)"
SKIA_VERSION="$(read_arg skia_version)"
DART_VERSION="$(read_arg dart_version)"

# args.gn records what GN was told, which is the upstream revision DEPS named
# when `gn gen` last ran. The port's sources come from six forks now
# (ADR-0021), so ask git what the build actually compiled. Each answer is a
# commit in the repository named beside it, and each falls back to the args
# value if that tree is not a checkout.
TREE_ROOT="$ENGINE_SRC/../.."
git_head() { git -C "$TREE_ROOT/$1" rev-parse HEAD 2>/dev/null; }
ENGINE_VERSION="$(git_head . || echo "$ENGINE_VERSION")"
SKIA_VERSION="$(git_head engine/src/flutter/third_party/skia || echo "$SKIA_VERSION")"
DART_VERSION="$(git_head engine/src/flutter/third_party/dart || echo "$DART_VERSION")"
ABSEIL_VERSION="$(git_head engine/src/third_party/abseil-cpp)"
BORINGSSL_VERSION="$(git_head engine/src/flutter/third_party/boringssl/src)"
ZLIB_VERSION="$(git_head engine/src/flutter/third_party/zlib)"
FLUTTER_VERSION="$(sed -n 's/^[[:space:]]*"flutter":[[:space:]]*"\([0-9.]*\)".*/\1/p' "$ROOT/versions.json" 2>/dev/null | head -1)"
[ -n "$FLUTTER_VERSION" ] || FLUTTER_VERSION=unknown

# The revision of the Flutter SDK these objects were built against.
#
# The artifact's compatibility key, and it has to be a revision: dart:ui and the
# engine are one source tree cut in half, so a framework that does not match is
# undefined behaviour at runtime with no error at build time. Read from
# bin/cache/flutter.version.json, the same file the consumer reads.
[ -n "${FLUTTER_DIR:-}" ] || FLUTTER_DIR="$("$HERE/flutter-sdk.sh")" || exit 1
VERSION_JSON="$FLUTTER_DIR/bin/cache/flutter.version.json"
read_json() { grep -o "\"$1\": *\"[^\"]*\"" "$VERSION_JSON" | sed 's/.*: *"//; s/"$//'; }
if [ -f "$VERSION_JSON" ]; then
  FRAMEWORK_REVISION="$(read_json frameworkRevision)"
  FLUTTER_VERSION="$(read_json frameworkVersion)"
else
  echo "!! no $VERSION_JSON" >&2
  echo "   The artifact would ship without a compatibility key, and every" >&2
  echo "   consumer would have to trust that their SDK matches. Set FLUTTER_DIR." >&2
  exit 1
fi

STAGE="$OUT/flutter-engine-vita-$FLUTTER_VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include" "$STAGE/data"

# Drop outputs the build no longer produces, before archiving anything.
#
# Anything ninja stops building stays on disk forever and keeps shipping, and
# `--whole-archive` then forces every orphan into the app. This has been wrong
# three times in one day. The worst: BoringSSL was switched to pure C, 316
# objects rebuilt, and 123 assembly objects from the previous configuration were
# still archived, so `ChaCha20_ctr32_neon` was in the final binary.
#
# `cleandead` reads the whole build graph rather than what was last built, so it
# is safe after a partial build.
#
# It does NOT protect against building *too much*. GN emits the same source into
# several toolchain variants -- file_linux.cc has six -- and only one belongs
# here. Building all six produces five live objects `cleandead` will never touch.
# With --whole-archive the app then fails to link on duplicate symbols. Build the
# specific object; the live family is the one with dozens of members.
#
#   ar t libflutter_engine_vita.a | sed -n 's/^\(libdart_builtin[a-z_]*\)\..*/\1/p' \
#     | sort | uniq -c | sort -rn
if [ "${SKIP_CLEANDEAD:-0}" != "1" ]; then
  echo "==> pruning dead objects"
  ( cd "$ENGINE_SRC/.." && ninja -C "$(basename "$ENGINE_OUT" | sed 's|^|out/|')" -t cleandead 2>/dev/null ) \
    || ninja -C "$ENGINE_OUT" -t cleandead 2>/dev/null \
    || echo "   (cleandead unavailable — archive may contain orphans)"
fi

echo "==> archiving engine objects"
# The host-toolchain tree under clang_arm64/ is deliberately not here: those are
# macOS binaries for the build machine, and they go in the host bundle below.
#
# vita_link_check.o carries its own main(), left over from M2. Archived here it
# produces a duplicate-symbol error naming `main`, which reads as a bug in the
# app rather than as two objects that were never meant to meet.
find "$ENGINE_OUT/obj" -name '*.o' ! -name '*vita_link_check*' > "$OUT/.objs"
COUNT=$(wc -l < "$OUT/.objs" | tr -d ' ')
# `xargs -a` is a GNU extension; BSD xargs on macOS needs the redirect.
# D: deterministic headers (no timestamps, uid, gid), so the same objects give
# the same archive and the same sha256, and a repackage does not move the
# bridge's pin.
xargs arm-vita-eabi-ar rcsD "$STAGE/lib/libflutter_engine_vita.a" < "$OUT/.objs"
rm -f "$OUT/.objs"

echo "==> stripping debug info"
# 1.1 GB to 63 MB, because the build carries -g2 and DWARF dwarfs the code.
# The trade is engine-level symbolication in crash dumps: anyone debugging the
# engine itself is building it anyway, and anyone building an app is not.
# -D: strip rewrites the archive, and without it puts the timestamps back.
arm-vita-eabi-strip -D --strip-debug "$STAGE/lib/libflutter_engine_vita.a"

# What the embedder (flutter-vita/flutter-vita-embedder, compiled into every
# app) includes from the archive: the embedder API, this port's partial-repaint
# channel, and the revision the archive was built from, for the debug strip.
# The archive's one undefined reference to the embedder is
# flutter_vita_log_affinity, from fml/thread.cc.
cp "$ENGINE_SRC/flutter/shell/platform/embedder/embedder.h" \
   "$ENGINE_SRC/flutter/shell/platform/embedder/embedder_software_frame_damage.h" \
   "$STAGE/include/"
cat > "$STAGE/include/engine_version.h" <<EOF
// Generated by tools/package-engine.sh with this archive; do not edit.
#ifndef FLUTTER_VITA_ENGINE_VERSION_H_
#define FLUTTER_VITA_ENGINE_VERSION_H_
// The flutter/flutter revision the engine objects were built from. The same
// string flutter::GetFlutterEngineVersion() answers inside the archive.
#define FLUTTER_VITA_ENGINE_REVISION "$ENGINE_VERSION"
#define FLUTTER_VITA_FLUTTER_VERSION "$FLUTTER_VERSION"
#endif  // FLUTTER_VITA_ENGINE_VERSION_H_
EOF
cp "$ENGINE_SRC/flutter/third_party/icu/flutter/icudtl.dat" "$STAGE/data/"
# No fonts. An app takes Roboto and Roboto Mono from templates/fonts in the
# tool repo (templates/vita-app/CMakeLists.txt), so a font change does not
# wait for an engine release. Until 2026-10-14 they travelled in data/ here.

# No emoji font ships. It used to, and it was 1.9 MB in every vpk for one test
# app. Emoji coverage is an application's choice, not a platform guarantee:
# an app that wants it declares a font under `fonts:` in its pubspec and the
# asset font provider picks it up. Roboto stops at U+FFFD, so an app that
# declares nothing draws tofu, and that is the app's answer to give.

# The platform dill, built from *our* Dart SDK rather than stock Flutter's.
#
# build-vita-app.sh used to compile every app against the Flutter cache's
# flutter_patched_sdk_product, so the Dart half of dart:io came from upstream
# while the native half came from this port. That held until dart:io needed a
# new native (SecureSocket_ProcessAllBuffersSync), declared only in our tree.
#
# Shipping ours removes the split.
if [ -f "$ENGINE_OUT/flutter_patched_sdk/platform_strong.dill" ]; then
  mkdir -p "$STAGE/flutter_patched_sdk"
  cp "$ENGINE_OUT/flutter_patched_sdk/platform_strong.dill" \
     "$ENGINE_OUT/flutter_patched_sdk/vm_outline_strong.dill" \
     "$STAGE/flutter_patched_sdk/"
else
  echo "!! no flutter_patched_sdk in the build; apps will fall back to the" >&2
  echo "   Flutter cache's, which does not know this port's dart:io natives" >&2
fi

# gen_snapshot runs on the *build* machine, so it is tagged by host rather than
# shipped with the target artifacts. A Linux user needs their own.
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
if [ -x "$ENGINE_OUT/clang_arm64/gen_snapshot_armv7" ]; then
  mkdir -p "$STAGE/host-$HOST"
  cp "$ENGINE_OUT/clang_arm64/gen_snapshot_armv7" "$STAGE/host-$HOST/"
fi

# Licences travel with the artifact, because the artifact is what gets linked
# into a .vpk and the .vpk is the binary distribution BSD-3 clause 2 is about.
# LICENSE.engine is Flutter's own generated aggregate of every third-party
# licence in the engine -- upstream's tooling produced it from these same
# sources, which is why it is copied rather than composed here. LICENSE is the
# fork's own, BSD-3: the engine is Flutter's code, not ours (ADR-0023).
cp "$ROOT/third_party/flutter/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/NOTICE" "$STAGE/NOTICE"
SKY_LICENSE="$FLUTTER_DIR/bin/cache/pkg/sky_engine/LICENSE"
if [ -f "$SKY_LICENSE" ]; then
  cp "$SKY_LICENSE" "$STAGE/LICENSE.engine"
else
  echo "!! no $SKY_LICENSE -- run: $FLUTTER_DIR/bin/flutter precache" >&2
  exit 1
fi

RELEASE_LINE=""
[ -n "$RELEASE" ] && RELEASE_LINE="release          ${RELEASE}
"
cat > "$STAGE/MANIFEST.txt" <<EOF
flutter-engine-vita

${RELEASE_LINE}flutter          $FLUTTER_VERSION
framework_rev    $FRAMEWORK_REVISION
engine           $ENGINE_VERSION  flutter-vita/flutter vita-$FLUTTER_VERSION
dart             $DART_VERSION  flutter-vita/dart-sdk
skia             $SKIA_VERSION  flutter-vita/skia
abseil           $ABSEIL_VERSION  flutter-vita/abseil-cpp
boringssl        $BORINGSSL_VERSION  flutter-vita/boringssl
zlib             $ZLIB_VERSION  flutter-vita/zlib
target           arm-vita-eabi, armv7-a hard-float, neon
objects archived $COUNT
built on         $HOST
built at         $(date -u +%Y-%m-%dT%H:%M:%SZ)

Every revision above is a commit in the repository named beside it. Those six
repositories are the whole port; there are no patch files. See ADR-0021.

framework_rev is the compatibility key. Build an app with a Flutter SDK at any
other revision and dart:ui will not match the engine it is calling into: no
build error, undefined behaviour at runtime. tools/build-vita-app.sh refuses
the mismatch rather than warning about it.

Link with --whole-archive. The engine relies on static initialisers in
translation units nothing references by symbol, and ordinary archive semantics
pull in only what resolves an undefined reference -- so a plain -l link drops
them silently and fails at runtime rather than at link time.

Also required, and easy to lose:

  -Wl,-u,pthread_cancel

gcc decides whether a program is threaded by taking the address of
pthread_cancel, which is a weak reference that does not pull an archive member.
Without this every std::mutex::lock() in the engine compiles to a no-op and the
mutexes are never initialised. See docs/phase-2-workplan.md.
EOF

echo "==> tarball"
mkdir -p "$OUT"
if [ -n "$RELEASE" ]; then
  TARBALL="$OUT/flutter-engine-vita-${FLUTTER_VERSION}-${RELEASE}.tar.gz"
else
  TARBALL="$OUT/flutter-engine-vita-$FLUTTER_VERSION.tar.gz"
fi
tar -czf "$TARBALL" -C "$OUT" "$(basename "$STAGE")"

echo
cat "$STAGE/MANIFEST.txt"
echo
echo "==> $TARBALL  $(du -h "$TARBALL" | cut -f1)"
