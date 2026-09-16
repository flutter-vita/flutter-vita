#!/usr/bin/env bash
# Package the built engine into something someone else can download.
#
# Building the engine for Vita costs a 12 GB gclient checkout, a patched tree,
# and ~30 minutes. This turns a finished build into a tarball an app developer
# can unpack and link against.
#
# Usage:  ./tools/package-engine.sh [output-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENGINE_SRC="$ROOT/third_party/flutter/engine/src"
ENGINE_OUT="$ENGINE_SRC/out/vita_release"
OUT="${1:-$ROOT/out/artifacts}"

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
  # report work pending forever. This phony target is the embedder plus
  # everything it links, which is what the archive below scrapes up.
  SHIP_TARGET="phony/flutter/shell/platform/embedder/vita_embedder"
  # depot_tools on PATH for the check too, not just for the build it tells you
  # to run. Without it `ninja -n` cannot resolve the host toolchain's generator
  # rules and reports 3096 pending steps on a tree it has just declared up to
  # date, which turns this guard into a wall.
  PENDING="$( (cd "$ENGINE_SRC" && PATH="$HOME/depot_tools:$PATH" ninja -C out/vita_release -n "$SHIP_TARGET" 2>/dev/null | grep -c '^\[') || echo 0)"
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

# Pins come from the build that produced these objects, not from VERSIONS.md.
# If the two ever disagree, the artifact is what actually shipped and the doc is
# what someone meant to ship -- so read the args.
read_arg() { grep -m1 "^$1 = " "$ENGINE_OUT/args.gn" | sed 's/.*= *//; s/"//g'; }
ENGINE_VERSION="$(read_arg engine_version)"
SKIA_VERSION="$(read_arg skia_version)"
DART_VERSION="$(read_arg dart_version)"
FLUTTER_VERSION="$(grep -m1 -oE '3\.[0-9]+\.[0-9]+' "$ROOT/VERSIONS.md" || echo unknown)"

# The revision of the Flutter SDK these objects were built against.
#
# The artifact's compatibility key, and it has to be a revision: dart:ui and the
# engine are one source tree cut in half, so a framework that does not match is
# undefined behaviour at runtime with no error at build time. Read from
# bin/cache/flutter.version.json, the same file the consumer reads.
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/fvm/versions/$FLUTTER_VERSION}"
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
xargs arm-vita-eabi-ar rcs "$STAGE/lib/libflutter_engine_vita.a" < "$OUT/.objs"
rm -f "$OUT/.objs"

echo "==> stripping debug info"
# 1.1 GB to 63 MB, because the build carries -g2 and DWARF dwarfs the code.
# The trade is engine-level symbolication in crash dumps: anyone debugging the
# engine itself is building it anyway, and anyone building an app is not.
arm-vita-eabi-strip --strip-debug "$STAGE/lib/libflutter_engine_vita.a"

cp "$ENGINE_SRC/flutter/shell/platform/embedder/embedder.h" "$STAGE/include/"
# The eight functions the embedder wants from the GL the app links (ADR-0019).
# The template's gl_gles2.c implements them over fvita_gles2.
cp "$ENGINE_SRC/flutter/shell/platform/embedder/flutter_vita_gl.h" "$STAGE/include/"

# The embedder inside the archive calls into the dev server, so the archive has
# three undefined symbols an app must satisfy:
#
#   U dev_server_run  dev_server_set_framebuffer_source  dev_server_set_tap_handler
#
# It ships as source, because it is the piece most likely to be swapped out: a
# shipping app wants no listening socket and can link a stub instead.
mkdir -p "$STAGE/src"
cp "$ROOT/experiments/m1-vpk/src/devserver.c" "$ROOT/experiments/m1-vpk/src/devserver.h" "$STAGE/src/"
cp "$ENGINE_SRC/flutter/third_party/icu/flutter/icudtl.dat" "$STAGE/data/"
# Roboto out of the repository, not out of the engine checkout.
#
# The checkout's copy lives under txt/third_party/fonts, which txt/BUILD.gn
# lists in test_fixtures inside `if (enable_unittests)`. It is a unit-test
# asset. That is why LICENSE.engine has no mention of Roboto: upstream's
# licence tooling excludes fixtures, correctly, because upstream does not ship
# them. This port does ship it, so it is tracked here with its licence.
cp "$ROOT/assets/fonts/Roboto-Regular.ttf" "$STAGE/data/"
# Roboto Mono, so that fontFamily: 'monospace' has something to resolve to.
# Without it the alias table in platform_vita.cc names a family nobody shipped
# and every fixed-pitch request falls back to Roboto, which is proportional.
cp "$ROOT/assets/fonts/RobotoMono-Regular.ttf" "$STAGE/data/"
# The OFL requires the notice and the licence to travel with every copy of the
# font. Both fonts above are under it and neither carried it until 2026-09-09,
# so every vpk built before then was out of compliance.
cp "$ROOT/assets/fonts/OFL.txt" "$STAGE/data/"

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
# sources, which is why it is copied rather than composed here.
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/NOTICE" "$STAGE/NOTICE"
SKY_LICENSE="$FLUTTER_DIR/bin/cache/pkg/sky_engine/LICENSE"
if [ -f "$SKY_LICENSE" ]; then
  cp "$SKY_LICENSE" "$STAGE/LICENSE.engine"
else
  echo "!! no $SKY_LICENSE -- run: $FLUTTER_DIR/bin/flutter precache" >&2
  exit 1
fi

cat > "$STAGE/MANIFEST.txt" <<EOF
flutter-engine-vita

flutter          $FLUTTER_VERSION
framework_rev    $FRAMEWORK_REVISION
engine           $ENGINE_VERSION
skia             $SKIA_VERSION
dart             $DART_VERSION
target           arm-vita-eabi, armv7-a hard-float, neon
objects archived $COUNT
built on         $HOST
built at         $(date -u +%Y-%m-%dT%H:%M:%SZ)

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
TARBALL="$OUT/flutter-engine-vita-$FLUTTER_VERSION.tar.gz"
tar -czf "$TARBALL" -C "$OUT" "$(basename "$STAGE")"

echo
cat "$STAGE/MANIFEST.txt"
echo
echo "==> $TARBALL  $(du -h "$TARBALL" | cut -f1)"
