#!/usr/bin/env bash
# Phase 0.5 / B2 — measure a real Flutter app's armv7 AOT snapshot.
#
# B1 showed a pure-Dart hello world needs 352 KiB of instructions. That says
# nothing about Flutter, because a Flutter app drags in the whole framework.
# This script produces the number that actually decides ADR-0005: does
# isolate_snapshot_instructions fit under the 16 MiB sceKernelAllocMemBlockForVM
# cap, with enough headroom to be worth designing around?
#
# Host-only. No Vita, no Vita3K.
#
# Usage:  ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
OUT=out
FLUTTER_VERSION=3.44.8   # must match VERSIONS.md
FLUTTER="$HOME/fvm/versions/$FLUTTER_VERSION"
SDK="$FLUTTER/bin/cache/dart-sdk"
PATCHED_SDK="$FLUTTER/bin/cache/artifacts/engine/common/flutter_patched_sdk_product"

# Reuse the gen_snapshot B1 already fetched; fall back to downloading it.
GEN_SNAPSHOT="../b1-aot-snapshot/out/gen_snapshot_arm"
GEN_SNAPSHOT_URL="https://raw.githubusercontent.com/ardera/flutter-engine-binaries-for-arm/main/arm/gen_snapshot_macos_x64_release"

mkdir -p "$OUT"

if [[ ! -d "$PATCHED_SDK" ]]; then
  echo "error: flutter_patched_sdk_product not found at:" >&2
  echo "       $PATCHED_SDK" >&2
  echo "       run: fvm flutter precache" >&2
  exit 1
fi

if [[ ! -x "$GEN_SNAPSHOT" ]]; then
  mkdir -p "$(dirname "$GEN_SNAPSHOT")"
  curl -fsSL -o "$GEN_SNAPSHOT" "$GEN_SNAPSHOT_URL"
  chmod +x "$GEN_SNAPSHOT"
  xattr -d com.apple.quarantine "$GEN_SNAPSHOT" 2>/dev/null || true
fi

# The app is generated rather than committed: it is stock `flutter create`
# output, and regenerating keeps it honest against the pinned SDK.
APP="$OUT/counter_app"
if [[ ! -d "$APP" ]]; then
  echo "==> flutter create (stock counter app)"
  "$FLUTTER/bin/flutter" create --project-name counter_app --platforms=android "$APP" >/dev/null
fi

echo "==> pub get"
(cd "$APP" && "$FLUTTER/bin/flutter" pub get >/dev/null)

# Step 1: Flutter app -> AOT kernel.
# Note --target=flutter and the *flutter* patched SDK: unlike B1, the platform
# here is Flutter's patched dart:ui-aware SDK, not the plain VM platform.
# --tfa is the global type-flow analysis pass that does the real tree shaking;
# without it the snapshot is dramatically larger and the measurement is useless.
echo "==> frontend_server: lib/main.dart -> $OUT/app.dill"
"$SDK/bin/dartaotruntime" \
  "$SDK/bin/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$PATCHED_SDK/" \
  --target=flutter \
  --aot --tfa \
  -Ddart.vm.product=true \
  --packages "$APP/.dart_tool/package_config.json" \
  --output-dill "$OUT/app.dill" \
  "$APP/lib/main.dart"

# Step 2: kernel -> armv7 AOT ELF.
echo "==> gen_snapshot: $OUT/app.dill -> $OUT/counter-armv7.elf"
"$GEN_SNAPSHOT" \
  --snapshot_kind=app-aot-elf \
  --elf="$OUT/counter-armv7.elf" \
  "$OUT/app.dill"

echo
echo "==> result"
file "$OUT/counter-armv7.elf"

echo
echo "==> sections vs the 16 MiB VM block cap (ADR-0005)"
objdump --section-headers "$OUT/counter-armv7.elf" 2>/dev/null \
  | awk '$2==".text" || $2==".rodata" {print "  " $2 "  0x" $3}'

python3 - "$OUT/counter-armv7.elf" <<'PY'
import subprocess, sys
out = subprocess.run(["objdump","--section-headers",sys.argv[1]],
                     capture_output=True, text=True).stdout
sec = {}
for line in out.splitlines():
    f = line.split()
    if len(f) >= 4 and f[1] in (".text", ".rodata"):
        sec[f[1]] = int(f[2], 16)
cap = 16 * 1024 * 1024
t, r = sec.get(".text", 0), sec.get(".rodata", 0)
print()
print(f"  .text   (AOT instructions) : {t:>10,} B = {t/1048576:6.2f} MiB")
print(f"  .rodata (snapshot heap)    : {r:>10,} B = {r/1048576:6.2f} MiB")
print(f"  16 MiB VM block cap        : {t/cap*100:6.2f}% consumed by instructions")
print(f"  headroom for app code      : {(cap-t)/1048576:6.2f} MiB")
PY
