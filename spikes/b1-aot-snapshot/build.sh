#!/usr/bin/env bash
# Phase 0.5 / B1 — produce an armv7 Dart AOT snapshot on the host.
#
# No Vita and no Vita3K involved. This proves the *host half* of milestone M1:
# that we can generate real 32-bit ARM AOT machine code for the pinned Flutter
# version, using a gen_snapshot we did not have to build ourselves.
#
# Usage:  ./build.sh
set -euo pipefail

cd "$(dirname "$0")"
OUT=out
FLUTTER_VERSION=3.44.8   # must match VERSIONS.md
SDK="$HOME/fvm/versions/$FLUTTER_VERSION/bin/cache/dart-sdk"

GEN_SNAPSHOT="$OUT/gen_snapshot_arm"
GEN_SNAPSHOT_URL="https://raw.githubusercontent.com/ardera/flutter-engine-binaries-for-arm/main/arm/gen_snapshot_macos_x64_release"

mkdir -p "$OUT"

if [[ ! -d "$SDK" ]]; then
  echo "error: Dart SDK not found at $SDK" >&2
  echo "       run: fvm install $FLUTTER_VERSION" >&2
  exit 1
fi

# ardera's gen_snapshot targets 32-bit ARM. It is an x86_64 Mach-O binary, so on
# Apple Silicon it runs under Rosetta. Host architecture is irrelevant to the
# output: this is a cross compiler.
if [[ ! -x "$GEN_SNAPSHOT" ]]; then
  echo "==> fetching gen_snapshot (arm target) from ardera/flutter-engine-binaries-for-arm"
  curl -fsSL -o "$GEN_SNAPSHOT" "$GEN_SNAPSHOT_URL"
  chmod +x "$GEN_SNAPSHOT"
  xattr -d com.apple.quarantine "$GEN_SNAPSHOT" 2>/dev/null || true
fi

# Step 1: Dart source -> AOT kernel (.dill).
# --aot enables the tree shaker and the AOT-specific transformations; the
# product platform dill drops assertions and debug-only code. The kernel binary
# format is version-locked to the SDK, so this SDK must match gen_snapshot's.
echo "==> gen_kernel: hello.dart -> $OUT/hello.dill"
"$SDK/bin/dartaotruntime" \
  "$SDK/bin/snapshots/gen_kernel_aot.dart.snapshot" \
  --platform "$SDK/lib/_internal/vm_platform_product.dill" \
  --aot \
  -Ddart.vm.product=true \
  -o "$OUT/hello.dill" \
  hello.dart

# Step 2: kernel -> armv7 AOT ELF.
# app-aot-elf is used here purely because it is the easiest form to inspect.
# Which form we actually ship on Vita is ADR-0005 and is still open.
echo "==> gen_snapshot: $OUT/hello.dill -> $OUT/hello-armv7.elf"
"$GEN_SNAPSHOT" \
  --snapshot_kind=app-aot-elf \
  --elf="$OUT/hello-armv7.elf" \
  "$OUT/hello.dill"

echo
echo "==> result"
file "$OUT/hello-armv7.elf"
ls -la "$OUT/hello-armv7.elf" "$OUT/hello.dill"

echo
echo "==> snapshot sections (the numbers that matter for ADR-0005's 16 MiB cap)"
objdump --section-headers "$OUT/hello-armv7.elf" 2>/dev/null \
  | awk '/Idx|isolate|vm_snapshot|\.text|\.rodata/ {print}'
