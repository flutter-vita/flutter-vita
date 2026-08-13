#!/usr/bin/env bash
# Package the built engine into something someone else can download.
#
# Building the engine for Vita currently costs a 12 GB gclient checkout, a
# patched tree, and ~30 minutes. Nobody evaluates a port with that as step one,
# so this turns a finished build into a tarball an app developer can unpack and
# link against. It is the gate on every other distribution idea.
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

# Pins come from the build that produced these objects, not from VERSIONS.md.
# If the two ever disagree, the artifact is what actually shipped and the doc is
# what someone meant to ship -- so read the args.
read_arg() { grep -m1 "^$1 = " "$ENGINE_OUT/args.gn" | sed 's/.*= *//; s/"//g'; }
ENGINE_VERSION="$(read_arg engine_version)"
SKIA_VERSION="$(read_arg skia_version)"
DART_VERSION="$(read_arg dart_version)"
FLUTTER_VERSION="$(grep -m1 -oE '3\.[0-9]+\.[0-9]+' "$ROOT/VERSIONS.md" || echo unknown)"

STAGE="$OUT/flutter-engine-vita-$FLUTTER_VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include" "$STAGE/data"

echo "==> archiving engine objects"
# The host-toolchain tree under clang_arm64/ is deliberately not here: those are
# macOS binaries for the build machine, and they go in the host bundle below.
#
# vita_link_check.o carries its own main(), left over from M2. Archived
# alongside vita_embedder.o it produces a duplicate-symbol error naming `main`,
# which reads as a bug in the app rather than as two objects that were never
# meant to meet.
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

# The embedder inside the archive calls into the dev server, so the archive has
# three undefined symbols an app must satisfy:
#
#   U dev_server_run  dev_server_set_framebuffer_source  dev_server_set_tap_handler
#
# It lives in this repo rather than the engine tree, so it ships as source. That
# is deliberate for now: it is the piece most likely to be swapped out — a
# shipping app wants no listening socket at all, and can link a stub instead.
mkdir -p "$STAGE/src"
cp "$ROOT/spikes/m1-vpk/src/devserver.c" "$ROOT/spikes/m1-vpk/src/devserver.h" "$STAGE/src/"
cp "$ENGINE_SRC/flutter/third_party/icu/flutter/icudtl.dat" "$STAGE/data/"
cp "$ENGINE_SRC/flutter/txt/third_party/fonts/Roboto-Regular.ttf" "$STAGE/data/"

# gen_snapshot runs on the *build* machine, so it is tagged by host rather than
# shipped with the target artifacts. A Linux user needs their own.
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
if [ -x "$ENGINE_OUT/clang_arm64/gen_snapshot_armv7" ]; then
  mkdir -p "$STAGE/host-$HOST"
  cp "$ENGINE_OUT/clang_arm64/gen_snapshot_armv7" "$STAGE/host-$HOST/"
fi

cat > "$STAGE/MANIFEST.txt" <<EOF
flutter-engine-vita

flutter          $FLUTTER_VERSION
engine           $ENGINE_VERSION
skia             $SKIA_VERSION
dart             $DART_VERSION
target           arm-vita-eabi, armv7-a hard-float, neon
objects archived $COUNT
built on         $HOST
built at         $(date -u +%Y-%m-%dT%H:%M:%SZ)

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
